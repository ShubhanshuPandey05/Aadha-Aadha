package com.twotally.two_tally;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.Arrays;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import org.json.JSONObject;

/** Keys remain in Android Keystore; no session or raw notification text in backups/logs. */
final class SecureStore {
    private static SharedPreferences prefs;
    static synchronized void init(Context context) {
        if (prefs == null) prefs = context.getSharedPreferences("encrypted_state", Context.MODE_PRIVATE);
    }
    private static SecretKey key() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        String alias = "two_tally_v1";
        if (!store.containsAlias(alias)) {
            KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
            generator.init(new KeyGenParameterSpec.Builder(alias,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
            generator.generateKey();
        }
        return (SecretKey) store.getKey(alias, null);
    }
    static synchronized JSONObject get(String name) {
        String encoded = prefs.getString(name, null);
        if (encoded == null) return new JSONObject();
        try {
            byte[] bytes = Base64.decode(encoded, Base64.NO_WRAP);
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(128, Arrays.copyOfRange(bytes, 0, 12)));
            cipher.updateAAD(name.getBytes(StandardCharsets.UTF_8));
            return new JSONObject(new String(cipher.doFinal(Arrays.copyOfRange(bytes, 12, bytes.length)), StandardCharsets.UTF_8));
        } catch (Exception e) { throw new IllegalStateException("Secure storage could not be read. Sign in again after resetting app storage.", e); }
    }
    static synchronized void put(String name, JSONObject value) {
        try {
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.ENCRYPT_MODE, key());
            cipher.updateAAD(name.getBytes(StandardCharsets.UTF_8));
            byte[] data = cipher.doFinal(value.toString().getBytes(StandardCharsets.UTF_8));
            byte[] combined = new byte[12 + data.length];
            System.arraycopy(cipher.getIV(), 0, combined, 0, 12);
            System.arraycopy(data, 0, combined, 12, data.length);
            if (!prefs.edit().putString(name, Base64.encodeToString(combined, Base64.NO_WRAP)).commit())
                throw new IllegalStateException("Storage is full.");
        } catch (Exception e) { throw new IllegalStateException("Could not save secure state.", e); }
    }
    static synchronized void remove(String name) {
        if (!prefs.edit().remove(name).commit()) throw new IllegalStateException("Could not clear secure state.");
    }
}
