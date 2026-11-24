class_name TmcGather
extends RefCounted

## Runs several awaitable calls at once and returns when every one has finished, so independent network
## fetches cost the slowest round trip instead of the sum. Results come back in the order the calls were given.
## `var out: Array = await TmcGather.run([_a.bind(1), _b])`

signal _all_done

var results: Array = []
var _left := 0


## [param calls] are Callables (coroutines or plain functions); the result of each is at the same index.
## `timeout_ms` 0 waits as long as the calls take. Above 0, calls still running when it passes are reported with push_error
## and their slots stay null, so a stuck call fails loudly instead of hanging the caller.
static func run(calls: Array, timeout_ms: int = 0) -> Array:
	var gather := TmcGather.new()
	gather.results.resize(calls.size())
	gather._left = calls.size()
	for i in calls.size():
		gather._one(i, calls[i] as Callable)
	if gather._left > 0:
		if timeout_ms > 0:
			Engine.get_main_loop().create_timer(timeout_ms / 1000.0).timeout.connect(gather._expire.bind(timeout_ms))
		await gather._all_done
	return gather.results


func _one(index: int, call: Callable) -> void:
	results[index] = await call.call()
	_left -= 1
	if _left == 0:
		_all_done.emit()


func _expire(timeout_ms: int) -> void:
	if _left > 0:
		push_error("TmcGather: %d of %d calls still running after %d ms" % [_left, results.size(), timeout_ms])
		_left = 0
		_all_done.emit()
