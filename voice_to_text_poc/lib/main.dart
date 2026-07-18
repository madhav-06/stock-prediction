import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'app_logger.dart';
import 'models.dart';
import 'sarvam_service.dart';

void main() {
  runApp(const VoicePocApp());
}

class VoicePocApp extends StatelessWidget {
  const VoicePocApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Voice-to-Text POC',
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

/// The overall state machine of one voice-to-text attempt.
enum PocState {
  idle,
  nativeListening, // native on-device recognizer is active
  sarvamRecording, // fallback: recording raw audio for Sarvam
  sarvamSending, // fallback: uploading audio to Sarvam
  translating, // accepted native text is being translated to English
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // ---- services ----
  final stt.SpeechToText _speech = stt.SpeechToText();
  final AudioRecorder _recorder = AudioRecorder();
  final SarvamService _sarvam = SarvamService();
  final AppLogger _log = AppLogger();

  // ---- settings (user-adjustable in the UI) ----
  PocLanguage _language = PocLanguage.tanglish;
  double _confidenceThreshold = 0.70;
  bool _forceSarvam = false;
  bool _translateToEnglish = true;
  final TextEditingController _apiKeyController = TextEditingController();

  // ---- runtime state ----
  PocState _state = PocState.idle;
  bool _speechAvailable = false;
  String? _resolvedNativeLocale; // actual locale id picked from the device
  String _liveTranscript = ''; // partial results while listening
  SttOutcome? _lastOutcome;
  final Stopwatch _nativeStopwatch = Stopwatch();
  bool _nativeResultHandled = false; // guard against double final-result/error
  Timer? _sarvamMaxTimer;
  static const _sarvamMaxRecordSeconds = 15;

  @override
  void initState() {
    super.initState();
    _restoreApiKey();
    _initSpeech();
  }

  @override
  void dispose() {
    _sarvamMaxTimer?.cancel();
    _recorder.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Initialization
  // ---------------------------------------------------------------------------

  Future<void> _restoreApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('sarvam_api_key') ?? '';
    if (saved.isNotEmpty) {
      _apiKeyController.text = saved;
      _log.info('APP', 'Loaded saved Sarvam API key (${saved.length} chars).');
    }
  }

  Future<void> _saveApiKey(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sarvam_api_key', value.trim());
  }

  Future<void> _initSpeech() async {
    _log.info('APP', 'Initializing native speech recognizer…');
    try {
      _speechAvailable = await _speech.initialize(
        onStatus: _onNativeStatus,
        onError: _onNativeError,
      );
    } catch (e) {
      _speechAvailable = false;
      _log.error('NATIVE', 'Initialization threw: $e');
    }
    if (_speechAvailable) {
      final locales = await _speech.locales();
      _log.success('NATIVE',
          'Recognizer ready. ${locales.length} locales installed on device.');
      final tamil = locales.where((l) => l.localeId.toLowerCase().startsWith('ta'));
      _log.info(
          'NATIVE',
          tamil.isEmpty
              ? 'No Tamil locale installed — native Tamil results may be poor. '
                  '(Android: install Tamil in Google app / keyboard voice settings.)'
              : 'Tamil locales available: ${tamil.map((l) => l.localeId).join(', ')}');
    } else {
      _log.error('NATIVE',
          'Speech recognition NOT available on this device (permission denied '
          'or no recognition service). Only the Sarvam path will work.');
    }
    if (mounted) setState(() {});
  }

  /// Picks the best installed native locale for the selected language,
  /// e.g. prefix "ta" -> "ta_IN". Returns null to use the system default.
  Future<String?> _resolveNativeLocale() async {
    final locales = await _speech.locales();
    final prefix = _language.nativePrefix.toLowerCase();
    final matches =
        locales.where((l) => l.localeId.toLowerCase().startsWith(prefix)).toList();
    if (matches.isEmpty) return null;
    final indian = matches.where((l) => l.localeId.toUpperCase().contains('IN'));
    return (indian.isNotEmpty ? indian.first : matches.first).localeId;
  }

  // ---------------------------------------------------------------------------
  // Mic button — entry point of the flow
  // ---------------------------------------------------------------------------

  Future<void> _onMicPressed() async {
    switch (_state) {
      case PocState.idle:
        if (_forceSarvam) {
          _log.info('APP', '"Force Sarvam" is ON — skipping native recognizer.');
          await _startSarvamRecording(reason: 'forced by settings toggle');
        } else {
          await _startNativeListening();
        }
      case PocState.nativeListening:
        _log.info('NATIVE', 'Stop requested by user.');
        await _speech.stop(); // final result arrives via _onNativeResult
      case PocState.sarvamRecording:
        await _stopRecordingAndSendToSarvam();
      case PocState.sarvamSending:
      case PocState.translating:
        break; // network call in progress, nothing to do
    }
  }

  /// True when the text contains Tamil script (U+0B80–U+0BFF) and therefore
  /// needs a translation step to produce English output.
  bool _containsTamilScript(String text) =>
      RegExp(r'[஀-௿]').hasMatch(text);

  // ---------------------------------------------------------------------------
  // Step 1 — native on-device recognition (free)
  // ---------------------------------------------------------------------------

  Future<void> _startNativeListening() async {
    if (!_speechAvailable) {
      _log.warn('APP', 'Native recognizer unavailable — going straight to Sarvam.');
      await _startSarvamRecording(reason: 'native recognizer unavailable');
      return;
    }

    _resolvedNativeLocale = await _resolveNativeLocale();
    _log.info(
        'NATIVE',
        'Listening started. locale=${_resolvedNativeLocale ?? "system default"}, '
        'threshold=${_confidenceThreshold.toStringAsFixed(2)}');

    setState(() {
      _state = PocState.nativeListening;
      _liveTranscript = '';
      _lastOutcome = null;
    });
    _nativeResultHandled = false;
    _nativeStopwatch
      ..reset()
      ..start();

    await _speech.listen(
      onResult: _onNativeResult,
      localeId: _resolvedNativeLocale,
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 3),
      listenOptions: stt.SpeechListenOptions(partialResults: true),
    );
  }

  void _onNativeResult(SpeechRecognitionResult result) {
    if (!result.finalResult) {
      // Partial (live) result — just show it, no decision yet.
      setState(() => _liveTranscript = result.recognizedWords);
      return;
    }
    if (_nativeResultHandled) return;
    _nativeResultHandled = true;

    _nativeStopwatch.stop();
    final latencyMs = _nativeStopwatch.elapsedMilliseconds;
    final words = result.recognizedWords.trim();
    final hasRating = result.hasConfidenceRating && result.confidence >= 0;
    final confidence = hasRating ? result.confidence : null;

    _log.info(
        'NATIVE',
        'Final result in ${latencyMs}ms: "$words" | '
        'confidence=${confidence?.toStringAsFixed(2) ?? "not reported"}');

    // Show everything the OS recognizer reported. Note: Android's Google
    // recognizer is known to return coarse, flat scores (often ~0.87-0.90
    // for anything it parsed) — the app displays the raw OS value, it does
    // not compute confidence itself.
    if (result.alternates.length > 1) {
      final alts = result.alternates
          .take(3)
          .map((a) =>
              '"${a.recognizedWords}" (${a.confidence.toStringAsFixed(2)})')
          .join(' | ');
      _log.info('NATIVE',
          'OS returned ${result.alternates.length} hypotheses: $alts');
    }

    if (words.isEmpty) {
      _log.warn('NATIVE', 'Empty transcript → falling back to Sarvam.');
      _startSarvamRecording(reason: 'native returned empty transcript');
      return;
    }

    // ---- THE fallback decision ----
    // No confidence rating (some devices) is treated as acceptable for the
    // POC; use the "Force Sarvam" toggle to exercise the cloud path anyway.
    final passes = confidence == null || confidence >= _confidenceThreshold;

    if (passes) {
      _log.success(
          'NATIVE',
          'ACCEPTED (confidence '
          '${confidence == null ? "not reported — accepted by default" : "${confidence.toStringAsFixed(2)} ≥ threshold ${_confidenceThreshold.toStringAsFixed(2)}"}). '
          'Speech-to-text engine: NATIVE. Cost: free.');
      if (_translateToEnglish && _containsTamilScript(words)) {
        // Cheap path to English: keep the free native transcript and only
        // send TEXT (not audio) to Sarvam for translation.
        _translateNativeText(words, confidence, latencyMs);
        return;
      }
      setState(() {
        _state = PocState.idle;
        _liveTranscript = '';
        _lastOutcome = SttOutcome(
          engine: Engine.native,
          transcript: words,
          confidence: confidence,
          latencyMs: latencyMs,
          languageCode: _resolvedNativeLocale ?? 'system default',
          details: hasRating ? '' : 'Device did not report a confidence score.',
        );
      });
    } else {
      _log.warn(
          'NATIVE',
          'REJECTED: confidence ${confidence!.toStringAsFixed(2)} < threshold '
          '${_confidenceThreshold.toStringAsFixed(2)} → falling back to Sarvam.');
      _startSarvamRecording(
          reason: 'low native confidence ${confidence.toStringAsFixed(2)}');
    }
  }

  /// Native STT was accepted but produced Tamil script and "Output English"
  /// is on → translate the text via Sarvam (much cheaper than sending audio).
  Future<void> _translateNativeText(
      String words, double? confidence, int nativeLatencyMs) async {
    final apiKey = _apiKeyController.text.trim();
    if (apiKey.isEmpty) {
      _log.warn('SARVAM',
          'Transcript is Tamil but no API key set — cannot translate. '
          'Showing the native transcript as-is.');
      setState(() {
        _state = PocState.idle;
        _liveTranscript = '';
        _lastOutcome = SttOutcome(
          engine: Engine.native,
          transcript: words,
          confidence: confidence,
          latencyMs: nativeLatencyMs,
          languageCode: _resolvedNativeLocale ?? 'system default',
          details: 'Not translated (no API key).',
        );
      });
      return;
    }

    _log.info('SARVAM',
        'Native transcript is Tamil script → translating text to English '
        '(ta-IN → en-IN)…');
    setState(() {
      _state = PocState.translating;
      _liveTranscript = '';
    });

    try {
      final t = await _sarvam.translateToEnglish(input: words, apiKey: apiKey);
      _log.success(
          'SARVAM',
          'Translated in ${t.latencyMs}ms: "${t.translatedText}". '
          'Engine used: NATIVE STT (free) + SARVAM TRANSLATE (paid, text-only).');
      setState(() {
        _state = PocState.idle;
        _lastOutcome = SttOutcome(
          engine: Engine.hybrid,
          transcript: t.translatedText,
          confidence: confidence,
          latencyMs: nativeLatencyMs + t.latencyMs,
          languageCode: '${_resolvedNativeLocale ?? "?"} → en-IN',
          details:
              'Native STT ${nativeLatencyMs}ms + translate ${t.latencyMs}ms. Original: "$words"',
        );
      });
    } catch (e) {
      _log.error('SARVAM',
          'Translation failed: $e — showing the native Tamil transcript.');
      setState(() {
        _state = PocState.idle;
        _lastOutcome = SttOutcome(
          engine: Engine.native,
          transcript: words,
          confidence: confidence,
          latencyMs: nativeLatencyMs,
          languageCode: _resolvedNativeLocale ?? 'system default',
          details: 'Translation failed.',
        );
      });
    }
  }

  void _onNativeStatus(String status) {
    _log.info('NATIVE', 'Status: $status');
  }

  void _onNativeError(SpeechRecognitionError error) {
    _log.error('NATIVE',
        'Error: ${error.errorMsg} (permanent: ${error.permanent})');
    if (_state != PocState.nativeListening || _nativeResultHandled) return;
    _nativeResultHandled = true;
    _nativeStopwatch.stop();
    // Typical errors here: error_no_match, error_speech_timeout.
    // Either way the free path failed, so fall back.
    _log.warn('NATIVE', 'Native path failed → falling back to Sarvam.');
    _startSarvamRecording(reason: 'native error: ${error.errorMsg}');
  }

  // ---------------------------------------------------------------------------
  // Step 2 — fallback: record audio and send to Sarvam AI (paid)
  // ---------------------------------------------------------------------------
  //
  // POC limitation: Android/iOS do not let the native recognizer and a raw
  // audio recorder share the microphone, so the audio of the *first* attempt
  // is not available to us. The fallback therefore asks the user to speak
  // again while we record a WAV file for Sarvam.

  Future<void> _startSarvamRecording({required String reason}) async {
    final apiKey = _apiKeyController.text.trim();
    if (apiKey.isEmpty) {
      _log.error('SARVAM',
          'Cannot fall back ($reason): no API key set. Paste your key in Settings.');
      setState(() => _state = PocState.idle);
      return;
    }

    if (!await _recorder.hasPermission()) {
      _log.error('SARVAM', 'Microphone permission denied — cannot record.');
      setState(() => _state = PocState.idle);
      return;
    }

    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/sarvam_${DateTime.now().millisecondsSinceEpoch}.wav';

    _log.info('SARVAM',
        'Fallback triggered ($reason). SPEAK AGAIN now — recording WAV '
        '16 kHz mono (max ${_sarvamMaxRecordSeconds}s, tap mic to stop early).');

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );

    setState(() {
      _state = PocState.sarvamRecording;
      _liveTranscript = '';
    });

    _sarvamMaxTimer?.cancel();
    _sarvamMaxTimer = Timer(const Duration(seconds: _sarvamMaxRecordSeconds), () {
      if (_state == PocState.sarvamRecording) {
        _log.info('SARVAM', 'Max recording time reached — auto-stopping.');
        _stopRecordingAndSendToSarvam();
      }
    });
  }

  Future<void> _stopRecordingAndSendToSarvam() async {
    _sarvamMaxTimer?.cancel();
    final path = await _recorder.stop();
    if (path == null) {
      _log.error('SARVAM', 'Recorder returned no file.');
      setState(() => _state = PocState.idle);
      return;
    }

    final sizeKb = (await File(path).length()) / 1024;
    final translating = _translateToEnglish;
    _log.info(
        'SARVAM',
        'Recording stopped (${sizeKb.toStringAsFixed(1)} KB). Uploading to '
        '${translating ? "Sarvam Saaras (speech→ENGLISH text, model saaras:v2.5, spoken language auto-detected)" : "Sarvam Saarika (speech→text, model saarika:v2.5, language_code=${_language.sarvamCode})"}…');
    setState(() => _state = PocState.sarvamSending);

    try {
      final result = translating
          ? await _sarvam.transcribeToEnglish(
              filePath: path,
              apiKey: _apiKeyController.text.trim(),
            )
          : await _sarvam.transcribe(
              filePath: path,
              apiKey: _apiKeyController.text.trim(),
              languageCode: _language.sarvamCode,
            );
      _log.success(
          'SARVAM',
          '${translating ? "English transcript" : "Transcript"} in '
          '${result.latencyMs}ms: "${result.transcript}" | '
          'detected language: ${result.detectedLanguage ?? "n/a"} | '
          'request id: ${result.requestId ?? "n/a"}. Engine used: SARVAM (paid).');
      setState(() {
        _state = PocState.idle;
        _lastOutcome = SttOutcome(
          engine: Engine.sarvam,
          transcript: result.transcript,
          confidence: null, // Sarvam's API does not return a confidence score
          latencyMs: result.latencyMs,
          languageCode: translating
              ? '${result.detectedLanguage ?? "auto"} → en-IN'
              : _language.sarvamCode,
          details:
              'Detected: ${result.detectedLanguage ?? "n/a"} · Request: ${result.requestId ?? "n/a"}',
        );
      });
    } catch (e) {
      _log.error('SARVAM', 'Transcription failed: $e');
      setState(() => _state = PocState.idle);
    } finally {
      // Clean up the temp WAV.
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  String get _statusText => switch (_state) {
        PocState.idle => 'Tap the mic and speak',
        PocState.nativeListening => 'Listening (native, on-device)…',
        PocState.sarvamRecording =>
          'Recording for Sarvam — speak again, tap mic to stop',
        PocState.sarvamSending => 'Uploading to Sarvam AI…',
        PocState.translating => 'Translating to English (Sarvam)…',
      };

  Color get _micColor => switch (_state) {
        PocState.idle => Colors.indigo,
        PocState.nativeListening => Colors.green,
        PocState.sarvamRecording => Colors.deepPurple,
        PocState.sarvamSending => Colors.grey,
        PocState.translating => Colors.teal,
      };

  IconData get _micIcon => switch (_state) {
        PocState.idle => Icons.mic,
        PocState.nativeListening => Icons.hearing,
        PocState.sarvamRecording => Icons.fiber_manual_record,
        PocState.sarvamSending => Icons.cloud_upload,
        PocState.translating => Icons.translate,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice → Text POC'),
        actions: [
          IconButton(
            tooltip: 'Copy log',
            icon: const Icon(Icons.copy_all),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _log.export()));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Log copied to clipboard')));
              }
            },
          ),
          IconButton(
            tooltip: 'Clear log',
            icon: const Icon(Icons.delete_outline),
            onPressed: _log.clear,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildSettingsCard(),
            _buildMicSection(),
            if (_lastOutcome != null) _buildResultCard(_lastOutcome!),
            const Padding(
              padding: EdgeInsets.only(left: 16, top: 8, bottom: 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Log',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              ),
            ),
            Expanded(child: _buildLogPanel()),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsCard() {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: ExpansionTile(
        title: Text(
          'Settings · ${_language.label} · threshold ${_confidenceThreshold.toStringAsFixed(2)}'
          '${_forceSarvam ? " · FORCE SARVAM" : ""}',
          style: const TextStyle(fontSize: 13),
        ),
        childrenPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        children: [
          Row(
            children: [
              const Text('Language: '),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButton<PocLanguage>(
                  value: _language,
                  isExpanded: true,
                  items: PocLanguage.all
                      .map((l) =>
                          DropdownMenuItem(value: l, child: Text(l.label)))
                      .toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _language = v);
                    _log.info('APP',
                        'Language set to ${v.label} (native prefix "${v.nativePrefix}", Sarvam code "${v.sarvamCode}").');
                  },
                ),
              ),
            ],
          ),
          Row(
            children: [
              Text(
                  'Confidence threshold: ${_confidenceThreshold.toStringAsFixed(2)}'),
              Expanded(
                child: Slider(
                  value: _confidenceThreshold,
                  divisions: 20,
                  onChanged: (v) => setState(() => _confidenceThreshold = v),
                  onChangeEnd: (v) => _log.info('APP',
                      'Confidence threshold set to ${v.toStringAsFixed(2)}.'),
                ),
              ),
            ],
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Force Sarvam (skip native recognizer)'),
            value: _forceSarvam,
            onChanged: (v) {
              setState(() => _forceSarvam = v);
              _log.info('APP', 'Force Sarvam ${v ? "enabled" : "disabled"}.');
            },
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Output English (translate Tamil speech)'),
            subtitle: const Text(
                'Native Tamil text → Sarvam translate · fallback uses Saaras (speech → English)',
                style: TextStyle(fontSize: 11)),
            value: _translateToEnglish,
            onChanged: (v) {
              setState(() => _translateToEnglish = v);
              _log.info('APP', 'Output English ${v ? "enabled" : "disabled"}.');
            },
          ),
          TextField(
            controller: _apiKeyController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Sarvam API key (from dashboard.sarvam.ai)',
              isDense: true,
            ),
            onChanged: _saveApiKey,
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildMicSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        children: [
          FloatingActionButton.large(
            backgroundColor: _micColor,
            onPressed: _state == PocState.sarvamSending ? null : _onMicPressed,
            child: Icon(_micIcon, color: Colors.white, size: 40),
          ),
          const SizedBox(height: 8),
          Text(_statusText, style: const TextStyle(fontSize: 14)),
          if (_liveTranscript.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
              child: Text(
                _liveTranscript,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontStyle: FontStyle.italic, color: Colors.grey),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildResultCard(SttOutcome o) {
    final badgeColor = switch (o.engine) {
      Engine.native => Colors.green,
      Engine.sarvam => Colors.deepPurple,
      Engine.hybrid => Colors.teal,
    };
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: badgeColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(o.engine.label,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 11)),
                ),
                const Spacer(),
                Text(
                  'confidence: ${o.confidence?.toStringAsFixed(2) ?? "n/a"} · ${o.latencyMs} ms',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(
              o.transcript.isEmpty ? '(empty transcript)' : o.transcript,
              style: const TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 4),
            Text(
              'language: ${o.languageCode}${o.details.isNotEmpty ? " · ${o.details}" : ""}',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogPanel() {
    return AnimatedBuilder(
      animation: _log,
      builder: (context, _) {
        final entries = _log.entries.reversed.toList();
        return Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E2E),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ListView.builder(
            reverse: false,
            itemCount: entries.length,
            itemBuilder: (context, i) {
              final e = entries[i];
              final color = switch (e.level) {
                LogLevel.info => Colors.white70,
                LogLevel.success => Colors.greenAccent,
                LogLevel.warn => Colors.orangeAccent,
                LogLevel.error => Colors.redAccent,
              };
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: SelectableText.rich(
                  TextSpan(
                    style: TextStyle(
                        fontFamily: 'monospace', fontSize: 11, color: color),
                    children: [
                      TextSpan(
                          text: '${e.timeString} ',
                          style: const TextStyle(color: Colors.white38)),
                      TextSpan(
                          text: '[${e.tag}] ',
                          style:
                              const TextStyle(fontWeight: FontWeight.bold)),
                      TextSpan(text: e.message),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}
