# Round 16: builds that connect, or get fixed

Implementer: Antigravity. Reviewer: Claude (diff review before commit).
Guardrails from `docs/ROUND13_PLAN.md` still apply:
- owned-only (`AIRegistry.is_owned`);
- no whole-surface scans, and every `find_entities_filtered` has an area or radius;
- all state in `storage`, and `on_load` never writes storage;
- bounded work per tick, and no new `on_nth_tick` handler for 15/30/60/1800;
- never read or print `bridge/.env`;
- push only to `solopass`.

## Why (live game on the r14b map, 23 game min)
The economy is fine: iron 75/min, red science 8/min, 7 techs. The layout is broken: 20 of 47
machines need attention, and plates reach the machines only because tend hand-hauls them. The
causes, in order of damage:

1. **The planner's blueprint connections ignore rotation.** `bridge/planner.py:480-493`,
   `:527-540` and `:577-582` join the `tileable-*` blueprints with hard-coded offsets, such as
   `smelt_out = pos + (5.0, 0.5)` and `red_in = pos + (0.5, 5.5)`.
   - The mod places blueprints in whichever of 4 rotations fits (`mod/scripts/blueprints.lua`
     stores `direction` in `storage.ai_player.placed_blueprints`), but the offsets assume north.
   - So in 3 of 4 rotations, belts get routed to the wrong tiles.
   - Even at the right tile, `connect_belt` doesn't arrive in the input belt's direction.
2. **The model chooses coordinates itself.** `connect_belt`, `connect_pipe`, `place_blueprint`
   and the `place` primitive are in the model's schema.
   - For example, it routed (14,-3.5) to (8.5,5.5) with points it made up.
   - A local 9B/12B model can't reason about belt sides, lanes or inserter facing.
3. **No build is checked for flow.** Skills return OK as soon as the entities exist, even when an
   inserter picks up from nothing or a belt ends in the air.
4. **Wasted turns:**
   - build_defense failed 20 times ("3 gun turrets already stand");
   - research failed 16 times on techs that are done or locked;
   - the coach rewrote 119 craft_for moves for plates and 103 build_ghosts moves with no ghosts.

## Part 1: Blueprint ports (fixes cause 1)
**1a. Find ports automatically** (`bridge/blueprints.py`). For each repo blueprint
(`blueprints/tileable-*.json`, not `blueprints/local/`), decode it and compute `ports`:
- belt `in` port: a belt or underground whose upstream tile, against its direction, holds no
  belt of the blueprint feeding it;
- belt `out` port: a belt whose downstream tile, in its direction, holds no belt of the blueprint
  it feeds;
- pipe ports: pipe entities with an open connection to outside the blueprint (use the prototype's
  pipe connections);
- each port gets `{name, kind: "belt_in"|"belt_out"|"pipe", x, y, dir}` in blueprint coordinates.
  - Name ports `in1`, `in2`, … and `out1`, … in a stable order (sorted by y, then x).
  - Add an optional hand-set `item` per port in the JSON (for example iron-plate), kept when the
    ports are regenerated.

Add a CLI step: `python -m bridge.blueprints ports` writes `ports` into each tileable JSON and
prints them. Check by hand that each tileable blueprint gets the ports you'd expect, then commit
the JSON. pytest: fixture blueprints with a straight belt, an L-belt and a loop; the loop has no
ports.

**1b. Ports in the world** (`mod/scripts/blueprints.lua`): the bridge sends ports with the
library sync (in `meta`, next to the existing measured footprint). When a blueprint is placed:
- rotate each port with the same function used for the entities (the `rot` helper about the
  origin, `blueprints.lua:23-28`), rotating `dir` by the placement direction, and apply the same
  offset the placement uses;
- store the result in `storage.ai_player.placed_blueprints[i].ports`;
- perception reports `placed_blueprints[].ports`.

Self-test `bp_ports` (4 facings) places `tileable-science-red` and asserts each world port lands
on a belt entity of that blueprint's ghosts, with the matching direction.

**1c. A connect skill that works on ports:** `connect_ports{from_bp, from_port, to_bp, to_port}`
in `mod/scripts/skills.lua`, built on the existing `skill_connect_belt` router.
- Look the ports up in `storage.ai_player.placed_blueprints`; the bridge never does port math.
- The route starts on the tile **after** the `out` port, in its direction, and ends on the tile
  **before** the `in` port.
  - The last belt faces into the `in` tile along the port's `dir`, so it continues the line
    rather than side-loading.
  - If the router can't end with that direction, fail with a reason.
- Record the link in `storage.ai_player.connected_belts` by port identity, not coordinates.
- Pipes follow the same rules through `skill_connect_pipe`.

**1d. The planner uses ports.** Delete the hard-coded offsets at `planner.py:480-493`,
`:527-540` and `:577-582`. Use `connect_ports` with port names from a small table:
```python
LINKS = {  # (from_bp, from_port) -> (to_bp, to_port); fill from the ports CLI output
    ("tileable-smelter-stone", "out1"): ("tileable-science-red", "in1"),
    ...
}
```
It's "connected" when perception lists the port pair in `connected_belts`. The steam power
offsets (`planner.py:299-397`) move to ports the same way.

## Part 2: The model doesn't do layout (fixes cause 2)
- Add config `AI_LLM_LAYOUT` (default `false`) to `bridge/config.py`.
- While it's false:
  - remove `place_blueprint`, `connect_belt`, `connect_pipe`, `connect_ports` and the `place`
    primitive from the model's schema (`bridge/schema.py`) and prompt (`bridge/prompt.py`,
    `bridge/factorio/api.py` SKILLS/ACTIONS lists sent to the model);
  - the coach guard drops them from model answers (counted in `coach.rewrites` as
    `drop_llm_layout`);
  - autopilot moves (`source == "autopilot"`) are unaffected.
- `blueprints/local/` (downloaded) blueprints are never offered to the model or the autopilot,
  whatever the setting. The player can still use `/ai-bp`.
- The model's prompt lists only the named builds it may choose: `build_miner`, `build_power`,
  `build_red_cell`, `build_green_cell`, `build_assembler`, `build_defense`, `research`,
  `craft_for` (non-plates), `tend`, `goto`, `gather`, `return_home`.
- pytest: with the flag off, a model answer containing `connect_belt` is dropped, and the schema
  enum doesn't list it.

## Part 3: Flow check and repair (fixes cause 3)
**New file `mod/scripts/flowcheck.lua`** (`AIFlow`). Load it in `control.lua` like the other
scripts.

`AIFlow.check(entities)` takes a list of AI-owned entities from one build and returns
`{ok, faults = {{entity, kind, detail}}}`. Entity types:
- **inserter:** `e.pickup_target` and `e.drop_target` are both non-nil. A belt or ground target is
  allowed when a belt entity sits at `e.pickup_position` / `e.drop_position` (find by position,
  radius 0.5).
  - If the drop target is a crafter, the pickup side must be able to carry one of its recipe's
    item ingredients: a chest or crafter output holding it, or the belt line's source.
  - Kinds: `no_pickup`, `no_drop`, `wrong_item`.
- **belt line:** from every belt in the set, walk `belt_neighbours.outputs` (and
  `underground_belt_neighbour` for `type == "underground-belt"` inputs), at most 200 steps.
  - The walk must reach a belt that some inserter's `pickup_position` covers, or a splitter, or a
    side-load into another line.
  - Kinds: `dead_end` (output with no neighbour and no consumer), `unpaired_underground`.
- **assembling machine / furnace:** each solid ingredient has one inserter in the set (or already
  standing, owned) whose `drop_target == e`. The output has an inserter with `pickup_target == e`,
  or the crafter is next to a chest it feeds.
  - Kinds: `no_input:<item>`, `no_output`.

`AIFlow.repair(character, result)`, in order, at most 10 entities per call:
1. `no_pickup` / `no_drop` / `wrong_item` on an inserter: try `e.rotate()` up to 3 times, and
   keep the first direction that passes the inserter check. Otherwise leave it as a fault.
2. `dead_end` on a belt: if a consumer belt is right beside the end, rotate the last belt toward
   it.
3. If it still fails: deconstruct the build's AI-owned entities (mine them into the AI's
   inventory with `character.mine_entity`, never `destroy`) and return
   `ok=false, detail="flow check: <first fault>"`. The coach then blocks that move.

**Where it runs:**
- At the end of every layout skill after `AILayout.build` / `build_ghosts` completes a build:
  `build_miner` (field, row, pair), `build_red_cell`, `build_green_cell`, `build_assembler`,
  `build_power`, `connect_ports`, `connect_belt`.
  - Ghosts not built yet: check on the `build_ghosts` call that finishes them. Keep the pending
    build's unit numbers in `storage.ai_player.pending_flow = {[build_id] = {unit_numbers…}}`.
- In the doctor pass (`reflexes.lua`): `AIFlow.check` on at most 5 owned inserters per pass
  (round-robin cursor in storage), with repair step 1 only.
- `bridge.diag` shows `flow faults: N` (last 10 min) with the first 5 details. Perception reports
  the count.

**Self-tests** (`mod/scripts/selftest.lua`, added to `ALL_CASES` in `tests/ingame/run_selftest.py`):
- `flow_reversed_inserter`: place an inserter backwards between a chest and an assembler; repair
  rotates it; the check passes.
- `flow_dead_end`: a belt that ends one tile short of a consumer gets turned; one that leads
  nowhere is reported and torn down.
- `flow_red_cell` (4 facings): `build_red_cell`, then `AIFlow.check` has zero faults.
- `prod_red_cell`, `prod_mining_field`: build with the inputs supplied, run 3 game min with no
  tend, assert the output passes a floor.

## Part 4: Stop the wasted moves (fixes cause 4)
- `planner.py`: `build_defense` only when `factory` turrets < wanted, or ammo per turret is under
  10. The guard drops `build_defense` when the last result for it said "already stand" in the last
  5 min (`bridge/coach.py`).
- `research`: the guard drops a tech in `research.done`, and one whose prerequisites aren't done.
  Perception adds `research.available` (techs whose prerequisites are researched, at most 30,
  from `force.technologies` filtered by `enabled and not researched` with all
  `prerequisites[..].researched`); the guard uses that.
- With `AI_JSON_SCHEMA=true`, `craft_for.item` excludes smelted plates, and `build_ghosts` is only
  in the schema enum when perception's `ghosts > 0`.
- pytest for each rule.

## Order of work
1. Part 2 (small; it stops new damage).
2. Part 4.
3. Part 1a-1b (the ports CLI and storage).
4. Part 1c-1d.
5. Part 3.

One commit per part, with a message saying what changed.

## Done means
- pytest green, with new tests for Parts 1a, 2 and 4.
- Lua syntax check on every edited Lua file (`luaparser`; there's no luac on this machine).
- New self-tests are in `ALL_CASES` / `FACING_CASES`.
- `docs/ROUND16_RESULTS.md` lists exactly what was run.
  - **Paste the real command lines and their result lines.**
  - Don't claim a self-test passed unless you show its output.
  - If you didn't run the in-game tests, say so plainly.
- Tell Claude when it's done, for the diff review.

## Optional but strongly recommended
In-game self-tests catch layout bugs before your game does. When the Factorio server is stopped:
```
.venv/Scripts/python tests/ingame/run_selftest.py bp_ports flow_reversed_inserter flow_dead_end flow_red_cell prod_red_cell prod_mining_field
```
Case names are plain arguments. With no arguments the runner runs **every** case, which takes
about 15 minutes; it has no `--help`.
