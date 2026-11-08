# EquipmentSearch

A working search bar for your inventory.

## What it does

- Adds an always-visible search box to every inventory item grid: rings,
  amulets, armor, relics, weapons, and the Inventory tab's
  materials/quest/usable lists.
- Filters live as you type, matching both the item's name **and** its
  gameplay-effect text (so searching "grey health" finds trigger rings that
  grant it, not just items with those words in their name).
- The X button clears the search.
- Lore/flavor text is intentionally excluded from matching.

## Requirements

- Remnant 2 (Steam/PC)
- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) — either experimental-latest or
  stable v3.0.1 Beta. **See the [repo README](../README.md#which-ue4ss-build-should-i-use)
  for which one you need** — it depends on whether you also use asset/pak mods
  like `AllowModsMod`.

## Installation

1. Download `EquipmentSearch-v1.0.0.zip` from the
   [Releases page](../../../releases) and extract it — you'll get an
   `EquipmentSearch` folder containing `Scripts\`, `mod.json`, and this README.
2. Copy that folder into your UE4SS Mods folder:
   - Experimental-latest: `<Remnant2>\Binaries\Win64\ue4ss\Mods\`
   - Stable: `<Remnant2>\Binaries\Win64\Mods\`
3. Add a line for it in that folder's `mods.txt`:
   ```
   EquipmentSearch : 1
   ```
4. Launch the game.

## Known limitations

- The search filter resets when you switch tabs on the Inventory screen.
- An upgraded item keeps its old "+N" text in the search cache until you
  relaunch (its name still matches fine in the meantime).
- Earlier builds can require one hot-reload after launch on stable UE4SS.
  This source fixes that startup issue with a native-widget listener, verified
  on a cold first equipment-screen open with stable v3.0.1.

## License

MIT — see the repository [LICENSE](../LICENSE).
