# Persisted SAF read after process death

This device acceptance checks the real Android document provider, App grant, and `DocumentAccess` snapshot reader. It is not a synthetic Cursor test. The test reads only a dedicated root-level file named `dsh-saf-acceptance.txt` containing exactly `Pocket Harness SAF acceptance v1` followed by one LF newline. Create a dedicated folder with that file and grant Pocket Harness read access to the folder through the App's file picker. The probe requires exactly one persisted, available directory grant containing that fixture. It does not revoke any grant or modify the fixture.

Build the App and AndroidTest APKs from the same source and signer, then run only when device access is authorized:

```sh
node apps/android/tool/acceptance-saf-grant-device.mjs --apk <app.apk> --test-apk <androidTest.apk> [--serial <adb-serial>]
```

The runner records both artifact hashes, verifies package identity, signer and the AndroidTest instrumentation manifest, installs with `adb install -r` (retaining App data), rejects missing or ambiguous ADB authorization, reads the exact fixture through the persisted grant in the Agent process, force-stops the App, and reads again in a distinct Agent process. Both reads must return the same grant ID and exact fixture digest. `am force-stop` interrupts all App processes and active tasks. Do not run while the user is using the phone. A pass establishes this narrow grant and read path on that device; it does not establish arbitrary provider compatibility, revoked-grant behavior, offline network execution, or long-running background task survival.

Host parser checks: `node --test apps/android/tool/acceptance-saf-grant-device.test.mjs`. Compilation alone and host checks do not count as device evidence.
