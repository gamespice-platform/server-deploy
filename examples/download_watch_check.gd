extends Node

## The shell's download watch ([TmcDownloadWatch]) against a driven clock and against a real misbehaving host (tools/fake_content_server.mjs, started from here):
## the rate follows the bytes that arrive and falls to zero when they stop, a stall is reported once, a 429's Retry-After is readable, and a transfer that goes quiet mid-body is flagged as stalled.
## godot --headless --path . res://examples/download_watch_check.tscn

const CHECKS := 22
const CHECKS_WITHOUT_NODE := 10

var _expected := CHECKS

var _passed := 0
var _failed := 0
var _pid := -1
var _pipe: Dictionary = {}  # held: the server exits when its stdin handle is freed
var _port := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("  FAIL: ", what)


func _run() -> void:
	print("dot-server-deploy: the download watch")
	_test_driven_clock()
	if await _start_server():
		await _test_429()
		await _test_stall()
		await _test_slow_is_not_a_stall()
	else:
		var probe: Array = []
		if OS.execute("node", ["-v"], probe) != 0:
			print("  SKIP: no node on this box, the live 429 / stall / slow checks did not run (run on a box with node)")
			_expected = CHECKS_WITHOUT_NODE
		else:
			_check(false, "the fake content server started")
	if _pid > 0:
		OS.kill(_pid)
	print("%d passed, %d failed (expected %d checks)" % [_passed, _failed, _expected])
	get_tree().quit(0 if _failed == 0 and _passed == _expected else 1)


func _test_driven_clock() -> void:
	var w := TmcDownloadWatch.new()
	w.stall_sec = 10.0
	_check(not w.is_stalled(0) and w.rate(0) == 0.0 and w.eta_sec(0) < 0.0, "nothing fed: not stalled, no rate, no estimate")
	var total := 400 * 1024 * 1024
	for s in range(0, 11):
		w.feed(s * 10 * 1024 * 1024, total, s * 1000)
	var r := w.rate(10000)
	_check(absf(r - 10.0 * 1024.0 * 1024.0) < 1.0 * 1024.0 * 1024.0, "10 MiB/s of arriving bytes reads as about 10 MiB/s (%.1f)" % (r / 1048576.0))
	var eta := w.eta_sec(10000)
	_check(eta > 25.0 and eta < 35.0, "300 MiB left at 10 MiB/s is about 30 s (%.1f)" % eta)
	_check(not w.is_stalled(15000), "five quiet seconds is not a stall under a ten second limit")
	for t in range(11, 24):
		w.feed(100 * 1024 * 1024, total, t * 1000)  # polled, but no new byte
	_check(w.is_stalled(23000), "thirteen quiet seconds is a stall")
	_check(w.rate(23000) == 0.0 and w.eta_sec(23000) < 0.0, "a stalled transfer shows no rate and no estimate, not its last speed")
	_check(w.take_stall_report(23000) and not w.take_stall_report(24000), "the stall is reported once")
	w.feed(101 * 1024 * 1024, total, 25000)
	_check(not w.is_stalled(25000) and not w.take_stall_report(25000), "a byte arriving ends the stall")
	w.feed(total, total, 26000)
	_check(not w.is_stalled(60000), "a finished download is never stalled")
	w.reset()
	_check(not w.is_stalled(100000) and w.quiet_sec(100000) == 0.0, "reset forgets everything")


func _start_server() -> bool:
	var script := ProjectSettings.globalize_path("res://tools/fake_content_server.mjs")
	var pipe := OS.execute_with_pipe("node", [script])
	if pipe.is_empty():
		return false
	_pipe = pipe
	_pid = int(pipe["pid"])
	var out: FileAccess = pipe["stdio"]
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 10000:
		var line := out.get_line()
		if line.begins_with("listening "):
			_port = int(line.get_slice(" ", 1))
			return true
		await get_tree().create_timer(0.05).timeout
	return false


## One GET, read for [param seconds] or to the end: {status, headers, got, total, done}, each byte batch fed to [param watch] when given.
func _fetch(path: String, seconds: float, watch: TmcDownloadWatch = null) -> Dictionary:
	var c := HTTPClient.new()
	c.connect_to_host("127.0.0.1", _port)
	while c.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		c.poll()
		await get_tree().process_frame
	c.request(HTTPClient.METHOD_GET, path, [])
	while c.get_status() == HTTPClient.STATUS_REQUESTING:
		c.poll()
		await get_tree().process_frame
	var out := {"status": c.get_response_code(), "headers": c.get_response_headers_as_dictionary(), "got": 0, "total": 0, "done": false}
	var t0 := Time.get_ticks_msec()
	var total := int(out["headers"].get("content-length", out["headers"].get("Content-Length", 0)))
	out["total"] = total
	while float(Time.get_ticks_msec() - t0) / 1000.0 < seconds:
		c.poll()
		if c.get_status() == HTTPClient.STATUS_BODY:
			out["got"] = int(out["got"]) + c.read_response_body_chunk().size()
		elif c.get_status() != HTTPClient.STATUS_BODY:
			out["done"] = true
			break
		if watch != null:
			watch.feed(int(out["got"]), total, Time.get_ticks_msec())
		if int(out["got"]) >= total and total > 0:
			out["done"] = true
			break
		await get_tree().process_frame
	c.close()
	return out


func _test_429() -> void:
	var first := await _fetch("/throttle/1", 3.0)
	_check(int(first["status"]) == 429, "the host answers 429 first")
	var after := str(first["headers"].get("retry-after", first["headers"].get("Retry-After", "")))
	_check(after == "1", "its Retry-After (1) is in the headers the downloader reads (%s)" % after)
	await get_tree().create_timer(1.0).timeout
	var second := await _fetch("/throttle/1", 3.0)
	_check(int(second["status"]) == 200 and int(second["got"]) == 65536, "after the wait the object is served whole")
	var ok := await _fetch("/ok/1000", 3.0)
	_check(int(ok["status"]) == 200 and int(ok["got"]) == 1000 and bool(ok["done"]), "a plain object arrives")


func _test_stall() -> void:
	var w := TmcDownloadWatch.new()
	w.stall_sec = 1.5
	var r := await _fetch("/stall/1000000", 4.0, w)
	_check(int(r["got"]) >= 32 * 1024 and int(r["got"]) < 1000000, "the host sent its first 32 KiB and then nothing (%d)" % int(r["got"]))
	var now := Time.get_ticks_msec()
	_check(w.is_stalled(now), "the quiet transfer is flagged as stalled after %.1f s quiet" % w.quiet_sec(now))
	_check(w.take_stall_report(now), "and reports it for the log")
	_check(w.rate(now) == 0.0 and w.eta_sec(now) < 0.0, "with no rate shown")
	_check(w.quiet_sec(now) >= 1.5 and w.quiet_sec(now) < 4.0, "quiet time counts from the last byte, not from the start (%.1f)" % w.quiet_sec(now))


func _test_slow_is_not_a_stall() -> void:
	var w := TmcDownloadWatch.new()
	w.stall_sec = 1.5
	var r := await _fetch("/slow/160000", 3.0, w)
	var now := Time.get_ticks_msec()
	_check(int(r["got"]) > 16 * 1024, "a slow host still delivers (%d bytes)" % int(r["got"]))
	_check(not w.is_stalled(now) or bool(r["done"]), "a slow but moving transfer is not a stall")
	var rate := w.rate(now)
	_check(rate > 20000.0 and rate < 400000.0 or bool(r["done"]), "its rate is the slow rate (%.0f B/s)" % rate)
