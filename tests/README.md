# Tests

Run from the repository root with Lua 5.4:

```sh
lua tests/ui_coexistence_test.lua
lua tests/equipment_search_test.lua
lua tests/loadout_runtime_test.lua
lua tests/game_tick_test.lua
lua tests/loadout_rename_test.lua
lua tests/more_loadouts_test.lua
lua tests/more_loadouts_test.lua native
lua tests/scrollbox_layout_test.lua
lua tests/vanilla_scrollbox_test.lua
lua tests/loadout_style_test.lua
```

`tests/support/ue4ss_mock.lua` models the pinned UE4SS hook contract: UObject access only in game-thread hooks, no `LoopAsync` or `ExecuteInGameThread`, no registration into a hook during its own dispatch, and a native abort ends one dispatch. `remnant_world.lua` models the shipped widget lifecycle. These tests do not verify native calls, real threads, Slate timing or rendered styles.
