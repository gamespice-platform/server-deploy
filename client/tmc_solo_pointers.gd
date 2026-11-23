class_name TmcSoloPointers
extends RefCounted

## The `latest.json` of a pack, kept on this machine so a second solo launch does not ask the network what it already
## knows: a pointer younger than [constant FRESH_SEC] is used as it is, and an older one is the answer when the network
## cannot be reached, so a pack already downloaded still starts offline. Never trusted beyond the pointer shape:
## [method TmcSolo.follow_pointer] still checks whatever this returns.

const DIR := "user://gs_cloud/pointers"

## Within this many seconds of the last successful fetch the pointer is not asked for again.
const FRESH_SEC := 300


## Where the pointer behind [param url] is kept; one file per address, named by the hash of it.
static func path_for(url: String) -> String:
	return DIR.path_join(url.sha256_text().substr(0, 32) + ".json")


## The kept pointer of [param url]: `{value, at}` or an empty dictionary when none is kept or the file is damaged.
static func load_kept(url: String, dir: String = DIR) -> Dictionary:
	var path := dir.path_join(url.sha256_text().substr(0, 32) + ".json")
	if not FileAccess.file_exists(path):
		return {}
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK:
		return {}
	var parsed: Variant = json.data
	if not parsed is Dictionary or not (parsed as Dictionary).has("at") or not (parsed as Dictionary).get("value") is Dictionary:
		return {}
	return parsed as Dictionary


## The pointer of [param url] when it was fetched less than [constant FRESH_SEC] ago, else null.
static func fresh(url: String, now: int = int(Time.get_unix_time_from_system()), dir: String = DIR) -> Variant:
	var kept := load_kept(url, dir)
	if kept.is_empty():
		return null
	var age := now - int(kept["at"])
	return kept["value"] if age >= 0 and age < FRESH_SEC else null


## The pointer of [param url] however old, or null: what an unreachable network falls back to.
static func stale(url: String, dir: String = DIR) -> Variant:
	var kept := load_kept(url, dir)
	return null if kept.is_empty() else kept["value"]


## Keeps [param value] as what [param url] answered just now. A failed write only costs the next launch a request.
static func remember(url: String, value: Dictionary, now: int = int(Time.get_unix_time_from_system()), dir: String = DIR) -> void:
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir)) != OK:
		return
	var file := FileAccess.open(dir.path_join(url.sha256_text().substr(0, 32) + ".json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"at": now, "value": value}))
