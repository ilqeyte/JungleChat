// JungleChat — create-account Edge Function.
//
// Creates an anonymous account:
//   1. Validates the chosen animal (server-side whitelist).
//   2. Generates the recovery credential with Web Crypto CSPRNG —
//      20 chars from a 32-symbol unambiguous alphabet (~100 bits),
//      formatted XXXX-XXXX-XXXX-XXXX-XXXX.
//   3. Calls service_create_account (atomic Animal ID allocation + bcrypt).
//   4. Returns { animalId, recoveryCredential } EXACTLY ONCE.
// The raw credential is never stored or logged anywhere.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ANIMALS = new Set([
  "Wolf", "Lion", "Eagle", "Tiger", "Fox", "Bear", "Owl", "Panther", "Falcon",
  "Camel", "Elephant", "Shark", "Snake", "Crocodile", "Deer", "Horse",
  "Gorilla", "Hyena", "Cheetah", "Rabbit", "Panda", "Zebra", "Leopard",
  "Hawk", "Parrot", "Dolphin", "Whale", "Turtle", "Monkey", "Buffalo",
]);

// No I, L, O, U, 0, 1 — unambiguous when read aloud or handwritten.
const ALPHABET = "ABCDEFGHJKMNPQRSTVWXYZ23456789";

function generateRecoveryCredential(): string {
  const bytes = new Uint8Array(20);
  crypto.getRandomValues(bytes);
  const chars = Array.from(bytes, (b) => ALPHABET[b % ALPHABET.length]);
  // PRD format: K7QM-4X9P-V2RT-8N6C-5LWA -> five groups of four.
  // NOTE: `return` and the expression MUST stay on one line — a comment
  // between them triggers automatic semicolon insertion and the function
  // would return undefined (the bug that broke every signup).
  return [0, 1, 2, 3, 4]
    .map((i) => chars.slice(i * 4, i * 4 + 4).join(""))
    .join("-");
}

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function clientIp(req: Request): string {
  return req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    req.headers.get("x-real-ip") ?? "unknown";
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
    const rawAnimal = String(body?.animal ?? "").trim();

    // Normalize to catalog capitalization ("wolf" -> "Wolf").
    const animal = rawAnimal.charAt(0).toUpperCase() + rawAnimal.slice(1).toLowerCase();
    if (!ANIMALS.has(animal)) {
      return new Response(JSON.stringify({ error: "INVALID_ANIMAL" }), {
        status: 400, headers: { ...CORS, "Content-Type": "application/json" },
      });
    }

    const credential = generateRecoveryCredential();
    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data, error } = await admin.rpc("service_create_account", {
      p_animal: animal,
      p_recovery_credential: credential,
      p_client_ip: clientIp(req),
    });

    if (error != null || data == null || (data as unknown[]).length === 0) {
      const code = error?.message?.includes("RATE_LIMITED")
        ? "RATE_LIMITED" : "ACCOUNT_CREATION_FAILED";
      return new Response(JSON.stringify({ error: code }), {
        status: code === "RATE_LIMITED" ? 429 : 500,
        headers: { ...CORS, "Content-Type": "application/json" },
      });
    }

    const row = (data as { user_id: string; display_animal_id: string }[])[0];
    return new Response(
      JSON.stringify({
        userId: row.user_id,
        animalId: row.display_animal_id,
        recoveryCredential: credential,
      }),
      { headers: { ...CORS, "Content-Type": "application/json" } },
    );
  } catch (_err) {
    return new Response(JSON.stringify({ error: "ACCOUNT_CREATION_FAILED" }), {
      status: 500, headers: { ...CORS, "Content-Type": "application/json" },
    });
  }
});
