# Short device acceptance preflight

Run this only after a candidate APK has already passed `verify-apk.ps1` and its
SHA-256 has been recorded:

```powershell
node apps/android/tool/device-readiness.mjs --apk .cache/android/pocket-harness-0.1.0+37-arm64-debug.apk --sha256 <recorded-sha256>
```

The command hashes the APK in bounded memory, then queries `adb devices -l`.
Only when exactly one authorized device is connected does it read the Android
API level, ABI, installed package version, overlay AppOp, currently registered
overlay window title, and Agent process ID. Every device query is read-only;
this command does not install, launch, grant permissions, or hold the display on.

The `connected` state means only that ADB can address one device. A false
`overlayWindow` value means the expected title was not observed in that
snapshot; it cannot prove an overlay was never displayed. An `ok: false` probe
means the fact is unavailable, not false. To accept the optional 1px overlay,
use `acceptance-overlay-lease.mjs` during an active task and verify its lifecycle
and background behavior on the phone. A visible overlay may be needed for some
Android foreground-service restart exemptions; the transparent 1px overlay
does not establish those exemptions or guarantee process survival.

This preflight is useful before requesting a short phone-testing window. If the
device is absent, unauthorized, or ambiguous, keep working on host-side checks
instead of occupying the phone with a stalled installation attempt.
