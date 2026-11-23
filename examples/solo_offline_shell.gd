extends Node

## Stands in for the shell where [TmcShellSolo] only reads the cloud client and the log channel (solo_check).

const CHANNEL := "shell"

var _cloud: GSCloudClient = null
