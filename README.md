# Aadha/Aadha

A small Android shared-expense tracker for two friends. Flutter handles the ledger UI; Java handles notification detection, encrypted sessions, confirmation actions, background uploads, and FCM. Supabase provides Auth, PostgreSQL, RLS, Realtime, and the push dispatcher.

**Latest evaluation release: 1.0.8, ARM64, 8.05 MB.** Supabase and the push backend are deployed. Google sign-in, group creation, and listener connectivity have been checked on a real device; full two-phone acceptance remains outstanding. See [deployment status](docs/deployment.md). Configured APKs include public client configuration and use the Android debug signing certificate.

- [Setup and deployment](docs/setup.md)
- [Detection, security, and reliability](docs/architecture.md)
- [Testing and real-device acceptance](docs/testing.md)
- [Measured APK sizes and verification](docs/verification.md)

## What is included

- Google sign-in and email/password Supabase Auth; two-person groups with expiring, single-use invitations.
- Java NotificationListenerService for allowlisted Google Pay, PhonePe, Paytm, Kotak 811, and BHIM packages.
- "Is this a shared expense with your friend?" with "Yes, Log Expense" for unambiguous amounts.
- Equal-split confirmation without launching Flutter; manual review when the amount is missing.
- Durable, encrypted local queue; WorkManager network constraints, retries, and reboot recovery.
- Integer-paise expenses, custom splits, repayments, current-month totals, all-time contributions and settlement.
- Member-only ledger access, server-derived payer, validated writes, and idempotency.
- Optional entry names, creator-only edits and shared before/after history.
- Automatic release checks and verified APK downloads with Android installation confirmation. See [updates and edits](docs/updates-and-edits.md).
- Database-triggered push outbox, secure Edge Function, FCM retry/deduplication, expense deep links.
- Supabase Realtime refresh and reconciliation after reconnecting.

## Build and check

The tested toolchain is Flutter 3.24.3 / Dart 3.5.3, Java 17 or 21, Gradle 8.7, AGP 8.6.1, Android SDK 35, and NDK 27.1.12297006. Android 8.0+; ARM32 and ARM64 release APKs.

~~~powershell
flutter pub get
flutter analyze
flutter test
Push-Location android
.\gradlew.bat testReleaseUnitTest lintRelease
Pop-Location
npm ci --prefix tool
node tool/test_database.mjs
npx --yes deno test --allow-env supabase/functions/dispatch-push/handler_test.ts
npx --yes deno check supabase/functions/dispatch-push/index.ts
powershell -ExecutionPolicy Bypass -File tool/build_release.ps1
~~~

The build script measures both APK files and fails if either is **20,000,000 bytes or larger**. The report is written to artifacts/apk-sizes.json. Use ABI-specific builds, as recommended by [Flutter's Android deployment guide](https://docs.flutter.dev/deployment/android).

## Detection feasibility

Android exposes posted system notifications with explicit notification-listener access. This does not give access to a payment app's internal transaction state. [Android NotificationListenerService](https://developer.android.com/reference/android/service/notification/NotificationListenerService)

Google Pay documents an **in-app** notification after each transaction. That does not establish that every outgoing payment produces a readable Android system notification. The parser therefore offers best-effort detection of conservative English templates; it does not promise full coverage of any payment app or language. Manual entry remains available. PhonePe/Paytm notification formats and outgoing coverage still need validation on the actual app versions used by the two friends. [Google Pay notification help](https://support.google.com/pay/india/answer/15299524?hl=en-GB)

The application never requests SMS/OTP access, banking credentials, or accessibility permissions, and never initiates a UPI payment.
