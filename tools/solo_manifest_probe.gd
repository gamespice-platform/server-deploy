extends SceneTree

## Does the shipped gs-cloud client PARSE and VERIFY the signed manifest a content origin serves?
##
## The solo outage of 2026-11-22 was exactly this and nothing else: the client changed the envelope marker, every
## published manifest still carried the old one, and "Could not download the content manifest" was all a player saw.
## cloud_fetch_probe.gd proves a whole pack (fetch, verify, mount, read back) but downloads every object; this fetches
## the manifests only, through the client's own fetch_manifest (the call `ensure` makes: download, parse, verify), so it is cheap
## enough to gate a publish on, for several games, against the origin the shell will point at.
##
##   godot --headless --path . -s tools/solo_manifest_probe.gd -- <manifest URL>...
##
## The REAL client/content.json is the trust policy, the same file the shell ships. Exit 0 when every URL parsed and
## verified, 1 when any did not (each named with the client's own message), 2 for no URLs.
## GS_SMOKE_STRICT_MARKER=1 additionally fails a manifest that carries the legacy `dot_cloud_signed` marker: the state
## after prod is re-signed and the read-only alias is removed, so a shell that no longer reads it is known safe.

const CONTENT_CONFIG := "res://client/content.json"


func _init() -> void:
	var urls := OS.get_cmdline_user_args()
	if urls.is_empty():
		print("[solo-smoke] no manifest URLs given")
		quit(2)
		return

	await process_frame

	var client := GSCloudClient.new()
	client.name = "Cloud"
	client.config = GSCloudConfig.new()
	client.config.side = "client"
	client.config_file = OS.get_environment("GS_SMOKE_CONTENT_CONFIG") if OS.get_environment("GS_SMOKE_CONTENT_CONFIG") != "" else CONTENT_CONFIG
	client.config.cache_dir = "user://smoke_cache_%d" % Time.get_ticks_msec()
	root.add_child(client)
	await process_frame

	# A hung request must fail the gate, not hold the publish for ever.
	create_timer(120.0).timeout.connect(func() -> void:
		print("[solo-smoke] FAIL no answer within 120 s")
		quit(1))

	# config_file (the trust policy) is applied by start(); fetch_manifest alone would verify against no keys.
	var started: GSResult = await client.start()
	if not started.ok:
		print("[solo-smoke] FAIL the cloud client did not start: %s" % started.error.message)
		quit(1)
		return

	var strict := OS.get_environment("GS_SMOKE_STRICT_MARKER") == "1"
	var failed := 0

	for url in urls:
		var res: GSResult = await client.fetch_manifest(url)
		if not res.ok:
			failed += 1
			print("[solo-smoke] FAIL %s: %s" % [url, res.error.message])
			continue

		var m: GSCloudManifest = res.value
		var marker: String = await _marker_of(client, url)
		if strict and marker == GSCloudEnvelope.LEGACY_MARKER:
			failed += 1
			print("[solo-smoke] FAIL %s: still signed with the legacy marker '%s' (strict)" % [url, marker])
			continue
		print("[solo-smoke] ok   %s -> %s@%s, %d files, signature verified (marker %s)" % [
			url, m.content_id, m.version, m.files.size(), marker])

	quit(1 if failed > 0 else 0)


## The marker the document carries, read from the same URL the client fetched.
func _marker_of(client: GSCloudClient, url: String) -> String:
	var res: GSResult = await client._http.get_bytes(url)
	if not res.ok:
		return "?"
	var d: Variant = JSON.parse_string((res.value as PackedByteArray).get_string_from_utf8())
	if d is Dictionary:
		for k in [GSCloudEnvelope.MARKER, GSCloudEnvelope.LEGACY_MARKER]:
			if (d as Dictionary).has(k):
				return k
	return "none"
