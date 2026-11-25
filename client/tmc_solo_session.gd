class_name TmcSoloSession
extends Node

## The solo game the shell is running, as a game and its menu find it.

## `<owner>/<repo>` and the version that was mounted.
var content_id: String = ""
var version: String = ""

## The game's display name, from its `game.yml`.
var display_name: String = ""

## Where the game's pack is mounted: `res://gs_cloud/<id>/<version>`.
var mount_root: String = ""

## Each mounted map pack's root, `res://gs_cloud/<id>/<version>`, in `client/solo.json`'s
## order, and the `<id>@<version>` keys they were mounted from.
var map_roots: PackedStringArray = PackedStringArray()
var map_keys: PackedStringArray = PackedStringArray()

## Emitted after map packs were mounted in the background, once the game was already running
## ([TmcSoloMaps]): a game's map list or vote re-reads [method map_dirs] on it.
signal maps_changed()

## Every map the game's map packs list, mounted or not ([method TmcSolo.provided_maps] rows), filled in by [TmcSoloMaps] from the packs' manifests; [signal maps_changed] fires when it is.
var available: Array = []

## Set once a game asked for [method available_maps]: it downloads each map when it is picked, so the shell does not ask to download them all.
var on_demand: bool = false

## Downloads one map: `func(id: StringName) -> GSResult`. Set by the shell ([TmcSoloMaps]).
var fetch_fn: Callable = Callable()

## The map the player asked to start on (`?map=`, `--solo-map`), &"" for the game's own first map.
## Only a request: the game checks it is a map it has or can fetch.
var start_map: StringName = &""

## Whether the game's manifest has `provides.accepts`. A game without it takes no
## subscriptions, the sync is not run for it, and its page says so.
var takes_subscriptions: bool = false

## The Workshop's summary for this start (`{}` when it did not run), for the Subscriptions
## page: what mounted, what was skipped and why, whether the player was a guest.
var workshop_summary: Dictionary = {}

## What leaving does. Set by the shell.
var leave_fn: Callable = Callable()

## The `<id>@<version>` keys of the packs the game named beside its own (`dependencies` and
## `server_dependencies`), as they were resolved and mounted.
var pack_keys: PackedStringArray = PackedStringArray()

## Where the packs were downloaded, and the `--content-url` this shell was given (or ""): what a
## second process needs to mount the same packs without fetching them again.
var cache_dir: String = ""
var content_url: String = ""


## GameSpice Menu's Leave calls this on its [member GSMenu.leave_link].
func disconnect_from_server(_reason: String = "") -> void:
	leave()


## Always true while the session exists, so GameSpice Menu shows Leave and routes it here.
func is_connected_to_server() -> bool:
	return true


func leave() -> void:
	if leave_fn.is_valid():
		leave_fn.call_deferred()


## The maps a game can list before they are downloaded (see [member available]). A game that calls this downloads each map when it is picked ([method fetch_map]).
func available_maps() -> Array:
	on_demand = true
	return available.duplicate(true)


## Downloads and mounts the map [param id] (its one-map pack, else its game's map pack), with the shell's busy panel up; [signal maps_changed] fires when it is mounted. Fails loudly, so the game can say so and let the player try again.
func fetch_map(id: StringName) -> GSResult:
	if not fetch_fn.is_valid():
		return GSResult.fail(GSError.CODE_STATE, "This shell cannot download maps.", String(id))
	var got: Variant = await fetch_fn.call(id)
	if got is GSResult:
		return got
	return GSResult.fail(GSError.CODE_STATE, "The map download gave no answer.", String(id))


## `<root>/<subdir>` for every mounted map pack that has that directory: the same answer
## `GSGameContent.map_dirs` gives a server module for the packs its server names.
func map_dirs(subdir: String) -> PackedStringArray:
	var out := PackedStringArray()
	for root in map_roots:
		var dir := root.path_join(subdir) if subdir != "" else root
		if DirAccess.dir_exists_absolute(dir):
			out.append(dir)
	return out


## The user args (after `--`) that start this shell again as the game's own server process: the same game, version and packs, from the same cache, with no menu (see [method TmcSolo.is_sim_child]). A game that hosts its solo session in a second process appends these to its own; one that does not never calls this. Subscribed Workshop packs are not passed, so a start that mounted any returns NOTHING: the game then plays in process, with the packs it has, rather than in a second process that lacks them.
func sim_child_args() -> PackedStringArray:
	if not (workshop_summary.get("mounted", []) as Array).is_empty():
		return PackedStringArray()
	var out := PackedStringArray([TmcSolo.CHILD_FLAG, "1", "--solo", content_id, "--solo-version", version])
	if start_map != &"":
		out.append_array(["--solo-map", String(start_map)])
	if not pack_keys.is_empty():
		out.append_array([TmcSolo.PACKS_FLAG, ",".join(pack_keys)])
	if not map_keys.is_empty():
		out.append_array([TmcSolo.MAPS_FLAG, ",".join(map_keys)])
	if cache_dir != "":
		out.append_array(["--cloud-cache-dir", cache_dir])
	if content_url != "":
		out.append_array(["--content-url", content_url])
	return out


func describe() -> Dictionary:
	return {
		"content_id": content_id,
		"version": version,
		"display_name": display_name,
		"mount_root": mount_root,
		"start_map": String(start_map),
		"map_keys": Array(map_keys),
		"takes_subscriptions": takes_subscriptions,
		"subscribed": (workshop_summary.get("mounted", []) as Array).size(),
	}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray()
	lines.append("solo %s@%s (%s)" % [content_id, version, display_name])
	if start_map != &"":
		lines.append("  start map %s" % start_map)
	for key in map_keys:
		lines.append("  maps %s" % key)
	return lines
