# MoreLoadoutSlots

Raises the Character screen's loadout count from **8 to 20**.

## What it does

- Adds 12 extra loadout tiles to the Loadouts panel, reachable by mouse-wheel
  scrolling with the vanilla advanced-stats scrollbar's styling and behavior.
- Every extra slot behaves exactly like a vanilla slot: right-click to save,
  left-click or Space to equip, F to delete — same confirmation dialogs, same
  rules (can't overwrite the currently-equipped loadout, can't load/delete an
  empty one).
- Gear saved in the extra slots is stored in your regular save file and
  survives relaunches.

## Requirements

- Remnant 2 (Steam/PC)
- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) — either experimental-latest or
  stable v3.0.1 Beta. **See the [repo README](../README.md#which-ue4ss-build-should-i-use)
  for which one you need** — it depends on whether you also use asset/pak mods
  like `AllowModsMod`.

## Installation

1. Download `MoreLoadoutSlots-v1.0.0.zip` from the
   [Releases page](../../../releases) and extract it — you'll get a
   `MoreLoadoutSlots` folder containing `Scripts\`, `mod.json`, and this README.
2. Copy that folder into your UE4SS Mods folder:
   - Experimental-latest: `<Remnant2>\Binaries\Win64\ue4ss\Mods\`
   - Stable: `<Remnant2>\Binaries\Win64\Mods\`
3. Add a line for it in that folder's `mods.txt`:
   ```
   MoreLoadoutSlots : 1
   ```
4. Launch the game.

## Known limitations

- Scrolling to slots 9+ is mouse-wheel only; gamepad focus-scroll is untested.
- Saving/equipping into an extra slot while in another player's co-op session
  is untested (should work, following the same rules as vanilla slots, but
  hasn't been verified).
- **On stable UE4SS only**: the extra slots may not appear the very first time
  you open the Loadouts screen after launch (a pre-existing UE4SS quirk on
  stable, not caused by this mod) — close and reopen the screen once (or
  hot-reload) and they'll show up for the rest of the session.

## License

MIT — see the repository [LICENSE](../LICENSE).
