# Deployment status

The configured evaluation build uses a deployed Supabase backend and Firebase Cloud Messaging. To deploy your own instance, follow [setup](setup.md) and [Google sign-in setup](google-sign-in.md). Local app configuration, credentials, signing keys, and deployment backups are excluded from Git.

## Verified

- All four SQL migrations applied; RLS and Realtime configured.
- Push dispatcher deployed with server-only credentials, post-commit wakeup and retry cron.
- FCM validation returned HTTP 200; unauthorized dispatcher requests returned 401. Validation does not prove phone delivery.
- Google sign-in and group creation succeeded on a real Android device.
- A real Kotak notification was detected. The Kotak/BHIM server source allowlist was corrected afterward.
- On Xiaomi, Background autostart and notification access were required. A live listener was verified after swipe-away/reopen with those settings enabled.

## Release 1.0.7

Aadha/Aadha branding and typographic logo; Android package remains `com.twotally.two_tally` to preserve updates and account configuration.

ARM64 release APK: **8,033,088 bytes (8.03 MB)**, below the 20,000,000-byte target. Signature and packaged version/label verified. This evaluation build uses the Android debug signing certificate. Installed size and network download size have not been measured. The latest build was not automatically installed on a phone.

Static analysis and all eight Flutter tests passed for the branding update. Earlier parser/deduplication coverage passed 33 Java tests; database coverage passed 15 integration checks. Complete two-phone push delivery, offline behavior, and the next real-payment detection after the Xiaomi settings correction remain acceptance checks.
