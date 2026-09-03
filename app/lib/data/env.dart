/// Build-time configuration. EVERYTHING is baked in: the apps (APK and
/// Windows EXE) ship pointing at the company's REAL server — a plain
/// `flutter build apk --release` needs no flags at all.
/// NOTE: the API lives at `data-api2` — the original `data-api` function
/// name got a corrupted deployment cache on Supabase's edge (every new
/// deploy of it kept serving a days-old bundle; verified by canary bisect),
/// so the identical code now deploys under a fresh name.
/// (The anon key is a PUBLIC client key by design; all authority is
/// enforced server-side by the data API.)
abstract final class Env {
  /// TEMPORARY (owner directive 2026-09-03): the "Sign to issue" passcode
  /// pop-up is switched OFF for every user. Documents are still stamped
  /// with the signed-in user's name/signature — only the passcode prompt
  /// is skipped. Set back to false to restore the gate (the server side
  /// is controlled by the SIGNATURE_GATE constant in data-api2/index.ts).
  static const bool signatureGateDisabled = true;

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
    defaultValue: 'https://kshuadjcflwlidupnqly.supabase.co/functions/v1/data-api2',
  );

  static bool get backendConfigured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
  static bool get apiConfigured => apiBase.isNotEmpty;
}
