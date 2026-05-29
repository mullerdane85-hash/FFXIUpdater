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
_addon.version   = '1.1.1'
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
    pos     = {x = 200, y = 200},
    visible = false,
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

-- //fu pull — visible cmd window, pauses so user can read the result.
-- Also drives the UI feedback path: button label flips to "Updating...",
-- body gets a banner, and after 8s we refresh status and report whether
-- the commit actually changed.
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

    -- Feedback: in-game chat, button visual, body banner.
    say(207, 'Starting update — a cmd window will show git pull output.')
    if settings.visible then
        set_update_button_busy(true)
        set_status_msg('Updating... (cmd window opened — output is there)', 'info')
    end
    ui.update_in_progress = true

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
            ui.update_in_progress = false
            -- Re-read git state, which will update ui.state.commit.
            refresh_status_async()
            -- After the status refresh completes (~1.5 s), compare commits.
            coroutine.schedule(function()
                local before = ui.last_commit_before_update or ''
                local after  = ui.state.commit or ''
                local same   = (before:sub(1, 7) == after:sub(1, 7))
                if settings.visible then
                    set_update_button_busy(false)
                    if same then
                        set_status_msg('Already up to date (' .. after:sub(1, 7) .. ').', 'ok')
                    else
                        set_status_msg('Update complete — now at ' .. after:sub(1, 7) .. '. Reload affected addons.', 'ok')
                    end
                end
                say(207, same and 'Already up to date.' or ('Update complete — now at ' .. after:sub(1, 7) .. '.'))
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

local W, H = 460, 200   -- window size

local ui = {
    panel     = nil,
    border    = nil,
    title     = nil,
    body      = nil,         -- shows multi-line status text
    btn_close = nil,
    btn_close_lbl = nil,
    btn_refresh = nil,
    btn_refresh_lbl = nil,
    btn_update = nil,
    btn_update_lbl = nil,

    -- runtime state cached for redraws / drag
    state = {
        branch  = '?',
        commit  = '?',
        dirty   = '?',
        checked = 'never',
        msg     = '',            -- bottom-of-body status banner (e.g. "Updating...")
        msg_color = 'info',      -- 'info' | 'ok' | 'warn'
    },
    drag = {
        active = false,
        ox = 0, oy = 0,        -- offset from cursor to window origin while dragging
    },
    update_in_progress = false,
    last_commit_before_update = nil,  -- so we can detect actual change after pull
}

-- ---------------------------------------------------------------------------
-- click rectangles (recomputed every move based on settings.pos)
-- ---------------------------------------------------------------------------
local function rect_titlebar()
    return settings.pos.x, settings.pos.y, settings.pos.x + W - 30, settings.pos.y + 30
end
local function rect_close()
    return settings.pos.x + W - 28, settings.pos.y + 4, settings.pos.x + W - 6, settings.pos.y + 26
end
local function rect_refresh()
    return settings.pos.x + 16, settings.pos.y + 158, settings.pos.x + 116, settings.pos.y + 186
end
local function rect_update()
    return settings.pos.x + 140, settings.pos.y + 158, settings.pos.x + 280, settings.pos.y + 186
end

local function point_in_rect(x, y, x1, y1, x2, y2)
    return x >= x1 and x <= x2 and y >= y1 and y <= y2
end

-- ---------------------------------------------------------------------------
-- Build UI elements once at load. Hidden until show_ui() is called.
-- All colors picked to mirror GSUI: dark navy bg, cyan accents.
-- ---------------------------------------------------------------------------
local function build_ui()
    ui.panel = images.new({
        pos     = settings.pos,
        size    = {width = W, height = H},
        color   = {alpha = 235, red =  14, green =  23, blue =  38},
        visible = false,
    })

    ui.border = images.new({
        pos     = settings.pos,
        size    = {width = W, height = H},
        color   = {alpha =   0, red =   0, green =   0, blue =   0},
        visible = false,
    })
    -- (no native stroke in images.new; we draw a faint inset frame by
    --  showing a slightly smaller darker panel underneath for depth)

    ui.title = texts.new('FFXIUpdater v' .. _addon.version, {
        pos   = {x = settings.pos.x + 12, y = settings.pos.y + 6},
        text  = {font = 'Arial', size = 13, alpha = 255, red = 95, green = 200, blue = 255, stroke = {width = 1, alpha = 255, red = 0, green = 0, blue = 0}},
        bg    = {visible = false},
        flags = {bold = true, draggable = false},
        visible = false,
    })

    ui.body = texts.new('', {
        pos   = {x = settings.pos.x + 14, y = settings.pos.y + 40},
        text  = {font = 'Consolas', size = 11, alpha = 255, red = 229, green = 238, blue = 248, stroke = {width = 1, alpha = 200, red = 0, green = 0, blue = 0}},
        bg    = {visible = false},
        flags = {draggable = false},
        visible = false,
    })

    -- Close button (top-right X)
    ui.btn_close = images.new({
        pos     = {x = settings.pos.x + W - 28, y = settings.pos.y + 4},
        size    = {width = 22, height = 22},
        color   = {alpha = 235, red = 130, green =  40, blue =  40},
        visible = false,
    })
    ui.btn_close_lbl = texts.new('X', {
        pos   = {x = settings.pos.x + W - 22, y = settings.pos.y + 5},
        text  = {font = 'Arial', size = 12, alpha = 255, red = 255, green = 230, blue = 230},
        bg    = {visible = false},
        flags = {bold = true, draggable = false},
        visible = false,
    })

    -- Refresh button
    ui.btn_refresh = images.new({
        pos     = {x = settings.pos.x + 16, y = settings.pos.y + 158},
        size    = {width = 100, height = 28},
        color   = {alpha = 235, red =  27, green =  42, blue =  71},
        visible = false,
    })
    ui.btn_refresh_lbl = texts.new('Refresh', {
        pos   = {x = settings.pos.x + 42, y = settings.pos.y + 164},
        text  = {font = 'Arial', size = 11, alpha = 255, red = 229, green = 238, blue = 248},
        bg    = {visible = false},
        flags = {draggable = false},
        visible = false,
    })

    -- Update Now button (accent)
    ui.btn_update = images.new({
        pos     = {x = settings.pos.x + 140, y = settings.pos.y + 158},
        size    = {width = 140, height = 28},
        color   = {alpha = 235, red =  58, green = 111, blue = 165},
        visible = false,
    })
    ui.btn_update_lbl = texts.new('Update Now', {
        pos   = {x = settings.pos.x + 168, y = settings.pos.y + 164},
        text  = {font = 'Arial', size = 11, alpha = 255, red = 229, green = 238, blue = 248},
        bg    = {visible = false},
        flags = {bold = true, draggable = false},
        visible = false,
    })
end

-- ---------------------------------------------------------------------------
-- Reposition all UI elements after a drag.
-- Use the combined :pos(x, y) form on texts — separate :pos_x() / :pos_y()
-- calls were dropping one axis on some Windower builds, which is what
-- made the title / body / button labels stay put when dragging the panel.
-- :pos(x, y) sets both atomically and triggers the redraw cleanly.
-- ---------------------------------------------------------------------------
local function move_ui(dx, dy)
    settings.pos.x = settings.pos.x + dx
    settings.pos.y = settings.pos.y + dy
    local px, py = settings.pos.x, settings.pos.y
    if ui.panel           then ui.panel:pos(px, py) end
    if ui.border          then ui.border:pos(px, py) end
    if ui.title           then ui.title:pos(px + 12, py + 6) end
    if ui.body            then ui.body:pos(px + 14, py + 40) end
    if ui.btn_close       then ui.btn_close:pos(px + W - 28, py + 4) end
    if ui.btn_close_lbl   then ui.btn_close_lbl:pos(px + W - 22, py + 5) end
    if ui.btn_refresh     then ui.btn_refresh:pos(px + 16, py + 158) end
    if ui.btn_refresh_lbl then ui.btn_refresh_lbl:pos(px + 42, py + 164) end
    if ui.btn_update      then ui.btn_update:pos(px + 140, py + 158) end
    if ui.btn_update_lbl  then ui.btn_update_lbl:pos(px + 168, py + 164) end
end

-- ---------------------------------------------------------------------------
-- Render the cached state into the body text. If a status message is
-- set (msg field), it appears as an extra line at the bottom — used to
-- give immediate feedback when the Update button is clicked, before
-- the actual git pull completes.
-- ---------------------------------------------------------------------------
local function redraw_body()
    local s = ui.state
    local body = string.format(
        'Branch:   %s\n' ..
        'Commit:   %s\n' ..
        'Status:   %s\n' ..
        'Checked:  %s',
        s.branch, s.commit, s.dirty, s.checked)
    if s.msg and s.msg ~= '' then
        body = body .. '\n\n>> ' .. s.msg
    end
    ui.body:text(body)
end

-- Update-button visual state. When an update is running, the button is
-- dimmed and its label changes to "Updating..." so the user knows the
-- click registered even before they see the cmd window appear.
local function set_update_button_busy(busy)
    if not ui.btn_update then return end
    if busy then
        ui.btn_update:color(70, 90, 110)         -- dim slate
        if ui.btn_update_lbl then ui.btn_update_lbl:text('Updating...') end
    else
        ui.btn_update:color(58, 111, 165)        -- accent cyan/blue
        if ui.btn_update_lbl then ui.btn_update_lbl:text('Update Now') end
    end
end

-- Set a body-status banner for N seconds (or until explicitly cleared).
local function set_status_msg(msg, level)
    ui.state.msg = msg or ''
    ui.state.msg_color = level or 'info'
    if settings.visible then redraw_body() end
end

local function show_ui()
    if not ui.panel then build_ui() end
    settings.visible = true
    ui.panel:show()
    ui.title:show()
    ui.body:show()
    ui.btn_close:show()
    ui.btn_close_lbl:show()
    ui.btn_refresh:show()
    ui.btn_refresh_lbl:show()
    ui.btn_update:show()
    ui.btn_update_lbl:show()
    -- Restore the button's visual state (was the last close mid-update?).
    set_update_button_busy(ui.update_in_progress)
    redraw_body()
    -- Auto-refresh on open so the user always sees current state.
    refresh_status_async()
end

local function hide_ui()
    settings.visible = false
    if ui.panel then ui.panel:hide() end
    if ui.title then ui.title:hide() end
    if ui.body  then ui.body:hide() end
    if ui.btn_close then ui.btn_close:hide() end
    if ui.btn_close_lbl then ui.btn_close_lbl:hide() end
    if ui.btn_refresh then ui.btn_refresh:hide() end
    if ui.btn_refresh_lbl then ui.btn_refresh_lbl:hide() end
    if ui.btn_update then ui.btn_update:hide() end
    if ui.btn_update_lbl then ui.btn_update_lbl:hide() end
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
    windower.add_to_chat(207, '  //fu                 git pull (update everything)')
    windower.add_to_chat(207, '  //fu status          status to chat (branch, commit, dirty)')
    windower.add_to_chat(207, '  //fu show / hide     open / close the on-screen panel')
    windower.add_to_chat(207, '  //fu help            this list')
    windower.add_to_chat(207, '  Z hotkey             toggles the on-screen panel')
end

windower.register_event('addon command', function(arg)
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
