package com.twotally.two_tally;
import android.app.Application;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class TallyApplication extends Application {
    static final ExecutorService IO = Executors.newSingleThreadExecutor();
    static final ExecutorService STORAGE = Executors.newSingleThreadExecutor();
    @Override public void onCreate() {
        super.onCreate();
        SecureStore.init(this);
        Notifications.channels(this);
        UpiNotificationListener.reconnect(this);
        SyncWorker.installRecovery(this);
    }
}
