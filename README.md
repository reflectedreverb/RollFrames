# RollFrames

Group loot rolls, live, in one window that looks like Blizzard's own UI. For **World of Warcraft: Forever**.

![RollFrames: the Compact and Detailed views](https://raw.githubusercontent.com/reflectedreverb/reflectedreverb/main/media/RollFrames/showcase.png)

When a group loot roll starts, RollFrames shows the drop as one steady row and keeps it up to date:

- **How many chose Need, Greed and Pass**, as their icons, plus your own choice and roll. Hover a drop for everyone's rolls (in a raid: the Need rolls, and a count of the rest).
- **The winner** and their roll, on the row the moment it's decided. The roll comes first, so a long name never hides it.
- **Your wins stand out:** a gold sweep across the drop, then a faint gold tint and a checkmark after your name, in the list and in History.
- **History:** decided drops move under the clock in the title bar after a minute, or as soon as the window fades out. Click the clock to bring them back into the list. It's kept for each character across reloads and logouts (100 drops by default), and the X clears it, after asking.
- **More detail if you like:** set View to Detailed for a line per player with their choice and roll.
- **Item level** for gear, next to the item name.
- **Optional Need, Greed and Pass buttons** on each drop, in four sizes up to Blizzard's own, with a gold glow behind the one under your mouse. While they're on and the window is open, Blizzard's roll popups stay hidden; if anything goes wrong, or you close the window, Blizzard's popups come back. When new loot moves the list, buttons that slide under a mouse that didn't move ignore clicks for a moment (the click guard), so a click meant for one item can't land on another.
- **Sized for your screen:** Window size makes the whole window 75% to 200%.
- **Accessibility options:** bigger roll buttons, a larger window, flashing that can be turned off, and an optional No animations mode.

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
| `/rollframes size [75-200]` | Set the Window size (`/rollframes size 150`); on its own, show the current size |
| `/rollframes reset` | Put the window back in its starting spot, at its starting height and 100% Window size |
| Options → AddOns → RollFrames → **Defaults** | Put every RollFrames setting back to its default (Window size included); your History and the window's spot and height stay |
| `/rollframes reset all` | Start over completely, after asking: every setting, the window, and this character's loot history (the interface reloads) |
| `/rollframes blizzard` | Open Blizzard's own loot history |
| `/rollframes diag` | Print a short status for bug reports (no names) |
| `/rollframes diag log` | Turn a troubleshooting log on or off; it's saved with your settings, never includes names |

You can also open it from the AddOns button by the minimap: left-click shows or hides the window, right-click opens the settings.

The window opens on the right, beside the quest tracker. Drag its title bar to move it anywhere. Hover the window to show the grip in its corner, and drag it to set the height; the window keeps that height (unless Grow with drops is on), and longer lists scroll. With nothing in it yet (and you're not in a group), it offers a **Try the demo** button; **Don't show this again** under it hides the offer for good.

## Settings

Under Options → AddOns → RollFrames.

**Rolling**

- **Open when a roll starts** (on): show the window whenever a group loot roll starts. Off: it keeps track in the background; open it yourself when you want it. While it's closed, Blizzard's roll popups show as usual.
- **Roll from this window** (off): Need, Greed and Pass buttons on each drop, with Blizzard's popups hidden while the window is open. If two copies of the same item drop at once, the game can't tell which roll is which: a click uses either of your rolls on that item, and the other copy then offers your second roll. With controller mode on, you roll in the game's own gamepad roll list instead, and the buttons come back when it's off. The settings under it need it on:
  - **Roll button size** (Medium): Small, Medium, Large or Extra large (the size of Blizzard's own roll buttons). Bigger buttons make each row a little taller; the item icon grows with it.
  - **Highlight drops to roll** (Gold border): a pulsing gold border, a glowing timer bar, sparkles, all three, or off.
  - **Glow on hovered buttons** (on): a soft gold glow behind the roll button under your mouse, so you can see which one a click will hit.
  - **Click guard** (on): buttons that slide under a mouse that didn't move ignore clicks for a moment, or until you move the mouse. A guarded click plays a short sound.
    - **Click guard time** (2 seconds): how long; half a second to 5 seconds, or until the mouse moves.

**Window**

- **View:** Compact (default): one row per drop with how many chose each; hover it for everyone's rolls. Auto (raids: Compact): Detailed in a party or solo, Compact in a raid. Detailed: a line per player with their choice and roll. Items only: just the items, with your own choice where the buttons were.
- **Window size** (100%): 75% to 200%. Text, icons, roll buttons and rows grow together, and the window stays on screen. Also `/rollframes size`.
- **Grow with drops** (off): the window grows with its drops up to the height you set, then scrolls. Off: it keeps one height.
- **Snap to whole rows** (off): dragging the corner moves a whole row at a time. Off: the corner goes exactly where you drag it.
- **Hide when idle after** (15 seconds): fade the window once every drop is decided and nothing has happened for this long (10, 15, 30 or 60 seconds, or never); hovering the window restarts the time. A thin line drains under the title for the last few seconds. A window you open yourself stays until you close it: the pin by the close button is lit; click the pin to switch.

**History**

- **Finished drops stay** (1 minute): how long a decided drop stays in the list before it moves to History; or until cleared.
- **Minimum quality kept:** all items (default), or only uncommon, rare or epic and better. Lower items fade out once decided and aren't kept in History. Rolls of any quality always show while they run, and every drop is still in Blizzard's loot history (`/loot`).
- **Keep trash drops** (on): off keeps only boss loot once the winner has shown.
- **History keeps** (100 drops): how many decided drops History keeps for this character (50, 100, 250 or 500).

**Tooltips**

- **Item tooltip** (Whole drop): where a drop shows its item's tooltip, beside the window. Whole drop: anywhere on it, and it stays up as you move to the roll buttons. Item icon only: just the item's icon, as on Blizzard's roll popup. Comparing with what you have equipped follows the game.
- **Roll button tooltips** (on): a small tip by the roll button under your mouse says which roll it is, why you can't choose it, or that the list just moved.
- **Tooltips at game's spot** (off): tooltips that open beside the window open where the game shows its own instead, so tooltip addons that move tooltips apply too.

**Motion and flashing**

- **No animations** (off): everything appears, changes and goes at once; nothing fades, slides, flashes, pulses or sweeps. The roll timers still count down.
- **Flashing:** Normal (default), Until noticed (the window's flash repeats until you hover it), or Off (nothing flashes, pulses or sweeps; a 100 roll shows a still glow).
- **Sweep when a roll ends** (on): a soft band crosses the drop once: gold on a drop you win, grey on a compact row someone else wins; in Detailed, gold on the winner's line. Off: no sweep; drops you win still get a steady gold tint.

## More addons

More addons by ReflectedReverb: <https://github.com/reflectedreverb>

## License

Copyright (C) 2026 ReflectedReverb.

RollFrames is free software under the [GNU General Public License v3.0](https://github.com/reflectedreverb/RollFrames/blob/main/LICENSE): you can use, change and share it, and any version you release must stay under the same license.
