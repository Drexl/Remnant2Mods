# Tests

Run from the repository root with Lua 5.4:

```sh
lua tests/loadout_runtime_test.lua
lua tests/more_loadouts_test.lua
lua tests/more_loadouts_test.lua native
lua tests/loadout_style_test.lua
```

These tests mock UE4SS. They do not verify native calls or rendered styles.
