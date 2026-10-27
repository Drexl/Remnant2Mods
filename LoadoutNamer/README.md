# LoadoutNamer

Custom names for your loadout slots on the Character screen.

## What it does

- Hover a loadout tile and press **F2** — a text box opens right in the
  tile's title. Type a name, then **Enter** or **F2** to save it, **Escape**
  to cancel.
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
- Stable UE4SS may log repeated rename-prompt messages while older tooltip
  instances remain valid.

## License

MIT — see the repository [LICENSE](../LICENSE).
