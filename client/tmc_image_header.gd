class_name TmcImageHeader
extends RefCounted

## Reads the size an image declares in its header, without decoding it.


## The width and height a PNG, JPEG or WebP header declares, or (0, 0) when it cannot be
## read. Header bytes only: nothing is decoded.
static func declared(body: PackedByteArray) -> Vector2i:
	var n := body.size()
	# PNG: IHDR is the first chunk, width and height big-endian at 16 and 20.
	if n >= 24 and body[0] == 0x89 and body[1] == 0x50:
		return Vector2i(_be32(body, 16), _be32(body, 20))
	# WebP: the first chunk after "WEBP" decides where the size is.
	if n >= 30 and body.slice(8, 12).get_string_from_ascii() == "WEBP":
		var chunk := body.slice(12, 16).get_string_from_ascii()
		if chunk == "VP8X":
			return Vector2i(1 + (body[24] | body[25] << 8 | body[26] << 16), 1 + (body[27] | body[28] << 8 | body[29] << 16))
		if chunk == "VP8 ":
			return Vector2i((body[26] | body[27] << 8) & 0x3FFF, (body[28] | body[29] << 8) & 0x3FFF)
		if chunk == "VP8L" and body[20] == 0x2F:
			var bits := body[21] | body[22] << 8 | body[23] << 16 | body[24] << 24
			return Vector2i(1 + (bits & 0x3FFF), 1 + ((bits >> 14) & 0x3FFF))
		return Vector2i.ZERO
	# JPEG: walk the markers to the first start-of-frame.
	if n >= 4 and body[0] == 0xFF and body[1] == 0xD8:
		var i := 2
		while i + 9 < n:
			if body[i] != 0xFF:
				return Vector2i.ZERO
			var marker := body[i + 1]
			if marker == 0xFF:
				i += 1
				continue
			if marker == 0xD8 or marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7):
				i += 2
				continue
			var length := body[i + 2] << 8 | body[i + 3]
			if marker >= 0xC0 and marker <= 0xCF and marker != 0xC4 and marker != 0xC8 and marker != 0xCC:
				return Vector2i(body[i + 7] << 8 | body[i + 8], body[i + 5] << 8 | body[i + 6])
			if length < 2:
				return Vector2i.ZERO
			i += 2 + length
	return Vector2i.ZERO


static func _be32(b: PackedByteArray, at: int) -> int:
	return b[at] << 24 | b[at + 1] << 16 | b[at + 2] << 8 | b[at + 3]
