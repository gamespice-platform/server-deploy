class_name TmcGameIdentity
extends RefCounted

## Who the shell is showing as: the OS window's title and icon, and the icon on the loading screen. The shell itself is GameSpice; once a game is known the window carries the game's display name and its icon, and goes back to GameSpice when the game is left.
##
## Where a game's identity comes from (what a game must publish, see docs/web-client.md "Window and loading identity"):
##   * the name: the pack manifest's `display_name`, which is `name:` in the game's `game.yml` (the server sends the same string with `game_changed`). A name that is only a repository or content id (`mg-prop-hunt`) is refused, so the window keeps the shell's title rather than showing it.
##   * the icon: a file in the pack, named by `metadata.icon` in the manifest (pack-relative; `tools/pack.gd` stamps it from `icon:` in `game.yml`, else the source project's `config/icon`, else `icon.svg`).
## A pack with no icon shows the GameSpice icon.

const SHELL_TITLE := "GameSpice"
const GS_ICON := "res://client/branding/gamespice-icon.svg"
const GS_NAME := "GameSpice"
const GODOT_LOGO := "res://client/branding/godot-logo.svg"
const DEFAULT_ICON := "icon.svg"

## Pixels on a side the icon is kept at: a window icon past this is only memory.
const ICON_SIDE := 256
const MAX_ICON_BYTES := 2 * 1024 * 1024

## Icons this device has seen, so the next load of a game shows its icon from the first frame.
const CACHE_DIR := "user://tmc_game_icons"

## `func(title: String)` and `func(icon: Image)`. Seams for a suite; the engine's own window calls when unset.
static var title_fn: Callable = Callable()
static var icon_fn: Callable = Callable()

## What the last [method apply_window] left in effect, for a suite.
static var last_title := ""


## True when [param raw] reads as a repository or content id and not as something to show a player: `mg-prop-hunt`, `game-zombie-zone`, or the id itself.
static func looks_like_id(raw: String, content_id: String = "") -> bool:
	var text := raw.strip_edges()
	if text == "":
		return false
	if content_id != "" and (text == content_id or text == content_id.get_slice("/", content_id.get_slice_count("/") - 1)):
		return true
	return " " not in text and "-" in text and text == text.to_lower()


## The name to show for a game: [param raw] cleaned, or "" when there is none worth showing.
static func display_name(raw: String, content_id: String = "") -> String:
	var text := raw.strip_edges()
	if text == "" or looks_like_id(text, content_id):
		return ""
	return text.substr(0, 64)


## The path a pack's icon is named by in [param metadata] (the manifest's), pack-relative; "" when it is unsafe.
static func icon_rel(metadata: Dictionary) -> String:
	var rel := str(metadata.get("icon", DEFAULT_ICON)).strip_edges()
	if rel == "":
		rel = DEFAULT_ICON
	var safe := DotPaths.safe_relative(rel)
	return rel if safe.ok else ""


## The manifest [param cloud] acquired for [param content_id], whatever its version, or null.
static func manifest_of(cloud: Object, content_id: String) -> DotCloudManifest:
	if cloud == null or content_id == "":
		return null
	for key in cloud.acquired_keys():
		if str(key).begins_with(content_id + "@"):
			return cloud.manifest_for(str(key))
	return null


## The icon of the pack mounted at [param prefix] (`res://dot_cloud/<id>/<version>`), or null when it has none. Tries the imported resource first and the raw file after: a pack published before an import has only the second.
static func icon_from_mount(prefix: String, rel: String) -> Texture2D:
	if rel == "":
		return null
	var path := prefix.path_join(rel)
	if ResourceLoader.exists(path):
		var loaded: Variant = load(path)
		if loaded is Texture2D:
			return loaded
	if not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty() or bytes.size() > MAX_ICON_BYTES:
		return null
	return texture_from_bytes(bytes, path.get_extension().to_lower())


static func texture_from_bytes(bytes: PackedByteArray, ext: String) -> Texture2D:
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	match ext:
		"svg":
			err = img.load_svg_from_buffer(bytes, 2.0)
		"png":
			err = img.load_png_from_buffer(bytes)
		"webp":
			err = img.load_webp_from_buffer(bytes)
		"jpg", "jpeg":
			err = img.load_jpg_from_buffer(bytes)
	if err != OK or img.is_empty():
		return null
	return ImageTexture.create_from_image(img)


## The icon [param manifest] names, mounted or not: null when the pack has none.
static func icon_of_manifest(manifest: DotCloudManifest) -> Texture2D:
	if manifest == null:
		return null
	return icon_from_mount(manifest.mount_prefix(), icon_rel(manifest.metadata))


static func shell_icon() -> Texture2D:
	return load(GS_ICON) as Texture2D


## An icon for a window: square-bounded, RGBA, never larger than [constant ICON_SIDE]. Null for a texture that has no image.
static func window_image(icon: Texture2D) -> Image:
	if icon == null:
		return null
	var img := icon.get_image()
	if img == null or img.is_empty():
		return null
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	if maxi(img.get_width(), img.get_height()) > ICON_SIDE:
		var scale := float(ICON_SIDE) / float(maxi(img.get_width(), img.get_height()))
		img.resize(maxi(1, int(img.get_width() * scale)), maxi(1, int(img.get_height() * scale)), Image.INTERPOLATE_LANCZOS)
	return img


## Sets the OS window's title and icon. An empty title is the shell's; a null icon leaves the icon alone.
static func apply_window(title: String, icon: Texture2D) -> void:
	var shown := title if title != "" else SHELL_TITLE
	last_title = shown
	if title_fn.is_valid():
		title_fn.call(shown)
	else:
		DisplayServer.window_set_title(shown)
	var img := window_image(icon)
	if img == null:
		return
	if icon_fn.is_valid():
		icon_fn.call(img)
	else:
		DisplayServer.set_icon(img)


## The shell's own title and icon: before a game is known and after it is left.
static func apply_shell() -> void:
	apply_window(SHELL_TITLE, shell_icon())


## Remembers [param icon] for [param content_id] on this device. Best effort.
static func cache_icon(content_id: String, icon: Texture2D) -> void:
	var img := window_image(icon)
	if img == null or content_id == "":
		return
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	img.save_png("%s/%s.png" % [CACHE_DIR, content_id.replace("/", "_")])


static func cached_icon(content_id: String) -> Texture2D:
	var path := "%s/%s.png" % [CACHE_DIR, content_id.replace("/", "_")]
	if content_id == "" or not FileAccess.file_exists(path):
		return null
	return texture_from_bytes(FileAccess.get_file_as_bytes(path), "png")
