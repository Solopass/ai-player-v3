# Round 20 Gate Results

## Part 0: Gate Infrastructure & Baseline Measurement

### 1. Pytest Unit Tests
```
============================= 146 passed in 6.65s ==============================
```

### 2. Lua Syntax Check (luaparser)
```
=== [GATE] Lua Syntax Check (luaparser) ===
  PASS: 19 Lua files parsed cleanly with no syntax errors.
```

### 3. Baseline Soak Run (Seed 424242, 90m game time at 4x speed)
- **Label**: `baseline-s424242-r1`
- **Game Time**: 90.9 game minutes (real duration: 1362s = 22.7 min)
- **Power Milestone**: reached at **minute 2.1**
- **Lab Row Consuming**: reached at **minute 28.9**
- **Techs Researched**: 4 (`steam-power`, `automation-science-pack`, `automation`, `electronics`)
- **Production Rates (last 10m mean)**:
  - Iron: 29.9 / min
  - Copper: 14.9 / min
  - Red Science: 0.0 / min (unreached on pre-Round 20 HEAD)
  - Green Science: 0.0 / min (unreached on pre-Round 20 HEAD)
- **Flow Faults (last 30m)**: **0**
- **Hand-hauled Items (last 30m)**: 0
- **Mod Errors**: 0 (fixed electric network stats lookup)

### Baseline File
Locked in `docs/scores/baseline.json`.
