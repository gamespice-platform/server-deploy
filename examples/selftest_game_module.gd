class_name SelftestGameModule
extends RefCounted

## Which module a game change leaves loaded. Run by `selftest.gd`, which keeps the counters: every check goes through its `_check`.

var t: Node


func _init(p_test: Node) -> void:
	t = p_test


func _section(title: String) -> void:
	t._section(title)


func _done() -> void:
	t._done()


func _check(condition: bool, what: String, detail: String = "") -> bool:
	return t._check(condition, what, detail)


func _descriptor(module_path: String) -> GSGameDescriptor:
	var descriptor := GSGameDescriptor.new()

	if module_path != "":
		descriptor.metadata["module"] = module_path

	return descriptor


func _test_game_module() -> void:
	_section("the module a game change keeps")
	var module := "game/hungry_module.gd"
	_check(TmcGameModule.wanted(_descriptor(module), _descriptor(""), "") == module, "a game in the content list loads the module its game.yml names")
	_check(TmcGameModule.wanted(_descriptor(""), _descriptor(module), module) == "", "a listed game with no module unloads the previous one")
	_check(TmcGameModule.wanted(null, _descriptor(module), "") == module, "a game only its module registers loads the module its own metadata names")
	_check(TmcGameModule.wanted(null, _descriptor(""), module) == module, "a mode change to a game neither list names keeps the loaded module")
	_check(TmcGameModule.wanted(null, null, module) == module, "no running game keeps the loaded module")
	_done()
