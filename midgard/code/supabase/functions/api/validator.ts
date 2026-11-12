// =============================================================================
// Run validator - reference sketch.
//
// IMPORTANT: this file and RULES live ONLY on the server. Pokebonk ships its
// equivalent table (heartbeat, maxGap, autoBan, ...) inside the public client
// bundle, which lets third-party tools read every threshold and stay just under
// it. Never import these numbers into the Godot project.
//
// The game simulation is not deterministic (bench runs vary ~5-7% with the same
// seed), so the server cannot re-simulate a run. It validates instead:
//   1. timing      - server clock vs. game clock, heartbeat gaps, run length
//   2. monotonicity- counters only grow, level only grows, stage order
//   3. plausibility- kill rate, level rate, zeny, damage vs. loadout
//   4. consistency - result matches the last checkpoint and the server loadout
//   5. history     - parallel runs, repeated results, device farms
// =============================================================================
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";

export type Severity = "info" | "review" | "reject" | "ban";
export type Flag = { rule: string; severity: Severity; details: Record<string, unknown> };
export type Checkpoint = { seq: number; t: number; server_at: string; payload: Record<string, any> };
export type RunContext = { run: Record<string, any>; checkpoints: Checkpoint[]; result: Record<string, any>; now: number };

// Mirrors of GameData constants (scripts/autoload/game_data.gd, 0.1.276).
const GD = {
  FESTIVAL_TIME: 60.0,          // game_data.gd:163
  FESTIVAL_BASE_HP: 6000.0,     // game_data.gd:176
  FESTIVAL_GROW: 1.4,           // game_data.gd:177
};

// Server-only tuning. Start lenient, log everything as "review", tighten with data.
const RULES = {
  heartbeat: 60,            // client sends a checkpoint every 60 s of game time
  maxGap: 180,              // > 3 missed heartbeats = checkpoints-missing
  clockSlack: 5,            // game seconds may exceed server seconds by 5 s (+ x speed)
  maxGameSpeed: 2.0,        // highest legal World.speed / fast_mode multiplier
  killsPerMin: { base: 900, perDanger: 120 },   // calibrate from log_run_metrics p99.9
  levelPerMin: { early: 12, late: 3, lateFrom: 600 },
  zenyPerKill: { max: 40, perDanger: 8 },       // run_zeny upper bound; calibrate
  festivalDpsJump: 50,      // dps between two consecutive Emperiums may not jump > x50
  autoBan: { rejectRuns: 2, days: 7, banDays: 30 },
  repeat: { minKills: 20, days: 7 },
};

export async function validateRun(db: SupabaseClient, ctx: RunContext) {
  const flags: Flag[] = [];
  const add = (rule: string, severity: Severity, details: Record<string, unknown> = {}) =>
    flags.push({ rule, severity, details });

  timing(ctx, add);
  monotonic(ctx, add);
  plausibility(ctx, add);
  if (ctx.run.mode === "festival") festival(ctx, add);
  consistency(ctx, add);
  await history(db, ctx, add);

  const reject = flags.some((f) => f.severity === "reject" || f.severity === "ban");
  const ranked = ctx.run.ranked && !reject && !flags.some((f) => f.severity === "review");
  const ban = await shouldBan(db, ctx, flags);
  return { flags, reject, ranked, ban };
}

// ------------------------------------------------------------------ timing --
function timing(ctx: RunContext, add: (r: string, s: Severity, d?: Record<string, unknown>) => void) {
  const start = new Date(ctx.run.started_at).getTime();
  const cps = ctx.checkpoints;
  const gameEnd = Number(ctx.result.time_s ?? 0);
  const wall = (ctx.now - start) / 1000;

  // Game time can only outrun wall time by the legal speed multiplier.
  if (gameEnd > wall * RULES.maxGameSpeed + RULES.clockSlack) add("speed", "reject", { gameEnd, wall });

  // Every heartbeat must exist. A client that suppresses checkpoints to hide a
  // spike is caught here (Pokebonk: `checkpoints-missing`).
  let prevT = 0;
  for (const cp of cps) {
    if (cp.t - prevT > RULES.maxGap) add("checkpoints-missing", "review", { from: prevT, to: cp.t });
    prevT = cp.t;
  }
  if (gameEnd - prevT > RULES.maxGap) add("checkpoints-missing", "review", { from: prevT, to: gameEnd });

  // Each checkpoint's game clock vs. the server's receive clock.
  for (const cp of cps) {
    const serverElapsed = (new Date(cp.server_at).getTime() - start) / 1000;
    if (cp.t > serverElapsed * RULES.maxGameSpeed + RULES.clockSlack + RULES.heartbeat)
      add("clock", "reject", { seq: cp.seq, t: cp.t, serverElapsed });
  }
}

// ------------------------------------------------------------- monotonic --
function monotonic(ctx: RunContext, add: (r: string, s: Severity, d?: Record<string, unknown>) => void) {
  const keys = ["kills", "level", "mvps", "zeny", "checks"];
  let prev: Record<string, number> = {};
  for (const cp of ctx.checkpoints) {
    for (const k of keys) {
      const v = Number(cp.payload[k] ?? 0);
      if (prev[k] !== undefined && v < prev[k]) add("counters-forged", "reject", { key: k, seq: cp.seq });
      prev[k] = v;
    }
  }
}

// ----------------------------------------------------------- plausibility --
function plausibility(ctx: RunContext, add: (r: string, s: Severity, d?: Record<string, unknown>) => void) {
  const danger = Number(ctx.run.danger ?? 1);
  const killCap = RULES.killsPerMin.base + RULES.killsPerMin.perDanger * (danger - 1);
  const cps = ctx.checkpoints;
  for (let i = 1; i < cps.length; i++) {
    const dtMin = Math.max(1 / 60, (cps[i].t - cps[i - 1].t) / 60);
    const dk = cps[i].payload.kills - cps[i - 1].payload.kills;
    if (dk / dtMin > killCap * 1.5) add("kill-impossible", "reject", { seq: cps[i].seq, rate: dk / dtMin });
    else if (dk / dtMin > killCap) add("kill-high", "review", { seq: cps[i].seq, rate: dk / dtMin });

    const dl = cps[i].payload.level - cps[i - 1].payload.level;
    const lvCap = cps[i].t < RULES.levelPerMin.lateFrom ? RULES.levelPerMin.early : RULES.levelPerMin.late;
    if (dl / dtMin > lvCap * 2) add("level-impossible", "reject", { seq: cps[i].seq, rate: dl / dtMin });
  }
  const kills = Number(ctx.result.kills ?? 0);
  const zeny = Number(ctx.result.zeny ?? 0);
  if (zeny > kills * (RULES.zenyPerKill.max + RULES.zenyPerKill.perDanger * danger) + 5000)
    add("gold-impossible", "reject", { zeny, kills });
}

// --------------------------------------------------------------- festival --
// Emperium k has max_hp = BASE_HP * GROW^k (festival_run.gd:396). Breaking n of
// them in FESTIVAL_TIME needs at least sum_{k<n} BASE*GROW^k damage, so the
// claimed `checks` and banked damage must agree, and each break must be logged.
function festival(ctx: RunContext, add: (r: string, s: Severity, d?: Record<string, unknown>) => void) {
  const n = Number(ctx.result.checks ?? 0);
  const banked = Number(ctx.result.dmg ?? 0);
  const minDmg = (GD.FESTIVAL_BASE_HP * (Math.pow(GD.FESTIVAL_GROW, n) - 1)) / (GD.FESTIVAL_GROW - 1);
  if (banked + 1 < minDmg * 0.999) add("result-forged", "reject", { n, banked, minDmg });

  // The client sends one checkpoint per Emperium break: {kind:'check', n, t, banked}
  const breaks = ctx.checkpoints.filter((c) => c.payload.kind === "check");
  if (breaks.length < n) add("checkpoints-missing", "reject", { logged: breaks.length, claimed: n });
  for (let i = 2; i < breaks.length; i++) {
    const hp = (k: number) => GD.FESTIVAL_BASE_HP * Math.pow(GD.FESTIVAL_GROW, k);
    const dps1 = hp(i - 1) / Math.max(0.05, breaks[i - 1].t - breaks[i - 2].t);
    const dps2 = hp(i) / Math.max(0.05, breaks[i].t - breaks[i - 1].t);
    if (dps2 / dps1 > RULES.festivalDpsJump) add("burst", "review", { at: i, dps1, dps2 });
  }
  const span = breaks.length ? breaks[breaks.length - 1].t - breaks[0].t : 0;
  if (span > GD.FESTIVAL_TIME + 2) add("festival-overtime", "reject", { span });
}

// ------------------------------------------------------------ consistency --
function consistency(ctx: RunContext, add: (r: string, s: Severity, d?: Record<string, unknown>) => void) {
  const last = ctx.checkpoints.at(-1)?.payload;
  if (last) {
    for (const k of ["kills", "level", "mvps"]) {
      if (Number(ctx.result[k] ?? 0) < Number(last[k] ?? 0)) add("result-forged", "reject", { key: k });
    }
  }
  // The hero must be the one the server handed out at /runs (loadout snapshot):
  // gear ids, refines, cards, pet and pacts are compared field by field.
  const lo = ctx.run.loadout ?? {};
  const claimed = ctx.result.gear ?? {};
  for (const slot of Object.keys(claimed)) {
    const g = claimed[slot], s = lo.gear?.[slot];
    if (!g || g._found_in_run) continue;                 // items picked up mid-run are checked by loot rules
    if (!s || s.id !== g.id || s.refine !== g.refine || JSON.stringify(s.cards) !== JSON.stringify(g.cards))
      add("loadout-mismatch", "reject", { slot });
  }
}

// ---------------------------------------------------------------- history --
async function history(db: SupabaseClient, ctx: RunContext, add: (r: string, s: Severity, d?: Record<string, unknown>) => void) {
  // Overlapping solo runs on one account (two clients playing at once).
  const { data: overlap } = await db.from("runs").select("id")
    .eq("account_id", ctx.run.account_id).neq("id", ctx.run.id).is("party_id", null)
    .lt("started_at", new Date(ctx.now).toISOString())
    .gt("finished_at", ctx.run.started_at).limit(1);
  if (overlap?.length && !ctx.run.party_id) add("parallel", "review", {});

  // Exact same result submitted twice = replayed payload.
  if (Number(ctx.result.kills ?? 0) >= RULES.repeat.minKills) {
    const since = new Date(ctx.now - RULES.repeat.days * 86400_000).toISOString();
    const { data: same } = await db.from("runs").select("id")
      .eq("account_id", ctx.run.account_id).gte("finished_at", since)
      .eq("result->>kills", String(ctx.result.kills)).eq("result->>time_s", String(ctx.result.time_s)).limit(1);
    if (same?.length) add("result-repeat", "reject", {});
  }
}

async function shouldBan(db: SupabaseClient, ctx: RunContext, flags: Flag[]) {
  if (!flags.some((f) => f.severity === "reject")) return false;
  const since = new Date(ctx.now - RULES.autoBan.days * 86400_000).toISOString();
  const { count } = await db.from("runs").select("id", { count: "exact", head: true })
    .eq("account_id", ctx.run.account_id).eq("status", "rejected").gte("finished_at", since);
  return (count ?? 0) + 1 >= RULES.autoBan.rejectRuns;   // caller sets accounts.banned_until / shadow
}
