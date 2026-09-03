// JungleChat — login Edge Function.
//
// Exchanges (Animal ID + credential) for a standard Supabase session.
// The credential is either:
//   • the recovery credential (canonical GoTrue password), or
//   • a user-chosen password set via the app.
// The internal login email is never exposed to the client. All failure modes
// are indistinguishable by design ("The Animal ID or credential is incorrect.").
// Rate limiting lives server-side in service_verify_login / service_verify_login_password.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const GENERIC_LOGIN_FAILED = "LOGIN_FAILED";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function clientIp(req: Request): string {
  return req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    req.headers.get("x-real-ip") ?? "unknown";
}

// Resolve the internal identity email via the server-side verify RPCs. This
// validates the animal, enforces rate limits, and maps Animal ID -> internal
// email WITHOUT ever sending that email to the client.
async function resolveInternalEmail(
  admin: ReturnType<typeof createClient>,
  animalId: string,
  credential: string,
  ip: string,
): Promise<string | null> {
  const r1 = await admin.rpc("service_verify_login", {
    p_display_animal_id: animalId,
    p_recovery_credential: credential,
    p_client_ip: ip,
  });
  if (r1.data != null) {
    return typeof r1.data === "string" ? r1.data : (r1.data as { email?: string })?.email ?? null;
  }
  // Fall back to the user-chosen password path.
  const r2 = await admin.rpc("service_verify_login_password", {
    p_display_animal_id: animalId,
    p_password: credential,
    p_client_ip: ip,
  });
  if (r2.data != null) {
    return typeof r2.data === "string" ? r2.data : (r2.data as { email?: string })?.email ?? null;
  }
  return null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "METHOD_NOT_ALLOWED" }), {
      status: 405, headers: { ...CORS, "Content-Type": "application/json" },
    });
  }

  try {
    const body = await req.json();
    const animalId = String(body?.animalId ?? "").toUpperCase().trim();
    const credential = String(body?.credential ?? "").toUpperCase().replace(/\s+/g, "");

    if (!animalId || !credential) {
      return new Response(JSON.stringify({ error: GENERIC_LOGIN_FAILED }), {
        status: 401, headers: { ...CORS, "Content-Type": "application/json" },
      });
    }

    const url = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    const internalEmail = await resolveInternalEmail(admin, animalId, credential, clientIp(req));
    if (internalEmail == null) {
      return new Response(JSON.stringify({ error: GENERIC_LOGIN_FAILED }), {
        status: 401, headers: { ...CORS, "Content-Type": "application/json" },
      });
    }

    // Mint a standard GoTrue session against the internal identity. Both the
    // recovery credential and the user password are valid GoTrue passwords.
    const res = await fetch(`${url}/auth/v1/token?grant_type=password`, {
      method: "POST",
      headers: { "Content-Type": "application/json", apikey: anonKey },
      body: JSON.stringify({ email: internalEmail, password: credential }),
    });

    if (!res.ok) {
      return new Response(JSON.stringify({ error: GENERIC_LOGIN_FAILED }), {
        status: 401, headers: { ...CORS, "Content-Type": "application/json" },
      });
    }

    const session = await res.json();
    return new Response(JSON.stringify({ session }), {
      headers: { ...CORS, "Content-Type": "application/json" },
    });
  } catch (_err) {
    return new Response(JSON.stringify({ error: GENERIC_LOGIN_FAILED }), {
      status: 401, headers: { ...CORS, "Content-Type": "application/json" },
    });
  }
});
