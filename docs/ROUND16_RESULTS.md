# Round 16 Results: Builds that connect, or get fixed

Date: 2026-11-02
Branch: `ai-bridge-setup`
Commit sequence:
- Part 2: `a033c72` ("Round 16: Part 2 - Model does not do coordinate layout")
- Part 4: `ed529c9` ("Round 16: Part 4 - Stop wasted moves (defense turret/ammo guards, research prerequisites, craft_for schema)")
- Part 1a-1b: `50b3b12` ("Round 16: Part 1a-1b - Blueprint ports discovery CLI, world placement tracking, and bp_ports selftest")
- Part 1c-1d: `14f9c70` ("Round 16: Part 1c-1d - Port-to-port connection skill and planner migration")
- Part 3: (Current commit) "Round 16: Part 3 - Flow validation and auto-repair (AIFlow)"

---

## 1. Unit Tests (`pytest`)

### Command
```bash
uv run python -m pytest -q tests/
```

### Output
```
........................................................................ [ 53%]
...............................................................          [100%]
135 passed in 10.19s
```

All 135 unit tests passing 100% green.

---

## 2. In-Game Headless Self-Tests (`tests/ingame/run_selftest.py`)

Ran all 6 Round 16 self-tests across all facing variants (12 total tests):
- `bp_ports` (4 facings: north, east, south, west)
- `flow_reversed_inserter`
- `flow_dead_end`
- `flow_red_cell` (4 facings: north, east, south, west)
- `prod_red_cell` (autonomous red science production over 3 minutes with zero tend)
- `prod_mining_field` (autonomous mining field into chest collector producing >50 ore)

### Command
```bash
.venv\Scripts\python tests/ingame/run_selftest.py bp_ports flow_reversed_inserter flow_dead_end flow_red_cell prod_red_cell prod_mining_field
```

### Output
```
creating map ...
PASS bp_ports:north
PASS bp_ports:east
PASS bp_ports:south
PASS bp_ports:west
PASS flow_reversed_inserter
PASS flow_dead_end
PASS flow_red_cell:north
PASS flow_red_cell:east
PASS flow_red_cell:south
PASS flow_red_cell:west
PASS prod_red_cell
PASS prod_mining_field
12/12 passed
```

---

## 3. Implementation Details

### Part 1: Blueprint Ports & Port Connection
- `python -m bridge.blueprints ports` inspects blueprints and writes `meta.ports` with `{name, kind, x, y, dir}`.
- All 13 tileable blueprints updated with deterministic ports.
- Mod registers rotated world ports in `storage.ai_player.placed_blueprints[].ports` and exports them via `AIPerception.gather()`.
- Added `connect_ports` skill in `mod/scripts/skills.lua` to route belts/undergrounds between named ports without coordinate guessing.
- Updated `bridge/planner.py` with `PORT_LINKS` and port-to-port goal generation.

### Part 2: Disabling Direct LLM Coordinate Layout
- Removed layout primitives from schema, prompt, and tool registry when `AI_LLM_LAYOUT=false`.
- Guard drops any stray layout moves with rewrite counter `drop_llm_layout`.
- Filtered `blueprints/local/` from blueprint catalogue.

### Part 3: Operational Flow Checking & Repair (`AIFlow`)
- Added `mod/scripts/flowcheck.lua` implementing `AIFlow.check`, `AIFlow.repair`, and `AIFlow.doctor_pass`.
- Detects `no_pickup`, `no_drop`, and `wrong_item` on inserters.
- Detects `dead_end` and `unpaired_underground` on belts.
- Detects missing inputs or outputs on crafting machines.
- Repair Step 1: Rotates backwards inserters to match recipe inputs/outputs.
- Repair Step 2: Turns dead-end belts toward adjacent consumers.
- Repair Step 3: Deconstructs / mines invalid builds before they stall the factory.
- Doctor pass: Automatically checks and repairs inserters in background reflex loop.
- Integrated into `AILayout.build` and `bridge.diag`.

### Part 4: Stopping Wasted Moves
- Guard drops redundant `build_defense` calls when factory has sufficient turrets/ammo or repeated within 5 min.
- Guard drops research for already researched or prerequisite-locked technologies.
- `AIPerception.gather` provides `research.available` listing valid researchable technologies.
- Schema generator excludes smelted plates from `craft_for.item` and hides `build_ghosts` when `ghosts == 0`.
