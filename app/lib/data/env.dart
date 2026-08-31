/// Build-time configuration. EVERYTHING is baked in: the apps (APK and
/// Windows EXE) ship pointing at the company's REAL server — a plain
/// `flutter build apk --release` needs no flags at all.
/// (The anon key is a PUBLIC client key by design; all authority is
/// enforced server-side by the data API.)
abstract final class Env {
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://kshuadjcflwlidupnqly.supabase.co',
  );
  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtzaHVhZGpjZmx3bGlkdXBucWx5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODgwMjg4NjksImV4cCI6MjEwMzYwNDg2OX0.9uK8CK-5Xw9ojCAHKQyUEPVleSDJYcsznmHZETNyJ-I',
  );
  static const apiBase = String.fromEnvironment(
    'MILS_API_BASE',
    defaultValue: 'https://kshuadjcflwlidupnqly.supabase.co/functions/v1/data-api',
  );

  static bool get backendConfigured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
  static bool get apiConfigured => apiBase.isNotEmpty;
}
