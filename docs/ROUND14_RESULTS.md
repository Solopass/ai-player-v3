# Round 14 Results: Electric Mining First, Stuck-Machine Doctor, and Correctness Fixes

## 1. Overview
Round 14 implements correctness fixes from the Round 13 review, stops wasted coach turns, establishes economy-first research, adds single-session logging, implements parametric electric mining fields with demand-driven targets, and provides the in-mod Stuck-Machine Doctor.

## 2. Implemented Components & Commits

### Part A1: Round 13 Review Fixes (`039abe0`)
- **AI Ghost Tracking:** Registered unit numbers in `storage.ai_player.ai_ghosts` so obstacle clearing never deletes player-placed blueprints or unowned ghosts.
- **Safe Obstacle Clearance:** Two-phase clearance verifies whether an obstacle tile contains only clearable entities (trees, rocks, AI ghosts, ground items, unowned burner drills) before clearing; never deletes player entities or cliffs; skips resource tiles.
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
  - Runs periodically every 10 seconds (cap 20 fixes/pass).
  - Clears full output inventories and chests into character inventory.
  - Automatically refuels burner machines.
  - Closes 1-2 pole gaps to restore power to unpowered machines via `AILayout.find_consumer_poles`.
  - Automatically hauls missing ingredients to hand-fed assemblers from AI chests/inventory.
  - Re-applies remembered recipes to assemblers with no recipe set.
- Perception and `diag` report tracked stuck machines and 10-minute fix history.

---

## 3. Verification & Test Results

### Unit Tests (pytest)
```text
116 passed in 0.43s
```
All unit tests in `tests/test_coach_planner.py` pass without failures or regressions.

### In-Game Self-Tests (Headless Factorio 2.0 / 2.1)
All 6 new self-tests passed cleanly on throwaway maps:
1. `field_sizing`:
   - `37.5/min request gives 2 furnaces`: PASS
   - `37.5/min request gives 2 drills`: PASS
   - `37.5/min request gives 1 coal drill`: PASS
   - `18.75/min gives 1 furnace & 1 drill`: PASS
2. `field_depletion`:
   - Resource amount computation on area: PASS
   - Under 20% depletion threshold detection: PASS
3. `mining_field`:
   - `mining_field:south`: PASS
   - `mining_field:north`: PASS
   - `mining_field:east`: PASS
   - `mining_field:west`: PASS
4. `doctor_output`:
   - Full output chest/furnace cleared into character inventory: PASS
5. `doctor_power`:
   - Missing power pole gap automatically placed and machine powered: PASS
6. `doctor_ingredients`:
   - Hand-fed assembler with recipe automatically supplied with plates from chest: PASS

---

## 4. Next Steps: Round 15 Preview
With Round 14 verified and committed, the foundation is ready for Round 15:
- Fixed-stamp mirrored main bus (`Fe Cu | Cu Fe` 4-lane core).
- Fixed tap stamps for science feeds.
- Red and green production blocks feeding into the bus head.
- Doctor escalation for persistent bottlenecks.
