class_name TmcShellSoloLate
extends RefCounted

## A web solo game starts on the addon groups it names as early, and the rest of its addons arrive after the game's gate opens.
##
## Why: the 227 MiB weapons overlay was downloaded whole before the game started, ~45 s on a cold web visit, and the first seconds of play
## draw only the default loadout. A game opts in with `web_early_groups.json` in its own pack, `{"<addon dir>": ["<group>", ...]}`; the
## files of the groups named, and every file that is in no group, go in the overlay the game starts on. [method GSCloudAddonSet.late_pack]
## fetches, packs (a few ms a frame) and mounts the rest in place once the gate is open. A browser only: the other platforms keep the
## whole overlay up front, as before. A game without the file is unchanged.

## The file in the game's pack that names the early groups.
const EARLY_FILE := "web_early_groups.json"

## Seconds after the game starts at which the top-up begins anyway, for a game with no load gate to open.
const START_ANYWAY_SEC := 20.0

var shell: Node = null

## The top-up is under way or done: a second call finds it so.
var _started := false


func _init(owner_shell: Node) -> void:
	shell = owner_shell


## The groups of [param text] (`{"<dir>": ["<group>", ...]}`), de-duplicated, in the order they are named; empty for anything else.
## An addon naming `*` has no late groups, so any `*` makes the result `["*"]`.
static func groups_in(text: String) -> PackedStringArray:
	var json := JSON.new()
	var out := PackedStringArray()
	if json.parse(text) != OK or not (json.data is Dictionary):
		return out
	for dir: Variant in (json.data as Dictionary):
		var list: Variant = (json.data as Dictionary)[dir]
		if not (list is Array):
			continue
		for group: Variant in list:
			var name := str(group)
			if name == GSCloudFile.ALL_GROUPS:
				return PackedStringArray([GSCloudFile.ALL_GROUPS])
			if name != "" and not out.has(name):
				out.append(name)
	return out


## The groups the game's overlay should hold on this platform: empty (every group, the default) off the web, or when the game names none.
func early_groups(content_id: String, version: String) -> PackedStringArray:
	if not GSPlatform.is_web() or bool(ProjectSettings.get_setting("tmc/solo/web_late_groups_off", false)):
		return PackedStringArray()
	var game: GSResult = await shell._cloud.resolve_manifest(StringName(content_id), version)
	if not game.ok:
		return PackedStringArray()
	var read: GSResult = await shell._cloud.read_pack_file(game.value as GSCloudManifest, EARLY_FILE)
	if not read.ok:
		return PackedStringArray()
	return groups_in((read.value as PackedByteArray).get_string_from_utf8())


## Whether the running overlay left groups out, and which addons it holds: the plan, or an empty dictionary when nothing is late.
static func late_plan() -> Dictionary:
	var plan := GSCloudAddonSet.read_plan()
	var held: Variant = plan.get("groups", [])
	if not GSCloudAddonSet.mounted_this_boot(plan) or not (held is Array) or (held as Array).has(GSCloudFile.ALL_GROUPS):
		return {}
	if not (plan.get("addons", {}) is Dictionary) or (plan["addons"] as Dictionary).is_empty():
		return {}
	return plan


## Called as the game goes in: when the overlay it runs on left groups out, says so to the game ([constant GSCloudAddonSet.LATE_PENDING])
## and tops it up once the game's gate opens (or [constant START_ANYWAY_SEC] passes).
func begin() -> void:
	var plan := late_plan()
	if plan.is_empty() or _started:
		return
	GSCloudAddonSet.mark_late_pending(true)
	shell._cover.gate_opened.connect(_start.bind(plan), CONNECT_ONE_SHOT)
	shell.get_tree().create_timer(START_ANYWAY_SEC).timeout.connect(_start.bind(plan), CONNECT_ONE_SHOT)


func _start(plan: Dictionary) -> void:
	if _started:
		return
	_started = true
	var addons := GSCloudAddonSet.new(shell._cloud)
	addons.groups = PackedStringArray(plan.get("groups", []))
	var began := Time.get_ticks_msec()
	var late: GSResult = await addons.late_pack(plan["addons"] as Dictionary)
	GSCloudAddonSet.mark_late_pending(false)
	if late.ok:
		GSLog.info(shell.CHANNEL, "late addon groups mounted", {
			"ms": Time.get_ticks_msec() - began, "files": int((late.value as Dictionary).get("files", 0)),
			"bytes": int((late.value as Dictionary).get("bytes", 0)),
		})
	else:
		GSLog.warn(shell.CHANNEL, "late addon groups not mounted; those weapons stay undrawn", {"why": str(late.error)})
