import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "npm:@supabase/supabase-js@2"

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
}

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  })
}

async function sha256(value: string) {
  const bytes = new TextEncoder().encode(value)
  const digest = await crypto.subtle.digest("SHA-256", bytes)
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("")
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders })
  }

  if (req.method !== "POST") {
    return json({ error: "METHOD_NOT_ALLOWED" }, 405)
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")

  if (!supabaseUrl || !serviceRoleKey) {
    return json({ error: "SERVER_CONFIGURATION_ERROR" }, 500)
  }

  let body: { email?: string; password?: string; displayName?: string }

  try {
    body = await req.json()
  } catch {
    return json({ error: "INVALID_JSON" }, 400)
  }

  const email = (body.email ?? "").trim().toLowerCase()
  const password = body.password ?? ""
  const displayName = (body.displayName ?? "").trim()

  if (!email || !/^\S+@\S+\.\S+$/.test(email)) {
    return json({ error: "INVALID_EMAIL" }, 400)
  }

  if (password.length < 6 || password.length > 72) {
    return json({ error: "INVALID_PASSWORD" }, 400)
  }

  if (!displayName || displayName.length > 40) {
    return json({ error: "INVALID_DISPLAY_NAME" }, 400)
  }

  const ip =
    req.headers.get("cf-connecting-ip") ??
    req.headers.get("x-real-ip") ??
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    "unknown"
  const userAgent = req.headers.get("user-agent") ?? "unknown"
  const fingerprintHash = await sha256(`${ip}|${userAgent}`)

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  })

  const { data: slotAllowed, error: slotError } = await admin.rpc(
    "consume_registration_slot",
    { p_fingerprint_hash: fingerprintHash },
  )

  if (slotError) {
    console.error("Registration rate-limit check failed", slotError)
    return json({ error: "REGISTRATION_TEMPORARILY_UNAVAILABLE" }, 503)
  }

  if (!slotAllowed) {
    return json({ error: "RATE_LIMITED" }, 429)
  }

  const { data, error } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: {
      display_name: displayName,
      veira_email_verified: false,
    },
  })

  if (error) {
    const duplicate =
      error.message.toLowerCase().includes("already") ||
      error.message.toLowerCase().includes("registered") ||
      error.status === 422

    if (duplicate) {
      return json({ error: "EMAIL_ALREADY_REGISTERED" }, 409)
    }

    console.error("User creation failed", error)
    return json({ error: "REGISTRATION_FAILED" }, 400)
  }

  return json({
    ok: true,
    userId: data.user?.id ?? null,
  })
})
