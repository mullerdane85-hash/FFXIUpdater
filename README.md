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
| `//fu help` | the list above |

`//ffxiupdater` and `//update` are accepted as aliases.

## How it works

Pure-Lua Windower addons have no HTTP module, so we shell out:

1. The addon writes a short `pull.bat` into its own folder.
2. `windower.send_command('@exec pull.bat')` spawns it asynchronously.
3. The bat `cd`s to Windower root, runs `git pull`, pauses so you can
   read the result.

For `//fu status` the same trick goes through a temp log file —
`git status` writes to `status.log`, then a 2-second `coroutine.schedule`
re-reads the log and prints each line to chat. No popup window for
status, since it's small enough to inline.

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
