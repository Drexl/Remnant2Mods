# Remnant2Mods

[UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua mods for **Remnant 2**
(Steam/PC, Unreal Engine 5.2).

| Mod | What it does |
|---|---|
| [MoreLoadoutSlots](MoreLoadoutSlots/) | Raises the Character screen's loadout count from 8 to 20. |
| [LoadoutNamer](LoadoutNamer/) | Rename loadout tiles with F2; names persist across sessions. |
| [EquipmentSearch](EquipmentSearch/) | A working search bar for every inventory item grid, filtering by name and effect text. |
| [PrismLegendaryReroller](PrismLegendaryReroller/) | Cleansing a Prism's legendary bonus no longer drops it back to level 50. |

Each mod works standalone. See each mod's own README for details, and its
`mod.json` for version/author metadata.

## Requirements

- Remnant 2 (Steam/PC)
- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) — **either** the experimental-latest
  build **or** stable v3.0.1 (see below for which one you need).

## Which UE4SS build should I use?

These mods work on **both** UE4SS build lines, but they aren't fully
interchangeable — pick based on whether you also use asset/pak mods:

| | UE4SS experimental-latest | UE4SS stable (v3.0.1 Beta) |
|---|---|---|
| **Use this if...** | You don't use `AllowModsMod` ("Allow Asset Mods") or other pak-based asset mods. | You use `AllowModsMod` or other asset/pak mods — they require the stable ABI and will fail to load (or crash) on experimental-latest. |
| **Mod folder location** | `<Remnant2>\Binaries\Win64\ue4ss\Mods\` | `<Remnant2>\Binaries\Win64\Mods\` (no `ue4ss` subfolder) |
| MoreLoadoutSlots | Full native behavior. | Fully functional via an automatic fallback path, including the first Loadouts-screen open after launch. |
| LoadoutNamer | Full native behavior, fully styled. | Fully functional, but the rename text box and the tooltip's "F2 Rename" text use the plain engine look instead of the game's styled font/colors. Purely cosmetic. |
| EquipmentSearch | Full native behavior. | Fully functional, filtering works identically. |

Everything above is handled automatically — there's no setting to flip. Just
install the matching UE4SS build for your situation and the mods detect and
adapt to it on their own.

If you're not using any asset/pak mods, experimental-latest is the simpler
choice with no cosmetic caveats.

## Installation

1. Download the mod(s) you want from the [Releases page](../../releases) —
   each mod ships as its own zip (e.g. `MoreLoadoutSlots-v1.0.0.zip`) and
   extracts to a single folder (e.g. `MoreLoadoutSlots\`) containing
   `Scripts\`, `mod.json`, and `README.md`.
2. Extract that folder into your UE4SS Mods folder — the path depends on
   which build you installed (see table above):
   - Experimental-latest: `<Remnant2>\Binaries\Win64\ue4ss\Mods\`
   - Stable: `<Remnant2>\Binaries\Win64\Mods\`
3. Add a line for each mod in that folder's `mods.txt`, e.g.:
   ```
   MoreLoadoutSlots : 1
   LoadoutNamer : 1
   EquipmentSearch : 1
   ```
4. Launch the game.

## License

MIT — see [LICENSE](LICENSE). Free to use, modify, and redistribute with
attribution.
