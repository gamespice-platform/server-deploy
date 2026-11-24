extends Node
# [b]Nothing preloaded out of a game, because no game is in this build.[/b] Hungario is a
# delivered pack.

## A client joins a server that is hibernating. The game's own RPC link must be under `Server`
## before the client's first RPC reaches it: the engine drops an RPC to a node the receiver lacks
## with "Node not found" and "Invalid packet received". Exits non-zero on any failure.

const CONFIG := "res://examples/fixtures/hibernated_join"
const ServerWorld := preload("res://examples/server_world.gd")
const RpcPathWatch := preload("res://examples/rpc_path_watch.gd")
const CONTENT := "res://content"
const DATA := "user://tmc_hibernated_join"
const SHELL := "res://client/shell.tscn"
const GAME := "hungry_classic"

## How far the game's link counters must move to count as traffic.
const MIN_TRAFFIC := 10

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _host: Node = null
var _shell: Node = null


func _ready() -> void:
	GSLog.set_level(
		GSLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args() else GSLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("gs-server-deploy: a client joins a hibernating server")

	if not FileAccess.file_exists("res://dist/tmc/hungry/manifest.json"):
		print("skipped: tmc/hungry is not published in dist/ here")
		get_tree().quit(0)
		return

	GSPaths.remove_tree(DATA)
	var rpc_watch := RpcPathWatch.new()
	OS.add_logger(rpc_watch)

	if await _boot():
		await _join()

	await _teardown()
	GSPaths.remove_tree(DATA)
	OS.remove_logger(rpc_watch)

	_check(
		rpc_watch.count() == 0,
		"no RPC was addressed to a node the other end does not have (%d)" % rpc_watch.count(),
		rpc_watch.summary()
	)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	get_tree().quit(1 if _failed > 0 else 0)


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s: %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	return condition


func _server() -> GSServer:
	if _host == null or not is_instance_valid(_host):
		return null
	return _host.server as GSServer


func _until(condition: Callable, seconds: float = 20.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().physics_frame
	return bool(condition.call())


func _boot() -> bool:
	print("booting")
	_host = (load("res://host/host.tscn") as PackedScene).instantiate()
	_host.name = "Host"
	_host.auto_start = false
	ServerWorld.add(self, _host)
	_host.port_override = -1
	var started: GSResult = await _host.start(CONFIG, CONTENT, DATA)
	if not _check(started.ok, "the host boots", str(started.error)):
		return false

	var loaded := await _until(
		func() -> bool:
			var current := _server().games.current()
			return current != null and current.game_id == GAME \
				and _server().games.phase == GSGameManager.Phase.IDLE,
		60.0
	)
	return _check(loaded, "the server loaded %s" % GAME)


## The game's link, as the engine resolves a client's RPC: by path under the server node.
func _server_link() -> Node:
	return _server().get_node_or_null(NodePath("Hungry"))


func _join() -> void:
	print("joining a sleeping server")
	var slept := await _until(func() -> bool: return _server().is_hibernating(), 30.0)
	if not _check(slept, "the empty server went to sleep"):
		return
	_check(_server_link() != null, "the game's link is under Server while it sleeps")

	_shell = (load(SHELL) as PackedScene).instantiate()
	_shell.name = "Shell"
	add_child(_shell)
	await get_tree().process_frame
	await get_tree().process_frame
	_shell._ensure_cloud()
	_shell._cloud.http_base_urls = PackedStringArray([
		ProjectSettings.globalize_path("res://dist"),
		ProjectSettings.globalize_path("res://dist/maps"),
	])
	_shell._connect_to("127.0.0.1:%d" % int(_host.config.server.port))

	var link: GSClientLink = null
	var playing := await _until(
		func() -> bool:
			link = _shell.link as GSClientLink if _shell.link != null else null
			return link != null and is_instance_valid(link) \
				and link.phase == GSClientLink.Phase.PLAYING,
		60.0
	)
	_check(playing, "a shell joins the sleeping server")
	_check(not _server().is_hibernating(), "and the server woke")

	var server_link := _server_link()
	if not _check(server_link != null, "the game's link is under Server after the join"):
		return
	var start := int(server_link.get("inputs_received"))
	var moved := await _until(
		func() -> bool:
			return is_instance_valid(server_link) \
				and int(server_link.get("inputs_received")) - start >= MIN_TRAFFIC,
		20.0
	)
	_check(moved, "the client's inputs reach the game's link")


func _teardown() -> void:
	if _shell != null and is_instance_valid(_shell):
		var link: Variant = _shell.link
		if link != null and is_instance_valid(link):
			link.disconnect_from_server()
		remove_child(_shell)
		_shell.queue_free()
		await get_tree().process_frame
	_shell = null

	if _host != null and is_instance_valid(_host):
		if _host.server != null and is_instance_valid(_host.server):
			_host.server.shutdown("test over")
		ServerWorld.remove(_host)
		_host.free()
		_host = null
		await get_tree().physics_frame
		await get_tree().physics_frame
