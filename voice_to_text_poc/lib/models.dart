/// Shared data types for the POC.

/// Which engine (or combination) produced the final text.
enum Engine { native, sarvam, hybrid }

extension EngineLabel on Engine {
  String get label => switch (this) {
        Engine.native => 'NATIVE (on-device)',
        Engine.sarvam => 'SARVAM AI (cloud)',
        Engine.hybrid => 'NATIVE STT + SARVAM TRANSLATE',
      };
}

/// Severity of a log line, used only for coloring in the log panel.
enum LogLevel { info, success, warn, error }

/// One line in the in-app log panel.
class LogEntry {
  final DateTime timestamp;
  final LogLevel level;

  /// Short tag shown in brackets: APP, NATIVE or SARVAM.
  final String tag;
  final String message;

  LogEntry(this.level, this.tag, this.message) : timestamp = DateTime.now();

  String get timeString {
    String two(int v) => v.toString().padLeft(2, '0');
    final t = timestamp;
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';
  }

  @override
  String toString() => '$timeString [$tag] $message';
}

/// The final outcome of one voice-to-text attempt, shown in the result card.
class SttOutcome {
  final Engine engine;
  final String transcript;

  /// 0.0 - 1.0, or null when the engine did not report a confidence
  /// (Sarvam's API does not return one; some Android devices return -1).
  final double? confidence;
  final int latencyMs;
  final String languageCode;

  /// Extra engine-specific details (e.g. Sarvam request id, detected language).
  final String details;

  SttOutcome({
    required this.engine,
    required this.transcript,
    required this.confidence,
    required this.latencyMs,
    required this.languageCode,
    this.details = '',
  });
}

/// Languages the POC supports. `nativePrefix` is matched against the
/// device's installed recognizer locales; `sarvamCode` is sent to Sarvam.
class PocLanguage {
  final String label;
  final String nativePrefix;
  final String sarvamCode;

  const PocLanguage(this.label, this.nativePrefix, this.sarvamCode);

  static const tamil = PocLanguage('Tamil', 'ta', 'ta-IN');
  static const english = PocLanguage('English (India)', 'en', 'en-IN');

  /// Tanglish: let the native recognizer use Tamil (best effort) and ask
  /// Sarvam to auto-detect ("unknown" enables code-mixed handling).
  static const tanglish = PocLanguage('Tanglish (auto-detect)', 'ta', 'unknown');

  static const all = [tamil, english, tanglish];
}
