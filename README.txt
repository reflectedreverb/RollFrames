RollFrames
A ReflectedReverb Addon, for World of Warcraft: Forever

Group loot rolls, live, in one window that looks like Blizzard's own UI.

Each drop gets a card with a line for every player from the start ("..." while
they decide). Their Need, Greed or Pass appears the moment they pick it, with
roll numbers as they're revealed: your own line first, then rolls in the order
they came in, then players still deciding, then passes. A drop keeps the same
height for its whole roll, so the roll buttons stay put as people choose.
The winner is highlighted, then the card shrinks to a compact history row with
the item, the winner and the boss it came from. Prefer less detail? Show one
summary line per drop, or just the items.

Optional Need, Greed and Pass buttons on each card. While they're on and the
window is open, Blizzard's roll popups stay hidden; if anything goes wrong, or
you close the window, Blizzard's popups come back.

This tracks group loot rolls (Need, Greed and Pass), not /roll number rolls.


INSTALL

1. Close the game.
2. Copy the RollFrames folder into:
   World of Warcraft/_forever_/Interface/AddOns/
3. Start the game and make sure RollFrames is ticked in the AddOns list.


USE

/rollframes            Show or hide the window
/rollframes demo       Play three made-up drops, so you can see it without a group
                       (/rollframes demo 10 for more, up to 20)
/rollframes options    Open the settings (also under Options > AddOns > RollFrames)
/rollframes reset      Put the window back above the roll popups at its normal size
/rollframes blizzard   Open Blizzard's own loot history
/rollframes diag       A short status for bug reports (no names)
/rollframes diag log   Turn a troubleshooting log on or off (saved with your
                       settings, never includes names)

The AddOns button by the minimap also works: left-click shows or hides the
window, right-click opens the settings.

Drag the window to move it; drag the grip in its corner to set how tall it may
grow. Longer lists scroll.


SETTINGS

Open when a roll starts      Show the window when a group loot roll starts (on).
                             Off: it stays in the background and keeps track;
                             open it yourself when you want it. While it's
                             closed, Blizzard's roll popups show as usual.
Roll from this window        Need, Greed and Pass buttons on each drop (off).
                             Two copies of one item at once: a click uses
                             either of your rolls on it; your choice shows on
                             the copy the game reports it for.
Player lines                 Auto (default: Everyone in a party, Summary in
                             a raid), Everyone (a line per player), Summary
                             (one line of counts; hover for everyone's rolls)
                             or None (just the items, with your own choice)
Position                     Attached above the roll popups (default), or free
Fixed window height          Keep the height you set with the corner grip;
                             longer lists scroll (off)
Show rolls after a winner    How long the full list stays (5 seconds)
Hide when idle after         Fade once everything is decided and quiet
                             (15 seconds, or never). A window you open
                             yourself stays until you close it (the pin by
                             the close button is lit; click it to switch).
Hovering stops the fade      Hovering keeps the window from fading (on)
Minimum quality kept         Lowest quality kept as a history row once a roll
                             is decided: all items (default), or uncommon /
                             rare / epic and better. Rolls of any quality
                             always show while they run; every drop is still
                             in Blizzard's loot history (/loot).
Keep trash drops             Off: only boss loot stays in the history (on)
History length               Finished drops listed as compact rows (10).
                             Older ones leave the list; Blizzard's loot
                             history (/loot) still has them.
