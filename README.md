# RollFrames

Group loot rolls, live, in one window that looks like Blizzard's own UI. For **World of Warcraft: Forever**.

When a group loot roll starts, RollFrames shows the drop as a card and fills it in as people choose:

- **Everyone's Need, Greed or Pass** the moment they pick it, with roll numbers as they're revealed. Every player has a line from the start ("..." while they decide): your own first and highlighted, then rolls in the order they came in, then players still deciding, then passes. A drop keeps the same height for its whole roll, so the roll buttons stay put as people choose.
- **The winner**, highlighted with a short sweep. A few seconds later the card shrinks to a compact history row: item, winner, and the boss it came from. Hover the item for its tooltip.
- **Less detail if you like:** one summary line per drop ("Need 2 · Greed 1 · Pass 3 · 2 deciding"), or just the items with your own choice and the winner.
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
| `/rollframes demo [count]` | Play made-up drops (three, or up to 20: `/rollframes demo 10`), so you can see it without a group |
| `/rollframes options` | Open the settings (also under Options → AddOns → RollFrames) |
| `/rollframes reset` | Put the window back above the roll popups at its normal size |
| `/rollframes blizzard` | Open Blizzard's own loot history |
| `/rollframes diag` | Print a short status for bug reports (no names) |
| `/rollframes diag log` | Turn a troubleshooting log on or off; it's saved with your settings, never includes names |

You can also open it from the AddOns button by the minimap: left-click shows or hides the window, right-click opens the settings.

Drag the window to move it anywhere; drag the grip in its corner to set how tall it may grow. Longer lists scroll.

## Settings

- **Open when a roll starts** (on): show the window whenever a group loot roll starts. Off: it stays in the background and keeps track; open it yourself when you want it. While it's closed, Blizzard's roll popups show as usual.
- **Roll from this window** (off): Need, Greed and Pass buttons on each drop, with Blizzard's popups hidden while the window is open. The drop under your mouse holds still while you decide. If two copies of the same item drop at once, the game can't say which roll is which copy, so a click uses either of your rolls on that item and your choice shows on the copy the game reports it for; the other copy then offers your second roll.
- **Player lines:** Auto (default): Everyone in a party, Summary in a raid. Everyone: a line per player. Summary: one line of counts per drop; hover it for everyone's rolls. None (item only): just the items, with your own choice and roll where the buttons were; hover an item for everyone's rolls.
- **Position:** attached above Blizzard's roll popups (default), or free.
- **Fixed window height** (off): keep the window at the height you set with its corner grip, so it never changes size; longer lists scroll.
- **Show rolls after a winner:** how long the full list stays before the drop collapses (5 seconds by default).
- **Hide when idle after:** fade the window once every drop is decided and nothing has happened for this long (15 seconds by default, or never). A thin line drains under the title for the last few seconds; hovering the window restarts the time. A window you open yourself stays until you close it: the pin by the close button is lit. Click the pin to switch.
- **Hovering stops the fade** (on): while the mouse is over the window it doesn't fade. Off: it fades on time even under the mouse.
- **Minimum quality kept:** the lowest item quality kept as a history row once a roll is decided: all items (default), or only uncommon, rare or epic and better. Rolls of any quality always show as normal while they run, and every drop is still in Blizzard's loot history (`/loot`).
- **Keep trash drops** (on): off keeps only boss loot in the history; trash drops leave once their winner has shown.
- **History length:** how many finished drops stay listed as compact rows (10 by default). Older ones leave the list; Blizzard's loot history (`/loot` or `/rollframes blizzard`) still has them.

## License

Copyright (C) 2026 ReflectedReverb.

RollFrames is free software under the [GNU General Public License v3.0](https://github.com/reflectedreverb/RollFrames/blob/main/LICENSE): you can use, change and share it, and any version you release must stay under the same license.
