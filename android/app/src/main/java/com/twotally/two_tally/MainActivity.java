package com.twotally.two_tally;

import android.Manifest;
import android.app.NotificationManager;
import android.content.ComponentName;
import android.content.Intent;
import android.os.Build;
import android.provider.Settings;
import androidx.annotation.NonNull;
import com.google.firebase.FirebaseApp;
import com.google.firebase.messaging.FirebaseMessaging;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import org.json.JSONArray;
import org.json.JSONObject;
import java.util.Map;

public class MainActivity extends FlutterActivity {
    private MethodChannel channel;
    private JSONObject route;
    private final android.os.Handler listenerRecovery = new android.os.Handler(android.os.Looper.getMainLooper());
    private int listenerRetries;
    private final Runnable reconnectWhileVisible = new Runnable() {
        @Override public void run() {
            if (UpiNotificationListener.isConnected() || listenerRetries-- <= 0) return;
            UpiNotificationListener.reconnect(MainActivity.this);
            listenerRecovery.postDelayed(this, 12000);
        }
    };
    @Override protected void onResume() {
        super.onResume();
        listenerRecovery.removeCallbacks(reconnectWhileVisible);
        UpiNotificationListener.reconnect(this, true);
        listenerRetries = 5;
        listenerRecovery.postDelayed(reconnectWhileVisible, 12000);
    }
    @Override protected void onPause() {
        listenerRecovery.removeCallbacks(reconnectWhileVisible);
        super.onPause();
    }
    @Override public void configureFlutterEngine(@NonNull FlutterEngine engine) {
        super.configureFlutterEngine(engine);
        channel = new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "two_tally/native");
        captureRoute(getIntent());
        channel.setMethodCallHandler(this::handle);
    }
    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent); setIntent(intent); captureRoute(intent);
        if (channel != null) channel.invokeMethod("route", null);
    }
    private void captureRoute(Intent intent) {
        android.net.Uri uri = intent.getData();
        if (uri != null && "com.twotally.app".equals(uri.getScheme()) && "auth".equals(uri.getHost())
            && uri.getPort() == -1 && uri.getUserInfo() == null) {
            // Consume once. Never send browser tokens, authorization codes or callback URLs to Flutter/logs.
            intent.setData(null);
            if ("/confirmed".equals(uri.getPath())) {
                authResult("Email confirmation link received. Sign in below to continue.");
            } else if ("/login-callback".equals(uri.getPath())) {
                final String code = uri.getQueryParameter("code");
                final boolean failed = uri.getQueryParameter("error") != null || uri.getFragment() != null;
                TallyApplication.IO.execute(() -> {
                    String message;
                    try {
                        if (failed) throw new IllegalStateException("Google sign-in was cancelled or declined. Please try again.");
                        Backend.finishGoogle(code);
                        startPush(); SyncWorker.enqueue(this);
                        message = "Signed in with Google.";
                    } catch (Exception e) {
                        message = e instanceof Backend.ApiException && ((Backend.ApiException)e).status == 400
                            ? "Could not finish Google sign-in. Retry, using the same account if you are already signed in."
                            : "Google sign-in did not complete. Check your connection and try again.";
                    }
                    final String resultMessage = message;
                    runOnUiThread(() -> authResult(resultMessage));
                });
            }
            return;
        }
        try {
            String kind = intent.getStringExtra("kind"), id = intent.getStringExtra("id");
            if (kind != null && id != null) route = new JSONObject().put("kind", kind).put("id", id);
        } catch (Exception ignored) { }
    }
    private void authResult(String message) {
        try {
            route = new JSONObject().put("kind", "auth").put("id", message);
            if (channel != null) channel.invokeMethod("route", null);
        } catch (Exception ignored) { }
    }
    private void handle(MethodCall call, MethodChannel.Result result) {
        try {
            switch (call.method) {
                case "reconnectListener":
                    UpiNotificationListener.reconnect(this, true);
                    result.success(null); return;
                case "googleSignIn":
                    TallyApplication.IO.execute(() -> {
                        try {
                            String url = Backend.beginGoogle();
                            runOnUiThread(() -> {
                                try {
                                    startActivity(new Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url))
                                        .addCategory(Intent.CATEGORY_BROWSABLE));
                                    result.success("{\"started\":true}");
                                } catch (Exception e) { result.error("browser", "Install or enable a browser to sign in with Google.", null); }
                            });
                        } catch (Exception e) {
                            runOnUiThread(() -> result.error("auth", "Could not start Google sign-in. Please try again.", null));
                        }
                    });
                    return;
                case "takeRoute": { JSONObject value = route; route = null; result.success(value == null ? null : value.toString()); return; }
                case "notificationPermission":
                    if (Build.VERSION.SDK_INT >= 33) requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 7);
                    else startActivity(new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, getPackageName()));
                    result.success(null); return;
                case "listenerSettings": startActivity(new Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)); result.success(null); return;
                case "appSettings": startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.parse("package:" + getPackageName()))); result.success(null); return;
            }
            TallyApplication.IO.execute(() -> {
                synchronized (Backend.class) {
                    try {
                        JSONObject args = call.arguments instanceof Map ? new JSONObject((Map<?, ?>) call.arguments) : new JSONObject();
                        JSONObject value = dispatch(call.method, args);
                        runOnUiThread(() -> result.success(value == null ? null : value.toString()));
                    } catch (Exception e) {
                        String code = e instanceof Backend.ApiException ? String.valueOf(((Backend.ApiException)e).status) : "native";
                        String message = e instanceof java.net.UnknownHostException ? "No connection. Try again when online." : e.getMessage();
                        runOnUiThread(() -> result.error(code, message == null ? "Unable to complete this request." : message, null));
                    }
                }
            });
        } catch (Exception e) { result.error("native", e.getMessage(), null); }
    }
    private JSONObject dispatch(String method, JSONObject args) throws Exception {
        switch (method) {
            case "status":
                return new JSONObject().put("configured", Backend.configured()).put("user_id", Backend.userId())
                    .put("detection", SecureStore.get("settings").optBoolean("detection"))
                    .put("detection_check", SecureStore.get("detection_check"))
                    .put("listener", listenerEnabled())
                    .put("listener_connected", UpiNotificationListener.isConnected())
                    .put("notifications", Notifications.promptsAllowed(this))
                    .put("firebase", !FirebaseApp.getApps(this).isEmpty())
                    .put("group", SecureStore.get("group"))
                    .put("pending", ExpenseQueue.list(Backend.userId(), false));
            case "auth": {
                JSONObject result = Backend.auth(args.getString("email"), args.getString("password"), args.optString("name"), args.optBoolean("signup"));
                if (result.optBoolean("signed_in")) { startPush(); SyncWorker.enqueue(this); }
                return result;
            }
            case "logout":
                String user = Backend.userId();
                if (ExpenseQueue.list(user, true).length() > 0) throw new IllegalStateException("Wait for confirmed expenses to sync before signing out.");
                Backend.logout();
                ExpenseQueue.clearSuggestions(user);
                getSystemService(NotificationManager.class).cancelAll();
                if (!FirebaseApp.getApps(this).isEmpty()) FirebaseMessaging.getInstance().setAutoInitEnabled(false);
                return new JSONObject();
            case "snapshot": {
                JSONObject snapshot = Backend.rpc("ledger_snapshot", new JSONObject());
                JSONObject group = snapshot.optJSONObject("group");
                SecureStore.put("group", group == null ? new JSONObject() : group);
                startPush();
                SyncWorker.enqueue(this);
                return snapshot;
            }
            case "createGroup": return Backend.rpc("create_group", new JSONObject().put("p_name", args.getString("name")));
            case "joinGroup": return Backend.rpc("join_group", new JSONObject().put("p_code", args.getString("code")));
            case "invite": return Backend.rpc("create_invite", new JSONObject());
            case "expense": return Backend.rpc("expense_detail", new JSONObject().put("p_id", args.getString("id")));
            case "realtime": return Backend.realtimeConfig();
            case "detection": {
                JSONObject settings = SecureStore.get("settings").put("detection", args.getBoolean("enabled"));
                SecureStore.put("settings", settings); return settings;
            }
            case "queue": {
                String group = SecureStore.get("group").optString("id"), owner = Backend.userId();
                if (owner.isEmpty() || group.isEmpty() || !SecureStore.get("group").optBoolean("ready"))
                    throw new IllegalStateException("Sign in and connect your friend first.");
                String id = ExpenseQueue.enqueueManual(args, owner, group);
                SyncWorker.enqueue(this); Notifications.cancelPrompt(this, id);
                return new JSONObject().put("id", id);
            }
            case "retry": ExpenseQueue.retry(args.getString("id"), Backend.userId()); SyncWorker.enqueue(this); return new JSONObject();
            case "dismiss": ExpenseQueue.dismiss(args.getString("id"), Backend.userId()); Notifications.cancelPrompt(this, args.getString("id")); return new JSONObject();
            default: throw new IllegalArgumentException("Unknown method.");
        }
    }
    private boolean listenerEnabled() {
        ComponentName component = new ComponentName(this, UpiNotificationListener.class);
        if (Build.VERSION.SDK_INT >= 27)
            return getSystemService(NotificationManager.class).isNotificationListenerAccessGranted(component);
        String enabled = Settings.Secure.getString(getContentResolver(), "enabled_notification_listeners");
        if (enabled == null) return false;
        for (String name : enabled.split(":")) if (component.equals(ComponentName.unflattenFromString(name))) return true;
        return false;
    }
    private void startPush() {
        if (FirebaseApp.getApps(this).isEmpty() || Backend.userId().isEmpty()) return;
        FirebaseMessaging messaging = FirebaseMessaging.getInstance();
        messaging.setAutoInitEnabled(true);
        messaging.getToken().addOnSuccessListener(token -> TallyApplication.IO.execute(() -> {
            try {
                JSONObject device = SecureStore.get("device").put("token", token);
                SecureStore.put("device", device); SyncWorker.enqueue(this);
            } catch (Exception ignored) { }
        }));
    }
}
