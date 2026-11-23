extends Node

## The kept `latest.json` of solo play ([TmcSoloPointers]): fresh inside the window, stale kept for offline starts,
## nothing for a damaged file. godot --headless --path . res://examples/solo_pointers_check.tscn

const CHECKS := 9
const DIR := "user://solo_pointers_check"
const URL := "https://cdn.example/content/a/b/latest.json"

var _passed := 0
var _failed := 0


func _ready() -> void:
	var dir := DIR
	DirAccess.remove_absolute(dir.path_join(URL.sha256_text().substr(0, 32) + ".json"))
	_check("nothing kept answers nothing", TmcSoloPointers.fresh(URL, 1000, dir) == null and TmcSoloPointers.stale(URL, dir) == null)
	TmcSoloPointers.remember(URL, {"version": "1.2.3"}, 1000, dir)
	var fresh: Variant = TmcSoloPointers.fresh(URL, 1100, dir)
	_check("a young pointer is answered without the network", fresh is Dictionary and fresh["version"] == "1.2.3", str(fresh))
	_check("a pointer at the window's edge is old", TmcSoloPointers.fresh(URL, 1000 + TmcSoloPointers.FRESH_SEC, dir) == null)
	var stale: Variant = TmcSoloPointers.stale(URL, dir)
	_check("an old pointer is still the offline answer", stale is Dictionary and stale["version"] == "1.2.3", str(stale))
	_check("a clock set back is not fresh", TmcSoloPointers.fresh(URL, 500, dir) == null)
	_check("another address has its own pointer", TmcSoloPointers.stale(URL + "x", dir) == null)
	TmcSoloPointers.remember(URL, {"version": "1.2.4"}, 2000, dir)
	var newer: Variant = TmcSoloPointers.fresh(URL, 2001, dir)
	_check("a newer answer replaces it", newer is Dictionary and newer["version"] == "1.2.4", str(newer))
	var file := FileAccess.open(dir.path_join(URL.sha256_text().substr(0, 32) + ".json"), FileAccess.WRITE)
	file.store_string("{ not json")
	file.close()
	_check("a damaged file is nothing", TmcSoloPointers.fresh(URL, 2001, dir) == null and TmcSoloPointers.stale(URL, dir) == null)
	_check("the default location is under the shell's cloud cache", TmcSoloPointers.path_for(URL).begins_with("user://gs_cloud/pointers/"))
	print("%d checks, %d failed" % [_passed + _failed, _failed])
	get_tree().quit(1 if _failed > 0 or _passed + _failed != CHECKS else 0)


func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
	print("  %s    %s%s" % ["ok" if ok else "FAIL", label, "" if ok or detail == "" else " (%s)" % detail])
