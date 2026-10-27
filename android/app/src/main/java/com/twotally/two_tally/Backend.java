package com.twotally.two_tally;

import java.io.InputStream;
import java.io.IOException;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;

/** Single session owner. The Flutter UI and native Worker share this refresh lock. */
final class Backend {
    static final class ApiException extends IOException {
        final int status;
        ApiException(int status, String message) { super(message); this.status = status; }
        boolean retryable() { return status == 408 || status == 429 || status >= 500; }
    }
    static boolean configured() {
        return BuildConfig.SUPABASE_URL.startsWith("https://") && !BuildConfig.SUPABASE_KEY.isEmpty();
    }
    static String userId() {
        return SecureStore.get("session").optJSONObject("user") == null ? "" :
            SecureStore.get("session").optJSONObject("user").optString("id");
    }
    static synchronized JSONObject auth(String email, String password, String name, boolean signup) throws Exception {
        if (!configured()) throw new ApiException(400, "This build needs Supabase configuration.");
        JSONObject body = new JSONObject().put("email", email).put("password", password);
        if (signup) body.put("data", new JSONObject().put("display_name", name));
        JSONObject result = request(signup ? "/auth/v1/signup?redirect_to=" + java.net.URLEncoder.encode(OAuthPkce.CONFIRMED, "UTF-8") : "/auth/v1/token?grant_type=password", body, null);
        if (result.has("access_token")) {
            if (!userId().isEmpty() && !userId().equals(result.getJSONObject("user").getString("id")))
                throw new ApiException(400, "Sign in with the same account to resume sync. Sign out before switching accounts.");
            saveSession(result);
        }
        return new JSONObject().put("signed_in", result.has("access_token"));
    }
    private static void saveSession(JSONObject session) throws Exception {
        if (!session.has("expires_at")) session.put("expires_at", System.currentTimeMillis() / 1000 + session.optLong("expires_in", 3600));
        SecureStore.put("session", session);
    }
    static synchronized String beginGoogle() throws Exception {
        if (!configured()) throw new ApiException(400, "This build needs Supabase configuration.");
        String verifier = OAuthPkce.verifier();
        SecureStore.put("oauth_pending", new JSONObject().put("verifier", verifier)
            .put("created_at", System.currentTimeMillis()).put("owner", userId()));
        return BuildConfig.SUPABASE_URL + "/auth/v1/authorize?provider=google&redirect_to="
            + java.net.URLEncoder.encode(OAuthPkce.CALLBACK, "UTF-8")
            + "&code_challenge=" + OAuthPkce.challenge(verifier) + "&code_challenge_method=s256"
            + "&prompt=select_account";
    }
    static synchronized void finishGoogle(String code) throws Exception {
        JSONObject pending = SecureStore.get("oauth_pending");
        long age = System.currentTimeMillis() - pending.optLong("created_at");
        if (pending.optString("verifier").isEmpty() || age < 0 || age > 600000
            || !pending.optString("owner").equals(userId())) {
            SecureStore.remove("oauth_pending");
            throw new ApiException(400, "Sign-in expired. Tap Continue with Google again.");
        }
        if (code == null || code.isEmpty() || code.length() > 2048)
            throw new ApiException(400, "Google sign-in did not complete. Please try again.");
        JSONObject session = request("/auth/v1/token?grant_type=pkce", new JSONObject()
            .put("auth_code", code).put("code_verifier", pending.getString("verifier")), null);
        if (!userId().isEmpty() && !userId().equals(session.getJSONObject("user").getString("id")))
            throw new ApiException(400, "Sign in with the same account to resume sync. Sign out before switching accounts.");
        if (session.optString("access_token").isEmpty() || session.optString("refresh_token").isEmpty())
            throw new ApiException(400, "Google sign-in did not return a session. Please try again.");
        saveSession(session);
        SecureStore.remove("oauth_pending");
    }
    static synchronized String token() throws Exception {
        JSONObject session = SecureStore.get("session");
        if (session.optString("refresh_token").isEmpty()) throw new ApiException(401, "Sign in to sync your expenses.");
        if (session.optLong("expires_at") < System.currentTimeMillis() / 1000 + 90) {
            try {
                session = request("/auth/v1/token?grant_type=refresh_token",
                    new JSONObject().put("refresh_token", session.getString("refresh_token")), null);
                saveSession(session);
            } catch (ApiException e) {
                if (e.status == 400 || e.status == 401 || e.status == 403)
                    throw new ApiException(401, "Your session expired. Sign in again to sync confirmed expenses.");
                throw e;
            }
        }
        return session.getString("access_token");
    }
    static synchronized JSONObject rpc(String name, JSONObject args) throws Exception {
        String access = token();
        try { return request("/rest/v1/rpc/" + name, args, access); }
        catch (ApiException e) {
            if (e.status != 401) throw e;
            JSONObject session = SecureStore.get("session");
            session.put("expires_at", 0);
            SecureStore.put("session", session);
            return request("/rest/v1/rpc/" + name, args, token());
        }
    }
    static synchronized void logout() throws Exception {
        // Unregister first. If offline, keep the session so logout can be retried safely.
        JSONObject device = SecureStore.get("device");
        if (!device.optString("id").isEmpty()) rpc("unregister_device", new JSONObject().put("p_device_id", device.getString("id")));
        try { request("/auth/v1/logout?scope=local", new JSONObject(), token()); }
        finally { SecureStore.remove("session"); SecureStore.remove("group"); SecureStore.remove("oauth_pending"); }
    }
    static synchronized JSONObject realtimeConfig() throws Exception {
        return new JSONObject().put("url", BuildConfig.SUPABASE_URL)
            .put("key", BuildConfig.SUPABASE_KEY).put("token", token());
    }
    private static JSONObject request(String path, JSONObject body, String token) throws Exception {
        if (!configured()) throw new ApiException(400, "Configure Supabase before using this build.");
        HttpURLConnection connection = (HttpURLConnection) new URL(BuildConfig.SUPABASE_URL + path).openConnection();
        connection.setConnectTimeout(15000);
        connection.setReadTimeout(20000);
        connection.setInstanceFollowRedirects(false);
        connection.setRequestMethod("POST");
        connection.setRequestProperty("apikey", BuildConfig.SUPABASE_KEY);
        connection.setRequestProperty("Content-Type", "application/json");
        if (token != null) connection.setRequestProperty("Authorization", "Bearer " + token);
        connection.setDoOutput(true);
        try {
            try (java.io.OutputStream stream = connection.getOutputStream()) {
                stream.write(body.toString().getBytes(StandardCharsets.UTF_8));
            }
            int status = connection.getResponseCode();
            InputStream stream = status >= 200 && status < 300 ? connection.getInputStream() : connection.getErrorStream();
            String raw = "";
            if (stream != null) {
                try (InputStream input = stream; java.io.ByteArrayOutputStream output = new java.io.ByteArrayOutputStream()) {
                    byte[] buffer = new byte[8192];
                    int n;
                    while ((n = input.read(buffer)) != -1) {
                        output.write(buffer, 0, n);
                        if (output.size() > 4_000_000) throw new IOException("Response too large.");
                    }
                    raw = output.toString("UTF-8");
                }
            }
            JSONObject response;
            try { response = raw.isEmpty() || raw.equals("null") ? new JSONObject() : new JSONObject(raw); }
            catch (Exception e) { throw new ApiException(status, "Unexpected server response (" + status + ")."); }
            if (status < 200 || status >= 300)
                throw new ApiException(status, response.optString("msg",
                    response.optString("message", response.optString("error_description", "Request failed (" + status + ")."))));
            return response;
        } finally { connection.disconnect(); }
    }
}
