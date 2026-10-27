package com.twotally.two_tally;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public class ExpenseActionReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        String id = intent.getStringExtra("id");
        if (id == null) return;
        PendingResult pending = goAsync();
        TallyApplication.STORAGE.execute(() -> {
            try {
                String owner = Backend.userId();
                if ("confirm".equals(intent.getAction()) && ExpenseQueue.confirm(id, owner)) {
                    // Consent is durably recorded before the notification disappears or work is scheduled.
                    SyncWorker.enqueue(context);
                    Notifications.status(context, id, "Expense queued", "Will sync when a connection is available.", null);
                } else if ("dismiss".equals(intent.getAction())) ExpenseQueue.dismiss(id, owner);
                Notifications.cancelPrompt(context, id);
            } catch (Exception e) {
                Notifications.status(context, id, "Could not queue expense", "Open Aadha/Aadha to review this payment.", null);
            } finally { pending.finish(); }
        });
    }
}
