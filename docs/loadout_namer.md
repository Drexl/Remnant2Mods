# LoadoutNamer — mod reference

Status: **feature-complete and user-confirmed** as of 2026-07-13. Source: `LoadoutNamer/Scripts/main.lua`. This doc is the what/why of this mod specifically; engine/UE4SS techniques live in `docs/remnant2-modding-research.md` (§3.4y, 3.4z, 3.4aa, 3.4bb).

## What it does

- **Rename**: hover a loadout tile on the character screen, press **F2** → an `EditableTextBox` styled to the game's look (GFGRemnantCracked font 10, ashen 0.85 text, dark translucent fill) replaces the title text in the tile's title row. **Enter/F2** commits, **Escape** cancels, committing empty removes the custom name.
- **Display**: names render via `tile.LabelOverride` + `Refresh()`, re-applied instantly whenever the panel is constructed, to whatever tile count exists at that moment — then reapplied if the count changes (MoreLoadoutSlots' synchronous tile injection landing after; fixed 2026-07-17, see Warts). Tile shows at most 18 chars (`..`-truncated); the hover tooltip's title (`ItemLabel`) shows the full name (cap 32).
- **Tooltip integration**: title swap per hover, plus an "F2 Rename" prompt injected into the tooltip's `ExtraActionList` action row (hidden on the Last Gear State tile).
- **Persistence**: `ue4ss/Mods/LoadoutNamer/loadout_names.txt`, tab-separated `recordIndex<TAB>name` lines, whole-file rewrite on every commit. Tabs/newlines stripped from names on commit.
- **Tab-hotkey suppression**: during an edit, the Traits/Inventory/Map tab buttons are set Hidden (visibility 2, keeps layout space) so T/I/M can't yank the menu; restored on every exit path. Confirmed necessary 2026-07-14: EquipmentSearch proved a focused, character-receiving text box does NOT block the hotkey dispatch (TODO.md, research doc §3.6c). The live `Widget_InGameMenu_C` is found via `FindAllOf` filtered to `IsVisible()` instances (fixed 2026-07-17, see Warts) — not "whichever non-default instance came last."

## User guide

**Keybinds** (active on the Character → Loadouts screen):

| Key | Action |
|---|---|
| **F2** (while hovering a tile) | Start renaming that loadout |
| **Enter** or **F2** (while editing) | Commit the new name |
| **Escape** (while editing) | Cancel, keep the old name |

**How to rename a loadout:**

1. Open the character screen and go to the Loadouts panel.
2. Hover the mouse over the loadout tile you want to rename.
3. Press **F2**. The tile's title text is replaced by a text box (dark fill, game font). It already has keyboard focus — just type.
4. Press **Enter** (or F2 again) to save, or **Escape** to cancel.
5. To remove a custom name, rename the slot and commit with the box empty — the tile returns to its default label ("Loadout N" / the archetype-combo name).

**What to expect on screen:**

- **Name length**: names can be up to 32 characters. The tile itself shows at most 18 — longer names are cut off with `..` on the tile, but the hover tooltip's title always shows the full name.
- **Tooltip**: hovering a tile shows its tooltip with the custom name as the title and an **"F2 Rename"** prompt in the action row at the bottom, alongside the game's own prompts.
- **While editing**: the Traits/Inventory/Map tab labels at the top of the menu fade out — this is intentional, so typing T/I/M doesn't switch tabs. They come back as soon as the edit ends.
- **Last Gear State**: the auto-save slot cannot be renamed — F2 does nothing on it and its tooltip shows no Rename prompt.
- **Persistence**: names are saved immediately on commit and survive relaunches. They are shared across all characters on this install.

## Key implementation facts

- Record indices: vanilla 0–7, mod tiles 8, 9, 11–20; **record 10 is the reserved Last Gear State auto-save** — F2 refuses it and the tooltip prompt hides on it.
- Default labels: records ≤ 10 regenerate natively from an empty override; records > 10 must get back MoreLoadoutSlots' pinned `"Loadout N"` (N = record index) when a custom name is removed.
- Hover identity comes from the `Widget_Loadout_C` OnMouseEnter bound-event hook (`..._4_OnAdvButtonClickedEvent...`); the hook body only does `self:get()` + an `Index` property read.
- The rename box lives in the title row (`tile.Label:GetParent()`); the label is blanked and its width reservation released via `SetMinDesiredWidth(0)` for the edit, restored to 130 after (real setter mandatory — H4).
- Tooltip work runs on a ~1s 50ms poll per hover (`FindAllOf("Widget_LoadoutTooltip_C")`, skip `Default__`), superseded by a generation counter on the next hover. Prompt widgets are tracked per tooltip instance (`ExtraActionList` full name).
- Names file path is probed from two candidates at load because the game's io CWD is the exe dir; the `ue4ss/Mods/...` prefix is the one that resolves on the current install.

## Known warts / deliberate scope cuts

- U/J/O/P/B menu hotkeys are unsuppressed and appear harmless while typing (unexplained, given T/I/M demonstrably needed suppression — see TODO.md).
- Edit box is still an engine `EditableTextBox` with tinted default brushes — close to native, not pixel-identical (no cracked border art).
- Names are per-install, not per-character/save: all characters share the record-index → name map.
- Multiplayer: rename flow untested in co-op sessions (tooltip/panel paths follow the GetOwningPlayer rule, so no known hazard — just unverified).
- **Fixed 2026-07-17**: `suppressTabHotkeys` used to find the menu via `FindAllOf("Widget_InGameMenu_C")`, taking whichever non-`Default__` instance came last in the results, with no logging if none were found. Reported as an intermittent, unreproducible failure to hide the T/I/M tabs (typing a name containing M would navigate to the Map tab mid-rename). Root cause: `FindAllOf` has no guarantee of returning only the live on-screen instance — stale instances can linger (same GC-timing class as the tooltip per-instance-tracking issue, research doc §3.4bb) — so the "last" one picked was sometimes the wrong (or no) menu, silently.
  - First attempt: replaced the search with a `GetParent()` walk up from the actual tile being renamed, reasoning that the tile's own hierarchy must lead to its true owning menu. Wrong: confirmed via a logged chain (`Widget_Loadout_C -> VerticalBox -> ScrollBox -> SizeBox -> VerticalBox -> RemnantCursorPanel -> Overlay -> CanvasPanel -> invalid`) that `GetParent()` only walks nesting *within* one UserWidget's own internal tree — it dead-ends at `Widget_LoadoutsPanel_C`'s own root `CanvasPanel` every time, because crossing into the tree that embeds a nested UserWidget (`Widget_Equipment_Stats_C`, then `Widget_InGameMenu_C`) isn't a parent-slot relationship at all. This failed 100% of the time (worse than the bug it replaced) — abandoned.
  - Actual fix: kept the global `FindAllOf("Widget_InGameMenu_C")` search, but disambiguate candidates with `IsVisible()` (only the on-screen instance should return true) instead of "whichever came last" — reusing the same visibility-gating technique this file already relies on for the tab hotkeys themselves (§3.4aa), rather than an unproven new API path. Also now logs a warning if suppression fails instead of failing silently.
  - EquipmentSearch had copied this same broken version verbatim (its file header calls it "LoadoutNamer's proven trick") — ported the identical fix there too (2026-07-17), plus the same instance-count/visibility diagnostic logging. General pattern write-up (for future mods that need "find my one live instance of widget class X"): research doc §3.4aa.
- **Logging hardening pass (2026-07-17)**, same session as the fix above, applied to all three shipped mods once the value of the diagnostic logging that solved it became clear: `endRename`'s previously-silent pcalls (reading the box's committed text, removing the box, restoring the label's width) now warn on failure instead of failing invisibly; `restoreTabHotkeys`/`suppressTabHotkeys` report a suppressed-count if it's less than expected; MoreLoadoutSlots' per-slot `NumRecords` patch loop (silent before) now warns if any slot failed to patch. None of this changes normal-path behavior or log volume — every added line only fires on the anomalous case.
- **Fixed 2026-07-17**: `applySavedNames` used to gate its *first* apply on the panel's tile count reaching `EXPECTED_TILES = 20` (MoreLoadoutSlots' target). Without that mod active the vanilla panel only ever has 8 tiles, so the gate never passed and the pass burned its full ~4s poll timeout before falling through and applying anything — a couple-second visible delay on every panel construction, present regardless of relaunch/hot-reload/reopen because it was deterministic, not a timing fluke. Root cause: the wait was never actually needed for correctness — the apply pass only ever writes tiles that already have a saved name (`names[idx]`), so it can never race MoreLoadoutSlots' default-label writes on tiles it hasn't named yet, in either hook-registration order. Fix: apply immediately on the first tick to whatever tile count already exists (idempotent, so this is safe and cheap), then keep polling only to catch a later count change — MoreLoadoutSlots injects its extra tiles synchronously in one jump (8→20), never gradually, so at most one more re-apply ever fires. Vanilla case is now instant; MoreLoadoutSlots case is unchanged (still resolves the moment the count hits 20).
