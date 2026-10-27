// Credentials exist only as Edge Function secrets. This endpoint requires an independent
// high-entropy secret from Vault; verify_jwt=false does NOT make it unauthenticated.
type Delivery = {
  id: string; lease_id: string; expense_id: string; recipient_id: string;
  token: string; attempts: number; amount_paise: number; kind: string; payer_name: string;
};
const env = (name: string): string => {
  const value = Deno.env.get(name);
  if (!value) throw new Error("Missing server configuration: " + name);
  return value;
};
function equalSecret(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let different = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) different |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return different === 0;
}
async function rpc(name: string, args: Record<string, unknown>): Promise<Record<string, unknown>> {
  const key = env("SUPABASE_SERVICE_ROLE_KEY");
  const response = await fetch(env("SUPABASE_URL") + "/rest/v1/rpc/" + name, {
    method: "POST",
    headers: { apikey: key, Authorization: "Bearer " + key, "Content-Type": "application/json" },
    body: JSON.stringify(args),
    signal: AbortSignal.timeout(20000),
  });
  if (!response.ok) throw new Error("Database RPC failed: " + response.status);
  return await response.json();
}
const base64url = (data: Uint8Array): string =>
  btoa(String.fromCharCode(...data)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const encode = (value: unknown): string => base64url(new TextEncoder().encode(JSON.stringify(value)));
let cachedAccess: { token: string; expires: number } | undefined;
async function googleToken(): Promise<string> {
  if (cachedAccess && cachedAccess.expires > Date.now() + 60000) return cachedAccess.token;
  const account = JSON.parse(env("FCM_SERVICE_ACCOUNT_JSON"));
  const now = Math.floor(Date.now() / 1000);
  const unsigned = encode({ alg: "RS256", typ: "JWT" }) + "." + encode({
    iss: account.client_email, scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token", iat: now, exp: now + 3600,
  });
  const pem = account.private_key.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "");
  const key = await crypto.subtle.importKey("pkcs8", Uint8Array.from(atob(pem), c => c.charCodeAt(0)),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned));
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: unsigned + "." + base64url(new Uint8Array(signature)) }),
    signal: AbortSignal.timeout(15000),
  });
  if (!response.ok) throw new Error("FCM OAuth failed: " + response.status);
  const result = await response.json();
  cachedAccess = { token: result.access_token, expires: Date.now() + result.expires_in * 1000 };
  return cachedAccess.token;
}
export function messageFor(item: Delivery): Record<string, unknown> {
  const amount = "₹" + (item.amount_paise / 100).toFixed(2);
  return {
    message: {
      token: item.token,
      // Data-only so native code handles both foreground/background and persistent deduplication.
      data: {
        expense_id: item.expense_id, recipient_user_id: item.recipient_id,
        title: item.payer_name + (item.kind === "repayment" ? " recorded a repayment" : " logged an expense"),
        body: item.kind === "repayment" ? item.payer_name + " recorded a repayment of " + amount + "." :
          item.payer_name + " logged a shared expense of " + amount + ".",
      },
      android: { priority: "HIGH", ttl: "2419200s" }, // 28 days, non-collapsible.
    },
  };
}
export async function handler(request: Request): Promise<Response> {
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });
  if (!equalSecret(request.headers.get("x-dispatch-secret") ?? "", env("PUSH_DISPATCH_SECRET")))
    return new Response("Unauthorized", { status: 401 });
  try {
    const access = await googleToken();
    const project = JSON.parse(env("FCM_SERVICE_ACCOUNT_JSON")).project_id;
    const result = await rpc("claim_push", { p_limit: 20 });
    const items = result.items as Delivery[];
    await Promise.all(items.map(async item => {
      let outcome = "retry", error: string | null = null;
      try {
        const response = await fetch("https://fcm.googleapis.com/v1/projects/" + project + "/messages:send", {
          method: "POST", headers: { Authorization: "Bearer " + access, "Content-Type": "application/json" },
          body: JSON.stringify(messageFor(item)), signal: AbortSignal.timeout(20000),
        });
        if (response.ok) outcome = "sent";
        else {
          const body = await response.json();
          const codes: string[] = (body.error?.details ?? []).map((v: { errorCode?: string }) => v.errorCode ?? "");
          // Invalid registration tokens are terminal; credential/server failures remain retryable.
          outcome = codes.includes("UNREGISTERED") ? "dead" : "retry";
          error = "FCM " + response.status + " " + codes.join(",");
          if (response.status === 401) cachedAccess = undefined;
        }
      } catch { error = "FCM request interrupted"; }
      await rpc("finish_push", { p_id: item.id, p_lease_id: item.lease_id, p_result: outcome, p_error: error });
    }));
    return Response.json({ processed: items.length });
  } catch {
    // Do not log tokens, payloads, service-account material, or notification text.
    return Response.json({ error: "Dispatch unavailable; durable deliveries will retry." }, { status: 503 });
  }
}
