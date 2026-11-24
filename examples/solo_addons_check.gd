extends Node

## The addons a solo game needs: what its requires files name, which of them this shell carries, whether a published pack holds the one a game needs,
## and the overlay decision (blocked behind Retry, mounted without a restart). godot --headless --path .

const CHECKS := 48

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0
var _failures: PackedStringArray = []


func _ready() -> void:
	_test_requires_reader()
	_test_pack_holds_dir()
	await _test_legacy_requirements()
	await _test_every_prod_legacy_dir()
	_test_overlay_blocked()
	# Last: it mounts a pack, which nothing unmounts.
	_test_overlay_in_place()

	print("")
	print("%d sections, %d completed" % [_entered, _completed])
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)

	if _passed + _failed != CHECKS or _completed != _entered:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


## A solo game's addons are read from both requires files before its pack is fetched: a hard
## requirement only in requires.json (Prop Hunt's zee_weapons) refuses the pack while missing.
func _test_requires_reader() -> void:
	_section("the addons a solo game's requires files name")
	var shell := load("res://client/tmc_shell_solo_addons.gd") as GDScript
	_check(shell.SOLO_REQUIRE_FILES.has("requires.json") and shell.SOLO_REQUIRE_FILES.has("requires.floor.json"),
		"both requires.json and requires.floor.json are read")
	var got: Dictionary = shell.solo_addons_in('{"addons": {"zee_weapons": 6, "gs_ui": 13}}')
	_check(got.get("zee_weapons") == 6 and got.get("gs_ui") == 13, "a requires file's addons and levels are read", str(got))
	_check((shell.solo_addons_in("not json") as Dictionary).is_empty()
			and (shell.solo_addons_in('{"addons": []}') as Dictionary).is_empty(),
		"a file that is not a requires map names nothing")
	_check(not (shell.solo_addons_in('{"addons": {"../x": 1, "a/b": 1, "ok": 1}}') as Dictionary).has("../x")
			and not (shell.solo_addons_in('{"addons": {"a/b": 1}}') as Dictionary).has("a/b"),
		"a name that is a path is dropped")
	_done()


## FC's real prod requires.json (published before the dot to gs rename) lists dot_* addons the shell carries as gs_*. No gs-* addon pack is
## published, so fetching one failed "has no published version" and stopped web solo. Each must resolve to the built-in with zero pack fetches.
const PROD_FC_REQUIRES := '{"addons": {"dot_achievements": 3, "dot_audio": 5, "dot_core": 12, "dot_net": 7, "dot_cloud": 20, "gs_ui": 13, "fc_weapons": 32}}'


func _test_legacy_requirements() -> void:
	_section("legacy dot_* requirements resolve to the shell's gs_* addons with no pack fetch")
	var shell := load("res://client/tmc_shell_solo_addons.gd") as GDScript
	var needs: Dictionary = shell.solo_addons_in(PROD_FC_REQUIRES)
	_check(needs.size() == 7, "the prod requirement list is read whole", str(needs))
	var fetched: PackedStringArray = []
	for dir: String in needs:
		if not shell.shell_carries(dir):
			fetched.append(dir)
	for dir in ["dot_achievements", "dot_audio", "dot_core", "dot_net", "dot_cloud"]:
		_check(shell.shell_carries(dir), "%s is carried as %s" % [dir, GSCloudLegacyRequirements.modern_name(dir)])
	_check("gs_ui" in needs and shell.shell_carries("gs_ui"), "a gs_ name is carried as it is")
	# Negative: what the shell does not carry still goes to the pack fetch, legacy-named or not.
	var dot_fetched := fetched.duplicate()
	for d in fetched:
		if not d.begins_with("dot_"):
			dot_fetched.remove_at(dot_fetched.find(d))
	_check(dot_fetched.is_empty(), "no legacy dot_* requirement goes to the pack fetch", str(fetched))
	_check(not shell.shell_carries("zzz_not_an_addon") and not shell.shell_carries("dot_zzz_not_an_addon"),
		"an addon the shell lacks, legacy-named or not, is not carried")
	_done()


## Every dot_* addon the live prod Playlot pack listed on 2026-11-22 (the repro log of a native solo start): all resolve to a carried gs_* addon.
const PROD_LEGACY_DIRS := ["dot_achievements", "dot_audio", "dot_auth", "dot_browser", "dot_chat", "dot_cloud", "dot_combat", "dot_console", "dot_core", "dot_economy", "dot_effects", "dot_entity", "dot_flashlight", "dot_fx", "dot_game", "dot_inventory", "dot_leaderboard", "dot_lighting", "dot_loadout", "dot_map", "dot_match", "dot_menu", "dot_mobile", "dot_moderation", "dot_net", "dot_npc", "dot_npc_ai", "dot_npc_ai_director", "dot_peer_to_peer", "dot_physics", "dot_platform", "dot_player", "dot_player_char", "dot_player_class", "dot_procedural_generation", "dot_profile", "dot_props", "dot_server", "dot_server_query", "dot_settings", "dot_spawn", "dot_spectate", "dot_stats", "dot_team", "dot_ui", "dot_user", "dot_user_avatar", "dot_vehicle", "dot_voice", "dot_vote", "dot_weapon", "dot_workbench"]


func _test_every_prod_legacy_dir() -> void:
	_section("every legacy dot_* addon a prod pack lists is carried as gs_*, so none is fetched")
	var shell := load("res://client/tmc_shell_solo_addons.gd") as GDScript
	var missing := PackedStringArray()
	for dir: String in PROD_LEGACY_DIRS:
		if not shell.shell_carries(dir):
			missing.append(dir)
	_check(missing.is_empty(), "all %d legacy names resolve to this shell's addons" % PROD_LEGACY_DIRS.size(), str(missing))
	_done()


## The newest published pack of a game addon must hold the directory the game needs. Fatal Contact 0.1.70 needs fc_weapons and the
## only published fc-weapons (1.4.50) held the legacy arena_weapons: the shell fetched it, the overlay refused it as "not an addon pack",  gs-rename: keep
## and an online join went on to GameSpice Cloud's "needs a newer version of the client". Now it is named as unpublished, up front.
func _test_pack_holds_dir() -> void:
	_section("a published addon pack is taken only when it holds the directory the game needs")
	var shell := load("res://client/tmc_shell_solo_addons.gd") as GDScript
	var legacy := PackedStringArray(["LICENSE", "addons/arena_weapons/plugin.cfg", "addons/arena_weapons/arena_weapons_api.gd", "_imported/a.scn"])  # gs-rename: keep (legacy id, see audit_old_names.allow)
	var current := PackedStringArray(["LICENSE", "addons/fc_weapons/plugin.cfg", "addons/fc_weapons/fc_weapons_api.gd", "addons/gs_sim/plugin.cfg"])
	var why: String = shell.pack_holds_dir("fc_weapons", "gamemann/fc-weapons", "1.4.50", legacy)
	_check(why.contains("addons/arena_weapons") and why.contains("addons/fc_weapons") and why.contains("1.4.50"),  # gs-rename: keep (legacy id, see audit_old_names.allow)
		"fc-weapons 1.4.50 (legacy arena_weapons) does not supply fc_weapons, and the reason names both and the version", why)  # gs-rename: keep (legacy id, see audit_old_names.allow)
	_check(shell.pack_holds_dir("fc_weapons", "gamemann/fc-weapons", "1.4.52", current) == "",
		"fc-weapons 1.4.52 (fc_weapons) supplies it: a game met by its addon's overlay is not refused")
	_check(shell.pack_holds_dir("arena_weapons", "gamemann/fc-weapons", "1.4.50", legacy) == "",  # gs-rename: keep (legacy id, see audit_old_names.allow)
		"a game that still needs the legacy directory takes the tag that holds it")
	_check(shell.pack_holds_dir("gs_trail", "gamemann/gs-trail", "0.1.6", PackedStringArray(["plugin.cfg", "trail.gd"])) == "",
		"a pack that is the addon itself (plugin.cfg at its root) supplies any directory")
	_check(shell.pack_holds_dir("zee_weapons", "gamemann/zee-gs-weapons", "0.1.66", PackedStringArray(["README.md"])).contains("holds no addon"),
		"a pack with no plugin.cfg supplies nothing")
	# Prop Hunt / Playlot / Zombie Zone need zee_weapons: it must resolve to the zee-gs-weapons pack and that pack's layout must be accepted.
	var zee := PackedStringArray(["LICENSE", "addons/zee_weapons/plugin.cfg", "addons/zee_weapons/zee_weapons_api.gd"])
	_check(TmcAddonNamespaces.lock_repo("zee_weapons") == "zee-gs-weapons",
		"zee_weapons is published as zee-gs-weapons", TmcAddonNamespaces.lock_repo("zee_weapons"))
	_check(shell.pack_holds_dir("zee_weapons", "gamemann/zee-gs-weapons", "0.1.68", zee) == "",
		"zee-gs-weapons 0.1.68 supplies zee_weapons: the solo overlay is not refused as 'needs zee-weapons'")
	# The same rule the overlay mounts by, so the two cannot drift apart.
	var overlay := load("res://addons/gs_cloud/addon_set/gs_cloud_addon_set_overlay.gd") as GDScript
	var agree := true
	for case: Array in [["fc_weapons", legacy], ["fc_weapons", current], ["arena_weapons", legacy], ["x", PackedStringArray(["plugin.cfg"])]]:  # gs-rename: keep (legacy id, see audit_old_names.allow)
		var manifest := GSCloudManifest.new()
		for path: String in case[1]:
			var f := GSCloudFile.new()
			f.path = path
			manifest.files.append(f)
		var mounts: bool = overlay.base(manifest, case[0]) != overlay.NOT_AN_ADDON
		var takes: bool = shell.pack_holds_dir(case[0], "o/r", "1", shell.manifest_paths(manifest)) == ""
		agree = agree and mounts == takes
	_check(agree, "it agrees with the overlay's own rule (GSCloudAddonSet's base) on every case")
	_done()


## `sessionStorage` for [method _test_overlay_blocked]: getItem, setItem and removeItem.
class FakeStorage:
	extends RefCounted
	var items := {}

	func getItem(key: String) -> Variant:
		return items.get(key)

	func setItem(key: String, value: String) -> void:
		items[key] = value

	func removeItem(key: String) -> void:
		items.erase(key)


## A solo game whose addons did not start must not be started without them (PLAYLOT's black screen: two restarts that
## worked used up the tab's count, and the third visit played on without zee_weapons). It is blocked behind Retry, and the
## count and the failed mark belong to one shell build.
func _test_overlay_blocked() -> void:
	_section("a solo game whose addons did not start is blocked behind Retry, per shell build")

	var plan_before := FileAccess.get_file_as_string(GSCloudAddonSet.PLAN)
	var shell: Node = (load("res://client/shell.gd") as GDScript).new()
	var storage := FakeStorage.new()
	shell.set("attempt_storage", storage)
	shell.set("shell_build", "20261113-0522")

	var wanted := {"zee_weapons": {"version": "0.1.62"}, "arena_weapons": {"version": "1.4.46"}}  # gs-rename: keep (legacy id, see audit_old_names.allow)
	var target := "solo:gamemann/game-playlot"
	var attempt: String = shell.call("_attempt_key", target, wanted)
	_check(attempt == "solo:gamemann/game-playlot|arena_weapons@1.4.46,zee_weapons@0.1.62", "the attempt key names the game and its addon set", attempt)  # gs-rename: keep (legacy id, see audit_old_names.allow)

	GSCloudAddonSet.forget()
	_check(not shell.call("_overlay_blocked", attempt, wanted), "a fresh tab builds the overlay")
	shell.call("_note_update_attempt", attempt)
	_check(not shell.call("_overlay_blocked", attempt, wanted), "one restart leaves another")
	shell.call("_note_update_attempt", attempt)
	_check(shell.call("_overlay_blocked", attempt, wanted), "after two restarts the game is blocked, not started without its addons")

	shell.set("_solo_retry", attempt)
	shell._solo_flow.call("_forget_solo_retry")
	_check(not shell.call("_overlay_blocked", attempt, wanted) and str(shell.get("_solo_retry")) == "", "Retry clears the count and builds the overlay again")

	shell.call("_note_update_attempt", attempt)
	shell.call("_note_update_attempt", attempt)
	shell.set("shell_build", "20261114-0900")
	_check(int(shell.call("_update_attempts", attempt)) == 0, "a new shell build starts the count again")

	storage.items[shell.get("UPDATE_ATTEMPTS_KEY")] = JSON.stringify({attempt: 2})
	_check(int(shell.call("_update_attempts", attempt)) == 0, "the flat count an older shell kept is not read as this build's")

	shell.call("_note_update_attempt", attempt)
	shell.call("_note_update_attempt", "solo:gamemann/other|x@1")
	shell.call("_clear_update_attempts", target)
	_check(int(shell.call("_update_attempts", attempt)) == 0 and int(shell.call("_update_attempts", "solo:gamemann/other|x@1")) == 1,
		"once a game's addons are running its counts go, and only its own")

	# A failed mark: the overlay's plan written for this build's addons.lock, then marked failed at boot.
	GSCloudAddonSet.write_plan({"state": GSCloudAddonSet.STATE_FAILED, "build": GSCloudAddonSet.build_fingerprint(), "addons": wanted})
	_check(GSCloudAddonSet.failed_before(wanted), "the seeded plan is a failed mark for this set")
	_check(not shell.call("_overlay_blocked", attempt, wanted), "a failed mark no shell build stamped gets one more try")
	shell.call("_stamp_plan")
	_check(str(GSCloudAddonSet.read_plan().get("shell", "")) == "20261114-0900" and GSCloudAddonSet.failed_before(wanted),
		"the plan is stamped with the shell build that built it, the rest kept")
	_check(shell.call("_overlay_blocked", attempt, wanted), "a failed mark from this shell build blocks")
	shell.set("shell_build", "20261115-0100")
	_check(not shell.call("_overlay_blocked", attempt, wanted), "a failed mark from another shell build does not")
	shell.set("shell_build", "20261114-0900")
	shell.set("_solo_retry", attempt)
	shell._solo_flow.call("_forget_solo_retry")
	_check(GSCloudAddonSet.read_plan().is_empty() and not shell.call("_overlay_blocked", attempt, wanted), "Retry forgets the failed mark")

	shell.free()
	if plan_before != "":
		GSPaths.write_text(GSCloudAddonSet.PLAN, plan_before)
	else:
		GSCloudAddonSet.forget()
	_done()


## A fresh visit must not restart the page (on PLAYLOT a first visit fetched the shell, built zee_weapons and
## arena_weapons into an overlay, then reloaded and fetched the shell again). An overlay that only adds addons is mounted in this  gs-rename: keep
## process and its classes resolve; one that would replace an addon, or come after another overlay, still restarts.
func _test_overlay_in_place() -> void:
	_section("a solo game's or a server's addons that only add to this process are mounted without a restart")

	var dir := "solo_check_overlay"
	var root := "res://addons/%s" % dir
	var shell_classes_build: String = GSCloudAddonSet.SHELL_CLASSES_BUILD
	var setting: String = (load("res://client/shell.gd") as GDScript).get_script_constant_map()["OVERLAY_SETTING"]
	var kept := {}
	for path: String in [GSCloudAddonSet.PLAN, GSCloudAddonSet.SHELL_CLASSES, shell_classes_build]:
		kept[path] = FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else null
		DirAccess.remove_absolute(path)
	var setting_before: Variant = ProjectSettings.get_setting(setting, "")

	# gs-cloud's early requirement check (the "needs a newer version of the client" panel) reads res://addons/<dir>: it refuses a game
	# needing an addon this shell does not carry, and passes once the addon's overlay is mounted (checked after the mount below).
	var needs := '{"format": 1, "addons": {"%s": 1}}' % dir
	var before_mount := GSAddonApi.new().check_text(needs, "client")
	_check(not before_mount.ok and before_mount.error.message.contains("does not have it"),
		"before its overlay, a game needing the addon is refused as client_behind", str(before_mount.error) if not before_mount.ok else "passed")

	var built := _build_probe_overlay(dir, root)
	var plan: Dictionary = built["plan"]
	var pack: String = built["pack"]
	var scratch: String = built["scratch"]

	var shell: Node = (load("res://client/shell.gd") as GDScript).new()
	var restarted := [false]
	shell.set("restart_fn", func() -> void: restarted[0] = true)

	_check(shell.call("_overlay_additive", plan), "a first visit's overlay only adds addons")
	_check(not shell.call("_overlay_additive", {"addons": {"gs_core": {}, dir: {}}}),
		"an overlay that would replace an addon the shell carries is not mounted in place")
	# A server's join takes the same overlay the same way (reloading the page for it cost a Fast 4G join about 20 s).
	var storage := FakeStorage.new()
	shell.set("attempt_storage", storage)
	shell.set("shell_build", "20261117-0400")
	var target := "wss://solo-check.invalid:6100"
	shell.call("_note_update_attempt", target + "|" + dir + "@0.0.1")
	shell.call("_note_update_attempt", "wss://other.invalid|x@1")
	_check(not shell.call("_join_in_place", {"addons": {"gs_core": {}, dir: {}}}, target)
		and str(GSCloudAddonSet.read_plan().get("state", "")) == GSCloudAddonSet.STATE_READY,
		"a server overlay that would replace an addon the shell carries is left for a restart")
	var joined: bool = shell.call("_join_in_place", plan, target)
	_check(joined and not restarted[0], "it is mounted in this process, with no restart, and the join goes on")
	_check(int(shell.call("_update_attempts", target + "|" + dir + "@0.0.1")) == 0
		and int(shell.call("_update_attempts", "wss://other.invalid|x@1")) == 1
		and not (shell.get("_addons_skipped") as Dictionary).has(target),
		"the server's restart counts go, another server's stay, and its addons are not skipped")
	var after := GSCloudAddonSet.read_plan()
	_check(str(after.get("state", "")) == GSCloudAddonSet.STATE_OK and GSCloudAddonSet.mounted_this_boot(after),
		"the plan says ok and names the mounted pack", str(after))
	_check((after.get("resume", {}) as Dictionary).is_empty(), "nothing is left to resume on the next visit")
	_check(FileAccess.get_file_as_string(GSCloudAddonSet.SHELL_CLASSES) != ""
		and FileAccess.get_file_as_string(shell_classes_build) == GSCloudAddonSet.build_fingerprint(),
		"the shell's own class list is kept for the next overlay")
	var user := load(root.path_join("user.gd")) as GDScript
	var answer: int = int(user.new().answer()) if user != null and user.can_instantiate() else -1
	_check(answer == 42, "a script naming the overlay's class_name compiles and runs", "got %d" % answer)
	var after_mount := GSAddonApi.new().check_text(needs, "client")
	_check(after_mount.ok, "with its overlay mounted, the same game passes the early requirement check (not client_behind)",
		str(after_mount.error) if not after_mount.ok else "")
	_check(not shell.call("_overlay_additive", {"addons": {"solo_check_other": {}}}),
		"a second overlay after this one restarts")

	shell.free()
	ProjectSettings.set_setting(setting, setting_before)
	for path: String in kept:
		if kept[path] == null:
			DirAccess.remove_absolute(path)
		else:
			GSPaths.write_text(path, str(kept[path]))
	GSPaths.remove_tree(scratch)
	DirAccess.remove_absolute(pack)
	_done()


## A pack as GSCloudAddonSet assembles it (an addon's files and the build's class list with its class added), with the READY plan that names it. Returns {plan, pack, scratch}.
func _build_probe_overlay(dir: String, root: String) -> Dictionary:
	# The overlay as GSCloudAddonSet assembles it: the addon's files and the build's class list with its class added.
	var scratch := GSCloudAddonSet.DIR.path_join("solo_check_scratch")
	GSPaths.ensure_dir(scratch)
	var scripts := {
		root.path_join("solo_check_overlay_probe.gd"): "class_name SoloCheckOverlayProbe\nextends RefCounted\n\nfunc answer() -> int:\n\treturn 42\n",
		root.path_join("user.gd"): "extends RefCounted\n\nfunc answer() -> int:\n\treturn SoloCheckOverlayProbe.new().answer()\n",
	}
	var packer := PCKPacker.new()
	var pack := GSCloudAddonSet.DIR.path_join("solo_check_overlay.pck")
	packer.pck_start(pack)
	var files := {root.path_join("plugin.cfg"): "[plugin]\nname=\"solo_check_overlay\"\n"}
	files.merge(scripts)
	var n := 0
	for target: String in files:
		var source := scratch.path_join("f%d" % n)
		n += 1
		GSPaths.write_text(source, str(files[target]), false)
		packer.add_file(target, source)
	GSCloudAddonSet._write_class_cache(scripts, PackedStringArray([root]), scratch)
	packer.add_file(GSCloudScriptClass.CACHE_PATH, scratch.path_join("global_script_class_cache.cfg"))
	packer.flush(false)

	var plan := {
		"format": GSCloudAddonSet.FORMAT, "build": GSCloudAddonSet.build_fingerprint(), "pack": pack,
		"addons": {dir: {"repo": dir, "version": "0.0.1"}}, "uids": [], "probes": {},
		"state": GSCloudAddonSet.STATE_READY, "resume": {"solo": "gamemann/game-playlot"},
	}
	GSCloudAddonSet.write_plan(plan)
	return {"plan": plan, "pack": pack, "scratch": scratch}


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("== %s" % title)


func _done() -> void:
	_completed += 1


func _check(ok: bool, what: String, detail: String = "") -> bool:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s%s" % [what, ("\n        " + detail.replace("\n", "\n        ")) if detail != "" else ""])
		_failures.append(what)
	return ok

