extends SceneTree

## Unpacks the metadata of an exported pck (every *.remap, *.uid, *.import, *.tscn, *.tres, *.cfg and the path list) into a
## directory, so tools/check_artifact_static.py judges the exact built artifact, not the repo tree. Godot itself reads the pck:
## the format changes between engine versions and a hand-rolled parser misread v4.
##   godot --headless --script tools/artifact_unpack.gd -- <pck> <outdir>

const KEEP := ["remap", "uid", "import", "tscn", "tres", "cfg", "godot", "json"]


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2:
		printerr("artifact_unpack: usage: -- <pck> <outdir>")
		quit(2)
		return
	if not ProjectSettings.load_resource_pack(args[0], false):
		printerr("artifact_unpack: cannot load %s" % args[0])
		quit(2)
		return
	var list := PackedStringArray()
	var n := _walk("res://", args[1], list)
	var f := FileAccess.open(args[1].path_join("_paths.txt"), FileAccess.WRITE)
	f.store_string("\n".join(list) + "\n")
	f.close()
	print("artifact_unpack: %d files listed, %d unpacked" % [list.size(), n])
	quit(0)


func _walk(dir: String, out: String, list: PackedStringArray) -> int:
	var n := 0
	var d := DirAccess.open(dir)
	if d == null:
		return 0
	for sub in d.get_directories():
		n += _walk(dir.path_join(sub), out, list)
	for fn in d.get_files():
		var p := dir.path_join(fn)
		list.append(p)
		if fn.get_extension() in KEEP:
			var rel := p.trim_prefix("res://")
			DirAccess.make_dir_recursive_absolute(out.path_join(rel).get_base_dir())
			var src := FileAccess.open(p, FileAccess.READ)
			if src == null:
				continue
			var dst := FileAccess.open(out.path_join(rel), FileAccess.WRITE)
			dst.store_buffer(src.get_buffer(src.get_length()))
			n += 1
	return n
