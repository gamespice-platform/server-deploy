class_name TmcBusyBridge
extends RefCounted

## Shows the shared bottom-right busy panel (gs-core's GSBusyIndicator) for a content fetch the shell does not put the blocking cover over: a map change in a live game, a solo game, a late sync of suggested packs. The blocking cover is skipped there on purpose; before this the fetch then ran with nothing on screen (the 1 FPS "nothing spawns" period of a Playlot map change).
## Duck-typed: a gs-core older than the indicator has no such class, and then this does nothing.

const SERVICE := &"gs_busy_indicator"
const CLASS_NAME := "GSBusyIndicator"
const SOURCE := &"content"


## The indicator in use: the one a game or gate registered, else one made under [param host]; null when this gs-core has none. It follows [param cloud] from then on.
static func ensure(host: Node, cloud: Object) -> Node:
	var found: Variant = GSRegistry.get_service(SERVICE)
	var indicator: Node = found as Node if found is Node else null
	if indicator == null:
		var script := _script_of(CLASS_NAME)
		if script == null or host == null:
			return null
		indicator = script.new() as Node
		if indicator == null:
			return null
		host.add_child(indicator)
	if cloud != null and indicator.has_method(&"bind_cloud"):
		indicator.call(&"bind_cloud", cloud)
	return indicator


## A fetch started that the cover skipped: the panel says what it is doing.
static func begin(host: Node, cloud: Object, text: String) -> void:
	var indicator := ensure(host, cloud)
	if indicator != null and indicator.has_method(&"begin"):
		indicator.call(&"begin", SOURCE, text)


## The fetch finished or failed.
static func end() -> void:
	var found: Variant = GSRegistry.get_service(SERVICE)
	if found is Node and (found as Node).has_method(&"end"):
		(found as Node).call(&"end", SOURCE)


static func _script_of(class_name_: String) -> Script:
	for entry: Dictionary in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == class_name_:
			return load(str(entry.get("path", ""))) as Script
	return null
