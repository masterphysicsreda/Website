// AI marking for the Biology Student Portal (Supabase Edge Function "mark").
// Auth: the portal's own session token (checked by portal_ai_allow, which also enforces a daily cap).
// The Anthropic key stays on the server: set the secret ANTHROPIC_API_KEY in Supabase.
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const MARKER = "You are a kind, precise high-school biology teacher";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ code: "method" }, 405);
  let body: { token?: string; prompt?: string };
  try { body = await req.json(); } catch { return json({ code: "bad_request" }, 400); }
  const token = String(body.token || ""), prompt = String(body.prompt || "");
  if (!/^[0-9a-f-]{36}$/i.test(token)) return json({ code: "not_granted" }, 401);
  if (!prompt.startsWith(MARKER) || prompt.length > 9000) return json({ code: "bad_request" }, 400);

  const url = Deno.env.get("SUPABASE_URL")!;
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || Deno.env.get("SUPABASE_ANON_KEY")!;
  const allow = await fetch(`${url}/rest/v1/rpc/portal_ai_allow`, {
    method: "POST",
    headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ p_token: token }),
  });
  if (!allow.ok) return json({ code: "not_granted" }, 401);
  const a = await allow.json();
  if (!a?.ok) return json({ code: "rate_limited" }, 429);

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) return json({ code: "no_key" }, 503);
  const model = Deno.env.get("ANTHROPIC_MODEL") || "claude-haiku-5-5";
  try {
    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": apiKey, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({ model, max_tokens: 600, system: "You mark student answers. Reply with ONLY the JSON object requested, no other text.", messages: [{ role: "user", content: prompt }] }),
    });
    if (!r.ok) return json({ code: "upstream", status: r.status }, 502);
    const d = await r.json();
    const text = (d.content || []).filter((c: { type: string }) => c.type === "text").map((c: { text: string }) => c.text).join("");
    return json({ text });
  } catch (_e) {
    return json({ code: "upstream" }, 502);
  }
});
