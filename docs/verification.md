# Verification record — 27 October 2026

## Final installable APK measurement

These are the final **release-mode, configuration-placeholder, debug-certificate-signed evaluation APKs** requested for this build. They are not connected to a live Supabase/Firebase project.

| ABI | APK bytes | Decimal MB | MiB | Strictly below 20,000,000 bytes |
| --- | ---: | ---: | ---: | --- |
| ARM64 / arm64-v8a | 7,708,952 | 7.708952 | 7.351830 | Yes |
| ARM32 / armeabi-v7a | 7,158,380 | 7.158380 | 6.826763 | Yes |

Distribution copies:

- artifacts/releases/two-tally-arm64-v8a-evaluation.apk
- artifacts/releases/two-tally-armeabi-v7a-evaluation.apk

Original build outputs are in build/app/outputs/flutter-apk/. Machine-readable reports: artifacts/apk-sizes.json and artifacts/apk-inspection.json.

The PowerShell file-size check and Android apkanalyzer apk file-size agree. apksigner verifies both APKs; both have debuggable=false and pass zipalign -c -P 16 4. The package is com.twotally.two_tally.

SHA-256:

~~~text
ARM64  67fd7b8f09edece5a9b0d9970832b211706b851f2b388f3626306abd0dd8c6e1
ARM32  2f353dae8735c12b42811633ab028b04a08c926fed851b6d6b673f71b0913077
~~~

Run tool/build_release.ps1 again after adding project configuration or changing dependencies. This record establishes the size of these exact APKs only.

## APK, download and installed size

APK size is the actual signed archive on disk and is the strict target used here. Separate ABIs avoid bundling libraries for architectures a phone cannot use.

Android apkanalyzer estimated compressed download sizes of **7,530,569 bytes for ARM64** and **6,984,075 bytes for ARM32**. These are tool estimates, not observed Play Store downloads. A store-generated split installation or direct file download can differ.

**Installed size was not measured** because no Android device was connected. It includes the APK, extracted native libraries with this packaging configuration, runtime-optimized code, and later application data. It can exceed 20 MB even when the installable APK meets the target. [Flutter's size measurement guidance](https://docs.flutter.dev/perf/app-size)

The ARM64 libapp.so and libflutter.so ELF LOAD segments were inspected with the Android NDK's llvm-readelf. All use 0x10000 (64 KiB) alignment. This passes the static alignment condition; actual 16 KB-page-device execution was not tested. Static checks do not establish runtime compatibility by themselves. [Android page-size compatibility](https://developer.android.com/guide/practices/page-sizes)

## Automated checks actually run

| Check | Result |
| --- | --- |
| Flutter analysis | No issues |
| Flutter unit/widget tests | 7 passed |
| Java payment parser tests | 17 passed |
| PostgreSQL/PGlite integration checks | 14 passed |
| Deno dispatcher tests | 3 passed |
| Deno type checking | Passed |
| Android release lint | Passed; 0 errors, informational compatibility/dependency warnings |
| ARM32/ARM64 release build | Passed |
| APK signature, alignment, debuggable flag | Verified |

Total: **41 local tests/check cases**, in addition to compilation, static analysis and APK inspection.

The Flutter tests cover exact money parsing, settlement math, request IDs, unconfigured startup, invalid custom shares, and rendering/navigation on a compact phone. The database suite executes actual PostgreSQL SQL with simulated Auth claims and roles, not mocked query return values.

Screen previews in artifacts/previews/ledger.png, summary.png, and settings.png were visually inspected. They use synthetic fixture data and are not evidence of a live cloud connection.

Android lint reports the pinned older dependency/target versions; no lint errors were suppressed or baselined. The API-27-only listener-access check was replaced with an API-26-compatible fallback. A Windows memory-limit failure during a later build was resolved by limiting Gradle to one worker and a 1 GiB heap; the final rebuild succeeded.

## Still requires external validation

- Deploying migrations and the Edge Function to Supabase with real configuration.
- Real Auth email confirmation, refresh/revocation, and hosted Realtime behavior.
- Actual outgoing notification formats from Google Pay, PhonePe, Paytm, Kotak 811, and BHIM on the chosen phones/app versions/languages.
- Background confirmation while Flutter is closed, Android reboot/Doze/force-stop behavior, and manufacturer battery restrictions.
- FCM delivery, offline reconnect timing, token rotation and duplicate suppression on devices.
- Actual installed storage and runtime behavior on both 4 KB and 16 KB-page devices.
- Production signing and any store-specific publishing requirements.

Use docs/testing.md for the two-device acceptance procedure. During the original placeholder build, no real payment was initiated, no financial credentials were accessed, and no cloud project was modified. Subsequent hosted setup is recorded separately in [deployment.md](deployment.md).
