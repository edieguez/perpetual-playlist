-- A small fake mpv, just enough to load scripts/perpetual_playlist.lua
-- outside the player and call the pure state functions it returns.
-- Each harness gets its own temp HOME so state files never collide.

local json = require("support.json")

local M = {}
local created = {}

local function shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function M.cleanup_all()
    for _, h in ipairs(created) do os.execute("rm -rf " .. shell_quote(h.home)) end
    created = {}
end

function M.new()
    local home = os.tmpname()
    os.remove(home)
    os.execute("mkdir -p " .. shell_quote(home))

    local h = { home = home, props = {}, commands = {}, timers = {}, events = {} }
    table.insert(created, h)

    local mp = {}
    function mp.get_property(name, def) local v = h.props[name]; return v == nil and def or tostring(v) end
    function mp.get_property_native(name, def) local v = h.props[name]; return v == nil and def or v end
    function mp.get_property_number(name, def) return tonumber(h.props[name]) or def end
    function mp.get_property_bool(name, def) local v = h.props[name]; return v == nil and def or v end
    function mp.set_property_number(name, v) h.props[name] = v end
    function mp.command(c) table.insert(h.commands, { c }) end
    function mp.commandv(...) table.insert(h.commands, { ... }) end
    function mp.command_native(t)
        if t[1] == "expand-path" then return (t[2]:gsub("^~/", home .. "/")) end
        if t.name == "subprocess" and t.args[1] == "mkdir" then
            os.execute("mkdir -p " .. shell_quote(t.args[3]))
            return { status = 0 }
        end
        return nil
    end
    function mp.add_timeout(s, fn) table.insert(h.timers, fn) end
    function mp.register_event(name, fn) h.events[name] = fn end
    function mp.add_hook() end
    function mp.observe_property() end
    function mp.osd_message() end
    mp.msg = { warn = function() end }

    package.preload["mp.utils"] = function()
        return {
            parse_json = function(s)
                local v, e = json.decode(s)
                if v == nil then error(e) end
                return v
            end,
            format_json = json.encode,
            split_path = function(p)
                local dir, file = p:match("^(.*/)([^/]*)$")
                return dir or ".", file or p
            end,
        }
    end
    package.preload["mp.options"] = function() return { read_options = function() end } end
    package.preload["mp.msg"] = function() return mp.msg end

    -- Loads the script and returns the table of functions it exposes.
    function h:load()
        for name in pairs(package.loaded) do
            if name:match("^mp%.") then package.loaded[name] = nil end
        end
        -- Left set after loading: the script reads the global `mp` at
        -- call time, not just while loading.
        rawset(_G, "mp", mp)
        local chunk, err = loadfile("scripts/perpetual_playlist.lua")
        assert(chunk, err)
        local ok, result = pcall(chunk)
        if not ok then error(result, 0) end
        return result
    end

    function h:state_file() return home .. "/.local/state/mpv/last_playlist.json" end
    function h:write_state(s)
        os.execute("mkdir -p " .. shell_quote(home .. "/.local/state/mpv"))
        local f = assert(io.open(self:state_file(), "w"))
        f:write(s)
        f:close()
    end
    function h:read_state()
        local f = io.open(self:state_file(), "r")
        if not f then return nil end
        local s = f:read("*a")
        f:close()
        return s
    end
    function h:file_exists(path)
        local f = io.open(path, "r")
        if f then f:close() end
        return f ~= nil
    end

    return h
end

return M
