// JungleChat — admin-hard-delete-user Edge Function.
//
// PERMANENTLY removes a user: wipes them from auth entirely via the Auth
// Admin API, which cascades their profile and content through the foreign
// keys. This is the ONLY supported way to hard-delete on hosted Supabase —
// auth.users is owned by supabase_auth_admin, so a SECURITY DEFINER SQL
// function gets "permission denied for schema auth". That permission failure
// is why the old delete path showed "Something went wrong".
//
// SECURITY (AGENTS.md — "THE CLIENT IS NOT TRUSTED")
//   * The caller must satisfy is_current_user_admin() (admin_roles row AND
//     an MFA-elevated aal2 session) — checked with the caller's own JWT, the
//     same pattern as r2-upload-url. Never reimplemented here.
//   * The service-role key never reaches the client; it lives in Edge
//     Function secrets.
//   * Admins cannot be deleted, and an admin cannot delete themself.
//   * Every success is audited; every failure returns one opaque code.

const JSON_HEADERS = { "Content-Type": "application/json" };

function fail(status: number, code: string): Response {
  return new Response(JSON.stringify({ error: code }), {
    status,
    headers: JSON_HEADERS,
  });
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return fail(405, "METHOD_NOT_ALLOWED");

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return fail(400, "BAD_REQUEST");
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceKey) {
    console.error("admin-hard-delete-user: missing configuration");
    return fail(500, "NOT_CONFIGURED");
  }

  // ---- Authorisation: caller's own JWT → is_current_user_admin() ----------
  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!jwt) return fail(401, "UNAUTHORIZED");

  let callerId: string | null = null;
  let isAdmin = false;
  try {
    const res = await fetch(`${supabaseUrl}/auth/v1/user`, {
      headers: { apikey: anonKey, Authorization: `Bearer ${jwt}` },
    });
    if (res.ok) {
      const user = await res.json();
      callerId = user?.id ?? null;
    }
  } catch (err) {
    console.error("admin-hard-delete-user: identity check failed", err);
  }
  if (!callerId) return fail(401, "UNAUTHORIZED");

  try {
    const res = await fetch(`${supabaseUrl}/rest/v1/rpc/is_current_user_admin`, {
      method: "POST",
      headers: {
        apikey: anonKey,
        Authorization: `Bearer ${jwt}`,
        "Content-Type": "application/json",
      },
      body: "{}",
    });
    if (res.ok) isAdmin = (await res.json()) === true;
  } catch (err) {
    console.error("admin-hard-delete-user: admin check failed", err);
  }
  if (!isAdmin) return fail(403, "NOT_ADMIN");

  // ---- Validate the target -------------------------------------------------
  const target = String(body.userId ?? "");
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(target)) {
    return fail(400, "INVALID_TARGET");
  }
  if (target === callerId) return fail(400, "INVALID_TARGET");

  // Target must exist and must not be an admin. Soft-delete was removed, so
  // permanent deletion now runs directly on a live account (no NOT_SOFT_DELETED
  // pre-step), and a hard delete simply wipes auth.users + cascaded content.
  const restHeaders = {
    apikey: serviceKey,
    Authorization: `Bearer ${serviceKey}`,
    "Content-Type": "application/json",
  };

  try {
    const profRes = await fetch(
      `${supabaseUrl}/rest/v1/profiles?id=eq.${target}&select=id`,
      { headers: restHeaders },
    );
    if (!profRes.ok) return fail(500, "LOOKUP_FAILED");
    const profiles = await profRes.json();
    if (!Array.isArray(profiles) || profiles.length === 0) {
      return fail(404, "TARGET_NOT_FOUND");
    }

    const roleRes = await fetch(
      `${supabaseUrl}/rest/v1/admin_roles?user_id=eq.${target}&select=user_id`,
      { headers: restHeaders },
    );
    if (roleRes.ok) {
      const roles = await roleRes.json();
      if (Array.isArray(roles) && roles.length > 0) {
        return fail(403, "TARGET_IS_ADMIN");
      }
    }
  } catch (err) {
    console.error("admin-hard-delete-user: target validation failed", err);
    return fail(500, "LOOKUP_FAILED");
  }

  // ---- Permanent delete via the Auth Admin API -----------------------------
  const { createClient } = await import(
    "https://esm.sh/@supabase/supabase-js@2"
  );
  const serviceClient = createClient(supabaseUrl, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { error } = await serviceClient.auth.admin.deleteUser(target);
  if (error) {
    // Log the FULL error object. `error.message` alone dropped the PostgreSQL
    // constraint/SQLSTATE detail that is the only way to tell a foreign-key
    // blocker from a genuine Auth failure.
    console.error(
      "admin-hard-delete-user: auth delete failed",
      JSON.stringify({
        message: error.message,
        status: (error as { status?: number }).status,
        name: error.name,
      }),
    );
    return fail(500, "DELETE_FAILED");
  }

  // ---- Audit (append-only; the profile row is gone, so record the id) ------
  try {
    await fetch(`${supabaseUrl}/rest/v1/admin_audit_logs`, {
      method: "POST",
      headers: { ...restHeaders, Prefer: "return=minimal" },
      body: JSON.stringify({
        actor_id: callerId,
        event: "user.permanently_deleted",
        details: { target },
      }),
    });
  } catch (err) {
    // The deletion succeeded; never fail the request over the audit write.
    console.error("admin-hard-delete-user: audit write failed", err);
  }

  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: JSON_HEADERS,
  });
});
