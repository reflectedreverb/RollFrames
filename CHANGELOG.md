# RollFrames

## v1.2.0

- **A calmer window by default.** It now sits on the right, beside the quest tracker, out of the way of your action bars, and keeps one size. Every drop is one steady row: the item, how many chose Need, Greed and Pass, and your own choice. Hover a drop for everyone's rolls (in a raid, the Need rolls and a count of the rest). Prefer the old way? Options: Position "Above roll popups", Player lines "Auto" or "Everyone".
- **History.** Decided drops move into History after a minute, or as soon as the window fades out. The clock in the title bar brings them back into the list. History is kept per character across reloads and logouts (100 drops by default), and the X clears it, after asking.
- **New loot comes in at the top**, even while your mouse is over the window.
- **Fewer settings.** "Show rolls after a winner" (now 5 seconds), "Hovering stops the fade" (always) and "Fixed window height" are gone; clearing History always asks first.
- **Click guard.** When new loot moves the list and roll buttons slide under a mouse that didn't move, they're dimmed and ignore clicks for 2 seconds or until you move the mouse, so a click meant for one item can't land on another. Its time is a setting (or "until the mouse moves"), and it can be turned off.
- **Drops waiting for your roll stand out**, with a gold border, a glowing timer bar or sparkles (Accessibility settings). **Flashing** can be set to Normal, Until noticed or Off.
- **One tooltip per drop**, wherever you hover it, opening beside the window instead of over the list. Choices show as their icons.
- The winner's roll shows first, so it's never cut off by a long name or boss name.
- **Window height** moves in whole rows, so the list shows whole rows. "Fixed window height" is gone: the window keeps one height unless you turn on "Grow with drops".
- **Try the demo** button in the empty window.
- **Safer.** If anything goes wrong showing your rolls, Blizzard's roll popups come back at once, and a chat line says so. A watchdog makes sure a roll waiting for you always has buttons somewhere. Rolls still open after a /reload are picked up. Smaller extras switch themselves off quietly if they hit a problem, and rolling keeps working.
- **`/rollframes reset all`** starts over completely, after asking: every setting, the window, and this character's loot history.
- Lighter: about half the UI updates of v1.1 in a real 5-man run with the same view (two thirds fewer with the new one-row view), and fewer frames and less memory in raids.
- Settings you never changed now follow the defaults, so improvements reach you automatically. Anything you chose stays.

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
