extends SceneTree

## A saved REAL prod manifest (Airdrift 0.1.34, signed 2026-11-18 under the legacy `dot_cloud_signed` marker) must parse and
## verify with the shipped client's own code, and so must the same document under the current `gs_cloud_signed` marker.
## The signature covers the payload only, so swapping the marker is exactly what a re-sign without a new payload does.
## The 2026-11-22 solo outage was this: the marker changed, the published manifests did not.
##
##   godot --headless --path . -s tests/verify_solo_envelope_test.gd
## Exit 0 all pass, 1 a case failed.

const FIXTURE := "res://tests/fixtures/manifest_legacy_dot_cloud_signed.json"
const CONTENT_CONFIG := "res://client/content.json"

var _failed := 0


func _check(name: String, ok: bool, detail: String = "") -> void:
	print("%s %s%s" % ["ok  " if ok else "FAIL", name, "" if ok else ": " + detail])
	if not ok:
		_failed += 1


func _keys() -> Dictionary:
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONTENT_CONFIG))
	return (d as Dictionary)["trusted_keys"] if d is Dictionary else {}


func _case(name: String, bytes: PackedByteArray, marker: String) -> void:
	_check(name + ": is an envelope", GSCloudEnvelope.is_envelope(bytes), "marker not recognised")
	var parsed := GSCloudManifest.from_json_bytes(bytes)
	_check(name + ": parses", parsed.ok, "" if parsed.ok else parsed.error.message)
	if not parsed.ok:
		return
	var m: GSCloudManifest = parsed.value
	_check(name + ": names its content", m.content_id == "gamemann/game-airdrift" and m.version == "0.1.34", "%s@%s" % [m.content_id, m.version])
	_check(name + ": has files", m.files.size() > 0, "no files")
	var v := GSCloudSignature.verify_for(m.raw_bytes, m.signature, _keys(), m.content_id, m.signature_key_id)
	_check(name + ": signature verifies with client/content.json", v.ok, "" if v.ok else v.error.message)
	var doc: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	_check(name + ": carries " + marker, doc is Dictionary and (doc as Dictionary).has(marker), "marker missing")


func _init() -> void:
	await process_frame
	var legacy := FileAccess.get_file_as_bytes(FIXTURE)
	_check("fixture present", legacy.size() > 1000, FIXTURE)
	_case("legacy dot_cloud_signed", legacy, GSCloudEnvelope.LEGACY_MARKER)
	var current := legacy.get_string_from_utf8().replace('"%s"' % GSCloudEnvelope.LEGACY_MARKER, '"%s"' % GSCloudEnvelope.MARKER).to_utf8_buffer()
	_case("current gs_cloud_signed", current, GSCloudEnvelope.MARKER)

	# A tampered payload under either marker must be refused, not waved through by the alias.
	var doc: Dictionary = JSON.parse_string(legacy.get_string_from_utf8())
	var p := GSHash.base64url_decode(str(doc["payload"]))
	p[10] = (p[10] + 1) % 256
	doc["payload"] = GSHash.base64url_encode(p)
	var bad := GSCloudManifest.from_json_bytes(JSON.stringify(doc).to_utf8_buffer())
	var refused := not bad.ok
	if bad.ok:
		var bm: GSCloudManifest = bad.value
		refused = not GSCloudSignature.verify_for(bm.raw_bytes, bm.signature, _keys(), bm.content_id, bm.signature_key_id).ok
	_check("tampered legacy payload is refused", refused, "accepted")

	print("verify_solo_envelope_test: %s" % ("PASS" if _failed == 0 else "FAIL (%d)" % _failed))
	quit(1 if _failed > 0 else 0)
