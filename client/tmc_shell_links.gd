class_name TmcShellLinks
extends RefCounted

## The shell's long-lived link nodes (radio, trail, inventory), built once under the shell and kept in its `radio_link`, `trail_link` and `inventory_link`.


## Creates the three links as children of [param shell], wired to its site, token, cloud and clear-downloads callbacks.
static func build(shell: Node) -> void:
	shell.radio_link = TmcRadioLink.new()
	shell.radio_link.name = "RadioLink"
	shell.add_child(shell.radio_link)
	var trail := TmcTrailLink.new()
	trail.name = "TrailLink"
	trail.site_fn = shell._workshop_site
	trail.token_fn = shell._workshop_token
	trail.cloud_fn = func() -> Object:
		shell._ensure_cloud()
		return shell._cloud
	shell.trail_link = trail
	shell.add_child(trail)
	var inventory := TmcInventoryLink.new()
	inventory.name = "InventoryLink"
	inventory.origins = shell._configured_inventory_origins()
	inventory.cloud_fn = trail.cloud_fn
	inventory.clear_fn = shell.request_clear
	shell.inventory_link = inventory
	shell.add_child(inventory)
	inventory.start()
