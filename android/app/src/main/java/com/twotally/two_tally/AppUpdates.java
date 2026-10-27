package com.twotally.two_tally;

import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.provider.Settings;
import androidx.core.content.FileProvider;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.*;
import java.net.*;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** GitHub-distributed APKs only. Never installs silently or accepts an arbitrary URL from Dart. */
final class AppUpdates {
    static final ExecutorService IO = Executors.newSingleThreadExecutor();
    private static final String REPO = "https://github.com/ShubhanshuPandey05/Aadha-Aadha/";
    private static final String API = "https://api.github.com/repos/ShubhanshuPandey05/Aadha-Aadha/releases/latest";
    static JSONObject check(boolean force) throws Exception {
        JSONObject cache = SecureStore.get("app_update");
        long age = System.currentTimeMillis() - cache.optLong("checked");
        if (!force && age >= 0 && age < 86400000L) return publicInfo(cache);
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        fetch(API, bytes, 1_000_000);
        JSONObject release = new JSONObject(bytes.toString("UTF-8"));
        JSONObject next = new JSONObject().put("checked", System.currentTimeMillis());
        String version = release.optString("tag_name").replaceFirst("^v", "");
        if (!release.optBoolean("draft") && !release.optBoolean("prerelease") && newer(version, BuildConfig.VERSION_NAME)) {
            String abi = android.os.Process.is64Bit() ? "arm64-v8a" : "armeabi-v7a";
            JSONArray assets = release.getJSONArray("assets");
            for (int i=0; i<assets.length(); i++) {
                JSONObject asset = assets.getJSONObject(i);
                String url = asset.optString("browser_download_url"), digest = asset.optString("digest");
                long size = asset.optLong("size");
                if (asset.optString("name").equals("aadha-aadha-" + version + "-" + abi + ".apk")
                    && url.startsWith(REPO + "releases/download/") && digest.matches("sha256:[a-f0-9]{64}")
                    && size > 0 && size < 20_000_000 && "uploaded".equals(asset.optString("state"))) {
                    next.put("version", version).put("url", url).put("digest", digest.substring(7)).put("size", size);
                    break;
                }
            }
        }
        SecureStore.put("app_update", next);
        return publicInfo(next);
    }
    private static JSONObject publicInfo(JSONObject value) throws Exception {
        return new JSONObject().put("available", newer(value.optString("version"), BuildConfig.VERSION_NAME))
            .put("version", value.optString("version")).put("size", value.optLong("size"))
            .put("current", BuildConfig.VERSION_NAME);
    }
    static boolean newer(String candidate, String current) {
        if (!candidate.matches("[0-9]{1,6}\\.[0-9]{1,6}\\.[0-9]{1,6}") || !current.matches("[0-9]{1,6}\\.[0-9]{1,6}\\.[0-9]{1,6}")) return false;
        String[] a = candidate.split("\\."), b = current.split("\\.");
        for (int i=0;i<3;i++) { int x=Integer.parseInt(a[i]),y=Integer.parseInt(b[i]); if(x!=y) return x>y; }
        return false;
    }
    private static void fetch(String address, OutputStream output, long limit) throws Exception {
        long deadline = System.currentTimeMillis() + 180000;
        for (int redirects=0;redirects<6;redirects++) {
            URL url = new URL(address);
            String host=url.getHost();
            if (!"https".equals(url.getProtocol()) || !(host.equals("api.github.com") || host.equals("github.com") || host.endsWith(".githubusercontent.com")))
                throw new IOException("Untrusted update download address.");
            HttpURLConnection connection = (HttpURLConnection)url.openConnection();
            connection.setConnectTimeout(15000); connection.setReadTimeout(15000);
            connection.setInstanceFollowRedirects(false);
            connection.setRequestProperty("User-Agent", "Aadha-Aadha/"+BuildConfig.VERSION_NAME);
            try {
                int status=connection.getResponseCode();
                if (status>=300 && status<400) {
                    address=new URL(url,connection.getHeaderField("Location")).toString(); continue;
                }
                if(status!=200) throw new IOException("Update server unavailable ("+status+"). Try again later.");
                try(InputStream input=connection.getInputStream()) {
                    byte[] buffer=new byte[16384]; long count=0; int n;
                    while((n=input.read(buffer))!=-1) {
                        count+=n;
                        if(count>limit || System.currentTimeMillis()>deadline) throw new IOException("Update download incomplete or too slow. Please retry on another network.");
                        output.write(buffer,0,n);
                    }
                }
                return;
            } finally { connection.disconnect(); }
        }
        throw new IOException("Too many download redirects.");
    }
    static File download(Activity activity) throws Exception {
        JSONObject info=SecureStore.get("app_update");
        if(!newer(info.optString("version"),BuildConfig.VERSION_NAME)) throw new IOException("Check for updates first.");
        File folder=new File(activity.getCacheDir(),"updates");
        if(!folder.isDirectory() && !folder.mkdirs()) throw new IOException("Not enough storage for the update.");
        File apk=new File(folder,"update.apk");
        if(apk.exists()) {
            try { verify(activity,apk,info); return apk; } catch(Exception invalid) { if(!apk.delete()) throw new IOException("Cannot replace cached update."); }
        }
        try {
            try(OutputStream out=new FileOutputStream(apk)) { fetch(info.getString("url"),out,19_999_999); }
            verify(activity,apk,info);
            return apk;
        } catch(Exception error) { apk.delete(); throw error; }
    }
    @SuppressWarnings("deprecation")
    private static void verify(Activity activity,File apk,JSONObject info) throws Exception {
        if(apk.length()!=info.getLong("size")) throw new IOException("Incomplete update. Please retry.");
        MessageDigest sha=MessageDigest.getInstance("SHA-256");
        try(InputStream input=new FileInputStream(apk)) {
            byte[] buf=new byte[16384];int n;while((n=input.read(buf))!=-1)sha.update(buf,0,n);
        }
        StringBuilder hex=new StringBuilder();for(byte b:sha.digest())hex.append(String.format(java.util.Locale.ROOT,"%02x",b&255));
        if(!hex.toString().equals(info.getString("digest"))) throw new IOException("Update checksum mismatch. Please retry.");
        PackageManager pm=activity.getPackageManager();
        PackageInfo installed=pm.getPackageInfo(activity.getPackageName(),PackageManager.GET_SIGNATURES);
        PackageInfo incoming=pm.getPackageArchiveInfo(apk.getAbsolutePath(),PackageManager.GET_SIGNATURES);
        if(incoming==null || !activity.getPackageName().equals(incoming.packageName)
            || !info.getString("version").equals(incoming.versionName) || incoming.versionCode<=installed.versionCode
            || installed.signatures==null || incoming.signatures==null || !Arrays.equals(installed.signatures,incoming.signatures))
            throw new IOException("This update does not match the installed app or signing certificate.");
    }
    static boolean install(Activity activity, File apk) {
        if(!activity.getPackageManager().canRequestPackageInstalls()) {
            activity.startActivity(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,Uri.parse("package:"+activity.getPackageName())));
            return false;
        }
        Uri uri=FileProvider.getUriForFile(activity,activity.getPackageName()+".updates",apk);
        activity.startActivity(new Intent(Intent.ACTION_VIEW).setDataAndType(uri,"application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION));
        return true;
    }
}
