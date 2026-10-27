package com.twotally.two_tally;

import android.content.Context;
import androidx.annotation.NonNull;
import androidx.work.*;
import org.json.JSONArray;
import org.json.JSONObject;
import java.util.UUID;
import java.util.concurrent.TimeUnit;

public class SyncWorker extends Worker {
    public SyncWorker(@NonNull Context context, @NonNull WorkerParameters params) { super(context, params); }
    private static Constraints network() { return new Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build(); }
    static void enqueue(Context context) {
        // APPEND_OR_REPLACE closes the race where a running drain just passed the newly queued row.
        OneTimeWorkRequest.Builder request = new OneTimeWorkRequest.Builder(SyncWorker.class)
            .setConstraints(network()).setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS);
        if (android.os.Build.VERSION.SDK_INT >= 31)
            request.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST);
        WorkManager.getInstance(context).enqueueUniqueWork("expense-sync", ExistingWorkPolicy.APPEND_OR_REPLACE,
            request.build());
    }
    static void installRecovery(Context context) {
        WorkManager.getInstance(context).enqueueUniquePeriodicWork("expense-recovery", ExistingPeriodicWorkPolicy.KEEP,
            new PeriodicWorkRequest.Builder(SyncWorker.class, 15, TimeUnit.MINUTES)
                .setConstraints(network()).build());
    }
    @NonNull @Override public Result doWork() {
        new android.os.Handler(android.os.Looper.getMainLooper()).post(
            () -> UpiNotificationListener.reconnect(getApplicationContext()));
        // Serialize account changes and all writes, including token rotation, with the channel.
        synchronized (Backend.class) {
            String user = Backend.userId();
            if (user.isEmpty()) return Result.success();
            try {
                registerDevice();
                JSONArray pending = ExpenseQueue.list(user, true);
                boolean retry = false;
                for (int i = 0; i < pending.length(); i++) {
                    if (isStopped()) return Result.retry();
                    JSONObject item = pending.getJSONObject(i);
                    String id = item.getString("id");
                    try {
                        JSONObject result = Backend.rpc("log_expense", item.getJSONObject("payload"));
                        ExpenseQueue.state(id, "saved", result.getString("id"));
                        Notifications.status(getApplicationContext(), id, "Shared expense saved",
                            Notifications.money(item.getLong("amount")) + " added to your ledger.", result.getString("id"));
                    } catch (Backend.ApiException e) {
                        if (e.retryable()) retry = true;
                        else {
                            ExpenseQueue.state(id, "failed", e.getMessage());
                            Notifications.status(getApplicationContext(), id, "Expense needs attention", e.getMessage(), null);
                        }
                    } catch (java.io.IOException e) { retry = true; }
                }
                return retry ? Result.retry() : Result.success();
            } catch (Backend.ApiException e) {
                // Device registration should never discard a confirmed write.
                if (e.status == 401) {
                    Notifications.status(getApplicationContext(), "session", "Sign in to sync", "Your confirmed expenses remain on this device.", null);
                    return Result.success();
                }
                return Result.retry();
            } catch (Exception e) { return Result.retry(); }
        }
    }
    private void registerDevice() throws Exception {
        JSONObject device = SecureStore.get("device");
        if (device.optString("id").isEmpty()) {
            device.put("id", UUID.randomUUID().toString()); SecureStore.put("device", device);
        }
        if (!device.optString("token").isEmpty()) {
            try {
                Backend.rpc("register_device", new JSONObject().put("p_device_id", device.getString("id"))
                    .put("p_token", device.getString("token")));
            } catch (Backend.ApiException e) {
                if (e.status == 401) throw e;
                // Expense writes have priority; the periodic recovery also retries registration.
            } catch (java.io.IOException ignored) { }
        }
    }
}
