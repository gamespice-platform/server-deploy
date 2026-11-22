class_name TmcLoadingIdentityHeader
extends RefCounted

## The loading screen's identity: the game's icon and name above the words, and the "Powered by GameSpice / Made with Godot" footer. Holds which icon each game has (the pack's, the device's memory of it, the server document's, or a launch link's hint) and what the header shows for the game now.

## The game's icon (the GameSpice icon until the game's is known) and name.
var icon: TextureRect = null
var label: Label = null
## "Powered by GameSpice" and "Made with Godot", bottom-centre.
var footer: HBoxContainer = null
## game id -> the icon its pack or the device's memory gave.
var icons: Dictionary = {}
## An icon a launch link named (TmcGameIconHint) for the first game this connection shows, used until the game's own is known. [member hint_game] is the game it was first shown for; another game drops it.
var hint_icon: Texture2D = null
var hint_game := ""
## game id -> the icon the server's loading document named for it (an `icon` URL in the game's entry).
var doc_icons: Dictionary = {}


## Forgets what this connection knew: a new server has its own games and hint.
func forget() -> void:
	icons.clear()
	hint_icon = null
	hint_game = ""


## Builds the icon and name row into [param box].
func build_header(box: Control) -> void:
	var identity := HBoxContainer.new()
	identity.add_theme_constant_override("separation", 14)
	identity.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(identity)
	icon = logo(TmcGameIdentity.shell_icon(), 72.0)
	identity.add_child(icon)
	label = Label.new()
	label.add_theme_font_size_override("font_size", 36)
	label.add_theme_font_override("font", TmcShellStyle.bold(0.8))
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	identity.add_child(label)


## A logo of [param side] pixels square, kept in proportion.
static func logo(tex: Texture2D, side: float) -> TextureRect:
	var rect := TextureRect.new()
	rect.texture = tex
	rect.custom_minimum_size = Vector2(side, side)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


## "Powered by GameSpice" and "Made with Godot" along the bottom edge of [param root], each a logo and its words. The Godot logo is CC BY 4.0, credited in client/branding/ATTRIBUTION.md.
func build_footer(root: Control) -> void:
	footer = HBoxContainer.new()
	footer.name = "Footer"
	footer.anchor_left = 0.5
	footer.anchor_right = 0.5
	footer.anchor_top = 1.0
	footer.anchor_bottom = 1.0
	footer.offset_top = -30.0
	footer.offset_bottom = -6.0
	footer.offset_left = -220.0
	footer.offset_right = 220.0
	footer.alignment = BoxContainer.ALIGNMENT_CENTER
	footer.add_theme_constant_override("separation", 8)
	footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	footer.modulate = Color(1, 1, 1, 0.75)
	root.add_child(footer)
	var parts: Array = [
		[TmcGameIdentity.GS_ICON, "Powered by GameSpice"],
		[TmcGameIdentity.GODOT_LOGO, "Made with Godot"],
	]
	for i in parts.size():
		if i > 0:
			var gap := Control.new()
			gap.custom_minimum_size = Vector2(18.0, 0.0)
			gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
			footer.add_child(gap)
		var tex: Texture2D = load(parts[i][0]) as Texture2D
		footer.add_child(logo(tex, 22.0))
		var words := Label.new()
		words.text = parts[i][1]
		words.add_theme_font_size_override("font_size", 13)
		words.add_theme_color_override("font_color", TmcShellStyle.MUTED)
		footer.add_child(words)


## What the header shows: the game's name and icon, or GameSpice's when the game has no name or icon yet.
func sync(game_id: String, game_name: String) -> void:
	if label == null:
		return
	var shown := TmcGameIdentity.display_name(game_name, game_id)
	label.text = shown if shown != "" else TmcGameIdentity.GS_NAME
	var tex: Texture2D = icons.get(game_id) as Texture2D if game_id != "" else null
	if tex == null and game_id != "":
		tex = TmcGameIdentity.cached_icon(game_id)
		if tex != null:
			icons[game_id] = tex
	if tex == null and game_id != "":
		tex = doc_icons.get(game_id) as Texture2D
	if tex == null and hint_icon != null:
		if hint_game == "" and game_id != "":
			hint_game = game_id
		if hint_game == "" or hint_game == game_id:
			tex = hint_icon
	icon.texture = tex if tex != null else TmcGameIdentity.shell_icon()


## Fetches the icon a loading document's [param entry] names for [param game_id], for [param screen] to show. The window takes it only when the screen is about that game and the device has no icon of the game's own.
func fetch_doc_icon(screen: TmcLoadingScreen, game_id: String, entry: Dictionary) -> void:
	var url := str(entry.get("icon", ""))
	if game_id == "" or url == "" or doc_icons.has(game_id):
		return
	TmcGameIconHint.fetch_to(screen, url, func(tex: Texture2D) -> void:
		doc_icons[game_id] = tex
		screen._sync_identity()
		if game_id == screen._game_id and TmcGameIdentity.cached_icon(game_id) == null:
			TmcGameIdentity.apply_window("", tex)
	)
