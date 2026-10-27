# Validation and real-device acceptance

See verification.md for results actually obtained in this workspace. The checklist below is an acceptance procedure, not a claim that physical-device testing has already happened.

## Local checks

~~~powershell
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

The PGlite tests run actual PostgreSQL tables, functions, constraints, grants and RLS with mock Auth users/JWT claims. They validate authorization, invitations, the maximum group size, idempotency, invalid inputs, shares, repayments, and push leases. They do not validate Supabase Auth HTTP behavior, concurrent remote transactions, hosted Realtime, Vault/pg_net/cron, or FCM.

The Flutter screen test renders a compact phone at 390 × 844 logical pixels and writes previews under artifacts/previews. Its names and expenses are synthetic test fixtures. Parser fixtures are synthetic English messages; no real financial notifications are included.

## Two real Android devices

Use two separate confirmed Supabase accounts in one group. Record manufacturer/model, Android version, payment-app version/language, build hash, battery mode and whether the device has Google Play services. Include an Android 13+ device and a device with aggressive background restrictions. Test Android 8.0 if retaining minSdk 26, and a 16 KB-page ARM64 device before claiming that compatibility.

| Scenario | Expected result |
| --- | --- |
| New install without consent | No payment detection or automatic logging |
| Detection enabled, listener denied | Manual ledger works; no prompts |
| Listener granted, POST_NOTIFICATIONS denied | No invisible automatic logging |
| App channel disabled | No loggable suggestion; re-enable channel to restore prompts |
| Outgoing success in each target payment app | Prompt only if readable outgoing system notification is actually posted |
| Same payment while payment app foreground/background | Record which versions emit system notifications in each state |
| Incoming, failure, pending, refund, collect request | No shared-expense prompt |
| Missing/hidden amount | Enter amount; no Yes action, no invented amount |
| Different amounts in notification | Manual amount review |
| Dismiss or ignore prompt for 24 hours | No database row |
| Tap Yes with Flutter app closed | Native queue submits; Flutter Activity does not start |
| Tap Yes repeatedly / repost the notification | One expense and one delivery per friend's device |
| Same reference with a new Android notification key | No second expense |
| Two real equal payments within two minutes without references | Document heuristic suppression; manually log missed payment |
| Tap Yes in airplane mode, restore network | One retained confirmation eventually saved |
| Reboot after confirming offline | Queued expense survives and syncs after unlock/network |
| Force-stop after confirmation | No delivery promise until app reopened; queue then recovers |
| Expire/revoke Auth refresh session | Confirmation retained; reauthentication and Retry work |
| Device full / secure storage unavailable | No success confirmation for an unpersisted expense |
| Friend app open | Realtime refreshes authoritative balance |
| Friend app closed/offline | FCM notification when delivery is possible; no notification to payer |
| FCM response lost, dispatch retried | Stable expense ID prevents ordinary duplicate notification display |
| Notification tap, app cold/warm | Correct expense details after sign-in and access validation |
| Reuse invite / race two users joining | Only one join succeeds; no group with three members |
| Outsider calls REST/RPC directly | No private ledger read or unauthorized write |
| Sign-out / different account on same phone | Old messages are discarded; queued ownership cannot transfer |
| Custom split / odd paise / repayment | Server and UI balances match expected math |

Do not use shell-posted notifications from com.android.shell as evidence of payment-app compatibility: that package is intentionally rejected. Real device tests must involve genuine notifications emitted by the supported app; choose the transactions yourself. The tracker must never initiate a payment as part of testing.

## Background diagnostics

~~~powershell
adb devices
adb shell getprop ro.product.cpu.abilist
adb shell getconf PAGE_SIZE
adb shell dumpsys jobscheduler com.twotally.two_tally
adb shell dumpsys package com.twotally.two_tally
~~~

For a controlled Doze test, enable device idle with adb shell dumpsys deviceidle force-idle, then restore normal behavior using adb shell dumpsys deviceidle unforce. Perform this only on a test device. Observe the application's queue screen and backend rows rather than assuming immediate scheduling.

Record times for notification posted → confirmation tapped → database commit → FCM accepted → alert displayed. Do not equate FCM acceptance with delivery. Check push_outbox last_error and the cron job before diagnosing a device failure.

For build inspection:

~~~powershell
apkanalyzer apk file-size build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
apkanalyzer apk download-size build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
apkanalyzer manifest permissions build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
apksigner verify --verbose build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
~~~

A final acceptance record should include both APK byte size and actual installed storage from Android Settings. They measure different things.

## Kotak 811 and BHIM (1.0.1)

Install the updated configured APK over the previous build. Verify notification access and detection are enabled. Using normal app activity, check a completed outgoing payment from each app, an incoming payment, and a dismissed shared-expense prompt. Confirm only the explicit Yes action logs an expense. If both apps report the same UPI reference, confirm only one expense is offered/logged. For a debit alert also containing an available balance, verify the amount-entry path instead of an inferred debit amount.

Recognition is based on synthetic English fixtures, not a verified vendor notification contract. If no prompt appears, record the app version and sanitized notification title/body (dummy names/account/reference values, original wording and amount format). Do not include OTPs or banking credentials. Kotak Bank (new/legacy) is separate from Kotak 811 and is not included in this change.

## Repeated Kotak payment regression (1.0.4)

The user reported a Kotak app notification for a second payment to the same recipient (INR 100 then INR 70, one or two minutes apart) without a Two Tally prompt. The supplied text matches the supported parser. Device event metadata was unavailable, so exact cause is unconfirmed. Fixed two known suppression paths: equal notification ID/time no longer overrides changed payment values or conflicting references, and equal text with a new timestamp is not suppressed for two minutes. Added sanitized Kotak fixtures and duplicate-policy tests. Identical text/ID/time without a reference remains inherently ambiguous.

Settings now shows the most recent checked notification outcome and local time, without retaining raw text, account numbers, recipient or amount. If a prompt is missing, check this status and the On this device section before making another payment. Existing missed notifications are not replayed automatically; manually enter an expense only after confirming it is absent from both the ledger and local queue.

## Listener disconnected despite permission (1.0.5)

ADB on the user's connected phone showed 1.0.4 installed, notification access and POST_NOTIFICATIONS granted, and the app process running, but no Two Tally live listener or bound service. ApplicationExitInfo recorded SwipeUpClean process kills. Thus opening the Flutter UI did not prove the listener had reconnected. This is direct evidence of a disconnected listener; the earlier duplicate-rule fixes did not establish the cause of these later misses.

The listener now tracks onListenerConnected/onListenerDisconnected/onDestroy in memory, requests rebind on app startup/resume and scheduled sync when already authorized, and exposes actual connection separately from permission. Settings shows connected/disconnected and offers Reconnect. No notification access permission is granted automatically, no active notifications are replayed and no payment is initiated. OEM restrictions and force-stops can still prevent reconnection. The widget test covers granted permission with disconnected listener, followed by an explicit reconnection.
