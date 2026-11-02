# Rounds 14 + 15: electric mining first, stuck-machine doctor, then a main bus

## Context
Your last game (logs from before the round-13 code):
- copper sat at 15/min all game;
- green science never ran;
- 20 machines were stuck for 50+ minutes;
- research went to military first;
- about 250 turns were wasted on moves that can only fail;
- the model did most of the turns, because autopilot kept failing on belt routing.

Since then, the routing crash is fixed and round 13 added underground routing and an electric
drill row. A review of round 13 found 7 bugs, and the current code hasn't been played yet.

You asked for:
1. better handling of stuck machines;
2. a **main bus** for belts and pipes;
3. **electric miners as a priority**, so the assemblers have plenty of materials.

An architect review of this plan said the bus alone is bigger than everything else combined,
and that it needs fixed stamps, not free routing. So it's **two rounds**:
- **Round 14:** correctness fixes, electric mining fields, the doctor's diagnosis and auto-fixes.
- **Round 15:** the main bus (stamp-based) with red and green blocks, plus doctor escalation,
  which needs both the mining fields and the bus.

After approval this file is saved as `docs/ROUND14_PLAN.md` (rounds 14 and 15). The guardrails
in `docs/ROUND13_PLAN.md` still apply: owned-only, no whole-surface scans, storage-only state,
bounded per-tick work, the round-6 guarantees, test safety, and push only to `solopass`.

---------------------------------------------------------------------------------------------
# ROUND 14

## A. Correctness first
### A1. Round-13 review must-fixes
1. **Obstacle clearing deletes the player's ghosts** (`primitives.lua:326`, `layout.lua:964`,
   `layout.lua:87`):
   - track AI ghosts by unit number in storage (`storage.ai_player.ai_ghosts`), wherever the AI
     creates ghosts (place_blueprint, routes);
   - clear only those, never any other ghost.
2. **Clearing happens before the full check** (`primitives.lua:310-329`, `layout.lua:947-969`):
   - first confirm the spot is blocked only by clearable things (trees, rocks matching
     `count_as_rock_for_filtered_deconstruction`, AI ghosts, ground items), then clear;
   - never clear when a player entity or a cliff blocks it.
3. **Ground items are lost** (`primitives.lua:316`, `layout.lua:957`):
   - `inv.insert(e.stack)`, which keeps quality;
   - destroy only if the whole stack went in.
4. **Clearing never works on ore:** a resource under the spot makes clearing fail
   (`layout.lua:81-90`). Skip `type == "resource"`.
5. **Underground hops turn mid-line** (`skills.lua:1160`):
   - hop only straight along `came_dir`;
   - out of an exit tile, only a straight step;
   - clear `came_ug` on normal steps.
6. **Hard-coded hop lengths** (`skills.lua:1043`): use `prototypes.entity[ug].max_underground_distance`.
   Self-test hops at max (works) and max+1 (refused).
7. **Tile checks redone for every hop length** (`skills.lua:1176`): break at the first blocked
   middle tile, and cache tile checks per call.
8. **Weak checks:**
   - a drill row needs every drill powered and its collector built;
   - self-tests must check real connections:
     - `belt_neighbours` (`{inputs, outputs}`) for belts;
     - `underground_belt_neighbour` for underground pairs;
     - `fluidbox` neighbours for pipes.

### A2. Stop wasted moves (`bridge/coach.py` guard, `bridge/prompt.py`)
- `fuel_all`: remove it from the prompt and drop it in the guard. Reflexes refuel.
- `craft_for <smelted item>`: rewrite it to the planner's mining move for that plate.
- `research <done or queued tech>`: drop it.
- `build_ghosts` with 0 ghosts: drop it.
- `bridge.diag` counts the rewrites. pytest per rule.

### A3. Research: economy first (`RESEARCH_ORDER` in `skills.lua`)
- automation → logistics → electronics → logistic-science-pack → steel-processing →
  automation-2 → fast-inserter → …
- Military techs move to the front only when `perception.threat` shows a nest within 150 tiles
  or an attack in the last 10 min.

### A4. One log per game
- A header line with mod version, seed and session id on init and load.
- `bridge.diag` shows only the current session (`--all` for everything).
- Old sessions are rotated, keeping the last 3.

## B. Electric mining as the top priority after power
### Targets from demand (`bridge/planner.py`, replaces the fixed `SMELT_TARGET` of iron 30 / copper 15)
- Each active science goal adds its plate needs: red 5/min → iron 10 + copper 5; green 5/min →
  iron 27.5 + copper 7.5; steel from its recipe.
- ×1.5 headroom, plus a build buffer while the base grows (iron 30, copper 15).
- **Rule order:** right after power, before any new production block:
  - keep every plate at its target;
  - the plate furthest below target gets the next mining field;
  - new science blocks start only at ≥ 80% of their plates' target.

### Mining field = a stamp, not routing (`AILayout.find_mining_field`)
- **One parametric layout,** checked with one `can_place` pass:
  - a straight ore belt;
  - electric drills on **one side** only, all dropping onto the **near lane**;
  - poles between the drills, every drill covered;
  - at the end of the ore belt, the **smelting column**: stone furnaces in a row beside the
    belt, with an input inserter from the ore belt and an output inserter onto a plate belt or
    chest per furnace.
- **Coal:** a short coal drill row whose belt side-loads onto the ore belt's **far (empty)
  lane** at the column start, from the correct side. Furnaces take ore and coal from the mixed
  belt. Reflex refuel stays as a backup.
- **Sizing:** furnaces = needed plates/min ÷ 18.75. Drills = ceil(furnaces × 18.75 / 30), since
  one electric drill gives 30 ore/min. Coal drills: 1 per 8 furnaces, at least 1.
- **Output before the bus exists:** the plate belt ends in a chest or two (iron chest), and
  tend/the reflex collects from there as now. In round 15 the plate belt goes to the bus head
  instead.
- **Rotation:** all 4 orientations, picked by fit (same approach as the existing row/pair
  layouts).
- **Depletion:** sum the remaining `.amount` of resources in the field's mining area (bounded
  search, every 5 min). Below 20%, the planner builds a replacement field on the nearest other
  patch before the old one runs dry.

### Self-tests
- `mining_field` (4 facings): drills powered, ore on the near lane, coal on the far lane,
  furnaces get both, plates reach the chest.
- `field_sizing`: a 37.5/min request gives 2 furnaces, 2 drills and 1 coal drill.
- `field_depletion`: a tiny patch triggers a replacement plan.

### Soak target
Iron and copper above target by game min 40 on both seeds; copper well past 15/min; no burner
drills placed after electric is researched.

## D1. The doctor: diagnose and auto-fix stuck machines (no bridge needed)
- **Diagnosis:**
  - read `LuaEntity.status` (`defines.entity_status`) for AI-owned machines and inserters,
    bounded per pass;
  - add the details the status doesn't give:
    - which input item is missing (recipe ingredients minus contents);
    - where output goes (drop target or chest);
    - the nearest pole for no-power;
  - keep `{status, since}` per unit number in storage. Perception reports the top 10 grouped
    by status.
- **Reflex fixes** (every 10 s, max 20 machines per pass):
  - `full_output` / output chest full → empty into the AI (or straight into the next AI-owned
    consumer that needs it);
  - `no_fuel` / low fuel → refuel;
  - `no_power` → `AILayout.find_consumer_poles` (`layout.lua:820`), placing the poles when one
    or two close the gap;
  - `no_ingredients` on a machine that's hand-fed (no belt feed) → haul from AI-owned outputs
    once;
  - `no_recipe` on an AI assembler with a remembered recipe → set it again.
- **Diag:** `bridge.diag` prints the attention list grouped by status, with the oldest `since`
  and what the doctor did in the last 10 min.
- **Self-tests:**
  - `doctor_output`: a full chest gets cleared;
  - `doctor_power`: a 1-pole gap gets closed;
  - `doctor_ingredients`: a hand-fed assembler gets hauled to.
- **Soak target:** attention < 5 machines over any 10-min stretch after game min 30.

## Round 14 verification
1. pytest green; Lua syntax check on every edited file.
2. Full self-test suite green, including the new cases.
3. Soaks `--no-llm` 90 game min on 2 armed seeds, against the targets above:
   - wasted moves near 0;
   - autopilot doing most turns;
   - green science > 0.
4. `docs/ROUND14_RESULTS.md`. Architect review of the diff, then commit. Push to the fork when
   you say so.
5. **Your test:** restart the server, start a NEW game, and paste the Diagnostics output after
   60 min.

---------------------------------------------------------------------------------------------
# ROUND 15: main bus (start after round 14 passes)

## Design: mirrored lanes, fixed stamps, no free routing
- **Corridor:** a straight strip from home along the direction with the most free land, stored
  in `storage.ai_player.bus = {origin, dir, lanes, slots, length}`.
  - Every AI layout and A* route avoids it: add a `forbidden` boxes option to A* and the
    `can_place` checks.
  - The player can still build there, so `build_bus` stops cleanly at a player entity and
    reports it.
- **Mirrored lanes:** `Fe Cu | 2-tile gap | Cu Fe`.
  - Each side's blocks tap only the lanes on their side.
  - The inner lane is at most one lane away, so a tap crosses at most one lane with one
    underground pair, well within yellow's 4-tile span.
  - More lanes are added later in groups of 4 with a 2-tile gap (standard bus spacing): steel,
    gears, green circuits.
- **Head:** the round-14 mining fields' plate belts run to the bus head (a stamped short belt
  from the column end to the lane start), one field per lane side.
- **Tap stamp:** for (lane, side, slot), a splitter on the lane, then the split-off belt turning
  out to the block side, with one underground pair when it crosses the other lane. It's a
  fixed list of relative positions for each (lane index, side), checked in one pass. A tap
  never joins another lane. Tested with `belt_neighbours` + `underground_belt_neighbour`.
- **Block stamp:** a row of assemblers along a block input belt fed by 1–2 taps, with input
  inserters from the belt and output inserters into chests or onto a science belt.
  - **Red block:** gears + red packs.
  - **Green block:** cables, circuits, inserters, belts, green packs.
  - **Lab row** at the end, fed by the science belt.
  - All are code stamps like `find_red_cell`. Blueprints only where input points are
    documented.
- **No pipe lanes this round.** Water for more steam stays with the existing steam code, and the
  pipe corridor comes with oil (later).
- **Extending:** when a lane's demand passes supply, round 14's B adds a field on that lane. When
  slots run out, `build_bus` extends the corridor.
- **Skills and planner:**
  - `build_bus`, `bus_tap{lane, side, slot}`, `build_block{kind, slot}`;
  - planner after round 14's B: bus → red block → lab row → green block;
  - the hand-fed cells are retired once their bus versions run, and hauling for them stops.
- **D2, doctor escalation:** stuck > 2 min after the reflex tried → a `sure` planner move:
  - lane empty → field;
  - tap broken → re-stamp the tap;
  - power short → steam scaling;
  - missing recipe → set it.

  Stuck > 5 min → it goes into the LLM prompt with the diagnosis.
- **Self-tests:**
  - `bus_lay`: lanes connected end to end;
  - `bus_tap` per (lane, side): the item reaches the block, no lane merge;
  - `bus_red_block`: red packs for 3 game min with no tend;
  - `bus_green_block`;
  - `doctor_escalate`: an empty lane produces a field move.
- **Soak target:** bus plus red and green blocks running by game min 75 on both seeds, green
  science > 5/min, attention < 5.
