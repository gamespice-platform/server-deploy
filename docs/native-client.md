# The native client: `./server export-native`

It builds the shell for Linux, Windows and macOS, writes one archive per platform into `build/`, and prints the command that publishes each. The desktop app installs a file, and before this the browser was the only way to play.

## The launch arguments need the bare `--`

`client/shell.gd` reads its arguments from `OS.get_cmdline_user_args()`, which is only what follows a `--`. **Godot 4 silently ignores an argument it does not recognise**, so `tmc.x86_64 --connect 127.0.0.1:6099` launches, renders the menu, and connects to nothing. The published argument template is:

```
--,--connect,{host}:{port},--udp,{host}:{udpPort}
```

The desktop app's builder drops a pair when its value is missing. `{udpPort}` is the server's own A2S `udp:<port>` keyword (spy records it as `meta.enetPort`; the site's app API hands it to the app as `udpPort`). Without it a native client tried UDP at the join port, which behind nginx is the TLS port, and fell back to WebSocket after 2.5 s. Other user arguments (`--locale-language de`, `--locale-pseudo true`) go after the same `--`.

## Signing in: `--auth-code`

A player signed into the desktop app should join as themselves, which a TICKET server with `allow_guests=false` requires. The app asks the site's `POST /play/launch` for a launch and gets a 60 s single-use handoff (`tmc_gh_...`, only when the viewer is signed in and the server signs in through TMC), then appends `--auth-code <code>` after the bare `--`. The shell redeems it with `GSAuthClient.redeem_handoff` at ITS OWN backbone (`client/auth.json` or `--auth-backbone-url`), never a URL named in argv. A refused or missing code leaves a guest. The site's `{authCode}` URI token carries the same value for a template that wants it.

## Presets

- **`export_presets.example.cfg` is tracked; `export_presets.cfg` is not.** The editor rewrites the real file, so it is gitignored like `cfg/`; `setup.sh` and `setup.ps1` copy the example in when there is none and never overwrite one.
- **One file per platform**: `binary_format/embed_pck=true` puts the pack inside the executable, so the archive holds exactly the one entry `--entry` names. The zips carry mode bits so the binary arrives executable.
- **It is the client, not the server.** Every preset excludes `host/*`, like the Web one. A native build that could also host is a different product.
- **It publishes under the ENGINE app**, as the web build does: a server can change which game it runs while players stay connected, so a Play press resolves the build from the engine app. Publishing the same shell under each game app is a copy per game.

## Phones: `--platform android` and `--platform ios`

- **`--platform all` stays the desktop three.** A phone build needs things a desktop build machine does not have (JDK 17 and the Android SDK, or a Mac with Xcode), and the site's publisher has no phone platform yet, so `all` building them would turn a working desktop export into a failing one. Ask for a phone by name.
- **Android is a debug APK, arm64-v8a, from the stock template** (gradle build off, so no Android source tree and no NDK): `build/android/tmc.apk`. `tools/fetch-android-sdk.sh` installs the pinned, digest-checked build-tools, platform-tools and cmdline-tools (to `$TMC_ANDROID_SDK`, by default under the Godot data dir), finds JDK 17 (`TMC_JAVA_HOME`, `JAVA_HOME`, or the usual install paths) and prints `ANDROID_HOME` and `JAVA_HOME`. Godot reads those two only when its editor settings file has no `export/android/android_sdk_path` or `java_sdk_path` key, and any editor that has saved its settings has both, often empty: the export then fails with "A valid Java SDK path is required in Editor Settings". So `export-native` runs the fetcher with `--editor-settings`, which writes both keys into the exporting Godot's `editor_settings-<major.minor>.tres` (server.ps1 does the same from `ANDROID_HOME` and `JAVA_HOME`). Godot 4.7 targets SDK 36 and says it is using build-tools 35.0.1 instead; it signs and aligns with them. The fetcher runs on every Android export, so the first Android export installs the SDK the way the first export installs the templates. `TMC_NO_DOWNLOAD` makes a missing SDK an error.
- **Signing**: the debug APK is signed with the editor's debug keystore (Godot makes one with the JDK's keytool when there is none, at `export/android/debug_keystore`) or the one `GODOT_ANDROID_KEYSTORE_DEBUG_PATH`, `_USER` and `_PASSWORD` name. `TMC_ANDROID_RELEASE=1` exports a release APK with the `GODOT_ANDROID_KEYSTORE_RELEASE_*` keystore. No keystore is in this repository.
- **iOS is arm64 and needs a Mac with Xcode**: Godot writes an Xcode project and xcodebuild signs it. `export-native --platform ios` refuses on any other OS (exit 3) before it fetches or writes anything, and on a Mac refuses a preset without `application/app_store_team_id`, which is the developer account's and so empty in the tracked preset.
- **No native library on a phone yet.** No gs-* addon publishes an android or ios build, so `tools/fetch-natives.sh` says so and carries on, both presets exclude `*.gdextension` and `addons/*/bin/*`, and the build runs the GDScript twins.
- **An older `export_presets.cfg` gets the preset added**: a preset `export-native` is asked for and does not find is copied in from the example at the next free index. The lock and non-gs-addon patching applies to every preset, these included, and the artifact checks read the APK's entry list and any pck inside it.
- **Nothing publishes it**: the command ends with `adb install -r build/android/tmc.apk` (or Xcode and TestFlight for an IPA) instead of a publish command.
- **Verified 2026-11-17** on a Linux build box with Godot 4.7.2 and Temurin 17: the export installed the pinned SDK, made the debug keystore and wrote a 76 MB APK (`net.dotgames.tmc`, sdk 24, target 36, native-code `arm64-v8a`, signed). It carries `assets/addons.lock` and no non-dot addon, `host/` or `maps/imported/`. `--platform ios` refused with exit 3. Not yet installed on a phone, and iOS has not been run on a Mac.

## Two engine facts, set in `project.godot`

- **A universal or arm64 macOS export is refused while `textures/vram_compression/import_etc2_astc` is off.** This project has no VRAM-compressed textures, so turning it on reimports nothing; the alternative was an x86_64-only build under a `MACOS_UNIVERSAL` column.
- **The `.app` bundle is named from the project name**, which is the server tool's. `config/name.macos="TMC"` is a feature-tagged override, so the bundle is `TMC.app` and the entry `TMC.app/Contents/MacOS/TMC`.

Verified by exporting all three, unpacking the Linux archive the way the app does, and joining a real `./server` with the address arriving through `-- --connect`.

## Where a player's crash log is

Two files, both on the player's machine; the first error in either names the cause.

- **The shell's own log** (Godot file logging, on by default on desktop): `user://logs/godot.log`, with the previous runs beside it. The project is now `config/name="GameSpice"`, but `config/custom_user_dir_name="TMC server"` keeps the user dir where it was: Windows `%APPDATA%\Godot\app_userdata\TMC server\logs\godot.log`, Linux `~/.local/share/godot/app_userdata/TMC server/logs/`, macOS `~/Library/Application Support/Godot/app_userdata/TMC/logs/` (the `name.macos` override).
- **The GameSpice app's capture of the shell's stdout and stderr**, one file per launch: `sessions/session-<id>.log` under the app's log dir (Windows `%LOCALAPPDATA%\gamespice-app\logs\sessions\`, Linux `~/.local/share/gamespice-app/logs/sessions/`, macOS `~/Library/Logs/gamespice-app/sessions/`). The app's own panics are `crash.log` in the same log dir.

A game whose scripts do not compile on the shell's addons is refused with `GAME_DID_NOT_COMPILE` (client/shell.gd) instead of a crash. The usual cause is an addon the shell's addons need and the shell does not carry; `tools/check_shell_parse.sh` catches that before a shell is published (2026-11-21: gs-animation and gs-camera were missing, and Fatal Contact and Hungario segfaulted on join).

## Publishing is automatic

`.github/workflows/native-shell.yml` exports the desktop three and publishes them (`tools/publish-native-shell.sh`, the site\x27s native build API, `--app godot`) whenever the shell\x27s inputs change on main, the same inputs as the web shell. A cache entry keyed by `tools/shell-inputs.sh`\x27s fingerprint marks a tree as published, so nothing is committed back and a re-run does nothing; `workflow_dispatch` with `force` publishes anyway. It uses the same `SHELL_PUBLISH_TOKEN` secret and `WEB_SHELL_BACKBONE_URL` variable as web-shell.yml. Running `./server export-native` and the printed commands by hand is the fallback.

## When a solo download looks stuck

The shell downloads a game and (unless "Download this game's maps" is off) its map packs as one job, so a slow or throttled host used to leave a frozen-looking bar. The download is asynchronous and never blocks the main thread; what was wrong was the figure: the addon's rate kept its last value while bytes stopped, so "a few seconds left" stayed on screen.

- **Rate and ETA come from the shell** (`client/tmc_download_watch.gd`): bytes over the last 8 s, zero when nothing arrives, no estimate under 2 % done.
- **A stall is 20 s without a new byte.** The status then reads "Download stalled" with "No data for N s", and a Retry button appears. Retry cancels the job and starts it again; finished packs are kept, so it resumes at pack level.
- **"Start without maps"** is shown from the first byte while maps download. It stores the skip-maps choice for that game (user://tmc_solo.cfg, the same switch as the checkbox) and starts without them.
- **Log lines** (channel `tmc.shell`, in Godot's log, `user://logs/godot.log`, info level): `solo download begins`, `solo job phase` and `solo pack finished` with elapsed time and bytes, `solo download stalled` (once per stall), `solo download ended`. A report of "stuck" is read from the gap between these.
- **Not in the shell**: the 429 / Retry-After backoff, parallelism and cancel live in the gs-cloud addon. It has no idle timeout (only a 600 s whole-file one) and no mid-file resume; filed on the nightly board.

`examples/download_watch_check.tscn` covers the watch and, against `tools/fake_content_server.mjs`, a 429 with Retry-After, a body that goes silent and a slow body that is not a stall.

**Running the checks from a worktree.** `tools/check.sh`, `check-pinned.sh` and the parse checks find the sibling addon checkouts through `TMC_SIBLINGS`; unset, they use the parent of the main checkout (so a worktree under `~/wt` works without it). To set it anyway under the fleet wrapper: `hv <worktree> local env TMC_SIBLINGS=/home/gamedev/godot tools/check.sh` (`hv local` is `heavy -- "$@"`, so `env` reaches the command; the `hv` script itself is outside this repo and is not changed here). `tools/pack.gd` stages in `user://pack_staging_<pid>`, so concurrent runs no longer remove each other's staging.
