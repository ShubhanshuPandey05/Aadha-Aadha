package com.twotally.two_tally;

import org.json.JSONArray;
import org.json.JSONObject;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.UUID;

/** Pending suggestions never leave the device. Only explicit consent changes state to queued. */
final class ExpenseQueue {
    static final long DAY = 86400000L;
    static synchronized JSONObject offer(PaymentParser.Payment payment, String pkg, String user, String group) throws Exception {
        JSONObject all = SecureStore.get("queue");
        long now = System.currentTimeMillis();
        prune(all, now);
        for (Iterator<String> it = all.keys(); it.hasNext();) {
            JSONObject prior = all.getJSONObject(it.next());
            if (!user.equals(prior.optString("owner"))) continue;
            if (PaymentDeduplication.matches(payment, prior.optString("fingerprint"), prior.optString("event_key"),
                prior.isNull("reference") ? null : prior.getString("reference"),
                prior.isNull("amount") ? null : prior.getLong("amount"),
                prior.isNull("recipient") ? null : prior.getString("recipient"))) return null;
        }
        if (all.length() >= 500) return null; // Never evict confirmed, unsynced writes.
        String id = UUID.randomUUID().toString();
        JSONObject item = new JSONObject().put("id", id).put("owner", user).put("group", group)
            .put("amount", payment.amountPaise == null ? JSONObject.NULL : payment.amountPaise)
            .put("recipient", payment.recipient == null ? JSONObject.NULL : payment.recipient)
            .put("reference", payment.reference == null ? JSONObject.NULL : payment.reference)
            .put("fingerprint", payment.fingerprint).put("semantic", payment.semantic).put("event_key", payment.eventKey).put("source", pkg)
            .put("timestamp", payment.timestamp).put("created", now).put("state", "suggested");
        all.put(id, item); SecureStore.put("queue", all);
        return item;
    }
    private static void prune(JSONObject all, long now) throws Exception {
        ArrayList<String> remove = new ArrayList<>();
        for (Iterator<String> it = all.keys(); it.hasNext();) {
            String id = it.next(); JSONObject item = all.getJSONObject(id);
            String state = item.optString("state");
            long age = now - item.optLong("created");
            if (state.equals("suggested") && age > DAY) {
                item.put("state", "dismissed"); all.put(id, item);
            }
            if (!state.equals("queued") && !state.equals("failed") && age > 30 * DAY) remove.add(id);
        }
        for (String id : remove) all.remove(id);
    }
    static synchronized JSONObject get(String id) { return SecureStore.get("queue").optJSONObject(id); }
    static synchronized void dismiss(String id, String owner) throws Exception {
        JSONObject all = SecureStore.get("queue"), item = all.optJSONObject(id);
        if (item == null || !owner.equals(item.optString("owner")) || !item.optString("state").equals("suggested")) return;
        item.put("state", "dismissed"); all.put(id, item); SecureStore.put("queue", all);
    }
    static synchronized boolean confirm(String id, String owner) throws Exception {
        JSONObject all = SecureStore.get("queue"), item = all.optJSONObject(id);
        if (item == null || !owner.equals(item.optString("owner")) || item.isNull("amount")
            || !item.optString("state").equals("suggested") || System.currentTimeMillis() - item.optLong("created") > DAY) return false;
        item.put("state", "queued");
        item.put("payload", payload(item, item.getLong("amount"), null, false));
        all.put(id, item); SecureStore.put("queue", all);
        return true;
    }
    static JSONObject payload(JSONObject item, long amount, Long share, boolean repayment) throws Exception {
        return new JSONObject().put("p_group_id", item.getString("group")).put("p_client_id", item.getString("id"))
            .put("p_amount_paise", amount).put("p_payer_share_paise", repayment ? 0 : share == null ? (amount + 1) / 2 : share)
            .put("p_name", item.has("name") ? item.get("name") : JSONObject.NULL)
            .put("p_kind", repayment ? "repayment" : "expense")
            .put("p_recipient", item.has("recipient") ? item.get("recipient") : JSONObject.NULL).put("p_occurred_at", java.time.Instant.ofEpochMilli(item.getLong("timestamp")).toString())
            .put("p_transaction_ref", item.has("reference") ? item.get("reference") : JSONObject.NULL).put("p_source", item.optString("source", "manual"))
            .put("p_fingerprint", item.has("fingerprint") ? item.get("fingerprint") : JSONObject.NULL);
    }
    static synchronized String enqueueManual(JSONObject args, String owner, String group) throws Exception {
        JSONObject all = SecureStore.get("queue");
        String id = args.getString("id");
        JSONObject previous = all.optJSONObject(id);
        if (previous != null && previous.optString("state").equals("queued")) return id;
        if (previous != null && previous.optString("state").equals("saved")) return id;
        if (previous != null && (!owner.equals(previous.optString("owner")) || !group.equals(previous.optString("group"))))
            throw new IllegalArgumentException("This suggestion belongs to a different account or group.");
        if (previous != null && (!previous.optString("state").equals("suggested")
            || System.currentTimeMillis() - previous.optLong("created") > DAY))
            throw new IllegalArgumentException("This suggestion has expired.");
        long amount = args.getLong("amount");
        Long share = args.isNull("share") ? null : args.getLong("share");
        if (amount <= 0 || amount > 1_000_000_000L || (share != null && (share < 0 || share > amount)))
            throw new IllegalArgumentException("Check the amount and your share.");
        JSONObject item = previous == null ? new JSONObject().put("id", id).put("owner", owner).put("group", group)
            .put("created", System.currentTimeMillis()).put("timestamp", System.currentTimeMillis()).put("source", "manual") : previous;
        item.put("name", args.opt("name")).put("amount", amount).put("recipient", args.opt("recipient")).put("state", "queued")
            .put("payload", payload(item, amount, share, args.optBoolean("repayment")));
        all.put(id, item); SecureStore.put("queue", all);
        return id;
    }
    static synchronized void state(String id, String state, String message) throws Exception {
        JSONObject all = SecureStore.get("queue"), item = all.optJSONObject(id);
        if (item == null) return;
        item.put("state", state).put("message", message); all.put(id, item); SecureStore.put("queue", all);
    }
    static synchronized JSONArray list(String user, boolean onlyQueued) throws Exception {
        JSONObject all = SecureStore.get("queue"); prune(all, System.currentTimeMillis()); SecureStore.put("queue", all);
        JSONArray result = new JSONArray();
        for (Iterator<String> it = all.keys(); it.hasNext();) {
            JSONObject item = all.getJSONObject(it.next()); String state = item.optString("state");
            if (user.equals(item.optString("owner")) && (onlyQueued ? state.equals("queued") :
                state.equals("queued") || state.equals("failed") || state.equals("suggested"))) result.put(item);
        }
        return result;
    }
    static synchronized void retry(String id, String owner) throws Exception {
        JSONObject item = get(id);
        if (item != null && owner.equals(item.optString("owner")) && item.optString("state").equals("failed"))
            state(id, "queued", "");
    }
    static synchronized void clearSuggestions(String owner) throws Exception {
        JSONObject all = SecureStore.get("queue");
        for (Iterator<String> it = all.keys(); it.hasNext();) {
            JSONObject item = all.getJSONObject(it.next());
            if (owner.equals(item.optString("owner")) && item.optString("state").equals("suggested")) item.put("state", "dismissed");
        }
        SecureStore.put("queue", all);
    }
}
