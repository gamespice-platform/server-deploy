class_name TmcDownloadWatch
extends RefCounted

## What the shell knows about a download from its byte counts alone: the rate and estimate over the last few seconds, and whether it has stopped.
## GameSpice Cloud's snapshot carries a rate that only changes when bytes arrive, so a transfer that stalled kept showing its last good "33.6 MiB/s" beside a frozen bar; this is fed the clock too, so a stall shows as one.
## Pure: time is passed in (msec), so a test drives it without waiting.

## Seconds of history the rate is taken over.
const WINDOW_SEC := 8.0
## Seconds with no new byte before the download counts as stalled.
const STALL_SEC := 20.0

var window_sec := WINDOW_SEC
var stall_sec := STALL_SEC

var _samples: Array = []   # [msec, done_bytes], oldest first
var _total := 0
var _done := 0
var _last_progress_msec := -1
var _stall_logged := false


## Starts again, for a new download.
func reset() -> void:
	_samples.clear()
	_total = 0
	_done = 0
	_last_progress_msec = -1
	_stall_logged = false


## A report of [param done] of [param total] bytes at [param now_msec]. Only more bytes than before count as progress.
func feed(done: int, total: int, now_msec: int) -> void:
	if _last_progress_msec < 0 or done > _done:
		_last_progress_msec = now_msec
		_stall_logged = false
	_done = done
	_total = total
	_samples.append([now_msec, done])
	var cutoff := now_msec - int(window_sec * 1000.0)
	while _samples.size() > 2 and int((_samples[1] as Array)[0]) <= cutoff:
		_samples.pop_front()


## Bytes per second over the window ending at [param now_msec]; 0 when stalled or too little is known.
func rate(now_msec: int) -> float:
	if _samples.size() < 2 or is_stalled(now_msec):
		return 0.0
	var first: Array = _samples[0]
	var last: Array = _samples[_samples.size() - 1]
	# Measured to now, not to the last sample: a transfer that went quiet decays rather than holding its old speed.
	var dt := float(now_msec - int(first[0])) / 1000.0
	if dt < 0.5:
		return 0.0
	return float(int(last[1]) - int(first[1])) / dt


## Seconds left at the current rate, or -1 when there is no honest answer (no rate, or under 2 % done).
func eta_sec(now_msec: int) -> float:
	var r := rate(now_msec)
	if r <= 1.0 or _total <= 0 or float(_done) / float(_total) < 0.02:
		return -1.0
	return float(_total - _done) / r


## Seconds since a byte last arrived.
func quiet_sec(now_msec: int) -> float:
	if _last_progress_msec < 0:
		return 0.0
	return float(now_msec - _last_progress_msec) / 1000.0


func is_stalled(now_msec: int) -> bool:
	return _last_progress_msec >= 0 and _done < _total and quiet_sec(now_msec) >= stall_sec


## True once per stall, so the log says it one time and not every tick.
func take_stall_report(now_msec: int) -> bool:
	if is_stalled(now_msec) and not _stall_logged:
		_stall_logged = true
		return true
	return false
