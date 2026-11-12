# =============================================================================
# Changes to existing scripts - reference sketch (line numbers from build 0.1.276)
#
# Goal: Save.data stays the in-memory model the whole game already reads, but it
# becomes a READ-ONLY CACHE of the server profile. Nothing the client writes to
# disk can add progression any more.
# =============================================================================


# ---------------------------------------------------------------------------
# 1) scripts/autoload/save.gd
# ---------------------------------------------------------------------------

# BEFORE (save.gd:117 load_profile, :206 flush): progression is read from and
# written to user://profile.json, encrypted with the SAVE_KEY constant at :144.
# Anyone who extracts the .pck has that constant, so the file is editable.
#
# AFTER: the profile comes from the server; the local file is only an offline
# read cache for menus (and is ignored if its rev is older than the server's).

var rev := 0                       # server profile revision

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Api.profile_changed.connect(_adopt)
	data = _merge(defaults(), _read_cache())       # instant menus while the request is in flight
	_boot.call_deferred()

func _boot() -> void:
	if not await Api.ensure_session():
		_offline_mode()                            # menus + practice runs only
		return
	await Api.flush_pending()                      # finishes queued while offline
	await Api.get_profile()                        # emits profile_changed -> _adopt()

func _adopt(profile: Dictionary, new_rev: int) -> void:
	if new_rev < rev:
		return
	var device := _device_settings()               # CloudSave.DEVICE_KEYS stay local
	data = _merge(defaults(), profile)
	data.settings.merge(device, true)
	rev = new_rev
	_write_cache()
	changed.emit()

# flush() no longer persists progression. It only saves device settings and the cache.
func flush() -> void:
	if not _dirty:
		return
	_dirty = false
	_write_cache()

# Every mutator becomes a command. Example: save.gd:314 spend()
#   BEFORE: data.zeny = zeny() - amount ; mark_dirty()
#   AFTER : the server checks the balance and the price from its own GameData copy.
func buy_upgrade(id: String) -> bool:
	var r := await Api.actions([{'k': 'upgrade', 'id': id}], rev)
	return r.ok

# The same shape for the rest of the economy (all in save.gd today):
#   add_card / fuse_card (:586/:533)        -> {'k':'fuse','card':id}
#   set_eternal / unset_eternal (:556/:573) -> {'k':'eternal','card':id,'on':bool}
#   unlock_class (:613)                      -> {'k':'unlock_class','id':id}
#   set_class_stats / reset_class_stats      -> {'k':'stats','class':id,'stats':{...}}
#   toggle_pact (:934)                       -> {'k':'pact','id':id}
#   add_tower_build / take_tower_build       -> {'k':'tower_build',...}
#   claim_achievement (:409)                 -> {'k':'claim','id':id}
#   set_look / wear_cosmetic / set_active_pet-> cosmetic, can stay batched in /prefs-like calls
# Pure UI preferences (pact toggles that cost nothing, looks) can be batched and
# sent every few seconds; anything that costs or grants a resource is sent at once.

# add_zeny (:306), add_kills (:436), add_class_xp (:644), add_material, record (:282)
# are no longer called by gameplay code. Their effects arrive in the /finish response.


# ---------------------------------------------------------------------------
# 2) scripts/core/main.gd (World)
# ---------------------------------------------------------------------------

# start_run (main.gd:1100): ask for a ticket first, build the hero from the
# server loadout (gear, cards, pet, pacts, class stats as the server has them).
func start_run(class_id: String, choose_start := false) -> void:
	var t := await Api.start_run({'mode': _mode_name(), 'class_id': class_id, 'stage_id': stage_id,
		'danger': danger, 'party_id': net.party_id() if is_coop() else null})
	practice = not t.ok
	if t.ok:
		seed(int(t.data.seed))                     # replaces randomize() at main.gd:523 for the run RNG
		_loadout = t.data.loadout
	else:
		hud.banner(tr('Offline: practice run. Progress and records are not saved.'))
	# ... existing setup continues, reading gear from _loadout instead of Save.storage()

# Heartbeat: every 60 s of game time plus key events.
func _process_checkpoints() -> void:
	if time >= _next_cp:
		_next_cp += 60.0
		_checkpoint()

func _checkpoint(kind := 'beat', extra := {}) -> void:
	Api.checkpoint({'kind': kind, 't': time, 'stage': stage_id, 'kills': kills, 'level': player.level,
		'xp': player.xp_gained, 'zeny': run_zeny, 'mvps': run_mvps, 'danger': danger, 'speed': speed,
		'dmg': Leaderboard.big(float(meter_stats.get('total', 0.0))),
		'best': Leaderboard.big(float(meter_stats.get('best', 0.0))),
		'stats': player.stats, 'loot': player.equipment.found_ids()}.merged(extra))

# _end_run (main.gd:13935) and _bank_run (:14206): stop writing Save directly.
# Send telemetry; the server answers with rewards, class xp and new records.
func _end_run(victory: bool) -> void:
	# ... existing teardown (net.send_end, song, karma, quest) stays ...
	var result := {'victory': victory, 'time_s': roundi(time), 'kills': kills, 'level': player.level,
		'xp': roundi(player.xp_gained), 'zeny': run_zeny, 'mvps': run_mvps, 'danger': danger,
		'gods': altars.taken, 'tower': tower.best if tower != null else 0,
		'gear': player.equipment.snapshot(), 'kept': _kept_items(), 'ores': player.equipment.ores_found,
		'meter': board.metrics_of(self, victory, {}, {}), 'tampered': player.tampered}
	var r := await Api.finish_run(result)
	if r.get('practice', false):
		results.show_practice()
	elif r.ok:
		results.show_rewards(r.data.rewards)       # what the server granted, not what the client computed
	else:
		results.show_pending()                     # queued: "Saved when the connection returns"
	# board.submit(...) / board.submit_tower(...) at main.gd:13997-14001 are removed:
	# the server writes leaderboard rows inside /finish.


# ---------------------------------------------------------------------------
# 3) scripts/core/festival_run.gd
# ---------------------------------------------------------------------------
# On each Emperium break (festival_run.gd:417 `checks += 1`) log it, so the server
# can rebuild the HP ladder BASE_HP * GROW^k and the time between breaks.
#	world._checkpoint('check', {'n': checks, 'banked': Leaderboard.big(banked)})
# The final submit_festival (festival_run.gd:446 -> leaderboard.gd:60) goes away.
# claim_festival_daily (leaderboard.gd:78) moves to /profile/actions {'k':'festival_daily'}
# and the server checks that a validated festival run exists for that day.


# ---------------------------------------------------------------------------
# 4) scripts/core/run_save.gd
# ---------------------------------------------------------------------------
# RunSave.save (run_save.gd:42) writes user://profile.run with var_to_str, in
# clear text. Resume (:141 -> apply_hero :170) trusts it fully, so editing the
# file edits the hero. Move it server-side:
#	RunSave.save(w) -> Api.req('/runs/%s/snapshot' % id, PUT, {'hash': sha256(text), 'data': gzip(text)})
#	RunSave.resume  -> GET the snapshot, check hash, check the server's last checkpoint matches it.
# Pokebonk does the same with /runs/:id/save, /suspend, /resume, /recover.


# ---------------------------------------------------------------------------
# 5) scripts/autoload/updater.gd
# ---------------------------------------------------------------------------
# Patches are decrypted with PATCH_KEY (updater.gd:55), a constant in the client:
# confidentiality only, no authenticity. Sign the manifest and each .pck with the
# developer key the game already verifies against (Save.dev_verify, save.gd:1227
# uses Crypto.verify with DEV_PUBLIC) and refuse anything that does not verify:
#	if not Crypto.new().verify(HashingContext.HASH_SHA256, file_sha256, sig, PATCH_PUBLIC): _fail()
# The server then enforces the minimum version (HTTP 426 -> Api.update_required).
