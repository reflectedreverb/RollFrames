RollFrames
A ReflectedReverb Addon, for World of Warcraft: Forever

Group loot rolls, live, in one window that looks like Blizzard's own UI.

Each drop is one steady row: how many chose Need, Greed and Pass (as their
icons), your own choice and roll, and the winner with their roll the moment
it's decided. Hover a drop for everyone's rolls (in a raid: the Need rolls and
a count of the rest). Prefer more detail? View: Detailed gives each player a
line with their choice and roll. Your wins stand out with a gold sweep, then a
faint gold tint and a checkmark after your name.

History: decided drops move under the clock in the title bar after a minute,
or as soon as the window fades out; click the clock to bring them back. It's
kept for each character across reloads and logouts (100 drops by default);
the X clears it, after asking.

Optional Need, Greed and Pass buttons on each drop, in four sizes up to
Blizzard's own, with a gold glow behind the one under your mouse. While
they're on and the window is open, Blizzard's roll popups stay hidden; if
anything goes wrong, or you close the window, Blizzard's popups come back.
When new loot moves the list, buttons that slide under a still mouse ignore
clicks for a moment, so a click meant for one item can't land on another.

Window size makes the whole window 75% to 200%. Flashing can be turned off,
and No animations stops all animation (the roll timers still count down).

This tracks group loot rolls (Need, Greed and Pass), not /roll number rolls.


INSTALL

1. Close the game.
2. Copy the RollFrames folder into:
   World of Warcraft/_forever_/Interface/AddOns/
3. Start the game and make sure RollFrames is ticked in the AddOns list.


USE

/rollframes            Show or hide the window
/rollframes demo       Play three made-up drops, so you can see it without
                       a group (/rollframes demo 10 for more, up to 20)
/rollframes options    Open the settings (also under
                       Options > AddOns > RollFrames)
/rollframes size 150   Set the Window size (75 to 200); on its own, show it
/rollframes reset      Put the window back in its starting spot, at its
                       starting height and 100% Window size
Options > AddOns > RollFrames > Defaults (then These Settings) puts every
                       setting back and keeps your History
/rollframes reset all  Start over completely, after asking: every setting,
                       the window, and this character's loot history
                       (reloads)
/rollframes blizzard   Open Blizzard's own loot history
/rollframes diag       A short status for bug reports (no names)
/rollframes diag log   Turn a troubleshooting log on or off (saved with your
                       settings, never includes names)

The AddOns button by the minimap also works: left-click shows or hides the
window, right-click opens the settings.

The window opens on the right, beside the quest tracker. Drag its title bar
to move it. Hover the window to show the grip in its corner, and drag it to
set the height; longer lists scroll. With nothing in it yet, it offers a
"Try the demo" button; "Don't show this again" under it hides the offer.


SETTINGS (Options > AddOns > RollFrames)

Rolling
Open when a roll starts      Show the window when a group loot roll starts
                             (on). Off: it keeps track in the background.
                             While it's closed, Blizzard's popups show.
Roll from this window        Need, Greed and Pass buttons on each drop (off).
                             Two copies of one item at once: a click uses
                             either of your rolls on it. In controller mode
                             you roll in the game's gamepad roll list.
  Roll button size           Small, Medium (default), Large, or Extra large
                             (Blizzard's own size)
  Highlight drops to roll    Gold border (default), glowing timer bar,
                             sparkles, all three, or off
  Glow on hovered buttons    A gold glow behind the button under the mouse (on)
  Click guard                Buttons that slide under a still mouse ignore
                             clicks for a moment (on); a short sound plays
  Click guard time           2 seconds (half a second to 5, or until the
                             mouse moves)

Window
View                         Compact (default: one row per drop; hover for
                             everyone's rolls), Auto (raids: Compact),
                             Detailed (a line per player), or Items only
Window size                  75% to 200% (100%)
Grow with drops              Grow with the drops up to the height you set
                             (off)
Snap to whole rows           Drag the corner a whole row at a time (off)
Hide when idle after         Fade once everything is decided and quiet
                             (15 seconds, or never; hovering restarts it).
                             A window you open yourself stays until you
                             close it (click the pin to switch).

History
Finished drops stay          How long a decided drop stays in the list
                             before it moves to History (1 minute)
Minimum quality kept         All items (default), or uncommon / rare / epic
                             and better. Every drop is still in Blizzard's
                             loot history (/loot).
Keep trash drops             Off: only boss loot stays once decided (on)
History keeps                Decided drops kept for this character (100)

Tooltips
Item tooltip                 Whole drop (default) or Item icon only
Roll button tooltips         A small tip by the button under the mouse (on)
Tooltips at game's spot      Open them where the game shows its own (off)

Motion and flashing
No animations                Everything at once; timers still count (off)
Flashing                     Normal (default), Until noticed, or Off
Sweep when a roll ends       A soft band across the drop as it ends (on)


MORE ADDONS

More addons by ReflectedReverb: https://github.com/reflectedreverb
