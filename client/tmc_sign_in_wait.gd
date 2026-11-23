class_name TmcSignInWait
extends RefCounted
## Runs the shell's sign-in without letting a stalled backbone block the start: solo and connect must not hang on it.

## Seconds a start waits for the sign-in before going on as a guest. 0 waits forever.
const TIMEOUT_S := 30.0

signal _settled

var _done := false


## Awaits `sign_in`, but gives up after [param timeout_s] and returns so the start goes on as a guest; a sign-in that
## finishes later still applies its identity.
static func bounded(host: Node, sign_in: Callable, timeout_s: float = TIMEOUT_S) -> void:
	var wait := TmcSignInWait.new()
	wait._run(sign_in)
	if wait._done:
		return
	if timeout_s > 0.0:
		host.get_tree().create_timer(timeout_s).timeout.connect(wait._settled.emit)
	await wait._settled
	if not wait._done:
		GSLog.warn("tmc.shell", "sign-in did not finish in time; starting as a guest", {"seconds": timeout_s})


func _run(sign_in: Callable) -> void:
	await sign_in.call()
	_done = true
	_settled.emit()
