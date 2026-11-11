# RollFrames

Group loot rolls, live, in one window that looks like Blizzard's own UI. For **World of Warcraft: Forever**.

When a group loot roll starts, RollFrames shows the drop as one steady row and keeps it up to date:

- **How many chose Need, Greed and Pass**, as their icons, plus your own choice and roll. Hover a drop for everyone's rolls (in a raid: the Need rolls, and a count of the rest).
- **The winner** and their roll, on the row the moment it's decided. The roll comes first, so a long name never hides it.
- **History:** decided drops move under the clock in the title bar after a minute, or as soon as the window fades out. Click the clock to bring them back into the list. It's kept for each character across reloads and logouts (100 drops by default), and the X clears it, after asking.
- **More detail if you like:** with Player lines set to Everyone, each player gets a line with their choice and roll, and the winner a short sweep.
- **Item level** for gear, next to the item name.
- **Optional Need, Greed and Pass buttons** on each drop. While they're on and the window is open, Blizzard's roll popups stay hidden; if anything goes wrong, or you close the window, Blizzard's popups come back. When new loot moves the list, buttons that slide under a mouse that didn't move ignore clicks for a moment (the click guard), so a click meant for one item can't land on another.

It's built for long raid nights without reloads: it reuses its frames instead of creating new ones for every drop, uses no libraries, and does nothing while there's no loot.

This tracks **group loot rolls** (Need, Greed and Pass). It isn't a tracker for `/roll` number rolls.

## Install

Install it from CurseForge or Wago, or by hand:

1. Close the game.
2. Download the latest zip from [Releases](https://github.com/reflectedreverb/RollFrames/releases) and put the `RollFrames` folder in `World of Warcraft/_forever_/Interface/AddOns/`.
3. Start the game and make sure RollFrames is ticked in the AddOns list.

## Use

| Command | What it does |
|---|---|
| `/rollframes` | Show or hide the window |
| `/rollframes demo [count]` | Play made-up drops (three, or up to 20: `/rollframes demo 10`), so you can see it without a group |
| `/rollframes options` | Open the settings (also under Options → AddOns → RollFrames) |
| `/rollframes reset` | Put the window back in its starting spot at its normal size |
| `/rollframes reset all` | Start over completely, after asking: every setting, the window, and this character's loot history (the interface reloads) |
| `/rollframes blizzard` | Open Blizzard's own loot history |
| `/rollframes diag` | Print a short status for bug reports (no names) |
| `/rollframes diag log` | Turn a troubleshooting log on or off; it's saved with your settings, never includes names |

You can also open it from the AddOns button by the minimap: left-click shows or hides the window, right-click opens the settings.

The window opens on the right, beside the quest tracker. Drag its title bar to move it anywhere; drag the grip in its corner to set its height (in whole rows). Longer lists scroll. With nothing in it yet, it offers a **Try the demo** button.

## Settings

Under Options → AddOns → RollFrames.

**Window**

- **Open when a roll starts** (on): show the window whenever a group loot roll starts. Off: it keeps track in the background; open it yourself when you want it. While it's closed, Blizzard's roll popups show as usual.
- **Roll from this window** (off): Need, Greed and Pass buttons on each drop, with Blizzard's popups hidden while the window is open. If two copies of the same item drop at once, the game can't say which roll is which copy, so a click uses either of your rolls on that item and your choice shows on the copy the game reports it for; the other copy then offers your second roll.
- **Player lines:** Summary (default): one row per drop with how many chose each; hover it for everyone's rolls. Auto: a line per player in a party, Summary in a raid. Everyone: a line per player. None: just the items, with your own choice where the buttons were.
- **Click guard** (on, 2 seconds): roll buttons that slide under a mouse that didn't move ignore clicks for half a second, 1, 2, 3 or 5 seconds, or until the mouse moves. A guarded click plays a short sound.
- **Position:** Free (default: beside the quest tracker until you drag it anywhere) or Above roll popups.
- **Grow with drops** (off): the window grows with its drops up to the height you set, then scrolls. Off: it keeps one height.
- **Hide when idle after** (15 seconds, or never): fade the window once every drop is decided and nothing has happened for this long; hovering the window restarts the time. A thin line drains under the title for the last few seconds. A window you open yourself stays until you close it: the pin by the close button is lit; click the pin to switch.

**History**

- **Minimum quality kept:** all items (default), or only uncommon, rare or epic and better. Lower items fade out once decided and aren't kept in History. Rolls of any quality always show while they run, and every drop is still in Blizzard's loot history (`/loot`).
- **Keep trash drops** (on): off keeps only boss loot once the winner has shown.
- **History keeps** (100 drops): how many decided drops History keeps for this character (50, 100, 250 or 500).
- **Finished drops stay** (1 minute): how long a decided drop stays in the list before it moves to History; or until cleared.

**Accessibility**

- **Highlight drops to roll** (gold border; needs Roll from this window): a pulsing gold border, a glowing timer bar, sparkles, all three, or off.
- **Flashing:** Normal (default), Until noticed (the window's flash repeats until you hover it), or Off (nothing flashes or pulses).

## More addons

More addons by ReflectedReverb: <https://github.com/reflectedreverb>

## License

Copyright (C) 2026 ReflectedReverb.

RollFrames is free software under the [GNU General Public License v3.0](https://github.com/reflectedreverb/RollFrames/blob/main/LICENSE): you can use, change and share it, and any version you release must stay under the same license.
