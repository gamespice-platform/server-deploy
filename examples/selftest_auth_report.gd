class_name SelftestAuthReport
extends RefCounted

## The auth.yml session report: URL, key file, and the refusals. Run by `selftest.gd`'s auth section, which keeps the counters: every check goes through its `_check`.

var t: Node


func _init(p_test: Node) -> void:
	t = p_test


func _check(condition: bool, what: String, detail: String = "") -> bool:
	return t._check(condition, what, detail)


## [param work] is the auth test's scratch folder, already holding `issuer.pub.pem`.
func _test_report(work: String) -> void:
	# [b]The roster report[/b]: the URL from the YAML, the key from a file beside it, and a
	# key written inline refused by name, because a secret in the YAML is a secret in every
	# paste of the configuration.
	GSPaths.write_text(work.path_join("report.key"), "s3cret-report-key\n")
	var reporting := TmcAuth.build({
		"enabled": true, "strategy": "ticket", "server_id": "eu-1",
		"issuer_public_key_file": "issuer.pub.pem",
		"session_report_url": "https://issuer.example", "session_report_key_file": "report.key",
		"session_report_interval_sec": 30,
	}, work)
	var reporting_cfg: GSAuthConfig = (reporting.value as Node).get("config") if reporting.ok else null
	_check(
		reporting_cfg != null and reporting_cfg.session_report_url == "https://issuer.example"
			and reporting_cfg.session_report_key == "s3cret-report-key"
			and is_equal_approx(reporting_cfg.session_report_interval_sec, 30.0),
		"session reporting is configured from auth.yml, the key read from its file",
		str(reporting.error)
	)
	if reporting.ok:
		(reporting.value as Node).free()
	var inline_key := TmcAuth.build({
		"enabled": true, "strategy": "ticket", "server_id": "eu-1",
		"issuer_public_key_file": "issuer.pub.pem",
		"session_report_url": "https://issuer.example", "session_report_key": "pasted",
	}, work)
	_check(not inline_key.ok, "a report key written into the YAML is refused")
	var no_key := TmcAuth.build({
		"enabled": true, "strategy": "ticket", "server_id": "eu-1",
		"issuer_public_key_file": "issuer.pub.pem", "session_report_url": "https://issuer.example",
	}, work)
	_check(not no_key.ok, "a report URL with no key is refused (anyone could report anyone)")
	var lost_key := TmcAuth.build({
		"enabled": true, "strategy": "ticket", "server_id": "eu-1",
		"issuer_public_key_file": "issuer.pub.pem",
		"session_report_url": "https://issuer.example", "session_report_key_file": "gone.key",
	}, work)
	_check(not lost_key.ok, "and a key file that is not there names the path")
