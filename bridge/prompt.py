"""
Router prompt assembly (v3).

The router is a SMALL prompt: given a compact game state it picks the next
SKILL (a parameterized basic loop) or, as a fallback, a primitive action.
Skills own the mechanics (positions, fuelling, pipe routing) so the model never
has to pixel-place — it just decides what to do, not how.

Keep this prompt small; that is the point of the skill design.
INVARIANT: the skill list must match bridge/factorio/api.py SKILLS and
mod/scripts/skills.lua REGISTRY.
"""

import json

def get_system_prompt(llm_layout: bool = False) -> str:
    skills = [
        '- {"skill":"build_ghosts"}            Build the buildings the human placed as ghosts. HIGHEST PRIORITY whenever ghosts.count > 0 — this is the human directing you.',
        '- {"skill":"deconstruct"}             Mine everything the human marked for deconstruction (buildings, trees, rocks). SECOND PRIORITY whenever deconstruction.count > 0 — the human flagged these to be removed; the items go into your inventory.',
        '- {"skill":"gather","item":"<item>","count":50}   Mine the nearest sources until you have count. item e.g. "wood" (chops trees), "iron-ore", "copper-ore", "coal", "stone".',
        '- {"skill":"build_miner","resource":"iron-ore","output":"furnace","count":2}   Build `count` (1-6) burner drills on the nearest patch, each facing a collector placed exactly where it drops: output=furnace (ore → plates, iron/copper), chest (coal, stone), or belt (a row of drills onto one belt into a chest; needs belts, 1 burner-inserter, 1 chest). Spots, facing and fuel are worked out for you. Needs burner-mining-drills (craft_for them in the same turn). Once the electric-mining-drill tech is done, a grid pole is nearby and you hold or can craft the drill, output=furnace builds ELECTRIC pairs instead: drill -> furnace -> inserter -> chest, powered by poles wired to the grid. output=field (electric era, count = furnaces, 1-6) builds a whole mining field in one move: a belt of drills on one patch, coal side-loaded onto it, and a column of furnaces with output chests (about 18 plates/min per furnace); the planner picks it when a plate is below target.',
        '- {"skill":"build_power"}             Steam power in one go: offshore pump on the nearest shore -> boiler (fuelled) -> 2 steam engines -> small poles back toward home. Needs offshore-pump, boiler, 2 steam-engine, pipes and poles in inventory (craft_for them first; goto landmarks.water if it is more than ~40 tiles away). Use when perception.power.has_grid is false.',
        '- {"skill":"build_assembler","recipe":"iron-gear-wheel"[,"count":1]}   Assembling-machine with the recipe set: input chest -> inserter -> assembler -> inserter -> output chest, poles wired to the grid. Needs power first. tend hauls plates into the input chest.',
        '- {"skill":"build_red_cell"}          Red science line: a gear assembler feeding two automation-science-pack assemblers that drop into a lab (or a chest), with copper/iron input chests and poles. Needs the automation tech and power; tend hauls plates in and packs to the labs.',
        '- {"skill":"build_green_cell"}        Green science from seven assembler units (gears, copper cable, circuits, inserters, belts, 2x logistic-science-pack), each with input and output chests; builds up to 3 missing units per call, so repeat it. Needs the logistic-science-pack tech and power; tend hauls plates in, carries each unit\'s output to the next, and the packs to the labs.',
        '- {"skill":"build_defense"[,"count":3]}   2-4 gun turrets on the side of home facing the nearest enemy nest (perception.threat.nearest) or the last attack, each loaded with firearm magazines. Needs the gun-turret tech and plates for turrets and ammo. Use when threat.nearest is within ~150 tiles or threat.attack is set; tend keeps the turrets stocked.',
        '- {"skill":"build_smelter","ore":"iron-ore","count":2}   Place & load stone-furnaces to smelt ore into plates (fuels + feeds them). Needs the ore in inventory first (gather it).',
        '- {"skill":"tend"}                    Look after YOUR burner base near home in one go: collect plates/ore/coal from your furnaces and chests, refuel, feed ore into idle furnaces, and put a furnace/chest under drills that spill onto the ground; tops boilers up to 20 coal, hauls plates into assembler chests and science packs into labs. Run it when needs[] lists anything, and every few turns while you have burner drills.',
        '- {"skill":"research"[,"tech":"automation"]}   Queue a technology on your force (picks one if you omit tech). REQUIRED before any research can progress — a lab does NOTHING until research is queued.',
        '- {"skill":"return_home"}             Walk back to your base anchor (use if you\'ve wandered far).',
        '- {"skill":"goto","position":{"x":N,"y":N}}   Teleport to any map coordinate. Use to reach a distant location (e.g. an oil outpost) before acting. build_ghosts auto-travels to ghost clusters, so only use goto for manual positioning.',
    ]
    if llm_layout:
        skills.append('- {"skill":"place_blueprint","name":"<library name>"[,"position":{"x":N,"y":N}]}   Stamp a proven build from the blueprint library as ghosts; the spot (clear ground, ore patch or shoreline) is found for you. Then build_ghosts builds it. Prefer this over placing buildings one by one.')
    skills.append('- {"skill":"craft_for","item":"<item>","count":N}   Hand-craft an item (and its intermediates) until you HOLD count in total; tells you which raw materials are still missing. Plates and steel can\'t be hand-crafted — smelt them. To craft NEW ones when you already hold some (e.g. a research trigger), set count = what you hold + how many more.')
    if llm_layout:
        skills.append('- {"skill":"connect_belt","from":{"x":N,"y":N},"to":{"x":N,"y":N}}   Lay a transport-belt (as ghosts) along an L-shaped path between two points, e.g. from a miner\'s output to a smelter\'s input.')
        skills.append('- {"skill":"connect_pipe","from":{"x":N,"y":N},"to":{"x":N,"y":N}}   Lay fluid pipes (as ghosts) along an L-shaped path between two fluid ports, e.g. from a pumpjack to an oil refinery, or refinery to chemical plant.')
    skills.extend([
        '- {"skill":"build_pumpjack"[,"position":{"x":N,"y":N}]}   Place an electric pumpjack on the nearest crude-oil node to extract oil and wire it to the power grid.',
        '- {"skill":"build_offshore_pump"[,"position":{"x":N,"y":N}]}   Place an offshore pump on the nearest shoreline tile to supply water for steam power or chemical plants.',
        '- {"skill":"build_radar"}                 Place a radar near base to continuously survey surrounding chunks and reveal distant ore, oil patches and biter nests.',
        '- {"skill":"connect_power","to":{"x":N,"y":N}}   String an electric pole chain from the powered grid to an unpowered machine or cluster so it has electric power.',
        '- {"skill":"fix_flow"}                    Audit and auto-repair broken belt lines, dead ends, and reversed inserters around machines.',
    ])
    skills_text = "\n".join(skills)

    if llm_layout:
        actions_line = "move{direction[,distance≤16]}, mine{name|type|position}, place{item,position[,direction]}, set_recipe{recipe,position}, craft{recipe,count}, insert{item,count,position[,inventory]}, take{item,count,position[,inventory]}, pickup{position}, chat{message}, add_note{text}, summary{text}, wait{}."
        rule_3 = "- Don't only smelt. To AUTOMATE mining use build_miner. To place ANY building not covered by a skill, use the place primitive with the item from your inventory (e.g. {\"action\":\"place\",\"item\":\"lab\",\"position\":{...}}). perception.inventory lists EVERYTHING you have — trust it for what's available."
    else:
        actions_line = "move{direction[,distance≤16]}, mine{name|type|position}, set_recipe{recipe,position}, craft{recipe,count}, insert{item,count,position[,inventory]}, take{item,count,position[,inventory]}, pickup{position}, chat{message}, add_note{text}, summary{text}, wait{}."
        rule_3 = "- Don't only smelt. To AUTOMATE mining use build_miner. Choose from named build skills (build_miner, build_power, build_red_cell, build_green_cell, build_assembler, build_defense) — do not attempt coordinate layout. perception.inventory lists EVERYTHING you have — trust it for what's available."

    return f"""You are an AI playing Factorio. You operate by choosing SKILLS — high-level parameterized tasks that handle placement, fuelling and positioning for you. Prefer skills; fall back to primitive actions only for things no skill covers.

Respond with a JSON ARRAY of skill and/or action objects. ONLY the array — no prose.

=== SKILLS (prefer these) ===
{skills_text}

=== PRIMITIVE ACTIONS (fallback only) ===
{actions_line}
(To get WOOD use gather item "wood" or mine type "tree". Directions are strings: north/east/south/west/…)

=== RULES ===
- If ghosts.count > 0, do {{"skill":"build_ghosts"}} FIRST, before anything else — this is the human telling you what to build.
- Else if deconstruction.count > 0, do {{"skill":"deconstruct"}} NEXT — the human marked those objects to be removed; clearing them comes before everything except building ghosts.
{rule_3}
- React to "Results of your last actions": never repeat a FAILED entry unchanged. If a skill says it needs an item, gather/craft it, then retry.
- Use needs[] to pick maintenance: anything in burners_low_fuel or outputs_full → tend. outputs_full entries with drop="ground" are drills with nothing under their output — tend places a collector.
- research.triggers lists techs unlocked by DOING something, not by research (2.x early game), e.g. {{"type":"craft-item","target":"lab","count":1}} = hand-craft 1 NEW lab. Do that to open up research.
- SUGGESTED MOVES are a safe default from the build order — send them when you have nothing better. Never send a BLOCKED move.
- SEND 2-4 MOVES PER TURN, in order. They run one after another and later moves wait for hand-crafting to finish, e.g. [{{"skill":"craft_for","item":"burner-mining-drill","count":2}},{{"skill":"build_miner","resource":"iron-ore","output":"furnace","count":2}},{{"skill":"tend"}}].
- Plates are SMELTED, never crafted: craft_for iron-plate smelts ore you hold; otherwise mine ore into furnaces with build_miner output=furnace.
- perception.factory is your whole-base view (all your machines, not just nearby ones): factory.summary.by_type/by_status are counts; factory.total is how many machines you have; factory.attention lists the machines that need action (nearest first) — fix those. factory.machines is a full per-machine list ONLY while the base is small; when it's absent the base is large, so rely on summary + attention instead of trying to micromanage every machine. perception.nearby_entities is just what's physically around the character (nearest first) for placement context.
- RESEARCH = your main progress marker (perception.game_phase tracks it). If perception.research.current is null, NOTHING is queued — queue the next tech for your phase with {{"skill":"research"}} and keep labs fed. ONLY in phase 0 (no red science yet) do you BOOTSTRAP: hand-craft automation-science-pack (1 copper-plate + 1 iron-gear-wheel; gear = 2 iron-plate) to auto-trigger the first tech, then place a lab and feed it. Past phase 0 do NOT hand-craft red science to "restart" — just queue research.
- POWER: perception.power shows grid health (has_grid, production_kw, consumption_kw, machines_no_power, machines_low_power). If has_grid is true and machines_no_power + machines_low_power are 0, power is SUFFICIENT — do NOT build boilers/steam/power. Only build power when there's no grid or machines report no_power/low_power.
- COOP: perception.coop true = you share the human's force (their whole base is your factory view; help expand it, don't rebuild basics). false = solo on your own force.
- REFLEXES: the mod itself shoots enemies near you, the human and your machines, refuels burners and boilers, empties furnaces, reloads turrets and queues research (perception.reflex shows what it is doing). Don't spend turns on shoot or refuelling. While reflex.state is fighting or retreating a turn may be cancelled ("cancelled: combat"); that is not a failure, just carry on afterwards.
- STAY NEAR HOME (perception.home.distance). If far with no reason, {{"skill":"return_home"}}.
- LANDMARKS: perception.landmarks lists the nearest water and the nearest patch of each resource within ~220 tiles (distance in tiles). nearby_* only covers what you can see. If what you need isn't nearby, goto its landmark position first (offshore pump: goto landmarks.water; mining: goto the ore), then build there.
- PLANET: perception.surface.name is the planet (or space platform) you are on. Home, factory and nearby_* cover only this surface; each planet has its own home and base. Use what this planet offers (e.g. no trees or coal on some planets) — check nearby_resources before gathering.
- When the player sends a message, reply with a chat action first, then act.
- Keep it to 1–3 entries per turn. Don't stack many actions blindly.

=== EXAMPLES ===
[{{"skill":"build_ghosts"}}]
[{{"skill":"gather","item":"iron-ore","count":40}}]
[{{"action":"chat","message":"On it — smelting iron."}},{{"skill":"build_smelter","ore":"iron-ore","count":2}}]
"""

SYSTEM_PROMPT = get_system_prompt(False)

# Per-phase hint (brief — the router stays small).
PHASE_HINT = {
    0: "Phase 0 (bootstrap, no red science): get iron/copper plates and a lab fed with hand-crafted automation-science-pack to trigger the first research.",
    1: "Phase 1 (red/automation science): automate iron+copper smelting and assemblers feeding labs; research toward logistic (green) science.",
    2: "Phase 2 (green/logistic science): scale belts, inserters, assemblers; research toward military science.",
    3: "Phase 3 (military science): turrets, walls, steel, ammo; secure and expand. Research toward chemical (blue) science.",
    4: "Phase 4 (blue/chemical science): oil → plastic/sulfur/batteries; research toward production/utility science.",
    5: "Phase 5 (production/utility science): modules, beacons, advanced production; research toward the rocket.",
    6: "Phase 6 (rocket): build and supply the rocket silo.",
}


def _failed_detail(results, name: str) -> str | None:
    """Detail of a FAILED entry for skill/action `name` in last turn's results."""
    for r in results or []:
        if not isinstance(r, dict) or r.get("ok"):
            continue
        label = str(r.get("skill") or r.get("action") or "").removeprefix("skill:")
        detail = str(r.get("detail") or "")
        if label == name or detail.startswith(name):
            return detail or label
    return None


def build_messages(payload: dict, system_prefix: str = "", goal_text: str = "",
                   coach_text: str = "", llm_layout: bool = False) -> list[dict]:
    """goal_text: the goal-ladder section from bridge/goals.py. When given it
    replaces the coarser per-phase hint. coach_text: recent turns, blocked
    moves and the planner's next step (bridge/coach.py)."""
    system = get_system_prompt(llm_layout)
    if system_prefix:
        system = system_prefix.strip() + "\n\n" + system

    parts: list[str] = []
    perception = payload.get("perception") or {}
    if perception:
        # The goal section already names the blueprints that matter; the full
        # library / locked lists and unbounded rosters would only cost tokens.
        drop = {"blueprint_locked", "connected_belts", "connected_pipes"} | ({"blueprint_library"} if goal_text else set())
        shown = {k: v for k, v in perception.items() if k not in drop}
        if isinstance(shown.get("factory"), dict) and "machines" in shown["factory"]:
            shown["factory"] = {k: v for k, v in shown["factory"].items() if k != "machines"}
        parts.append("Game state:\n" + json.dumps(shown, indent=1))
        phase = perception.get("game_phase")
        if phase in PHASE_HINT and not goal_text:
            parts.append(PHASE_HINT[phase])

    mem = payload.get("memory") or {}
    results = mem.get("last_action_results")
    if results:
        lines = [f"  [{'OK' if r.get('ok') else 'FAILED'}] {r.get('detail') or r.get('action','')}"
                 for r in results]
        parts.append("Results of your last actions (react to FAILED — don't repeat them):\n"
                     + "\n".join(lines))
    if mem.get("previous_summary"):
        parts.append("Last turn: " + str(mem["previous_summary"]))
    if mem.get("notes"):
        notes = [n.get("text", "") if isinstance(n, dict) else str(n) for n in mem["notes"]]
        parts.append("Notes: " + " | ".join(notes))
    if mem.get("user_directive"):
        parts.append("Player directive (keep following): " + str(mem["user_directive"]))
    if goal_text:
        parts.append(goal_text + ("\n(The player directive above comes first; work on the goal "
                                  "when it's done.)" if mem.get("user_directive") else ""))

    if coach_text:
        parts.append(coach_text)

    user_message = payload.get("user_message")
    if user_message:
        parts.append('Player says: "' + str(user_message) + '" — reply with a chat action first.')

    # Hard gate, placed LAST for recency: small models ignore priority rules buried
    # mid-prompt, so restate the mandate as the final instruction they read.
    # Priority order: ghosts > deconstruction (both physical human intent) > force_skill.
    # NOTE: factory_state returns ghosts/deconstruction as plain integers; gather_perception
    # returns them as {count, list} dicts. Handle both forms.
    _ghosts_raw = perception.get("ghosts") or 0
    _decon_raw  = perception.get("deconstruction") or 0
    ghost_count = _ghosts_raw.get("count", 0) if isinstance(_ghosts_raw, dict) else int(_ghosts_raw)
    decon_count = _decon_raw.get("count", 0)  if isinstance(_decon_raw,  dict) else int(_decon_raw)
    forced = mem.get("force_skill")
    # Escape hatch: if the previous turn's build_ghosts FAILED (e.g. "no buildable
    # ghosts" — missing items), forcing it again would loop forever. Release the
    # gate for this turn so the model can gather/craft what the ghosts need.
    ghost_blocked = _failed_detail(results, "build_ghosts")
    missing_items = (perception.get("ghosts") if isinstance(perception.get("ghosts"), dict) else {}).get("missing_items") or {}
    missing_str = ", ".join(f"{cnt}x {it}" for it, cnt in sorted(missing_items.items()))

    if ghost_count > 0 and ghost_blocked is None and not missing_items:
        parts.append(
            f'IMPORTANT: there are {ghost_count} ghost(s) the human placed for you to build. '
            'Your response MUST be exactly [{"skill":"build_ghosts"}] and nothing else — '
            'build what the human asked for before doing anything else.'
        )
    elif ghost_count > 0 and missing_items:
        parts.append(
            f'NOTE: {ghost_count} ghost(s) are waiting to be built, but you lack required items: {missing_str}. '
            'Do NOT call build_ghosts yet — craft or gather the missing items first using craft_for, '
            'or tend to collect smelted plates from furnaces. Once crafted, call build_ghosts.'
        )
    elif ghost_count > 0:
        parts.append(
            f'NOTE: {ghost_count} ghost(s) are waiting, but your last build_ghosts attempt '
            f'FAILED ("{ghost_blocked}"). Do NOT call build_ghosts again this turn — '
            'look at the ghost list in perception, then gather or craft the items those '
            'ghosts need. Retry build_ghosts only once you have the items.'
        )
    elif decon_count > 0:
        parts.append(
            f'IMPORTANT: the human marked {decon_count} object(s) for deconstruction. '
            'Your response MUST be exactly [{"skill":"deconstruct"}] and nothing else — '
            'clearing what the human flagged comes before everything except building ghosts.'
        )
    elif forced:
        parts.append(
            f'IMPORTANT: the player has directed you to use the "{forced}" skill. '
            f'Your response MUST be a JSON array containing only that skill — '
            f'[{{"skill":"{forced}", ...}}] with appropriate params taken from the directive '
            'above — and nothing else (you may prepend one chat action if replying to the player).'
        )
    else:
        parts.append("What is your next move? Respond with a JSON array of skill/action objects.")
    return [
        {"role": "system", "content": system},
        {"role": "user",   "content": "\n\n".join(parts)},
    ]
