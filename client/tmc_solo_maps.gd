class_name TmcSoloMaps
extends RefCounted

## A solo game's map packs, once the game is already on screen. The loading screen never waits for them: the game starts with the maps built into it, and this decides what happens next. A new player is asked once (Yes / Not now, remembered per game in `user://tmc_solo.cfg`, changed later on the game menu's Maps page); a player who said yes, or who already has the packs on the disk, gets them mounted in the background with the shared busy panel ([TmcBusyBridge], which hides under the shell's cover) showing the progress. Mounted packs join [member TmcSoloSession.map_roots] and the session emits [signal TmcSoloSession.maps_changed], which a game's map list or vote listens for. Every map the packs list is shown at once ([member TmcSoloSession.available]); a game that lists them downloads each one when it is picked ([method fetch_map]) and the "download them all" question is not asked (the Maps page keeps "Download all maps").
## See [method TmcSolo.maps_plan] for the decision.

const CHANNEL := "tmc.solo_maps"

## The page's id in a GSMenu.
const PAGE_ID := &"solo_maps"

## Seconds between looks at whether the shell's cover is still up, and the longest the question waits for it.
const COVER_POLL_SEC := 0.5
const COVER_WAIT_MAX_SEC := 120.0

signal _answered(yes: bool)

var shell: Node = null
## A download is under way ([method download] does nothing twice at once).
var _busy := false


func _init(owner_shell: Node) -> void:
	shell = owner_shell


## Called when a solo game has just been put on screen. Lists every map the packs hold (a game downloads one when it is picked, [method fetch_map]); then a player who said yes, or has the packs on the disk, gets them all mounted.
func after_start(session: TmcSoloSession) -> void:
	session.fetch_fn = func(id: StringName) -> GSResult:
		return await fetch_map(session, id)
	var packs := TmcSolo.map_packs(session.content_id)
	if packs.is_empty():
		return
	# Whatever the answer about downloading them all: the list shows every map, each downloaded when picked.
	await list_available(session, packs)
	if not _alive(session) or TmcSolo.maps_answer(session.content_id) == TmcSolo.ANSWER_NO:
		return
	if not await _until_uncovered(session):
		return
	var answer := TmcSolo.maps_answer(session.content_id)
	var plan := TmcSolo.maps_plan(answer, true, await _on_disk(packs), session.on_demand)
	if not _alive(session):
		return
	GSLog.info(CHANNEL, "solo maps plan", {"content": session.content_id, "answer": answer, "plan": plan})
	if plan == "ask":
		var yes: bool = await _ask(session)
		if not _alive(session):
			return
		TmcSolo.set_maps_answer(session.content_id, TmcSolo.ANSWER_YES if yes else TmcSolo.ANSWER_NO)
		if not yes:
			return
		plan = "mount"
	if plan == "mount":
		await download(session)


## Reads the maps [param packs] list from their manifests (no pack is downloaded) into [member TmcSoloSession.available], and tells the game. A pack whose manifest cannot be read is left out with a warning.
func list_available(session: TmcSoloSession, packs: PackedStringArray) -> int:
	var rows: Array = []
	for key in packs:
		var latest: GSResult = await shell._solo_packs._resolve_solo_key(key)
		if not latest.ok:
			GSLog.warn(CHANNEL, "a map pack's newest version could not be read", {"pack": key, "why": str(latest.error)})
			continue
		var resolved: GSResult = await shell._cloud.resolve_manifest(StringName(str(latest.value["id"])), str(latest.value["version"]))
		if not resolved.ok:
			GSLog.warn(CHANNEL, "a map pack's manifest could not be read", {"pack": key, "why": str(resolved.error)})
			continue
		rows.append_array(TmcSolo.provided_maps((resolved.value as GSCloudManifest).provides, key))
	if not _alive(session):
		return 0
	session.available = rows
	GSLog.info(CHANNEL, "solo maps listed", {"content": session.content_id, "maps": rows.size()})
	session.maps_changed.emit()
	return rows.size()


## Downloads and mounts one map: its one-map pack when one is published, else its game's map pack (on the web only the files no group holds plus the map's group). The busy panel shows the progress. Fails loudly; calling it again retries.
func fetch_map(session: TmcSoloSession, id: StringName) -> GSResult:
	var row: Dictionary = {}
	for one: Variant in session.available:
		if one is Dictionary and str((one as Dictionary).get("id", "")) == String(id):
			row = one
	if row.is_empty():
		return GSResult.fail(GSError.CODE_INVALID, "No map pack lists that map.", String(id))
	var name_text := str(row.get("name", id))
	TmcBusyBridge.begin(shell, shell._cloud, shell._text("solo.map_busy", {"name": name_text}, "Downloading the map %s…" % name_text))
	var got := GSResult.fail(GSError.CODE_STATE, "Nothing was downloaded.", String(id))
	var one_key := str(row.get("key", ""))
	if one_key != "" and (await shell._solo_packs._resolve_solo_key(one_key)).ok:
		got = await shell._solo_packs._ensure_solo_pack(one_key, false, PackedStringArray(["*"]))
	if not got.ok and _alive(session):
		got = await shell._solo_packs._ensure_solo_pack(str(row["pack"]), false, TmcSolo.map_groups(GSPlatform.is_web(), String(id)))
	TmcBusyBridge.end()
	if not _alive(session):
		return GSResult.fail(GSError.CODE_STATE, "The game ended.", String(id))
	if not got.ok:
		GSLog.error(CHANNEL, "a map could not be downloaded", {"map": String(id), "why": str(got.error)})
		return GSResult.fail(GSError.CODE_NETWORK, "Could not download the map %s." % name_text, str(got.error))
	add_pack(session, str(got.value))
	session.maps_changed.emit()
	GSLog.info(CHANNEL, "a map was downloaded", {"map": String(id), "pack": str(got.value)})
	return GSResult.success(str(got.value))


## Fetches (if need be) and mounts every map pack of the session's game, with the busy panel up while bytes move. Safe to call twice: a pack already mounted is skipped and a second call while one runs does nothing.
func download(session: TmcSoloSession) -> int:
	if _busy or not _alive(session):
		return 0
	_busy = true
	var groups := TmcSolo.map_groups(GSPlatform.is_web(), String(session.start_map))
	var added := 0
	var name_text := session.display_name if session.display_name != "" else session.content_id
	TmcBusyBridge.begin(shell, shell._cloud, shell._text("solo.maps_busy", {"name": name_text}, "Downloading maps for %s…" % name_text))
	for key in TmcSolo.map_packs(session.content_id):
		var got: GSResult = await shell._solo_packs._ensure_solo_pack(key, false, groups)
		if not _alive(session):
			break
		if not got.ok:
			GSLog.warn(CHANNEL, "a solo map pack could not be fetched", {"pack": key, "why": str(got.error)})
			continue
		if add_pack(session, str(got.value)):
			added += 1
	TmcBusyBridge.end()
	_busy = false
	if added > 0 and _alive(session):
		session.maps_changed.emit()
		GSLog.info(CHANNEL, "solo maps mounted in the background", {"content": session.content_id, "packs": added})
	return added


## Adds the mounted pack [param key] (`<id>@<version>`) to [param session]; false when it was already there.
static func add_pack(session: TmcSoloSession, key: String) -> bool:
	if session.map_keys.has(key):
		return false
	var parts := TmcSolo.split_key(key)
	session.map_keys.append(key)
	session.map_roots.append(GSCloudClient.mount_prefix_for(StringName(parts["id"]), str(parts["version"])))
	return true


## True while [param session] is the one the shell is running.
func _alive(session: TmcSoloSession) -> bool:
	return is_instance_valid(shell) and is_instance_valid(session) and shell._solo_session == session


## Waits until the shell's cover has lifted (the player is in the game), so the question is never under it. False when the game ended first. After [constant COVER_WAIT_MAX_SEC] it goes on anyway.
func _until_uncovered(session: TmcSoloSession) -> bool:
	var waited := 0.0
	while _alive(session) and waited < COVER_WAIT_MAX_SEC:
		if not bool(Engine.get_meta(&"gs_host_cover_up", false)) and (shell.loading == null or not shell.loading.is_showing()):
			return true
		await shell.get_tree().create_timer(COVER_POLL_SEC).timeout
		waited += COVER_POLL_SEC
	return _alive(session)


## Whether every map pack of the game is already on the disk (nothing left to download), by the manifests alone.
func _on_disk(packs: PackedStringArray) -> bool:
	var groups := TmcSolo.map_groups(GSPlatform.is_web(), shell._solo_map)
	for key in packs:
		var latest: GSResult = await shell._solo_packs._resolve_solo_key(key)
		if not latest.ok:
			return false
		var resolved: GSResult = await shell._cloud.resolve_manifest(StringName(str(latest.value["id"])), str(latest.value["version"]))
		if not resolved.ok:
			return false
		var plan = shell._cloud.plan_for(resolved.value as GSCloudManifest, groups)
		if int(plan.get("missing_bytes", 0)) > 0:
			return false
	return true


## The pop-up: "Download maps for <game>?" with Yes and Not now. True for yes.
func _ask(session: TmcSoloSession) -> bool:
	var dialog := TmcShellStyle.dialog(ConfirmationDialog.new())
	var name_text := session.display_name if session.display_name != "" else session.content_id
	dialog.title = shell._text("solo.maps_ask.title", {}, "More maps")
	dialog.dialog_text = shell._text("solo.maps_ask.text", {"name": name_text},
		"Download the map packs for %s? They download in the background while you play, and the maps show up in the map list when they are done. You can change this later in the game menu, under Maps." % name_text)
	dialog.ok_button_text = shell._text("solo.maps_ask.yes", {}, "Yes, download")
	dialog.cancel_button_text = shell._text("solo.maps_ask.no", {}, "Not now")
	dialog.confirmed.connect(func() -> void: _answered.emit(true))
	dialog.canceled.connect(func() -> void: _answered.emit(false))
	shell.add_child(dialog)
	shell._popup_dialog(dialog)
	var yes: bool = await _answered
	dialog.queue_free()
	return yes


## Which line the Maps page shows: "none" (the game has no map pack), "yes" with [param mounted] packs mounted, "no", or "unasked".
static func status_of(answer: String, has_packs: bool, mounted: int) -> String:
	if not has_packs:
		return "none"
	if answer == TmcSolo.ANSWER_YES or (answer == "" and mounted > 0):
		return "yes"
	return "no" if answer == TmcSolo.ANSWER_NO else "unasked"


## Adds the Maps page to [param menu] (a GSMenu): what was chosen, a button to download now and one to stop asking.
func add_to_menu(menu: Object) -> void:
	var page := GSMenuPage.make(PAGE_ID, "Maps", "Download this game's map packs.")
	page.build = func(_kit: Object, body: VBoxContainer) -> void:
		_build_page(body)
	menu.call(&"add_page", page)


func _build_page(body: VBoxContainer) -> void:
	var session: TmcSoloSession = shell._solo_session
	if session == null:
		return
	var id := session.content_id
	var label := Label.new()
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(label)
	var yes := Button.new()
	var no := Button.new()
	var refresh := func() -> void:
		var status := status_of(TmcSolo.maps_answer(id), not TmcSolo.map_packs(id).is_empty(), session.map_keys.size())
		label.text = shell._text("solo.maps_status." + status, {}, {
			"none": "This game has no map packs to download.",
			"yes": "Map packs: on (%d mounted)." % session.map_keys.size(),
			"no": "Maps download one at a time, when you pick them.",
			"unasked": "Maps download one at a time, when you pick them.",
		}[status])
		yes.visible = status != "none"
		no.visible = status != "none" and status != "no"
		yes.disabled = _busy
	yes.text = shell._text("solo.maps_page.yes", {}, "Download all maps")
	no.text = shell._text("solo.maps_page.no", {}, "Download maps when picked")
	yes.pressed.connect(func() -> void:
		TmcSolo.set_maps_answer(id, TmcSolo.ANSWER_YES)
		refresh.call()
		await download(session)
		if is_instance_valid(label):
			refresh.call())
	no.pressed.connect(func() -> void:
		TmcSolo.set_maps_answer(id, TmcSolo.ANSWER_NO)
		refresh.call())
	body.add_child(yes)
	body.add_child(no)
	refresh.call()
