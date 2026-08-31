import 'rest_client_io.dart' if (dart.library.html) 'rest_client_web.dart' as impl;

export 'rest_client_io.dart' if (dart.library.html) 'rest_client_web.dart'
    show RestJsonResponse;

/// The M-TEK DATA API client — every business read/write goes through the
/// `data-api` Supabase Edge Function (supabase/functions/data-api/index.ts),
/// which stores everything in the MongoDB section databases. Requests carry
/// the signed-in user's Supabase JWT so the server can enforce
/// CEO/Admin/Sales authority on every endpoint.
class ApiClient {
  final String baseUrl;
  String? accessToken; // Supabase JWT (set after sign-in)
  ApiClient({required this.baseUrl});

  Map<String, String> _headers() => {
        'Content-Type': 'application/json',
        if (accessToken != null) 'Authorization': 'Bearer $accessToken',
      };

  Future<impl.RestJsonResponse?> get(String path) => impl.httpJson(
        method: 'GET', url: '$baseUrl$path', headers: _headers());

  Future<impl.RestJsonResponse?> post(String path, Map<String, dynamic> body) =>
      impl.httpJson(method: 'POST', url: '$baseUrl$path', headers: _headers(), body: body);
}
