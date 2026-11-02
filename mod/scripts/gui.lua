-- In-game control panel for the AI player.
--
-- Open with the "AI" button at the top-left or Ctrl+Shift+A. Shows what the
-- AI is doing (character, brain state, the bridge's current goal, last
-- results, recent debug events) and has buttons for everything the console
-- commands do. State-changing buttons are admin-only, like the commands.
--
-- control.lua hands over the shared action functions with AIGui.set_actions
-- so buttons and commands run the exact same code.

AIGui = {}

local PANEL = "aip_panel"
local TOGGLE = "aip_toggle"
local WIDTH = 460
local actions = {}

function AIGui.set_actions(t) actions = t end

function AIGui.reset_all()
  for _, p in pairs(game.players) do
    if p.gui.screen[PANEL] then p.gui.screen[PANEL].destroy() end
  end
  if storage.ai_player then storage.ai_player.gui = {} end
end

-- -------------------------------------------------------------------------
-- Helpers
-- -------------------------------------------------------------------------

local function pin_sprite(pinned)
  local candidate = pinned and "utility/track_button_white" or "utility/track_button"
  if helpers and helpers.is_valid_sprite_path and helpers.is_valid_sprite_path(candidate) then
    return candidate
  end
  if helpers and helpers.is_valid_sprite_path and helpers.is_valid_sprite_path("utility/track_button") then
    return "utility/track_button"
  end
  if helpers and helpers.is_valid_sprite_path and helpers.is_valid_sprite_path("utility/bookmark") then
    return "utility/bookmark"
  end
  return nil
end

local function refs(player)
  storage.ai_player.gui = storage.ai_player.gui or {}
  storage.ai_player.gui[player.index] = storage.ai_player.gui[player.index] or {}
  return storage.ai_player.gui[player.index]
end

local function label(parent, name, caption, wrap)
  local l = parent.add{type = "label", name = name, caption = caption or ""}
  if wrap then l.style.single_line = false; l.style.maximal_width = WIDTH - 24 end
  return l
end

local function heading(parent, text)
  local l = parent.add{type = "label", caption = text, style = "caption_label"}
  l.style.top_margin = 6
end

local function sorted_keys(t)
  local out = {}
  for k in pairs(t or {}) do out[#out + 1] = k end
  table.sort(out)
  return out
end

local function say(player, msg, good)
  player.print("[AI panel] " .. msg, good == false and {r = 1, g = 0.6, b = 0.3} or {r = 0.6, g = 1, b = 0.6})
end

local function is_admin(player)
  if player.admin then return true end
  say(player, "that button is admin-only", false)
  return false
end

-- -------------------------------------------------------------------------
-- Toggle button
-- -------------------------------------------------------------------------

function AIGui.ensure_button(player)
  if player.gui.top[TOGGLE] then return end
  local ok = pcall(function()
    player.gui.top.add{type = "sprite-button", name = TOGGLE, sprite = "virtual-signal/signal-A",
                       tooltip = "AI Player panel (Ctrl+Shift+A)"}
  end)
  if not ok then
    player.gui.top.add{type = "button", name = TOGGLE, caption = "AI", tooltip = "AI Player panel (Ctrl+Shift+A)"}
  end
end

-- -------------------------------------------------------------------------
-- Panel
-- -------------------------------------------------------------------------

local DEFAULT_LOCATION = {x = 15, y = 80}

local function build(player)
  local frame = player.gui.screen.add{type = "frame", name = PANEL, direction = "vertical"}
  local saved_loc = storage.ai_player and storage.ai_player.gui_location and storage.ai_player.gui_location[player.index]
  frame.auto_center = false
  frame.location = saved_loc or DEFAULT_LOCATION
  local r = refs(player)

  local bar = frame.add{type = "flow", direction = "horizontal"}
  bar.drag_target = frame
  bar.add{type = "label", caption = "AI Player", style = "frame_title"}.drag_target = frame
  local drag = bar.add{type = "empty-widget", style = "draggable_space_header"}
  drag.style.horizontally_stretchable = true
  drag.style.height = 24
  drag.drag_target = frame

  storage.ai_player.gui_pinned = storage.ai_player.gui_pinned or {}
  if storage.ai_player.gui_pinned[player.index] == nil then
    storage.ai_player.gui_pinned[player.index] = true
  end
  local pinned = storage.ai_player.gui_pinned[player.index]
  if not pinned then
    player.opened = frame
  else
    if player.opened == frame then player.opened = nil end
  end
  local ps = pin_sprite(pinned)
  if ps then
    bar.add{
      type = "sprite-button",
      name = "aip_pin",
      sprite = ps,
      style = "frame_action_button",
      tooltip = pinned and "Pinned: window stays in place and won't auto-close. Click to unpin." or "Pin: click to keep window open and locked where you drag it."
    }
  else
    bar.add{
      type = "button",
      name = "aip_pin",
      caption = pinned and "[Pin]" or "Pin",
      style = "frame_action_button",
      tooltip = pinned and "Pinned: window stays in place and won't auto-close. Click to unpin." or "Pin: click to keep window open and locked where you drag it."
    }
  end

  local close_sprite = "utility/close"
  if helpers and helpers.is_valid_sprite_path and not helpers.is_valid_sprite_path(close_sprite) then
    close_sprite = nil
  end
  if close_sprite then
    bar.add{type = "sprite-button", name = "aip_close", sprite = close_sprite, style = "frame_action_button"}
  else
    bar.add{type = "button", name = "aip_close", caption = "X", style = "frame_action_button"}
  end

  local body = frame.add{type = "frame", direction = "vertical", style = "inside_shallow_frame_with_padding"}
  body.style.width = WIDTH

  heading(body, "Status")
  r.char = label(body, nil, "", true)
  r.brain = label(body, nil, "", true)
  r.reflex = label(body, nil, "", true)
  r.goal = label(body, nil, "", true)
  r.rates = label(body, nil, "", true)
  r.model = label(body, nil, "", true)
  r.summary = label(body, nil, "", true)
  r.directive = label(body, nil, "", true)

  heading(body, "Last actions")
  r.results = body.add{type = "flow", direction = "vertical"}

  heading(body, "Controls")
  local row = body.add{type = "flow", direction = "horizontal"}
  row.add{type = "button", name = "aip_spawn", caption = "Spawn", tooltip = "Spawn or reset the AI next to you"}
  row.add{type = "button", name = "aip_come", caption = "Come here"}
  r.pause = row.add{type = "button", name = "aip_pause", caption = "Pause",
                    tooltip = "Stop/start the AI deciding on its own (chat orders still work)"}
  r.coop = row.add{type = "button", name = "aip_coop", caption = "Co-op",
                   tooltip = "Share your force and base (on) or play solo (off)"}
  row.add{type = "button", name = "aip_clear", caption = "Unstick",
          tooltip = "Drop in-flight requests if it seems stuck waiting"}
  r.mode = row.add{type = "button", name = "aip_mode", caption = "Defend",
                   tooltip = "Combat mode: defend (only fight what attacks) or hunt (also clear nests near home)"}

  heading(body, "Tell the AI")
  local talk = body.add{type = "flow", direction = "horizontal"}
  r.talk = talk.add{type = "textfield", name = "aip_talk", tooltip = "Same as typing ai: … in chat. Enter sends."}
  r.talk.style.horizontally_stretchable = true
  r.talk.style.maximal_width = WIDTH - 90
  talk.add{type = "button", name = "aip_send", caption = "Send"}

  heading(body, "Blueprints")
  local bp = body.add{type = "flow", direction = "horizontal"}
  r.bp_list = bp.add{type = "drop-down", name = "aip_bp_list"}
  r.bp_list.style.width = 170
  bp.add{type = "button", name = "aip_bp_place", caption = "Place", tooltip = "AI picks a spot and places ghosts"}
  bp.add{type = "button", name = "aip_bp_tile", caption = "Tile +1", tooltip = "Snaps another slice of this modular blueprint adjacent to existing ones"}
  bp.add{type = "button", name = "aip_bp_test", caption = "Preview", tooltip = "Ghosts right next to you, to check it"}
  local bp2 = body.add{type = "flow", direction = "horizontal"}
  bp2.add{type = "button", name = "aip_bp_add", caption = "Add held blueprint",
          tooltip = "Hold a blueprint or book first; the bridge imports it"}
  r.bp_info = label(bp2, nil, "")

  heading(body, "Run a skill (no AI)")
  local sk = body.add{type = "flow", direction = "horizontal"}
  r.skill_list = sk.add{type = "drop-down", name = "aip_skill"}
  r.skill_list.style.width = 150
  r.skill_arg = sk.add{type = "textfield", name = "aip_skill_arg",
                       tooltip = "e.g. iron-ore 50 · for place_blueprint: <name>"}
  r.skill_arg.style.width = 160
  sk.add{type = "button", name = "aip_run", caption = "Run"}

  heading(body, "Recent events")
  r.events = body.add{type = "flow", direction = "vertical"}

  local foot = body.add{type = "flow", direction = "horizontal"}
  foot.style.top_margin = 6
  foot.add{type = "button", name = "aip_refresh", caption = "Refresh lists"}
  r.debug_hint = label(foot, nil, "Full log: script-output/ai-player/debug.jsonl")
  r.debug_hint.style.font_color = {r = 0.6, g = 0.6, b = 0.6}

  r.frame = frame
  AIGui.refresh_lists(player)
  AIGui.update(player)
end

function AIGui.refresh_lists(player)
  local r = refs(player)
  if not (r.frame and r.frame.valid) then return end
  local names = {}
  for _, e in ipairs(AIBlueprints.list()) do names[#names + 1] = e.name end
  local sel = r.bp_list.selected_index > 0 and r.bp_list.get_item(r.bp_list.selected_index)
  r.bp_list.items = names
  for i, n in ipairs(names) do if n == sel then r.bp_list.selected_index = i end end
  if r.bp_list.selected_index == 0 and #names > 0 then r.bp_list.selected_index = 1 end
  r.bp_info.caption = #names .. " in library"

  local skills = sorted_keys(AISkills.REGISTRY)
  local ssel = r.skill_list.selected_index > 0 and r.skill_list.get_item(r.skill_list.selected_index)
  r.skill_list.items = skills
  for i, n in ipairs(skills) do if n == ssel then r.skill_list.selected_index = i end end
  if r.skill_list.selected_index == 0 then r.skill_list.selected_index = 1 end
end

local function fill_lines(flow, lines)
  flow.clear()
  for _, l in ipairs(lines) do
    local e = flow.add{type = "label", caption = l.text}
    e.style.single_line = false
    e.style.maximal_width = WIDTH - 24
    if l.color then e.style.font_color = l.color end
  end
end

function AIGui.update(player)
  local r = refs(player)
  if not (r.frame and r.frame.valid) then return end
  local ap = storage.ai_player

  local c = ap.character
  if c and c.valid then
    r.char.caption = string.format("Character: on %s at {%d, %d}, health %d%%", c.surface.name,
      math.floor(c.position.x), math.floor(c.position.y),
      math.floor(100 * c.health / (c.max_health or 250)))
  elseif ap.respawn_tick then
    r.char.caption = string.format("Character: dead — respawning in %ds", math.max(0, math.floor((ap.respawn_tick - game.tick) / 60)))
  else
    r.char.caption = "Character: not spawned — press Spawn"
  end

  local oldest
  for _, req in pairs(ap.pending_requests or {}) do
    local age = (game.tick - req.timestamp) / 60
    if not oldest or age > oldest then oldest = age end
  end
  local interval = settings.global["ai-player-tick-interval"].value
  if ap.autonomy_enabled == false then
    r.brain.caption = "Brain: paused (press Pause again to resume; chat orders still work)"
  elseif oldest then
    r.brain.caption = string.format("Brain: thinking… waiting %ds for the bridge", math.floor(oldest))
  else
    local left = math.max(0, interval - (ap.tick_counter or 0))
    r.brain.caption = string.format("Brain: idle — next decision in %ds", math.ceil(left / 60))
  end
  r.pause.caption = ap.autonomy_enabled == false and "Resume" or "Pause"
  local rf = AIReflexes.status()
  r.mode.caption = rf.mode == "hunt" and "Hunt" or "Defend"
  if rf.bridge_offline then
    r.reflex.caption = "Bridge offline: reflexes only (" .. rf.state .. ")"
    r.reflex.style.font_color = {r = 1, g = 0.6, b = 0.3}
  else
    r.reflex.caption = string.format("Reflexes: %s%s · mode %s", rf.state,
      rf.target and (" — " .. rf.target) or "", rf.mode)
    r.reflex.style.font_color = {r = 1, g = 1, b = 1}
  end
  r.coop.caption = ap.force_name == "player" and "Co-op: on" or "Co-op: off"

  local st = ap.bridge_status
  if st then
    local age = math.floor((game.tick - (st.tick or 0)) / 60)
    r.goal.caption = "Goal: " .. tostring(st.goal or "?")
    r.model.caption = string.format("Bridge: %s, last turn %.1fs (%ds ago)%s", tostring(st.model or "?"),
      tonumber(st.seconds) or 0, age, age > 120 and " — is the bridge still running?" or "")
    r.model.style.font_color = age > 120 and {r = 1, g = 0.6, b = 0.3} or {r = 1, g = 1, b = 1}
  else
    r.goal.caption = "Goal: (no word from the bridge yet — is it running?)"
    r.model.caption = ""
  end
  if c and c.valid and r.rates then
    local stats = c.force.get_item_production_statistics(c.surface)
    if stats then
      local function rate(item)
        local flow = stats.get_flow_count{name = item, count = true, category = "input",
                                          precision_index = defines.flow_precision_index.one_minute}
        return math.floor(flow + 0.5)
      end
      r.rates.caption = string.format("Rates (/min): Fe %d | Cu %d | Coal %d | 🔴 %d | 🟢 %d | Steel %d",
        rate("iron-plate"), rate("copper-plate"), rate("coal"),
        rate("automation-science-pack"), rate("logistic-science-pack"), rate("steel-plate"))
    end
  end
  local mem = ap.memory or {}
  r.summary.caption = mem.previous_summary and ("Last turn: " .. mem.previous_summary) or ""
  r.directive.caption = mem.user_directive and ("Your order: " .. mem.user_directive) or ""

  local lines = {}
  for _, res in ipairs(mem.last_action_results or {}) do
    lines[#lines + 1] = {
      text = (res.ok and "✔ " or "✘ ") .. (res.action or "?") .. ": " .. tostring(res.detail or ""),
      color = res.ok and {r = 0.6, g = 1, b = 0.6} or {r = 1, g = 0.55, b = 0.4},
    }
  end
  if #lines == 0 then lines[1] = {text = "(none yet)", color = {r = 0.6, g = 0.6, b = 0.6}} end
  fill_lines(r.results, lines)

  local ev = {}
  local ring = ap.events or {}
  for i = #ring, math.max(1, #ring - 5), -1 do
    local e = ring[i]
    ev[#ev + 1] = {text = AIDebug.format(e),
                   color = (e.kind == "error" or e.ok == false) and {r = 1, g = 0.55, b = 0.4}
                           or {r = 0.75, g = 0.75, b = 0.75}}
  end
  if #ev == 0 then ev[1] = {text = "(none yet)", color = {r = 0.6, g = 0.6, b = 0.6}} end
  fill_lines(r.events, ev)
end

function AIGui.toggle(player)
  local f = player.gui.screen[PANEL]
  if f then
    if f.valid and storage.ai_player then
      storage.ai_player.gui_location = storage.ai_player.gui_location or {}
      storage.ai_player.gui_location[player.index] = f.location
    end
    f.destroy()
    refs(player).frame = nil
  else
    local ok, err = AIDebug.xpcall(build, player)
    if not ok then
      -- Never leave a half-built window behind.
      if player.gui.screen[PANEL] then player.gui.screen[PANEL].destroy() end
      refs(player).frame = nil
      AIDebug.event("error", {name = "gui", error = err})
      say(player, "panel failed to open: " .. tostring(err):match("^[^\n]*"), false)
    end
  end
end

-- -------------------------------------------------------------------------
-- Clicks
-- -------------------------------------------------------------------------

local function need_character(player)
  local c = AICharacter.get_character()
  if not c then say(player, "no AI character — press Spawn first", false) end
  return c
end

local function selected(dd)
  return dd.selected_index > 0 and dd.get_item(dd.selected_index) or nil
end

local function send_talk(player)
  local r = refs(player)
  local text = (r.talk.text or ""):match("^%s*(.-)%s*$")
  if text == "" then return end
  r.talk.text = ""
  actions.give_directive(text)
end

local HANDLERS = {
  aip_close = function(player) AIGui.toggle(player) end,
  aip_refresh = function(player) AIGui.refresh_lists(player) end,
  aip_spawn = function(player)
    if not is_admin(player) then return end
    if AICharacter.spawn_ai_player(player.physical_surface) then say(player, "AI spawned") end
  end,
  aip_come = function(player) actions.bring_ai_to(player) end,
  aip_pause = function(player)
    if not is_admin(player) then return end
    storage.ai_player.autonomy_enabled = (storage.ai_player.autonomy_enabled == false)
    say(player, storage.ai_player.autonomy_enabled and "AI resumed" or "AI paused")
  end,
  aip_coop = function(player)
    if not is_admin(player) then return end
    local r = AICharacter.set_coop(storage.ai_player.force_name ~= "player")
    say(player, r.coop and "co-op on: the AI shares your base" or "co-op off: the AI plays solo")
  end,
  aip_mode = function(player)
    if not is_admin(player) then return end
    AIReflexes.set_mode(AIReflexes.mode() == "hunt" and "defend" or "hunt")
  end,
  aip_clear = function(player)
    if not is_admin(player) then return end
    local n = 0
    for _ in pairs(storage.ai_player.pending_requests) do n = n + 1 end
    storage.ai_player.pending_requests = {}
    say(player, "cleared " .. n .. " pending request(s)")
  end,
  aip_send = function(player) send_talk(player) end,
  aip_pin = function(player)
    storage.ai_player.gui_pinned = storage.ai_player.gui_pinned or {}
    local p = not storage.ai_player.gui_pinned[player.index]
    storage.ai_player.gui_pinned[player.index] = p
    local f = player.gui.screen[PANEL]
    if f and f.valid then
      storage.ai_player.gui_location = storage.ai_player.gui_location or {}
      storage.ai_player.gui_location[player.index] = f.location
      if p then
        if player.opened == f then player.opened = nil end
      else
        player.opened = f
      end
      local bar = f.children[1]
      local btn = bar and bar.aip_pin
      if btn and btn.valid then
        local ps = pin_sprite(p)
        pcall(function()
          if ps and btn.type == "sprite-button" then
            btn.sprite = ps
          elseif btn.type == "button" then
            btn.caption = p and "[Pin]" or "Pin"
          end
        end)
        btn.tooltip = p and "Pinned: window stays in place and won't auto-close. Click to unpin." or "Pin: click to keep window open and locked where you drag it."
      end
    end
  end,
  aip_bp_tile = function(player)
    if not is_admin(player) then return end
    local c = need_character(player); if not c then return end
    local name = selected(refs(player).bp_list)
    if not name then return say(player, "library is empty", false) end
    local last_pos = nil
    for _, b in ipairs(storage.ai_player.placed_blueprints or {}) do
      if b.name == name and b.surface == c.surface.name then
        last_pos = b.position
      end
    end
    local bp_entry = (storage.ai_player.blueprints or {})[name]
    local meta = bp_entry and bp_entry.meta or {}
    local offset = meta.tile_offset or meta.snap_grid
    local pos = nil
    if last_pos and offset then
      pos = {x = last_pos.x + (offset.x or 0), y = last_pos.y + (offset.y or 0)}
    end
    local ok, res = AIBlueprints.place(c, name, {position = pos})
    say(player, res, ok)
  end,
  aip_bp_place = function(player)
    if not is_admin(player) then return end
    local c = need_character(player); if not c then return end
    local name = selected(refs(player).bp_list)
    if not name then return say(player, "library is empty", false) end
    actions.run_skill_text(c, "place_blueprint", name)
  end,
  aip_bp_test = function(player)
    if not is_admin(player) then return end
    local name = selected(refs(player).bp_list)
    if not name then return say(player, "library is empty", false) end
    local ok, msg = AIBlueprints.test_place(player, name)
    say(player, msg, ok)
  end,
  aip_bp_add = function(player)
    if not is_admin(player) then return end
    local ok, res = AIBlueprints.export_held(player, nil, nil)
    if ok then say(player, "exported '" .. res .. "' — it appears in the list after the bridge syncs (~10s), then Refresh lists")
    else say(player, res, false) end
  end,
  aip_run = function(player)
    if not is_admin(player) then return end
    local c = need_character(player); if not c then return end
    local r = refs(player)
    local skill = selected(r.skill_list)
    if skill then actions.run_skill_text(c, skill, r.skill_arg.text) end
  end,
}

script.on_event(defines.events.on_gui_click, function(event)
  local el = event.element
  if not (el and el.valid and storage.ai_player) then return end
  local player = game.get_player(event.player_index)
  if el.name == TOGGLE then return AIGui.toggle(player) end
  local h = HANDLERS[el.name]
  if h then
    h(player)
    AIGui.update(player)
  end
end)

script.on_event(defines.events.on_gui_confirmed, function(event)
  if event.element and event.element.valid and event.element.name == "aip_talk" and storage.ai_player then
    send_talk(game.get_player(event.player_index))
  end
end)

script.on_event("ai-player-toggle-panel", function(event)
  if storage.ai_player then AIGui.toggle(game.get_player(event.player_index)) end
end)

script.on_event(defines.events.on_player_created, function(event)
  AIGui.ensure_button(game.get_player(event.player_index))
end)

script.on_event(defines.events.on_gui_location_changed, function(event)
  local el = event.element
  if el and el.valid and el.name == PANEL and storage.ai_player then
    storage.ai_player.gui_location = storage.ai_player.gui_location or {}
    storage.ai_player.gui_location[event.player_index] = el.location
  end
end)

script.on_event(defines.events.on_gui_closed, function(event)
  local el = event.element
  if el and el.valid and el.name == PANEL and storage.ai_player then
    local pinned = storage.ai_player.gui_pinned and storage.ai_player.gui_pinned[event.player_index]
    if pinned ~= false then
      -- Default to pinned: stays open when pressing E / ESC, keeping position on left
      return
    end
    storage.ai_player.gui_location = storage.ai_player.gui_location or {}
    storage.ai_player.gui_location[event.player_index] = el.location
    el.destroy()
    local player = game.get_player(event.player_index)
    if player then refs(player).frame = nil end
  end
end)

script.on_nth_tick(60, function()
  if not storage.ai_player then return end
  for _, player in pairs(game.connected_players) do
    if player.gui.screen[PANEL] then AIGui.update(player) end
  end
end)

return AIGui
