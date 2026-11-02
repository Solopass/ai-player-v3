# Round 13 plan for Antigravity: hold the base, prove the late game, stop hand-hauling, and master underground routing

## What happens with this plan
After approval, it's saved in the repo as `docs/ROUND13_PLAN.md`. Antigravity builds it. Afterwards Claude reviews the diff the same way rounds 7–12 were reviewed.

## Context (for Antigravity)
- **The repo:** `D:\Workspace\factorio-ai-bridge`, branch `ai-bridge-setup`, fork
  `Solopass/ai-player-v3` (both branches at 8836dbf). It's a Factorio 2.1.24 AI co-op player:
  a Lua mod in `mod/`, a Python bridge in `bridge/`, a local LLM via the router at
  `http://127.0.0.1:11440/v1`.
- **Layers:**
  - reflexes in the mod (`mod/scripts/reflexes.lua`, always on);
  - the autopilot planner in the bridge (`bridge/planner.py`, `sure` moves skip the LLM);
  - the LLM for strategy and chat orders.
- **Testing:**
  - `tests/ingame/run_selftest.py`: headless one-skill cases on lab tiles,
    `mod/scripts/selftest.lua` and `selftest_reflex.lua`;
  - `tests/ingame/run_soak.py`: whole games on generated maps with `--raids --mediums --nests
    --enemies --kill-bridge-at --combat --llm`;
  - pytest: 110 tests.
- **Known weak spots** (from soaks and reviews):
  1. **Medium biters wreck the base.** In a 60-minute raid soak, 33 AI buildings were lost.
     Pistol and plain ammo barely hurt mediums, and turrets only exist where `build_defense`
     put them.
  2. **The late game is unproven.** Rounds 7–12 added steel, oil, pumpjacks, robotics and blue
     science, but no soak has shown the chain getting there. Only seed 424242 was ever soaked.
  3. **No tests for routing:** `connect_pipe`, `connect_belt`, the offshore pump search and A*
     only had a syntax check after the review rewrite.
  4. **Hand hauling:** `tend` carries plates into the red/green cells and packs into labs. It's
     slow, and it stops entirely when the bridge is down.
  5. **No recovery:** after a raid, destroyed AI buildings stay gone, and after a death the
     corpse's items are lost.
  6. **Electric mining setups & belt routing struggle on ore patches:** it struggles to place clean
     drill setups on ore patches and connect belts cleanly. It needs to pick up/deconstruct
     obstructing entities and utilize underground belts (`underground-belt`) and underground pipes
     (`pipe-to-ground`) to cross intersecting lines cleanly rather than dead-ending or refusing routes.

## GUARDRAILS (Antigravity must follow all of these)
1. **Ownership:** the AI only touches entities it placed:
   - `AIRegistry.is_owned` = in `storage.ai_player.owned` and `last_user == nil`;
   - never empty, refuel, mine or reroute a player's entity;
   - only ghosts with `last_user == nil` become AI-owned when built.
2. **No whole-surface scans** in anything that runs often (reflexes, tend, perception). Every
   `find_entities_filtered` needs an `area` or `radius`, or iterate the owned registry instead.
3. **Determinism:**
   - all mutable state lives in `storage`, never in module-level locals;
   - no `os`/`io`/unseeded randomness;
   - settings are runtime-global;
   - `script.on_nth_tick(n)` replaces any other handler for the same n. In use already: 15
     (reflexes), 30, 60, 1800. Check before adding one.
4. **Bounded per-tick work:** cap searches (A* has a 400-node cap; the pump search widens
   20/40/64). No unbounded loops on the game tick.
5. **Round-6 guarantees stay:**
   - the combat gate pauses turns during fights, capped at 2.5 min;
   - a player's chat order is never lost and waits at most 30 s;
   - death backoff (30 s → 5 min) and a safe respawn spot;
   - the protect radius is 64 tiles, and combat hops are at most 30 tiles.
6. **Safety in tests:**
   - harnesses refuse to start while any `factorio.exe` runs;
   - temp write-data, loopback only, a random RCON password, a temp mods dir (never copy
     `mod-settings.dat`);
   - never read, print or edit `bridge/.env`;
   - never touch `%APPDATA%\Factorio\saves`;
   - armed test commands work only on the armed seeds with zero players.
7. **Git:**
   - commit per feature, with clear messages;
   - push only to the `solopass` remote, never `origin` (thedemon117's upstream);
   - nothing secret, personal (no `C:\Users\...` paths) or generated gets committed
     (`soak-out/`, `debug_sprint/`, `memory/leaderboard.json` are gitignored).
8. **Every feature ships with a self-test case,** and every behavior change keeps pytest green.
   After mod edits, copy `mod/` to `%APPDATA%\Factorio\mods\ai-player-v3_0.5.0`.

## Work items (in this order)

### 1. Tests for the untested routing (small, do first)
New self-test cases in `mod/scripts/selftest.lua`:
- **`connect_pipe`:** a clean route between two points around an obstacle. A route next to
  another fluid network must be refused, never merged.
- **`connect_belt`:** a clean route. It must refuse to cross or join an existing belt mid-route.
- **`pump_search`:** a lake 30 and 60 tiles away gets found; no lake within 64 gives a clean
  failure.
- **`astar_cap`:** an impossible route fails fast. Log the tick time from `game.create_profiler`
  in the result.

Done when all four pass in all relevant facings.

### 2. Robust Electric Mining Setups & Underground Routing
- **Electric drill patch layout:**
  - Support high-throughput row layout on ore patches: rows of electric mining drills outputting onto
    a shared transport belt with small electric poles.
  - Automatically deconstruct or clear blocking obstacles (trees, rocks, dead burner drills, loose items)
    in the footprint before placing electric drill rows.
- **Underground Belts & Underground Pipes:**
  - Enable `connect_belt` and `connect_pipe` to use `underground-belt` (max span 4 tiles for basic yellow)
    and `pipe-to-ground` (max span 10 tiles) when crossing intersecting lines, buildings, or obstacles.
  - Prioritize underground belts for factory bus crossings so belts never get blocked by perpendicular runs.
  - Prioritize underground pipes for long fluid runs to maximize fluid flow and keep terrain traversable.

### 3. Base defense that holds against mediums
- **`build_defense site="perimeter"`:** a turret ring around the AI's base bounding box (the
  owned registry's extent + 8 tiles), weighted toward the nearest nests and the last attack
  direction. One gun turret per about 12 tiles of perimeter facing nests, in pairs. Stone walls
  (when researched) 2 tiles outside the turrets, with a gap for the AI.
- **Ammo supply** without the bridge:
  - one assembler making magazines next to the base (piercing once researched);
  - reflex `light_tend` keeps every owned turret at ≥ 20 rounds from that assembler's output
    and the AI's inventory, rotating so each pass touches at most 30 turrets.
- **Research priority:** put `military-2` (piercing ammo), `stone-wall`, `gun-turret` and
  `physical-projectile-damage-1/2` / `weapon-shooting-speed-1/2` into the shared Lua
  RESEARCH_ORDER right after red science is automated, when enemies exist on the map
  (`perception.threat`).
- **Repair:**
  - the AI crafts repair packs (repair-pack recipe);
  - a reflex every 10 s repairs owned entities below 70% health within 30 tiles of the AI.
    There's no "repair" call for a character, so raise `entity.health` (writable) by the pack's
    repair amount and remove one repair pack per 300 HP restored. Read the amount from
    `prototypes.item["repair-pack"]`; check the exact field in the 2.1 docs.
- **Planner:**
  - a `defense` rule after red science, when enemies are on the map;
  - more turrets when `last_attack` is newer than 5 min and losses happened.
- **Self-tests:**
  - `perimeter`: a ring is placed, loaded and powered where needed;
  - `ammo_feed`: turrets refilled from the assembler output with no bridge;
  - `repair`: a damaged owned furnace gets healed, a damaged player furnace doesn't.
- **Soak target:** `--raids --mediums` 60 min. AI buildings lost ≤ 5 (was 33), AI deaths ≤ 3.

### 4. Recovery after raids and deaths
- **Rebuild:** when an owned entity dies (`on_entity_died` or `on_object_destroyed`), record
  `{name, position, direction, recipe}` in `storage.ai_player.rebuild` (cap 200). A tend step
  (and a planner `sure` move) re-places them once the area is calm, with no enemy within
  40 tiles. Drop entries older than 30 min.
- **Corpse loot:** on the AI's death, remember the corpse position. After respawn and once the
  area is calm, a reflex goes there and takes everything (`character-corpse` inventory).
- **Self-tests:**
  - `rebuild`: kill 3 owned machines and they come back;
  - `corpse`: kill the AI with items, and its items come back.

### 5. Belts instead of hand hauling for the science cells
- Give the red cell (and green if the lab bus doesn't already feed it; check what round 9
  built) a belt input from the nearest owned smelter output chest:
  - an inserter onto a belt;
  - the belt routed with `connect_belt`;
  - inserters into the cell's input chests.

  Output packs go to the labs by belt or an inserter chain.
- `tend` keeps hauling only for cells that have no belt feed, and flags `fed_by_belt` per cell
  in perception.
- **Bridge-down:** a reflex moves packs from cell output chests into the labs (owned only,
  capped), so research continues with the bridge killed.
- **Self-test** `belt_feed`: the cell keeps producing for 2 game minutes with no tend calls.
- **Soak:** `--kill-bridge-at 20` → research keeps progressing (techs count rises after
  minute 20).

### 6. Prove the late game across seeds
- Soak all 4 armed seeds, `--no-llm`, 120 game minutes at 4x (`--enemies` off).
- Report the milestone minute for each of red, green, steel, oil, plastic, red circuits, blue.
- Fix the first failure on each seed (time-box: 3 iterations per seed). Add a self-test for
  every fix that can be reproduced on lab tiles.
- **Target:** every seed reaches green; at least 2 of 4 reach oil.

### 7. LLM comparison (only if time is left)
- `run_soak.py --llm --model <preset>` for each model in the control panel's dropdown, 30 game
  min at 1x, seed 424242.
- One table:
  - model, red/green minute;
  - LLM turns, overrides;
  - bad moves (failed or blocked);
  - average seconds per turn.
- Save it as `docs/MODEL_COMPARISON.md`.

## Not this round
- walking instead of teleporting;
- trains;
- quality;
- planets;
- the speedrun loop (leave it as it is).

## Verification (Antigravity runs these, then Claude reviews)
1. pytest green, and the Lua syntax check on every edited `.lua`.
2. The full self-test suite passes (all old cases plus the new ones from items 1–5).
3. Soaks:
   - `--raids --mediums` 60 min: ≤ 5 AI buildings lost, ≤ 3 deaths;
   - `--kill-bridge-at 20`: research keeps rising;
   - the 4-seed late-game table from item 6.
4. A short `docs/ROUND13_RESULTS.md` with the soak numbers and anything not done.
5. **Then the user asks Claude to review the diff.** Push to the fork only after that review.
