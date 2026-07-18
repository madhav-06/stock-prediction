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

/// Thin client for Sarvam's Saarika speech-to-text API.
/// Docs: https://docs.sarvam.ai/api-reference-docs/speech-to-text/transcribe
class SarvamService {
  static const _endpoint = 'https://api.sarvam.ai/speech-to-text';

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
}
