# EquipmentSearch — mod reference

Status: **feature-complete and user-confirmed** as of 2026-07-14. Source: `EquipmentSearch/Scripts/main.lua`. This doc is the what/why of this mod specifically; engine/UE4SS techniques and the discovery trail live in `docs/remnant2-modding-research.md` (§3.6, 3.6a, 3.6b, 3.6c). Cold-start maintenance handoff: `dev-docs/EQUIPMENT_SEARCH_COLD_START.md` (local, gitignored). The native-widget listener fix passes mocked tests and a cold first equipment-screen test on stable UE4SS v3.0.1. The user reported that it works, and the live log confirms setup and filtering without a hot-reload. Inventory-tab lists and other input modes have not been separately live-verified for this change.

## What it does

- **Search bar**: the game's own shipped-but-hidden search bar (`Widget_InventorySearchFilter` inside every `Widget_InventoryList_C`) is made permanently visible on all inventory item grids — rings, amulets, armor, relics, weapons, plus the Inventory tab's materials/quest/usable lists. Its vestigial category dropdown (leftover dev-test options) is collapsed; the W-filters menu already covers category filtering.
- **Filtering**: live per keystroke, substring match against item **name AND gameplay-effect text** ("grey health" finds every ring whose effect mentions grey health). Lore — the `Description` paragraph and `FlavorText` quote — is deliberately excluded: search is gameplay-only. Non-matching cards collapse so matches flow together; the X button (or emptying the box) restores the full grid.
- **Tab-hotkey suppression**: while the search box has keyboard focus, the menu's Traits/Inventory/Map tab buttons are set Hidden (visibility 2, keeps layout space) so typing t/i/m can't yank the menu to another tab; restored when focus leaves. Engages on click-in, before the first keystroke.
- **Debug commands** (typed into the search box; kept in the shipped mod): `!<word>` prints the full cached text of every matching item, `!!` clears the text cache, `!?` lists items whose cache is name-only — the after-a-game-patch health check (0 of 213 rings as of 2026-07-14).

## User guide

### Using the search bar

- The bar sits at the top of every inventory item grid (rings, amulets, armor, relics, weapons, and the Inventory tab's materials/quest/usable lists). **Click into the box and type** — the grid filters live on every keystroke; no Enter needed (Enter does nothing extra).
- **Clearing**: click the **X button**, or delete the text. An empty box always shows the full grid.
- The filter is per-list: each grid has its own box and its own active query.

### Search logic

- **Case-insensitive plain substring** match — no wildcards, regex, or word-order tolerance. A multi-word query is one exact phrase: `grey health` matches "…of grey health…"; `health grey` matches nothing.
- **What's searched** per item: the **name**, the **type line** (e.g. "Ring"), and the **gameplay-effect text** — the sentences the tooltip shows, including numbers (`15%`, `3m` are searchable).
- **What's deliberately NOT searched**: the lore paragraph and the quoted flavor text. The search is gameplay-only by design.
- Formatting is invisible to matching: the game's color/stat markup and line breaks are stripped before comparison, so phrases match even where the tooltip styles or wraps mid-phrase.

### Keys while typing

- **T / I / M** (Traits/Inventory/Map tab hotkeys) are **suppressed while the box has keyboard focus** — their tab labels fade to show suppression is active, and both labels and hotkeys return the moment focus leaves the box (click elsewhere). Without this, typing any `m` yanked the menu to the map. The live `Widget_InGameMenu_C` instance is found via `IsVisible()`-filtered `FindAllOf` (fixed 2026-07-17 — this mod copied LoadoutNamer's original "whichever non-`Default__` instance came last" version, which had the same intermittent failure to suppress; see `docs/loadout_namer.md` Warts for the root-cause writeup, identical fix ported here).
- Other menu letter hotkeys (U/J/O/P/B) are **not** suppressed; in testing they haven't interfered while the box is focused. If one ever does, the fix is one entry in `TAB_HOTKEY_PROPS`.

### Debug commands (type into the search box)

Anything starting with `!` is a command, not a search — the grid shows everything while a command is in the box, and all output goes to `UE4SS.log`, not on screen:

- **`!<word>`** (word must be ≥ 2 characters) — prints the FULL cached search text of every item containing `<word>`. Use it to answer "why did/didn't item X match?"
- **`!!`** — clears the item text cache; the next keystroke rebuilds it fresh from the live grid. Use after upgrading an item (see below) or whenever cached text looks stale.
- **`!?`** — lists every item whose cached text is *name-only* (no effect text found — such an item can never match an effect search) plus a total count. Healthy state is `0 name-only item(s) total`; a nonzero count after a game patch means the game moved some items' effect text again.

### Special cases

- **Upgraded items**: the cache is built once per session, so an item upgraded mid-session keeps its old "+N" level suffix in its searchable text until you type `!!` or relaunch. Name and effect words still match; only the level number is stale.
- **Inventory-tab lists** (materials/quest/usable) don't keep the filter across tab switches — switching tabs rebuilds the list unfiltered; retype to re-filter.
- The equipment screen's grids share one search box; the Inventory tab's lists each have their own.

## Key implementation facts

- **The vanilla filter pipeline is dead, so matching and hiding are both ours.** The shipped bar was a keyword→tag prototype fed by `DataTable_ItemFilters`, which ships empty; and every vanilla rebuild entry point (including the once-planned `ShouldHideItem` hook) early-outs when the game thinks nothing changed. The mod instead walks `list.InventoryGrid`'s card children on query change and calls `SetVisibility` per card, recording each hidden card's prior visibility for exact restore.
- **Two hiding layers on the bar**: the `CanSeeSearchBar` gate binding on the filter child (fires only during construction, inert after — a plain visibility write sticks) and the text box itself, `Collapsed` at the asset level. Both are unhidden per list construction, with one delayed re-apply to outlast the construction-time binding evaluations. Startup now watches `/Script/UMG.UserWidget` and filters for `Widget_InventoryList_C`, avoiding stable's registration against an unloaded Blueprint class. Template/CDO objects are ignored; per-address deduplication and up to 40 game-thread readiness checks wait for the filter child, text box and owning player. No global discovery scan is added.
- **Search text per ItemID** comes from each card's `Get_InspectInfo({})` (BlueprintPure; UE4SS spreads the out-struct's fields into the passed table), cached for the session, built lazily from each list's own grid children — never the global card pool (stale pooled cards from destroyed screens poisoned the cache once).
- **Effect text lives in two different places by item style**: stat-style items → `Mods[].Label` (`InspectMod`); trigger-style items (~30 rings) → `Stats[].CustomDescription`, inherited from `InspectStatBase`. Field names are resolved at load by reflection, **per array** — Stats and Mods entries are different structs, and reading a field a struct doesn't own is a native crash (hazard H9); the reflection walk must include the `GetSuperStruct()` chain or inherited fields are silently missed (H10).
- **Text normalization**: cached text and queries both get lowercased, rich-text markup stripped (`<stat>`, `<span color=...>`), NBSPs and whitespace runs collapsed — phrase matching fails otherwise ("grey health" with a tag between the words).
- **Multiple lists coexist** (equipment screen + three Inventory-tab lists); each is tracked by full name and synced against its *own* text box — a single "current list" variable let one list's typing stomp another's filter state.
- **Rebuild resilience**: post-hooks on the game's `Update Inventory List` / `Build Inventory List` passes (plus a one-shot 150 ms delayed re-apply — Build repopulates asynchronously) and a 300 ms watchdog that silently re-applies active filters, because some rebuild paths (equip → popup reopen) bypass both hooks. A full re-apply pass measured ~2 ms.
- **Hotkey suppression mechanism**: tab switches early-out when the tab *button* isn't visible (LoadoutNamer's probe, §3.4aa). The typing-session boundary is the filter widget's `OnAddedToFocusPath` / `OnRemovedFromFocusPath` overrides — they fire when keyboard focus enters/leaves the box. Only tabs that were actually visible get hidden, and only those get restored; a leaked Hidden state self-heals when the menu reopens.
- Hooks on `/Game/` classes can't register at mod start on a fresh launch (Blueprint not loaded yet) — registration is deferred to the first list capture.

## Known warts / deliberate scope cuts

- Upgraded items keep their old "+N" level suffix in cached text until relaunch (session-lifetime cache by design; the name and effect words still match).
- The Inventory tab's lists don't persist the filter across tab switches (each switch rebuilds; retyping is cheap).
- The search covers item grids only — trait/archetype screens use different widgets and are out of scope.
- Cache assumes effect text is static per ItemID within a session; items whose display text changes with game state would show stale matches until `!!`.
