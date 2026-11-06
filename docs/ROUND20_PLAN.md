# Round 20: one base plan, tested stamps, a score that gates every change

Implementer: Antigravity. Reviewer: Claude (plan and diff review).
Goal from the player: **the AI gets resources and factories up correctly, with little help.**

## Why change course
Rounds 13–19 added cleanup layers on top of each other:
- coach rewrites;
- guard drops;
- the doctor;
- the flow check and repair.

Each one cleans up after something already went wrong. Since Round 14, no round has been played
or soaked before the live game, so the live game finds the bugs and the next round patches them.
The belt and inserter mess comes from **free placement**: blocks go wherever they fit, and belts
are then routed between them.

Real players pick one base design and grow it. This round makes the AI do the same. It also
makes measurement the gate: a change that lowers the score doesn't get merged.

## Words used in this plan
- **belt** = one belt line.
- **lane** = one side of a belt (every belt has a left and a right lane).
- **base frame**: `u` = distance along the bus, `v` = distance across it (`v < 0` = left side).

## Ground rules (read first)
1. **The gate is not optional.** Every commit runs the quick gate, and every Part ends with the
   full gate (Part 0). Paste the real output into `docs/ROUND20_RESULTS.md`, and never write a
   PASS that isn't in the output.
   - Factorio must be closed for the gate.
   - If the gate can't be run, stop and say so. Don't commit.
   - The gate must never print the env file the soak writes.
2. **Nothing outside this plan.** No new GUI, bunker, speedrun or playbook features this round.
3. **Everything new sits behind the runtime setting `ai-buildbook`, default off.** Old behaviour
   stays the default until the flag-on full gate scores at least as well as flag-off on both
   seeds.
4. **Guardrails from `docs/ROUND13_PLAN.md` still apply:**
   - owned-only (`AIRegistry.is_owned`);
   - every `find_entities_filtered` has an area or radius;
   - state only in `storage`, and `on_load` writes nothing;
   - bounded work per tick;
   - no new `on_nth_tick` for 15/20/30/60/1800;
   - never read or print `bridge/.env`;
   - push only to `solopass`, and only when the player says so.
5. One commit per step. Keep the code style of the file you edit.

## Part 0: the gate and the score (do this first)
**`tests/ingame/gate.py`** (new) has two modes. Both stop at the first hard failure.

- **Quick gate (every commit, about 15–30 min real time):**
  1. `pytest -q`;
  2. the Lua syntax check on `mod/` (luaparser; there's no luac here);
  3. `run_selftest.py <cases the commit touched>`;
  4. one soak: `run_soak.py --no-llm --minutes 45 --seed <A>`.
- **Full gate (end of each Part, and nightly; about 1–3 h):**
  1. pytest;
  2. the Lua syntax check;
  3. `run_selftest.py --all` (add the `--all` flag);
  4. two soaks, `--minutes 90`, seeds A and B (two fixed armed seeds from `SEEDS` in
     `run_soak.py`).
  - A seed that fails gets one rerun, and fails only if both runs fail.

**The score** (extend `evaluate` in `tests/ingame/run_soak.py:285`). Per seed, record:
- **Milestone game-minutes:**
  - power;
  - electric-mining-drill researched;
  - first mining field producing;
  - bus head fed;
  - red producing (red_per_min > 0 from any AI assembler, so red cells and the bus compare);
  - lab row consuming;
  - green producing.
- **Rates:** iron, copper, red and green per min, **each the mean of the last 10 game min**.
- **Other numbers:**
  - techs researched;
  - flow faults over the last 30 min;
  - attention machines as a share of all machines;
  - hand-hauled items over the last 30 min (add a counter to `tend` if it isn't there);
  - Lua errors (`mod_errors`), which must be 0;
  - share of turns made by autopilot.

**Verdict:**
- **Hard fail:** any Lua error, any self-test failure, or a soak hitting `--max-real-min`.
- **Regression against `docs/scores/baseline.json`:**
  - For each number, the threshold is max(5 game min or 10%, 2× the spread seen in the baseline
    runs).
  - Flow faults fail only if they rise by more than 2.
  - A milestone missing from the baseline isn't compared. A milestone present in the baseline but
    missing now fails.
- A part that *intends* to change a number lists it in the results doc. The baseline is updated
  only with `gate.py --accept` after the player or Claude approves.
- Append one line per run to `docs/SCORES.md` (date, commit, seed, flag on or off, key numbers).

**First action:** run each baseline seed **twice** on the current HEAD, to measure spread. Save
the result as the baseline.

Also add `memory/speedrun_playbook.json` to `.gitignore` and `git rm --cached` it, since runs
keep changing it.

## Part 1a: the base frame (`mod/scripts/baseplan.lua`, new)
`Base.to_world(base, u, v)` returns a world position, and `Base.dir(base, d)` rotates a direction.
Use exactly this table, where the bus direction is the direction `+u` points in world space:

| bus dir | world x | world y |
|---|---|---|
| north | origin.x + v | origin.y − u |
| east  | origin.x + u | origin.y + v |
| south | origin.x − v | origin.y + u |
| west  | origin.x − u | origin.y − v |

- Entities with an even width or height, such as splitters (2×1) and assemblers (3×3 odd, centred
  on .5), keep their centre offsets. Put stamp positions at the entity **centre** in the base frame
  and rotate the centre.
- Self-test `base_frame:<facing>`:
  - round-trip `u, v → world → u, v`;
  - place a splitter and an assembler from the frame and check their world positions and
    directions.

## Part 2: stamps (`mod/scripts/stamps.lua`, new)
A **stamp** is code data: a list of `{name, u, v, dir, recipe?}` (entity centres, base frame,
`dir` relative to `+u`), **including every small electric pole**, plus named `ports`
(`in_fe`, `in_cu`, `out`, …). `Stamps.place(name, at_u, side)` turns it into ghosts through
`AILayout.build`. Rotation goes through `Base.to_world` only. Add `opts.ignore_forbidden` to
`can_place` (`mod/scripts/layout.lua:68`), which stamps use inside their own footprint.

**Bus geometry:**
- **The left side only, this round.** Iron trunk to Fe at `v = −2`, copper trunk to Cu at
  `v = −1`. The right side (`+1`, `+2`) comes later and mirrors it.
- **`v = 0`** holds the bus pole line: small poles at most 7 tiles apart.

**Stamps:**
| stamp | what |
|---|---|
| `bus_segment` | Fe belt at v=−2 and Cu belt at v=−1, 14 long, plus poles at v=0 |
| `bus_head` | 2 head ports (Fe, Cu) where trunks join, then the start of both bus belts |
| `tap_outer` (Fe) | splitter on the Fe belt at v=−2/−3. The branch at v=−3 turns outward into the slot's input. |
| `tap_inner` (Cu) | the Fe belt (v=−2) dives underground from u−1 to u+3. The Cu splitter sits at v=−1/−2 at u, and its branch turns outward over the buried Fe. |
| `gear_red` | 2 × `[red asm | inserter | gear asm | inserter | red asm]`. Gears go by direct insertion. One slot input belt carries Fe on one lane and Cu on the other (from the two taps, side-loaded), and belt inserters feed each assembler. Output inserters put red packs on a **science belt** along the slot's outer edge (running along u). |
| `lab_row` | 6 labs along the science belt, with inserters lab-to-lab. Red is on one lane, and green side-loads onto the other lane. |

- **Slot size** is set by the `gear_red` stamp, likely about 14 along u × 22 deep. Measure it once
  the stamp passes and **then** lock it as constants in `baseplan.lua`. The slot order on the
  left side: `L1 = gear_red`, `L2 = lab_row`, `L3 = green` (later).
- **Green this round:** keep the existing `build_green_cell` as the green source. It's fed from
  the bus by tend, and the gate counts its hand-haul. A `green` stamp needs 2 green assemblers +
  1 each of inserter, belt, circuit, cable and gear assemblers for about 10/min. Only start it
  after `gear_red` and `lab_row` pass, with an ASCII layout committed in `stamps.lua` first.

**Stamp tests:** `stamp_<name>:<facing>`, all 4 facings, added to `ALL_CASES`/`FACING_CASES`.
- **Inputs:** `infinity-chest` entities made with `create_entity` and filtered to the input item,
  feeding a short belt to each input port.
- **Power:** an `electric-energy-interface` made with `create_entity`.
- **Building:** the AI character builds the ghosts from an inventory pre-filled with the stamp's
  items.
- **Run** 3 game min with **no tend and no doctor**.
- **Assert:**
  - the output passes a floor (`gear_red`: ≥ 40 red packs in 3 min, which allows for ramp-up;
    `lab_row`: science consumed > 0 on both lanes);
  - `AIFlow.check` over the stamp's owned entities has zero faults.
- **Ownership:** register the test chests with `AIRegistry.own`, or leave them out of the check
  list. `AIFlow.check` skips entities that aren't owned (`flowcheck.lua:246`).

**`mod/scripts/stamps_verified.lua`** is generated by `run_selftest.py --record`: a stamp is
listed only after it passes in all 4 facings. The build book offers only listed stamps.

## Part 1b: the site and reservation (after the stamps pass)
- **Site search:**
  - from `home`, try the 4 bus directions;
  - for each, check a rectangle `(slot depth + 4) × 120` along u, on the left side plus the bus;
  - score it by free tiles per 10×10 chunk inside the rectangle (`count_tiles_filtered` for
    water, `count_entities_filtered` for cliffs and the player's entities; bounded);
  - pick the best one, and shrink the length to the first blocked chunk (at least 60).
- **Store** `storage.ai_player.base = {origin, dir, length, slots = {}, state}`.
- **Reservation:** a `forbidden` list (world boxes of the base) in `can_place` and in the A*
  router used by `connect_belt`/`connect_pipe`/`connect_power`.
  - Every AI placement outside a stamp avoids the base, except trunks entering head ports.
  - The player can still build there. A stamp that finds a player entity in its footprint fails
    with that reason, and its slot is marked `blocked`. Player entities are never cleared.
- **Self-test `base_site`:** water painted on 3 sides; it picks the free side.

## Part 3: resources into the bus
- **Mining fields stay** (`AILayout.find_mining_field`, smelting at the field).
- **Field plate output = a port.** A **trunk** is one belt route from the field's plate-belt end
  to a `bus_head` port.
  - `connect_ports` only knows placed blueprints (`skills.lua:1565`). Extend it to accept
    `{kind = "field"|"base", id, port}` records from `storage.ai_player.fields` /
    `storage.ai_player.base`.
  - This is the only free routing left: A*, undergrounds allowed, the base `forbidden` boxes
    apply except the target head port.
  - The flow check must pass before the field counts as feeding.
- **A second field for the same plate** side-loads onto that trunk through a fixed 3-tile
  side-load piece at the trunk's end. It never joins the bus mid-way.
- **Self-test `trunk_feed`:** a field 40 tiles from a bus head, with plates reaching the right
  bus belt.

## Part 4: the build book (behind `ai-buildbook`)
`bridge/buildbook.py` (new) is an ordered list of steps. Each step has a `done(p)` check from
perception, its prerequisites, and the move to send. With the flag on, the planner's
`_candidates` (`bridge/planner.py:850`) yields the first not-done step whose prerequisites are
done, through the existing sure/autopilot path. With the flag off, nothing changes.
1. Bootstrap (unchanged: the burner phase).
2. Power (`build_power`).
3. Research automation, then electric-mining-drill.
4. Iron field, then copper field.
5. Base site, bus head, 2 bus segments.
6. Trunks: iron to Fe (v=−2), copper to Cu (v=−1).
7. Taps + `gear_red` in L1; `lab_row` in L2.
8. Research logistics, then logistic-science-pack; `build_green_cell` for green.
9. Expansion loop:
   - bus belt rate below demand → a new field + side-load onto the trunk;
   - more slots needed → `bus_segment`;
   - demand comes from `demand_targets`.

**Retiring old code is a separate, later commit.** Do it only when the flag-on full gate scores at
least as well as flag-off on both seeds. Then:
- make the flag default on;
- remove the hand-fed `build_red_cell`, except as a bootstrap before step 7;
- remove autopilot `place_blueprint` of `tileable-*`;
- remove `tend` hauling into bus-fed blocks;
- remove the goal-ladder branches for red and smelting in `planner.py`.

Delete the code rather than commenting it out, and remove the tests that only covered it. The
model may pick among build-book moves and chat; it never places.

## Targets (90-min soak, both seeds, `--no-llm`, 4x, flag on)
| metric | target |
|---|---|
| electric drills researched | ≤ min 15 |
| first field producing | ≤ min 20 |
| bus head fed (both plates) | ≤ min 30 |
| red producing from `gear_red` | ≤ min 35, ≥ 15 red/min by min 60 |
| lab row consuming | ≤ min 40 |
| flow faults (last 30 min) | 0 |
| attention | < 5% of machines |
| hand-hauled items (last 30 min) | only for the green cell |
| Lua errors | 0 |

When a new seed or the player's map breaks something, add that seed to the gate.

## Order and commits
1. Part 0 (gate and baseline). **Tell Claude** before going on.
2. 1a.
3. Part 2, one stamp at a time: `bus_segment` → `bus_head` → `tap_outer` → `tap_inner` →
   `gear_red` → `lab_row`. Each must pass its 4-facing test before the next. **Tell Claude** after
   the stamps pass.
4. 1b, then 3, then 4.
5. The full gate with the flag off and with it on.
6. The retire commit, only if it wins.

`docs/ROUND20_RESULTS.md` gets the real gate output per step.
