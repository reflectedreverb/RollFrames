# RollFrames

## v1.3.0

### New
All settings are under Options → AddOns → RollFrames. New options that are off by default change nothing until you turn them on, and the page's Defaults button puts every setting back.

- **Roll button size:** Small, Medium, Large or Extra large (the size of Blizzard's own roll buttons). Medium is the new default; see Changed.
- **Window size:** make the whole window anywhere from 75% to 200%. Text, icons, roll buttons and rows grow together, and the window stays on screen. It stays at 100% until you change it. Also `/rollframes size 150`.
- **Glow on hovered buttons:** a soft gold glow behind the roll button under your mouse, so you can see which one a click will hit. It's on when you roll from the window, and you can turn it off.
- **Tooltips:** a new section of settings. The item's tooltip shows over the whole drop, as before, or only over its icon if you prefer. A small tip by the roll button under your mouse says which roll it is, why it can't be chosen, or that the list just moved; it's on, and you can turn it off. Tooltips can also open where the game shows its own, if you turn that on.
- **Sweep when a roll ends:** a soft band crosses the drop once: gold when you win, grey when someone else does (in Detailed, gold on the winner's line). It's on, and you can turn it off in Motion and flashing.
- **Your wins stay marked:** a faint gold tint and a checkmark after your name, in the list and in History.
- **A 100 lights up:** anyone's 100 plays a short burst on that drop's choice icon. With Flashing set to Off, it's a still glow instead.
- **Animations can be turned off,** if you prefer: No animations in Motion and flashing is an accessibility option for motion sensitivity. Everything then appears, changes and goes at once, while the roll timers still count down. For just a little less motion, Flashing: Off and Sweep when a roll ends are there too.
- **Don't show this again** under the empty window's Try the demo button hides the demo offer for good. `/rollframes demo` still plays it.

### Changed
- **Controller mode:** you roll in the game's own gamepad roll list; the window's roll buttons step aside while controller mode is on and come back when it's off.
- **Bigger roll buttons if you roll from the window.** They're now Medium by default (25 px, up from 20), and each drop's row is a little taller. To go back: Options → AddOns → RollFrames → Roll button size: Small.
- **"Above roll popups" is gone.** A window that sat above Blizzard's roll popups starts beside the quest tracker again; drag it anywhere, and it stays there.
- **"Player lines" is now "View":** Compact (was Summary), Auto, Detailed (was Everyone) and Items only (was None). Your choice is kept.
- **Settings grouped by task:** Rolling, Window, History, Tooltips, Motion and flashing. What needs Roll from this window sits under it, greyed out while it's off. Click guard and its time are two rows, and both can be found with the Options search.
- **The window moves by its title bar.** Dragging elsewhere in the window no longer moves it, so a drag meant for the corner or the list can't shift it.
- **Dragging the corner no longer snaps to whole rows:** it goes exactly where you drag it. For the old feel, tick Snap to whole rows (Window).
- **The window keeps the height you drag it to** (unless Grow with drops is on), and changing the button size never resizes it. Its resize corner shows while the mouse is over the window.
- **Options opens in front of the window.** While a drop waits for your roll, the window stays on top, like Blizzard's roll popups.
- **Detailed view: after you roll, your choice takes the buttons' place,** as in Compact. Your roll number stays on your own line, with everyone's.
- **A slim scrollbar,** shown only while the list scrolls. Rows no longer shift sideways when it appears.
- Compact view's Need, Greed and Pass counts line up in columns down the list.
- In a window you keep open, the demo's drops fade out a little after the last one is decided and leave nothing in History.
- `/rollframes reset` also puts Window size back to 100%.
- The roll highlights and the window's flash now run in the game's own animation engine, instead of being redrawn by the addon every frame.

### Fixed
- **No more "RollFrames has been blocked" in Options.** After opening RollFrames' settings, typing in the Options search or opening another page could get Blizzard's own Discord setting blocked, with RollFrames named. Settings now use Blizzard's plain section headers (hovering one shows its name, as on Blizzard's pages).
- **Ctrl-click in combat** no longer prints "Interface action failed because of an AddOn": the game doesn't let addons open the dressing room in a fight, so the click does nothing then; Ctrl-click again after the fight (with the dressing room already open, it still previews).
- Item comparison tooltips ("Equipped") open on the far side of the item's tooltip, not over the window and its roll buttons.
- When someone chose Need, Greed choices never get a roll; once the roll is over they now show "-" instead of "…", which looked like they were still rolling. The demo follows the same rule.
- The close button sits in the window's corner at every size.
- Your roll number is centred beside your choice; roll icons in drop tooltips line up.
- A damaged settings file no longer stops RollFrames at login: a broken value goes back to its default.

## v1.2.1

- **Roll buttons in Blizzard's order.** Need, Greed and Pass now read left to right, with Pass on the right, like Blizzard's roll popup. Each still keeps a fixed spot on every drop.

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
