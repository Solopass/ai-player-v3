-- Debug trail: what the mod actually did, and why.
--
-- Every event goes two places:
--   * script-output/ai-player/debug.jsonl — one JSON object per line, for the
--     bridge's `python -m bridge.diag` (and anyone tailing it). The bridge
--     rotates it when it gets big.
--   * storage.ai_player.events — the last RING_SIZE events, shown in the
--     in-game panel and returned by the `diag` remote call.
--
-- Event kinds: request, response, timeout, skill, action, error, place,
-- measure, bp_sync. Fields are kept small and flat.

AIDebug = {}

local LOG_FILE = "ai-player/debug.jsonl"
local RING_SIZE = 40

local function enabled()
  local s = settings.global["ai-player-debug-log"]
  return not s or s.value ~= false
end

-- First `n` bytes of `s`, never splitting a UTF-8 character (a split one
-- makes the request file invalid UTF-8 for the bridge).
function AIDebug.utf8_sub(s, n)
  if #s <= n then return s end
  local cut = n
  -- step back over continuation bytes (10xxxxxx) to the start of the char
  while cut > 0 and s:byte(cut + 1) and s:byte(cut + 1) >= 0x80 and s:byte(cut + 1) < 0xC0 do
    cut = cut - 1
  end
  return s:sub(1, cut)
end

-- Turn values into something table_to_json accepts (no LuaObjects, no
-- functions), truncating long strings. Never tostring() a table or object:
-- that embeds a memory address, which differs between multiplayer peers and
-- would desync storage.
local function clean(v, depth)
  local t = type(v)
  if t == "string" then return #v > 300 and (AIDebug.utf8_sub(v, 300) .. "…") or v end
  if t == "number" or t == "boolean" or v == nil then return v end
  if t == "userdata" or (t == "table" and v.object_name) then
    local ok, name = pcall(function() return v.object_name end)
    return "<" .. (ok and name or t) .. ">"
  end
  if t == "table" then
    if (depth or 0) >= 3 then return "<table>" end
    local out = {}
    for k, x in pairs(v) do
      if type(k) == "string" or type(k) == "number" then out[k] = clean(x, (depth or 0) + 1) end
    end
    return out
  end
  return "<" .. t .. ">"
end

function AIDebug.session_header(event_type, session_id, seed)
  AIDebug.event("session_start", {
    version = "0.5.0",
    seed = seed,
    session_id = session_id,
    event_type = event_type,
  })
end

function AIDebug.event(kind, fields)
  if not storage.ai_player then return end
  local e = clean(fields or {}) or {}
  e.kind = kind
  e.tick = game.tick
  e.session_id = storage.ai_player.session_id
  local ring = storage.ai_player.events or {}
  storage.ai_player.events = ring
  ring[#ring + 1] = e
  while #ring > RING_SIZE do table.remove(ring, 1) end
  if enabled() then
    local ok, line = pcall(helpers.table_to_json, e)
    -- No for_player, like the request files: written wherever the mod runs
    -- (also in single-player).
    if ok then helpers.write_file(LOG_FILE, line .. "\n", true, 0) end
  end
end

-- One-line text for the panel: "12:34 [skill] gather OK — gathered 50 coal".
function AIDebug.format(e)
  local secs = math.floor((e.tick or 0) / 60)
  local stamp = string.format("%d:%02d", math.floor(secs / 60) % 60, secs % 60)
  local what = e.name or e.skill or e.action or e.req_id or ""
  local status = (e.ok == true and "OK") or (e.ok == false and "FAILED") or ""
  local detail = e.detail or e.error or e.reason or ""
  return string.format("%s [%s] %s %s%s", stamp, e.kind or "?", what, status,
                       detail ~= "" and (" — " .. detail) or "")
end

-- Run fn with a Lua traceback on error. Returns ok, results... like pcall.
function AIDebug.xpcall(fn, ...)
  return xpcall(fn, function(err)
    local tb = debug and debug.traceback and debug.traceback(tostring(err), 2) or tostring(err)
    return tb
  end, ...)
end

return AIDebug
