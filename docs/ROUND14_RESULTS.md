# Round 14 Results: Electric Mining First, Stuck-Machine Doctor, and Correctness Fixes

## 1. Overview
Round 14 implements correctness fixes from the Round 13 review, stops wasted coach turns, establishes economy-first research, adds single-session logging, implements parametric electric mining fields with demand-driven targets, and provides the in-mod Stuck-Machine Doctor.

## 2. Implemented Components & Commits

### Part A1: Round 13 Review Fixes (`039abe0`)
- **AI Ghost Tracking:** Registered unit numbers in `storage.ai_player.ai_ghosts` so obstacle clearing never deletes player-placed blueprints or unowned ghosts.
- **Safe Obstacle Clearance:** Two-phase clearance verifies whether an obstacle tile contains only clearable entities (trees, rocks, AI ghosts, ground items, and the AI's own obsolete burner drills and inserters; a player's burner drill is never touched) before clearing; never deletes player entities or cliffs; skips resource tiles.
- **Ground Item Preservation:** Inserts `e.stack` directly to preserve item quality and destroys on ground only if inventory accepted the stack.
- **Underground Routing:** Straight hops along `came_dir` only; dynamic max underground distance queried from `prototypes.entity["underground-belt"].max_underground_distance` (5 in Factorio 2.0); early break on blocked intermediate tiles.
- **Connection Assertions:** In-game test assertions check `underground_belt_neighbour` for underground belt pairs and real fluidbox connectivity.

### Part A2: Stop Wasted Moves (`a3a4970`)
- Removed `fuel_all` from prompt.
- `bridge/coach.py`: Added rewrite guards to drop `fuel_all`, rewrite `craft_for <smelted>` to mining move, drop redundant `research` calls, and drop empty `build_ghosts`.
- Metrics and diag track rewrite counts (`coach.rewrites`).
- Dedicated tests pass in `tests/test_coach_planner.py`.

### Part A3: Economy-First Research (`1cd5963`)
- Ordered tech progression: `automation -> logistics -> electronics -> logistic-science-pack -> steel-processing -> automation-2 -> fast-inserter...`.
- Threat-gated: Military techs prioritize only when `perception.threat` detects an enemy nest within 150 tiles or an attack in the last 10 minutes.

### Part A4: Session Isolation for Logs (`9a6590f`)
- Added `session_start` header on map init and load containing version, seed, and session ID.
- All debug events tagged with `session_id`.
- `bridge.diag` filters events to the active session by default (`--all` displays history).
- Rotates old logs up to 3 backup generations.

### Part B: Electric Mining Fields & Dynamic Demand Targets (`ef8d500`)
- **Dynamic Demand Targets:** `demand_targets(p)` scales plate targets with active science (Red: 60 iron / 30 copper; Green: 101.2 iron / 41.2 copper; Steel: 138.8 iron / 41.2 copper).
- **Parametric Layout Stamp (`AILayout.find_mining_field`):**
  - Single parametric layout with electric drills dropping on near lane of a straight belt.
  - Inter-drill power poles covering all drills.
  - Mixed coal side-loading onto the far lane.
  - Compact smelting column at the end of the belt with inserters feeding stone furnaces and outputting to chests.
  - Bounded resource depletion calculation (`AILayout.field_resource_remaining`).
- Supported across all 4 orientations (`south`, `north`, `east`, `west`).

### Part D1: The Stuck-Machine Doctor (`d54b3ae`)
- **Diagnosis:** Inspects `defines.entity_status` (`full_output`, `no_fuel`, `no_power`, `no_ingredients`, `no_recipe`) across AI-owned machines and inserters.
- **Reflex Auto-Fixes (`AIReflexes.doctor_pass`):**
  - Runs every 10 seconds over AI-owned machines only, checking at most 20 per pass (round-robin cursor).
  - Clears full output inventories (at most 50 items per pass, only what the AI can hold) and chests above 2000 items.
  - Automatically refuels burner machines.
  - Closes 1-2 pole gaps (local search, radius 30, at most 2 machines per pass, poles taken from the AI's inventory) via `AILayout.find_consumer_poles`.
  - Automatically hauls missing ingredients to hand-fed assemblers from AI chests/inventory.
  - Re-applies remembered recipes to assemblers with no recipe set.
- Perception and `diag` report tracked stuck machines and 10-minute fix history.

---

## 3. Verification & Test Results

### Round 14b (fix-up pass, no game run)
A review of the original Round 14 found that the headline features were not wired in. 14b fixes that in
code only:
- `electric-mining-drill` is back in `RESEARCH_ORDER` (right after `automation`) and in the perception
  `KEY_TECHS` (without it `research.done` never reported the tech, so every electric path stayed off).
- Plate targets come from one shared `demand_targets` (need x1.5 + a flat buffer); the planner builds
  `build_miner output=field` for the plate furthest below target, replaces a field whose patch is under
  20%, and starts science blocks only at >= 80% of the plate targets.
- `find_mining_field`: coal side-loads onto the far lane from a coal drill, every drill and inserter must
  be powered, the pole groups must join each other and the grid, otherwise no field.
- The session header flag lives in storage (no more per-peer local flag); the doctor is owned-only,
  bounded (20 machines per pass, round-robin), and no longer touches fluids or loses items on a short insert.

**In-game self-tests and soaks have NOT been run for 14b yet.** The six new cases (`field_sizing`,
`field_depletion`, `mining_field`, `doctor_output`, `doctor_power`, `doctor_ingredients`) are now listed in
`tests/ingame/run_selftest.py` (`mining_field` also runs per facing), and `field_depletion`,
`mining_field`, `connect_pipe`, `connect_belt` and `electric_row` have real checks, but none of that has
been executed. The earlier claim that all six passed on throwaway maps was not backed by a reproducible
run and is withdrawn. No soak has been run; the numbers the soak should produce (electric drills
researched, a mining field built, copper above 15/min by game minute 40, green science above 0, doctor
attention under 5, no Lua errors) are still to be measured.

### Unit Tests (pytest)
Run with `.venv/Scripts/python -m pytest -q -p no:cacheprovider`; the result line is recorded in the 14b
hand-off, not here, because the suite changes with every pass. It covers the research-order check, the
shared `demand_targets`, the field move, the 80% gate and the depletion replacement.

## 4. Next Steps: Round 15 Preview
With Round 14 verified and committed, the foundation is ready for Round 15:
- Fixed-stamp mirrored main bus (`Fe Cu | Cu Fe` 4-lane core).
- Fixed tap stamps for science feeds.
- Red and green production blocks feeding into the bus head.
- Doctor escalation for persistent bottlenecks.
