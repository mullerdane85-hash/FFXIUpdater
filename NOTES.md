# FFXIUpdater — handoff notes for home PC

**Last session ended:** 2026-05-28 (laptop), heading home.
**Last commit pushed (standalone):** `3a0a7d3` — v1.3.2
**Last commit pushed (aggregate):** `f6938a8` — FFXIWindower

Read this before touching anything. It records every bug we hit on
the laptop, what fixed each one, and **what remains untested** because
the laptop is being shut down before the user can verify the latest
fix lands.

---

## What the addon does

Pure-Lua Windower 4 addon that:

1. Provides `//fu` (and `//ffxiupdater`, `//update`) chat commands
2. Provides a Z hotkey to toggle a GSUI-styled status panel in-game
3. Runs `git pull` on the Windower root folder (which is a checkout of
   `mullerdane85-hash/FFXIWindower`)
4. After a successful pull, parses `git diff --name-only old..new` to
   find which addons changed and runs `//lua reload <name>` for each
   (and `//gs reload` if any `addons/GearSwap/data/*` changed). Skips
   reloading itself.

It can't HTTP directly (no LuaSocket bundled in Windower's Lua), so
every git operation goes through a generated bat file spawned via
`os.execute('start ...')` and a result-file poll.

---

## Bug timeline (what's been tried)

### v1.0 → v1.1.x — initial build + Z hotkey
- v1.0.0: bare `//fu` command, no UI
- v1.1.0: added the Z-toggle window with status block + buttons
- v1.1.1: drag was moving the panel but not the text labels. Cause:
  separate `:pos_x()` / `:pos_y()` calls — switched to combined
  `:pos(x, y)` form.

### v1.2.x — auto-reload after pull
- v1.2.0: after successful pull, runs `git diff --name-only old..new`
  and reloads each touched addon. Skips self.
- v1.2.1: drag STILL didn't move the title + body + X label even
  though button labels worked. Cause: any text with `stroke = {...}`
  or `flags = {bold = true}` falls onto a render path that ignores
  `:pos(x, y)`. Stripped both from title/body/X.

### v1.3.x — GSUI rebuild (the part still uncertain)
- v1.3.0: rebuilt layout to actually look like GSUI — 1px cyan border,
  BgPanel title strip with cyan separator, status dot indicator,
  column-aligned status rows, BgPanel footer with hint line. Bigger
  window 500x270. Bigger Update Now button. Ticking elapsed-time
  poller for click feedback.
- v1.3.1: user screenshot showed every colored band was draggable
  independently. Cause: `images.new()` defaults to `draggable = true`.
  Added `draggable = false` to the `img()` helper.
- **v1.3.2 (current, UNTESTED ON THIS LAPTOP):** two crashes stacked
  - Lexical scope bug: `local function do_update()` at line 204
    referenced `ui`, but `local ui = {...}` wasn't declared until
    line ~440. So `ui` was global nil inside do_update, and every
    `ui.state.commit` write threw "attempt to index a nil value".
    Same for `set_status_msg`, `set_update_button_busy`,
    `tick_elapsed`, `refresh_status_async`. Fix: forward-declare
    them at the top of the file.
  - `windower.send_command('@exec <bat>')` produced "Could not
    execute D:/FFXI/Windower/addons/FFXIUpdater/status.bat" in the
    Windower console. `@exec` isn't a recognised command on this
    install. Fix: replaced with `os.execute('start "" /B "...bat"')`
    via `spawn_bg()` (background) and `spawn_visible()` (new cmd
    window for `git pull` so user sees output).

---

## Things to verify FIRST when you sit down at home

The laptop pushed v1.3.2 but never opened FFXI again to test it. On
the home PC, after `git pull` + `//lua reload FFXIUpdater`, check:

1. **No "attempt to index a nil value" errors** in chat or the
   Windower console when the addon loads or when you press Z.
2. **No "Could not execute" errors** when clicking Refresh or
   Update Now.
3. **`//fu status` to chat** — should print branch, latest commit,
   clean/dirty. If output never arrives, the `spawn_bg` path is
   broken on home install too — see "If os.execute also fails" below.
4. **Click Refresh in the panel** — body should populate within ~2 s
   with real branch/commit/status. Dot should turn green (clean) or
   yellow (dirty).
5. **Click Update Now** — should:
   - Flip the button to bright cyan with label `Updating...`
   - Tick the label every second: `Updating... 1s`, `2s`, `3s`...
   - Open a separate cmd window showing live `git pull` output
   - When the cmd window finishes, the panel restores Update Now
     and prints either "Already up to date" or the new commit hash
6. **Drag the title bar** — every visual band (panel, title strip,
   separators, footer, buttons, dot, all text) should move together.
   If anything stays behind it's another `draggable=true` default
   we missed.

---

## If `os.execute` ALSO fails on the home install

If the home Windower install doesn't allow `os.execute` either (some
sandboxed builds disable it), the addon can't shell out at all. In
that case the realistic fallbacks are:

- **Hard option:** ship a tiny companion Windower plugin (C++) that
  exposes an HTTP fetch or process spawn. Heavy.
- **Soft option:** the user runs a `Launch-Windower.bat` from outside
  the game that does `cd /d D:\FFXI\Windower && git pull && Windower.exe`.
  We already have one of these in the FFXIWindower repo root (per
  the SESSION-NOTES history). Document `//fu` as best-effort and
  point users at the launcher.

Don't go nuclear on the fallback unless `os.execute` is confirmed
broken at home — every Windower install I've seen allows it.

---

## File map (for orienting fast)

```
addons/FFXIUpdater/
├── FFXIUpdater.lua    ← the only source file. Sections in order:
│   - _addon manifest, requires
│   - windower_root + addon_dir resolution
│   - FORWARD DECLARATIONS (line ~50)  ← keep in sync if you add helpers
│   - spawn_bg / spawn_visible (line ~80)
│   - settings (line ~95)
│   - say() chat helper
│   - is_git_checkout / write_file
│   - detect_changed_addons / reload_addons (auto-reload subsystem)
│   - do_update (line ~204) — TOP-LEVEL UPDATE FLOW
│   - refresh_status_async + do_status_chat
│   - do_help
│   - addon command dispatcher
│   - UI section: C palette, layout constants, `ui` table
│   - img() / txt() builders (line ~422)
│   - rect_* hit-test rects
│   - build_ui()
│   - move_ui()
│   - redraw_body / refresh_footer
│   - set_update_button_busy / set_status_msg / tick_elapsed
│   - ui_elements() / show_ui / hide_ui / toggle_ui
│   - keyboard + mouse event handlers
│   - load/unload events
├── README.md          ← user-facing docs
├── NOTES.md           ← this file
├── .gitignore         ← excludes pull.bat / status.bat / etc.
└── data/settings.xml  ← persisted pos + auto_reload toggle
```

---

## Layout constants worth knowing

If buttons/dot/title look misaligned, these are the source-of-truth:

```lua
W, H = 500, 270        -- window size
Y_TITLE     =   0      -- title bar 0..36
Y_TITLE_END =  36
Y_BODY      =  48      -- status block 48..170
Y_BUTTONS   = 180      -- button row 180..212
Y_FOOT_LINE = 222      -- 1px separator above footer
Y_FOOTER    = 226      -- footer 226..270
```

`build_ui()` uses these. `move_ui()` must use the EXACT SAME offsets
when repositioning; the two have to stay in lock-step or drag
rearranges things.

---

## Color palette (matches GSUI)

```
bg_deep    14, 23, 38     main panel background
bg_panel   22, 34, 58     title bar / footer
bg_panel2  27, 42, 71     button rest state
accent     95, 200, 255   cyan, separators + title text
accent_dim 58, 111, 165   update button idle
border     58, 90, 153    1px outer frame
ok         126, 224, 122  green status dot
warn       227, 195, 90   yellow status dot
err        227, 108, 108  red status dot
busy       95, 200, 255   cyan status dot while updating
```

---

## Other repos pushed this session

For full context if home Claude wants to know what landed:

| Repo | Commit | What |
|---|---|---|
| mullerdane85-hash/FFXIWindower | f6938a8 | latest aggregate; includes FFXIUpdater v1.3.2 + SMN audit + Macro Manager notes |
| mullerdane85-hash/FFXIUpdater  | 3a0a7d3 | standalone updater v1.3.2 |
| mullerdane85-hash/FFXIMacroManager | 1971395 | standalone .exe macro editor (initial). README + binary format docs live there. |

Also note: `addons/GearSwap/data/Kalitzo_SMN.lua` got a major BG-Wiki
audit this session — new `//gs c siphon`, new `//gs c dt` (Nyame),
buff/spirit/other sets rebuilt around Baayami summoning-skill stack.
If the user wants to keep iterating on SMN, the docblock at the top
of that file lists upgrade-path pieces (Beckoner's +3, Glyphic +3,
Convoker's Horn +3, Stikini Ring +1).

---

## Likely next steps when home

1. Pull on home PC: `git pull` in the Windower root
2. `//lua reload FFXIUpdater` (or close+open Windower)
3. Run through the "verify FIRST" checklist above
4. If something fails, paste me the chat / Windower console error
   and we iterate from there
5. If everything works, the natural follow-up is integrating
   FFXIUpdater into the autoload list of init.txt (already done) and
   maybe extracting the spawn / poll-result pattern into a shared
   library if other addons want similar `git pull` integration

Have a good ride home.
