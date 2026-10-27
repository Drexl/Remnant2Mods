# Loadout compatibility tests

Run from the repository root with Lua 5.4:

```sh
lua tests/loadout_runtime_test.lua
lua tests/more_loadouts_test.lua
lua tests/more_loadouts_test.lua native
```

The runtime test mocks UE4SS construction notifications and the game-thread
queue. It checks cold-start discovery without resolving the Blueprint class,
filters templates and ownerless panels, waits for eight vanilla tiles, and
bounds readiness work without global scans. It also checks both standalone
copies of `loadout_runtime.lua` remain identical.

The extra-slot test simulates an unsupported multicast read that escapes Lua
`pcall`. It checks the first injection still creates 20 uniquely indexed tiles,
keeps record 10 reserved, and uses the existing forwarding gates. The `native`
mode checks native bindings still work without duplicate forwarding hooks.

These are control-flow regressions, not native-engine tests. For a real check,
launch cold without hot reload, load a character, and open Loadouts once.
Test each mod alone and both together: 20 slots with MoreLoadoutSlots enabled,
and the first F2 editor with LoadoutNamer enabled. Close/reopen the screen too.
Engine behavior on experimental UE4SS, controller navigation, co-op, and full
save/equip/delete/persistence acceptance require separate live tests.
