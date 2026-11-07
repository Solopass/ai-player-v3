# Round 21: the model sees problems in words and picks the fix

Implementer: Antigravity. Reviewer: Claude.
**Start only after the 20b Step 6 soak (build book ON) has been reviewed.**
Round 20 ground rules apply:
- the gate is mandatory, with real output pasted;
- one commit per step;
- everything is behind settings;
- the guardrails (owned-only, bounded, state in `storage`, no `bridge/.env`, push only to
  `solopass`).

## Idea
Code finds problems exactly and carries out fixes exactly. The model reads a short plain-words
list of problems, picks a named fix from an allowed list, and tells the player what it's doing.
The model never gets coordinates and never places entities by hand.

## Step 1: Problem detector (`mod/scripts/problems.lua`, new)
- `AIProblems.scan()` runs inside the existing 60-tick handler, round-robin, at most 20 owned
  entities per pass.
- It keeps `storage.ai_player.problems`, keyed by a stable id. Each entry holds
  `{id, kind, where, since_tick, cause, fixes = {...}}`.
- **Kinds** (each detected from data we already have):

| kind | detected from | allowed fixes |
|---|---|---|
| `starved:<stamp>:<item>` | crafter `status == item_ingredient_shortage` for 3+ min, mapped to its stamp | `rebuild_link`, `add_field`, `wait` |
| `output_full:<stamp>` | `full_output` for 3+ min | `extend_consumer`, `add_lab_row`, `wait` |
| `field_low:<res>` | `fields_report` remaining < 20% | `add_field` |
| `trunk_broken:<res>` | a belt in a `base_links` trunk is missing or invalid | `rebuild_link` |
| `no_power:<area>` | `no_power`/`low_power` on owned entities for 1+ min | `add_power`, `fuel_power` |
| `flow_fault` | AIFlow faults the doctor couldn't repair | `rebuild_stamp`, `ask_player` |
| `blocked_by_player` | a player entity in a reserved slot or trunk path | `move_slot`, `ask_player` |
| `under_attack` | attack events near owned entities | `build_defense`, `repair` |

- `where` is a name, not coordinates: `"gear_red@9"`, `"iron trunk"`, `"copper field 2"`.
- A problem clears when its condition has been gone for 1 minute.
- **Self-tests:** for each kind, make the condition happen, check it appears with the right
  fixes, remove the condition, and check it clears.

## Step 2: Repair skills (`skills.lua`)
Each repair skill is named, carried out by code, and refuses with a reason when it doesn't apply:
- `rebuild_link{link}`: rerun `connect_ports` for that `base_links` key, after mining whatever
  is left of the old route.
- `add_field{resource}`: build another `plate_belt` field and side-load it onto the existing
  trunk.
- `rebuild_stamp{slot}`: mine the stamp at that slot and place it again.
- `add_lab_row` / `extend_consumer`: the next free slot, from the build book's own table.
- `add_power`: one more boiler and 2 engines on the existing offshore line.
- `move_slot{slot}`: mark the slot dead and use the next free one.
- `ask_player{problem}`: a chat line plus an alert. Rate-limit it to once per problem.
- **Self-test per skill:** cause the problem, run the skill, and check that the problem clears
  within 3 game minutes.

## Step 3: What the model sees and may choose (`bridge/prompt.py`, `schema.py`, `coach.py`)
- **The prompt gets a `PROBLEMS` block:** at most 5 problems, oldest first. Each is one line:
  `starved: gear_red@9 lacks copper-plate for 4 min (copper lane empty). fixes: rebuild_link copper trunk | add_field copper-ore | wait`
- **The schema lets the model pick a fix only from that problem's list.** The coach drops
  anything else (counted as `drop_bad_fix`).
- **Who acts first:**
  - When the problem list is empty, the build book drives as now and the model only comments.
  - When there are problems, the model's fix choice goes before build-book moves.
  - The autopilot falls back to the first listed fix if the model gives no valid answer within
    2 turns.
- The model has to give a one-line reason, which shows in the HUD and in chat.
- New setting: `ai-model-repairs` (default on once the gate shows it helps).

## Step 4: Measure it
Add to the gate's score:
- `problems_opened`, `problems_fixed`;
- `median_minutes_to_fix`;
- `fixed_by_model` vs `fixed_by_fallback`;
- `ask_player` count.

**Chaos soak** (`run_soak.py --chaos`) does 3 scripted breaks during the run:
- mine 3 belts of the copper trunk at min 30;
- deplete the iron field to 10% at min 45;
- place a player chest in the next free slot at min 50.

**Pass when:**
- every break gets fixed within 10 game minutes, with zero `ask_player` for the first two;
- the normal gate doesn't get worse.

**Compare** the model choosing (`ai-model-repairs` on) against the fallback only (off). Keep the
model choosing only if it fixes things at least as fast.

## Order
Step 1 → 2 → 3 → 4, one commit each. Stop and tell Claude after Step 1, and after the first chaos
soak.
