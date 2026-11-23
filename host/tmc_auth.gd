class_name TmcAuth
extends RefCounted

## `cfg/auth.yml` turned into a running [GSAuthServer].

const CHANNEL := "tmc.auth"

## YAML `strategy:` values, to [enum GSAuthConfig.Strategy].
const STRATEGIES := {
	"ticket": GSAuthConfig.Strategy.TICKET,
	"introspect": GSAuthConfig.Strategy.INTROSPECT,
	"local": GSAuthConfig.Strategy.LOCAL,
	"anonymous": GSAuthConfig.Strategy.ANONYMOUS,
}


## The auth server this configuration asks for, or null when it asks for none. [param auth] is
## [member TmcConfig.auth]; [param config_dir] is where relative paths in it resolve, so an operator
## writes `issuer.pub.pem` and not an absolute path that only works on the box it was typed on.
static func build(auth: Dictionary, config_dir: String, data_dir: String = "") -> GSResult:
	# No auth.yml is TMC's own sign-in (ticket strategy, guests allowed, the site's keys
	# adopted on first boot); a server only writes the file to change that or to turn it off.
	if auth.is_empty():
		auth = {"enabled": true, "strategy": "ticket", "allow_guests": true}

	# Named rather than tolerated.
	if auth.has("backend") and not auth.has("strategy"):
		GSLog.warn(CHANNEL, "auth.yml is the old example and configures nothing", {
			"fix": "see cfg.example/auth.yml: strategy, server_id and issuer_public_key",
		})

	if not bool(auth.get("enabled", not auth.has("backend"))):
		GSLog.info(CHANNEL, "authentication is off; everybody is a guest", {
			"consequence": "cfg/permissions.yml cannot apply; the console is the only admin",
		})
		return GSResult.success(null)

	var named := str(auth.get("strategy", "ticket")).to_lower()

	if not STRATEGIES.has(named):
		return GSResult.fail(
			GSError.CODE_INVALID,
			"auth.yml: unknown strategy '%s'." % named,
			"expected one of: %s" % ", ".join(PackedStringArray(STRATEGIES.keys()))
		)

	var cfg := GSAuthConfig.new()
	cfg.strategy = STRATEGIES[named]
	cfg.server_id = str(auth.get("server_id", "")).strip_edges()
	cfg.allow_guests = bool(auth.get("allow_guests", true))
	cfg.require_ticket_binding = bool(auth.get("require_ticket_binding", false))

	if auth.has("backbone_url"):
		cfg.backbone_url = str(auth["backbone_url"])

	# The old shipped default: introspect hands this server the player's sign-in, which
	# clients give only to the game's own servers, so everybody else arrived as a guest.
	if named == "introspect" and cfg.server_id == "" and not bool(auth.get("first_party", false)):
		named = "ticket"
		cfg.strategy = GSAuthConfig.Strategy.TICKET
		GSLog.warn(CHANNEL, "auth.yml asks for introspect, which only the game's own servers get; using ticket", {
			"files": ", ".join(auth_files(config_dir)),
			"fix": "set strategy: ticket there (or delete the line), or first_party: true to keep introspect",
		})

	# [b]A PATH in the YAML and a PEM on the config.[/b] `ticket_public_key` is the key itself, and a
	# multi-line PEM inside a YAML value is the kind of thing that survives one edit and not two. The
	# file also keeps the key out of anything that prints the configuration. Read for `ticket` only.
	var key_file := str(auth.get("issuer_public_key_file", "")) \
		if cfg.strategy == GSAuthConfig.Strategy.TICKET else ""

	var path := ""
	if key_file != "":
		path = key_file if key_file.is_absolute_path() else config_dir.path_join(key_file)
		# The old template named a file nobody was given; the site's keys replace it.
		if not FileAccess.file_exists(path):
			GSLog.info(CHANNEL, "no issuer key file; the site's keys are fetched instead", {"path": path})
			path = ""

	if path != "":
		cfg.ticket_public_key = FileAccess.get_file_as_string(path)

		if not cfg.ticket_public_key.contains("PUBLIC KEY"):
			# [b]A PRIVATE key here would verify and mint.[/b] Every operator holding one could forge any
			# player's identity, which is the single thing the ticket design exists to prevent -- so it is
			# worth refusing by name rather than letting it work.
			return GSResult.fail(
				GSError.CODE_INVALID,
				"auth.yml: that is not a public key.",
				"%s -- an operator holds the issuer's PUBLIC half and nothing else" % path
			)

	var accounts := str(auth.get("local_accounts_file", ""))

	if accounts != "":
		cfg.local_accounts_path = accounts if accounts.is_absolute_path() \
			else config_dir.path_join(accounts)

	var reported := _apply_session_report(auth, cfg, config_dir)

	if not reported.ok:
		return reported

	# Ticket mode with no id or key adopts them from the site this server enrolled with:
	# the id from integration/v1/me, the keys from its ticket-keys route over HTTPS.
	if cfg.strategy == GSAuthConfig.Strategy.TICKET \
			and (cfg.server_id == "" or cfg.ticket_public_key == ""):
		cfg.adopt_ticket_trust = true
		if data_dir != "":
			cfg.ticket_trust_cache = data_dir.path_join("ticket_trust.json")

	var valid := cfg.validate()

	if not valid.ok:
		return valid.wrap("auth.yml is incomplete")

	var node := GSAuthServer.new()
	node.name = "Auth"
	node.config = cfg
	# Empty, not the exported default.
	node.config_file = ""
	# [b]Introspection is SCOPED here, or it is refused.[/b] The site answers a server that asks with
	# its integration credential with the player's key in that server's scope — the key the site's
	# avatar and profile routes resolve.
	if cfg.strategy == GSAuthConfig.Strategy.INTROSPECT:
		node.scoped_only = bool(auth.get("introspect_scoped", true))

	apply_guest_profiles(auth, cfg.allow_guests)

	GSLog.info(CHANNEL, "authentication is on", {
		"strategy": named,
		"server_id": cfg.server_id if cfg.server_id != "" else "(from the site)",
		"issuer_key": "file" if cfg.ticket_public_key != "" else "from the site",
		"guests": cfg.allow_guests,
		"session_report": cfg.session_report_url != "",
	})

	return GSResult.success(node)


## The roster report: the URL from the YAML and the key from a file beside it. A key written inline is refused.
static func _apply_session_report(auth: Dictionary, cfg: GSAuthConfig, config_dir: String) -> GSResult:
	# [b]This server's roster, reported to the issuer[/b], so a player who leaves is released at once
	# rather than held for the issuer's lease (GameSpice Auth's GSAuthSessionReporter, built by
	# GSAuthServer whenever the URL is set).
	var report_url := str(auth.get("session_report_url", "")).strip_edges()

	if auth.has("session_report_key"):
		return GSResult.fail(
			GSError.CODE_INVALID,
			"auth.yml: session_report_key is a secret and is not read from the YAML.",
			"put it in a file and name the file in session_report_key_file"
		)

	if report_url != "":
		cfg.session_report_url = report_url
		var report_key_file := str(auth.get("session_report_key_file", "")).strip_edges()

		if report_key_file != "":
			var report_key_path := report_key_file if report_key_file.is_absolute_path() \
				else config_dir.path_join(report_key_file)

			if not FileAccess.file_exists(report_key_path):
				return GSResult.fail(
					GSError.CODE_IO,
					"auth.yml: the session report key is not there.",
					report_key_path
				)

			cfg.session_report_key = FileAccess.get_file_as_string(report_key_path).strip_edges()

		if auth.has("session_report_interval_sec"):
			cfg.session_report_interval_sec = float(auth["session_report_interval_sec"])

	return GSResult.success(null)


## Whether guests get stored profiles: auth.yml `guest_profiles`, defaulting to [param allow_guests]. A server that admits guests
## and then refuses each one's profile ("Guest profiles are not enabled on this server") logs that on every join for nothing.
static func guest_profiles_wanted(auth: Dictionary, allow_guests: bool) -> bool:
	return bool(auth.get("guest_profiles", allow_guests))


## Hands [method guest_profiles_wanted] to the profile manager (`GS_USER_ALLOW_GUEST_PROFILES`), unless the operator already set that variable.
static func apply_guest_profiles(auth: Dictionary, allow_guests: bool) -> void:
	if OS.get_environment("GS_USER_ALLOW_GUEST_PROFILES") != "":
		return
	if guest_profiles_wanted(auth, allow_guests):
		OS.set_environment("GS_USER_ALLOW_GUEST_PROFILES", "true")


## The auth.yml files that exist under [param config_dir], lowest tier first.
static func auth_files(config_dir: String) -> PackedStringArray:
	var found := PackedStringArray()
	for rel in ["addons/gs_auth/auth.yml", "server/addons/gs_auth/auth.yml", "auth.yml"]:
		if FileAccess.file_exists(config_dir.path_join(rel)):
			found.append(config_dir.path_join(rel))
	return found
