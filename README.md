# RollFrames

Group loot rolls, live, in one window that looks like Blizzard's own UI. For **World of Warcraft: Forever**.

When a group loot roll starts, RollFrames shows the drop as a card and fills it in as people choose:

- **Everyone's Need, Greed or Pass** the moment they pick it, with roll numbers as they're revealed. Your own roll is highlighted and listed first.
- **Who's still deciding:** "Waiting on 3 players", with the names on hover.
- **The winner**, highlighted with a short sweep. A few seconds later the card shrinks to a compact history row (item and winner). Hover the item for its tooltip.
- **Item level** for gear, next to the item name.
- **Optional Need, Greed and Pass buttons** on each card. While they're on and the window is open, Blizzard's roll popups stay hidden; if anything goes wrong, or you close the window, Blizzard's popups come back.

It's built for long raid nights without reloads: it reuses its frames instead of creating new ones for every drop, uses no libraries, and does nothing while there's no loot.

This tracks **group loot rolls** (Need, Greed and Pass). It isn't a tracker for `/roll` number rolls.

## Install

Install it from CurseForge or Wago, or by hand:

1. Close the game.
2. Download the latest zip from [Releases](../../releases) and put the `RollFrames` folder in `World of Warcraft/_forever_/Interface/AddOns/`.
3. Start the game and make sure RollFrames is ticked in the AddOns list.

## Use

| Command | What it does |
|---|---|
| `/rollframes` | Show or hide the window |
| `/rollframes demo` | Play three made-up drops, so you can see it without a group |
| `/rollframes options` | Open the settings (also under Options → AddOns → RollFrames) |
| `/rollframes reset` | Put the window back above the roll popups at its normal size |
| `/rollframes blizzard` | Open Blizzard's own loot history |
| `/rollframes diag` | Print a short status for bug reports (no names) |
| `/rollframes diag log` | Turn a troubleshooting log on or off; it's saved with your settings, never includes names |

You can also open it from the AddOns button by the minimap: left-click shows or hides the window, right-click opens the settings.

Drag the window to move it anywhere; drag the grip in its corner to set how tall it may grow. Longer lists scroll.

## Settings

- **Open when a roll starts** (on): show the window whenever a group loot roll starts. Off: it stays in the background and keeps track; open it yourself when you want it. While it's closed, Blizzard's roll popups show as usual.
- **Roll from this window** (off): Need, Greed and Pass buttons on each drop, with Blizzard's popups hidden while the window is open.
- **Position:** attached above Blizzard's roll popups (default), or free.
- **Fixed window height** (off): keep the window at the height you set with its corner grip, so it never changes size; longer lists scroll.
- **Show rolls after a winner:** how long the full list stays before the drop collapses (5 seconds by default).
- **Hide when idle after:** fade the window once every drop is decided and nothing has happened for this long (15 seconds by default, or never). A thin line drains under the title for the last few seconds; hovering the window restarts the time. A window you open yourself stays until you close it: the pin by the close button is lit. Click the pin to switch.
- **Minimum quality kept:** the lowest item quality kept as a history row once a roll is decided: all items (default), or only uncommon, rare or epic and better. Rolls of any quality always show as normal while they run, and every drop is still in Blizzard's loot history (`/loot`).
- **History length:** how many finished drops stay listed as compact rows (10 by default). Older ones leave the list; Blizzard's loot history (`/loot` or `/rollframes blizzard`) still has them.

## License

Copyright (C) 2026 ReflectedReverb.

RollFrames is free software under the [GNU General Public License v3.0](https://github.com/reflectedreverb/RollFrames/blob/main/LICENSE): you can use, change and share it, and any version you release must stay under the same license.
