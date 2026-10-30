# Seeing what the AI is doing

## In game: the AI panel

Click the **A** button at the top-left, or press **Ctrl+Shift+A** (rebind it in
Settings > Controls). The panel refreshes every second:

- **Status:** where the character is, whether the brain is thinking, idle or
  paused, the current goal from the bridge, the model and how long the last
  turn took (it warns if the bridge has gone quiet), the last summary, and your
  current order.
- **Last actions:** each skill from the last turn, ✔ or ✘ with the reason.
- **Controls:** Spawn, Come here, Pause/Resume, Co-op on/off, Unstick (drops
  in-flight requests).
- **Tell the AI:** the same as typing `ai: …` in chat.
- **Blueprints:** pick one, then *AI place* (the AI finds a spot) or *Preview*
  (ghosts right next to you, to check how it looks). *Add held blueprint*
  exports what you're holding; it shows up after the bridge syncs (about 10 s,
  then *Refresh lists*).
- **Run a skill (no AI):** the same as `/ai-do`, e.g. `gather` + `iron-ore 50`.
- **Recent events:** the last few entries from the debug log, with errors in red.

Buttons that change things are admin-only, like the commands. Hosting a game
makes you admin.

## On the PC: one command

```
.venv\Scripts\python -m bridge.diag
```

It reports, in order:
- **Setup:** model, endpoint, flags, and the local router's mode (if
  `AI_ROUTER_STATE` is set in `bridge/.env`)
- **Model:** whether the endpoint is up and the model is known
- **Mod:** a live snapshot over RCON (character, brain, pending requests, last
  results, blueprints)
- **Mod events:** recent entries, including why `place_blueprint` turned spots
  down and Lua errors with stack traces
- **Errors:** `errors.log` and warnings from `bridge.log`
- **Last turn:** the goal section the model saw, its reply, what was parsed
- **Turns:** success counts and latency

`--events 60` shows more events; `--json` prints everything as JSON.

## The files (script-output/ai-player/)

| File | Written by | What's in it |
|---|---|---|
| `debug.jsonl` | mod | one JSON event per line: request, response, timeout, skill, action, place, measure, error |
| `errors.log` | mod | primitive action errors |
| `chat.log` | bridge | every prompt and raw reply |
| `metrics.jsonl` | bridge | one line per turn: status, latency, factory stats |
| `bridge.log` | bridge | the bridge's own log |

The bridge moves `debug.jsonl`, `chat.log`, `metrics.jsonl` and `errors.log` to
`<name>.1` once they get large. Turn the mod's event log off with the
`ai-player-debug-log` map setting.
