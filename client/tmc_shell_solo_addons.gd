class_name TmcShellSoloAddons
extends RefCounted

## The addons a solo game needs that the shell does not carry: read what a pack names, decide the overlay, fetch it and mount or restart into it.

## The shell this works for. Its state stays there.
var shell: Node = null


func _init(owner_shell: Node) -> void:
	shell = owner_shell


## What [method _solo_overlay] did: nothing was missing, a restart into the addons is under way, they are missing and cannot be had now,
## or the content store publishes no pack that holds one of them ([member unpublished] says which).
enum SoloOverlay { NONE, RESTARTING, BLOCKED, UNPUBLISHED }

## Why [constant SoloOverlay.UNPUBLISHED]: dir -> the sentence [method pack_holds_dir] gave, from the last [method _collect_solo_announce].
var unpublished: Dictionary = {}

## [method TmcSolo.client_refusal] for the game's own `requires.json`, read alone from the store: "" when this client can run it (or the file cannot be read).
func _solo_client_refusal(content_id: String, version: String) -> String:
	var game: GSResult = await shell._cloud.resolve_manifest(StringName(content_id), version)
	if not game.ok:
		return ""
	var read: GSResult = await shell._cloud.read_pack_file(game.value as GSCloudManifest, "requires.json")
	if not read.ok:
		return ""
	return TmcSolo.client_refusal(shell._cloud.addon_api, (read.value as PackedByteArray).get_string_from_utf8())


## The addons a game's pack names (`addons` in its `requires.json` and `requires.floor.json`),
## read from the store before the pack is fetched: dir -> level. Empty when the pack has neither.
func _solo_needs(content_id: String, version: String) -> Dictionary:
	var needs := {}
	var game: GSResult = await shell._cloud.resolve_manifest(StringName(content_id), version)
	if not game.ok:
		return needs
	for file in SOLO_REQUIRE_FILES:
		var read: GSResult = await shell._cloud.read_pack_file(game.value as GSCloudManifest, file)
		if read.ok:
			needs.merge(solo_addons_in((read.value as PackedByteArray).get_string_from_utf8()))
	return needs


## The `addons` map of a requires file's text (dir -> level); empty for anything else.
static func solo_addons_in(text: String) -> Dictionary:
	var json := JSON.new()
	var out := {}
	if json.parse(text) != OK or not (json.data is Dictionary):
		return out
	var addons: Variant = (json.data as Dictionary).get("addons", {})
	if addons is Dictionary:
		for dir: Variant in addons:
			if dir is String and str(dir).is_valid_filename() and not str(dir).contains("."):
				out[dir] = addons[dir]
	return out


## Whether this shell carries the addon a pack names as [param dir]: `res://addons/<dir>`, or the gs name of a legacy one (prod packs published before the
## dot to gs rename still list `dot_achievements`; the shell carries `gs_achievements`, and no `gs-*` addon pack is published to fetch instead).
## Read only: [method GSCloudLegacyRequirements.modern_name] maps the name; nothing writes the old one.
static func shell_carries(dir: String) -> bool:
	var modern := GSCloudLegacyRequirements.modern_name(dir)
	return DirAccess.dir_exists_absolute("res://addons/%s" % dir) or DirAccess.dir_exists_absolute("res://addons/%s" % modern) \
		or GSAddonApi.installed(modern)


## The addons a solo game needs that this shell does not carry, as the announce a server would send (`announce`), which of them the player's subscription
## supplied (`from_subscription`: dir -> id), and which no published pack holds (`unpublished`: dir -> why, see [method pack_holds_dir]).
func _collect_solo_announce(content_id: String, needs: Dictionary, subscribed: Array) -> Dictionary:
	var announce: Array = []
	var from_subscription := {}
	var unpublished := {}
	for entry: Variant in subscribed:
		if not (entry is Dictionary):
			continue
		var dir := str(entry.get("dir", ""))
		if dir == "" or bool(entry.get("running", false)) or DirAccess.dir_exists_absolute("res://addons/%s" % dir):
			continue
		from_subscription[dir] = str(entry.get("id", ""))
		announce.append({"dir": dir, "repo": str(entry.get("repo", "")), "id": from_subscription[dir],
			"version": str(entry.get("version", ""))})
	var dirs: Array = []
	for dir: String in needs:
		if not from_subscription.has(dir) and not shell_carries(dir):
			# The game needs what the player subscribed to when it is in from_subscription: that checked version serves both.
			dirs.append(dir)
	# One round trip for all of them, not one after another.
	var calls: Array = []
	for dir: String in dirs:
		calls.append(_announce_for_dir.bind(content_id, dir))
	var found: Array = await TmcGather.run(calls)
	for i in dirs.size():
		var one: Dictionary = found[i]
		if one.has("unpublished"):
			unpublished[dirs[i]] = one["unpublished"]
		elif one.has("announce"):
			announce.append(one["announce"])
	unpublished = unpublished
	return {"announce": announce, "from_subscription": from_subscription, "unpublished": unpublished}


## What one missing game addon needs: `{announce}` (what to fetch), `{unpublished}` (why it cannot be had) or `{}` (not published; logged).
func _announce_for_dir(content_id: String, dir: String) -> Dictionary:
	var pack := TmcAddonNamespaces.pack_for(dir)
	var latest: GSResult = await TmcSolo.resolve_latest(shell, str(pack["id"]), shell._cloud.http_base_urls, true)
	if not latest.ok and str(pack["old_id"]) != "":
		# Before the site renamed the organisation's packs only the old id is published.
		latest = await TmcSolo.resolve_latest(shell, str(pack["old_id"]), shell._cloud.http_base_urls, true)
	if not latest.ok:
		GSLog.warn(shell.CHANNEL, "a game addon this solo game needs is not published", {
			"content": content_id, "dir": dir, "id": pack["id"], "why": str(latest.error),
		})
		return {}
	# A retired id resolves to the one it moved to, whose name is the repo [GSCloudAddonSet] checks.
	var id := str(latest.value["id"])
	var version := str(latest.value["version"])
	# The newest published version must hold `addons/<dir>`: fc-weapons up to v1.4.51 holds the legacy arena_weapons, so  gs-rename: keep
	# Fatal Contact 0.1.70 (fc_weapons 32) fetched 1.4.50, which [GSCloudAddonSet] refused as "not an addon pack".
	var manifest: GSResult = await shell._cloud.resolve_manifest(StringName(id), version)
	if manifest.ok:
		var why := pack_holds_dir(dir, id, version, manifest_paths(manifest.value as GSCloudManifest))
		if why != "":
			return {"unpublished": why}
	return {"announce": {"dir": dir, "repo": id.get_file(), "id": id, "version": version}}


## Every path [param manifest] lists.
static func manifest_paths(manifest: GSCloudManifest) -> PackedStringArray:
	var out := PackedStringArray()
	if manifest != null:
		for f in manifest.files:
			out.append(f.path)
	return out


## Why the pack [param id] at [param version], whose files are [param paths], cannot supply `addons/<dir>`; empty when it can.
## It can when it is the addon itself (a `plugin.cfg` at its root) or holds `addons/<dir>/plugin.cfg`, which is what
## [GSCloudAddonSet] mounts; a pack that holds the addon under another directory (a renamed repository's older tags) cannot.
static func pack_holds_dir(dir: String, id: String, version: String, paths: PackedStringArray) -> String:
	if paths.has("plugin.cfg") or paths.has("addons/%s/plugin.cfg" % dir):
		return ""
	var holds := PackedStringArray()
	for path in paths:
		var parts := path.split("/")
		if parts.size() == 3 and parts[0] == "addons" and parts[2] == "plugin.cfg":
			holds.append("addons/" + parts[1])
	if holds.is_empty():
		return "%s %s, the newest published, holds no addon, and this game needs addons/%s" % [id, version, dir]
	return "%s %s, the newest published, holds %s, and this game needs addons/%s" % [id, version, ", ".join(holds), dir]


## The addons in [param needs] (from [method _solo_needs]) that this shell neither carries nor has mounted, fetched as the overlay a server would announce. When it only adds addons to this process (a first visit, a new shell build) it is mounted here and the game starts ([method _mount_in_place]); otherwise it is restarted into, as [method _update_addons] does for a join. [constant SoloOverlay.RESTARTING] when a restart is under way (the caller stops there); [constant SoloOverlay.NONE] when nothing is missing or it is mounted here; [constant SoloOverlay.BLOCKED] when the addons are missing and cannot be had now: after a failed start on the same overlay in this shell build, after [constant MAX_UPDATE_RESTARTS] restarts for it, or when building it failed. Blocked never plays on: the game's scripts do not parse without its addons, which leaves PLAYLOT on a black screen. The caller fails the start and the solo button becomes Retry ([member _solo_retry]). [param subscribed] are the Workshop's `summary.addons` (GameSpice Cloud 28): approved addon packs of a game whose `accepts.kinds` has `addon`, already checked against the build's own addons. They join the overlay under their exact ids and are marked `source: "subscription"` in the plan, which [method _restart_for_online] drops.
func _solo_overlay(content_id: String, needs: Dictionary, subscribed: Array = []) -> SoloOverlay:
	var found := await _collect_solo_announce(content_id, needs, subscribed)
	var announce: Array = found["announce"]
	var from_subscription: Dictionary = found["from_subscription"]
	if not (found["unpublished"] as Dictionary).is_empty():
		return SoloOverlay.UNPUBLISHED
	if announce.is_empty():
		return SoloOverlay.NONE

	var addons := GSCloudAddonSet.new(shell._cloud)
	addons.namespaces = TmcAddonNamespaces.load_shell()
	# A web game that names its early groups starts on those; the rest is topped up after its gate opens (TmcShellSoloLate).
	var early := await shell._solo_late.early_groups(content_id, shell._solo_version)
	if not early.is_empty():
		addons.groups = early
	for dir: String in from_subscription:
		# The site approved this exact pack for this player; that, not a namespace, is why it is taken.
		addons.namespaces.append(str(from_subscription[dir]))
	var decided := addons.plan_for(announce)
	var wanted: Dictionary = decided["wanted"]
	mark_subscribed(wanted, from_subscription)

	if not (decided["refused"] as Dictionary).is_empty():
		GSLog.warn(shell.CHANNEL, "solo game addons not taken", {"content": content_id, "refused": decided["refused"]})

	var target := "solo:%s" % content_id

	if wanted.is_empty():
		shell._clear_update_attempts(target)
		return SoloOverlay.NONE

	var attempt = shell._attempt_key(target, wanted)
	if shell._overlay_blocked(attempt, wanted):
		GSLog.warn(shell.CHANNEL, "this solo game's addons did not start here; not starting it without them", {
			"content": content_id, "addons": wanted.keys(), "failed": shell._overlay_failed_here(wanted),
			"restarts": shell._update_attempts(attempt),
		})
		shell._solo_retry = attempt
		return SoloOverlay.BLOCKED

	GSLog.info(shell.CHANNEL, "this solo game needs addons the shell does not carry; fetching them", {
		"content": content_id, "addons": wanted.keys(),
	})
	shell._say(shell._text("shell.addons.updating_solo", {}, "Adding this game's addons…"))
	shell.loading.set_progress(-1.0, shell._text("shell.addons.updating_solo", {}, "Adding this game's addons…"))

	var resume := _solo_resume(content_id)
	var built: GSResult = await addons.build(wanted, resume)
	if not built.ok and plan_holds_subscription({"addons": wanted}):
		# A subscription is optional: one broken pack must not stop solo play. Retry once with the game's own needs.
		GSLog.warn(shell.CHANNEL, "a subscribed addon could not be fetched; playing without the subscribed addons", {
			"content": content_id, "dropped": subscribed_ids(wanted), "why": str(built.error),
		})
		wanted = without_subscribed(wanted)
		if wanted.is_empty():
			shell._clear_update_attempts(target)
			return SoloOverlay.NONE
		attempt = shell._attempt_key(target, wanted)
		built = await addons.build(wanted, resume)
	if not built.ok:
		GSLog.error(shell.CHANNEL, "could not fetch this solo game's addons", {"content": content_id, "why": str(built.error)})
		shell._solo_retry = attempt
		return SoloOverlay.BLOCKED

	shell._stamp_plan()

	# A first visit, or the first start on a new shell build, has none of these addons in this process: mount them here and play on, rather than reload the page and fetch the shell again. A restart stays for an overlay that would replace a mounted addon: a compiled script is never read again. It also stays for a workshop subscription (never on a first visit): an online join drops that overlay, and only a restart unmounts it.
	if shell._overlay_additive(built.value) and not plan_holds_subscription(built.value) \
			and not plan_holds_subscription({"addons": wanted}):
		match shell._mount_in_place():
			shell.InPlace.RUNNING:
				shell._clear_update_attempts(target)
				return SoloOverlay.NONE
			shell.InPlace.STALE:
				shell._solo_retry = attempt
				return SoloOverlay.BLOCKED

	shell._note_update_attempt(attempt)
	return await _restart_for_solo_addons(built.value, resume)

## Where a restart for [param content_id]'s addons comes back to: the page's `?solo=` names the game too, but a menu launch has no address.
func _solo_resume(content_id: String) -> Dictionary:
	var resume := {"solo": content_id, "solo_version": shell._solo_version, "solo_map": shell._solo_map}
	if shell._auth != null and shell._auth.is_signed_in() and shell._auth.identity() != null:
		resume["member"] = shell._auth.identity().uid
	return resume


## Restarts into the overlay that carries a solo game's addons, keeping the files [param plan] names and the sign-in token.
func _restart_for_solo_addons(plan: Dictionary, resume: Dictionary) -> SoloOverlay:
	var keep := GSCloudAddonSet.plan_files(plan)
	if resume.has("member"):
		var tokens = shell._auth.config.token_store_path
		for token in [tokens, tokens + ".salt"]:
			if FileAccess.file_exists(token):
				keep.append(token)

	shell._say(shell._text("shell.addons.restarting", {}, "Restarting to finish the update…"))
	if await shell._restart(keep):
		return SoloOverlay.RESTARTING
	# Without its addons the game's scripts do not parse: say so rather than start a grey screen.
	# A browser that cannot store the overlay (a full quota; before GameSpice Cloud 0.1.47 any overlay over 127 MiB) stops here.
	shell.loading.set_progress(-1.0, shell._text("shell.addons.unsaved_solo", {}, "This browser could not keep the addons this game needs, so it cannot start here yet."))
	return SoloOverlay.RESTARTING


## Marks each entry of a [method GSCloudAddonSet.plan_for] `wanted` that came from a subscription ([param from_subscription]:
## dir -> id) with `source: "subscription"`, which [method GSCloudAddonSet.build] keeps in the plan.
static func mark_subscribed(wanted: Dictionary, from_subscription: Dictionary) -> void:
	for dir: Variant in wanted:
		var entry: Variant = wanted[dir]
		if entry is Dictionary and from_subscription.get(dir, "") == str((entry as Dictionary).get("id", "")) and str(from_subscription.get(dir, "")) != "":
			(entry as Dictionary)["source"] = SUBSCRIPTION_SOURCE


## [param wanted] without the entries a subscription put there (marked by [method mark_subscribed]); a new Dictionary, the entries are shared.
static func without_subscribed(wanted: Dictionary) -> Dictionary:
	var kept := {}
	for dir: Variant in wanted:
		var entry: Variant = wanted[dir]
		if not (entry is Dictionary and str((entry as Dictionary).get("source", "")) == SUBSCRIPTION_SOURCE):
			kept[dir] = entry
	return kept


## The content ids of the entries in [param wanted] a subscription put there (for the log when they are dropped).
static func subscribed_ids(wanted: Dictionary) -> Array:
	var ids: Array = []
	for dir: Variant in wanted:
		var entry: Variant = wanted[dir]
		if entry is Dictionary and str((entry as Dictionary).get("source", "")) == SUBSCRIPTION_SOURCE:
			ids.append(str((entry as Dictionary).get("id", dir)))
	return ids


## Whether an overlay plan holds an addon a player's subscription put there: such a plan never boots into an online session.
static func plan_holds_subscription(plan: Dictionary) -> bool:
	var addons: Variant = plan.get("addons", {})
	if addons is Dictionary:
		for dir: Variant in addons:
			var entry: Variant = (addons as Dictionary)[dir]
			if entry is Dictionary and str((entry as Dictionary).get("source", "")) == SUBSCRIPTION_SOURCE:
				return true
	return false


const SUBSCRIPTION_SOURCE := "subscription"


## Where a game's pack names the addons it needs (and their API floors): the hard requirements
## GameSpice Cloud checks before mounting, and the floors it was built against.
const SOLO_REQUIRE_FILES: PackedStringArray = ["requires.json", "requires.floor.json"]
