package com.twotally.two_tally;

import android.app.Notification;
import android.content.ComponentName;
import android.os.Bundle;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;
import org.json.JSONObject;

public class UpiNotificationListener extends NotificationListenerService {
    private static volatile boolean connected;
    private static long lastReconnect;
    static boolean isConnected() { return connected; }
    static void reconnect(android.content.Context context) { reconnect(context, false); }
    static synchronized void reconnect(android.content.Context context, boolean immediate) {
        if (connected || !SecureStore.get("settings").optBoolean("detection")) return;
        long now = android.os.SystemClock.elapsedRealtime();
        if (!immediate && lastReconnect != 0 && now - lastReconnect < 10000) return;
        ComponentName component = new ComponentName(context, UpiNotificationListener.class);
        String allowed = android.provider.Settings.Secure.getString(context.getContentResolver(), "enabled_notification_listeners");
        boolean granted = false;
        if (allowed != null) for (String value : allowed.split(":"))
            if (component.equals(ComponentName.unflattenFromString(value))) granted = true;
        if (!granted) return;
        lastReconnect = now;
        try { requestRebind(component); } catch (RuntimeException ignored) { }
    }
    @Override public void onNotificationPosted(StatusBarNotification sbn) {
        if (!PaymentParser.PACKAGES.contains(sbn.getPackageName())) return;
        try {
            if (!SecureStore.get("settings").optBoolean("detection") || Backend.userId().isEmpty()) return;
        } catch (Exception ignored) { return; }
        Notification notification = sbn.getNotification();
        if ((notification.flags & Notification.FLAG_GROUP_SUMMARY) != 0) { note("Grouped notification skipped."); return; }
        // Capture only fields from allowlisted packages. Never persist the raw notification.
        Bundle extras = notification.extras;
        if (extras == null) { note("App notification had no readable text."); return; }
        String title = String.valueOf(extras.getCharSequence(Notification.EXTRA_TITLE, ""));
        CharSequence big = extras.getCharSequence(Notification.EXTRA_BIG_TEXT);
        String body = big == null ? String.valueOf(extras.getCharSequence(Notification.EXTRA_TEXT, "")) : big.toString();
        long timestamp = notification.when > 0 && notification.when <= sbn.getPostTime() + 300000
            ? notification.when : sbn.getPostTime();
        PaymentParser.Payment payment = PaymentParser.parse(sbn.getPackageName(), sbn.getKey(), title + "\n" + body, timestamp);
        if (payment == null) { note("App notification did not match a supported outgoing payment."); return; }
        TallyApplication.STORAGE.execute(() -> {
            try {
                JSONObject settings = SecureStore.get("settings"), group = SecureStore.get("group");
                String owner = Backend.userId();
                if (!settings.optBoolean("detection") || owner.isEmpty()) return;
                if (group.optString("id").isEmpty() || !group.optBoolean("ready")) {
                    saveNote("Payment detected; connect your friend in the ledger first."); return;
                }
                if (!Notifications.promptsAllowed(this)) {
                    saveNote("Payment detected; shared-payment alerts are disabled."); return;
                }
                JSONObject item = ExpenseQueue.offer(payment, sbn.getPackageName(), owner, group.getString("id"));
                if (item != null) {
                    Notifications.prompt(this, item);
                    saveNote("Payment prompt posted. Check notifications or On this device below.");
                } else saveNote("Repeated notification skipped, or the local queue is full.");
            } catch (Exception ignored) {
                // No sensitive logs. A failed durable write never produces a loggable prompt.
                saveNote("Could not save or show the payment prompt. Reopen the app and check storage.");
            }
        });
    }
    // Last outcome only, on this device. No notification text, names, accounts or amounts.
    private void note(String message) { TallyApplication.STORAGE.execute(() -> saveNote(message)); }
    private void saveNote(String message) {
        try { SecureStore.put("detection_check", new JSONObject().put("message", message)
            .put("time", System.currentTimeMillis())); } catch (Exception ignored) { }
    }
    @Override public void onListenerConnected() { connected = true; SyncWorker.enqueue(this); }
    @Override public void onListenerDisconnected() {
        connected = false;
        reconnect(this);
    }
    @Override public void onDestroy() { connected = false; super.onDestroy(); }
}
