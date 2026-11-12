# =============================================================================
# res://scripts/autoload/api.gd  (new autoload "Api") - reference sketch
#
# Replaces the unauthenticated Leaderboard._call() / CloudSave._call() pair with
# one authenticated client. Everything that changes progression goes through it.
#
#   Api.ensure_session()            -> Supabase anonymous sign-in or stored session
#   Api.get_profile()               -> authoritative profile (Save becomes a cache)
#   Api.actions([...])              -> shop/refine/fuse/claim... as server commands
#   Api.start_run(opts)             -> ticket {id, seed, loadout, ranked}
#   Api.checkpoint(payload)         -> queued heartbeat, flushed in batches
#   Api.finish_run(result)          -> rewards computed by the server
#
# Pattern taken from Pokebonk's backend client (main-*.js, class with req(),
# startRun(), checkpoint()/flushCps(), finishRun(), pending queue + retryLater()).
# =============================================================================
extends Node

signal session_changed
signal banned(info: Dictionary)
signal update_required(min_version: String)
signal profile_changed(profile: Dictionary, rev: int)

const AUTH_URL := 'https://<project>.supabase.co/auth/v1/'
const API_URL := 'https://<project>.supabase.co/functions/v1/api'
const ANON_KEY := '<publishable key>'      # public by design; grants nothing without RLS policies
const SESSION_PATH := 'user://session.dat'
const PENDING_PATH := 'user://pending_finish.dat'
const CP_BATCH := 300
const TIMEOUT := 15.0
const FINISH_TIMEOUT := 180.0

var _session: Dictionary = {}              # {access_token, refresh_token, expires_at, user_id}
var _ticket: Dictionary = {}               # current run ticket
var _cps: Array = []                       # checkpoints waiting to be sent
var _cp_seq := 0
var _sending := false
var clock_skew_ms := 0

# ------------------------------------------------------------------ session --
func ensure_session() -> bool:
	if _session.is_empty():
		_session = _load_secure(SESSION_PATH)
	if not _session.is_empty() and Time.get_unix_time_from_system() < float(_session.get('expires_at', 0)) - 60:
		return true
	if _session.has('refresh_token'):
		var r := await _auth('token?grant_type=refresh_token', {'refresh_token': _session.refresh_token})
		if r.ok:
			return _store_session(r.data)
	# First launch: anonymous account (Supabase "anonymous sign-ins"), upgraded later
	# to user+password with the same id, so progress is never tied to a device.
	var a := await _auth('signup', {'data': {'device': device_id()}})
	return a.ok and _store_session(a.data)

func _store_session(d: Dictionary) -> bool:
	_session = {'access_token': d.access_token, 'refresh_token': d.refresh_token,
		'expires_at': Time.get_unix_time_from_system() + float(d.get('expires_in', 3600)),
		'user_id': d.get('user', {}).get('id', '')}
	_save_secure(SESSION_PATH, _session)
	session_changed.emit()
	return true

# Random per-install id, like Pokebonk's `pb.device`. Not a secret, only a signal
# for device-farm detection.
static func device_id() -> String:
	var id := str(Save.setting('device_id', ''))
	if id.length() < 32:
		id = Crypto.new().generate_random_bytes(16).hex_encode()
		Save.set_setting('device_id', id)
	return id

# ------------------------------------------------------------------ profile --
func get_profile() -> Dictionary:
	var r := await req('/profile', HTTPClient.METHOD_GET)
	if r.ok:
		clock_skew_ms = int(r.data.get('now', 0)) - int(Time.get_unix_time_from_system() * 1000.0)
		profile_changed.emit(r.data.profile, int(r.data.rev))
	return r

# Batched commands. `key` makes a retried request apply once (server keeps the response).
func actions(list: Array, if_rev: int) -> Dictionary:
	var key := Crypto.new().generate_random_bytes(12).hex_encode()
	var r := await req('/profile/actions', HTTPClient.METHOD_POST, {'actions': list, 'key': key, 'if_rev': if_rev})
	if r.ok:
		profile_changed.emit(r.data.profile, int(r.data.rev))
	elif r.code == 409 and r.data is Dictionary and r.data.has('profile'):
		profile_changed.emit(r.data.profile, int(r.data.rev))   # stale cache: adopt server state, let UI retry
	return r

# --------------------------------------------------------------------- runs --
func start_run(opts: Dictionary) -> Dictionary:
	var key := Crypto.new().generate_random_bytes(8).hex_encode() + str(Time.get_ticks_msec())
	for attempt in 3:
		var r := await req('/runs', HTTPClient.METHOD_POST, opts.merged({'key': key}))
		if r.ok:
			_ticket = r.data
			_cps.clear()
			_cp_seq = 0
			return r
		if not r.offline:
			return r
		await get_tree().create_timer((0.5 + randf() * 1.5) * (attempt + 1)).timeout
	# Online-only: no ticket means a PRACTICE run. It plays normally but grants
	# nothing and cannot reach a board (Pokebonk returns {ranked:false, offline:true}).
	_ticket = {}
	return {'ok': false, 'offline': true, 'practice': true}

func has_ticket() -> bool:
	return _ticket.has('id')

# Called by World every RULES.heartbeat seconds of game time, and on events that
# matter for validation (boss kill, stage change, Emperium break).
func checkpoint(payload: Dictionary) -> void:
	if not has_ticket():
		return
	_cp_seq += 1
	payload['seq'] = _cp_seq
	_cps.append(payload)
	_flush_cps()

func _flush_cps() -> void:
	if _sending or _cps.is_empty() or not has_ticket():
		return
	_sending = true
	var batch := _cps.slice(0, CP_BATCH)
	var r := await req('/runs/%s/checkpoint' % _ticket.id, HTTPClient.METHOD_POST, {'cps': batch})
	_sending = false
	if r.ok:
		_cps = _cps.slice(batch.size())
		_flush_cps()

func finish_run(result: Dictionary) -> Dictionary:
	if not has_ticket():
		return {'ok': false, 'practice': true}
	var body := {'result': result, 'cps': _cps.slice(-CP_BATCH)}
	var id := str(_ticket.id)
	_queue_pending(id, body)                    # survives a crash or a closed window
	_ticket = {}
	var r := await req('/runs/%s/finish' % id, HTTPClient.METHOD_POST, body, FINISH_TIMEOUT)
	if r.ok or r.code == 409:                   # 409 = the server already saved it
		_drop_pending(id)
		if r.ok:
			profile_changed.emit(r.data.profile, int(r.data.rev))
	elif not _retryable(r):
		_drop_pending(id)                       # 4xx rejection: do not resend forever
	return r

# On boot and when the connection returns: resend unfinished finishes.
func flush_pending() -> void:
	for item in _load_secure(PENDING_PATH).get('items', []):
		var r := await req('/runs/%s/finish' % item.id, HTTPClient.METHOD_POST, item.body, FINISH_TIMEOUT)
		if r.ok or r.code == 409 or not _retryable(r):
			_drop_pending(str(item.id))

# ------------------------------------------------------------------ request --
func req(path: String, method: int, body = null, timeout := TIMEOUT) -> Dictionary:
	if not await ensure_session():
		return {'ok': false, 'offline': true, 'code': 0}
	var http := HTTPRequest.new()
	http.timeout = timeout
	add_child(http)
	var headers := PackedStringArray([
		'apikey: ' + ANON_KEY,
		'Authorization: Bearer ' + str(_session.access_token),
		'Content-Type: application/json',
		'X-Device: ' + device_id(),
		'X-Client: ' + str(Updater.version),
	])
	# No TLS fallback: Leaderboard._call() retries with TLSOptions.client_unsafe()
	# after a handshake error, which lets any proxy read and rewrite traffic.
	var err := http.request(API_URL + path, headers, method, '' if body == null else JSON.stringify(body))
	if err != OK:
		http.queue_free()
		return {'ok': false, 'offline': true, 'code': 0}
	var res: Array = await http.request_completed
	http.queue_free()
	var code: int = res[1]
	var data = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8()) if (res[3] as PackedByteArray).size() > 0 else null
	if res[0] != HTTPRequest.RESULT_SUCCESS or code == 502 or code == 504:
		return {'ok': false, 'offline': true, 'code': code}
	if code == 426:
		update_required.emit(str(data.get('min', '')) if data is Dictionary else '')
	if code == 403 and data is Dictionary and data.has('banned'):
		banned.emit(data.banned)
	return {'ok': code >= 200 and code < 300, 'code': code, 'data': data, 'offline': false}

func _retryable(r: Dictionary) -> bool:
	return r.get('offline', false) or int(r.get('code', 0)) >= 500 or int(r.get('code', 0)) in [401, 408, 425, 429]

func _auth(endpoint: String, body: Dictionary) -> Dictionary:
	var http := HTTPRequest.new()
	add_child(http)
	http.request(AUTH_URL + endpoint, PackedStringArray(['apikey: ' + ANON_KEY, 'Content-Type: application/json']),
		HTTPClient.METHOD_POST, JSON.stringify(body))
	var res: Array = await http.request_completed
	http.queue_free()
	var ok: bool = res[0] == HTTPRequest.RESULT_SUCCESS and res[1] >= 200 and res[1] < 300
	return {'ok': ok, 'data': JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8()) if ok else {}}

# -------------------------------------------------------------- local files --
# Only the session token and the pending-finish queue are stored locally. They
# are not progression: editing them cannot grant anything the server would not.
func _queue_pending(id: String, body: Dictionary) -> void:
	var d := _load_secure(PENDING_PATH)
	var items: Array = d.get('items', [])
	items.append({'id': id, 'body': body})
	_save_secure(PENDING_PATH, {'items': items.slice(-20)})

func _drop_pending(id: String) -> void:
	var d := _load_secure(PENDING_PATH)
	_save_secure(PENDING_PATH, {'items': (d.get('items', []) as Array).filter(func(i): return str(i.id) != id)})

func _save_secure(path: String, d: Dictionary) -> void:
	var f := FileAccess.open_encrypted_with_pass(path, FileAccess.WRITE, OS.get_unique_id())
	if f:
		f.store_string(JSON.stringify(d))

func _load_secure(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open_encrypted_with_pass(path, FileAccess.READ, OS.get_unique_id())
	var d = JSON.parse_string(f.get_as_text()) if f else null
	return d if d is Dictionary else {}
