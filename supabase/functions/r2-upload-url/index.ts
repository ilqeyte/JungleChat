// JungleChat — r2-upload-url Edge Function.
//
// Mints a short-lived pre-signed PUT URL for the Cloudflare R2 `updates`
// bucket so the admin sheet can push a release APK straight from the device
// to R2 without the bytes ever touching Supabase.
//
// WHY THIS EXISTS
//   The APK is ~127 MiB. Supabase Storage's free plan caps the global file
//   size limit at 50 MB and a per-bucket limit may never exceed it, so no
//   bucket configuration can hold the file. Proxying the upload through an
//   Edge Function is equally impossible — the request body limit is far lower
//   than 127 MiB. So this function returns only a signed URL; the device then
//   PUTs directly to R2.
//
// SECURITY (AGENTS.md — "THE CLIENT IS NOT TRUSTED")
//   * The caller must satisfy private.is_admin(): an admin_roles row AND an
//     MFA-elevated (aal2) session. That rule is enforced by the DATABASE via
//     public.is_current_user_admin(), never reimplemented here, so the two
//     can never drift apart.
//   * The R2 credentials live only in Edge Function secrets. An APK can be
//     decompiled, so anything compiled into the Flutter binary is public.
//   * The object key is generated SERVER-SIDE. The client cannot choose a
//     path, traverse directories, or overwrite someone else's object.
//   * The signed URL is PUT-only, scoped to that single key, and expires.
//   * Failures return one opaque code. No user enumeration, no detail.

const JSON_HEADERS = { "Content-Type": "application/json" };

// Generous enough for the current APK with room to grow, small enough that a
// leaked URL cannot park a huge object in the bucket.
const MAX_BYTES = 512 * 1024 * 1024;
const ALLOWED_TYPES = new Set([
  "application/vnd.android.package-archive",
  "application/octet-stream",
]);
const URL_TTL_SECONDS = 1800;

function fail(status: number, code: string): Response {
  return new Response(JSON.stringify({ error: code }), {
    status,
    headers: JSON_HEADERS,
  });
}

// ---------------------------------------------------------------------------
// AWS SigV4 (pre-signing). R2 is S3-compatible; the region is always "auto".
// ---------------------------------------------------------------------------
const encoder = new TextEncoder();

function hex(buf: ArrayBuffer | Uint8Array): string {
  const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  let out = "";
  for (const b of bytes) out += b.toString(16).padStart(2, "0");
  return out;
}

// TS 5.7 gave Uint8Array a buffer-type parameter. `TextEncoder.encode()`
// returns Uint8Array<ArrayBufferLike>, which ALSO covers SharedArrayBuffer,
// and WebCrypto's BufferSource only accepts views backed by a plain
// ArrayBuffer — hence "not assignable to parameter of type 'BufferSource'".
//
// Every value reaching here is backed by a regular ArrayBuffer (this file
// builds them with TextEncoder / new Uint8Array), so narrowing the type is
// semantically correct. It is a compile-time-only assertion: no copy, no
// runtime cost.
function toBufferSource(data: Uint8Array | ArrayBuffer | string): BufferSource {
  const bytes = typeof data === "string"
    ? encoder.encode(data)
    : data instanceof Uint8Array
    ? data
    : new Uint8Array(data);
  return bytes as Uint8Array<ArrayBuffer>;
}

async function sha256Hex(data: string | Uint8Array): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", toBufferSource(data)));
}

async function hmac(key: Uint8Array, msg: string): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey(
    "raw",
    toBufferSource(key),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, toBufferSource(msg)));
}

// RFC 3986. Distinct from encodeURIComponent, which leaves !'()* alone.
// `encodeSlash = false` is for the canonical URI, where "/" is a separator.
function rfc3986(str: string, encodeSlash = true): string {
  let out = "";
  for (const byte of encoder.encode(str)) {
    const ch = String.fromCharCode(byte);
    if (
      (byte >= 0x41 && byte <= 0x5a) || // A-Z
      (byte >= 0x61 && byte <= 0x7a) || // a-z
      (byte >= 0x30 && byte <= 0x39) || // 0-9
      ch === "_" || ch === "-" || ch === "~" || ch === "."
    ) {
      out += ch;
    } else if (ch === "/") {
      out += encodeSlash ? "%2F" : "/";
    } else {
      out += "%" + byte.toString(16).toUpperCase().padStart(2, "0");
    }
  }
  return out;
}

async function presignPut(args: {
  host: string;
  bucket: string;
  key: string;
  accessKeyId: string;
  secretAccessKey: string;
  expiresIn: number;
  now: Date;
}): Promise<string> {
  const { host, bucket, key, accessKeyId, secretAccessKey, expiresIn, now } = args;
  const region = "auto";
  const service = "s3";

  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, "");
  const dateStamp = amzDate.slice(0, 8);
  const scope = `${dateStamp}/${region}/${service}/aws4_request`;

  // The body is streamed from the device and its hash is unknowable here, so
  // the payload is flagged unsigned — the standard approach for pre-signed
  // PUTs. Only "host" is signed, which lets the client send whatever
  // content-type/content-length it needs.
  const payloadHash = "UNSIGNED-PAYLOAD";
  const query: Record<string, string> = {
    "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
    "X-Amz-Credential": `${accessKeyId}/${scope}`,
    "X-Amz-Date": amzDate,
    "X-Amz-Expires": String(expiresIn),
    "X-Amz-SignedHeaders": "host",
  };

  // `key` is built server-side from [0-9a-f-] plus "v" and ".apk", so the
  // canonical URI needs no escaping. rfc3986 is applied regardless so a
  // future change to key generation cannot silently break signing.
  const canonicalUri = rfc3986(`/${bucket}/${key}`, false);
  const canonicalQuery = Object.keys(query)
    .sort()
    .map((k) => `${rfc3986(k)}=${rfc3986(query[k])}`)
    .join("&");

  const canonicalRequest = [
    "PUT",
    canonicalUri,
    canonicalQuery,
    `host:${host}\n`, // canonical headers
    "host", // signed headers
    payloadHash,
  ].join("\n");

  const stringToSign = [
    "AWS4-HMAC-SHA256",
    amzDate,
    scope,
    await sha256Hex(canonicalRequest),
  ].join("\n");

  let k = await hmac(encoder.encode(`AWS4${secretAccessKey}`), dateStamp);
  k = await hmac(k, region);
  k = await hmac(k, service);
  k = await hmac(k, "aws4_request");
  const signature = hex(await hmac(k, stringToSign));

  return `https://${host}${canonicalUri}?${canonicalQuery}&X-Amz-Signature=${signature}`;
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------
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
  const accountId = Deno.env.get("R2_ACCOUNT_ID");
  const accessKeyId = Deno.env.get("R2_ACCESS_KEY_ID");
  const secretAccessKey = Deno.env.get("R2_SECRET_ACCESS_KEY");
  const bucket = Deno.env.get("R2_BUCKET") ?? "updates";
  const publicBase = Deno.env.get("R2_PUBLIC_BASE");

  if (
    !supabaseUrl || !anonKey || !accountId || !accessKeyId ||
    !secretAccessKey || !publicBase
  ) {
    console.error("r2-upload-url: missing configuration");
    return fail(500, "NOT_CONFIGURED");
  }

  // ---- Authorisation -----------------------------------------------------
  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!jwt) return fail(401, "UNAUTHORIZED");

  // The user's own JWT is forwarded so PostgREST resolves auth.uid() and
  // auth.jwt() as THIS caller. The anon key is only the gateway's apikey and
  // must NOT be the service role key, which would make auth.uid() null and
  // silently deny every admin.
  let isAdmin = false;
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
    console.error("r2-upload-url: admin check failed", err);
  }
  if (!isAdmin) return fail(403, "NOT_ADMIN");

  // ---- Validate the request ---------------------------------------------
  const size = Number(body.size);
  if (!Number.isFinite(size) || size <= 0 || size > MAX_BYTES) {
    return fail(400, "INVALID_SIZE");
  }

  const contentType = String(body.contentType ?? "");
  if (!ALLOWED_TYPES.has(contentType)) return fail(400, "INVALID_TYPE");

  const versionCode = Number(body.versionCode);
  if (!Number.isInteger(versionCode) || versionCode < 1) {
    return fail(400, "INVALID_VERSION");
  }

  // ---- Build the object key server-side ------------------------------------
  // Only [0-9a-f], "-", "v" and ".apk" can appear, so no traversal, no
  // escaping, and no collision with a previous release.
  const key = `v${versionCode}-${crypto.randomUUID()}.apk`;
  const host = `${accountId}.r2.cloudflarestorage.com`;

  try {
    const uploadUrl = await presignPut({
      host,
      bucket,
      key,
      accessKeyId,
      secretAccessKey,
      expiresIn: URL_TTL_SECONDS,
      now: new Date(),
    });

    return new Response(
      JSON.stringify({
        key,
        uploadUrl,
        publicUrl: `${publicBase.replace(/\/+$/, "")}/${rfc3986(key, false)}`,
        expiresIn: URL_TTL_SECONDS,
      }),
      { status: 200, headers: JSON_HEADERS },
    );
  } catch (err) {
    console.error("r2-upload-url: signing failed", err);
    return fail(500, "SIGNING_FAILED");
  }
});
