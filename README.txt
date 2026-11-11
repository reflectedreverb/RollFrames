RollFrames
A ReflectedReverb Addon, for World of Warcraft: Forever

Group loot rolls, live, in one window that looks like Blizzard's own UI.

Each drop is one steady row: how many chose Need, Greed and Pass (as their
icons), your own choice and roll, and the winner with their roll the moment
it's decided. Hover a drop for everyone's rolls (in a raid: the Need rolls and
a count of the rest). Prefer more detail? Player lines: Everyone gives each
player a line.

History: decided drops move under the clock in the title bar after a minute,
or as soon as the window fades out; click the clock to bring them back. It's
kept for each character across reloads (100 drops by default); the X clears
it, after asking.

Optional Need, Greed and Pass buttons on each drop. While they're on and the
window is open, Blizzard's roll popups stay hidden; if anything goes wrong, or
you close the window, Blizzard's popups come back. When new loot moves the
list, buttons that slide under a still mouse ignore clicks for a moment, so a
click meant for one item can't land on another.

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
/rollframes reset      Put the window back in its starting spot at its normal size
/rollframes reset all  Start over completely, after asking: every setting, the
                       window, and this character's loot history (reloads)
/rollframes blizzard   Open Blizzard's own loot history
/rollframes diag       A short status for bug reports (no names)
/rollframes diag log   Turn a troubleshooting log on or off (saved with your
                       settings, never includes names)

The AddOns button by the minimap also works: left-click shows or hides the
window, right-click opens the settings.

The window opens on the right, beside the quest tracker. Drag its title bar to
move it; drag the grip in its corner to set its height (in whole rows). Longer
lists scroll. With nothing in it yet, it offers a "Try the demo" button.


SETTINGS (Options > AddOns > RollFrames)

Window
Open when a roll starts      Show the window when a group loot roll starts (on).
                             Off: it keeps track in the background. While it's
                             closed, Blizzard's roll popups show as usual.
Roll from this window        Need, Greed and Pass buttons on each drop (off).
                             Two copies of one item at once: a click uses
                             either of your rolls on it; your choice shows on
                             the copy the game reports it for.
Player lines                 Summary (default: one row per drop; hover for
                             everyone's rolls), Auto (a line per player in a
                             party, Summary in a raid), Everyone, or None
Click guard                  On, 2 seconds (or half a second to 5 seconds, or
                             until the mouse moves); a guarded click plays a
                             short sound
Position                     Free (default: beside the quest tracker until you
                             drag it) or Above roll popups
Grow with drops              Grow with the drops up to the height you set (off)
Hide when idle after         Fade once everything is decided and quiet
                             (15 seconds, or never; hovering restarts it). A window you open
                             yourself stays until you close it (the pin by
                             the close button is lit; click it to switch).

History
Minimum quality kept         All items (default), or uncommon / rare / epic and
                             better. Lower items fade out once decided and
                             aren't kept in History. Every drop is still in
                             Blizzard's loot history (/loot).
Keep trash drops             Off: only boss loot stays once decided (on)
History keeps                Decided drops kept for this character (100)
Finished drops stay          How long a decided drop stays in the list before
                             it moves to History (1 minute, or until cleared)

Accessibility
Highlight drops to roll      Gold border (default), glowing timer bar,
                             sparkles, all three, or off (needs Roll from this
                             window)
Flashing                     Normal (default), Until noticed, or Off

MORE ADDONS

More addons by ReflectedReverb: https://github.com/reflectedreverb
