// Web HTTP implementation (fetch).
// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:convert';
import 'dart:html' as html;

Future<RestJsonResponse?> httpJson({
  required String method,
  required String url,
  required Map<String, String> headers,
  Object? body,
}) async {
  try {
    final res = await html.HttpRequest.request(url,
        method: method,
        requestHeaders: headers,
        sendData: body == null ? null : jsonEncode(body));
    return RestJsonResponse(status: res.status, text: res.responseText ?? '');
  } catch (_) {
    return null; // offline — callers fall back to the local store / queue
  }
}

/// Legacy boolean helper kept for the sync queue flush path.
Future<bool> httpRequest({
  required String method,
  required String url,
  required Map<String, String> headers,
  required List<Map<String, dynamic>> body,
}) async {
  final res = await httpJson(method: method, url: url, headers: headers, body: body);
  return res != null && res.ok;
}

class RestJsonResponse {
  final int status;
  final String text;
  const RestJsonResponse({required this.status, required this.text});
  bool get ok => status >= 200 && status < 300;
  dynamic get json {
    try {
      return text.isEmpty ? null : jsonDecode(text);
    } catch (_) {
      return null;
    }
  }
}
