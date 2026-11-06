-- In-game Spectator & Command Center for the AI Monitoring Station.
--
-- When a player enters an "ai-monitoring-station" vehicle (by pressing Enter),
-- this expanded HUD automatically opens, providing:
-- 1. A live CCTV spectator camera feed tracking the AI character.
-- 2. Real-time AI brain telemetry (directive, current skill, bridge status).
-- 3. 4-tier factory health audit (power, boiler fuel, flow faults, ghosts).
-- 4. Remote command console to issue directives or recall the agent.

StationGui = {}

local FRAME_NAME = "aip_station_frame"
local DEFAULT_ZOOM = 0.75

local function get_refs(player)
  storage.ai_player = storage.ai_player or {}
  storage.ai_player.station_gui = storage.ai_player.station_gui or {}
  storage.ai_player.station_gui[player.index] = storage.ai_player.station_gui[player.index] or {}
  return storage.ai_player.station_gui[player.index]
end

local function get_zoom(player)
  storage.ai_player = storage.ai_player or {}
  storage.ai_player.station_zoom = storage.ai_player.station_zoom or {}
  if not storage.ai_player.station_zoom[player.index] then
    storage.ai_player.station_zoom[player.index] = DEFAULT_ZOOM
  end
  return storage.ai_player.station_zoom[player.index]
end

local function set_zoom(player, zoom)
  zoom = math.max(0.2, math.min(2.5, zoom))
  storage.ai_player.station_zoom = storage.ai_player.station_zoom or {}
  storage.ai_player.station_zoom[player.index] = zoom
  local r = get_refs(player)
  if r.cam and r.cam.valid then
    r.cam.zoom = zoom
  end
  if r.zoom_label and r.zoom_label.valid then
    r.zoom_label.caption = string.format("%.2fx", zoom)
  end
end

function StationGui.is_open(player)
  return player.gui.screen[FRAME_NAME] ~= nil and player.gui.screen[FRAME_NAME].valid
end

function StationGui.close(player)
  if player.gui.screen[FRAME_NAME] then
    player.gui.screen[FRAME_NAME].destroy()
  end
  if storage.ai_player and storage.ai_player.station_gui then
    storage.ai_player.station_gui[player.index] = nil
  end
end

function StationGui.open(player, vehicle)
  if StationGui.is_open(player) then
    StationGui.update(player)
    return
  end

  local ap = storage.ai_player or {}
  local char = ap.character
  local target_pos = (char and char.valid) and char.position or (vehicle and vehicle.valid and vehicle.position or {x = 0, y = 0})
  local surface_index = (char and char.valid) and char.surface.index or (vehicle and vehicle.valid and vehicle.surface.index or 1)
  local zoom = get_zoom(player)

  local frame = player.gui.screen.add{
    type = "frame",
    name = FRAME_NAME,
    direction = "vertical"
  }
  frame.auto_center = true
  player.opened = frame

  local r = get_refs(player)
  r.frame = frame

  -- -----------------------------------------------------------------------
  -- Header Title Bar
  -- -----------------------------------------------------------------------
  local title_bar = frame.add{type = "flow", direction = "horizontal"}
  title_bar.drag_target = frame
  local title_label = title_bar.add{
    type = "label",
    caption = "[O] AI MONITORING STATION - SECURE COMMAND CENTER",
    style = "frame_title"
  }
  title_label.drag_target = frame

  local spacer = title_bar.add{type = "empty-widget", style = "draggable_space_header"}
  spacer.style.horizontally_stretchable = true
  spacer.style.height = 24
  spacer.drag_target = frame

  -- Zoom Controls in Header
  local zoom_out = title_bar.add{
    type = "button",
    name = "aip_station_zoom_out",
    caption = "-",
    style = "frame_action_button",
    tooltip = "Zoom out spectator camera"
  }
  r.zoom_label = title_bar.add{
    type = "label",
    caption = string.format("%.2fx", zoom),
    style = "bold_label"
  }
  r.zoom_label.style.left_margin = 4
  r.zoom_label.style.right_margin = 4

  local zoom_in = title_bar.add{
    type = "button",
    name = "aip_station_zoom_in",
    caption = "+",
    style = "frame_action_button",
    tooltip = "Zoom in spectator camera"
  }

  local exit_btn = title_bar.add{
    type = "button",
    name = "aip_station_exit",
    caption = "Exit Station [Enter]",
    style = "frame_action_button",
    tooltip = "Step out of the monitoring station"
  }
  exit_btn.style.left_margin = 12

  -- -----------------------------------------------------------------------
  -- Main Content Body: Two Columns (CCTV View + Telemetry/Triage)
  -- -----------------------------------------------------------------------
  local main_body = frame.add{type = "flow", direction = "horizontal"}
  main_body.style.top_margin = 6

  -- Left Column: CCTV Spectator Feed (width 400px)
  local left_col = main_body.add{type = "frame", style = "inside_deep_frame", direction = "vertical"}
  left_col.style.width = 410
  left_col.style.padding = 6

  local cctv_header = left_col.add{type = "flow", direction = "horizontal"}
  cctv_header.add{type = "label", caption = "LIVE CCTV FEED", style = "caption_label"}
  local cctv_spacer = cctv_header.add{type = "empty-widget"}
  cctv_spacer.style.horizontally_stretchable = true
  r.cam_badge = cctv_header.add{type = "label", caption = "ONLINE", style = "bold_label"}
  r.cam_badge.style.font_color = {r = 0.2, g = 1, b = 0.2}

  -- Camera widget
  r.cam = left_col.add{
    type = "camera",
    name = "aip_station_camera",
    position = target_pos,
    surface_index = surface_index,
    zoom = zoom
  }
  r.cam.style.width = 396
  r.cam.style.height = 300

  -- Target details beneath camera
  local target_flow = left_col.add{type = "flow", direction = "vertical"}
  target_flow.style.top_margin = 6
  r.target_info = target_flow.add{type = "label", caption = "Target: AI Character", style = "bold_label"}
  r.pos_info = target_flow.add{type = "label", caption = "Pos: -- | Surface: --"}
  r.dist_info = target_flow.add{type = "label", caption = "Distance from Station: --"}
  
  local health_flow = target_flow.add{type = "flow", direction = "horizontal"}
  health_flow.add{type = "label", caption = "AI Health: "}
  r.health_bar = health_flow.add{type = "progressbar", size = 150, value = 1.0}
  r.health_bar.style.color = {r = 0.2, g = 0.8, b = 0.2}
  r.health_text = health_flow.add{type = "label", caption = " 100%"}
  r.health_text.style.font_color = {r = 0.2, g = 0.8, b = 0.2}

  -- Right Column: Brain Telemetry & Factory Triage (width 450px)
  local right_col = main_body.add{type = "flow", direction = "vertical"}
  right_col.style.width = 460
  right_col.style.left_margin = 8

  -- Box 1: AI Brain Telemetry
  local b1 = right_col.add{type = "frame", style = "bordered_frame", direction = "vertical"}
  b1.style.horizontally_stretchable = true
  b1.style.padding = 6
  b1.add{type = "label", caption = "1. AI BRAIN TELEMETRY", style = "caption_label"}

  r.tel_status = b1.add{type = "label", caption = "Status: Initializing..."}
  r.tel_goal = b1.add{type = "label", caption = "Directive / Goal: None"}
  r.tel_goal.style.single_line = false
  r.tel_goal.style.maximal_width = 430
  r.tel_skill = b1.add{type = "label", caption = "Active Skill: None"}
  r.tel_step = b1.add{type = "label", caption = "Step: Idle"}

  -- Box 2: Factory Health Triage
  local b2 = right_col.add{type = "frame", style = "bordered_frame", direction = "vertical"}
  b2.style.horizontally_stretchable = true
  b2.style.top_margin = 6
  b2.style.padding = 6
  b2.add{type = "label", caption = "2. FACTORY HEALTH AUDIT (TRIAGE)", style = "caption_label"}

  r.triage_power = b2.add{type = "label", caption = "Power: Scanning..."}
  r.triage_boiler = b2.add{type = "label", caption = "Boiler Fuel: Checking..."}
  r.triage_flow = b2.add{type = "label", caption = "Flow Faults: 0 detected"}
  r.triage_ghosts = b2.add{type = "label", caption = "Ghost Backlog: 0 unbuilt"}

  -- Box 3: Remote Command Console
  local b3 = right_col.add{type = "frame", style = "bordered_frame", direction = "vertical"}
  b3.style.horizontally_stretchable = true
  b3.style.top_margin = 6
  b3.style.padding = 6
  b3.add{type = "label", caption = "3. REMOTE STATION DIRECTIVES", style = "caption_label"}

  local row1 = b3.add{type = "flow", direction = "horizontal"}
  local btn_power = row1.add{type = "button", name = "aip_station_cmd_power", caption = "Prioritize Power"}
  btn_power.tooltip = "Injects top priority directive to verify boilers, fuel line and power grid"
  btn_power.style.right_margin = 4

  local btn_flow = row1.add{type = "button", name = "aip_station_cmd_flow", caption = "Audit & Fix Flow"}
  btn_flow.tooltip = "Scans surrounding machines for reversed inserters and dead belts, then repairs them"
  btn_flow.style.right_margin = 4

  local btn_clear = row1.add{type = "button", name = "aip_station_cmd_clear", caption = "Clear Deadlocks"}
  btn_clear.tooltip = "Clears any stuck in-flight requests or blocked turn queue"

  local row2 = b3.add{type = "flow", direction = "horizontal"}
  row2.style.top_margin = 4

  local btn_recall = row2.add{type = "button", name = "aip_station_cmd_recall", caption = "Recall AI Here"}
  btn_recall.tooltip = "Directs the AI character to return to the monitoring station bunker"
  btn_recall.style.right_margin = 4

  r.btn_auto = row2.add{type = "button", name = "aip_station_cmd_autopilot", caption = "Pause Autopilot"}
  r.btn_auto.tooltip = "Pause or resume autonomous decision making"

  StationGui.update(player)
end

function StationGui.update(player)
  local r = get_refs(player)
  if not (r.frame and r.frame.valid) then return end

  local ap = storage.ai_player or {}
  local char = ap.character
  local vehicle = player.vehicle

  -- 1. Camera & Tracking Position
  if char and char.valid then
    r.cam.position = char.position
    r.cam.surface_index = char.surface.index
    r.cam_badge.caption = "ONLINE (TRACKING AI)"
    r.cam_badge.style.font_color = {r = 0.2, g = 1, b = 0.2}
    r.target_info.caption = "Target: AI Character"

    local hp = math.max(0, math.floor(char.health))
    local max_hp = math.max(1, math.floor(char.max_health or 250))
    local pct = hp / max_hp
    r.pos_info.caption = string.format("Pos: (%.1f, %.1f) | Surface: %s", char.position.x, char.position.y, char.surface.name)
    r.health_bar.value = pct
    r.health_text.caption = string.format(" %d%% (%d/%d)", math.floor(pct * 100), hp, max_hp)

    if vehicle and vehicle.valid then
      local dx = char.position.x - vehicle.position.x
      local dy = char.position.y - vehicle.position.y
      local dist = math.sqrt(dx * dx + dy * dy)
      r.dist_info.caption = string.format("Distance from Station: %.1f tiles", dist)
    else
      r.dist_info.caption = "Distance from Station: --"
    end
  else
    if vehicle and vehicle.valid then
      r.cam.position = vehicle.position
      r.cam.surface_index = vehicle.surface.index
    end
    r.cam_badge.caption = "AI CHARACTER OFFLINE"
    r.cam_badge.style.font_color = {r = 1, g = 0.4, b = 0.2}
    r.target_info.caption = "Target: Station Area (AI not spawned)"
    r.pos_info.caption = "Pos: -- | Surface: --"
    r.dist_info.caption = "Distance from Station: 0.0 tiles"
    r.health_bar.value = 0
    r.health_text.caption = " 0%"
  end

  -- 2. Brain Telemetry
  local mem = ap.memory or {}
  local directive = mem.user_directive or mem.previous_summary or "Running autonomous factory loops"
  r.tel_goal.caption = "Directive / Goal: " .. directive

  local turn = ap.turn or ap.held_turn
  if turn then
    local cur_entry = turn.entries and turn.entries[turn.index or 1]
    local act_name = (cur_entry and cur_entry.action) or (cur_entry and cur_entry.skill) or "Executing turn"
    r.tel_skill.caption = string.format("Active Skill: %s", act_name)
    r.tel_step.caption = string.format("Step: [%d / %d] in plan", turn.index or 1, #(turn.entries or {}))
  else
    r.tel_skill.caption = "Active Skill: Idle / Waiting for next cycle"
    r.tel_step.caption = "Step: Ready"
  end

  local auto_on = (ap.autonomy_enabled ~= false)
  r.tel_status.caption = string.format("Status: %s (Autonomy: %s)",
    (char and char.valid and "OPERATIONAL" or "STANDBY"),
    (auto_on and "ON" or "PAUSED"))
  if r.btn_auto and r.btn_auto.valid then
    r.btn_auto.caption = auto_on and "Pause Autopilot" or "Resume Autopilot"
  end

  -- 3. Factory Health Triage
  local surf = (char and char.valid) and char.surface or (vehicle and vehicle.valid and vehicle.surface or game.surfaces["nauvis"])
  local force = (char and char.valid) and char.force or player.force

  -- Power & Boiler check
  -- the AI's own power only: a whole-surface scan per viewer every refresh lags big maps
  local boilers = AIRegistry.owned(surf, {"boiler"})
  local engines = AIRegistry.owned(surf, {"generator"})
  local poles = AIRegistry.owned(surf, {"electric-pole"})

  local has_boiler = #boilers > 0
  local has_engine = #engines > 0
  local boiler_fuel_fed = false
  if has_boiler then
    for _, b in ipairs(boilers) do
      local inv = b.get_inventory(defines.inventory.fuel)
      if inv and inv.get_item_count("coal") > 0 then
        boiler_fuel_fed = true
        break
      end
    end
  end

  if has_engine and #poles > 0 then
    local pole = poles[1]
    local pnet = pole.electric_network_statistics
    if pnet then
      r.triage_power.caption = string.format("Power: Grid Active (%d engines, %d boilers)", #engines, #boilers)
    else
      r.triage_power.caption = string.format("Power: Grid Active (%d steam engines)", #engines)
    end
  elseif has_boiler and not has_engine then
    r.triage_power.caption = "Power: Warning - Boilers placed without Steam Engines!"
  elseif not has_boiler then
    r.triage_power.caption = "Power: No Steam Grid detected"
  else
    r.triage_power.caption = "Power: Operational"
  end

  if has_boiler then
    r.triage_boiler.caption = string.format("Boilers: %d online | Fuel Fed: %s", #boilers, boiler_fuel_fed and "YES (Coal present)" or "NO (Fuel starved!)")
  else
    r.triage_boiler.caption = "Boilers: None constructed"
  end

  -- Flow faults
  local faults_count = 0
  if ap.flow_faults and type(ap.flow_faults) == "table" then
    faults_count = #ap.flow_faults
  end
  r.triage_flow.caption = string.format("Flow Faults: %d detected (inserters / belts)", faults_count)

  -- Ghost backlog
  local n_ghosts = 0
  for _ in pairs(ap.ai_ghosts or {}) do n_ghosts = n_ghosts + 1 end
  r.triage_ghosts.caption = string.format("Ghost Backlog: %d pending placement", n_ghosts)
end

function StationGui.on_gui_click(event)
  local el = event.element
  if not (el and el.valid and storage.ai_player) then return end
  local player = game.get_player(event.player_index)
  if not (player and player.valid) then return end

  local name = el.name

  if name == "aip_station_zoom_in" then
    set_zoom(player, get_zoom(player) + 0.25)
  elseif name == "aip_station_zoom_out" then
    set_zoom(player, get_zoom(player) - 0.25)
  elseif name == "aip_station_exit" then
    player.driving = false
    StationGui.close(player)
  elseif name == "aip_station_cmd_power" then
    storage.ai_player.memory = storage.ai_player.memory or {}
    storage.ai_player.memory.user_directive = "Prioritize power expansion, boiler fuel line, and electrical connections"
    player.print("[Station] Directive sent: Prioritize power & boiler fuel logistics", {r = 0.4, g = 1, b = 0.4})
    StationGui.update(player)
  elseif name == "aip_station_cmd_flow" then
    local char = storage.ai_player.character
    if char and char.valid and AISkills and AISkills.run then
      local ok, msg = AISkills.run(char, {skill = "fix_flow"})
      player.print("[Station] Flow audit triggered: " .. tostring(msg or "scanning..."), {r = 0.4, g = 1, b = 0.4})
    else
      player.print("[Station] AI character unavailable to execute flow audit", {r = 1, g = 0.5, b = 0.2})
    end
    StationGui.update(player)
  elseif name == "aip_station_cmd_clear" then
    local n = 0
    for _ in pairs(storage.ai_player.pending_requests or {}) do n = n + 1 end
    storage.ai_player.pending_requests = {}
    storage.ai_player.turn = nil
    storage.ai_player.held_turn = nil
    player.print(string.format("[Station] Cleared %d pending request(s) and reset active plan", n), {r = 0.4, g = 1, b = 0.4})
    StationGui.update(player)
  elseif name == "aip_station_cmd_recall" then
    local char = storage.ai_player.character
    local veh = player.vehicle
    if char and char.valid and veh and veh.valid then
      storage.ai_player.turn = nil
      AISkills.queue_turn(char, {{action = "walk_to", position = veh.position}})
      player.print(string.format("[Station] Recalling AI character to station at {%.1f, %.1f}", veh.position.x, veh.position.y), {r = 0.4, g = 1, b = 0.4})
    else
      player.print("[Station] Cannot recall: station or AI character is invalid", {r = 1, g = 0.5, b = 0.2})
    end
    StationGui.update(player)
  elseif name == "aip_station_cmd_autopilot" then
    local curr = (storage.ai_player.autonomy_enabled ~= false)
    storage.ai_player.autonomy_enabled = not curr
    player.print(string.format("[Station] AI Autopilot is now %s", not curr and "ACTIVE" or "PAUSED"), {r = 0.4, g = 1, b = 0.4})
    StationGui.update(player)
  end
end

return StationGui
