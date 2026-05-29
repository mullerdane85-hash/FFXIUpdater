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
_addon.version   = '1.0.0'
_addon.author    = 'TWinn22'
_addon.commands  = {'fu', 'ffxiupdater', 'update'}

-- ============================================================================
-- FFXIUpdater — one-shot self-update for the whole Windower folder
-- ============================================================================
-- Assumes Windower itself is a git checkout of an aggregate repo (e.g.
-- mullerdane85-hash/FFXIWindower). When you type //fu, this addon writes a
-- short pull.bat into its own folder, then asks Windower to spawn it
-- through `@exec`. The bat opens a cmd window, runs `git pull` in the
-- Windower root, and pauses so you can read the result before it closes.
--
-- All your installed addons + plugins + settings come along for the ride
-- because they all live under the same git tree.
--
-- Commands
--   //fu           — git pull (update everything)
--   //fu status    — branch, last commit, dirty files
--   //fu help      — this list
-- ============================================================================

-- Windower's path helpers. windower_path always ends with a separator.
local windower_root = windower.windower_path:gsub('\\$', ''):gsub('/$', '')
-- The addon's own folder; trailing separator stripped for clean concat.
local addon_dir = (windower.addon_path or (windower_root .. '/addons/FFXIUpdater/'))
                  :gsub('\\$', ''):gsub('/$', '')

-- ----------------------------------------------------------------------------
-- Small helpers
-- ----------------------------------------------------------------------------
-- Chat-print with our prefix. Color 207 = teal (info), 167 = red (warn).
local function say(color, msg)
    windower.add_to_chat(color or 207, '[FFXIUpdater] ' .. tostring(msg))
end

-- The git CLI only works if Windower's root folder is actually a clone.
-- Looking for .git/HEAD is more reliable than testing the .git folder
-- itself (which could be a file in some submodule setups).
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

-- ----------------------------------------------------------------------------
-- //fu  — git pull, visible cmd window
-- ----------------------------------------------------------------------------
local function do_update()
    if not is_git_checkout() then
        say(167, 'Windower root is not a git checkout (.git missing).')
        say(167, 'Looked at: ' .. windower_root .. '/.git/HEAD')
        say(167, 'Install Windower as `git clone <your-aggregate>` to enable updates.')
        return
    end

    local bat_path = addon_dir .. '/pull.bat'
    -- The bat changes to the Windower root, runs git pull, then pauses so
    -- the user can read the result. `>nul` on pause hides "Press any key
    -- to continue" so the screen stays clean.
    local bat = table.concat({
        '@echo off',
        'title FFXIUpdater - git pull',
        'cd /d "' .. windower_root .. '"',
        'echo === FFXIUpdater: pulling latest from origin ===',
        'echo.',
        'git pull',
        'echo.',
        'echo === done. press any key to close ===',
        'pause >nul',
    }, '\r\n') .. '\r\n'

    if not write_file(bat_path, bat) then return end

    say(207, 'Starting update — a cmd window will show git pull output.')
    -- @exec spawns the bat asynchronously so the FFXI thread isn't blocked.
    -- The new console window is what the user interacts with.
    windower.send_command('@exec ' .. bat_path)
end

-- ----------------------------------------------------------------------------
-- //fu status — branch, last commit, dirty files
-- ----------------------------------------------------------------------------
-- This one wants chat output, not a popup window, so we route through a
-- temp log file:
--   1. delete any stale log from a previous run
--   2. write a bat that pipes git output into the log
--   3. spawn the bat asynchronously
--   4. schedule a re-read of the log after 2 seconds and print to chat
-- The 2-second window covers `git status` even on a slow disk; pure `git
-- branch` + `git log -1` runs in <100ms.
local function do_status()
    if not is_git_checkout() then
        say(167, 'Windower root is not a git checkout.')
        return
    end

    local bat_path = addon_dir .. '/status.bat'
    local out_path = addon_dir .. '/status.log'

    -- Delete the old log so a failed run doesn't show stale data
    os.remove(out_path)

    local bat = table.concat({
        '@echo off',
        'cd /d "' .. windower_root .. '"',
        '(',
        '  echo === branch ===',
        '  git branch --show-current',
        '  echo.',
        '  echo === latest commit ===',
        '  git log -1 --oneline',
        '  echo.',
        '  echo === local changes ^(empty == clean^) ===',
        '  git status -s',
        ') > "' .. out_path .. '" 2>&1',
    }, '\r\n') .. '\r\n'

    if not write_file(bat_path, bat) then return end

    say(207, 'Checking repo status...')
    windower.send_command('@exec ' .. bat_path)

    -- coroutine.schedule fires after the delay without blocking. By 2 s
    -- git will have written the log and the cmd window will have closed.
    coroutine.schedule(function()
        local f = io.open(out_path, 'r')
        if not f then
            say(167, 'Status output not ready. Try `//fu status` again.')
            return
        end
        say(207, '--- repo status ---')
        for line in f:lines() do
            if line and line ~= '' then
                windower.add_to_chat(207, '  ' .. line)
            end
        end
        f:close()
    end, 2)
end

-- ----------------------------------------------------------------------------
-- //fu help
-- ----------------------------------------------------------------------------
local function do_help()
    say(207, 'commands:')
    windower.add_to_chat(207, '  //fu                 git pull (update everything)')
    windower.add_to_chat(207, '  //fu status          branch, last commit, dirty files')
    windower.add_to_chat(207, '  //fu help            this list')
    windower.add_to_chat(207, '  also accepts //ffxiupdater and //update as aliases')
    say(207, 'Updates the whole Windower folder from its origin remote.')
    say(207, 'Your addons live inside Windower/addons/, so they all update together.')
end

-- ============================================================================
-- Command dispatch
-- ============================================================================
windower.register_event('addon command', function(arg, ...)
    -- Lowercased once so "STATUS" == "status" == "Status".
    arg = (arg or ''):lower()
    if arg == '' or arg == 'pull' then
        do_update()
    elseif arg == 'status' or arg == 's' then
        do_status()
    elseif arg == 'help' or arg == 'h' or arg == '?' then
        do_help()
    else
        say(167, 'unknown subcommand: ' .. arg)
        do_help()
    end
end)

windower.register_event('load', function()
    say(207, ('loaded v%s. //fu to update, //fu help for commands.'):format(_addon.version))
end)
