# MoreLoadoutSlots — mod reference

Status: **feature-complete and user-confirmed** as of 2026-07-12 (solo and co-op display; first shipped mod of the project). Source: `MoreLoadoutSlots/Scripts/main.lua`. This doc is the what/why of this mod specifically; engine/UE4SS techniques live in `docs/remnant2-modding-research.md` (the §3.4 series — this mod's build-out IS most of that section).

## What it does

- **20 loadout slots instead of 8** on the Character → Loadouts screen. The count is a single knob: `TOTAL_LOADOUT_SLOTS` at the top of `main.lua`.
- **Record capacity**: on every player spawn (`PlayerController:ClientRestart` hook), all `LoadoutComponent.Slots[].NumRecords` are patched to `TOTAL + 1` (21) so the underlying storage accepts the high record indices.
- **Extra tiles**: when a player-owned Loadouts panel finishes initializing (a native `UserWidget` construction listener filters for `Widget_LoadoutsPanel_C`), 12 extra `Widget_Loadout_C` tiles are created via `WidgetBlueprintLibrary.Create` and appended to the panel's tile list, using record indices **8, 9, 11–20** — record **10 is skipped** (the game's reserved "Last Gear State" auto-save; a visible tile there self-overwrites on every equip).
- **Scrolling**: the panel's fixed 688px tile area only fits 8 tiles, so a runtime-created engine `ScrollBox` is spliced into the widget tree (`SizeBox_0 → ScrollBox → LoadoutList`); overflow tiles are reached with the mouse wheel.
- **Labels**: tiles past the skipped record get a pinned `LabelOverride` so on-screen names run a contiguous "Loadout 9".."Loadout 20" with no gap. (LoadoutNamer's custom names layer on top of this.)
- **Interactions**: each mod tile subscribes the panel's own handlers to its delegates (`OnClicked`/`OnLoadoutSaved`/`OnLoadoutSlotDeleted` → `OnLoadoutClicked`/`OnLoadoutSlotSaved`/`OnLoadoutSlotDeleted`) — the exact bindings the panel gives the tiles it creates itself, so save/load/equip/delete behave 100% vanilla, including the equipped/empty gating and confirmation dialogs. A hook-forwarding fallback path is used on stable UE4SS, which cannot expose the multicast delegate properties to Lua.

## User guide

There is nothing to configure or learn — the extra slots behave exactly like the vanilla eight:

| Input (on a loadout tile) | Action |
|---|---|
| **Left-click** or **Space** | Equip that loadout |
| **Right-click** | Save your current gear into that slot |
| **F** | Delete the slot's contents |

- **Scrolling**: only 8 tiles fit on screen at once; use the **mouse wheel** over the tile list to reach slots 9–20.
- Vanilla rules still apply: you can't overwrite-save onto the currently equipped loadout, and clicking an empty slot does nothing.
- **Persistence**: loadouts saved to the extra slots (including slot 20) survive full game relaunches — they live in the game's own save data, same as vanilla slots. Note this also means gear saved in extra slots stays in your save even with the mod disabled; it's just not visible/reachable until the mod is re-enabled.
- **Changing the slot count**: edit `TOTAL_LOADOUT_SLOTS` in `MoreLoadoutSlots/Scripts/main.lua` and relaunch (or hot-reload and reopen the screen). Anything from 9 up should work mechanically; 20 is the tested value. If you *lower* it, gear already saved in now-hidden slots isn't deleted, just unreachable.
- **Co-op**: browsing and seeing the extra slots while in a multiplayer session works (fixed 2026-07-12). **Saving/equipping the extra slots (9+) while in someone else's game is untested** — do it in your own world until proven safe.

## Key implementation facts

- Record indices: vanilla tiles 0–7, mod tiles 8, 9, 11–20. **Record 10 = the reserved Last Gear State auto-save** — never given a visible tile; `NumRecords` is patched to `TOTAL + 1` to account for it (research doc §3.4w).
- Tiles MUST be created with `WidgetBlueprintLibrary.Create`, not `StaticConstructObject` — the tile class's `ComponentDelegateBinding` (button clicks → tile handlers) is only applied during `UUserWidget::Initialize()`, which raw construction skips (a raw-constructed tile renders but ignores all clicks). The engine `ScrollBox`, a plain C++ widget with no such bindings, is safe to `StaticConstructObject`.
- CreateWidget's owning player comes from `panel:GetOwningPlayer()`, never `FindFirstOf("PlayerController")` — the latter returns a non-local controller in multiplayer and CreateWidget then yields an invalid widget (§3.4cc; `FindFirstOf` survives only as a logged fallback).
- Each tile gets `Index` (record), `LoadoutTemplate` (the `Gear_Loadout` asset), a `LabelOverride` when its record runs ahead of its visible position (FText-wrapped — mandatory), the three delegate subscriptions, then `Refresh()` and `AddChild`.
- Delegate binding failure rolls back any bindings that landed (a half-bound tile on the fallback path would double-fire) and registers the tile in `ourTileFullNames` for the hook-forwarding path: post-hooks on the tile class's mouse bound events + `OnInputAction` (enum: 1 = equip/Space, 3 = delete/F) forward to the current panel's handlers, with manual equipped (`EquippedIconBox:IsVisible()`) and empty (`IsEmpty`) gates re-creating the checks vanilla tiles do pre-broadcast.
- Tile creation waits on a 50ms poll (max 40 attempts) for `panel.LoadoutList` to become valid, then runs in the game thread; a `GetChildrenCount() >= 20` guard makes reruns idempotent. `currentPanel` is re-captured on every panel construction — screen reopens build a fresh panel, and acting on a stale closured one was a real bug.
- `loadout_runtime.lua` listens on the already-loaded `/Script/UMG.UserWidget` ancestor because stable UE4SS resolves notification classes at registration time, before the Blueprint panel class may exist. It filters template objects, deduplicates panels, and briefly waits for eight vanilla tiles and a valid owning player before setup. There is no global discovery scan. Keep the standalone helper identical in both loadout mods.
- The `SizeBox` deliberately keeps its native 688px `HeightOverride`; the ScrollBox handles all overflow.

## Known warts / deliberate scope cuts

- The tile list has no gamepad-focus scrolling guarantee — scrolling was built and tested for mouse wheel (gamepad users may not reach slots 9+; untested).
- Saving/equipping extra slots while in another player's co-op session is untested (H2 — LoadoutComponent write safety was proven with exactly one component instance, solo; a co-op session may hold several locally). Display/browsing in co-op is confirmed fine (§3.4cc).
- Stable UE4SS uses the hook-forwarding fallback path and its equipped/empty gates. Its multicast capability probe runs in a separate native callback: an unsupported property read can escape Lua `pcall`, but must not abort the first tile-injection callback. Experimental UE4SS retains native subscriptions when available.
- The "Loadout N" numbering assumes tiles are only ever appended by this mod; a vanilla patch that changes the base slot count or the reserved-record position (10) would misalign labels and the skip logic.
