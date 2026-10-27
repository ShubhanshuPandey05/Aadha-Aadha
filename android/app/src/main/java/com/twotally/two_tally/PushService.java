package com.twotally.two_tally;

import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;
import org.json.JSONObject;
import java.util.Iterator;
import java.util.Map;

public class PushService extends FirebaseMessagingService {
    @Override public void onNewToken(String token) {
        TallyApplication.IO.execute(() -> {
            try {
                JSONObject device = SecureStore.get("device");
                device.put("token", token); SecureStore.put("device", device); SyncWorker.enqueue(this);
            } catch (Exception ignored) { }
        });
    }
    @Override public void onMessageReceived(RemoteMessage message) {
        Map<String, String> data = message.getData();
        String expense = data.get("expense_id"), recipient = data.get("recipient_user_id");
        if (expense == null || recipient == null || !recipient.equals(Backend.userId()) || !Notifications.allowed(this)) return;
        synchronized (PushService.class) {
            try {
                JSONObject seen = SecureStore.get("push_seen");
                String key = recipient + ":" + expense;
                if (seen.has(key)) return;
                // Stable Android notification tag also replaces a delivery retried after a process crash.
                Notifications.status(this, expense, data.getOrDefault("title", "Shared expense"),
                    data.getOrDefault("body", "Your friend updated the ledger."), expense);
                long now = System.currentTimeMillis();
                java.util.ArrayList<String> expired = new java.util.ArrayList<>();
                for (Iterator<String> it = seen.keys(); it.hasNext();) {
                    String id = it.next();
                    if (now - seen.optLong(id) > 35 * ExpenseQueue.DAY) expired.add(id);
                }
                for (String id : expired) seen.remove(id);
                seen.put(key, now); SecureStore.put("push_seen", seen);
            } catch (Exception ignored) { }
        }
    }
}
