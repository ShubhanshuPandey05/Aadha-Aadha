# Updates, names and entry history

## App updates

Version 1.0.8 introduces the updater. Install this version manually once over the existing app; do not uninstall or clear its data. Later releases are checked automatically on opening/resuming the app, with successful checks cached for one day. Settings also provides Check for updates and Install update. Checks do not block the ledger.

The app offers a download, then verifies the exact byte count, SHA-256 digest, Android package, signing certificate, version name and increasing version code before opening Android's installer. Downloads use a separate executor, HTTPS, restricted GitHub hosts, bounded file size and timeouts. Incomplete downloads are discarded. A verified cached APK can be reused after granting installation permission. No login credentials are sent to GitHub.

Android requires permission to install from Aadha/Aadha and user confirmation. Installation is not silent. On the permission screen, allow the source, return to the app and tap Install update again. Slow GitHub downloads can still require a different network or USB installation. Update checks run when the app is opened, not while it is force-stopped.

Release publishing convention:

- Publish a stable, non-draft GitHub release in `ShubhanshuPandey05/Aadha-Aadha`, tagged `vMAJOR.MINOR.PATCH`.
- Use increasing Flutter build numbers and the same signing key and Android application ID.
- Attach `aadha-aadha-MAJOR.MINOR.PATCH-arm64-v8a.apk` (or `armeabi-v7a` for a 32-bit release). Each asset must be under 20,000,000 bytes and have GitHub's SHA-256 digest.
- Publish all assets before making the release visible. The updater skips prereleases and incompatible/missing assets.
- This is a GitHub APK distribution path. A future Play Store build should use Play's update mechanism and omit the self-install permission.

References: [GitHub release metadata](https://docs.github.com/en/rest/releases/releases), [Android installation permissions](https://android-developers.googleblog.com/2017/08/making-it-safer-to-get-apps-on-android-o.html).

## Editing ledger entries

Names are optional, up to 100 characters, and available for both expenses and repayments. Notification confirmations leave the name blank. Open the saved entry and choose Edit your entry to add a name such as Food later.

Only the original payer/creator may edit the amount, payer share, recipient or name. The server derives identity from Auth; group membership and ownership are checked inside the edit RPC. The payer, group, payment date, source, transaction reference and entry kind cannot be changed. Repayment shares remain zero. Clearing a name restores the default display label.

Each edit updates the row and appends its before/after values, actor, revision and server timestamp in one transaction. Both friends can read Entry history; neither client can write or delete history directly. Existing rows are backfilled as creation baselines. The full ledger totals and settlements use the current values, and the open friend's ledger receives Realtime updates. Edit history does not initiate another new-expense FCM push.

Edits require a network connection. A revision check rejects stale edits, and request IDs deduplicate retries after a lost response. Replaying the original creation request after editing returns the original entry ID without overwriting edits or creating a duplicate. On a stale-edit error, reopen the entry to load the latest values.

## Device acceptance

1. Install 1.0.8 over 1.0.7 and confirm account/ledger data survives.
2. Name and edit your own entry. On the friend's phone, confirm the changed totals and readable history; the Edit control must be absent for your entry.
3. Turn off the network before editing; confirm an error appears and no success is claimed. Reconnect and retry.
4. On the next higher release, check the update prompt, Later, download, source-permission denial/grant, and Android installation confirmation. Cancel installation and retry; existing data must remain.
5. Verify behavior on slow/offline networks. Update failures must not interrupt notification detection or queued expense syncing.

Automated coverage verifies server ownership/RLS, immutable history access, input validation, stale revision rejection, request idempotency, settlement recalculation, UI edit visibility, and the update prompt's Later action. End-to-end installation of a future release requires a real device.
