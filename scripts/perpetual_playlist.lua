-- perpetual-playlist: persist the playlist across mpv restarts, resume
-- exact playback position, and play cold-start items first.
--
-- See plugins/perpetual-playlist/SPECS.md for the feature spec and
-- plugins/perpetual-playlist/README.md for usage.

local options = require "mp.options"

local opts = {
    playlist_file = "~/.config/mpv/last_playlist.m3u8",
    osd_duration = 3,
}
options.read_options(opts, "perpetual_playlist")

-- mpv's own path expansion (~/, ~~/, etc.) only applies to paths passed
-- directly to mpv commands, not to strings handed to Lua's io.open. Resolve
-- once at load time via the `expand-path` command.
local playlist_file = mp.command_native({"expand-path", opts.playlist_file})

local finished_all = false

-- Helpers

local function is_url(s)
    return s:match("^%a[%a%d+%-%.]*://") ~= nil
end

local function resolve_path(filename, cwd)
    if not is_url(filename) and not filename:match("^/") then
        return cwd .. "/" .. filename
    end
    return filename
end

local function read_saved_playlist()
    local items = {}
    local f = io.open(playlist_file, "r")
    if not f then
        return items
    end
    for raw_line in f:lines() do
        local line = raw_line:match("^%s*(.-)%s*$") -- trim whitespace
        if line ~= "" and not line:match("^#") then
            table.insert(items, line)
        end
    end
    f:close()
    return items
end

local function save_playlist_items(items)
    if #items == 0 then
        os.remove(playlist_file)
        return
    end
    local f = io.open(playlist_file, "w")
    if f then
        f:write("#EXTM3U\n")
        for _, item in ipairs(items) do
            f:write(item .. "\n")
        end
        f:close()
    end
end

-- Returns playlist items from a given 0-indexed position onwards
local function get_remaining_items(from_pos)
    local playlist = mp.get_property_native("playlist") or {}
    local cwd = mp.get_property("working-directory")
    local items = {}
    for i = from_pos + 1, #playlist do -- +1: Lua is 1-indexed, from_pos is 0-indexed
        table.insert(items, resolve_path(playlist[i].filename, cwd))
    end
    return items
end

-- Startup: merge saved playlist with command-line args
--
-- Command-line items (if any) are already queued as playlist entries by the
-- time this callback runs, but mpv's core hasn't necessarily started truly
-- playing entry 0 yet. Appending to the playlist while that's still
-- pending can make mpv jump straight to playing entry 1 instead, empirically
-- (verified against mpv 0.41.0) - so the append is deferred until the
-- "file-loaded" event confirms entry 0 has genuinely begun playback, rather
-- than trying to out-guess the race with a fixed delay.
local pending_append = nil

local function on_startup()
    local cwd = mp.get_property("working-directory")
    local cmdline_items = {}
    for _, item in ipairs(mp.get_property_native("playlist") or {}) do
        table.insert(cmdline_items, resolve_path(item.filename, cwd))
    end

    local saved_items = read_saved_playlist()

    if #saved_items == 0 and #cmdline_items == 0 then
        return -- nothing to do
    end

    if #saved_items == 0 then
        -- First run, or the previous run finished everything: just persist
        -- what's already playing for future tracking.
        save_playlist_items(cmdline_items)
        return
    end

    if #cmdline_items == 0 then
        -- Plain resume: no new items, load the saved playlist and let mpv
        -- autoplay item 1, which the end-file retention logic below always
        -- keeps pointed at "the last watched / next-to-watch" item.
        mp.commandv("loadlist", playlist_file)
        mp.osd_message("Resuming saved playlist (" .. #saved_items .. " item(s))", opts.osd_duration)
        return
    end

    -- Both present: cmdline items are already loading and item 1 will play
    -- immediately. Don't touch the current playlist with `loadlist` (that
    -- replaces it and would kill playback) - append the saved items to the
    -- end instead, once item 0 has actually started (see pending_append).
    -- They'll play automatically once the cmdline items are exhausted, via
    -- mpv's normal playlist-advance + keep-open=yes.
    pending_append = function()
        for _, filename in ipairs(saved_items) do
            mp.commandv("loadfile", filename, "append")
        end

        local combined = {}
        for _, item in ipairs(cmdline_items) do
            table.insert(combined, item)
        end
        for _, item in ipairs(saved_items) do
            table.insert(combined, item)
        end
        save_playlist_items(combined)

        mp.osd_message(
            "Playing " .. #cmdline_items .. " new item(s), then resuming " .. #saved_items .. " saved",
            opts.osd_duration
        )
    end
end

mp.add_timeout(0, on_startup)

mp.register_event("file-loaded", function()
    if pending_append then
        pending_append()
        pending_append = nil
    end
end)

-- Whenever the current file stops, for any reason: proactively write its
-- exact resume position, and update the saved playlist depending on whether
-- it actually finished or not.

mp.register_event("end-file", function(event)
    -- mpv's save-position-on-quit=yes only writes a watch_later entry
    -- natively at process shutdown. This call is what makes mid-session
    -- navigation (N/P, playlist_manager jumps, natural eof) also leave a
    -- resumable exact-position entry, not just clean quits. playlist-pos
    -- still refers to the entry that just ended at this point - mpv only
    -- advances it once the next file actually starts loading.
    mp.command("write-watch-later-config")

    local pos = mp.get_property_number("playlist-pos", 0)
    local count = mp.get_property_number("playlist-count", 0)

    if event.reason == "eof" then
        -- Item genuinely finished: drop it from the saved list.
        if pos >= count - 1 then
            save_playlist_items({})
            finished_all = true
        else
            save_playlist_items(get_remaining_items(pos + 1))
            finished_all = false
        end
    else
        -- "stop" (manual next/prev, playlist_manager jump), "quit", "error":
        -- the item did not finish, keep it (and everything after it) so it
        -- can be resumed later.
        save_playlist_items(get_remaining_items(pos))
        finished_all = false
    end
end)

-- Defensive backstop in case some quit path doesn't cleanly emit end-file
-- with a reason before shutdown fires. save_playlist_items is a full
-- overwrite, so a redundant call here is harmless.

mp.register_event("shutdown", function()
    if finished_all then
        return
    end
    local pos = mp.get_property_number("playlist-pos", 0)
    save_playlist_items(get_remaining_items(pos))
end)
