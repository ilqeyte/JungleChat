// JungleChat — push-worker Edge Function.
//
// Called every minute by pg_cron (with the x-cron-key header):
//   1. Fetches unpushed notifications (last 10 min).
//   2. Resolves each recipient's FCM tokens.
//   3. Sends FCM v1 pushes using the FCM_SERVICE_ACCOUNT secret.
//   4. Marks notifications pushed.
//
// Privacy: payloads are the same fixed templates as in-app notifications â€”
// never Animal IDs, never message content.

const CORS = { "Content-Type": "application/json" };

function b64url(input: string | Uint8Array): string {
  const bytes =
    typeof input === "string" ? new TextEncoder().encode(input) : input;
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

let cachedToken: { token: string; expiresAt: number } | null = null;

async function getAccessToken(
  serviceAccount: Record<string, string>,
): Promise<string> {
  // Cache per isolate: skips the OAuth exchange on warm invocations.
  if (cachedToken && cachedToken.expiresAt > Date.now() / 1000 + 60) {
    return cachedToken.token;
  }
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = b64url(
    JSON.stringify({
      iss: serviceAccount.client_email,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: now + 3600,
    }),
  );
  const unsigned = `${header}.${claims}`;

  const keyData = serviceAccount.private_key
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const der = Uint8Array.from(atob(keyData), (ch) => ch.charCodeAt(0));

  const key = await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned),
  );
  const signature = b64url(new Uint8Array(sig));

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: `${unsigned}.${signature}`,
    }),
  });
  if (!res.ok) throw new Error(`token exchange failed: ${await res.text()}`);
  const json = await res.json();
  return json.access_token;
}

function template(kind: string): { title: string; body: string } {
  switch (kind) {
    case "new_message":
      return { title: "JungleChat", body: "An animal sent you a message." };
    case "talk_request":
      return {
        title: "JungleChat",
        body: "An animal wants to talk to you.",
      };
    case "talk_accepted":
      return {
        title: "JungleChat",
        body: "Your talk request was accepted.",
      };
    case "group_message":
      return {
        title: "JungleChat",
        body: "New message in a group.",
      };
    case "official_message":
      return {
        title: "JungleChat",
        body: "Adam sent you a message.",
      };
    case "group_added":
      return {
        title: "JungleChat",
        body: "You were added to a group.",
      };
    case "inactivity_warning":
      return {
        title: "JungleChat",
        body: "Your account is approaching its inactivity deadline.",
      };
    // A new release went live. Deliberately generic: the payload may name a
    // version, but the push text must never carry anything else.
    case "group_invitation":
      return {
        title: "JungleChat",
        body: "You have been invited to a group.",
      };
    case "app_update":
      return {
        title: "JungleChat",
        body: "A new version is available. Update to keep using the app.",
      };
    default:
      return {
        title: "JungleChat",
        body: "Something happened in the shadows.",
      };
  }
}

Deno.serve(async (req) => {
  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const admin = { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` };

  // Cron key lives in a sealed table; the function reads it with the
  // service role. No dashboard secret setup required.
  const kRes = await fetch(
    `${url}/rest/v1/app_secrets?key_name=eq.push_cron&select=key_value`,
    { headers: admin },
  );
  const kRows = await kRes.json();
  const dbCronKey =
    (kRows as { key_value: string }[])?.[0]?.key_value ?? "";
  if (!dbCronKey || req.headers.get("x-cron-key") !== dbCronKey) {
    return new Response(JSON.stringify({ error: "FORBIDDEN" }), {
      status: 403,
      headers: CORS,
    });
  }

  const limit = 30;

  // 1. Fetch unpushed notifications (last 10 minutes).
  const nRes = await fetch(
    `${url}/rest/v1/notifications?pushed_at=is.null&created_at=gte.${
      new Date(Date.now() - 10 * 60 * 1000).toISOString()
    }&select=id,user_id,kind,payload&order=created_at.asc&limit=${limit}`,
    { headers: admin },
  );
  const notifications: {
    id: string;
    user_id: string;
    kind: string;
    payload: unknown;
  }[] = await nRes.json();

  if (notifications.length === 0) {
    return new Response(JSON.stringify({ pushed: 0 }), { headers: CORS });
  }

  // 2. Service account for FCM v1 (sealed app_secrets table).
  const sRes = await fetch(
    `${url}/rest/v1/app_secrets?key_name=eq.fcm_service_account&select=key_value`,
    { headers: admin },
  );
  const sRows = await sRes.json();
  const saRaw = (sRows as { key_value: string }[])?.[0]?.key_value ?? null;
  if (!saRaw) {
    return new Response(
      JSON.stringify({ pushed: 0, note: "FCM not configured yet" }),
      { headers: CORS },
    );
  }
  let serviceAccount: Record<string, string>;
  try {
    serviceAccount = JSON.parse(saRaw);
  } catch (_e) {
    return new Response(
      JSON.stringify({ error: "BAD_SERVICE_ACCOUNT" }),
      { status: 500, headers: CORS },
    );
  }

  let accessToken: string;
  try {
    accessToken = await getAccessToken(serviceAccount);
  } catch (e) {
    return new Response(
      JSON.stringify({ error: String(e).slice(0, 200) }),
      { status: 500, headers: CORS },
    );
  }

  const fcmProject = serviceAccount.project_id;
  let pushed = 0;
  let failed = 0;

  for (const n of notifications) {
    try {
      // FCM tokens for this user.
      const tRes = await fetch(
        `${url}/rest/v1/push_tokens?user_id=eq.${n.user_id}&select=token`,
        { headers: admin },
      );
      const tokens: { token: string }[] = await tRes.json();
      if (tokens.length === 0) {
        // No devices: mark pushed so we never retry.
        await fetch(`${url}/rest/v1/notifications?id=eq.${n.id}`, {
          method: "PATCH",
          headers: {
            ...admin,
            "Content-Type": "application/json",
            Prefer: "return=minimal",
          },
          body: JSON.stringify({ pushed_at: new Date().toISOString() }),
        });
        continue;
      }

      const { title, body } = template(n.kind);
      // Routing keys only: kind + the conversation/group UUID when the
      // payload carries one, so a tap can deep-link. FCM requires string
      // values; no room names, previews or Animal IDs ever ride along
      // (security rule 8).
      const payload =
        n.payload && typeof n.payload === "object"
          ? (n.payload as Record<string, unknown>)
          : {};
      const data: Record<string, string> = { kind: n.kind };
      if (typeof payload.conversation_id === "string") {
        data.conversation_id = payload.conversation_id;
      }
      if (typeof payload.group_id === "string") {
        data.group_id = payload.group_id;
      }
      for (const t of tokens) {
        const fcmRes = await fetch(
          `https://fcm.googleapis.com/v1/projects/${fcmProject}/messages:send`,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              Authorization: `Bearer ${accessToken}`,
            },
            body: JSON.stringify({
              message: {
                token: t.token,
                notification: { title, body },
                data,
                android: { priority: "high" },
              },
            }),
          },
        );
        if (fcmRes.ok) {
          pushed++;
        } else {
          const errText = await fcmRes.text();
          // Permanently invalid token: drop it.
          if (errText.includes("UNREGISTERED") || fcmRes.status === 404) {
            await fetch(`${url}/rest/v1/push_tokens?token=eq.${t.token}`, {
              method: "DELETE",
              headers: admin,
            });
          }
          failed++;
        }
      }

      await fetch(`${url}/rest/v1/notifications?id=eq.${n.id}`, {
        method: "PATCH",
        headers: {
          ...admin,
          "Content-Type": "application/json",
          Prefer: "return=minimal",
        },
        body: JSON.stringify({ pushed_at: new Date().toISOString() }),
      });
    } catch (_e) {
      failed++;
    }
  }

  return new Response(JSON.stringify({ pushed, failed }), { headers: CORS });
});
