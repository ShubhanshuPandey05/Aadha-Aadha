package com.twotally.two_tally;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import org.json.JSONObject;
import java.util.Locale;

final class Notifications {
    static final String PROMPTS = "shared_prompts", UPDATES = "ledger_updates";
    static void channels(Context c) {
        NotificationManager nm = c.getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel(PROMPTS, "Confirm shared payments", NotificationManager.IMPORTANCE_HIGH));
        nm.createNotificationChannel(new NotificationChannel(UPDATES, "Ledger updates", NotificationManager.IMPORTANCE_DEFAULT));
    }
    static boolean allowed(Context c) { return c.getSystemService(NotificationManager.class).areNotificationsEnabled(); }
    static boolean promptsAllowed(Context c) {
        return allowed(c) && c.getSystemService(NotificationManager.class).getNotificationChannel(PROMPTS).getImportance() != NotificationManager.IMPORTANCE_NONE;
    }
    static PendingIntent open(Context c, String kind, String id) {
        Intent intent = new Intent(c, MainActivity.class)
            .setData(Uri.parse("twotally://" + kind + "/" + id))
            .putExtra("kind", kind).putExtra("id", id)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        return PendingIntent.getActivity(c, 0, intent, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }
    private static PendingIntent action(Context c, String action, String id) {
        Intent intent = new Intent(c, ExpenseActionReceiver.class).setAction(action)
            .setData(Uri.parse("twotally://action/" + id)).putExtra("id", id);
        return PendingIntent.getBroadcast(c, 0, intent, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }
    static String money(long paise) { return String.format(Locale.ENGLISH, "₹%,d.%02d", paise / 100, paise % 100); }
    static void prompt(Context c, JSONObject item) {
        if (!promptsAllowed(c)) return;
        String id = item.optString("id");
        boolean amountKnown = !item.isNull("amount");
        String title = "Is this a shared expense with your friend?";
        String detail = amountKnown ? money(item.optLong("amount")) + " · Split equally" : "Amount unavailable. Enter it before logging.";
        if (!item.isNull("recipient")) detail += " · " + item.optString("recipient");
        Notification.Builder builder = new Notification.Builder(c, PROMPTS)
            .setSmallIcon(com.twotally.two_tally.R.drawable.ic_notification)
            .setContentTitle(title).setContentText(detail)
            .setStyle(new Notification.BigTextStyle().bigText(title + "\n" + detail))
            .setContentIntent(open(c, "candidate", id))
            .setDeleteIntent(action(c, "dismiss", id))
            .setVisibility(Notification.VISIBILITY_PRIVATE).setTimeoutAfter(ExpenseQueue.DAY)
            .setAutoCancel(true).setOnlyAlertOnce(true);
        if (amountKnown) builder.addAction(new Notification.Action.Builder(null, "Yes, Log Expense", action(c, "confirm", id)).build());
        else builder.addAction(new Notification.Action.Builder(null, "Enter amount", open(c, "candidate", id)).build());
        c.getSystemService(NotificationManager.class).notify("candidate:" + id, 1, builder.build());
    }
    static void cancelPrompt(Context c, String id) { c.getSystemService(NotificationManager.class).cancel("candidate:" + id, 1); }
    static void status(Context c, String id, String title, String detail, String expenseId) {
        if (!allowed(c)) return;
        Notification notification = new Notification.Builder(c, UPDATES)
            .setSmallIcon(R.drawable.ic_notification).setContentTitle(title).setContentText(detail)
            .setStyle(new Notification.BigTextStyle().bigText(detail)).setAutoCancel(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE).setOnlyAlertOnce(true)
            .setContentIntent(open(c, expenseId == null ? "queue" : "expense", expenseId == null ? id : expenseId)).build();
        c.getSystemService(NotificationManager.class).notify("status:" + id, 2, notification);
    }
}
