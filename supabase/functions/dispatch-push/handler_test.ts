import { handler, messageFor } from "./handler.ts";
function assert(value: unknown, message = "Assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
const item = {
  id: "delivery", lease_id: "lease", expense_id: "expense", recipient_id: "friend",
  token: "fcm-token", attempts: 1, amount_paise: 35000, kind: "expense", payer_name: "Asha",
};
Deno.test("FCM message has stable expense identity, recipient gate, TTL and amount", () => {
  const payload = messageFor(item) as { message: { data: Record<string, string>; android: Record<string, unknown>; notification?: unknown } };
  assert(payload.message.data.expense_id === "expense");
  assert(payload.message.data.recipient_user_id === "friend");
  assert(payload.message.data.body === "Asha logged a shared expense of ₹350.00.");
  assert(payload.message.android.ttl === "2419200s");
  assert(!payload.message.notification, "OS auto-display would bypass client duplicate suppression");
});
Deno.test("repayment message is distinguished from shared spending", () => {
  assert(JSON.stringify(messageFor({ ...item, kind: "repayment" })).includes("repayment of ₹350.00"));
});
Deno.test("webhook refuses missing or wrong secrets before accessing credentials", async () => {
  Deno.env.set("PUSH_DISPATCH_SECRET", "a-secret-only-the-server-knows");
  for (const secret of ["", "wrong"]) {
    const response = await handler(new Request("https://example.test", {
      method: "POST", headers: { "x-dispatch-secret": secret },
    }));
    assert(response.status === 401);
  }
  assert((await handler(new Request("https://example.test"))).status === 405);
});
