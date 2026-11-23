extends Node

## The player's answer about a solo game's map packs (TmcSolo.maps_answer / maps_plan) and TmcSoloMaps' pure parts.

const CHECKS := 20

var _passed := 0
var _failed := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("gs-server-deploy: the solo maps answer and plan")
	_test_maps_answer()
	print("%d passed, %d failed (expected %d checks)" % [_passed, _failed, CHECKS])
	get_tree().quit(0 if _failed == 0 and _passed == CHECKS else 1)


func _test_maps_answer() -> void:
	print("== the player's answer about a game's map packs is kept, per game, and decides what happens next")

	var id := "gamemann/solo-check-probe"
	var before := FileAccess.get_file_as_bytes(TmcSolo.PREFS) if FileAccess.file_exists(TmcSolo.PREFS) else PackedByteArray()
	TmcSolo.set_maps_answer(id, "")
	_check(TmcSolo.maps_answer(id) == "", "a new player has not answered")
	TmcSolo.set_maps_answer(id, TmcSolo.ANSWER_YES)
	_check(TmcSolo.maps_answer(id) == TmcSolo.ANSWER_YES, "a yes is kept")
	_check(TmcSolo.maps_answer("gamemann/other") == "", "and is per game")
	TmcSolo.set_maps_answer(id, TmcSolo.ANSWER_NO)
	_check(TmcSolo.maps_answer(id) == TmcSolo.ANSWER_NO, "a Not now is kept")
	TmcSolo.set_maps_answer(id, "maybe")
	_check(TmcSolo.maps_answer(id) == "", "anything else forgets it, so the pop-up asks again")

	var legacy := ConfigFile.new()
	legacy.load(TmcSolo.PREFS)
	legacy.set_value("skip_maps", id, true)
	legacy.save(TmcSolo.PREFS)
	_check(TmcSolo.maps_answer(id) == TmcSolo.ANSWER_NO, "the old loading-screen skip reads as a no")
	TmcSolo.set_maps_answer(id, TmcSolo.ANSWER_YES)
	_check(TmcSolo.maps_answer(id) == TmcSolo.ANSWER_YES, "a new answer replaces the old skip")

	_check(TmcSolo.maps_plan("", false, false) == "none", "a game with no map packs has nothing to ask")
	_check(TmcSolo.maps_plan(TmcSolo.ANSWER_NO, true, true) == "none", "a no is not asked again, whatever is on the disk")
	_check(TmcSolo.maps_plan(TmcSolo.ANSWER_YES, true, false) == "mount", "a yes downloads in the background")
	_check(TmcSolo.maps_plan("", true, true) == "mount", "packs already on the disk are mounted without asking")
	_check(TmcSolo.maps_plan("", true, false) == "ask", "a new player is asked")

	_check(TmcSoloMaps.status_of("", false, 0) == "none", "the Maps page says a game has no packs")
	_check(TmcSoloMaps.status_of("", true, 2) == "yes", "mounted packs read as on")
	_check(TmcSoloMaps.status_of(TmcSolo.ANSWER_NO, true, 0) == "no", "a no reads as off")
	_check(TmcSoloMaps.status_of("", true, 0) == "unasked", "no answer and nothing mounted reads as not chosen")

	var session := TmcSoloSession.new()
	var changes := [0]
	session.maps_changed.connect(func() -> void: changes[0] += 1)
	_check(TmcSoloMaps.add_pack(session, "gamemann/probe-maps@1.0.0"), "a mounted pack joins the session's map roots")
	_check(session.map_keys.size() == 1 and session.map_roots.size() == 1, "as a key and a root")
	_check(not TmcSoloMaps.add_pack(session, "gamemann/probe-maps@1.0.0"), "once, not twice")
	session.maps_changed.emit()
	_check(changes[0] == 1, "maps_changed reaches a game's listener")
	session.free()

	if before.is_empty():
		DirAccess.remove_absolute(TmcSolo.PREFS)
	else:
		var f := FileAccess.open(TmcSolo.PREFS, FileAccess.WRITE)
		f.store_buffer(before)
		f.close()


func _check(ok: bool, what: String) -> bool:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s" % what)
	return ok
