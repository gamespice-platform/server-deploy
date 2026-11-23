class_name TmcShellDownloadGuard
extends RefCounted

## Keeps a solo launch's download from looking frozen: a once-a-second tick that redraws the rate and estimate from the bytes actually arriving (see [TmcDownloadWatch]), says so when none have for a while, and offers Retry for a fetch that stalls. Every transition is logged with its time, so a stall that ended on its own is still diagnosable afterwards.
## The shell owns the bar and the text; this owns when they say "stalled" and the buttons.

## Seconds between redraws of the line while bytes (or the lack of them) change it.
const TICK_SEC := 1.0

var shell: Node = null
var watch := TmcDownloadWatch.new()
## What the player asked of a launch that is still downloading: "" (nothing) or "retry". [method TmcShellSolo._load_solo_inner] stops at it and [method TmcShellSolo._start_solo] starts over.
var requested := ""

var _box: HBoxContainer = null
var _retry: Button = null
var _timer: Timer = null
var _phase := ""
var _begin_msec := 0
var _done_packs := -1


func _init(owner_shell: Node) -> void:
	shell = owner_shell


## The Retry button, hidden, under the shell's detail line.
func build(parent: VBoxContainer) -> void:
	_box = HBoxContainer.new()
	_box.add_theme_constant_override("separation", 8)
	_box.visible = false
	_retry = Button.new()
	_retry.text = shell._text("shell.job.retry", {}, "Retry")
	_retry.pressed.connect(_on_retry)
	_box.add_child(_retry)
	parent.add_child(_box)
	_timer = Timer.new()
	_timer.wait_time = TICK_SEC
	_timer.timeout.connect(tick)
	shell.add_child(_timer)


## A launch begins.
func begin() -> void:
	watch.reset()
	requested = ""
	_phase = ""
	_done_packs = -1
	_begin_msec = Time.get_ticks_msec()
	if _timer != null:
		_timer.start()
	_show_buttons(false)
	GSLog.info(shell.CHANNEL, "solo download begins", {"stall_sec": watch.stall_sec})


func end() -> void:
	if _timer != null:
		_timer.stop()
	_show_buttons(false)
	if _begin_msec > 0:
		GSLog.info(shell.CHANNEL, "solo download ended", {"after_ms": Time.get_ticks_msec() - _begin_msec, "requested": requested})
	_begin_msec = 0


## A job snapshot from GameSpice Cloud.
## Returns it with the rate and ETA from the bytes that arrived in the last seconds: the addon's figures hold their last speed when a transfer stops.
func on_snapshot(snap: Dictionary) -> Dictionary:
	var now := Time.get_ticks_msec()
	var phase := str(snap.get("phase", "download"))
	if phase == "download":
		watch.feed(int(snap.get("done_bytes", 0)), int(snap.get("total_bytes", 0)), now)
	if phase != _phase:
		_phase = phase
		GSLog.info(shell.CHANNEL, "solo job phase", {"phase": phase, "at_ms": now - _begin_msec,
			"done_bytes": int(snap.get("done_bytes", 0)), "total_bytes": int(snap.get("total_bytes", 0))})
	var packs := int(snap.get("done_packs", 0))
	if packs != _done_packs:
		_done_packs = packs
		GSLog.info(shell.CHANNEL, "solo pack finished", {"done_packs": packs, "total_packs": int(snap.get("total_packs", 0)),
			"at_ms": now - _begin_msec, "done_bytes": int(snap.get("done_bytes", 0))})
	_show_buttons(phase == "download" and watch.is_stalled(now))
	snap["bytes_per_sec"] = watch.rate(now)
	snap["eta_sec"] = watch.eta_sec(now)
	return snap


## Every second while a launch downloads: the numbers from what arrived, and the stall message when nothing did.
func tick() -> void:
	if not shell._launch_job or _phase != "download":
		return
	var now := Time.get_ticks_msec()
	if watch.take_stall_report(now):
		GSLog.warn(shell.CHANNEL, "solo download stalled", {"quiet_s": watch.quiet_sec(now), "done_bytes": watch.done_bytes(), "total_bytes": watch.total_bytes(), "at_ms": now - _begin_msec})
	var stalled := watch.is_stalled(now)
	_show_buttons(stalled)
	_redraw(stalled)


## The launch's download text again: its numbers decay and the stall message appears without a new snapshot.
func _redraw(stalled: bool) -> void:
	var job: Dictionary = shell._job
	if job.is_empty() or int(job.get("total_bytes", 0)) <= 0:
		return
	var now := Time.get_ticks_msec()
	job["bytes_per_sec"] = watch.rate(now)
	job["eta_sec"] = watch.eta_sec(now)
	var line: String = shell._job_line()
	var title: String = shell._text("shell.job.downloading_title", {}, "Downloading…")
	if stalled:
		var quiet := int(watch.quiet_sec(now))
		title = shell._text("shell.job.stalled_title", {}, "Download stalled")
		line = shell._text("shell.job.stalled", {"n": quiet}, "No data for %d s. The server may be busy; it is still trying." % quiet) + "\n" + line
	if shell._status != null:
		shell._status.text = title
	if shell.loading != null:
		shell.loading.set_progress(float(job.get("fraction", 0.0)), title, line)
	if shell._detail != null:
		shell._detail.text = line
		shell._detail.visible = true


func is_stalled() -> bool:
	return watch.is_stalled(Time.get_ticks_msec())


func _show_buttons(retry: bool) -> void:
	if _box == null:
		return
	_retry.visible = retry
	_box.visible = retry


func _on_retry() -> void:
	_ask("retry")


## Stops the transfer in flight; the launch notices [member requested] and starts over.
func _ask(what: String) -> void:
	GSLog.info(shell.CHANNEL, "solo download %s asked by the player" % what, {"at_ms": Time.get_ticks_msec() - _begin_msec, "done_bytes": watch.done_bytes()})
	requested = what
	_show_buttons(false)
	shell._cloud.cancel()
