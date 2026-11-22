extends Node

## What the shell shows as the game: its name and icon on the loading screen and on the OS window, GameSpice's before and after, and "Powered by GameSpice / Made with Godot" under both. No server and no pack download.

const CHECKS := 26

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


func _ready() -> void:
	_run.call_deferred()


func _check(condition: bool, what: String, detail: String = "") -> void:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what)
		print("  FAIL  %s%s" % [what, "" if detail == "" else "  (%s)" % detail])


func _run() -> void:
	print("game identity")
	var titles: Array = []
	var icons: Array = []
	TmcGameIdentity.title_fn = func(t: String) -> void: titles.append(t)
	TmcGameIdentity.icon_fn = func(i: Image) -> void: icons.append(i)

	print("names")
	_check(TmcGameIdentity.display_name("Fatal Contact") == "Fatal Contact", "a display name passes")
	_check(TmcGameIdentity.display_name("Zee's Playlot", "mg-playlot") == "Zee's Playlot", "an apostrophe and spaces pass")
	_check(TmcGameIdentity.display_name("mg-prop-hunt") == "", "a repository name is refused")
	_check(TmcGameIdentity.display_name("game-zombie-zone") == "", "a game- repository name is refused")
	_check(TmcGameIdentity.display_name("airdrift", "airdrift") == "", "the content id itself is refused")
	_check(TmcGameIdentity.display_name("  ") == "", "a blank name is refused")
	_check(TmcGameIdentity.display_name("Zee's Airdrift".repeat(10)).length() == 64, "a long name is cut")

	print("icon path")
	_check(TmcGameIdentity.icon_rel({}) == "icon.svg", "no metadata asks for icon.svg")
	_check(TmcGameIdentity.icon_rel({"icon": "art/logo.png"}) == "art/logo.png", "metadata.icon is used")
	_check(TmcGameIdentity.icon_rel({"icon": "../../secret.png"}) == "", "an unsafe path is refused")

	print("icon from a mount")
	var shell_icon := TmcGameIdentity.shell_icon()
	_check(shell_icon != null, "the GameSpice icon loads")
	_check(TmcGameIdentity.icon_from_mount("res://client/branding", "gamespice-icon.svg") != null, "an svg in a mount loads")
	_check(TmcGameIdentity.icon_from_mount("res://client/branding", "nothing.svg") == null, "a pack with no icon gives null")
	_check(TmcGameIdentity.icon_from_mount("res://client/branding", "") == null, "an empty path gives null")
	_check(TmcGameIdentity.icon_of_manifest(null) == null, "no manifest gives null")

	print("window")
	TmcGameIdentity.apply_window("Fatal Contact", shell_icon)
	_check(titles == ["Fatal Contact"], "the window takes the game's name", str(titles))
	_check(icons.size() == 1 and (icons[0] as Image).get_width() <= TmcGameIdentity.ICON_SIDE, "and a window-sized icon")
	_check((icons[0] as Image).get_format() == Image.FORMAT_RGBA8, "in RGBA")
	TmcGameIdentity.apply_window("", null)
	_check(titles[1] == "GameSpice" and icons.size() == 1, "no name is the shell's title and no icon leaves the icon")
	TmcGameIdentity.apply_shell()
	_check(titles[2] == "GameSpice" and icons.size() == 2, "apply_shell restores title and icon")

	print("loading screen")
	var screen := TmcLoadingScreen.new()
	screen.in_game_fn = func() -> bool: return true
	add_child(screen)
	var d := screen.describe()
	_check(d["game_title"] == "GameSpice" and d["game_icon_is_shell"], "before a game is known the header is GameSpice's")
	_check(d["footer"], "the Powered by GameSpice / Made with Godot footer is built")
	screen.begin(TmcLoadingScreen.REASON_GAME, "playlot", "Zee's Playlot", true)
	d = screen.describe()
	_check(d["game_title"] == "Zee's Playlot", "the header names the game", str(d))
	_check(d["game_icon_is_shell"], "a game with no icon yet shows the GameSpice icon")
	var tex := TmcGameIdentity.icon_from_mount("res://client/branding", "godot-icon.svg")
	screen.set_game_icon("playlot", tex)
	_check(not screen.describe()["game_icon_is_shell"], "the game's icon replaces it once known")
	screen.end(TmcLoadingScreen.REASON_GAME)
	screen.begin(TmcLoadingScreen.REASON_GAME, "mg-prop-hunt", "mg-prop-hunt", true)
	_check(screen.describe()["game_title"] == "GameSpice", "a repository name is never shown as the title")
	screen.free()

	TmcGameIdentity.title_fn = Callable()
	TmcGameIdentity.icon_fn = Callable()
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)
