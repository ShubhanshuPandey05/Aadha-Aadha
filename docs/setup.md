# Setup and deployment

## 1. Supabase

Use a dedicated Supabase project. Install the Supabase CLI if you want to deploy from the terminal, or execute the SQL files in order through the project's SQL editor.

~~~powershell
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase db push
~~~

Migrations:

1. supabase/migrations/202610270001_ledger.sql — schema, Auth profile trigger, RLS, validated RPCs, realtime publication, push outbox and delivery leases.
2. supabase/migrations/202610270002_push_dispatch.sql — pg_net, pg_cron, Vault, after-insert wake-up, and a one-minute retry schedule.

The second migration requires Supabase's extensions. The local database test runs the first migration in PostgreSQL through PGlite; it does not simulate the cloud extension runtime.

Enable email/password Auth. Set the minimum password length to at least 8. Keep email confirmation enabled, configure a working SMTP sender and a valid Auth Site URL. Users confirm their account in their email browser, then return to Two Tally and sign in. No app deep link is required for email confirmation. Password reset/account administration can be managed through Supabase; a dedicated recovery screen is outside this minimal app.

Copy android/app-config.example.properties to android/app-config.properties and supply:

~~~properties
SUPABASE_URL=https://YOUR_PROJECT.supabase.co
SUPABASE_KEY=YOUR_PUBLISHABLE_OR_ANON_KEY
~~~

Use the base HTTPS project URL with no trailing slash. The app key is public and intentionally extractable from the APK; security depends on Auth, RPC validation and RLS. Never put a service-role/secret key here.

## 2. Firebase Android configuration

Create a Firebase project and register Android package **com.twotally.two_tally**. Download google-services.json to **android/app/google-services.json**. If you change the application ID, register the matching package in Firebase and update the Java namespace/manifest consistently.

Only firebase-messaging is used; no Analytics SDK or Flutter Firebase plugin is included. The Google Services Gradle plugin is applied only when the configuration file exists, so a configuration-free evaluation APK can still build. Native FCM initialization and registration begin after sign-in. FCM requires a compatible device with Google Play services.

Enable the Firebase Cloud Messaging HTTP v1 API. Create a service account permitted to send FCM messages in that Firebase project (Firebase Cloud Messaging API Admin role). Its JSON credentials belong in **Supabase Edge Function secrets only**. The dispatcher obtains short-lived OAuth access tokens on the server. [FCM HTTP v1 authorization](https://firebase.google.com/docs/cloud-messaging/send/v1-api)

## 3. Edge Function secrets and trigger

Configure these Edge Function environment variables:

| Name | Where it belongs | Meaning |
| --- | --- | --- |
| SUPABASE_URL | Supabase-provided server environment | Project URL |
| SUPABASE_SERVICE_ROLE_KEY | Supabase-provided server environment | Server-only database access |
| FCM_SERVICE_ACCOUNT_JSON | Edge Function secret | Entire service-account JSON, compacted to one line |
| PUSH_DISPATCH_SECRET | Edge Function secret and Supabase Vault | Random 32-byte or stronger secret |

SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are normally available automatically in hosted Edge Functions. Do not copy them into mobile configuration. Store the remaining values in an ignored local environment file, following supabase/.env.example. Compact the private-key JSON without altering its escaped newline characters. Do not commit that file or print credentials into build logs.

~~~powershell
supabase secrets set --env-file .env.local
supabase functions deploy dispatch-push
~~~

The committed config.toml sets verify_jwt=false for this function because the database calls it using a separate shared secret, not a user JWT. The handler checks x-dispatch-secret before reading FCM credentials or claiming deliveries. Do not remove this check or expose this secret in the app.

In the Supabase SQL editor, provision the matching values once, outside versioned migrations:

~~~sql
select vault.create_secret(
  'https://YOUR_PROJECT.supabase.co/functions/v1/dispatch-push',
  'push_function_url'
);
select vault.create_secret(
  'THE_SAME_RANDOM_VALUE_AS_PUSH_DISPATCH_SECRET',
  'push_dispatch_secret'
);
~~~

Use vault.update_secret for subsequent rotations rather than creating duplicate secret names. Update both the function secret and Vault together.

The database creates delivery rows in the same transaction as the expense. pg_net dispatches the HTTP request only after commit; a failed wake-up leaves the outbox available for the scheduled retry. [Supabase pg_net](https://supabase.com/docs/guides/database/extensions/pg_net)

Check deployment with a manual expense from one real account to a group containing a second signed-in device. Inspect push_outbox state/last_error using an administrator connection. “sent” means FCM accepted the message, not proof the device displayed it.

~~~sql
select state, count(*) from public.push_outbox group by state;
select id, attempts, next_attempt_at, last_error
from public.push_outbox where state='pending' order by next_attempt_at;
select jobname, schedule, active from cron.job where jobname='two-tally-push-retry';
~~~

The expense payer is excluded from push recipients. Register the friend's device before the expense is created; there is no retroactive notification for expenses created before a device registered. Offline registered devices remain eligible for FCM delivery.

## 4. Build, sign, measure, install

Run flutter doctor and install any missing SDK components/licences locally. The current source targets API 35; do not claim latest Play publishing compliance without updating/testing the target/toolchain as appropriate.

For personal evaluation, the release build falls back to the existing Android debug certificate. For distribution, generate your own private keystore and copy android/key.example.properties to android/key.properties. Keep the keystore and passwords outside version control and retain backups.

~~~powershell
keytool -genkeypair -v -keystore android/release-keystore.jks -alias two-tally -keyalg RSA -keysize 2048 -validity 10000
powershell -ExecutionPolicy Bypass -File tool/build_release.ps1
adb shell getprop ro.product.cpu.abilist
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
~~~

Choose app-armeabi-v7a-release.apk for ARM32. The script builds release mode, obfuscates Dart, retains symbol files outside the APK, shrinks Java/resources, and measures file sizes. Preserve build/symbols and build/app/outputs/mapping/release/mapping.txt for diagnosing your exact build.

An optional Play upload artifact can be produced with:

~~~powershell
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols
~~~

An AAB is not directly installable. Its size does not establish the size of a delivered APK. The included size gate specifically measures installable ABI APK files. [Flutter size measurement](https://docs.flutter.dev/perf/app-size)

## 5. First run on both phones

1. Sign up, confirm email, and sign in.
2. Friend A creates a group and privately shares the invitation code. Friend B joins. Both wait until the ledger shows two people.
3. In Settings, enable payment detection after reading the consent dialog.
4. Open Notification access and explicitly allow Two Tally.
5. Allow Two Tally to show notifications. Android 13+ has a separate runtime permission. Both permissions and the confirmation channel must be enabled. [Android notification permission](https://developer.android.com/develop/ui/compose/notifications/notification-permission)
6. If Android blocks notification access for a sideloaded build, use Android's app-info restricted-settings controls only after you trust your own build. The exact flow varies by Android version and installer.
7. Ensure payment-app notifications are enabled. Review manufacturer battery/autostart settings only if prompts or sync are delayed.
8. Validate the checklist in testing.md before relying on automatic detection.

Tapping Yes uses an equal split, with an odd paise assigned to the payer. Tap the notification body to review a custom split. A missing/ambiguous amount produces Enter amount, never an invented value or a background write.
