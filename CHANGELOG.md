# RollFrames

## v1.1.0

- **Roll buttons stay put.** A drop keeps its size while people roll, and the drop under your mouse doesn't move when other drops arrive or finish.
- **Fixed button spots.** Need, Greed and Pass are always in the same places, right to left. A choice the item doesn't allow is greyed out rather than removed.
- **"N more to roll":** when drops still waiting for your roll are scrolled out of view, a bar at that edge says so. Click it to jump to them.
- **Asked at login** whether you want to roll from the window, with a sample to try. Never during combat or loot. Change it any time in Options.
- **Player lines:** a line per player, one summary line per drop, or just the items. Default: a line per player in a party, the summary in a raid.
- **Boss names** on history rows, and a **Keep trash drops** option.
- **Hovering stops the fade** is now a setting.
- Drops stay in the order they arrived; a decided drop shrinks where it is. The window opens at the newest drops.
- Two copies of the same item dropping together each get their own drop, and either of your rolls can be used on them.
- Cancelling a bind-on-pickup confirmation gives you the roll back. Addons that auto-confirm it are handled.
- A click that was already in progress when new buttons appeared doesn't count.
- The window no longer grows over the roll popups.
- `/rollframes demo 10` plays 10 made-up drops (up to 20). The demo never touches your real history, and isn't available in a group.
- Lighter on busy raid nights: about 90% fewer UI updates than v1.0 in a 40-player stress test with default settings.

## v1.0.0

First release. Group loot rolls, live, in one Blizzard-style window.

- Everyone's Need, Greed or Pass the moment they choose, with roll numbers as they're revealed. Your own roll is listed first and highlighted.
- "Waiting on N players", with the names on hover.
- The winner is highlighted, then the drop shrinks to a compact history row with the item, item level and winner.
- Optional Need, Greed and Pass buttons on each card. Blizzard's popups come back if anything goes wrong or the window closes.
- Sits above the roll popups or anywhere you drag it. Resizable, with an optional fixed height. Fades when idle; the pin keeps it open.
- History settings: minimum quality kept, and history length.
- Reuses its frames, so memory stays flat over a full raid night.
- `/rollframes`, `/rollframes demo`, `/rollframes options`, `/rollframes reset`. Also in the AddOns button by the minimap.
