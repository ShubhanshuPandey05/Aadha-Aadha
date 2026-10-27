# Deployment status

The configured evaluation build uses a deployed Supabase backend and Firebase Cloud Messaging. To deploy your own instance, follow [setup](setup.md) and [Google sign-in setup](google-sign-in.md). Local app configuration, credentials, signing keys, and deployment backups are excluded from Git.

## Verified

- All five SQL migrations applied; RLS and Realtime configured.
- Push dispatcher deployed with server-only credentials, post-commit wakeup and retry cron.
- FCM validation returned HTTP 200; unauthorized dispatcher requests returned 401. Validation does not prove phone delivery.
- Google sign-in and group creation succeeded on a real Android device.
- A real Kotak notification was detected. The Kotak/BHIM server source allowlist was corrected afterward.
- On Xiaomi, Background autostart and notification access were required. A live listener was verified after swipe-away/reopen with those settings enabled.

## Release 1.0.7

Aadha/Aadha branding and typographic logo; Android package remains `com.twotally.two_tally` to preserve updates and account configuration.

ARM64 release APK: **8,033,088 bytes (8.03 MB)**, below the 20,000,000-byte target. Signature and packaged version/label verified. This evaluation build uses the Android debug signing certificate. Installed size and network download size have not been measured. The latest build was not automatically installed on a phone.

Static analysis and all eight Flutter tests passed for the branding update. Earlier parser/deduplication coverage passed 33 Java tests; database coverage passed 15 integration checks. Complete two-phone push delivery, offline behavior, and the next real-payment detection after the Xiaomi settings correction remain acceptance checks.


## Release 1.0.8

Migration 202610270005 is deployed: optional names, creator-only edits, revision conflict checks, and group-readable append-only history. Older client creation calls remain compatible. Existing rows have creation baselines.

The updater checks stable GitHub releases on app opening/resuming (daily cache), offers a verified download, and opens Android installation confirmation. Initial installation of 1.0.8 must be manual. No silent installation is claimed.

ARM64 APK: **8,054,164 bytes (8.054164 MB)**. Version code 2009; version name 1.0.8; same package and signing certificate as 1.0.7. SHA-256: `ec6374feb0c02df70fff2c2c8a1369bf54b9ab138c43d95b69fdf8f092a5e0ae`. Signature verified; strict 20 MB target passed. Download/installed sizes are separate and unmeasured.

Validation: 19 database checks, 34 Java tests and 12 Flutter tests; static analysis clean. Real-device update installation and two-phone edit acceptance are pending; no phone was attached during this change. See [update and edit instructions](updates-and-edits.md).
