class_name TmcGameIconHint
extends Node

## A game's icon named before the game's pack exists, so the loading screen shows it instead of the GameSpice icon on the very first load of that game.
##
## Where the URL comes from: `?icon=<url>` on the page (a game list, a site card or an embed that already knows the icon links with it) or `--icon-url <url>` on a native command line. Only http(s); a private or local address is refused on a desktop (the same rule as the loading screen's media). Nothing is sent to the URL but a GET. Best effort: no icon, an oversized or unreadable one leaves the GameSpice icon, and the pack's own icon replaces this one the moment it mounts.

signal icon_ready(texture: Texture2D)

const MAX_BYTES := 512 * 1024

var url := ""
## Why the URL was not used ("" when it was, or there was none), for a suite and the log.
var refusal := ""


## What the last fetch brought, by URL: a reconnect shows it at once and does not ask again.
static var _fetched: Dictionary = {}


## Gives [param loading] the requested icon, if there is one: now when this session already fetched it, else when it arrives. Call after the loading screen's reset.
static func start(parent: Node, loading: TmcLoadingScreen) -> void:
	var raw := requested().strip_edges()
	if raw == "" or loading == null:
		return
	if _fetched.has(raw):
		loading.set_hint_icon(_fetched[raw])
		TmcGameIdentity.apply_window("", _fetched[raw])
		return
	var hint := TmcGameIconHint.new()
	parent.add_child(hint)
	hint.icon_ready.connect(func(texture: Texture2D) -> void:
		_fetched[raw] = texture
		loading.set_hint_icon(texture)
		TmcGameIdentity.apply_window("", texture)
		hint.queue_free()
	)
	if not hint.fetch(raw):
		DotLog.info("shell", "icon URL not used", {"why": hint.refusal})
		hint.queue_free()


## The URL asked for by the page or the command line, or "".
static func requested() -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--icon-url")
	if index >= 0 and index + 1 < args.size():
		return args[index + 1]
	if DotPlatform.is_web():
		return DotWeb.query_param("icon")
	return ""


## Why [param raw] cannot be fetched as an icon, or "" when it can.
static func refuse(raw: String, web: bool) -> String:
	var text := raw.strip_edges()
	if not (text.begins_with("https://") or text.begins_with("http://")):
		return "not an http(s) URL"
	if text.length() > 2048:
		return "too long"
	if not web and TmcLoadingScreen.is_private_host(text):
		return "a private or local address"
	return ""


## Starts the fetch of [param raw]. False (and [member refusal] says why) when it is not one to fetch.
func fetch(raw: String, web: bool = DotPlatform.is_web()) -> bool:
	url = raw.strip_edges()
	refusal = refuse(url, web)
	if refusal != "":
		return false
	var request := HTTPRequest.new()
	request.body_size_limit = MAX_BYTES
	request.timeout = 15.0
	add_child(request)
	request.request_completed.connect(func(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
		request.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			refusal = "result %d, status %d" % [result, code]
			return
		var texture := TmcGameIconHint.texture_of(body, headers)
		if texture == null:
			refusal = "not an image this client reads"
			return
		icon_ready.emit(texture)
	)
	if request.request(url) != OK:
		request.queue_free()
		refusal = "the request could not start"
		return false
	return true


## The icon in [param body]: by its content type when the server named one, else by its bytes.
static func texture_of(body: PackedByteArray, headers: PackedStringArray = PackedStringArray()) -> Texture2D:
	if body.is_empty() or body.size() > MAX_BYTES:
		return null
	var ext := ""
	for line in headers:
		var low := line.to_lower()
		if low.begins_with("content-type:"):
			for kind in ["svg", "png", "webp", "jpeg", "jpg"]:
				if kind in low:
					ext = kind
					break
	if ext == "":
		var head := body.slice(0, 8)
		if head.size() >= 4 and head[0] == 0x89 and head[1] == 0x50:
			ext = "png"
		elif head.size() >= 3 and head[0] == 0xFF and head[1] == 0xD8:
			ext = "jpg"
		elif head.size() >= 4 and head[0] == 0x52 and head[1] == 0x49:
			ext = "webp"
		else:
			ext = "svg"
	return TmcGameIdentity.texture_from_bytes(body, ext)
