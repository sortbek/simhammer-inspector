# Simhammer Inspector

Live raid gear inspection for World of Warcraft retail. One screen showing every
raider's item level, missing enchants, empty sockets, upgrade tracks, tier pieces
and embellishments — and a SimulationCraft profile for any of them without
leaving the game.

Built on in-game inspect only, so it works on people who do not run the addon,
including pugs.

## Using it

| Command | What it does |
|---|---|
| `/sh` | Opens the grid. Click a row for one player's detail panel, right-click to draft a whisper about their gear |
| `/sh scan` | Priority pass over everyone in range — best used while the raid is stacked before a pull |
| `/sh report` | Prints the findings to chat |
| `/sh simc` | SimulationCraft profiles for the roles you pick |
| `/sh simc self` | Your own profile |
| `/sh simc target` | Whoever you have targeted |

`/simhammer` works everywhere `/sh` does, in case something else has claimed the
short form.

The `SimC` button in a player's detail panel exports that one player.

## What it will not tell you

Inspect has two limits the addon cannot design around, so it says so rather than
guessing:

- **Out of range is unreadable.** Someone the client cannot inspect shows as
  unknown, never as a problem. A grey cell means "not read yet".
- **Nothing announces a gear change.** Data ages; the grid dims a player's row
  once their reading is stale.

Findings only turn red or amber once there is confirmed evidence behind them.
Until then they stay grey, because telling a raider to fix something that is
already fine is worse than saying nothing.

## Building

The addon is the repository root — `SimhammerInspector.toc` and everything it
lists. `spec`, `tools`, `spike` and `docs` are development only and are left out
of releases by [.pkgmeta](.pkgmeta).

```
tools\test.ps1        # run the test suite (Lua 5.1, bundled)
tools\deploy.ps1      # copy the addon into your AddOns folder
tools\generate.mjs    # regenerate the ID tables from wago.tools DB2 exports
```

Releases are built by [BigWigs packager](https://github.com/BigWigsMods/packager)
from a pushed tag. The tag is the only version number: it is substituted into the
TOC at build time and read back at runtime.

## Licence

MIT. See [LICENSE](LICENSE).
