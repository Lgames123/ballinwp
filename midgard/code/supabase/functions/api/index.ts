// =============================================================================
// MidgardSurvivors `api` Edge Function (Deno) - reference sketch, not drop-in.
//
// Route map (all require `Authorization: Bearer <supabase access token>`):
//   GET  /profile                     -> { profile, rev, now }
//   PUT  /prefs                       -> whitelisted device prefs only
//   POST /profile/actions             -> batched meta commands (shop, refine, fuse...)
//   POST /runs                        -> start a run, returns a ticket { id, seed, ranked }
//   POST /runs/:id/checkpoint         -> heartbeat batch { cps: [...] }
//   PUT  /runs/:id/snapshot           -> mid-run save (replaces user://profile.run)
//   POST /runs/:id/suspend | /resume  -> pause and continue on any device
//   POST /runs/:id/finish             -> validate, grant rewards, write boards
//
// Headers every request sends (same idea as Pokebonk's X-Device / X-Client):
//   X-Device: random 32-hex id generated once per install
//   X-Client: game version string (Updater.version)
// =============================================================================
import { createClient } from "jsr:@supabase/supabase-js@2";
import { validateRun, type RunContext } from "./validator.ts";
import { applyAction, type Action } from "./actions.ts";      // one handler per command
import { computeRewards } from "./rewards.ts";                // mirrors GameData formulas

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const MIN_CLIENT = Deno.env.get("MIN_CLIENT") ?? "0.1.280";   // bump on every security-relevant patch
const CP_BATCH_MAX = 300;          // Pokebonk uses the same cap per checkpoint request
const RUN_TTL_MS = 4 * 3600_000;   // active run expires after 4 h without finish
const FINISH_GRACE_MS = 48 * 3600_000; // a queued finish may arrive up to 48 h late

type Ctx = { uid: string; device: string; client: string; now: number };

// ----------------------------------------------------------------- helpers --
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

function newer(a: string, b: string): boolean {             // same rule as Updater._newer
  const pa = a.split(".").map(Number), pb = b.split(".").map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (d) return d > 0;
  }
  return false;
}

async function auth(req: Request): Promise<Ctx | Response> {
  const token = req.headers.get("authorization")?.replace(/^Bearer /, "");
  if (!token) return json(401, { error: "auth" });
  const { data, error } = await db.auth.getUser(token);
  if (error || !data.user) return json(401, { error: "auth" });

  const client = req.headers.get("x-client") ?? "0";
  if (newer(MIN_CLIENT, client)) return json(426, { error: "update", min: MIN_CLIENT });

  const device = req.headers.get("x-device") ?? "";
  if (!/^[\w-]{16,64}$/.test(device)) return json(400, { error: "device" });

  const { data: acc } = await db.from("accounts").select("banned_until, ban_reason").eq("id", data.user.id).single();
  if (acc?.banned_until && new Date(acc.banned_until).getTime() > Date.now())
    return json(403, { error: "banned", banned: { until: acc.banned_until, reason: acc.ban_reason } });

  await db.from("devices").upsert(
    { account_id: data.user.id, device_id: device, last_seen: new Date().toISOString() },
    { onConflict: "account_id,device_id" },
  );
  return { uid: data.user.id, device, client, now: Date.now() };
}

// Optimistic-concurrency write of the profile + ledger row in one RPC
// (`apply_profile_delta` is a small plpgsql function that checks rev, merges
// `data`, bumps rev and inserts the ledger row in the same transaction).
async function commit(uid: string, ifRev: number, data: unknown, source: string, ref: string, delta: unknown) {
  const { data: rev, error } = await db.rpc("apply_profile_delta", {
    p_account: uid, p_if_rev: ifRev, p_data: data, p_source: source, p_ref: ref, p_delta: delta,
  });
  if (error) throw Object.assign(new Error(error.message), { status: error.code === "40001" ? 409 : 500 });
  return rev as number;
}

// ------------------------------------------------------------------ routes --
async function getProfile(c: Ctx) {
  const { data } = await db.from("profiles").select("data, rev").eq("account_id", c.uid).single();
  return json(200, { profile: data?.data, rev: data?.rev, now: c.now }); // `now` lets the client measure clock skew
}

async function postActions(c: Ctx, body: { actions: Action[]; key: string; if_rev: number }) {
  if (!body.key || body.actions?.length > 50) return json(400, { error: "bad_request" });
  const seen = await db.from("action_keys").select("response").eq("account_id", c.uid).eq("key", body.key).maybeSingle();
  if (seen.data) return json(200, seen.data.response);                    // retry-safe

  const { data: p } = await db.from("profiles").select("data, rev").eq("account_id", c.uid).single();
  if (!p) return json(404, { error: "profile" });
  if (body.if_rev !== p.rev) return json(409, { error: "stale", rev: p.rev, profile: p.data });

  const state = structuredClone(p.data);
  const delta: Record<string, unknown>[] = [];
  for (const a of body.actions) {
    const r = applyAction(state, a);           // throws {status:422, error:'not_enough_zeny'} etc.
    delta.push(r.delta);
  }
  const rev = await commit(c.uid, p.rev, state, "action", body.key, delta);
  const response = { profile: state, rev };
  await db.from("action_keys").insert({ account_id: c.uid, key: body.key, response });
  return json(200, response);
}

async function startRun(c: Ctx, body: { key: string; mode: string; class_id: string; stage_id: string; danger: number; party_id?: string }) {
  // Idempotent: the same key returns the same ticket (client retries on timeout).
  const prev = await db.from("runs").select("id, seed, ranked").eq("account_id", c.uid).eq("idem_key", body.key).maybeSingle();
  if (prev.data) return json(200, prev.data);

  const { data: p } = await db.from("profiles").select("data").eq("account_id", c.uid).single();
  if (!p) return json(404, { error: "profile" });
  // Server decides what the player may bring: class unlocked, stage unlocked, danger allowed.
  const loadout = snapshotLoadout(p.data, body.class_id);       // gear, cards, pet, pacts, stats from the PROFILE
  if (!loadout) return json(422, { error: "locked" });

  // Parallel runs: only one active solo run per account (co-op runs share party_id).
  await db.from("runs").update({ status: "expired" })
    .eq("account_id", c.uid).eq("status", "active").lt("started_at", new Date(c.now - RUN_TTL_MS).toISOString());

  const seed = crypto.getRandomValues(new Uint32Array(1))[0];
  const { data: run, error } = await db.from("runs").insert({
    account_id: c.uid, idem_key: body.key, mode: body.mode, class_id: body.class_id, stage_id: body.stage_id,
    danger: body.danger, party_id: body.party_id ?? null, seed, client_version: c.client, loadout,
  }).select("id, seed, ranked").single();
  if (error) return json(500, { error: "db" });
  return json(200, { ...run, loadout });     // client builds the hero FROM this loadout, not from local data
}

async function checkpoint(c: Ctx, runId: string, body: { cps: { seq: number; t: number; [k: string]: unknown }[] }) {
  if (!Array.isArray(body.cps) || body.cps.length > CP_BATCH_MAX) return json(400, { error: "bad_request" });
  const { data: run } = await db.from("runs").select("account_id, status").eq("id", runId).single();
  if (!run || run.account_id !== c.uid) return json(404, { error: "run" });
  if (run.status !== "active") return json(409, { error: "closed" });
  const rows = body.cps.map((cp) => ({ run_id: runId, seq: cp.seq, t: cp.t, payload: cp }));
  await db.from("run_checkpoints").upsert(rows, { onConflict: "run_id,seq", ignoreDuplicates: true });
  await db.from("runs").update({ last_cp_at: new Date().toISOString() }).eq("id", runId);
  return new Response(null, { status: 204 });
}

async function finish(c: Ctx, runId: string, body: { result: Record<string, unknown>; cps?: unknown[] }) {
  const { data: run } = await db.from("runs").select("*").eq("id", runId).single();
  if (!run || run.account_id !== c.uid) return json(404, { error: "run" });
  if (run.status === "finished") return json(409, { error: "already_saved", rewards: run.rewards }); // client treats 409 as success
  if (c.now - new Date(run.started_at).getTime() > RUN_TTL_MS + FINISH_GRACE_MS) return json(410, { error: "expired" });

  if (body.cps?.length) await checkpoint(c, runId, { cps: body.cps as never });
  const { data: cps } = await db.from("run_checkpoints").select("seq, t, server_at, payload").eq("run_id", runId).order("seq");

  const ctx: RunContext = { run, checkpoints: cps ?? [], result: body.result, now: c.now };
  const verdict = await validateRun(db, ctx);         // { flags, ranked, reject, ban }

  for (const f of verdict.flags)
    await db.from("flags").insert({ account_id: c.uid, run_id: runId, rule: f.rule, severity: f.severity, details: f.details });

  if (verdict.reject) {
    await db.from("runs").update({ status: "rejected", flags: verdict.flags.map((f) => f.rule), finished_at: new Date().toISOString() }).eq("id", runId);
    return json(422, { error: "rejected" });          // generic message on purpose: do not tell which rule fired
  }

  const { data: p } = await db.from("profiles").select("data, rev").eq("account_id", c.uid).single();
  const state = structuredClone(p!.data);
  // Rewards are computed by the SERVER from validated, clamped telemetry (kills, time, danger, mvps),
  // never copied from a client-sent "zeny" field.
  const rewards = computeRewards(state, run, ctx.result, verdict);
  const rev = await commit(c.uid, p!.rev, state, "run", runId, rewards.delta);

  if (verdict.ranked) await writeBoards(c.uid, run, ctx.result, verdict);
  await db.from("runs").update({
    status: "finished", result: body.result, rewards: rewards.delta, ranked: verdict.ranked,
    flags: verdict.flags.map((f) => f.rule), finished_at: new Date().toISOString(),
  }).eq("id", runId);
  return json(200, { rewards: rewards.delta, profile: state, rev });
}

// ------------------------------------------------------------------ router --
Deno.serve(async (req) => {
  const url = new URL(req.url);
  const path = url.pathname.replace(/^\/api/, "");
  const c = await auth(req);
  if (c instanceof Response) return c;
  const body = req.method === "GET" ? undefined : await req.json().catch(() => ({}));
  try {
    let m: RegExpMatchArray | null;
    if (req.method === "GET" && path === "/profile") return await getProfile(c);
    if (req.method === "POST" && path === "/profile/actions") return await postActions(c, body);
    if (req.method === "POST" && path === "/runs") return await startRun(c, body);
    if ((m = path.match(/^\/runs\/([0-9a-f-]{36})\/checkpoint$/)) && req.method === "POST") return await checkpoint(c, m[1], body);
    if ((m = path.match(/^\/runs\/([0-9a-f-]{36})\/finish$/)) && req.method === "POST") return await finish(c, m[1], body);
    // ... /prefs, /runs/:id/snapshot, /suspend, /resume follow the same pattern
    return json(404, { error: "route" });
  } catch (e) {
    const s = (e as { status?: number }).status ?? 500;
    return json(s, { error: (e as Error).message });
  }
});

// Declared elsewhere in the function bundle:
declare function snapshotLoadout(profile: unknown, classId: string): Record<string, unknown> | null;
declare function writeBoards(uid: string, run: unknown, result: unknown, verdict: unknown): Promise<void>;
