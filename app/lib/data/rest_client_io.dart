import 'dart:convert';
import 'dart:io';

/// IO HTTP implementation (Android/Windows/desktop).
/// [httpJson] returns status + decoded body (null on transport failure) so
/// callers can distinguish "server said no" from "offline".
Future<RestJsonResponse?> httpJson({
  required String method,
  required String url,
  required Map<String, String> headers,
  Object? body,
}) async {
  HttpClient? client;
  try {
    client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 12);
    final req = await client.openUrl(method, Uri.parse(url));
    headers.forEach(req.headers.set);
    if (body != null) req.add(utf8.encode(jsonEncode(body)));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    return RestJsonResponse(status: res.statusCode, text: text);
  } catch (_) {
    return null; // offline — callers fall back to the local store / queue
  } finally {
    client?.close();
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
