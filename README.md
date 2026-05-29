<!-- BEGIN DISCLAIMER (managed by FFXIWindower author; do not remove) -->
## ⚠️ Disclaimer — Use at Your Own Risk

This is unofficial, fan-made software for *Final Fantasy XI*. It is **not affiliated with, endorsed by, or supported by Square Enix Holdings Co., Ltd.** FINAL FANTASY is a registered trademark of Square Enix.

**Square Enix's official position is that third-party tools and modifications to the FFXI client are prohibited by the Terms of Service.** Installing or using this software may result in account suspension, account termination, character data loss, or other action taken by Square Enix at their sole discretion.

This software is provided **AS IS, without warranty of any kind**, express or implied — including but not limited to warranties of merchantability, fitness for a particular purpose, and non-infringement. In no event shall the author or contributors be liable for any claim, damages, account action, lost time, lost progress, file corruption, or any other liability arising from the use of, or inability to use, this software.

**By installing, building, or running this software you acknowledge that you understand and accept these risks.**

<!-- END DISCLAIMER -->
### Additional warning — supply-chain risk

This addon performs `git pull` from a remote repository at runtime and (optionally) auto-reloads modified addons inside a running FFXI session. **That makes a compromise of the publishing GitHub account a malware-delivery vector to every user.** Even with the v2.0.0 safeguards (signed-commit verification, remote URL pinning, fast-forward-only pulls, sensitive-path blocklist, size circuit-breaker, preview/confirm two-step), an in-game auto-updater cannot be made as safe as a traditional out-of-game installer. **The author recommends against using this for any account you cannot afford to lose.** For personal multi-machine sync, `git pull` from a terminal between play sessions is strictly safer.
# FFXIUpdater

One-line `//fu` to git-pull your whole Windower folder. Built for the
mullerdane85-hash/FFXIWindower aggregate-repo workflow but works with any
Windower install that's a git checkout.

## Why

If your Windower folder is `git clone <your aggregate repo>`, every addon,
plugin, and settings file you author lives in one tree. A single
`git pull` updates everything. This addon wraps that into one chat
command so you don't have to alt-tab to a terminal.

## Install

```
git pull        — if it's already in your aggregate (e.g. mullerdane85-hash/FFXIWindower)
```

or drop the `FFXIUpdater` folder into `Windower/addons/`, then in-game:

```
//lua load FFXIUpdater
```

Autoload by adding `lua load FFXIUpdater` to `Windower/scripts/init.txt`.

## Hotkey

Press **Z** in-game to toggle the status window. Suppressed while chat
is open so typing the letter 'z' still works.

The window shows current branch + latest commit + clean/dirty status,
with two buttons:

- **Refresh** — re-read git state without pulling
- **Update Now** — same as `//fu`, runs `git pull` in a cmd window

Drag the title bar to move; position persists to `data/settings.xml`.

## Commands

| Command | Effect |
|---|---|
| `//fu` | git pull, opens a cmd window so you can see the result |
| `//fu status` | branch, latest commit, dirty files — printed to chat |
| `//fu show` / `//fu hide` | open / close the status window programmatically |
| `//fu toggle` | same as pressing Z |
| `//fu autoreload on \| off` | after pull, auto-reload only the addons that actually changed (default ON) |
| `//fu help` | the list above |

`//ffxiupdater` and `//update` are accepted as aliases.

## How it works

Pure-Lua Windower addons have no HTTP module, so we shell out:

1. The addon writes a short `pull.bat` into its own folder.
2. `windower.send_command('@exec pull.bat')` spawns it asynchronously.
3. The bat `cd`s to Windower root, runs `git pull`, writes a one-byte
   `pull.result` marker, then pauses so you can read the cmd window.
4. The addon polls `pull.result` once a second (up to 60 s). When it
   appears, status is refreshed and the panel reports the new commit.

### Auto-reload after pull

If `auto_reload` is on (default), the addon also runs:

```
git diff --name-only <old hash>..<new hash>
```

to find every file the pull touched, maps each path to an addon name,
and issues the right reload command:

| Changed path | Action |
|---|---|
| `addons/<X>/...` | `//lua reload <X>` |
| `addons/GearSwap/data/...` | `//gs reload` |
| `addons/FFXIUpdater/...` | skipped — would kill the running poller |
| `plugins/`, `scripts/`, `res/` | reported in chat as "manual restart needed" |

So after `//fu`, the addons that actually changed pick up their new
code automatically. If only GearSwap data changed, only `//gs reload`
fires — no unnecessary full-addon reloads.

For `//fu status` the same shell-out trick goes through a temp log file
— `git status` writes to `status.log`, then a 2-second
`coroutine.schedule` re-reads the log and prints each line to chat. No
popup window for status, since it's small enough to inline.

## Requirements

- **git** in your system PATH (test with `git --version` in cmd)
- Windower install is a git checkout — i.e. `Windower/.git/HEAD` exists
- `@exec` enabled in Windower (it is by default)

If the Windower folder isn't a git checkout, `//fu` prints a friendly
error and does nothing.

## What it doesn't do

- Doesn't push — only pulls. Outgoing changes are still on you.
- Doesn't stash dirty files. If `git pull` would conflict with your
  local edits, the cmd window will tell you and abort. Resolve manually.
- Doesn't support multiple remotes or non-`origin` setups. PRs welcome.

## License

BSD 3-Clause. See header in `FFXIUpdater.lua`.

## Author

TWinn22 (GitHub: TWinn22 / FFXI: Jason, 2026)
