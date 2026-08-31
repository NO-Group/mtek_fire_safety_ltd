# M-TEK Inventory — ONE app, TWO build paths

The Flutter app in this folder is the whole product. There is no web/PWA
version anymore (owner directive 2026-08-30). Both builds talk to the SAME
server (Supabase Auth + the `data-api` Edge Function over MongoDB), so data
entered on the phone appears on the PC instantly.

**STOCK IS NEVER PRE-LOADED.** A fresh install has an empty catalogue —
every product is entered through the app itself:
- **Stock → Add product** (name, category, cost, selling price, quantity,
  reorder level, unit, service toggle), or
- **Stock → Import TXT** (optional bulk path for an edited products_seed.txt).

## Build the APK (Android)
1. Install Flutter SDK (flutter.dev) and Android Studio once.
2. Open this `app/` folder.
3. Double-click **`make_apk.bat`** — nothing else. Server and keys are
   already baked into the app.
   → APK appears at `app\build\app\outputs\flutter-apk\app-release.apk`.

Command line equivalent:
```
flutter build apk --release
```
(SUPABASE_URL and MILS_API_BASE are already baked in.)

## Build the EXE (Windows)
One-time prerequisite: install **Visual Studio 2022** (the free Community
edition) and tick **"Desktop development with C++"** in the installer —
Flutter needs its compiler for Windows EXEs.

Same prerequisites, then double-click **`make_exe.bat`** — nothing else.
→ Folder: `app\build\windows\x64\runner\Release\` (zip created for you:
`M-TEK-windows.zip`). Copy the whole folder to any Windows PC and run
`m_tek_inventory.exe` — no installation needed.

Command line equivalent:
```
flutter build windows --release
```

## Sign in
The CEO signs in with `mtekfiresafetyltd@gmail.com` + the company password.
The server (Supabase + MongoDB) must be deployed first — see
`supabase/README.md` in the repo root.
