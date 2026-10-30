# Blueprint library

The AI builds from these with the `place_blueprint` skill. The bridge owns the
library and syncs it to the mod every 10 seconds while it runs.

- `blueprints/*.json` — starter set that ships with the repo
- `blueprints/local/*.json` — your own and community imports (gitignored)

## Adding blueprints

**In game** (admin): hold a blueprint or a whole book, then

```
/ai-bp add [name] [category]
```

Books are split into one entry per blueprint, named from their labels. Other
commands: `/ai-bp list`, `/ai-bp remove <name>`, `/ai-bp test <name>` (puts the
ghosts next to you to check how it looks).

**From the command line** (repo root):

```
.venv\Scripts\python -m bridge.blueprints import <file | factorioprints.com/view/... link | string>
.venv\Scripts\python -m bridge.blueprints list
.venv\Scripts\python -m bridge.blueprints remove <name>
```

Strings from before Factorio 0.15 (they start with `H4sI`) can't be imported.

## Categories

Each blueprint is sorted automatically from what's in it, which decides where
it gets placed and which goal on the ladder (`bridge/goals.py`) suggests it:

| Category | Placed | Detected from |
|---|---|---|
| power | on a shoreline | offshore pump + boiler/steam engine (solar: clear ground) |
| mining | on an ore patch | mining drills (ore taken from the label, e.g. "iron") |
| smelting | clear ground | furnaces |
| science-red, science-green, ... | clear ground | assemblers set to a science pack |
| oil | on oil wells | pumpjacks |
| oil-processing | clear ground | refinery / chemical plant |
| circuits | clear ground | advanced circuit / processing unit recipes |
| research | clear ground | labs |
| rocket | clear ground | rocket silo |

Override with `--category` on import, or the category argument of `/ai-bp add`.

Small, self-contained builds work best: one job each, with their own inserters
and power poles. The AI connects blocks with `connect_belt`.
