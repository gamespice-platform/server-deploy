class_name TmcShellSolo
extends RefCounted

## Playing one game with no server: fetch, mount and start it, and the addon overlay it may need first.

## The shell this works for. Its state stays there.
var shell: Node = null


func _init(owner_shell: Node) -> void:
	shell = owner_shell


## Runs [param content_id] here, with no server: fetch, verify and mount it as a join does,
## then start its client scene, which finds no link and plays offline. See [TmcSolo].
func _start_solo(content_id: String, version: String = "", map: String = "") -> void:
	if content_id == "" or not TmcSolo.valid_id(content_id):
		return

	shell._drop_link()
	shell._end_solo_session()
	shell._clear_game()
	shell._leave_game_ui()

	shell._solo_id = content_id
	shell._solo_version = version
	shell._solo_map = map if TmcSolo.valid_map(map) else ""
	shell._solo_retry = ""
	shell._set_busy(true)
	shell._join.text = "Connect"
	shell._show_connect_form(false)
	if shell._solo_button != null:
		shell._solo_button.disabled = true
	shell._say("Finding %s…" % content_id)
	_launch_t0 = Time.get_ticks_msec()
	_show_launch_identity(content_id)

	shell._ensure_cloud()
	# The solo game's server runs here as well: it needs the server-only files (API 8).
	shell._cloud.config.side = "both"
	shell._adopt_content_url_arg()
	shell._enter_solo_session()

	var started := await _load_solo(content_id, version)
	shell._solo_launching = false
	_stage("start finished", {"ok": started.ok})

	if shell._solo_button != null:
		shell._solo_button.disabled = false

	# Retry: go again, once, from the top.
	if not started.ok and shell._dl_guard != null and shell._dl_guard.requested != "":
		GSLog.info(shell.CHANNEL, "restarting the solo launch", {"why": shell._dl_guard.requested})
		_start_solo.call_deferred(content_id, version, map)
		return

	if not started.ok:
		shell.loading.end(TmcLoadingScreen.REASON_GAME)
		shell._end_solo_session()
		# The detail names every address asked and why it failed (one per line), which is what tells a missing file from a refused one.
		var reason: String = shell._explain(started.error)
		if started.error != null and started.error.detail != "":
			reason += "\n" + started.error.detail
		GSLog.error(shell.CHANNEL, "solo start failed", {"content": content_id, "reason": reason})
		shell._fail(shell._text("shell.solo.failed", {"reason": reason},
			"Could not start %s: %s" % [content_id, reason]))
		if shell._solo_retry != "" and shell._solo_button != null:
			shell._solo_button.text = shell._text("shell.solo.retry", {}, "Retry")
			shell._solo_button.visible = true
			shell._primary(shell._solo_button)
		return


## The solo button: Retry after [method TmcShellSoloAddons._solo_overlay] was blocked, which forgets that set's restarts and a failed mark first, so the overlay is built again.
func _on_solo_pressed() -> void:
	var refusal := solo_press_refusal(shell._solo_id, shell._launch_job)
	if refusal != "":
		# Never a silent no-op: the player pressed a button and is told why nothing started.
		GSLog.warn(shell.CHANNEL, "solo button pressed but no solo start is possible", {"why": refusal})
		shell._say(refusal)
		return
	_forget_solo_retry()
	_start_solo(shell._solo_id, shell._solo_version, shell._solo_map)


## Why pressing Play solo cannot start a game, shown to the player; empty when it can. [param launching] is a launch already under way.
static func solo_press_refusal(solo_id: String, launching: bool) -> String:
	if solo_id == "":
		return "No solo game was chosen: open this client from a game's Play solo link."
	if launching:
		return "%s is already starting; please wait." % solo_id
	return ""


## What Retry clears: the blocked set's restarts and a failed mark, so [method _overlay_blocked] lets the overlay be built again.
func _forget_solo_retry() -> void:
	if shell._solo_retry == "":
		return
	GSLog.info(shell.CHANNEL, "retrying this solo game's addons", {"attempt": shell._solo_retry})
	shell._forget_update_attempt(shell._solo_retry)
	if GSValue.same(GSCloudAddonSet.read_plan().get("state", ""), GSCloudAddonSet.STATE_FAILED):
		GSCloudAddonSet.forget()
	shell._solo_retry = ""


## When this launch began (msec), for [method _stage].
var _launch_t0 := 0


## The name a game shows before its pack says one: its repository slug, `game-` dropped, in words.
static func friendly_name(content_id: String) -> String:
	var slug := content_id.get_slice("/", content_id.get_slice_count("/") - 1)
	slug = slug.trim_prefix("game-").trim_prefix("mg-")
	return slug.replace("-", " ").replace("_", " ").capitalize()


## The game's name, its icon (when hinted) and a bar with words, from the first frame, so the wait before the download is never the bare shell splash.
func _show_launch_identity(content_id: String) -> void:
	shell._solo_launching = true
	var title := friendly_name(content_id)
	shell.loading.begin(TmcLoadingScreen.REASON_GAME, content_id, title, true)
	# Determinate from the first frame: the bar starts at a sliver and each stage moves it, instead of an unfilled bar for the pin and fetches.
	shell.loading.set_progress(0.01, shell._text("shell.loading.game", {"game": title}, "Loading %s…" % title))
	TmcGameIconHint.start(shell, shell.loading)


## One timing line per stage of a launch: where the time before the download goes.
func _stage(what: String, extra: Dictionary = {}) -> void:
	var data := extra.duplicate()
	data["ms"] = Time.get_ticks_msec() - _launch_t0
	GSLog.info(shell.CHANNEL, "[TMC] solo stage: %s" % what, data)


## Everything [method _start_solo] does that can fail, so it has one way out.
func _load_solo(content_id: String, version: String) -> GSResult:
	if not shell._cloud.manifest_from_cache.is_connected(_on_manifest_from_cache):
		shell._cloud.manifest_from_cache.connect(_on_manifest_from_cache)
	shell._cloud.begin_job("launch")
	shell._launch_job = true
	if shell._dl_guard != null:
		shell._dl_guard.begin()
	shell._solo_key_cache = {}
	shell._solo_map_packs_memo = null
	shell._deferred_workshop = false
	var res: GSResult = await _load_solo_inner(content_id, version)
	shell._launch_job = false
	shell._job = {}
	shell._solo_pack_label = ""
	if shell._dl_guard != null:
		shell._dl_guard.end()
	shell._cloud.end_job()
	return res


## The id and version a solo start uses: the newest when none was asked for, and the newest
## published when the pinned one has no manifest. Fails with the resolver's result.
func _pin_solo_version(content_id: String, version: String) -> GSResult:
	var wanted := version

	if wanted == "":
		var latest: GSResult = await TmcSolo.resolve_latest(shell, content_id, shell._cloud.http_base_urls, true)
		if not latest.ok:
			# The pointer cannot be fetched (offline, CDN down): a game already on this machine still starts, from the newest manifest kept with it.
			var kept: PackedStringArray = GSCloudManifestCache.versions(shell._cloud.config.cache_dir, content_id)
			if kept.is_empty():
				return latest
			GSLog.warn(shell.CHANNEL, "latest.json unreachable; using the newest kept version",
				{"content": content_id, "using": kept[0], "why": str(latest.error)})
			return GSResult.success({"id": content_id, "version": kept[0]})
		# A retired id resolves to the one it moved to; use that from here on.
		content_id = str(latest.value["id"])
		wanted = str(latest.value["version"])

	elif not (await shell._cloud.resolve_manifest(StringName(content_id), wanted)).ok:
		# The site pins the newest READY upload; the CDN may only hold a later one.
		var newest: GSResult = await TmcSolo.resolve_latest(shell, content_id, shell._cloud.http_base_urls)
		if newest.ok and TmcSolo.falls_back(wanted, str(newest.value["version"])):
			GSLog.warn(shell.CHANNEL, "pinned solo version has no manifest; using the newest published",
				{"content": content_id, "pinned": wanted, "using": newest.value["version"]})
			content_id = str(newest.value["id"])
			wanted = str(newest.value["version"])
	return GSResult.success({"id": content_id, "version": wanted})


## The content network could not be reached and the game starts from the manifest kept when it was downloaded.
func _on_manifest_from_cache(manifest: GSCloudManifest, detail: String) -> void:
	GSLog.warn(shell.CHANNEL, "solo starts from the copy on this machine", {"content": manifest.content_id, "version": manifest.version, "tried": detail})
	shell._say(shell._text("shell.solo.offline_copy", {"version": manifest.version},
		"Offline: starting the copy of version %s kept on this computer." % manifest.version))


func _unpublished_failure(content_id: String, wanted: String) -> GSResult:
	# Not the "needs a newer client" panel GameSpice Cloud's requirement check would show next: no shell build can carry a game
	# addon (only gs-* addons), so the fix is a publish of that addon's pack, never a newer client.
	var why := "; ".join(PackedStringArray(shell._solo_addons.unpublished.values()))
	GSLog.error(shell.CHANNEL, "a game addon this solo game needs is not published in a pack that holds it", {
		"content": content_id, "version": wanted, "unpublished": shell._solo_addons.unpublished,
	})
	return GSResult.fail(GSError.CODE_STATE, shell._text("shell.solo.addon_unpublished", {"why": why},
		"this game needs an addon that is not published yet ({why}). Nothing was downloaded.".format({"why": why})))


## Fails with the republish message when the game's pack needs an addon API this client does not run; nothing is fetched.
func _solo_refusal_result(content_id: String, wanted: String) -> GSResult:
	var refusal: String = await shell._solo_addons._solo_client_refusal(content_id, wanted)
	if refusal == "":
		return GSResult.success(null)
	GSLog.error(shell.CHANNEL, "this game's addon API is not one this client runs; nothing was downloaded",
		{"content": content_id, "version": wanted, "why": refusal})
	return GSResult.fail(GSError.CODE_VERSION, refusal)


## The client refusal for a game, then the addons its pack names; both read the same requires files, one after the other.
func _refusal_and_needs(content_id: String, wanted: String) -> Dictionary:
	var refused := await _solo_refusal_result(content_id, wanted)
	if not refused.ok:
		return {"refused": refused, "needs": {}}
	return {"refused": refused, "needs": await shell._solo_addons._solo_needs(content_id, wanted)}


## The cover's status line from a locale key, at [param fraction] of the bar (negative: moving without a fraction).
func _set_status(key: String, fallback: String, fraction: float) -> void:
	var title := friendly_name(shell._solo_id) if shell._solo_id != "" else ""
	shell.loading.set_progress(fraction, shell._text(key, {"name": title}, fallback % title))


func _load_solo_inner(content_id: String, version: String) -> GSResult:
	var pinned := await _pin_solo_version(content_id, version)
	if not pinned.ok:
		return pinned
	content_id = str(pinned.value["id"])
	var wanted := str(pinned.value["version"])
	_stage("version pinned", {"version": wanted})

	shell._solo_id = content_id
	shell._solo_version = wanted
	GSLog.info(shell.CHANNEL, "starting solo", {"content": content_id, "version": wanted})
	# An icon URL the launcher gave (?icon=) shows from here, before the pack is mounted.
	TmcGameIconHint.start(shell, shell.loading)

	var stopped: Variant = await _check_solo_needs(content_id, wanted)
	if stopped != null:
		return stopped
	var fetched := await _fetch_solo_packs(content_id, wanted)
	if not fetched.ok:
		return fetched
	var mount: String = fetched.value["mount"]
	var desc: Dictionary = fetched.value["desc"]
	var path: String = fetched.value["path"]

	var deps := await _fetch_solo_dependencies(desc)
	if not deps.ok:
		return deps
	var dep_keys: PackedStringArray = deps.value

	var session := _new_solo_session(content_id, wanted, mount, desc, dep_keys)

	var slice_keys := _solo_slice_keys(content_id, wanted, desc)
	await _add_solo_map_packs(session, content_id)
	shell._solo_pack_label = ""
	await _add_solo_subscriptions(session, content_id, mount)

	_stage("mounted, preparing scripts")
	shell._warm_hold = await shell._solo_packs._warm_pack(slice_keys)
	_stage("scripts prepared")
	var packed: Variant = await _load_scene_threaded(path)
	_stage("client scene loaded")

	if not (packed is PackedScene):
		return GSResult.fail(GSError.CODE_IO, "The game's client scene would not load.", path)

	return _enter_solo_game(session, packed as PackedScene, desc, path)


## What stops a start before anything is downloaded: a game this client refuses, addons it needs that are blocked, unpublished or being restarted into.
## Null when the start goes on; otherwise the [GSResult] it ends with (a success when a restart is under way).
func _check_solo_needs(content_id: String, wanted: String) -> Variant:
	# The refusal check (a game this client cannot run must not download its maps) and the addon list read the game's requires files;
	# the Workshop plan reads provides.json and asks the site. Different files and hosts, so they run at once. The plan only registers
	# downloads with the launch job (none starts before _prefetch_solo), so a refused game still fetches nothing.
	_set_status("shell.solo.preparing", "Preparing %s…", 0.05)
	# Start the content client before two calls share it: GSCloudClient.start() is not re-entrant, and two first calls each ran it, opening
	# the cache store twice. On the web the second open never answered, so the launch hung here.
	var started: GSResult = await shell._cloud.start()
	if not started.ok:
		return started
	var both: Array = await TmcGather.run([_refusal_and_needs.bind(content_id, wanted),
		shell._solo_packs._solo_workshop_plan.bind(content_id, wanted)])
	var first: Dictionary = both[0]
	var subscribed: Array = both[1]
	_stage("refusal, needs and workshop plan read", {"addons": subscribed.size()})
	if not (first["refused"] as GSResult).ok:
		return first["refused"]
	var needs: Dictionary = first["needs"]
	var overlay: int = await shell._solo_addons._solo_overlay(content_id, needs, subscribed)
	_stage("overlay decided", {"overlay": overlay})
	match overlay:
		TmcShellSoloAddons.SoloOverlay.RESTARTING:
			return GSResult.success(null)
		TmcShellSoloAddons.SoloOverlay.BLOCKED:
			return GSResult.fail(GSError.CODE_STATE, shell._text("shell.solo.addons_blocked", {},
				"this game's addons did not start in this tab, so it was not started without them. Retry fetches them again."))
		TmcShellSoloAddons.SoloOverlay.UNPUBLISHED:
			return _unpublished_failure(content_id, wanted)
	return null


## Downloads and unpacks the game's packs, then reads its descriptor: `{mount, desc, path}` (the client scene's path under the mount).
func _fetch_solo_packs(content_id: String, wanted: String) -> GSResult:
	# Everything is registered and fetched first, so the total is fixed before a byte moves; mounting follows.
	await shell._solo_packs._prefetch_solo(content_id, wanted)
	_stage("packs downloaded")
	# The player pressed Retry: the transfer was cancelled, so do not go on to fetch it again here; _start_solo starts over.
	if shell._dl_guard != null and shell._dl_guard.requested != "":
		return GSResult.fail(GSError.CODE_CANCELLED, "The download was stopped.")
	shell._cloud.job_begin_unpack()

	# "*" asks for every download group (GameSpice Cloud 22): a solo host serves any map. Older GameSpice Cloud reads it as
	# a group no file has, which is what an empty list already fetched there.
	var got: GSResult = await shell._cloud.ensure(StringName(content_id), wanted, PackedStringArray(["*"]))
	if not got.ok:
		return got

	var mount := GSCloudClient.mount_prefix_for(StringName(content_id), wanted)
	var read := TmcSolo.read_descriptor(mount)
	if not read.ok:
		return read

	var desc: Dictionary = read.value
	var scene_rel := str(desc.get("client_scene", ""))
	if scene_rel == "":
		return GSResult.fail(GSError.CODE_INVALID,
			"This game names no client scene, so it cannot be played here.", mount)

	var safe := GSPaths.safe_relative(scene_rel)
	if not safe.ok:
		return GSResult.fail(GSError.CODE_INVALID, "This game's client scene is not a safe path.", scene_rel)
	return GSResult.success({"mount": mount, "desc": desc, "path": mount.path_join(safe.value)})


## Loads the game's client scene (and everything it references) on the engine's loader threads, one frame at a time on this one, so the cover keeps drawing and the window keeps answering the OS for the seconds a big game takes. A plain `load` here froze the main thread, which on Windows reads as "Not Responding". Falls back to a plain load when the threaded request is refused.
func _load_scene_threaded(path: String) -> Variant:
	if ResourceLoader.load_threaded_request(path, "PackedScene", true) != OK:
		return load(path)
	var progress: Array = []
	while true:
		var status := ResourceLoader.load_threaded_get_status(path, progress)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			return ResourceLoader.load_threaded_get(path)
		if status != ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			return null
		await shell.get_tree().process_frame
	return null


## Puts the loaded solo session and its client scene into the tree and tells the shell the
## game is running.
func _enter_solo_game(session: TmcSoloSession, packed: PackedScene, desc: Dictionary, path: String) -> GSResult:
	var content_id := session.content_id
	# Before the session goes in, so a refusal leaves nothing behind (instantiate runs no _ready).
	var instance := packed.instantiate()
	_stage("client scene instantiated")
	if instance == null:
		return GSResult.fail(GSError.CODE_INVALID, shell.GAME_DID_NOT_COMPILE, path)
	shell.add_child(session)
	shell._solo_session = session
	GSRegistry.register(TmcSolo.MAPS_SERVICE, session)

	if not shell.get_tree().node_added.is_connected(shell._on_solo_node_added):
		shell.get_tree().node_added.connect(shell._on_solo_node_added)

	# A client that announces Leave rather than acting on it (`leave_requested`: "what leave
	# means belongs to whatever loaded this client") is answered here, as a server's game is
	# answered by its disconnect.
	if instance.has_signal(&"leave_requested"):
		instance.connect(&"leave_requested", shell._leave_solo, CONNECT_DEFERRED)

	shell._game_root.add_child(instance)

	shell._set_busy(false)
	shell._menu.visible = false
	shell._has_spawned = true
	shell.loading.end(TmcLoadingScreen.REASON_GAME)
	shell.loading.end(TmcLoadingScreen.REASON_CONTENT)
	shell._say("")
	shell._watch_game_ready()
	if session.takes_subscriptions:
		shell._sync_suggested_later(content_id, desc["suggested"] as PackedStringArray)

	var solo_icon := TmcGameIdentity.icon_from_mount(session.mount_root, TmcGameIdentity.icon_rel({"icon": desc.get("icon", TmcGameIdentity.DEFAULT_ICON)}))
	TmcGameIdentity.apply_window(TmcGameIdentity.display_name(session.display_name, content_id), solo_icon if solo_icon != null else TmcGameIdentity.shell_icon())
	var shown := session.display_name if session.display_name != "" else content_id
	if shell._solo_button != null:
		shell._solo_button.text = "Play %s solo" % shown
	if shell._friends != null:
		shell._friends.on_game_changed(shown, "")

	GSLog.info(shell.CHANNEL, "solo game started", {
		"content": "%s@%s" % [content_id, session.version], "scene": path, "maps": session.map_keys.size(),
	})
	# The bulk map packs come after the game is up (the question, or the background download), never before.
	shell._solo_maps.after_start.call_deferred(session)
	return GSResult.success(instance)


## The session node for a solo game whose pack is mounted at [param mount].
func _new_solo_session(content_id: String, wanted: String, mount: String, desc: Dictionary, dep_keys: PackedStringArray) -> TmcSoloSession:
	var session := TmcSoloSession.new()
	session.name = "Solo"
	session.content_id = content_id
	session.version = wanted
	session.mount_root = mount
	session.display_name = str(desc.get("name", ""))
	session.start_map = StringName(shell._solo_map)
	session.leave_fn = shell._leave_solo
	session.pack_keys = dep_keys
	session.cache_dir = shell._cloud.config.cache_dir
	session.content_url = shell._user_arg("--content-url").strip_edges()
	return session


## The packs the game needs beside its own, by the rule a join fetches them: a key with
## no version is not one a server would send, and here it is resolved to the newest
## rather than refused, because nobody pinned it. The value is the fetched keys.
func _fetch_solo_dependencies(desc: Dictionary) -> GSResult:
	var dep_keys := PackedStringArray()
	for key in (desc["dependencies"] as PackedStringArray) + (desc["server_dependencies"] as PackedStringArray):
		var dep = await shell._solo_packs._ensure_solo_pack(key)
		if not dep.ok:
			return GSResult.fail(dep.error.code,
				"This game needs %s, which could not be downloaded." % key, str(dep.error))
		dep_keys.append(str(dep.value))
	return GSResult.success(dep_keys)


## The content keys the warm-up slices load: the game's own and each pinned dependency.
func _solo_slice_keys(content_id: String, wanted: String, desc: Dictionary) -> Array[String]:
	var slice_keys: Array[String] = [GSCloudClient.content_key_for(StringName(content_id), wanted)]
	for key in (desc["dependencies"] as PackedStringArray) + (desc["server_dependencies"] as PackedStringArray):
		var parts := TmcSolo.split_key(key)
		if str(parts["version"]) != "":
			slice_keys.append(GSCloudClient.content_key_for(StringName(parts["id"]), str(parts["version"])))
	return slice_keys


## What the solo start fetches of the game's map packs before the game is shown: nothing, unless the player asked for a start map (`?map=`, `--solo-map`) that has a pack of its own, and then only that one-map pack, so the link opens on the map it names. The rest is [TmcSoloMaps]' job once the game is up, so the loading screen never waits for the bulk packs. One that will not fetch is a map nobody can change to, not a game that will not start.
func _add_solo_map_packs(session: TmcSoloSession, content_id: String) -> void:
	for key in await shell._solo_packs._solo_start_map_packs(content_id):
		var maps = await shell._solo_packs._ensure_solo_pack(key, true, TmcSolo.map_groups(GSPlatform.is_web(), shell._solo_map))
		if not maps.ok:
			GSLog.warn(shell.CHANNEL, "a solo map pack could not be fetched", {
				"pack": key, "why": str(maps.error),
			})
			continue
		TmcSoloMaps.add_pack(session, str(maps.value))


## Subscribed packs, after the game's own and before its scene exists, so the scene's
## catalogues find every entry already in the index. A game that states no `accepts`
## takes none and is not asked about them.
func _add_solo_subscriptions(session: TmcSoloSession, content_id: String, mount: String) -> void:
	session.takes_subscriptions = not shell._game_accepts(mount).is_empty()
	if not session.takes_subscriptions:
		return
	if shell._deferred_workshop:
		var mounted: GSResult = await shell._ensure_workshop().mount_pending()
		session.workshop_summary = mounted.value as Dictionary if mounted.ok and mounted.value is Dictionary else {}
	else:
		# Subscribed content only: the suggested map packs are fetched after the scene is up.
		session.workshop_summary = await shell._sync_workshop(content_id)


## The server process a solo game started for itself ([method TmcSoloSession.sim_child_args]): the packs the shell that started it mounted, from the same cache, the session registered as that shell registers it, and the game's client scene, which hands over to its server. A failure quits with 1, and the game that started it plays in-process.
func _start_sim_child() -> void:
	# The overlay mounted at boot is the parent's: an unconfirmed boot would count against it.
	GSCloudAddonSet.confirm_boot()
	var started := await _load_sim_child()
	if not started.ok:
		GSLog.error(shell.CHANNEL, "the solo server process could not start its game", {"why": str(started.error)})
		shell.get_tree().quit(1)


func _load_sim_child() -> GSResult:
	var asked := TmcSolo.requested()
	var content_id := str(asked["id"])
	var version := str(asked["version"])
	if content_id == "" or version == "":
		return GSResult.fail(GSError.CODE_INVALID, "A solo server process needs --solo and --solo-version.")

	shell._cloud = shell._new_cloud()
	shell._cloud.config.side = "both"
	shell.add_child(shell._cloud)
	shell._adopt_content_url_arg()

	var got: GSResult = await shell._cloud.ensure(StringName(content_id), version, PackedStringArray(["*"]))
	if not got.ok:
		return got

	var session := TmcSoloSession.new()
	session.name = "Solo"
	session.content_id = content_id
	session.version = version
	session.mount_root = GSCloudClient.mount_prefix_for(StringName(content_id), version)
	session.cache_dir = shell._cloud.config.cache_dir
	session.start_map = StringName(str(asked.get("map", "")))

	for flag in [TmcSolo.PACKS_FLAG, TmcSolo.MAPS_FLAG]:
		for key in TmcSolo.child_keys(str(flag)):
			var parts := TmcSolo.split_key(key)
			if str(parts["version"]) == "" or not TmcSolo.valid_id(str(parts["id"])) or not TmcSolo.valid_version(str(parts["version"])):
				return GSResult.fail(GSError.CODE_INVALID, "Not a pinned pack key.", key)
			var pack: GSResult = await shell._cloud.ensure(StringName(parts["id"]), str(parts["version"]), PackedStringArray(["*"]))
			if not pack.ok:
				return pack
			if str(flag) == TmcSolo.MAPS_FLAG:
				session.map_keys.append(key)
				session.map_roots.append(GSCloudClient.mount_prefix_for(StringName(parts["id"]), str(parts["version"])))
			else:
				session.pack_keys.append(key)

	var read := TmcSolo.read_descriptor(session.mount_root)
	if not read.ok:
		return read
	var desc: Dictionary = read.value
	session.display_name = str(desc.get("name", ""))
	var safe := GSPaths.safe_relative(str(desc.get("client_scene", "")))
	if not safe.ok:
		return GSResult.fail(GSError.CODE_INVALID, "This game names no usable client scene.", session.mount_root)
	var path := session.mount_root.path_join(safe.value)
	var packed: Variant = load(path)
	if not (packed is PackedScene):
		return GSResult.fail(GSError.CODE_IO, "The game's client scene would not load.", path)

	var instance := (packed as PackedScene).instantiate()
	if instance == null:
		return GSResult.fail(GSError.CODE_INVALID, shell.GAME_DID_NOT_COMPILE, path)
	shell.add_child(session)
	shell._solo_session = session
	GSRegistry.register(TmcSolo.MAPS_SERVICE, session)
	shell._game_root.add_child(instance)
	GSLog.info(shell.CHANNEL, "solo server process started its game", {
		"content": "%s@%s" % [content_id, version], "packs": session.pack_keys.size(), "maps": session.map_keys.size(),
	})
	return GSResult.success(null)
