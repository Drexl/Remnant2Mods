# LoadoutNamer

Custom names for your loadout slots on the Character screen.

## What it does

- Hover a loadout tile and press **F2** — a focused text box opens right in
  the tile's title, with any existing custom name selected. Type a name,
  then **Enter**, **F2**, or **click outside** to save it; **Escape** cancels.
- Committing an empty name removes the custom name and restores the default
  ("Loadout N").
- The tile shows up to 18 characters (truncated with `..`); hovering shows
  the full name (up to 32 characters) in the tooltip, which also gets its
  own "F2 Rename" reminder.
- Names are saved to a text file next to the mod and persist across game
  sessions.
- The rename key is configurable: edit `RenameKey=` in `settings.txt` (created
  next to the mod on first run) to any UE4SS key name (e.g. `F3`, `R`) if you'd
  rather not use F2.

Pairs well with **MoreLoadoutSlots** (20 slots instead of 8) but works fine
on its own with the vanilla 8-slot panel.

## Requirements

- Remnant 2 (Steam/PC)
- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) — either experimental-latest or
  stable v3.0.1 Beta. **See the [repo README](../README.md#which-ue4ss-build-should-i-use)
  for which one you need** — it depends on whether you also use asset/pak mods
  like `AllowModsMod`.

## Installation

1. Download `LoadoutNamer-v1.0.0.zip` from the
   [Releases page](../../../releases) and extract it — you'll get a
   `LoadoutNamer` folder containing `Scripts\`, `mod.json`, and this README.
2. Copy that folder into your UE4SS Mods folder:
   - Experimental-latest: `<Remnant2>\Binaries\Win64\ue4ss\Mods\`
   - Stable: `<Remnant2>\Binaries\Win64\Mods\`
3. Add a line for it in that folder's `mods.txt`:
   ```
   LoadoutNamer : 1
   ```
4. Launch the game.

## Known limitations

- The reserved "Last Gear State" auto-save slot can't be renamed.
- The edit box is a styled engine text box — close to the game's look, but
  not pixel-identical.
- **On stable UE4SS only**: the rename text box and the tooltip's "F2 Rename"
  text fall back to the plain engine font/color instead of the game's styled
  look (cosmetic only — renaming still works fully). You may also see repeated
  harmless log lines about the rename prompt on stable; this doesn't affect
  gameplay.

## License

MIT — see the repository [LICENSE](../LICENSE).
