--[[
Copyright 2026, TWinn22

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

  1. Redistributions of source code must retain the above copyright notice,
     this list of conditions and the following disclaimer.
  2. Redistributions in binary form must reproduce the above copyright
     notice, this list of conditions and the following disclaimer in the
     documentation and/or other materials provided with the distribution.
  3. Neither the name of the copyright holder nor the names of its
     contributors may be used to endorse or promote products derived from
     this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.
]]

_addon = {}
_addon.name      = 'FFXIUpdater'
_addon.version   = '1.3.0'
_addon.author    = 'TWinn22'
_addon.commands  = {'fu', 'ffxiupdater', 'update'}

require('logger')
local config = require('config')
local images = require('images')
local texts  = require('texts')

-- ============================================================================
-- FFXIUpdater — one-shot self-update for the whole Windower folder
-- ============================================================================
-- Hotkey: Z toggles the status window (suppressed while chat is open so
--         typing 'z' in chat still works).
--
-- Commands
--   //fu           — git pull (update everything)
--   //fu status    — branch, last commit, dirty files (printed to chat)
--   //fu show      — open the status window
--   //fu hide      — close the status window
--   //fu help      — list of commands
-- ============================================================================

local windower_root = windower.windower_path:gsub('\\$', ''):gsub('/$', '')
local addon_dir = (windower.addon_path or (windower_root .. '/addons/FFXIUpdater/'))
                  :gsub('\\$', ''):gsub('/$', '')

-- ============================================================================
-- Settings (persisted to data/settings.xml)
-- ============================================================================
local defaults = {
    pos         = {x = 200, y = 200},
    visible     = false,
    -- After a successful pull, auto-run `//lua reload <name>` for every
    -- addon whose files changed (and `//gs reload` if any GearSwap data
    -- file changed). Self-reload is always skipped — reloading
    -- FFXIUpdater while it's running its own pull would kill the
    -- post-pull coroutines mid-flight. Toggle with //fu autoreload on/off.
    auto_reload = true,
}
local settings = config.load(defaults)

-- ============================================================================
-- Chat helper
-- ============================================================================
-- Color 207 = teal/info, 167 = red/warn.
local function say(color, msg)
    windower.add_to_chat(color or 207, '[FFXIUpdater] ' .. tostring(msg))
end

-- ============================================================================
-- Git helpers (shell out via @exec — Windower addons can't HTTP directly)
-- ============================================================================
local function is_git_checkout()
    local f = io.open(windower_root .. '/.git/HEAD', 'r')
    if not f then return false end
    f:close()
    return true
end

local function write_file(path, content)
    local f, err = io.open(path, 'w')
    if not f then
        say(167, 'Could not write ' .. path .. ': ' .. tostring(err))
        return false
    end
    f:write(content)
    f:close()
    return true
end

-- =====================================================================
-- Auto-reload helpers
-- =====================================================================
-- After a successful pull, ask git which files changed between the
-- pre-pull and post-pull commits, map those paths to addon names, then
-- send the right reload command for each. We skip ourselves because
-- reloading FFXIUpdater mid-coroutine would kill the very poller that
-- triggered the reload.
--
-- Path-to-action mapping:
--   addons/<X>/...                  ->  //lua reload <X>
--   addons/GearSwap/data/...        ->  //gs reload  (data files are
--                                       hot-loaded by GearSwap, not by
--                                       the lua loader, so reloading
--                                       the addon would be excessive)
--   plugins/, scripts/, res/        ->  no auto-action; reported only
--                                       (those need Windower restart)
-- =====================================================================

-- Extract the 7-character short hash from a `git log --oneline` line
-- like "f77916f v1.1.1: fix drag...".
local function short_hash(commit_line)
    if not commit_line then return '' end
    return (commit_line:match('^(%S+)') or ''):sub(1, 7)
end

-- Spawn a bat that runs `git diff --name-only old..new`, then in 1.5 s
-- read the resulting log and pass parsed addon names to on_complete.
-- Result:
--   on_complete(addons[], gs_data_changed, other_paths[])
-- addons[]       = unique addon folder names whose files changed
-- gs_data_changed = true if any addons/GearSwap/data/* changed
-- other_paths[]  = list of changed paths outside addons/ (plugins,
--                  scripts, res, etc.) — reported but not auto-actioned
local function detect_changed_addons(old_hash, new_hash, on_complete)
    if old_hash == '' or new_hash == '' or old_hash == new_hash then
        on_complete({}, false, {})
        return
    end

    local bat = addon_dir .. '/diff.bat'
    local out = addon_dir .. '/diff.log'
    os.remove(out)

    local content = table.concat({
        '@echo off',
        'cd /d "' .. windower_root .. '"',
        'git diff --name-only ' .. old_hash .. '..' .. new_hash .. ' > "' .. out .. '" 2>&1',
    }, '\r\n') .. '\r\n'
    if not write_file(bat, content) then
        on_complete({}, false, {})
        return
    end
    windower.send_command('@exec ' .. bat)

    coroutine.schedule(function()
        local f = io.open(out, 'r')
        if not f then
            on_complete({}, false, {})
            return
        end
        local addons, seen, other = {}, {}, {}
        local gs_data_changed = false
        for line in f:lines() do
            -- git on Windows still writes forward-slash paths in its
            -- diff output, so the pattern is portable.
            local addon_under_gs_data = line:match('^addons/GearSwap/data/')
            local addon              = line:match('^addons/([^/]+)/')
            if addon_under_gs_data then
                gs_data_changed = true
            elseif addon then
                if not seen[addon] then
                    seen[addon] = true
                    table.insert(addons, addon)
                end
            elseif line ~= '' then
                table.insert(other, line)
            end
        end
        f:close()
        on_complete(addons, gs_data_changed, other)
    end, 1.5)
end

-- Send reload commands for the addons listed. Returns a label string
-- summarizing what was reloaded (for the UI banner / chat).
local function reload_addons(addons, gs_data_changed)
    local reloaded, skipped = {}, {}
    for _, name in ipairs(addons) do
        if name:lower() == 'ffxiupdater' then
            table.insert(skipped, name)
        else
            windower.send_command('lua reload ' .. name)
            table.insert(reloaded, name)
        end
    end
    if gs_data_changed then
        windower.send_command('gs reload')
        table.insert(reloaded, 'GearSwap (data)')
    end
    return reloaded, skipped
end

-- =====================================================================
-- //fu pull — visible cmd window, pauses so user can read the result.
-- Also drives the UI feedback path: button label flips to "Updating...",
-- body gets a banner, and after 8s we refresh status and report whether
-- the commit actually changed.
-- =====================================================================
local function do_update()
    if not is_git_checkout() then
        say(167, 'Windower root is not a git checkout (.git missing).')
        if settings.visible then set_status_msg('Not a git checkout — cannot update.', 'warn') end
        return
    end

    -- Remember the commit hash from before the pull so we can tell
    -- "already up to date" from "actually updated" after the bat finishes.
    ui.last_commit_before_update = ui.state.commit

    local bat = addon_dir .. '/pull.bat'
    local pull_log = addon_dir .. '/pull.result'
    -- We also pipe a sentinel into pull.result so the addon can detect
    -- when the bat finished (the file appears after `git pull` returns).
    -- The cmd window stays open with `pause >nul` for the user to read,
    -- but the result file lets us update the panel even if they leave
    -- the cmd window minimized.
    local content = table.concat({
        '@echo off',
        'title FFXIUpdater - git pull',
        'cd /d "' .. windower_root .. '"',
        'echo === FFXIUpdater: pulling latest from origin ===',
        'echo.',
        'git pull',
        'set EC=%errorlevel%',
        -- Write the exit code as a one-byte marker file so the addon can
        -- detect completion without parsing the verbose pull transcript.
        '> "' .. pull_log .. '" echo %EC%',
        'echo.',
        'echo === done. press any key to close ===',
        'pause >nul',
    }, '\r\n') .. '\r\n'

    if not write_file(bat, content) then return end

    -- Clear any stale completion marker from a previous run.
    os.remove(pull_log)

    -- Feedback: chat, button recolor + label, banner, ticking elapsed.
    say(207, 'Starting update — git pull running in a cmd window.')
    ui.update_in_progress  = true
    ui.update_start_time   = os.time()
    if settings.visible then
        set_update_button_busy(true)
        set_status_msg('git pull starting...', 'busy')
    end
    -- Kick off the ticking elapsed-seconds poller (also runs even when
    -- the window is hidden so reopening it mid-pull shows live state).
    coroutine.schedule(tick_elapsed, 1)

    windower.send_command('@exec ' .. bat)

    -- Poll for completion. Most pulls finish in 2-6 s. We check every
    -- second for up to 60 s; the moment pull.result appears we refresh
    -- status and switch the banner to a success/no-change message.
    local poll_count = 0
    local function poll()
        poll_count = poll_count + 1
        local f = io.open(pull_log, 'r')
        if f then
            -- git pull is done — read the marker (we don't actually use
            -- the exit code yet, presence of the file is enough).
            f:close()
            os.remove(pull_log)
            ui.update_in_progress = false   -- stops tick_elapsed at its next check
            -- Re-read git state, which will update ui.state.commit.
            refresh_status_async()
            -- After the status refresh completes (~1.5 s), compare commits.
            coroutine.schedule(function()
                local before_hash = short_hash(ui.last_commit_before_update or '')
                local after_hash  = short_hash(ui.state.commit or '')
                local same        = (before_hash ~= '' and before_hash == after_hash)

                if settings.visible then set_update_button_busy(false) end

                if same then
                    -- No new commits — nothing to reload.
                    if settings.visible then
                        set_status_msg('Already up to date (' .. after_hash .. ').', 'ok')
                    end
                    say(207, 'Already up to date.')
                    return
                end

                -- Commits differ -> there's new code on disk. Decide what
                -- to reload, then either fire the reloads or just report.
                say(207, ('Update complete — now at %s.'):format(after_hash))
                if settings.visible then
                    set_status_msg(('Update complete — now at %s. Checking what to reload...'):format(after_hash), 'ok')
                end

                if not settings.auto_reload then
                    if settings.visible then
                        set_status_msg(('Update complete — now at %s. Auto-reload OFF — run //lua reload <name> yourself.'):format(after_hash), 'ok')
                    end
                    return
                end

                detect_changed_addons(before_hash, after_hash, function(addons, gs_data_changed, other)
                    local reloaded, skipped = reload_addons(addons, gs_data_changed)
                    -- Compose a concise summary for both chat and panel.
                    local parts = {}
                    if #reloaded > 0 then
                        table.insert(parts, 'reloaded: ' .. table.concat(reloaded, ', '))
                    end
                    if #skipped > 0 then
                        table.insert(parts, 'skipped self: ' .. table.concat(skipped, ', '))
                    end
                    if #other > 0 then
                        table.insert(parts, ('%d non-addon file(s) changed (manual restart needed)'):format(#other))
                    end
                    if #reloaded == 0 and #skipped == 0 and #other == 0 then
                        table.insert(parts, 'no addon files changed')
                    end
                    local summary = table.concat(parts, '; ')

                    say(207, summary)
                    if settings.visible then
                        set_status_msg(('Update complete (%s) — %s'):format(after_hash, summary), 'ok')
                    end
                end)
            end, 2)
            return
        end
        if poll_count < 60 then
            coroutine.schedule(poll, 1)
        else
            ui.update_in_progress = false
            if settings.visible then
                set_update_button_busy(false)
                set_status_msg('Update timed out after 60 s. Check the cmd window.', 'warn')
            end
        end
    end
    coroutine.schedule(poll, 2)
end

-- ============================================================================
-- UI window (Z toggles)
-- ============================================================================
-- Layout (all coords relative to window origin pos):
--   +-------------------------------------------------+
--   |  FFXIUpdater v1.1.0                          [X]|   y =  0..30  title bar (drag)
--   +-------------------------------------------------+
--   |  Branch:   main                                 |   y = 36..52
--   |  Commit:   362b60c init.txt: autoload all ...   |   y = 54..70
--   |  Status:   clean                                |   y = 72..88
--   |  Updated:  2026-05-28 18:42:11                  |   y = 90..106
--   |                                                 |
--   |  [ Refresh ]      [ Update Now ]                |   y = 130..160
--   +-------------------------------------------------+
--
-- Click & drag the title bar to move. Click "Refresh" to re-read git
-- state without pulling. Click "Update Now" to run //fu.
-- ============================================================================

-- =====================================================================
-- GSUI color palette (matches the GSUI overlay so the two addons look
-- like siblings on screen).  Windower image/text colors use 0-255 RGB.
-- =====================================================================
local C = {
    bg_deep    = {a = 240, r =  14, g =  23, b =  38},  -- main panel
    bg_panel   = {a = 240, r =  22, g =  34, b =  58},  -- title bar / footer
    bg_panel2  = {a = 240, r =  27, g =  42, b =  71},  -- button rest
    bg_row     = {a = 240, r =  34, g =  52, b =  90},  -- selected row
    accent     = {a = 255, r =  95, g = 200, b = 255},  -- cyan
    accent_dim = {a = 240, r =  58, g = 111, b = 165},  -- pressed/idle accent
    border     = {a = 240, r =  58, g =  90, b = 153},  -- frame lines
    text_main  = {a = 255, r = 229, g = 238, b = 248},  -- white-ish
    text_muted = {a = 255, r = 156, g = 177, b = 204},  -- secondary text
    text_dim   = {a = 255, r = 111, g = 134, b = 164},  -- footer text
    ok         = {a = 255, r = 126, g = 224, b = 122},  -- green dot
    warn       = {a = 255, r = 227, g = 195, b =  90},  -- yellow dot
    err        = {a = 255, r = 227, g = 108, b = 108},  -- red dot
    busy       = {a = 255, r =  95, g = 200, b = 255},  -- cyan dot when updating
}

-- =====================================================================
-- Layout constants — everything addresses pos relative to the window
-- origin (settings.pos.x / .y) so a single move_ui() pass repositions
-- the whole panel.
-- =====================================================================
local W, H = 500, 270

-- y-offsets of each band
local Y_TITLE     =   0           -- title bar 0..36
local Y_TITLE_END =  36
local Y_BODY      =  48           -- status block 48..170
local Y_BUTTONS   = 180           -- button row 180..212
local Y_FOOT_LINE = 222           -- 1px separator above footer
local Y_FOOTER    = 226           -- footer 226..H

local ui = {
    -- visual frame
    border_outer = nil,    -- 1px accent rect — drawn first behind panel
    panel        = nil,    -- main BgDeep panel
    titlebar_bg  = nil,    -- BgPanel strip across the top
    title_line   = nil,    -- 1px cyan separator at y=Y_TITLE_END
    footer_bg    = nil,    -- BgPanel strip at the bottom
    foot_line    = nil,    -- 1px cyan separator at y=Y_FOOT_LINE
    -- texts
    title        = nil,
    version      = nil,    -- "v1.3.0" subtitle next to title
    body         = nil,
    footer_text  = nil,
    -- close X
    btn_close    = nil,
    btn_close_lbl = nil,
    -- buttons
    btn_refresh  = nil,
    btn_refresh_lbl = nil,
    btn_update   = nil,
    btn_update_lbl = nil,
    -- status indicator dot (small filled square next to Status: row)
    status_dot   = nil,

    -- runtime state cached for redraws / drag
    state = {
        branch  = '?',
        commit  = '?',
        dirty   = '?',
        checked = 'never',
        msg     = '',
        dot     = 'warn',          -- 'ok' | 'warn' | 'err' | 'busy'
    },
    drag = {
        active = false,
        ox = 0, oy = 0,
    },
    update_in_progress       = false,
    update_start_time        = 0,
    last_commit_before_update = nil,
}

-- ---------------------------------------------------------------------------
-- click rectangles (recomputed every move based on settings.pos)
-- ---------------------------------------------------------------------------
local function rect_titlebar()
    return settings.pos.x, settings.pos.y, settings.pos.x + W - 36, settings.pos.y + Y_TITLE_END
end
local function rect_close()
    return settings.pos.x + W - 32, settings.pos.y + 6, settings.pos.x + W - 8, settings.pos.y + 30
end
local function rect_refresh()
    return settings.pos.x + 20, settings.pos.y + Y_BUTTONS, settings.pos.x + 160, settings.pos.y + Y_BUTTONS + 32
end
local function rect_update()
    return settings.pos.x + 180, settings.pos.y + Y_BUTTONS, settings.pos.x + 360, settings.pos.y + Y_BUTTONS + 32
end

local function point_in_rect(x, y, x1, y1, x2, y2)
    return x >= x1 and x <= x2 and y >= y1 and y <= y2
end

-- Small builder helpers to keep build_ui readable.
local function img(x, y, w, h, c)
    return images.new({
        pos     = {x = x, y = y},
        size    = {width = w, height = h},
        color   = {alpha = c.a, red = c.r, green = c.g, blue = c.b},
        visible = false,
    })
end

local function txt(s, x, y, font, size, c)
    return texts.new(s, {
        pos   = {x = x, y = y},
        text  = {font = font, size = size, alpha = c.a, red = c.r, green = c.g, blue = c.b},
        bg    = {visible = false},
        flags = {draggable = false},
        visible = false,
    })
end

-- ---------------------------------------------------------------------------
-- Build UI elements once at load. Hidden until show_ui() is called.
-- Layout target — match GSUI's look so the two overlays feel related:
--
--   +================================================+  outer accent
--   | (BgPanel)  FFXIUpdater  v1.3.0              [X]|  title strip y=0..36
--   +================================================+  1px cyan separator
--   |                                                |
--   |   Branch    :  main                            |
--   |   Commit    :  d1cf291 v1.2.1: drag now mov... |
--   |   Status    :  ● clean                         |
--   |   Checked   :  19:45:11                        |
--   |                                                |
--   |   >> Updating... 3s elapsed                    |  status banner
--   |                                                |
--   |   [ Refresh ]       [ Update Now ]             |  button row y=180
--   |                                                |
--   +================================================+  1px cyan separator
--   | (BgPanel)  Press Z to toggle · auto-reload: ON |  footer y=226..H
--   +================================================+
-- ---------------------------------------------------------------------------
local function build_ui()
    local px, py = settings.pos.x, settings.pos.y

    -- 1-pixel-wider outer accent rect, drawn first so the BgDeep panel
    -- on top of it leaves a 1px cyan border showing on all four sides.
    ui.border_outer = img(px - 1, py - 1, W + 2, H + 2, C.border)

    -- Main dark navy body
    ui.panel        = img(px, py, W, H, C.bg_deep)

    -- Title strip (slightly lighter than the body so the title band reads)
    ui.titlebar_bg  = img(px, py + Y_TITLE, W, Y_TITLE_END - Y_TITLE, C.bg_panel)

    -- 1px cyan separator under the title
    ui.title_line   = img(px, py + Y_TITLE_END, W, 1, C.accent)

    -- Footer strip + separator above it
    ui.foot_line    = img(px, py + Y_FOOT_LINE, W, 1, C.accent)
    ui.footer_bg    = img(px, py + Y_FOOTER, W, H - Y_FOOTER, C.bg_panel)

    -- Title text + version subtitle (kept as plain non-bold texts so they
    -- track drags — see v1.2.1 commit for the stroke/bold movement bug).
    ui.title   = txt('FFXIUpdater', px + 14, py + 8,  'Arial',   15, C.accent)
    ui.version = txt('v' .. _addon.version, px + 130, py + 11, 'Arial', 10, C.text_muted)

    -- Close button (X) top-right
    ui.btn_close     = img(px + W - 32, py + 6, 24, 24, {a=240, r=130, g=40, b=40})
    ui.btn_close_lbl = txt('X', px + W - 26, py + 8, 'Arial', 13, C.text_main)

    -- Status block — one multi-line text so layout stays simple. Each
    -- row is "Label    :  value" with consistent padding via printf.
    ui.body = txt('', px + 24, py + Y_BODY, 'Consolas', 11, C.text_main)

    -- Tiny colored dot next to the "Status:" row. Placed manually because
    -- the body is a single text block. Default position is row 3 of body.
    ui.status_dot = img(px + 110, py + Y_BODY + 36, 10, 10, C.warn)

    -- Buttons
    ui.btn_refresh     = img(px + 20, py + Y_BUTTONS, 140, 32, C.bg_panel2)
    ui.btn_refresh_lbl = txt('Refresh', px + 64, py + Y_BUTTONS + 8, 'Arial', 12, C.text_main)

    ui.btn_update      = img(px + 180, py + Y_BUTTONS, 180, 32, C.accent_dim)
    ui.btn_update_lbl  = txt('Update Now', px + 220, py + Y_BUTTONS + 8, 'Arial', 12, C.text_main)

    -- Footer hint
    ui.footer_text = txt('Press Z to toggle  ·  auto-reload: ON', px + 14, py + Y_FOOTER + 9,
                         'Arial', 10, C.text_dim)
end

-- ---------------------------------------------------------------------------
-- Reposition every UI element after a drag. Same offsets as build_ui so
-- the two must stay in sync. Uses :pos(x, y) for everything because the
-- separate :pos_x() / :pos_y() pair drops one axis on some Windower
-- builds (see v1.1.1 commit message).
-- ---------------------------------------------------------------------------
local function move_ui(dx, dy)
    settings.pos.x = settings.pos.x + dx
    settings.pos.y = settings.pos.y + dy
    local px, py = settings.pos.x, settings.pos.y

    if ui.border_outer    then ui.border_outer:pos(px - 1, py - 1) end
    if ui.panel           then ui.panel:pos(px, py) end
    if ui.titlebar_bg     then ui.titlebar_bg:pos(px, py + Y_TITLE) end
    if ui.title_line      then ui.title_line:pos(px, py + Y_TITLE_END) end
    if ui.foot_line       then ui.foot_line:pos(px, py + Y_FOOT_LINE) end
    if ui.footer_bg       then ui.footer_bg:pos(px, py + Y_FOOTER) end

    if ui.title           then ui.title:pos(px + 14, py + 8) end
    if ui.version         then ui.version:pos(px + 130, py + 11) end
    if ui.body            then ui.body:pos(px + 24, py + Y_BODY) end
    if ui.status_dot      then ui.status_dot:pos(px + 110, py + Y_BODY + 36) end
    if ui.footer_text     then ui.footer_text:pos(px + 14, py + Y_FOOTER + 9) end

    if ui.btn_close       then ui.btn_close:pos(px + W - 32, py + 6) end
    if ui.btn_close_lbl   then ui.btn_close_lbl:pos(px + W - 26, py + 8) end
    if ui.btn_refresh     then ui.btn_refresh:pos(px + 20, py + Y_BUTTONS) end
    if ui.btn_refresh_lbl then ui.btn_refresh_lbl:pos(px + 64, py + Y_BUTTONS + 8) end
    if ui.btn_update      then ui.btn_update:pos(px + 180, py + Y_BUTTONS) end
    if ui.btn_update_lbl  then ui.btn_update_lbl:pos(px + 220, py + Y_BUTTONS + 8) end
end

-- ---------------------------------------------------------------------------
-- Render the cached state into the body text. Each line is padded so the
-- "label : value" columns align in the monospace font.
-- ---------------------------------------------------------------------------
local function redraw_body()
    local s = ui.state
    -- Body has fixed slot for branch/commit/status/checked, then a
    -- blank line, then the optional status banner.
    local body = string.format(
        'Branch    :  %s\n' ..
        'Commit    :  %s\n' ..
        'Status    :     %s\n' ..  -- extra space leaves room for the dot
        'Checked   :  %s',
        s.branch, s.commit, s.dirty, s.checked)
    if s.msg and s.msg ~= '' then
        body = body .. '\n\n>> ' .. s.msg
    end
    if ui.body then ui.body:text(body) end

    -- Status dot color tracks the dot state.
    if ui.status_dot then
        local dotc = C[s.dot] or C.warn
        ui.status_dot:color(dotc.r, dotc.g, dotc.b)
    end
end

local function refresh_footer()
    if not ui.footer_text then return end
    ui.footer_text:text(string.format(
        'Press Z to toggle  ·  auto-reload: %s',
        settings.auto_reload and 'ON' or 'off'))
end

-- Update-button visual state. When an update is running, the button is
-- recolored bright cyan and the label ticks elapsed seconds so the user
-- can see the addon IS doing something — no more silent click.
local function set_update_button_busy(busy)
    if not ui.btn_update then return end
    if busy then
        -- Bright cyan accent — "busy" rather than "available". Looks
        -- distinctly different from the idle state and from a disabled
        -- state. The label is overwritten by the elapsed-time poller
        -- below, but we start with "Updating..." in case the poller
        -- hasn't run its first tick yet.
        ui.btn_update:color(C.busy.r, C.busy.g, C.busy.b)
        if ui.btn_update_lbl then ui.btn_update_lbl:text('Updating...') end
        ui.state.dot = 'busy'
    else
        ui.btn_update:color(C.accent_dim.r, C.accent_dim.g, C.accent_dim.b)
        if ui.btn_update_lbl then ui.btn_update_lbl:text('Update Now') end
    end
    if settings.visible then redraw_body() end
end

-- Set a body-status banner. Banner stays until next refresh_status or
-- explicit clear.
local function set_status_msg(msg, level)
    ui.state.msg = msg or ''
    if level and (level == 'ok' or level == 'warn' or level == 'err' or level == 'busy') then
        ui.state.dot = level
    end
    if settings.visible then redraw_body() end
end

-- ---------------------------------------------------------------------------
-- Ticking feedback: while update_in_progress is true, refresh the button
-- label and the body banner once a second with the elapsed seconds. Both
-- the click signal (initial recolor) AND this ongoing tick are needed to
-- visibly distinguish "click registered → working" from "nothing happened."
-- ---------------------------------------------------------------------------
local function tick_elapsed()
    if not ui.update_in_progress then return end
    local elapsed = os.time() - (ui.update_start_time or os.time())
    if ui.btn_update_lbl then
        ui.btn_update_lbl:text(string.format('Updating... %ds', elapsed))
    end
    set_status_msg(string.format(
        'git pull running... %ds elapsed (cmd window has the live output)',
        elapsed), 'busy')
    -- Also nudge chat every 5 s so users not staring at the panel
    -- still know something's happening.
    if elapsed > 0 and elapsed % 5 == 0 then
        say(207, string.format('still running... %ds elapsed', elapsed))
    end
    coroutine.schedule(tick_elapsed, 1)
end

-- All visible elements, in z-order from back to front.
local function ui_elements()
    return {
        ui.border_outer, ui.panel,
        ui.titlebar_bg, ui.title_line,
        ui.foot_line,   ui.footer_bg,
        ui.title,       ui.version,
        ui.btn_close,   ui.btn_close_lbl,
        ui.body,        ui.status_dot,
        ui.btn_refresh, ui.btn_refresh_lbl,
        ui.btn_update,  ui.btn_update_lbl,
        ui.footer_text,
    }
end

local function show_ui()
    if not ui.panel then build_ui() end
    settings.visible = true
    for _, e in ipairs(ui_elements()) do if e then e:show() end end
    -- Restore the button's visual state in case we're reopening mid-update.
    set_update_button_busy(ui.update_in_progress)
    refresh_footer()
    redraw_body()
    refresh_status_async()  -- auto-fresh on open
end

local function hide_ui()
    settings.visible = false
    for _, e in ipairs(ui_elements()) do if e then e:hide() end end
end

local function toggle_ui()
    if settings.visible then hide_ui() else show_ui() end
end

-- ============================================================================
-- Status refresh (async — never blocks the game thread)
-- ============================================================================
-- Routes through a temp log file:
--   1. write a bat that pipes `git branch` + `git log -1` + `git status -s`
--      into status.log (one redirect at the end of a parenthesized block)
--   2. @exec the bat
--   3. coroutine.schedule re-reads the log after ~1.5s and updates ui.state
-- We don't block on os.execute because that would freeze the FFXI thread
-- during the git call, which feels janky.
-- ============================================================================
function refresh_status_async()
    if not is_git_checkout() then
        ui.state.branch  = '(not a git checkout)'
        ui.state.commit  = '-'
        ui.state.dirty   = '-'
        ui.state.checked = os.date('%Y-%m-%d %H:%M:%S')
        if settings.visible then redraw_body() end
        return
    end

    local bat = addon_dir .. '/status.bat'
    local out = addon_dir .. '/status.log'
    os.remove(out)

    local content = table.concat({
        '@echo off',
        'cd /d "' .. windower_root .. '"',
        '(',
        '  git branch --show-current',
        '  echo ---',
        '  git log -1 --oneline',
        '  echo ---',
        '  git status -s',
        ') > "' .. out .. '" 2>&1',
    }, '\r\n') .. '\r\n'

    if not write_file(bat, content) then return end
    windower.send_command('@exec ' .. bat)

    coroutine.schedule(function()
        local f = io.open(out, 'r')
        if not f then
            ui.state.branch = '(no output)'
            if settings.visible then redraw_body() end
            return
        end
        -- Parse the three sections separated by "---" markers.
        local section = 1
        ui.state.branch = ''
        ui.state.commit = ''
        local dirty_lines = 0
        for line in f:lines() do
            if line == '---' then
                section = section + 1
            elseif section == 1 and ui.state.branch == '' then
                ui.state.branch = line
            elseif section == 2 and ui.state.commit == '' then
                -- Truncate the commit subject so long messages don't
                -- overflow the panel.
                ui.state.commit = line:sub(1, 60) .. (line:len() > 60 and '...' or '')
            elseif section == 3 and line ~= '' then
                dirty_lines = dirty_lines + 1
            end
        end
        f:close()
        ui.state.dirty   = dirty_lines == 0 and 'clean' or (dirty_lines .. ' file(s) modified')
        ui.state.checked = os.date('%Y-%m-%d %H:%M:%S')
        -- Status dot color tracks the state: green when clean, yellow
        -- when there are uncommitted edits, cyan during an active pull,
        -- red on parse failure. Don't override 'busy' mid-update.
        if not ui.update_in_progress then
            ui.state.dot = (dirty_lines == 0) and 'ok' or 'warn'
        end
        if settings.visible then redraw_body() end
    end, 1.5)
end

-- ============================================================================
-- Chat commands
-- ============================================================================
local function do_status_chat()
    refresh_status_async()
    coroutine.schedule(function()
        say(207, '--- repo status ---')
        windower.add_to_chat(207, '  Branch:  ' .. ui.state.branch)
        windower.add_to_chat(207, '  Commit:  ' .. ui.state.commit)
        windower.add_to_chat(207, '  Status:  ' .. ui.state.dirty)
    end, 2)
end

local function do_help()
    say(207, 'commands:')
    windower.add_to_chat(207, '  //fu                       git pull (update everything)')
    windower.add_to_chat(207, '  //fu status                status to chat (branch, commit, dirty)')
    windower.add_to_chat(207, '  //fu show / hide           open / close the on-screen panel')
    windower.add_to_chat(207, '  //fu autoreload on|off     after pull, auto //lua reload changed addons (now: '
                              .. (settings.auto_reload and 'ON' or 'off') .. ')')
    windower.add_to_chat(207, '  //fu help                  this list')
    windower.add_to_chat(207, '  Z hotkey                   toggles the on-screen panel')
end

windower.register_event('addon command', function(arg, arg2)
    arg = (arg or ''):lower()
    if arg == '' or arg == 'pull' then
        do_update()
    elseif arg == 'status' or arg == 's' then
        do_status_chat()
    elseif arg == 'show' or arg == 'open' then
        show_ui()
    elseif arg == 'hide' or arg == 'close' then
        hide_ui()
    elseif arg == 'toggle' then
        toggle_ui()
    elseif arg == 'autoreload' then
        -- Accept `on`, `off`, `true`, `false`, `1`, `0`, or no arg (= toggle).
        local v = (arg2 or ''):lower()
        if v == 'on' or v == 'true' or v == '1' then
            settings.auto_reload = true
        elseif v == 'off' or v == 'false' or v == '0' then
            settings.auto_reload = false
        else
            settings.auto_reload = not settings.auto_reload
        end
        config.save(settings)
        refresh_footer()
        say(207, 'auto-reload after update: ' .. (settings.auto_reload and 'ON' or 'off'))
    elseif arg == 'help' or arg == 'h' or arg == '?' then
        do_help()
    else
        say(167, 'unknown subcommand: ' .. arg)
        do_help()
    end
end)

-- ============================================================================
-- Keyboard: Z toggles, suppressed while chat is open.
-- DIK scancodes (DirectInput) — Z = 0x2C = 44.
-- We `return true` for both press and release of Z when we handle it so
-- FFXI never sees the key (otherwise the next character cast or menu
-- could pick it up as input).
-- ============================================================================
local DIK_Z = 44

windower.register_event('keyboard', function(dik, pressed, flags, blocked)
    if blocked then return end
    if dik ~= DIK_Z then return end
    -- If chat is open, let Z fall through so typing the letter works.
    if windower.ffxi.get_info().chat_open then return end
    if pressed then toggle_ui() end
    return true
end)

-- ============================================================================
-- Mouse: drag the title bar to move, click buttons.
-- Mouse event types: 0 = move, 1 = LMB down, 2 = LMB up, 3 = RMB down,
-- 4 = RMB up. We only act when the window is visible.
-- ============================================================================
windower.register_event('mouse', function(mtype, x, y, delta, blocked)
    if blocked then return end
    if not settings.visible then return end

    if mtype == 1 then  -- LMB down
        -- close button has precedence so an accidental drag from the X
        -- still closes the panel
        local cx1, cy1, cx2, cy2 = rect_close()
        if point_in_rect(x, y, cx1, cy1, cx2, cy2) then
            hide_ui()
            return true
        end
        local rx1, ry1, rx2, ry2 = rect_refresh()
        if point_in_rect(x, y, rx1, ry1, rx2, ry2) then
            refresh_status_async()
            return true
        end
        local ux1, uy1, ux2, uy2 = rect_update()
        if point_in_rect(x, y, ux1, uy1, ux2, uy2) then
            do_update()
            return true
        end
        -- Title bar — start drag
        local tx1, ty1, tx2, ty2 = rect_titlebar()
        if point_in_rect(x, y, tx1, ty1, tx2, ty2) then
            ui.drag.active = true
            ui.drag.ox = x - settings.pos.x
            ui.drag.oy = y - settings.pos.y
            return true
        end
    elseif mtype == 0 then  -- mouse move
        if ui.drag.active then
            local target_x = x - ui.drag.ox
            local target_y = y - ui.drag.oy
            move_ui(target_x - settings.pos.x, target_y - settings.pos.y)
            return true
        end
    elseif mtype == 2 then  -- LMB up
        if ui.drag.active then
            ui.drag.active = false
            config.save(settings)
            return true
        end
    end
end)

-- ============================================================================
-- Lifecycle
-- ============================================================================
windower.register_event('load', function()
    build_ui()
    if settings.visible then show_ui() end
    say(207, ('loaded v%s. Z toggles the window, //fu help for commands.'):format(_addon.version))
end)

windower.register_event('unload', function()
    -- Persist the last window position even if FFXI/Windower is being
    -- shut down cleanly.
    config.save(settings)
end)
