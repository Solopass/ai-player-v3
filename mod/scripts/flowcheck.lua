-- Flow validation and auto-repair (AIFlow)
-- Checks inserters, belt lines, and crafters for operational flow.
-- Can rotate backwards inserters, turn dead-end belts, or deconstruct broken builds.

AIFlow = {}

local MAX_BELT_STEPS = 200
local MAX_REPAIR_ENTITIES = 10

local function target_at(surface, pos)
  local area = {{pos.x - 0.4, pos.y - 0.4}, {pos.x + 0.4, pos.y + 0.4}}
  local found = surface.find_entities_filtered{
    area = area,
    type = {"transport-belt", "underground-belt", "splitter", "container", "logistic-container", "assembling-machine", "furnace", "lab", "boiler"}
  }
  if #found > 0 then return found[1] end
  local ghosts = surface.find_entities_filtered{area = area, type = "entity-ghost"}
  if #ghosts > 0 then return ghosts[1] end
  return nil
end

-- Check inserter pickup & drop targets and recipe compatibility
local function check_inserter(e)
  local faults = {}
  local surface = e.surface
  local pickup = e.pickup_target or target_at(surface, e.pickup_position)
  if not pickup then
    faults[#faults + 1] = {entity = e, kind = "no_pickup", detail = "inserter has no pickup source"}
  end

  local drop = e.drop_target or target_at(surface, e.drop_position)
  if not drop then
    faults[#faults + 1] = {entity = e, kind = "no_drop", detail = "inserter has no drop target"}
  end

  -- If pickup is crafter and drop is container, verify container matches crafter products
  if pickup and (pickup.type == "assembling-machine" or pickup.type == "furnace") then
    if drop and drop.type == "container" then
      local inv = drop.get_inventory(defines.inventory.chest)
      if inv and not inv.is_empty() then
        local p_recipe = pickup.get_recipe and pickup.get_recipe()
        local proto = p_recipe and prototypes.recipe[p_recipe.name]
        if proto and proto.products then
          local matches = false
          for _, pr in ipairs(proto.products) do
            if pr.type == "item" and inv.get_item_count(pr.name) > 0 then matches = true; break end
          end
          if not matches then
            faults[#faults + 1] = {entity = e, kind = "wrong_item", detail = "pickup crafter products do not match drop container contents"}
          end
        end
      end
    end
  end

  -- If drop target is a crafter, verify pickup side can supply one of the recipe's ingredients
  if drop then
    local crafter = drop
    if crafter.type == "entity-ghost" and (crafter.ghost_type == "assembling-machine" or crafter.ghost_type == "furnace") then
      -- Ghost crafter
    elseif crafter.type == "assembling-machine" or crafter.type == "furnace" then
      local recipe = crafter.get_recipe and crafter.get_recipe()
      local proto = recipe and prototypes.recipe[recipe.name]
      if proto and proto.ingredients then
        local ing_map = {}
        -- items only: get_item_count errors on fluid names
        for _, ing in ipairs(proto.ingredients) do
          if ing.type == "item" then ing_map[ing.name] = true end
        end

        -- If pickup is another crafter, check its output products
        if pickup and (pickup.type == "assembling-machine" or pickup.type == "furnace") then
          local p_recipe = pickup.get_recipe and pickup.get_recipe()
          local p_proto = p_recipe and prototypes.recipe[p_recipe.name]
          if p_proto and p_proto.products then
            local matches = false
            for _, pr in ipairs(p_proto.products) do
              if ing_map[pr.name] then matches = true; break end
            end
            if not matches then
              faults[#faults + 1] = {entity = e, kind = "wrong_item", detail = "pickup crafter does not produce any recipe ingredient"}
            end
          end
        elseif pickup and pickup.type == "container" then
          -- If chest has inventory and has items, ensure at least one matches
          local inv = pickup.get_inventory(defines.inventory.chest)
          if inv and not inv.is_empty() then
            local matches = false
            for name, _ in pairs(ing_map) do
              if inv.get_item_count(name) > 0 then matches = true; break end
            end
            if not matches then
              faults[#faults + 1] = {entity = e, kind = "wrong_item", detail = "pickup chest does not contain any recipe ingredient"}
            end
          end
        end
      end
    end
  end

  return faults
end

-- Walk belt line to verify it reaches an inserter consumer, splitter, or connection
local function check_belt_line(start_belt)
  local cur = start_belt
  local visited = {}
  local steps = 0
  local surface = start_belt.surface

  while cur and steps < MAX_BELT_STEPS do
    steps = steps + 1
    local key = cur.unit_number or string.format("%.1f,%.1f", cur.position.x, cur.position.y)
    if visited[key] then break end
    visited[key] = true

    -- Check if an inserter has pickup on this belt
    local near_ins = surface.find_entities_filtered{position = cur.position, radius = 1.6, type = "inserter"}
    for _, ins in ipairs(near_ins) do
      local ppos = ins.pickup_position
      if math.abs(ppos.x - cur.position.x) < 0.6 and math.abs(ppos.y - cur.position.y) < 0.6 then
        return nil -- Reached a consumer inserter!
      end
    end

    -- Splitter counts as consumer/distribution
    if cur.type == "splitter" or (cur.type == "entity-ghost" and cur.ghost_type == "splitter") then
      return nil
    end

    -- Underground belt handling
    if cur.type == "underground-belt" or (cur.type == "entity-ghost" and cur.ghost_type == "underground-belt") then
      local is_input = (cur.belt_to_ground_type == "input")
      if is_input then
        local neighbour = cur.underground_belt_neighbour
        if not neighbour then
          return {entity = cur, kind = "unpaired_underground", detail = "underground belt input has no exit"}
        end
        cur = neighbour
      else
        local outs = cur.belt_neighbours and cur.belt_neighbours.outputs
        if outs and #outs > 0 then cur = outs[1] else break end
      end
    else
      -- Regular transport belt
      local outs = cur.belt_neighbours and cur.belt_neighbours.outputs
      if outs and #outs > 0 then
        local nxt = outs[1]
        if nxt and nxt.direction ~= cur.direction then
          return nil -- Side-loads into another line
        end
        cur = nxt
      else
        break
      end
    end
  end

  -- If line ended without reaching a consumer, check if an inserter covers `cur`
  if cur and cur.valid then
    local near_ins = surface.find_entities_filtered{position = cur.position, radius = 1.6, type = "inserter"}
    for _, ins in ipairs(near_ins) do
      local ppos = ins.pickup_position
      if math.abs(ppos.x - cur.position.x) < 0.6 and math.abs(ppos.y - cur.position.y) < 0.6 then
        return nil
      end
    end
    -- Check if cur outputs directly into an adjacent consumer
    local dx, dy = 0, 0
    if cur.direction == defines.direction.north then dy = -1
    elseif cur.direction == defines.direction.east then dx = 1
    elseif cur.direction == defines.direction.south then dy = 1
    elseif cur.direction == defines.direction.west then dx = -1
    end
    local forward_pos = {x = cur.position.x + dx, y = cur.position.y + dy}
    local forward_consumer = surface.find_entities_filtered{position = forward_pos, radius = 0.5, type = {"container", "assembling-machine", "furnace"}}
    if #forward_consumer > 0 then return nil end

    return {entity = cur, kind = "dead_end", detail = "belt ends with no consumer or downstream connection"}
  end

  return nil
end

-- Check assembling machine / furnace inputs & outputs
local function check_crafter(m)
  local faults = {}
  local surface = m.surface
  local pos = m.position

  local has_input = false
  local has_output = false

  local near_ins = surface.find_entities_filtered{position = pos, radius = 3.5, type = "inserter"}
  for _, ins in ipairs(near_ins) do
    if ins.drop_target == m or (math.abs(ins.drop_position.x - pos.x) <= 1.5 and math.abs(ins.drop_position.y - pos.y) <= 1.5) then
      has_input = true
    end
    if ins.pickup_target == m or (math.abs(ins.pickup_position.x - pos.x) <= 1.5 and math.abs(ins.pickup_position.y - pos.y) <= 1.5) then
      has_output = true
    end
  end

  -- Check ghosts
  local near_ghosts = surface.find_entities_filtered{position = pos, radius = 3.5, type = "entity-ghost"}
  for _, g in ipairs(near_ghosts) do
    if g.ghost_type == "inserter" then
      if math.abs(g.drop_position.x - pos.x) <= 1.5 and math.abs(g.drop_position.y - pos.y) <= 1.5 then
        has_input = true
      end
      if math.abs(g.pickup_position.x - pos.x) <= 1.5 and math.abs(g.pickup_position.y - pos.y) <= 1.5 then
        has_output = true
      end
    end
  end

  if not has_output then
    local near_containers = surface.find_entities_filtered{position = pos, radius = 2.5, type = {"container", "furnace"}}
    if #near_containers == 0 then
      faults[#faults + 1] = {entity = m, kind = "no_output", detail = "machine has no output inserter or collector"}
    end
  end

  if m.type == "assembling-machine" then
    local recipe = m.get_recipe and m.get_recipe()
    local proto = recipe and prototypes.recipe[recipe.name]
    if proto and proto.ingredients then
      for _, ing in ipairs(proto.ingredients) do
        if not has_input then
          faults[#faults + 1] = {entity = m, kind = "no_input:" .. ing.name, detail = "machine has no input inserter for " .. ing.name}
        end
      end
    end
  end

  return faults
end

function AIFlow.check(entities)
  local faults = {}
  if not entities or #entities == 0 then return {ok = true, faults = {}} end

  -- Only the AI's own built entities: ghosts can't be read for belt/inserter targets, and the
  -- player's builds are never checked or repaired.
  for _, e in ipairs(entities) do
    if e and e.valid and e.type ~= "entity-ghost" and AIRegistry.is_owned(e) then
      local t = e.type
      if t == "inserter" then
        local ins_faults = check_inserter(e)
        for _, f in ipairs(ins_faults) do faults[#faults + 1] = f end
      elseif t == "transport-belt" or t == "underground-belt" then
        local b_fault = check_belt_line(e)
        if b_fault then
          local already = false
          for _, f in ipairs(faults) do
            if f.entity == b_fault.entity and f.kind == b_fault.kind then already = true; break end
          end
          if not already then faults[#faults + 1] = b_fault end
        end
      elseif t == "assembling-machine" or t == "furnace" then
        local c_faults = check_crafter(e)
        for _, f in ipairs(c_faults) do faults[#faults + 1] = f end
      end
    end
  end

  -- Record recent faults in storage
  if storage.ai_player and #faults > 0 then
    storage.ai_player.flow_faults = storage.ai_player.flow_faults or {}
    local tick = game.tick
    for _, f in ipairs(faults) do
      table.insert(storage.ai_player.flow_faults, {
        tick = tick,
        kind = f.kind,
        detail = f.detail,
        pos = f.entity and f.entity.valid and f.entity.position or nil
      })
    end
    local recent = {}
    for _, f in ipairs(storage.ai_player.flow_faults) do
      if tick - f.tick <= 36000 then recent[#recent + 1] = f end
    end
    while #recent > 50 do table.remove(recent, 1) end
    storage.ai_player.flow_faults = recent
  end

  return {ok = (#faults == 0), faults = faults}
end

function AIFlow.repair(character, result, opts)
  opts = opts or {}
  if not result or result.ok or not result.faults then return true, "ok" end

  local faults = result.faults
  local repaired_count = 0

  -- 1. Step 1: Rotate inserters
  for _, f in ipairs(faults) do
    if repaired_count >= MAX_REPAIR_ENTITIES then break end
    local e = f.entity
    if e and e.valid and AIRegistry.is_owned(e)
       and (f.kind == "no_pickup" or f.kind == "no_drop" or f.kind == "wrong_item") then
      local t = e.type == "entity-ghost" and e.ghost_type or e.type
      if t == "inserter" then
        local fixed = false
        for r = 1, 3 do
          e.rotate()
          local check_res = check_inserter(e)
          if #check_res == 0 then
            fixed = true
            repaired_count = repaired_count + 1
            break
          end
        end
        if not fixed then
          e.rotate() -- return to original orientation
        end
      end
    end
  end

  if opts.step1_only then
    return true, "step1 complete"
  end

  -- 2. Step 2: Turn dead-end belts
  for _, f in ipairs(faults) do
    if repaired_count >= MAX_REPAIR_ENTITIES then break end
    local e = f.entity
    -- a belt walk can end on a player's belt: only turn the AI's own
    if e and e.valid and f.kind == "dead_end" and AIRegistry.is_owned(e) then
      local t = e.type == "entity-ghost" and e.ghost_type or e.type
      if t == "transport-belt" then
        local surface = e.surface
        local pos = e.position
        local DIRS = {
          {dx = 0, dy = -1, dir = defines.direction.north},
          {dx = 1, dy = 0, dir = defines.direction.east},
          {dx = 0, dy = 1, dir = defines.direction.south},
          {dx = -1, dy = 0, dir = defines.direction.west},
        }
        local opp_dir = (e.direction + 8) % 16
        for _, d in ipairs(DIRS) do
          if d.dir ~= opp_dir then
            local adj_pos = {x = pos.x + d.dx, y = pos.y + d.dy}
            local adj_ents = surface.find_entities_filtered{position = adj_pos, radius = 0.4, type = {"transport-belt", "splitter", "underground-belt", "container", "assembling-machine", "furnace"}}
            local valid_target = false
            for _, adj in ipairs(adj_ents) do
              if adj ~= e then
                -- Don't turn into an entity that outputs into us
                local feeds_us = false
                local is_belt = (adj.type == "transport-belt" or adj.type == "underground-belt" or adj.type == "splitter")
                if is_belt and adj.belt_neighbours and adj.belt_neighbours.outputs then
                  for _, out_b in ipairs(adj.belt_neighbours.outputs) do
                    if out_b == e then feeds_us = true; break end
                  end
                end
                if not feeds_us then valid_target = true; break end
              end
            end
            if valid_target then
              e.direction = d.dir
              repaired_count = repaired_count + 1
              break
            end
          end
        end
      end
    end
  end

  -- Re-check entities
  local recheck_list = {}
  for _, f in ipairs(faults) do
    if f.entity and f.entity.valid then
      recheck_list[#recheck_list + 1] = f.entity
    end
  end

  local second_check = AIFlow.check(recheck_list)
  if second_check.ok then
    return true, "flow check: repaired"
  end

  -- 3. Step 3: Deconstruct broken build
  local first_fault = second_check.faults[1]
  local detail = first_fault and first_fault.detail or (first_fault and first_fault.kind or "flow check failed")

  for _, e in ipairs(recheck_list) do
    if e and e.valid and AIRegistry.is_owned(e) then
      if e.type == "entity-ghost" then
        e.destroy()
      elseif character and character.valid then
        character.mine_entity(e, true)
      end
    end
  end

  return false, "flow check: " .. detail
end

function AIFlow.doctor_pass(character, limit)
  if not (character and character.valid) then return end
  local surface = character.surface
  local owned_ins = AIRegistry.owned(surface, {"inserter"})
  if #owned_ins == 0 then return end

  limit = limit or 5
  local ap = storage.ai_player
  ap.flow_cursor = ap.flow_cursor or 1
  if ap.flow_cursor > #owned_ins then ap.flow_cursor = 1 end

  local checked = 0
  while checked < limit and checked < #owned_ins do
    local ins = owned_ins[ap.flow_cursor]
    ap.flow_cursor = ap.flow_cursor + 1
    if ap.flow_cursor > #owned_ins then ap.flow_cursor = 1 end

    if ins and ins.valid then
      local res = AIFlow.check({ins})
      if not res.ok then
        AIFlow.repair(character, res, {step1_only = true})
      end
    end
    checked = checked + 1
  end
end

return AIFlow
