-- perpetual-playlist: persist the playlist across mpv restarts, resume
-- exact playback position, and play cold-start items first.
--
-- See plugins/perpetual-playlist/SPECS.md for the feature spec and
-- plugins/perpetual-playlist/README.md for usage.

local options = require "mp.options"
local utils = require "mp.utils"

local opts = {
    playlist_file = "~/.config/mpv/last_playlist.json",
    osd_duration = 3,
    -- By default nothing is ever removed from the saved playlist, including
    -- items that finished playing - matches SPECS.md's "will not be
    -- deleting items from the playlist". Set to yes to opt back into the
    -- old behavior of dropping an item once it's been watched to the end.
    drop_finished_items = false,
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

-- Returns a new list with duplicate entries removed, keeping the first
-- occurrence of each. `seed_seen`, if given, is a list of entries treated
-- as already-seen (e.g. cmdline items queued ahead of a saved list), so
-- anything in `items` that duplicates one of those is dropped too.
local function dedupe_items(items, seed_seen)
    local seen = {}
    if seed_seen then
        for _, item in ipairs(seed_seen) do
            seen[item] = true
        end
    end
    local result = {}
    for _, item in ipairs(items) do
        if not seen[item] then
            seen[item] = true
            table.insert(result, item)
        end
    end
    return result
end

-- Saved state is { items = {path, path, ...}, current = <0-indexed> }.
-- `items` is never reordered or trimmed except when drop_finished_items
-- opts a file out; `current` independently tracks which item to resume
-- from, so a finished item sitting earlier in the list doesn't get
-- replayed ahead of where playback actually left off.

local function read_saved_state()
    local f = io.open(playlist_file, "r")
    if not f then
        return { items = {}, current = 0 }
    end
    local content = f:read("*a")
    f:close()

    local ok, parsed = pcall(utils.parse_json, content)
    if not ok or type(parsed) ~= "table" or type(parsed.items) ~= "table" then
        return { items = {}, current = 0 }
    end

    local current = tonumber(parsed.current) or 0
    if current < 0 then
        current = 0
    end
    if #parsed.items > 0 and current > #parsed.items - 1 then
        current = #parsed.items - 1
    end

    -- Defensive: a save written before duplicate ingestion was fixed (or
    -- corrupted some other way) may already have duplicate entries baked
    -- in. Dedupe on read so it self-heals on next load rather than
    -- persisting forever. `current` is remapped by value, not index, so it
    -- still points at the same logical item after dedup.
    local current_item = parsed.items[current + 1]
    local items = dedupe_items(parsed.items)
    if current_item then
        for i, item in ipairs(items) do
            if item == current_item then
                current = i - 1
                break
            end
        end
    end

    return { items = items, current = current }
end

local function save_saved_state(items, current)
    if #items == 0 then
        os.remove(playlist_file)
        return
    end
    local f = io.open(playlist_file, "w")
    if f then
        f:write(utils.format_json({ items = items, current = current }))
        f:close()
    end
end

-- Returns the full live playlist as resolved paths. Defensive about holes:
-- mpv's "playlist" property can come back with an unreliable/inconsistent
-- length right at the very end of shutdown (other scripts already being
-- torn down at that point), so entries are checked rather than assumed
-- present just because their index is within #playlist.
local function snapshot_playlist()
    local playlist = mp.get_property_native("playlist") or {}
    local cwd = mp.get_property("working-directory")
    local items = {}
    for _, entry in ipairs(playlist) do
        if entry and entry.filename then
            table.insert(items, resolve_path(entry.filename, cwd))
        end
    end
    return items
end

-- Startup: merge saved state with command-line args
--
-- Command-line items (if any) are already queued as playlist entries by the
-- time this callback runs, but mpv's core hasn't necessarily started truly
-- playing entry 0 yet. Appending to the playlist while that's still
-- pending can make mpv jump straight to playing entry 1 instead, empirically
-- (verified against mpv 0.41.0) - so any further playlist mutation is
-- deferred until the "file-loaded" event confirms the first item has
-- genuinely begun playback, rather than trying to out-guess the race with
-- a fixed delay.
local pending_append = nil

local function on_startup()
    local cmdline_items = snapshot_playlist()
    local saved = read_saved_state()

    if #saved.items == 0 and #cmdline_items == 0 then
        return -- nothing to do
    end

    if #saved.items == 0 then
        -- First run, or the previous run finished everything: just persist
        -- what's already playing for future tracking.
        save_saved_state(cmdline_items, 0)
        return
    end

    if #cmdline_items == 0 then
        -- Plain resume: load every item back in its exact saved order -
        -- item 1 starts playing immediately (unavoidable, loading always
        -- plays what it loads), the rest are appended after it once that's
        -- confirmed (see pending_append). Once the full list is rebuilt,
        -- jump to `current` to actually resume where playback left off;
        -- native per-file watch_later resume applies the same way it does
        -- for any other jump to that item.
        local items = saved.items
        local current = saved.current
        mp.commandv("loadfile", items[1], "replace")

        pending_append = function()
            for i = 2, #items do
                mp.commandv("loadfile", items[i], "append")
            end
            if current > 0 then
                mp.set_property_number("playlist-pos", current)
            end
            save_saved_state(items, current)
        end

        mp.osd_message("Resuming saved playlist (" .. #items .. " item(s))", opts.osd_duration)
        return
    end

    -- Both present: cmdline items are already loading and will play
    -- immediately. Don't touch the current playlist with `loadfile
    -- replace` (that would kill playback) - append the full saved history
    -- to the end instead, once the cmdline item has actually started (see
    -- pending_append). It plays automatically once the cmdline items are
    -- exhausted, via mpv's normal playlist-advance + keep-open=yes.
    --
    -- Saved items that duplicate a cmdline item (e.g. `mpv-add` on
    -- something already in the saved playlist, starting a fresh instance)
    -- are dropped here, before they're ever live-appended or persisted -
    -- relying on playlist_manager.lua's passive post-hoc dedup alone would
    -- leave the duplicate baked into last_playlist.json, since that
    -- cleanup only touches mpv's live playlist and runs after this
    -- function has already saved state to disk.
    pending_append = function()
        local saved_unique = dedupe_items(saved.items, cmdline_items)
        for _, filename in ipairs(saved_unique) do
            mp.commandv("loadfile", filename, "append")
        end

        local combined = {}
        for _, item in ipairs(cmdline_items) do
            table.insert(combined, item)
        end
        for _, item in ipairs(saved_unique) do
            table.insert(combined, item)
        end
        save_saved_state(combined, 0)

        mp.osd_message(
            "Playing " .. #cmdline_items .. " new item(s), then resuming " .. #saved_unique .. " saved",
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
-- exact resume position, and update the saved state depending on whether
-- it actually finished or not.
--
-- By the time the "end-file" event fires, mpv has already fully unloaded
-- the old file - `path`/`time-pos` read back as nil, and `playlist-pos`
-- already points at whatever comes next, not the entry that just ended
-- (verified empirically against mpv 0.41.0). So the resume-position write
-- and the playlist/position snapshot used below have to be captured
-- earlier, from the "on_unload" hook, which fires while the
-- about-to-be-unloaded file is still current. Even there, `playlist-pos`
-- has already advanced - `playlist-playing-pos` is the one that still
-- correctly refers to the entry actually being unloaded.
local last_items = nil
local last_pos = nil

mp.add_hook("on_unload", 50, function()
    -- mpv's save-position-on-quit=yes only writes a watch_later entry
    -- natively at process shutdown. This call is what makes mid-session
    -- navigation (N/P, playlist_manager jumps, natural eof) also leave a
    -- resumable exact-position entry, not just clean quits.
    --
    -- Except when the file being unloaded has already fully finished
    -- (eof-reached) - writing a normal resume entry then would capture
    -- time-pos at essentially the file's own duration, so mpv's own
    -- --resume-playback would honor "resume right at the end" the next
    -- time this item is loaded, making a fully-watched video unwatchable
    -- a second time. Delete any existing entry instead, so a later replay
    -- starts from the beginning - mpv's own default when no watch_later
    -- entry exists. This has to live here rather than only in
    -- handle_finished() below (tried first, confirmed insufficient by
    -- testing): eof-reached also stays true for a last-item file sitting
    -- frozen under keep-open, and unloading it *again* later (e.g.
    -- reloading it, or any other transition away from that frozen state)
    -- re-enters on_unload without necessarily re-entering handle_finished
    -- - a second unconditional write would otherwise silently recreate
    -- the exact bad entry handle_finished had already deleted once.
    if mp.get_property_bool("eof-reached", false) then
        local current_file = mp.get_property("path")
        if current_file then
            mp.commandv("delete-watch-later-config", current_file)
        end
    else
        mp.command("write-watch-later-config")
    end
    last_items = snapshot_playlist()
    last_pos = mp.get_property_number("playlist-playing-pos", nil)
end)

-- Shared by both the mid-playlist end-file(eof) case and the true-last-item
-- eof-reached case below: either drop the finished item (opted in) or keep
-- everything as-is (default).
local function handle_finished(items, pos)
    if opts.drop_finished_items then
        -- Remove it from both the saved state and mpv's own live playlist.
        -- Without the latter, the next transition's snapshot_playlist()
        -- would just read it right back out of mpv's still-intact live
        -- playlist and silently undo the drop.
        if pos >= 0 and pos < #items then
            table.remove(items, pos + 1) -- +1: Lua is 1-indexed
            mp.commandv("playlist-remove", pos)
        end
        if #items == 0 then
            save_saved_state({}, 0)
            finished_all = true
        else
            save_saved_state(items, math.min(pos, #items - 1))
            finished_all = false
        end
    else
        -- Keep every item, including one that just finished playing, so
        -- nothing is ever silently removed from the saved playlist.
        save_saved_state(items, pos)
        finished_all = false
    end
end

mp.register_event("end-file", function(event)
    local items = last_items or snapshot_playlist()
    local pos = last_pos or 0

    if event.reason == "eof" then
        handle_finished(items, pos)
    else
        -- "stop" (manual next/prev, playlist_manager jump), "quit", "error":
        -- the item did not finish, always keep it (and everything else)
        -- regardless of drop_finished_items, since it never finished
        -- playing in the first place.
        save_saved_state(items, pos)
        finished_all = false
    end
end)

-- The true last item in the playlist is a special case: with keep-open=yes,
-- mpv freezes on its last frame instead of unloading it, so on_unload/
-- end-file never fire for that specific transition (verified empirically -
-- confirmed no "end-file" event at all when the final item finishes).
-- eof-reached is the one property that still flips true for it, but it also
-- flips true+false for every ordinary mid-playlist transition (already
-- handled above), so this only acts when it's genuinely the last entry.
mp.observe_property("eof-reached", "bool", function(_, reached)
    if not reached or finished_all then
        return
    end
    local count = mp.get_property_number("playlist-count", 0)
    local pos = mp.get_property_number("playlist-playing-pos", -1)
    if pos < 0 or pos + 1 < count then
        return -- not the last item; the normal end-file path already handled it
    end
    handle_finished(snapshot_playlist(), pos)
end)

-- Defensive backstop in case some quit path doesn't cleanly emit end-file
-- with a reason before shutdown fires. save_saved_state is a full
-- overwrite, so a redundant call here is harmless. Wrapped in pcall: this
-- is the very last event mpv fires before exiting, other scripts are
-- already being torn down alongside it, and mpv's own APIs are less
-- reliable at this point (see snapshot_playlist) - any unexpected error
-- here should never surface as a visible stack trace on quit.
mp.register_event("shutdown", function()
    local ok, err = pcall(function()
        if finished_all then
            return
        end
        local items = last_items or snapshot_playlist()
        local pos = last_pos or 0
        save_saved_state(items, pos)
    end)
    if not ok then
        require("mp.msg").warn("shutdown handler failed: " .. tostring(err))
    end
end)

-- bin/mpv-add's own add-item handlers, so "add a video from outside mpv"
-- - this submodule's own core, advertised feature - keeps working when
-- plugins/playlist-manager isn't installed alongside it. mpv-add sends
-- to both playlist_manager and perpetual_playlist as script-message-to
-- targets; whichever is actually loaded handles it, and if both are,
-- each one's own "already in playlist" check below prevents a double
-- add - no "is X installed" detection needed on either side.
--
-- Deliberately simpler than playlist_manager.lua's own handlers: no
-- yt-dlp playlist-URL expansion (a whole playlist added as one URL
-- auto-expanding into individual videos) - that stays a
-- playlist-manager-only enhancement. Does include the two correctness
-- fixes made to playlist_manager.lua's own handlers the same session
-- these were written, since leaving them out here would mean a
-- perpetual-playlist-only install hits bugs already fixed for everyone
-- else - see the two functions below for exactly what's ported and why.

local function pp_is_in_playlist(item)
    for _, entry in ipairs(mp.get_property_native("playlist") or {}) do
        if entry.filename == item then
            return true
        end
    end
    return false
end

-- Mirrors playlist_manager.lua's next_insert_index/batch_id mechanism:
-- multiple items from the *same* mpv-add -n call land in the order
-- given (index keeps incrementing); a separate, later call - a
-- different batch_id, or none at all, which always counts as new -
-- resets and lands back at playlist-pos + 1, displacing whatever an
-- earlier call had already queued there instead of accumulating after
-- it. See that file's own comments (and the commit that added this) for
-- the full reasoning; ported as-is since it's a correctness fix, not an
-- enhancement.
local pp_next_insert_index = nil
local pp_last_next_batch_id = nil

local function pp_add_item(item, next_mode, batch_id)
    if not item or item == "" or pp_is_in_playlist(item) then
        return
    end

    -- Tried for local paths only, never URLs - confirmed (see
    -- plugins/playlist-manager's own history) that loadlist does NOT
    -- cleanly fail on a plain YouTube watch URL the way it does on a
    -- plain local file: it "succeeds" by pulling in YouTube's
    -- autoplay/"up next" mix as a giant playlist. Omitting this guard
    -- would reintroduce that exact runaway-growth bug here.
    local try_loadlist = not is_url(item)

    if next_mode then
        if not batch_id or batch_id == "" or batch_id ~= pp_last_next_batch_id then
            pp_next_insert_index = nil
            pp_last_next_batch_id = batch_id
        end

        local is_batch_start = pp_next_insert_index == nil
        if is_batch_start then
            local pos = mp.get_property_number("playlist-pos", -1)
            pp_next_insert_index = (pos >= 0) and (pos + 1) or 0
        end

        local flag = is_batch_start and "insert-at-play" or "insert-at"
        local index = tostring(pp_next_insert_index)
        if not (try_loadlist and mp.commandv("loadlist", item, flag, index)) then
            mp.commandv("loadfile", item, flag, index)
        end
        pp_next_insert_index = pp_next_insert_index + 1
    else
        if not (try_loadlist and mp.commandv("loadlist", item, "append-play")) then
            mp.commandv("loadfile", item, "append-play")
        end
    end

    mp.osd_message((next_mode and "Added next: " or "Added: ") .. item, opts.osd_duration)
end

mp.register_script_message("mpv-add-item", function(item)
    pp_add_item(item, false, nil)
end)

mp.register_script_message("mpv-add-item-next", function(item, batch_id)
    pp_add_item(item, true, batch_id)
end)
