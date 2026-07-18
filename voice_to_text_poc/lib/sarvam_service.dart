import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

/// Result of one Sarvam speech-to-text call.
class SarvamResult {
  final String transcript;
  final String? detectedLanguage;
  final String? requestId;
  final int latencyMs;

  SarvamResult({
    required this.transcript,
    required this.detectedLanguage,
    required this.requestId,
    required this.latencyMs,
  });
}

class SarvamException implements Exception {
  final String message;
  SarvamException(this.message);
  @override
  String toString() => message;
}

/// Result of one Sarvam text-translation call.
class SarvamTranslateResult {
  final String translatedText;
  final int latencyMs;

  SarvamTranslateResult({required this.translatedText, required this.latencyMs});
}

/// Thin client for Sarvam's speech APIs:
/// - Saarika  (speech-to-text):            transcribe in the spoken language
/// - Saaras   (speech-to-text-translate):  transcribe AND translate to English
/// - Mayura   (translate):                 text -> English
/// Docs: https://docs.sarvam.ai/api-reference-docs
class SarvamService {
  static const _endpoint = 'https://api.sarvam.ai/speech-to-text';
  static const _translateSpeechEndpoint =
      'https://api.sarvam.ai/speech-to-text-translate';
  static const _translateTextEndpoint = 'https://api.sarvam.ai/translate';

  /// Uploads the WAV file at [filePath] and returns the transcript.
  /// [languageCode] is e.g. 'ta-IN', 'en-IN' or 'unknown' (auto-detect,
  /// which is what handles Tanglish / code-mixed speech best).
  Future<SarvamResult> transcribe({
    required String filePath,
    required String apiKey,
    required String languageCode,
    String model = 'saarika:v2.5',
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw SarvamException('Recorded audio file not found: $filePath');
    }

    final stopwatch = Stopwatch()..start();
    final request = http.MultipartRequest('POST', Uri.parse(_endpoint))
      ..headers['api-subscription-key'] = apiKey
      ..fields['model'] = model
      ..fields['language_code'] = languageCode
      ..files.add(await http.MultipartFile.fromPath(
        'file',
        filePath,
        contentType: MediaType('audio', 'wav'),
      ));

    final http.StreamedResponse streamed;
    try {
      streamed = await request.send().timeout(const Duration(seconds: 60));
    } on SocketException catch (e) {
      throw SarvamException('Network error calling Sarvam: ${e.message}');
    }
    final body = await streamed.stream.bytesToString();
    stopwatch.stop();

    if (streamed.statusCode != 200) {
      throw SarvamException('Sarvam HTTP ${streamed.statusCode}: $body');
    }

    final json = jsonDecode(body) as Map<String, dynamic>;
    return SarvamResult(
      transcript: (json['transcript'] ?? '') as String,
      detectedLanguage: json['language_code'] as String?,
      requestId: json['request_id'] as String?,
      latencyMs: stopwatch.elapsedMilliseconds,
    );
  }

  /// Uploads the WAV file and returns an ENGLISH transcript (Saaras model).
  /// The spoken language (Tamil / English / code-mixed) is auto-detected.
  Future<SarvamResult> transcribeToEnglish({
    required String filePath,
    required String apiKey,
    String model = 'saaras:v2.5',
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw SarvamException('Recorded audio file not found: $filePath');
    }

    final stopwatch = Stopwatch()..start();
    final request =
        http.MultipartRequest('POST', Uri.parse(_translateSpeechEndpoint))
          ..headers['api-subscription-key'] = apiKey
          ..fields['model'] = model
          ..files.add(await http.MultipartFile.fromPath(
            'file',
            filePath,
            contentType: MediaType('audio', 'wav'),
          ));

    final http.StreamedResponse streamed;
    try {
      streamed = await request.send().timeout(const Duration(seconds: 60));
    } on SocketException catch (e) {
      throw SarvamException('Network error calling Sarvam: ${e.message}');
    }
    final body = await streamed.stream.bytesToString();
    stopwatch.stop();

    if (streamed.statusCode != 200) {
      throw SarvamException('Sarvam HTTP ${streamed.statusCode}: $body');
    }

    final json = jsonDecode(body) as Map<String, dynamic>;
    return SarvamResult(
      transcript: (json['transcript'] ?? '') as String,
      detectedLanguage: json['language_code'] as String?,
      requestId: json['request_id'] as String?,
      latencyMs: stopwatch.elapsedMilliseconds,
    );
  }

  /// Translates already-transcribed text to English. Used on the cheap path:
  /// native STT produced Tamil text and only the translation needs the cloud.
  Future<SarvamTranslateResult> translateToEnglish({
    required String input,
    required String apiKey,
    String sourceLanguageCode = 'ta-IN',
  }) async {
    final stopwatch = Stopwatch()..start();
    final http.Response response;
    try {
      response = await http
          .post(
            Uri.parse(_translateTextEndpoint),
            headers: {
              'api-subscription-key': apiKey,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'input': input,
              'source_language_code': sourceLanguageCode,
              'target_language_code': 'en-IN',
            }),
          )
          .timeout(const Duration(seconds: 30));
    } on SocketException catch (e) {
      throw SarvamException('Network error calling Sarvam translate: ${e.message}');
    }
    stopwatch.stop();

    if (response.statusCode != 200) {
      throw SarvamException(
          'Sarvam translate HTTP ${response.statusCode}: ${response.body}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return SarvamTranslateResult(
      translatedText: (json['translated_text'] ?? '') as String,
      latencyMs: stopwatch.elapsedMilliseconds,
    );
  }
}
