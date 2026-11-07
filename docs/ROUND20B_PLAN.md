# Round 20b: make the build book actually run

Implementer: Antigravity. Reviewer: Claude.
All Round 20 ground rules still apply (`docs/ROUND20_PLAN.md`):
- the gate is mandatory, and you paste its real output;
- no features outside this plan;
- everything stays behind `ai-buildbook`;
- one commit per step;
- the Round 13 guardrails: owned-only, no whole-surface scans, state in `storage`, bounded work
  per tick, never read `bridge/.env`, push only to `solopass`.

## Why
Round 20 Parts 0–4 landed, and with the build book **off** nothing got worse (red science went
from 0 to about 1.5/min). But every score row is flag-off: the build book has never run. Reading
the code shows it would stop partway through any real game:

1. **The base site is the burner base.** `Base.find_site` (`baseplan.lua:133`) puts the origin at
   `home`.
   - The burner base is there, so every facing fails at chunk 0 (`player_ents > 2`).
   - It then falls back to "east, length 60" anyway, right on top of the AI's own buildings.
2. **The taps collide with the bus.** The build book places `bus_segment` at u=4, then
   `tap_outer` at u=4 and `tap_inner` at u=6 on top of it.
   - Their splitter and underground land on bus belts that are already there.
   - `clear_spot_for_placement` (`layout.lua:1407`) never clears belts, so the placement fails
     and the build book retries forever.
   - The tap self-tests place each tap on empty ground, so they didn't catch this.
3. **Fields have no plate output.** A real field ends in furnace → inserter → chest, and its
   record (`skills.lua:2096`) has no `ports` and no `plate_output`.
   - Only the self-test fakes one (`selftest.lua:350`).
   - So `connect_ports` falls back to the first drill's position.
   - `field:1` / `field:2` also depend on build order and on the 12-entry cap.
4. **Iron and copper share one lane.** Both taps side-load into gear_red's input belt from the bus
   side, so both plates land on the same lane, and a mixed lane jams when one plate backs up.
   - There's also no build-book step that connects the copper tap at all.
   - The gear_red test fed it with inserters, so the tap → gear_red joint has never run.
5. **Smaller issues:**
   - `_has_field` counts burner drills (3 iron burners make the field step look done).
   - `place_stamp` never checks `stamps_verified.lua`.
   - Progress is read from `connected_belts`, which is capped at 50, so old links drop out and
     the build book redoes them.
   - `base.slots[at_u]` gets overwritten when two stamps share a u.

## Base frame reminder
- **u** runs along the bus ("north" in stamp files).
- **v** runs across it: the bus is at v = −1.5 (Fe) and −0.5 (Cu), poles at v = +0.5, and the
  left-side slots at v ≤ −2.5. "west" in stamp files means −v and "east" means +v.
- A stamp entity at (u, v) placed `at_u = A` lands at (A + u, v).

## Step 1: Site search that avoids the burner base (`baseplan.lua`)
- **`Base.find_site(surface, home, opts)` tries candidate origins,** not just `home`:
  - rings at 24, 40, 56 and 72 tiles from home, 8 points per ring, × 4 facings;
  - stop at the first 12 clear candidates and pick the one closest to home.
- **A candidate is clear when** the whole corridor (u 0..60, v −22..+2) has:
  - no water, no cliffs, no resources (`count_entities_filtered{type="resource"}`);
  - zero entities of the AI's force other than the character.
  Also check a 6×6 approach area in front of the bus head (u −6..0, v −4..+2).
- **No fallback.** If nothing fits, return nil and let `build_base` report it.
- Bound it: at most 32 candidates per call.
- **Self-test `base_site`:** place a fake burner base (8 stone furnaces) around home and assert
  that the chosen corridor contains none of them. Run it in 2 layouts: water to the east, and no
  water.

## Step 2: A bus with no overlaps, plus a lane-split feed (`stamps.lua`, `buildbook.py`)
The taps already carry their own bus belts, so they are **bus pieces** and replace segments
rather than sitting on them.

**Fixed layout** (left side, all u values are `at_u`):

| Stamp | at_u | Bus tiles it covers |
|---|---|---|
| bus_head | 0 | 0–3 |
| tap_inner (Cu) | 4 | 4–7 |
| tap_outer (Fe) | 8 | 8–9 |
| bus_segment | 10 | 10–23 |
| bus_segment | 24 | 24–37 |
| **red_feed (new)** | 6 | slot side only |
| gear_red | 9 | slot side, u 9–22 |
| lab_row | 23 | slot side, u 23–46 |

- Bus continuity: each piece's `out_fe`/`out_cu` sits one tile before the next piece's
  `in_fe`/`in_cu` (3.5 → 4.5, 7.5 → 8.5, 9.5 → 10.5, 23.5 → 24.5).
- tap_outer's `tap_fe` lands at (9.5, −3.5) facing west, so it drops straight into gear_red's
  first input tile **S = (9.5, −4.5)** from the +v side.
- tap_inner's `tap_cu` lands at (6.5, −3.5) facing west.

**New stamp `red_feed`** brings copper around to the other side of S, so the two plates end up on
different lanes:
```
-- red_feed, entities relative to at_u (placed at at_u = 6)
{name="transport-belt", u=0.5, v=-4.5, dir="west"},   -- Cu from tap_inner keeps going -v
{name="transport-belt", u=0.5, v=-5.5, dir="north"},  -- curve
{name="transport-belt", u=1.5, v=-5.5, dir="north"},
{name="transport-belt", u=2.5, v=-5.5, dir="north"},
{name="transport-belt", u=3.5, v=-5.5, dir="east"},   -- curve, then into S from the -v side
{name="transport-belt", u=2.5, v=-4.5, dir="north"},  -- "L": feeds S head-on, so Fe and Cu
                                                      -- arrive as true side-loads, not curves
-- length = 4, depth = 6, no ports needed (it is fixed to gear_red at at_u - 3)
```
- **Why it works:** a belt that has another belt directly behind it takes side-loads onto the
  near lane only. Fe arrives from +v (from tap_outer) and Cu from −v (from red_feed), so they
  land on opposite lanes.
- Without "L", S would turn into a curve, and Fe would fill both lanes.
- Check that the tile (7.5, −4.5) stays empty, and that nothing in gear_red sits at
  (9.5, −5.5) or (9.5, −6.5) (from the stamp file it doesn't).
- Add a `stamp_red_feed` self-test (4 facings) like the other stamps, then rerun
  `--record-stamps`.

**Build book changes** (`buildbook.py`):
- `base_frame` places bus_head@0, tap_inner@4, tap_outer@8, bus_segment@10, bus_segment@24.
- `red_and_lab` places gear_red@9, red_feed@6, lab_row@23, then connects
  `gear_red:out_science` → `lab_row:in_science`.
- Delete the `tap_outer → gear_red` connect_ports step: the feed is now part of the stamps.

## Step 3: Fields with a plate output belt (`layout.lua`, `skills.lua`)
- **New build_miner option `plate_belt=true`** (only used with `output="field"`; add it to
  `OPTIONAL["build_miner"]` in `bridge/schema.py`).
  - In `find_mining_field`, each furnace's output inserter drops onto a plate belt instead of a
    chest.
  - The belt runs along the furnace column and ends one tile past the last furnace.
  - Pole coverage and the flow check stay as they are.
  - Without the option, nothing changes, so flag-off games are untouched.
- **The field record stores**
  `ports = {plate_output = {x, y, dir, kind="belt", item=<plate>}}` (the last belt tile and its
  direction) and an `id`.
- **`resolve_port` accepts `field:<resource>`,** for example `field:iron-ore`: the newest field
  of that resource that has a `plate_output` port.
  - If none exists, fail with a reason. Delete the fallback to `f.position`.
- **`fields_report` adds `has_output = (f.ports ~= nil)`.**
- **Build book:**
  - `build_miner{resource, output="field", plate_belt=true}`;
  - `_has_field` is true only for a `fields[]` entry with that resource and `has_output`. Delete
    the `miners_by_resource` fallback;
  - trunks use `from_bp="field:iron-ore"` / `"field:copper-ore"`.

## Step 4: Progress records that don't fall off (`skills.lua`, `perception.lua`, `buildbook.py`)
- **`storage.ai_player.base_links`:** a map keyed `"<from>:<port>-><to>:<port>"`, uncapped (it
  only holds build-book links).
  - `connect_ports` writes it whenever `to_bp` or `from_bp` is a stamp, `base` or a field.
  - Perception sends it as `base_links` (a list of keys).
  - `_has_trunk` / `_has_feed` read only `base_links`.
- **`_has_stamp` reads only `placed_stamps`.** Drop the `base.slots` fallback.
  - In `place_stamp`, key `base.slots` as `name .. "@" .. at_u`, so two stamps at the same u
    don't overwrite each other.
  - Before placing, skip (return ok, "already placed") when a matching record exists and its
    entities are still valid.
- **`place_stamp` refuses** a stamp whose name is not `true` in `stamps_verified.lua`, with the
  detail "stamp X not verified".

## Step 5: One test of the whole chain (`selftest.lua`, `run_selftest.py`)
**`base_red_chain`, 4 facings, `delay` long enough for 4 game minutes:**
- Build a fixed base (origin chosen by the test, not by `find_site`).
- Through the **`place_stamp` skill** (not `Stamps.place`), in build-book order, place every
  stamp from Step 2's table. Then call `connect_ports gear_red:out_science → lab_row:in_science`.
- Feed the bus head:
  - one infinity chest + 2 inserters onto a belt at (−0.5, −1.5) facing north (iron);
  - the same at (−0.5, −0.5) for copper.
- Power: electric-energy-interface next to the bus head pole.
- Run with no tend and no doctor. Assert:
  - every placement succeeded;
  - **lanes at S (9.5, −4.5)** after 2 game minutes: one transport line holds only iron-plate
    and the other only copper-plate (`belt.get_transport_line(1/2).get_contents()`; an empty
    line counts as fine);
  - gear_red made at least 40 red packs (`products_finished`);
  - at least 1 lab has science in its input or `force.research_progress > 0` (start a red-only
    tech);
  - `AIFlow.check` on owned entities: zero faults.

**`trunk_feed` (rework the existing one), 2 facings:**
- `build_miner{resource="iron-ore", output="field", plate_belt=true}` on a small test patch
  beside a base;
- then `connect_ports field:iron-ore/plate_output → base/in_fe`;
- assert iron plates reach the bus belt at u = 10.5 within 3 game minutes.

Add both to `ALL_CASES` / `FACING_CASES`.

## Step 6: First run with the build book ON
1. **Quick gate with the flag on:**
   `.venv/Scripts/python tests/ingame/gate.py --mode quick --buildbook` (seed A, 45 min).
2. In `ROUND20_RESULTS.md` paste:
   - the score line;
   - which build-book step it reached, and when;
   - the last 20 build-book moves with their results (from debug.jsonl);
   - any step that repeated more than 5 times.
3. **Stop there and tell Claude.** No full gate and no retiring code until that's reviewed.

**Separately (needs Factorio closed, best overnight):** bring the baseline up to the plan,
flag off: `gate.py --baseline-only --runs-per-seed 2` on seeds A and B, then `--accept`. The single-run baseline can't give a spread.

## Order and done
Steps 1 → 5 one commit each, then Step 6. For each step:
- pytest green;
- the Lua syntax check;
- the touched self-tests with their real output pasted;
- the quick gate flag-off (to prove nothing regressed).

If a self-test fails twice for the same reason, stop and tell Claude rather than adjusting the
test until it passes.
