# Detection, security, and reliability

## Small integration surface

The Flutter app has one runtime Dart dependency: Supabase's realtime_client. Auth and REST calls live in Java behind two_tally/native. One native session owner serializes refresh-token rotation, channel requests, and background uploads. Flutter receives an access token for Realtime only, not the refresh token.

Android dependencies are WorkManager and Firebase Messaging, plus their transitive dependencies. There are no analytics, image, animation, accessibility, or SMS libraries.

## Payment flow

1. NotificationListenerService receives a system-posted notification.
2. It checks the source package before reading text. Group summaries are ignored.
3. PaymentParser recognizes conservative outgoing success wording, excludes incoming/failure/pending/refund/request wording, and parses only explicit INR/rupee amounts.
4. A suggestion, owned by the signed-in user and active group, is persisted locally before its prompt is shown.
5. Only an explicit confirmation changes suggested to queued. Dismissal produces no expense; ignored suggestions expire after 24 hours.
6. An immutable PendingIntent targets a non-exported receiver. The receiver stores consent on a separate short-work executor and enqueues WorkManager. It does not launch an Activity or Flutter engine.
7. The worker submits log_expense with the same request ID on every retry.
8. A committed expense creates push delivery rows. A post-commit pg_net request wakes the Edge Function. The one-minute cron job recovers missed wake-ups.
9. The other device renders the data-only FCM message and deduplicates by expense UUID. A notification tap opens details through an explicit MainActivity intent and an RLS-protected RPC.
10. Realtime updates the open ledger and triggers a fresh authoritative snapshot after reconnecting.

A notification timestamp is not independently verified bank transaction time. The source's notification time is used when plausible, otherwise the Android posting time. Raw title/body text is not persisted or uploaded.

## Parser scope

Allowlisted packages:

| App | Package |
| --- | --- |
| Google Pay India | com.google.android.apps.nbu.paisa.user |
| PhonePe | com.phonepe.app |
| Paytm | net.one97.paytm |
| Kotak 811 | com.kotak811mobilebankingapp.instantsavingsupiscanandpayrecharge |
| BHIM (NPCI) | in.org.npci.upiapp |

Kotak 811 additionally recognizes debit alerts explicitly mentioning UPI. Both added apps recognize successful transfer wording with an outgoing recipient. Generic bank debits without UPI are not accepted by the bank-debit rule. OTPs, mandates, future debits and negated transactions are rejected. Multiple amounts (for example a debit plus available balance) require amount entry. UPI Ref No and RRN references participate in cross-app deduplication. The separate Kotak Bank and legacy Kotak apps are not included.

Package identities were verified against the official [Kotak 811 listing](https://play.google.com/store/apps/details?id=com.kotak811mobilebankingapp.instantsavingsupiscanandpayrecharge) and [BHIM listing](https://play.google.com/store/apps/details?id=in.org.npci.upiapp). Notification formats are synthetic fixtures pending real-device verification.

Synthetic unit-test examples include “You paid ₹350.25 to Riya successfully. UPI Ref: 123456789012”, “Sent Rs. 1,200 to Shop”, and “Payment successful” followed by “₹350 to Riya”. These are parser fixtures, **not captured proof of any current app's notification format**.

The listener cannot inspect in-app-only receipts, hidden/redacted fields, work-profile restrictions, disabled notifications, or past notifications before access was granted. Unsupported/localized templates are ignored. A generic “Payment successful” with no outgoing evidence is ignored. Multiple different currency amounts or malformed decimal/grouping formats require manual entry.

Duplicate handling uses a transaction-reference fingerprint where present, otherwise source/notification identity, timestamp and normalized-text hashes. A stable source event key suppresses notification updates that add a reference later. Repeated notifications with a new timestamp are not suppressed merely because their text matches. Reused event metadata only suppresses matching amount/recipient values without conflicting transaction references. If an app reuses identical text, ID and timestamp without a reference, separate payments cannot reliably be distinguished; substantially changed reposts can also evade detection. Manual entry remains the fallback. Universal deduplication cannot be guaranteed without a stable transaction reference.

## Ledger rules

- One permanent group per user, at most two members through validated RPCs.
- Invitations use random UUID entropy, are stored as SHA-256 hashes, expire after 48 hours, and are single-use. Rotation invalidates the previous code.
- Group row locks serialize joins and writes. Mobile users have no direct INSERT/UPDATE/DELETE privileges.
- Payer is always auth.uid(); clients cannot select another payer.
- Amounts are positive integer paise, capped at 1,000,000,000 paise. Shares must be within the amount. No floating-point arithmetic is used to parse input or settle balances.
- Equal split assigns any odd paise to the payer. Custom split records the payer's share explicitly; the other member gets the remainder.
- Repayments record money already sent by the logged-in payer. They do not increase spending totals.
- Positive balance means the other friend owes this person. Balance = expense contributions − expense shares + outgoing repayments − incoming repayments.
- Current-month totals use Asia/Kolkata month boundaries. Balances and contribution/share totals cover the complete ledger.
- The activity feed shows the latest 100 rows; push-linked older expenses can still be fetched by ID. Creator-only edits require a connection and append shared history. No cached offline ledger or delete UI is included. See [updates and edits](updates-and-edits.md).

## Data protection

Sessions and the local queue use AES-GCM with a key held in Android Keystore. Each record name is authenticated as associated data. Backup and device-transfer rules exclude private app storage. Keystore/storage failures fail closed; there is no plaintext fallback.

Confirmed unsynced expenses remain on the device until saved. Failed writes stay visible for retry. Unconfirmed suggestions expire after one day; local completed/dismissed deduplication records are removed after 30 days. FCM seen IDs are retained for 35 days, exceeding the 28-day message TTL. Raw notification text is never retained.

Group-member SELECT policies protect profiles, groups, memberships, and expenses. Invitations, device tokens, and push queues have no mobile read policies. SECURITY DEFINER functions use an empty search_path and explicit auth checks. Only service_role can claim/complete push deliveries.

Sign-out unregisters the installation online before clearing the session. It is refused while confirmed writes remain queued. Failed writes are retained and remain owned by the original user. Reauthentication must use the same account; switching requires sign-out. Old push messages include a recipient user ID and are discarded if a different account is active.

## Reliability limits

WorkManager persists confirmed uploads and applies network constraints/backoff. Android 12+ uses expedited work when quota permits, falling back to ordinary work. Periodic recovery also runs every 15 minutes at best; Android controls actual scheduling. Force-stop, Doze, battery restrictions, revoked access, reboots before unlock, or invalid sessions can delay work. An expired session keeps confirmed expenses locally and asks the user to sign in. [Android WorkManager](https://developer.android.com/develop/background-work/background-tasks/persistent/getting-started)

Database delivery rows are unique per expense/device. The dispatcher claims rows with a five-minute lease and retries transient errors with capped exponential backoff. UNREGISTERED FCM tokens are marked dead. A crash between FCM acceptance and recording success may resend; persistent device deduplication and a stable notification tag prevent ordinary duplicate display. This is not a claim of mathematically exact-once delivery across distributed systems.

FCM messages are non-collapsible, high priority, data-only, with a 28-day TTL. Registered offline devices can receive messages when they reconnect within FCM's limits. High priority is a delivery request, not a timing guarantee; delivery can be delayed, expired, deprioritized or dropped. If notification permission is disabled, the ledger remains authoritative. [FCM priority](https://firebase.google.com/docs/cloud-messaging/android-message-priority), [FCM message lifespan](https://firebase.google.com/docs/cloud-messaging/customize-messages/setting-message-lifespan)

No bank verification, payment initiation, OTP reading, banking login, or accessibility automation exists in this application.
