# Claude Profiles

Run several Claude Desktop accounts side by side on one Mac. Each profile is a separate Claude window
with its own sign-in, chats, settings and MCP config. All profiles run the **same** official
`/Applications/Claude.app`, so one update covers all of them.

> **Unofficial.** Claude Profiles is not made by, affiliated with, or endorsed by Anthropic. It launches
> the official Claude app and never modifies, patches, copies or re-signs it. "Claude" is a trademark of Anthropic.

## Install

1. Open `ClaudeProfiles-<version>.dmg` and drag **Claude Profiles** to Applications.
2. The app is ad-hoc signed (no Developer ID), so the first time you open it, Control-click it and choose **Open**.

Requires macOS 15 or later and Claude Desktop in `/Applications/Claude.app`.

## How it works

| Topic | Behavior |
|---|---|
| Isolation | Non-default profiles launch `Claude.app` as a new instance with Chromium's `--user-data-dir=<dir>`. Electron uses it as `userData`, so cookies/sign-in, local storage, `config.json` and `claude_desktop_config.json` all live in `~/Library/Application Support/ClaudeProfiles/Profiles/<id>/`. Electron's single-instance lock is per data dir, so profiles run at the same time. |
| Default profile | Your existing `~/Library/Application Support/Claude`, launched exactly like opening Claude normally (no arguments). It can't be deleted here, and Claude Profiles never moves, changes or deletes it. |
| Why not `CLAUDE_USER_DATA_DIR`? | Claude 4.23118.1 deletes that variable at startup in packaged builds unless it comes with an Anthropic-signed `CLAUDE_CDP_AUTH` token (it's an internal test hook), so it can't be used. |
| Running state | Claude main processes are found with `sysctl` (`KERN_PROCARGS2`) and mapped to profiles by their `--user-data-dir`. The version each instance was started with is saved in `runtime.json`, so the mapping survives a restart of Claude Profiles. |
| Deleting | The data folder goes to the Trash after you confirm. Deleting is refused while that profile is running. |

### Things that are shared or limited (Claude's behavior, not ours)

- **Logs**: every instance writes to `~/Library/Logs/Claude/main.log`. Claude only moves logs per profile when the blocked env var is used.
- **Claude in Chrome local pairing** is turned off by Claude itself for any instance whose data folder isn't the default ("userData relocated"). It still works in the Default profile.
- Anything Claude keeps outside its data folder, such as `~/.claude` for Claude Code and the macOS Keychain "Claude Safe Storage" key, is shared by all profiles.

## Signing in to several accounts

With more than one Claude window open, macOS delivers `claude://` links (browser sign-in callbacks) to
the **oldest** running Claude instance, whichever one you were signing in to. We confirmed this on macOS 27.0.1.

How Claude Profiles fixes it:

1. Choose **Sign In…** on a profile (from its card, the sidebar, or the context menu). The profile launches or comes to the front, and a "Signing in to …" banner appears.
2. Claude Profiles then registers itself as the `claude://` handler. **macOS may ask once whether to use Claude Profiles for claude links. Choose to allow it.**
3. When the browser hands back the sign-in link, Claude Profiles forwards it as a `GURL` Apple Event addressed to that profile's process ID. Only that window receives it.
   Without a pending sign-in, links go to the Claude window you used most recently.
4. If macOS asks whether Claude Profiles may control Claude (Automation), allow it. You can change this later in System Settings > Privacy & Security > Automation.

Claude registers itself as the `claude://` handler again every time it launches. That's harmless: links
then behave as they do without this app. Claude Profiles takes the scheme back only when you start
another sign-in. It never fights Claude for it on a timer. Turn the feature off in **Settings > Sign-in links**.

Every routing decision is logged to `~/Library/Logs/ClaudeProfiles/ClaudeProfiles.log` (query strings are redacted).

## Updates: one update for every profile

- Claude Profiles reads Claude's official update feed:
  `https://api.anthropic.com/api/desktop/darwin/<arm64|universal>/squirrel/update?device_id=…&version=…&os_version=…`
  (it falls back to `releases.claude.com`). This is the same URL Claude's own updater builds. Only GET requests are made, and the `device_id` is a random ID specific to Claude Profiles.
- It checks at launch and then on the interval you set in Settings (15 min to daily, or never). When a newer version is available you get a banner and a notification.
- **Update All Profiles** runs these steps:
  1. Downloads the official zip and checks the feed's SHA-256.
  2. Unpacks it with `ditto`.
  3. Verifies the code signature (deep, strict), Team ID `Q6L2SF6YDW`, bundle ID and version.
  4. Quits running profiles gracefully and remembers which ones were running.
  5. Moves the old bundle aside, moves the new one in and verifies it again in place.
  6. Deletes the old bundle only after that check passes. If anything fails, it rolls back.
  7. Relaunches exactly the profiles that were running.
- **Fallback**: if the direct install fails, choose **Let Claude Update Itself**. Claude's own Squirrel updater downloads the update, Claude Profiles watches the log for "Update downloaded", quits every instance so ShipIt applies it, waits for the new version on disk, then relaunches the profiles.
- If Claude updated itself from one profile while others were open, those instances are flagged
  "Running an Older Version" with a one-click **Restart Them**. Settings has an option to restart idle profiles automatically. A profile counts as idle when its window hasn't been in front for 10 minutes.

## Keyboard and automation

| Shortcut | Action |
|---|---|
| ⌘N | New profile |
| ⌘1…⌘9 | Launch or open profile N |
| ⇧⌘L | Launch all |
| ⌥⌘Q | Quit all profiles |
| ⇧⌘U | Check for Claude updates |
| ⌘, | Settings |

`claudeprofiles://<action>/<profile id or name>` works from Shortcuts, Raycast or `open`. Actions:
`launch`, `open`, `quit`, `restart`, `signin`, `launch-all`, `quit-all`, `check-updates`. A link that names
a profile that doesn't exist is ignored. It shows a short notice that dismisses itself, and the event is logged.

The bundled CLI `Claude Profiles.app/Contents/MacOS/claude-profiles-cli` provides `status`, `profiles`,
`create`, `delete`, `launch`, `quit`, `check-update`, `verify <app>`, `route <pid> <url>`, and
`install-test` (runs download → verify → swap → rollback against a **copy** of Claude.app; it refuses to touch `/Applications/Claude.app`).

## Building

Requires Xcode (Swift 6 toolchain). There are no third-party dependencies.

```sh
make test       # swift test (core logic: store, versions, feed, update/rollback, routing, process scanning)
make app        # dist/Claude Profiles.app (universal, ad-hoc signed)
make dmg        # dist/ClaudeProfiles-<version>.dmg
make release    # test + app + dmg (same as scripts/release.sh)
```

The version is set in `VERSION` and nowhere else. The app icon artwork is `Resources/AppIcon-source.png`.
`scripts/make-icon.swift` crops it to the solid tile, which drops the source's soft shadow and fringe. It then masks the tile to a clean macOS
rounded rect on the 824-in-1024 grid and renders every size from 16 to 1024 px at 1x and 2x into `AppIcon.icns`. The same icon is used
for the About panel and the DMG volume. The menu bar item uses a monochrome SF Symbol template.

### Layout

```
Sources/ClaudeProfilesCore/   UI-free logic (unit tested)
  ProfileStore, Profile, Paths     profiles.json + data dirs
  ProcessScanner, RuntimeTracker   find Claude instances, map PIDs to profiles, remember versions
  Launcher                         launch / focus / quit via NSWorkspace
  UpdateFeed, UpdateState          official feed client + pure update decisions
  UpdateInstaller, CodeSignVerifier  download, verify, swap, roll back
  URLRouting                       sign-in link routing policy + PID-targeted GURL
Sources/ClaudeProfiles/       SwiftUI app (window, menu bar extra, settings)
Sources/claude-profiles-cli/  maintainer CLI
scripts/                      build.sh, make-dmg.sh, release.sh, make-icon.swift
```

## Data locations

- `~/Library/Application Support/ClaudeProfiles/profiles.json`: profiles
- `~/Library/Application Support/ClaudeProfiles/runtime.json`: PID → launch version records
- `~/Library/Application Support/ClaudeProfiles/Profiles/<id>/`: Claude data for each profile
- `~/Library/Logs/ClaudeProfiles/ClaudeProfiles.log`: app log
