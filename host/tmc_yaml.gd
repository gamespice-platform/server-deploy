class_name TmcYaml
extends RefCounted

## The server's name for GameSpice Core's [GSYaml], the family's one YAML subset reader. Kept as a
## wrapper rather than replaced at every call site so TmcConfig, TmcContent, install_games and the
## rest keep one name for "read an operator's file", and so a second parser cannot grow back here.

## Longest line accepted, in characters. Mirrors [constant GSYaml.MAX_LINE].
const MAX_LINE := GSYaml.MAX_LINE

## Deepest nesting accepted. Mirrors [constant GSYaml.MAX_DEPTH].
const MAX_DEPTH := GSYaml.MAX_DEPTH


## Parses YAML text into a [Dictionary]. See [method GSYaml.parse].
static func parse(text: String, source: String = "<string>") -> GSResult:
	return GSYaml.parse(text, source)


## Parses a file; a missing file is a failure. See [method GSYaml.parse_file].
static func parse_file(path: String) -> GSResult:
	return GSYaml.parse_file(path)


## Fetches a nested value by a dotted path. See [method GSYaml.at].
static func at(tree: Dictionary, path: String, fallback: Variant = null) -> Variant:
	return GSYaml.at(tree, path, fallback)
