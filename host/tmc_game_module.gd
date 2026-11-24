class_name TmcGameModule
extends RefCounted

## Which game module the host keeps loaded as the running game changes.

## The module path the running game needs. A game the content list knows names it in its game.yml; a game only its module registers
## (Hungario's other modes, from [code]game_descriptors()[/code]) is not in that list and carries it in its own metadata. A game known
## to neither keeps the module already loaded: unloading it on a mode change strips the server of its commands and nodes.
static func wanted(installed: GSGameDescriptor, current: GSGameDescriptor, loaded: String) -> String:
	if installed != null:
		return String(installed.metadata.get("module", ""))

	if current != null:
		var stamped := String(current.metadata.get("module", ""))

		if stamped != "":
			return stamped

	return loaded
