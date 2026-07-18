import 'package:flutter/foundation.dart';

import 'models.dart';

/// Very small in-memory logger that the UI listens to.
/// Every important event (engine choice, confidence, latency, errors)
/// goes through here so it is visible inside the app itself.
class AppLogger extends ChangeNotifier {
  final List<LogEntry> entries = [];

  void _add(LogLevel level, String tag, String message) {
    entries.add(LogEntry(level, tag, message));
    debugPrint(entries.last.toString());
    notifyListeners();
  }

  void info(String tag, String message) => _add(LogLevel.info, tag, message);
  void success(String tag, String message) => _add(LogLevel.success, tag, message);
  void warn(String tag, String message) => _add(LogLevel.warn, tag, message);
  void error(String tag, String message) => _add(LogLevel.error, tag, message);

  void clear() {
    entries.clear();
    notifyListeners();
  }

  /// Full log as plain text (for the copy-to-clipboard button).
  String export() => entries.map((e) => e.toString()).join('\n');
}
