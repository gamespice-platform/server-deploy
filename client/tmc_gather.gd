class_name TmcGather
extends RefCounted

## Runs several awaitable calls at once and returns when every one has finished, so independent network
## fetches cost the slowest round trip instead of the sum. Results come back in the order the calls were given.
## `var out: Array = await TmcGather.run([_a.bind(1), _b])`

signal _all_done

var results: Array = []
var _left := 0


## [param calls] are Callables (coroutines or plain functions); the result of each is at the same index.
static func run(calls: Array) -> Array:
	var gather := TmcGather.new()
	gather.results.resize(calls.size())
	gather._left = calls.size()
	for i in calls.size():
		gather._one(i, calls[i] as Callable)
	if gather._left > 0:
		await gather._all_done
	return gather.results


func _one(index: int, call: Callable) -> void:
	results[index] = await call.call()
	_left -= 1
	if _left == 0:
		_all_done.emit()
