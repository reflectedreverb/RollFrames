-- RollFrames: live group loot rolls in one Blizzard-style window.
-- Each drop gets a card. While rolls are open, every player has a line from the start ("..." until
-- they choose): your own first, then rolls in the order they came in, then players still deciding,
-- then passes. Choosing moves a line within the card, so the card's height (and your roll buttons) stay
-- put. "Player lines" can show a one-line summary or nothing instead. When a winner is picked, their
-- line is highlighted with a sweep, the rolls stay a few seconds, then the card collapses to a compact
-- row: item (hover for tooltip), winner, and the boss it came from.
-- Data: C_LootHistory (Blizzard's loot history, built into Forever) plus START_LOOT_ROLL for
-- the roll timer and optional Need/Greed/Pass buttons (RollOnLoot).
-- Commands: /rollframes | demo | options | reset | blizzard | diag

local ADDON = "RollFrames"
-- Grey footer at the end of the settings page. Set to "" to leave the spot blank.
local FOOTER = "ReflectedReverb Addons"

-- The footer row: a section header without the hover tooltip every header gets (it would only repeat
-- the text). The settings list reuses rows for other headers, so the row's mouse settings come back when it lets go.
local function footerInitializer()
	local init = CreateSettingsListSectionHeaderInitializer("|cff8c8c8c" .. FOOTER .. "|r")
	local initFrame, resetter = init.InitFrame, init.Resetter
	local mouse = {} -- row -> its mouse settings before the footer turned them off
	function init:InitFrame(frame)
		initFrame(self, frame)
		if not mouse[frame] then
			mouse[frame] = { frame:IsMouseClickEnabled(), frame:IsMouseMotionEnabled() }
		end
		frame:EnableMouse(false)
	end
	function init:Resetter(frame)
		local was = mouse[frame]
		if was then -- put back exactly what the row had, for the header that reuses it
			frame:SetMouseClickEnabled(was[1])
			frame:SetMouseMotionEnabled(was[2])
			mouse[frame] = nil
		end
		resetter(self, frame)
	end
	return init
end

-- Layout
local WIDTH = 300
local SIDE_PAD = 10
local TITLE_H = 28
local BOTTOM_PAD = 10
local CARD_GAP = 4
local HEADER_H = 34
local ICON = 28
local LINE_H = 18
-- Heights are whole-row steps (History.snapHeight: 38 per row plus 56).
local MAX_HEIGHT = 550 -- default for the user's height limit (db.maxHeight) when the window grows: 13 rows
local FIXED_HEIGHT = 322 -- default height of a window that doesn't grow (db.height): 2 live 5-man drops, or 7 rows
	-- with the "more to roll" bar clear below them (user, 2026-11-10)
-- Never shorter than two compact rows: Blizzard's panel template draws broken corners on a shorter window
-- (tried one row in game, 2026-11-08).
local MIN_HEIGHT = TITLE_H + 2 * HEADER_H + CARD_GAP + BOTTOM_PAD
local SCROLLBAR_W = 10 -- space kept on the right for the scrollbar when the list scrolls

-- Enum.EncounterLootDropRollState: NeedMainSpec 0, NeedOffSpec 1, Transmog 2, Greed 3, NoRoll 4, Pass 5.
local STATE = { NEED = 0, NEED_OFF = 1, TRANSMOG = 2, GREED = 3, NOROLL = 4, PASS = 5 }
local STATE_ATLAS = {
	[0] = "lootroll-toast-icon-need-up", [1] = "lootroll-toast-icon-need-up",
	[2] = "lootroll-toast-icon-transmog-up", [3] = "lootroll-toast-icon-greed-up",
	[5] = "lootroll-toast-icon-pass-up",
}
-- RollOnLoot roll types, right to left: Need, Greed and Pass always in these spots; Transmog to the left
-- of Pass, shown only on a roll that allows it (none seen on Forever so far), so the others never move.
local ROLL_BUTTONS = {
	{ type = 1, atlas = "lootroll-toast-icon-need", label = "Need", can = "canNeed" },
	{ type = 2, atlas = "lootroll-toast-icon-greed", label = "Greed", can = "canGreed" },
	{ type = 0, atlas = "lootroll-toast-icon-pass", label = "Pass" },
	{ type = 4, atlas = "lootroll-toast-icon-transmog", label = "Transmog", can = "canTransmog", onlyIfAllowed = true },
}
ROLL_BUTTONS.can = {} -- what the current roll allows (see cardRollTypes)

-- Where a player's line sits in a card: you on top, then rolls in the order they came in, then the
-- players still deciding, then passes. Lines only trade places, so one choice moves two lines at most.
local GROUP_YOU, GROUP_ROLLED, GROUP_DECIDING, GROUP_PASSED = 1, 2, 3, 4
-- A roll button's choice as the loot history reports it.
local CLICK_STATE = { [1] = STATE.NEED, [2] = STATE.GREED, [4] = STATE.TRANSMOG, [0] = STATE.PASS }

local DEFAULTS = {
	autoOpen = true,
	rollFromWindow = false,
	-- "auto" (Everyone in parties, Summary in raids), "all" (a line per player), "summary" (one line of
	-- counts) or "none" (item row only)
	playerLines = "summary", -- (Auto until 2026-11-10: the user chose one calm row per drop for everyone)
	-- Drops waiting for your roll (their roll buttons show, so only with rollFromWindow): "border" (a pulsing
	-- gold frame), "timer" (the timer bar glows, with a spark at its edge), "sparkle", "all" or "off".
	highlightRolls = "border",
	-- Accessibility: "normal" (pulses, sweeps, one flash when new loot brings the window back from History),
	-- "persist" (that flash repeats until you hover the window) or "off" (nothing flashes or pulses).
	flashing = "normal",
	keepTrash = true, -- false: drops from trash (encounter 0) leave the history once decided
	position = "free", -- or "attached" (the default until 2026-11-10); free and never dragged: right of centre
	-- Internal, no longer settings (removed from Options 2026-11-10, user: simpler; what they were and how to
	-- bring them back: docs/rollframes-removed-settings.md). Kept as values because tests still use them.
	newOrder = "top", -- new drops appear "top" (older below, History under them) or "bottom"
	hoverHold = "off", -- what holds the list under the mouse: "off", "buttons" or "window"
	snapRows = true, -- heights in whole-row steps (History.snapHeight)
	holdSeconds = 5, -- how long a decided drop shows its result before it becomes a history row
	-- Click guard: roll buttons that slide under a still cursor (the list moved) ignore clicks, dimmed, for
	-- guardTime seconds or until the mouse moves a button's width (guardTime 0: only when the mouse moves).
	buttonGuard = true,
	guardTime = 2,
	autoHide = 15, -- seconds after the last activity; 0 = never
	historyCount = 20, -- decided rows kept in the list (fixed, no setting since 2026-11-10; the rest are in History)
	historyKeep = 100, -- decided drops History keeps (saved per character across reloads): 50/100/250/500
	historyFade = 60, -- seconds a decided drop stays in the list before it fades into History; 0 = until cleared
	historyMinQuality = 0, -- 0 = keep every item in the history; 2/3/4 = uncommon/rare/epic and better
	-- The window keeps one height (db.height, set by dragging its corner; longer lists scroll) unless the player
	-- turns on "Grow with drops": then it grows with its drops up to db.maxHeight (also set by dragging).
	autoGrow = false,
	height = FIXED_HEIGHT,
	maxHeight = MAX_HEIGHT,
}

-- Saved settings hold only real choices (see Saved, below): a setting the player never changed isn't stored,
-- so reading it gives the current default, and changing a default here reaches everyone who didn't choose
-- otherwise. Change defaults freely; add a Saved.MIGRATIONS step only to carry choices across a rename or a
-- changed meaning.
local Saved = {
	-- Saved values that aren't settings (kept as they are). Anything else that isn't a setting is removed at
	-- login (settings that no longer exist).
	STATE = { point = true, log = true, pairLog = true, askedRollHere = true, askClosed = true, debugLog = true,
		settingsVersion = true, historySaved = true, lastError = true },
	-- v1.1.0's defaults: it saved every setting, defaults included, so a v1.1 file's values equal to these
	-- weren't choices (step 2 removes them).
	V11 = { autoOpen = true, rollFromWindow = false, playerLines = "auto", hoverHoldsFade = true, keepTrash = true,
		position = "attached", holdSeconds = 5, autoHide = 15, historyCount = 10, historyMinQuality = 0,
		fixedHeight = false, maxHeight = 560 }, -- (v1.1's own number: MAX_HEIGHT has changed since)
	MIGRATIONS = {}, -- [settings version] = function(db): one-off conversions, run once each, in order
}
Saved.MIGRATIONS[2] = function(db) -- v1.1 -> v1.2
	-- v1.1 kept a dragged spot after you chose Attached again; it would come back now that Free is the default.
	if rawget(db, "position") == "attached" then
		db.point = nil
	end
	-- "Fixed window height" ticked: that size becomes the (now default) fixed height.
	if rawget(db, "fixedHeight") == true and rawget(db, "maxHeight") then
		db.height = db.maxHeight
	end
	for key, value in pairs(Saved.V11) do
		if rawget(db, key) == value then
			db[key] = nil -- a v1.1 default, not a choice
		end
	end
	db.fixedHeight, db.historyCount, db.newestAt = nil, nil, nil -- gone: replaced, now fixed, dev-only
	db.holdSeconds = nil -- ("Show rolls after a winner" left Options in v1.2: everyone gets 5 s)
	if rawget(db, "historyKeep") == 0 then db.historyKeep = nil end -- (a dev build's "All", no longer offered)
	if rawget(db, "historyFade") == 120 then db.historyFade = nil end -- (a dev build's default)
	-- The two defaults a v1.1 player sees change (left at v1.1's, so they follow the new ones): one chat line,
	-- once (this step only ever runs once), saying what changed and how to go back (user, 2026-11-10).
	-- REMOVE in the release after v1.2: by then upgraders have seen it (docs/todo/RollFrames.md, "Later").
	local moved = rawget(db, "position") == nil or (rawget(db, "position") == "free" and rawget(db, "point") == nil)
	local lines = rawget(db, "playerLines") == nil
	if moved or lines then
		Saved.upgradeNote = { moved = moved, lines = lines }
	end
end
Saved.LATEST = 2

-- The upgrade note (see MIGRATIONS[2]); shown a few seconds after login. REMOVE with it.
function Saved.showUpgradeNote()
	local n = Saved.upgradeNote
	Saved.upgradeNote = nil
	if not n then
		return
	end
	local where = "Options > AddOns > RollFrames"
	local text
	if n.moved and n.lines then
		text = "the window now sits on the right, beside the quest tracker, with one row per drop (hover a drop "
			.. "for everyone's rolls). To go back: " .. where .. ", Position: Above roll popups, Player lines: Auto."
	elseif n.moved then
		text = "the window now sits on the right, beside the quest tracker. To put it back above Blizzard's roll "
			.. "popups: " .. where .. ", Position: Above roll popups."
	else
		text = "each drop is now one row (hover it for everyone's rolls). For a line per player again: "
			.. where .. ", Player lines: Auto."
	end
	print("|cff66ccffRollFrames|r was updated: " .. text .. " Finished drops now move under the clock (History) "
		.. "in the title bar.") -- (say() is defined further down)
end

-- Drops what isn't a choice: values equal to their current default, and keys that are neither settings nor
-- saved state. Runs at login and logout, so the saved file only ever holds real choices.
function Saved.prune(db)
	for key, value in pairs(db) do
		local default = DEFAULTS[key]
		if default ~= nil then
			if value == default then
				db[key] = nil
			end
		elseif not Saved.STATE[key] then
			db[key] = nil
		end
	end
end

function Saved.load(db)
	if next(db) ~= nil then -- (a new install has nothing to convert)
		for version = (tonumber(rawget(db, "settingsVersion")) or 1) + 1, Saved.LATEST do
			if Saved.MIGRATIONS[version] then
				Saved.MIGRATIONS[version](db)
			end
		end
	end
	db.settingsVersion = math.max(tonumber(rawget(db, "settingsVersion")) or 0, Saved.LATEST) -- (never lower it)
	Saved.prune(db)
	setmetatable(db, { __index = DEFAULTS }) -- a setting not stored reads as its default
end


local db
local main, content, scroll, scrollBar, grip
local shownNewestAtBottom -- the direction the list was last laid out in
local scrollToNewestPending = false -- a new drop arrived: show it (scroll to its end) when the mouse isn't over the window
local cards = {} -- newest first
local cardsByHistory = {} -- "encounterID:lootListKey" -> card
local trimPending = true -- history needs trimming at the next layout (a card collapsed, or the setting changed)
local demoCardCount = 0 -- demo cards currently in the list
local demoClears = 0 -- counts clearDemoCards runs, so the dev stress test can tell it was interrupted
local cardsByRollID = {}
local anchorFactor = 1 -- how the window grows: 1 = from its bottom (attached), 0 = from its top (free)
local holdWatch -- frame that waits for a held card to let go (see heldCard)
local askShown = false -- the "Roll from this window?" question is showing (see "First-use question")
local askPutAway = false -- put away unanswered for combat: back a few seconds after the fight
local maybeAsk, hideAsk, Ask -- forward declarations (defined with the question; Ask is its table)
-- History (the clock in the title bar): records of drops decided this session, newest first. The clock
-- brings back the ones that have left the list as rows that continue it on its older side; only the rows
-- in view have a frame (reused as you scroll). Demo drops keep their own records, so a demo never touches
-- your real history.
local History = { records = {}, demo = {}, merged = {}, rows = {}, shown = false, top = 0, seq = 0,
	MAX = 500, ROW_H = HEADER_H + CARD_GAP,
	byMark = {}, -- drop mark (item link @ start time) -> its record, so a drop seen again (a reload) isn't added twice
	cardOf = setmetatable({}, { __mode = "k" }), -- record -> { card, gen } while its card may still be listed
}
-- "encounterID:lootListKey" -> the drop left out of the list (faded, trimmed, cleared or filtered): later
-- updates for that drop are ignored. The value is the drop's mark (item link and start time; true when not
-- known), so if the game ever reused a key for a different drop, that drop is still new loot.
local skippedHistory = {}
local dismissCard -- forward declaration (defined with the frame pool)
local nextCardID = 0
-- Fail-safes. The rolls come first: an error in what shows a roll and its buttons (events, layout, the
-- watchdog) switches back to Blizzard's popups for the session (Guard.fail). An error in an extra (the
-- highlight, markers, History, the demo...) switches only that extra off for the session (Guard.trip),
-- quietly: the troubleshooting log gets one entry and rolling keeps working. off[name]: that extra is off.
local Guard = { fallback = false, off = {}, fails = 0 }
local lastActivity = 0
local layout -- forward declaration
local updateRollMarkers, scrollToWaitingFn -- forward declarations (the "more to roll" markers, after layout)
local markersDirty = false -- the markers need a recount (done once, on the next frame)
-- Pinned: the window stays until closed (it was opened by hand, or the pin was clicked). Unpinned, it fades
-- once loot is decided and nothing has happened for the idle time, with a short draining line first.
local pinned = false
local COUNTDOWN = 5 -- seconds of draining line before an idle window fades
local PIN_ATLAS = "Waypoint-MapPin-Tracked"
local CHROME_IDLE_ALPHA = 0.6 -- border and background of a window that fades when idle (text stays solid)
local setPinned, refreshPin, fadeEligible, startFade -- forward declarations (defined with auto-hide)
local log, logging -- forward declarations (defined with the troubleshooting log)

local function say(...)
	print("|cff66ccffRollFrames:|r", ...)
end

-- Remembers an error for /rollframes diag (saved, so a bug report can quote it) and writes it to the
-- troubleshooting log, once per place. Never raises: it runs on the way into a fail-safe.
function Guard.note(where, err)
	pcall(function()
		local text = tostring(where) .. ": " .. tostring(err)
		db.lastError = date("%Y-%m-%d %H:%M ") .. text:sub(1, 300)
		Guard.noted = Guard.noted or {}
		if not Guard.noted[where] then
			Guard.noted[where] = true
			if logging() then
				log("error", { where = where, error = tostring(err) })
			end
		end
	end)
end

-- Switches the extra `name` off for the session after an error, and runs its clean-up (Guard.stops).
Guard.stops = {}
function Guard.trip(name, err)
	if Guard.off[name] then
		return
	end
	Guard.off[name] = true
	Guard.note(name, err)
	if Guard.stops[name] then
		pcall(Guard.stops[name])
	end
end

-- Guard.test is set only by the dev command /rollframes fail <part>: that part runs Guard.boom instead,
-- to watch its fail-safe work in game.
function Guard.boom()
	error("test failure (/rollframes fail " .. tostring(Guard.test) .. ")")
end
function Guard.run(name, fn, ...) -- (for code that calls pcall itself)
	if Guard.test == name then
		Guard.boom()
	end
	return fn(...)
end

-- Runs an extra's fn; an error switches that extra off. Returns false if it errored or is off.
function Guard.call(name, fn, ...)
	if Guard.off[name] then
		return false
	end
	local ok, err = pcall(Guard.test == name and Guard.boom or fn, ...)
	if not ok then
		Guard.trip(name, err)
	end
	return ok
end

-- Runs part of what shows the rolls; an error brings Blizzard's popups back for the session (Guard.fail).
function Guard.core(where, fn, ...)
	local ok, err = pcall(Guard.test == where and Guard.boom or fn, ...)
	if not ok then
		Guard.fail(err, where)
	end
	return ok
end

-- The same for scripts and timers: Guard.wrap for an extra, Guard.wrapCore for the rolls. An OnUpdate
-- script of an extra that is off hides its frame, so it stops running. (OnUpdate wrappers take exactly
-- the two arguments OnUpdate gets: they run every frame.)
function Guard.wrap(name, fn)
	return function(...)
		Guard.call(name, fn, ...)
	end
end
-- interval: run at most that often (seconds), with the time since the last run as elapsed, so a check
-- that runs a few times a second makes its protected call only then, not every frame.
function Guard.wrapUpdate(name, fn, interval)
	local since = 0
	return function(self, elapsed)
		if interval then
			since = since + elapsed
			if since < interval then
				return
			end
			elapsed, since = since, 0
		end
		if Guard.off[name] then
			self:Hide()
			return
		end
		local ok, err = pcall(Guard.test == name and Guard.boom or fn, self, elapsed)
		if not ok then
			Guard.trip(name, err)
		end
	end
end
function Guard.wrapCore(where, fn)
	return function(...)
		Guard.core(where, fn, ...)
	end
end
function Guard.wrapCoreUpdate(where, fn, interval)
	local since = 0
	return function(self, elapsed)
		if interval then
			since = since + elapsed
			if since < interval then
				return
			end
			elapsed, since = since, 0
		end
		local ok, err = pcall(Guard.test == where and Guard.boom or fn, self, elapsed)
		if not ok then
			self:Hide() -- (no error every frame)
			Guard.fail(err, where)
		end
	end
end

local function isSecret(value)
	return issecretvalue and issecretvalue(value)
end

local function safe(value, default)
	if value == nil or isSecret(value) then
		return default
	end
	return value
end

local function itemIDFromLink(link)
	return link and tonumber(link:match("item:(%d+)"))
end

-- Which item a link is, for pairing rolls with drops and spotting copies: the item ID plus its random
-- suffix ("of the Eagle" and "of the Monkey" are different items), without the unique instance ID.
local function itemKeyFromLink(link)
	if not link or isSecret(link) then
		return nil
	end
	local str = link:match("item:([%-%d:]+)")
	local id = str and str:match("^(%d+)")
	if not id then
		return nil
	end
	local n, suffix = 0, nil
	for field in (str .. ":"):gmatch("([^:]*):") do
		n = n + 1
		if n == 7 then
			suffix = field
			break
		end
	end
	return id .. ":" .. ((suffix and suffix ~= "") and suffix or "0")
end

-- The game's class colour around a name. Blizzard's RAID_CLASS_COLORS keeps each colour's code ready
-- (colorStr), so this makes one string; C_ClassColor makes a new colour object every call.
local function classColored(name, class)
	local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if color and type(color.colorStr) == "string" then
		return "|c" .. color.colorStr .. name .. "|r"
	end
	color = class and C_ClassColor and C_ClassColor.GetClassColor(class)
	return color and color:WrapTextInColorCode(name) or name
end

----------------------------------------------------------------------------------------------------
-- Tweens: one OnUpdate driver for every animation (slides, fades, height changes, sweeps).
----------------------------------------------------------------------------------------------------

local tweens = {}
local driver = CreateFrame("Frame")
driver:Hide()

local function easeOut(p)
	return 1 - (1 - p) ^ 3
end

-- Runs fn(progress 0..1, eased) over duration seconds; a new tween with the same key replaces the old one.
local function tween(key, duration, fn, done, linear)
	-- Nobody can see an animation while the window is hidden: jump straight to the end (measured: 29 ms/s
	-- of animation with the window closed in the stress test). Nothing is ever mid-flight when it opens.
	-- Animations switched off after repeated errors (Guard.animationFailed) jump to the end the same way.
	if Guard.off.animations or (main and not main:IsVisible()) then
		tweens[key] = nil
		local ok, err = pcall(fn, 1)
		if ok and done then
			ok, err = pcall(done)
		end
		if not ok then
			Guard.animationFailed(err)
		end
		driver:Show() -- one frame, so a pending history trim still runs while hidden (the driver does it)
		return
	end
	tweens[key] = { duration = math.max(duration, 0.01), elapsed = 0, fn = fn, done = done, linear = linear }
	driver:Show()
end

local relayoutPending = false
local finished = {} -- scratch list of tweens that ended this frame, emptied after each use
local trimHistory -- forward declaration (defined with the cards)
-- One frame of every running animation. driver.current names the one running, so one that errors is
-- dropped (Guard.animationFailed) and the rest carry on next frame.
function driver.step(elapsed)
	-- Start clean every frame, so an error in some tween's finish step last frame can't leave entries behind.
	wipe(finished)
	for key, t in pairs(tweens) do
		driver.current = key
		t.elapsed = t.elapsed + elapsed
		local p = math.min(1, t.elapsed / t.duration)
		if Guard.test == "animations" then
			error("test failure (/rollframes fail animations)")
		end
		t.fn(t.linear and p or easeOut(p))
		if p >= 1 then
			finished[#finished + 1] = key
		end
	end
	driver.current = nil -- (a finish step that errors: its tween is already gone)
	for i = 1, #finished do
		local key = finished[i]
		finished[i] = nil
		local t = tweens[key]
		tweens[key] = nil
		if t and t.done then
			t.done()
		end
	end
end
-- driver.profiling and driver.ms: time spent here, measured only while the dev stress test runs.
driver.ms = 0
driver:SetScript("OnUpdate", function(self, elapsed)
	local profileStart = self.profiling and debugprofilestop()
	local ok, err = pcall(self.step, elapsed)
	if not ok then
		Guard.animationFailed(err)
	end
	-- The rest runs even when an animation failed (each part is protected on its own).
	if History.guardCheck then
		History.guardCheck = false
		Guard.call("guard", History.checkGuard)
	end
	-- While the window is hidden, a relayout waits: the window lays itself out once when it opens.
	-- Trimming the history doesn't wait, so cards still go back for reuse with the window closed.
	if relayoutPending and main and main:IsShown() then
		relayoutPending = false
		layout() -- (protected: an error there brings Blizzard's popups back)
	elseif trimPending and not (main and main:IsShown()) then
		trimPending = false
		Guard.core("trim", trimHistory)
	end
	if markersDirty and main and main:IsShown() then
		markersDirty = false
		Guard.call("markers", updateRollMarkers)
	end
	if profileStart then
		self.ms = self.ms + debugprofilestop() - profileStart
	end
	if next(tweens) == nil then
		self:Hide()
	end
end)

-- An animation errored: drop it (the rest keep going). After 3 errors in a session, animations switch
-- off: every one still running is finished where it would end, and new ones jump straight to their end.
function Guard.animationFailed(err)
	local key = driver.current
	driver.current = nil
	if key then
		tweens[key] = nil
	end
	Guard.fails = Guard.fails + 1
	Guard.note("animations", err)
	if Guard.fails >= 3 and not Guard.off.animations then
		Guard.off.animations = true
		local running = {}
		for k, t in pairs(tweens) do
			running[#running + 1] = t
			tweens[k] = nil
		end
		for _, t in ipairs(running) do
			if pcall(t.fn, 1) and t.done then
				pcall(t.done)
			end
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Main window
----------------------------------------------------------------------------------------------------

-- Saved by the top-left corner, so a height change grows or shrinks the window downward.
-- Roll buttons appeared or went somewhere, or the list scrolled: recount the markers next frame.
local function requestMarkers()
	markersDirty = true
	driver:Show()
end

local function savePosition()
	local left, top = main:GetLeft(), main:GetTop()
	if left and top then
		db.point = { "TOPLEFT", "BOTTOMLEFT", left, top }
	end
end

-- Blizzard only places its roll-popup container on screen once a popup has shown, so before the first
-- roll of a session it has no position at all, and a window anchored to it can't be drawn. While the
-- popups are showing, the window sits on top of them; otherwise it sits where they last were (or above
-- the area Blizzard keeps for them), so it can always be opened.
local lastPopupSpot -- { x, top } of the popup container the last time it was on screen
local function popupsOnScreen()
	if not (GroupLootContainer and GroupLootContainer:IsShown()) then
		return false
	end
	local top, x = GroupLootContainer:GetTop(), GroupLootContainer:GetCenter()
	if top and x then
		lastPopupSpot = lastPopupSpot or {}
		lastPopupSpot[1], lastPopupSpot[2] = x, top
		return true
	end
	return false
end

-- The area above the action bars where Blizzard stacks its bottom popups (Forever's name first).
local function bottomContainer()
	local f = BottomManagedFrameContainer or UIParentBottomManagedFrameContainer
	return f and f:GetTop() and f or nil
end

local function applyPosition()
	main:ClearAllPoints()
	anchorFactor = db.position == "attached" and 1 or 0 -- free: anchored by its top, grows downward
	if db.position == "attached" and popupsOnScreen() then
		main:SetPoint("BOTTOM", GroupLootContainer, "TOP", 0, 8)
	elseif db.position == "attached" and lastPopupSpot then
		main:SetPoint("BOTTOM", UIParent, "BOTTOMLEFT", lastPopupSpot[1], lastPopupSpot[2] + 8)
	elseif db.position == "attached" and bottomContainer() then
		main:SetPoint("BOTTOM", bottomContainer(), "TOP", 0, 8)
	elseif db.position == "attached" then
		main:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 220)
	elseif db.point then
		main:SetPoint(db.point[1], UIParent, db.point[2], db.point[3], db.point[4])
	else
		-- Free and never dragged (the default, user 2026-11-10): on the right, beside the quest tracker, top a
		-- little above the middle of the screen, growing downward, so it's out of the way of the action bars
		-- and of what you're fighting. Placed fresh each time until you drag it.
		local x = -300
		pcall(function()
			local tracker = ObjectiveTrackerFrame
			if tracker and tracker:IsShown() and tracker:GetLeft() then
				local scale = main:GetEffectiveScale()
				local trackerLeft = tracker:GetLeft() * tracker:GetEffectiveScale() / scale
				local right = UIParent:GetRight() * UIParent:GetEffectiveScale() / scale
				if trackerLeft > right / 2 then -- (a tracker moved to the left side: ignore it)
					x = trackerLeft - 12 - right
				end
			end
		end)
		main:SetPoint("TOPRIGHT", UIParent, "RIGHT", x, 120)
	end
end

-- Which end of the list new drops appear at: the side the window grows from (see layout).
-- Where new drops appear: at the top (db.newOrder, internal since the "New drops appear" setting went on
-- 2026-11-10; see docs/rollframes-removed-settings.md).
local function newestAtBottom()
	return db.newOrder == "bottom"
end

-- R32: in the attached spot the window grows upward from just above the roll popups; it may only grow
-- to the top of the screen, so the game never has to push it down over the popups. Returns the height
-- available, or nil when the window isn't attached.
local function roomAbovePopups()
	if db.position ~= "attached" then
		return nil
	end
	local bottom
	if popupsOnScreen() then
		bottom = GroupLootContainer:GetTop() + 8
	elseif lastPopupSpot then
		bottom = lastPopupSpot[2] + 8
	elseif bottomContainer() then
		bottom = bottomContainer():GetTop() + 8
	else
		bottom = 220
	end
	local top = UIParent:GetTop()
	return top and (top - bottom - 10) or nil
end

local function createMain()
	local ok, frame = pcall(CreateFrame, "Frame", "RollFramesFrame", UIParent, "DefaultPanelFlatTemplate")
	if not ok or not frame then
		frame = CreateFrame("Frame", "RollFramesFrame", UIParent, "BackdropTemplate")
		frame:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		frame:SetBackdropColor(0.05, 0.05, 0.07, 0.92)
	end
	main = frame
	main:SetSize(WIDTH, MIN_HEIGHT)
	main:SetFrameStrata("HIGH")
	main:SetClampedToScreen(true)
	main:SetMovable(true)
	main:EnableMouse(true)
	main:RegisterForDrag("LeftButton")
	main:SetScript("OnDragStart", function(self)
		db.position = "free"
		self:StartMoving()
		self.moving = true -- (see the window's OnHide: a drag cut short by the window hiding still ends)
	end)
	main:SetScript("OnDragStop", Guard.wrapCore("move", function(self)
		self:StopMovingOrSizing()
		self.moving = nil
		savePosition()
		applyPosition() -- anchor by the saved top-left corner (the window is free now)
		layout() -- grip to its corner for a free window
	end))
	main:Hide()

	local titleText = main.TitleContainer and main.TitleContainer.TitleText
	if titleText then
		titleText:SetText("Loot Rolls")
	else
		local title = main:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		title:SetPoint("TOP", 0, -8)
		title:SetText("Loot Rolls")
		titleText = title -- (History switches it to "Loot History")
	end
	local close = CreateFrame("Button", nil, main, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 2, 1)
	main.closeButton = close

	-- The pin, left of the close button: lit when the window stays open, dim when it fades when idle.
	local pin = CreateFrame("Button", nil, main)
	pin:SetSize(16, 16)
	pin:SetPoint("RIGHT", close, "LEFT", -1, 0)
	-- Above the template's title strip (Blizzard puts it at frame level 510) so nothing draws over the pin.
	local titleLevel = main.TitleContainer and main.TitleContainer:GetFrameLevel() or main:GetFrameLevel()
	pin:SetFrameLevel(titleLevel + 5)
	pin.icon = pin:CreateTexture(nil, "ARTWORK")
	pin.icon:SetAllPoints()
	if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(PIN_ATLAS) then
		pin.icon:SetAtlas(PIN_ATLAS)
	else
		pin.icon:SetTexture("Interface\\Buttons\\LockButton-Locked-Up")
	end
	pin:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
	pin:SetScript("OnClick", function(self)
		setPinned(not pinned)
		lastActivity = GetTime() -- unpinning starts the idle time afresh
		if GameTooltip:IsOwned(self) then
			self:GetScript("OnEnter")(self) -- show the new state at once
		end
	end)
	pin:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		if pinned then
			GameTooltip:SetText("Stays open", 1, 1, 1)
			GameTooltip:AddLine("Stays until you close it. Click to let it fade when loot is done.", nil, nil, nil, true)
		else
			GameTooltip:SetText("Fades when idle", 1, 1, 1)
			GameTooltip:AddLine(string.format("Fades %d seconds after the last roll is decided. Click to keep it open.",
				db.autoHide), nil, nil, nil, true)
		end
		GameTooltip:AddLine("Idle time: Options > AddOns > RollFrames.", 0.6, 0.6, 0.6, true)
		GameTooltip:Show()
	end)
	pin:SetScript("OnLeave", GameTooltip_Hide)
	main.pin = pin

	-- Clear (an X, left of the pin; refreshPin moves it next to the close button when the pin is hidden).
	local clear = CreateFrame("Button", nil, main)
	clear:SetSize(14, 14)
	clear:Hide() -- shown with History (the clock), just left of it
	clear:SetFrameLevel(titleLevel + 5)
	clear.icon = clear:CreateTexture(nil, "ARTWORK")
	clear.icon:SetAllPoints()
	-- An X from Blizzard's common icons (the checkmark beside it is used on winners), checked first; else the
	-- Pass icon; else a plain gold X, so the button can never be invisible (the first texture tried in game,
	-- UI-GroupLoot-Pass-Up, isn't in Forever's client).
	local xAtlas
	for _, atlas in ipairs({ "common-icon-redx", "lootroll-toast-icon-pass-up" }) do
		if not xAtlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
			xAtlas = atlas
		end
	end
	if xAtlas then
		clear.icon:SetAtlas(xAtlas)
	else
		clear.icon:Hide()
		clear.text = clear:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		clear.text:SetPoint("CENTER")
		clear.text:SetText("X")
	end
	clear:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
	clear:SetScript("OnClick", function()
		Guard.call("history", History.askClear)
	end)
	clear:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		if History.demoActive then
			GameTooltip:SetText("Stop the demo", 1, 1, 1)
			GameTooltip:AddLine("Removes the demo's made-up drops. Your own history isn't touched.", nil, nil, nil, true)
			GameTooltip:Show()
			return
		end
		GameTooltip:SetText("Clear history", 1, 1, 1)
		GameTooltip:AddLine("Removes every decided drop from the list and from History. Rolls in progress stay.",
			nil, nil, nil, true)
		GameTooltip:Show()
	end)
	clear:SetScript("OnLeave", GameTooltip_Hide)
	main.clear = clear

	-- History (left of the clear X): shows or hides the drops decided earlier, continuing the list.
	local hist = CreateFrame("Button", nil, main)
	hist:SetSize(16, 16)
	hist:SetPoint("RIGHT", pin, "LEFT", -18, 0) -- (an icon-wide gap from the pin and close; not the top-left corner,
	-- where the resize grip is when attached)
	clear:SetPoint("RIGHT", hist, "LEFT", -4, 0)
	hist:SetFrameLevel(titleLevel + 5)
	hist.lit = hist:CreateTexture(nil, "BACKGROUND") -- a gold box behind the clock while History shows
	hist.lit:SetPoint("TOPLEFT", -2, 2)
	hist.lit:SetPoint("BOTTOMRIGHT", 2, -2)
	hist.lit:SetColorTexture(1, 0.78, 0.15, 0.55)
	hist.lit:Hide()
	hist.icon = hist:CreateTexture(nil, "ARTWORK")
	hist.icon:SetAllPoints()
	hist.icon:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
	hist.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	hist:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
	hist:SetScript("OnClick", function(self)
		Guard.call("history", History.toggle, not History.shown)
		if GameTooltip:IsOwned(self) then
			self:GetScript("OnEnter")(self)
		end
	end)
	hist:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		if History.shown then
			GameTooltip:SetText("Hide older drops", 1, 1, 1)
		else
			GameTooltip:SetText("History", 1, 1, 1)
			GameTooltip:AddLine("Shows the drops decided earlier (saved for this character), continuing the list. They go again "
				.. "on their own after a while if you leave the window alone (unless \"Finished drops stay\" is Until cleared).",
				nil, nil, nil, true)
		end
		GameTooltip:Show()
	end)
	hist:SetScript("OnLeave", GameTooltip_Hide)
	main.hist = hist
	main.titleText = titleText

	-- The draining line just under the title bar (next to the pin that explains it), shown for the last few
	-- seconds before an idle window fades. Silver, so it isn't mistaken for a roll's gold timer bar.
	local countdown = CreateFrame("Frame", nil, main)
	countdown:SetHeight(2)
	countdown:SetPoint("TOPLEFT", main, "TOPLEFT", SIDE_PAD, -(TITLE_H - 3))
	countdown:SetPoint("TOPRIGHT", main, "TOPRIGHT", -SIDE_PAD, -(TITLE_H - 3))
	countdown:SetFrameLevel(titleLevel + 5)
	countdown.fill = countdown:CreateTexture(nil, "OVERLAY")
	countdown.fill:SetPoint("TOPLEFT")
	countdown.fill:SetPoint("BOTTOMLEFT")
	countdown.fill:SetColorTexture(0.85, 0.85, 0.85, 0.6)
	countdown:Hide()
	countdown:SetScript("OnUpdate", Guard.wrapUpdate("autohide", function(self)
		if main:IsMouseOver() then
			lastActivity = GetTime() -- hovering keeps it open and restarts the idle time
		end
		if not fadeEligible() then
			self:Hide()
			return
		end
		local left = db.autoHide - (GetTime() - lastActivity)
		if left > COUNTDOWN + 1 then
			self:Hide() -- something happened; the ticker shows the line again near the end
			return
		end
		if left <= 0 then
			self:Hide()
			startFade()
			return
		end
		self.fill:SetWidth(math.max(0.01, self:GetWidth() * math.min(1, left / math.min(COUNTDOWN, db.autoHide))))
	end))
	main.countdown = countdown

	-- Border and background: see-through a little while the window can fade by itself, solid when pinned or
	-- while the mouse is over it. Only runs while an unpinned window is visible (refreshPin shows/hides it).
	local chrome = { main.NineSlice, main.Bg }
	local chromeAlpha, chromeTarget = 1, 1
	local function setChrome(target)
		if target == chromeTarget then
			return
		end
		chromeTarget = target
		local from = chromeAlpha
		tween("main:chrome", 0.25, function(p)
			chromeAlpha = from + (target - from) * p
			for _, region in ipairs(chrome) do
				region:SetAlpha(chromeAlpha)
			end
		end)
	end
	main.setChrome = setChrome
	local watch = CreateFrame("Frame", nil, main)
	watch:SetScript("OnUpdate", Guard.wrapUpdate("chrome", function()
		setChrome(main:IsMouseOver() and 1 or CHROME_IDLE_ALPHA)
	end, 0.1)) -- (10 times a second)
	watch:Hide()
	main.chromeWatch = watch
	-- (Protected: whatever happens here, the hooks after it still run, among them the one that brings
	-- Blizzard's popups back.)
	main:HookScript("OnHide", Guard.wrap("close", function()
		-- A resize or drag cut short by the window hiding (no mouse-up reaches a hidden window) ends here;
		-- otherwise the height would follow the mouse when the window opens again.
		if grip and grip:GetScript("OnUpdate") then
			pcall(grip:GetScript("OnMouseUp"), grip)
		end
		if main.moving then
			pcall(main:GetScript("OnDragStop"), main)
		end
		if not main:IsShown() then -- closed itself; not just hidden with the whole UI (Alt-Z, cinematics)
			setPinned(false) -- the next window opened by a roll fades as usual
			if History.shown then -- (opens again without the older drops)
				History.shown = false
				main.hist.lit:Hide()
				main.clear:Hide()
				History.hideRows()
			end
		end
	end))

	-- The drops sit in a scroll area that clips at the window's edge.
	scroll = CreateFrame("ScrollFrame", nil, main)
	scroll:SetPoint("TOPLEFT", SIDE_PAD, -TITLE_H)
	scroll:SetPoint("BOTTOMRIGHT", -SIDE_PAD, BOTTOM_PAD)
	content = CreateFrame("Frame", nil, scroll)
	content:SetSize(WIDTH - 2 * SIDE_PAD, 1)
	scroll:SetScrollChild(content)
	main.empty = main:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	main.empty:SetPoint("TOP", scroll, "TOP", 0, -5)
	main.empty:SetText("No loot rolls yet")
	main.emptyHint = main:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	main.emptyHint:SetPoint("TOP", main.empty, "BOTTOM", 0, -4)
	main.emptyHint:SetWidth(WIDTH - 2 * SIDE_PAD - 8) -- wraps inside the window
	main.emptyHint:SetWordWrap(true)
	main.emptyHint:SetJustifyH("CENTER")
	main.emptyHint:SetText("Group loot rolls appear here.")
	-- A new player can see it work straight away (user, 2026-11-10): the demo plays out in the window, with
	-- the first-use question above it. Shown only while the list is empty and the demo can run (solo).
	main.demoButton = CreateFrame("Button", nil, main, "UIPanelButtonTemplate")
	main.demoButton:SetSize(120, 22)
	main.demoButton:SetPoint("TOP", main.emptyHint, "BOTTOM", 0, -10)
	main.demoButton:SetText("Try the demo")
	main.demoButton:SetScript("OnClick", function()
		History.startDemo()
	end)
	main.demoButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:SetText("Try the demo", 1, 1, 1)
		GameTooltip:AddLine("A few made-up drops play out here, so you can see how it works. Nothing is rolled. "
			.. "(Also: /rollframes demo)", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	main.demoButton:SetScript("OnLeave", GameTooltip_Hide)
	main.demoButton:Hide()
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local range = self:GetVerticalScrollRange()
		self:SetVerticalScroll(math.max(0, math.min(range, self:GetVerticalScroll() - delta * 40)))
	end)

	-- "More to roll" markers: pinned inside the top and bottom edges of the list while drops that still
	-- have your roll buttons are scrolled out of view there, with a gentle gold pulse so they're noticed.
	-- Clicking one scrolls the next waiting drop into view. Their OnUpdate (the pulse) only runs while
	-- they show.
	local function createMarker(up)
		local m = CreateFrame("Button", nil, main)
		m.up = up
		m:SetHeight(18)
		local edge = up and "TOP" or "BOTTOM"
		m:SetPoint(edge .. "LEFT", scroll, edge .. "LEFT", 0, 0)
		m:SetPoint(edge .. "RIGHT", scroll, edge .. "RIGHT", 0, 0)
		m:SetFrameLevel(main:GetFrameLevel() + 20)
		m.bg = m:CreateTexture(nil, "BACKGROUND")
		m.bg:SetAllPoints()
		m.bg:SetColorTexture(0.1, 0.07, 0.01, 0.94)
		m.line = m:CreateTexture(nil, "BORDER") -- a thin gold line on the side facing the list
		m.line:SetHeight(1)
		local inner = up and "BOTTOM" or "TOP"
		m.line:SetPoint(inner .. "LEFT", m, inner .. "LEFT", 0, 0)
		m.line:SetPoint(inner .. "RIGHT", m, inner .. "RIGHT", 0, 0)
		m.line:SetColorTexture(1, 0.82, 0.2, 0.8)
		m.face = CreateFrame("Frame", nil, m) -- arrow and text, drawn above the pulse
		m.face:SetAllPoints()
		m.face:SetFrameLevel(m:GetFrameLevel() + 3)
		m.arrow = m.face:CreateTexture(nil, "ARTWORK")
		m.arrow:SetSize(16, 16)
		m.arrow:SetPoint("LEFT", 4, 0)
		m.arrow:SetTexture(up and "Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Up"
			or "Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
		m.text = m.face:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		m.text:SetPoint("LEFT", m.arrow, "RIGHT", 3, 0)
		-- The pulse: a faint gold wash over the bar that slowly brightens and fades, with the gold edge line.
		-- (Not a sweep: that's how a roll's winner is shown.) The arrow and text stay steady.
		m.glow = m:CreateTexture(nil, "ARTWORK")
		m.glow:SetAllPoints()
		m.glow:SetColorTexture(1, 0.8, 0.3, 1)
		m.glow:SetBlendMode("ADD")
		m.glow:SetAlpha(0)
		m:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
		m:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Waiting for your roll", 1, 1, 1)
			GameTooltip:AddLine("Click to scroll to the next one.", nil, nil, nil, true)
			GameTooltip:Show()
		end)
		m:SetScript("OnLeave", GameTooltip_Hide)
		m:SetScript("OnClick", Guard.wrap("markers", function(self)
			scrollToWaitingFn(self.up)
		end))
		-- Pulse: one slow breath every 1.6 s (only runs while the bar shows).
		m:SetScript("OnUpdate", Guard.wrapUpdate("markers", function(self, elapsed)
			self.t = ((self.t or 0) + elapsed) % 1.6
			local level = 0.5 - 0.5 * math.cos(self.t / 1.6 * 2 * math.pi) -- 0 -> 1 -> 0
			if db.flashing == "off" then
				level = 0.6 -- Accessibility: steady
			end
			self.glow:SetAlpha(0.16 * level)
			self.line:SetAlpha(0.45 + 0.55 * level)
		end, 1 / 30)) -- (30 times a second, like the drop highlight)
		m:SetScript("OnShow", function(self)
			self.t = 0
		end)
		m:Hide()
		return m
	end
	main.markerUp, main.markerDown = createMarker(true), createMarker(false)

	-- Blizzard's slim scrollbar when this client has it; otherwise the mouse wheel alone scrolls. (Its setup
	-- replaces the scroll frame's OnVerticalScroll and OnMouseWheel scripts, so hooks go after it.)
	if ScrollUtil and ScrollUtil.InitScrollFrameWithScrollBar then
		local ok, bar = pcall(CreateFrame, "EventFrame", nil, main, "MinimalScrollBar")
		if ok and bar then
			bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 2, 0)
			bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 2, 0)
			if pcall(ScrollUtil.InitScrollFrameWithScrollBar, scroll, bar) then
				scrollBar = bar
			else
				bar:Hide()
			end
		end
	end

	scroll:HookScript("OnVerticalScroll", requestMarkers) -- every scroll (wheel, bar, ours) recounts the markers
	scroll:HookScript("OnVerticalScroll", function()
		if History.shown then
			History.safePlace() -- the older drops in view get the row frames
			History.touch = GetTime() -- scrolling counts as using the window
		end
	end)

	-- Resize grip: drag to set how tall the window may grow. Bottom-right when free; top-left when attached
	-- above the loot roll popups, so it grows away from them.
	grip = CreateFrame("Button", nil, main)
	grip:SetSize(16, 16)
	grip:SetFrameLevel((main.TitleContainer and main.TitleContainer:GetFrameLevel() or main:GetFrameLevel()) + 5)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	grip:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Drag to set the window's height", 1, 1, 1)
		GameTooltip:AddLine("Longer lists scroll. /rollframes reset puts it back.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	grip:SetScript("OnLeave", GameTooltip_Hide)
	grip:SetScript("OnMouseDown", function(self)
		local _, cursorY = GetCursorPosition()
		self.startY, self.startHeight = cursorY, main:GetHeight()
		self:SetScript("OnUpdate", Guard.wrapUpdate("resize", function()
			local _, y = GetCursorPosition()
			local delta = (y - self.startY) / main:GetEffectiveScale()
			if db.position ~= "attached" then
				delta = -delta -- the grip is at the bottom: dragging down makes it taller
			end
			local maxAllowed = math.max(MIN_HEIGHT, math.min(UIParent:GetHeight() - 40, roomAbovePopups() or math.huge))
			local key = db.autoGrow and "maxHeight" or "height" -- the limit when growing; else the fixed height
			local h = math.max(MIN_HEIGHT, math.min(maxAllowed, self.startHeight + delta))
			if db.snapRows then -- (jumps a row at a time, at each halfway point: what you see is what you get)
				h = History.snapHeight(h)
				if h > maxAllowed then
					h = History.snapHeight(maxAllowed, true)
					if h > maxAllowed then
						h = maxAllowed -- (less room than two rows: the room it has)
					end
				end
			end
			db[key] = math.floor(h)
			main:SetHeight(db[key])
		end))
	end)
	grip:SetScript("OnMouseUp", function(self)
		self:SetScript("OnUpdate", nil)
		layout() -- shrinks back to the drops if they need less than the new limit
	end)

	-- Catch up on any relayout that waited while the window was hidden, before its first visible frame.
	main:HookScript("OnShow", Guard.wrapCore("open", function()
		if db.position == "attached" then
			applyPosition() -- the popups' spot may have changed, or not been known at login
		end
		scrollToNewestPending = true -- open at the newest drops (and the rolls in progress); older ones are a scroll away
		relayoutPending = false
		layout()
	end))

	applyPosition()
end

local function placeGrip()
	grip:ClearAllPoints()
	if db.position == "attached" then
		grip:SetPoint("TOPLEFT", main, "TOPLEFT", 2, -2)
		grip:GetNormalTexture():SetTexCoord(1, 0, 1, 0) -- point the grabber up-left
		grip:GetHighlightTexture():SetTexCoord(1, 0, 1, 0)
		grip:GetPushedTexture():SetTexCoord(1, 0, 1, 0)
	else
		grip:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT", -2, 2)
		grip:GetNormalTexture():SetTexCoord(0, 1, 0, 1)
		grip:GetHighlightTexture():SetTexCoord(0, 1, 0, 1)
		grip:GetPushedTexture():SetTexCoord(0, 1, 0, 1)
	end
end

----------------------------------------------------------------------------------------------------
-- Cards
----------------------------------------------------------------------------------------------------

local function qualityColor(quality)
	if quality and C_Item and C_Item.GetItemQualityColor then
		local ok, r, g, b = pcall(C_Item.GetItemQualityColor, quality)
		if ok and r then
			return r, g, b
		end
	end
	local color = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
	if color then
		return color.r, color.g, color.b
	end
	return 0.6, 0.6, 0.6
end


-- "Player lines" as it applies to a new drop: Auto is Everyone in a party (or solo) and Summary in a
-- raid, where 40 lines per drop would push the other drops off screen. A drop keeps the view it started
-- with until the setting itself changes.
local function currentLinesMode()
	local mode = db.playerLines
	if mode == "auto" or (mode ~= "all" and mode ~= "summary" and mode ~= "none") then
		return IsInRaid() and "summary" or "all"
	end
	return mode
end

-- A card's height while its roll is open. It's set by how many players can roll, not by how many have
-- chosen, so it doesn't change as people roll (R31). "reserved" is the most players listed so far, or
-- the group size when the roll starts before the loot history lists anyone.
local function expandedHeight(card)
	local mode = card.linesMode
	if mode == "none" then
		return HEADER_H
	elseif mode == "summary" then
		return HEADER_H -- the counts sit on the item row's second line (then the winner), so one height throughout
	end
	return HEADER_H + math.max(#card.lineOrder, card.reserved or 0) * LINE_H + 6
end

-- A decided drop shrinks to a compact row. (Summary and None drops are that height all along.)
local function targetHeight(card)
	return card.collapsed and HEADER_H or expandedHeight(card)
end

-- Animate the card's height to where its content needs it.
local function resize(card, instant)
	local to = targetHeight(card)
	if card.height == to then
		return -- unchanged: no relayout needed
	end
	local from = card.height or to
	if instant or from == to then
		card.height = to
		card.frame:SetHeight(to)
		relayoutPending = true
		driver:Show()
		return
	end
	tween(card.id .. ":height", 0.25, function(p)
		card.height = from + (to - from) * p
		card.frame:SetHeight(card.height)
		relayoutPending = true
	end)
end

-- Only the top-left point moves; the right edge is anchored once when the line joins a card.
local function placeLine(card, line, i)
	line.index = i
	line:SetPoint("TOPLEFT", card.frame, "TOPLEFT", ICON + 12 + (line.slide or 0), -(HEADER_H + (i - 1) * LINE_H))
end

-- First position of a group's lines in the card (groups are contiguous, in GROUP_ order).
local function groupStart(card, group)
	local counts, first = card.groupCount, 1
	for g = GROUP_YOU, group - 1 do
		first = first + counts[g]
	end
	return first
end

local function swapLines(card, i, j)
	if i == j then
		return
	end
	local order = card.lineOrder
	order[i], order[j] = order[j], order[i]
	placeLine(card, card.lines[order[i]], i)
	placeLine(card, card.lines[order[j]], j)
end

-- Moves a line to another group by trading places at each group boundary it crosses. Joining an earlier
-- group makes it that group's last line (rolls stay in the order they came in); joining a later group
-- makes it the first (newest pass on top). Deciding -> rolled or passed is one swap.
local function moveToGroup(card, line, to)
	local counts, g = card.groupCount, line.group
	while g < to do
		swapLines(card, line.index, groupStart(card, g) + counts[g] - 1)
		counts[g], counts[g + 1] = counts[g] - 1, counts[g + 1] + 1
		g = g + 1
	end
	while g > to do
		swapLines(card, line.index, groupStart(card, g))
		counts[g], counts[g - 1] = counts[g] - 1, counts[g - 1] + 1
		g = g - 1
	end
	line.group = g
end

local function lineGroup(entry)
	if entry.isSelf then
		return GROUP_YOU
	elseif entry.state == STATE.NOROLL then
		return GROUP_DECIDING
	elseif entry.state == STATE.PASS then
		return GROUP_PASSED
	end
	return GROUP_ROLLED
end

-- The summary line ("Player lines: Summary") sits right under the item row.
local function placeSummary(card)
	if card.summaryPlaced then
		return
	end
	card.summaryPlaced = true
	-- On the item row's second line (where the winner goes once it's decided), with the roll's timer as a
	-- thin line along the bottom edge under it (user, 2026-11-10: one compact height in Summary).
	card.waiting:ClearAllPoints()
	card.waiting:SetPoint("BOTTOMLEFT", card.icon, "BOTTOMRIGHT", 6, 4) -- (line 2's column and baseline; the thin timer is below)
	card.waiting:SetPoint("RIGHT", card.frame, "RIGHT", -6, 0)
	if not card.timerThin then
		card.timerThin = true -- (kept across reuse; resetCard puts the normal timer back)
		card.timer:ClearAllPoints()
		card.timer:SetPoint("BOTTOMLEFT", card.frame, "BOTTOMLEFT", ICON + 9, 3) -- (above the highlight's 2 px border)
		card.timer:SetPoint("RIGHT", card.frame, "RIGHT", -6, 0)
		card.timer:SetHeight(2)
	end
end

local function createLine(card)
	local line = CreateFrame("Frame", nil, card.frame)
	line:SetHeight(LINE_H)
	line:SetPoint("RIGHT", card.frame, "RIGHT", -6, 0)
	line.bg = line:CreateTexture(nil, "BACKGROUND")
	line.bg:SetAllPoints()
	line.bg:SetColorTexture(1, 0.82, 0.2, 0)
	-- Your own roll: a faint blue tint and an accent bar, separate from the gold winner highlight.
	line.selfBg = line:CreateTexture(nil, "BACKGROUND", nil, 1)
	line.selfBg:SetAllPoints()
	line.selfBg:SetColorTexture(0.4, 0.7, 1, 0.08)
	line.selfBg:Hide()
	line.selfMark = line:CreateTexture(nil, "ARTWORK")
	line.selfMark:SetPoint("TOPLEFT", -3, 0)
	line.selfMark:SetPoint("BOTTOMLEFT", -3, 0)
	line.selfMark:SetWidth(2)
	line.selfMark:SetColorTexture(0.4, 0.7, 1, 0.9)
	line.selfMark:Hide()
	line.icon = line:CreateTexture(nil, "ARTWORK")
	line.icon:SetSize(14, 14)
	line.icon:SetPoint("LEFT", 2, 0)
	line.name = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	line.name:SetPoint("LEFT", line.icon, "RIGHT", 4, 0)
	line.name:SetJustifyH("LEFT")
	line.roll = line:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	line.roll:SetPoint("RIGHT", -4, 0)
	line.check = line:CreateTexture(nil, "OVERLAY")
	line.check:SetSize(14, 14)
	line.check:SetPoint("RIGHT", line.roll, "LEFT", -4, 0)
	line.check:SetAtlas("common-icon-checkmark")
	line.check:Hide()
	line.shine = line:CreateTexture(nil, "OVERLAY")
	line.shine:SetSize(60, LINE_H)
	line.shine:SetTexture("Interface\\Buttons\\WHITE8X8")
	line.shine:SetBlendMode("ADD")
	if not pcall(line.shine.SetGradient, line.shine, "HORIZONTAL",
		CreateColor(1, 0.85, 0.4, 0), CreateColor(1, 0.85, 0.4, 0.7)) then
		line.shine:SetColorTexture(1, 0.85, 0.4, 0.4)
	end
	line.shine:Hide()
	return line
end

-- Skips the redraw when nothing the line shows has changed (drop updates repeat every roll).
local function updateLineText(card, line, entry)
	local isSelf = entry.isSelf and true or false
	local done = card.finished and true or false
	if line.drawn and line.shownState == entry.state and line.shownName == entry.name
		and line.shownClass == entry.class and line.shownRoll == entry.roll and line.shownSelf == isSelf
		and line.shownDone == done then
		return
	end
	-- Only the parts that changed are redrawn (an update usually changes one player's choice or roll).
	local was, state = line.drawn, entry.state
	local old = line.shownState
	local nameSame = was and line.shownName == entry.name and line.shownClass == entry.class
		and (old == STATE.NEED_OFF) == (state == STATE.NEED_OFF)
	local selfSame = was and line.shownSelf == isSelf
	local rollSame = was and old == state and line.shownRoll == entry.roll and line.shownDone == done
	line.drawn, line.shownState, line.shownName, line.shownClass, line.shownRoll, line.shownSelf, line.shownDone =
		true, state, entry.name, entry.class, entry.roll, isSelf, done
	-- Passes are dimmed: they sit at the bottom and matter least.
	if not (was and (old == STATE.PASS) == (state == STATE.PASS)) then
		local alpha = state == STATE.PASS and 0.55 or 1
		line.name:SetAlpha(alpha)
		line.icon:SetAlpha(alpha)
	end
	if not (was and old == state) then
		if state == STATE.NOROLL then
			line.icon:Hide() -- not chosen yet: no icon
		else
			line.icon:SetAtlas(STATE_ATLAS[state] or STATE_ATLAS[STATE.PASS])
			line.icon:Show()
		end
	end
	if not nameSame then
		local name = classColored(entry.name, entry.class)
		if state == STATE.NEED_OFF then
			name = name .. " |cff999999(off-spec)|r"
		end
		line.name:SetText(name)
	end
	if not selfSame then
		line.selfBg:SetShown(isSelf)
		line.selfMark:SetShown(isSelf)
	end
	if rollSame then
		return
	end
	if entry.state == STATE.NOROLL then
		-- Still deciding; once the roll is over, someone who never chose shows "no roll".
		line.roll:SetText(done and "|cff888888no roll|r" or "|cff888888...|r")
	elseif entry.state == STATE.PASS then
		line.roll:SetText("|cff888888pass|r")
	elseif entry.roll then
		line.roll:SetText(entry.roll)
	else
		line.roll:SetText("|cff888888...|r")
	end
end

local function playWinnerSweep(card, line)
	line.check:Show()
	if db.flashing == "off" then -- Accessibility: highlighted at once, no sweep
		line.bg:SetColorTexture(1, 0.82, 0.2, 0.28)
		return
	end
	tween(card.id .. ":winbg", 0.4, function(p)
		line.bg:SetColorTexture(1, 0.82, 0.2, 0.28 * p)
	end)
	local width = line:GetWidth() > 0 and line:GetWidth() or (WIDTH - ICON - 40)
	local function sweep(times)
		line.shine:Show()
		tween(card.id .. ":shine", 0.7, function(p)
			line.shine:SetPoint("LEFT", line, "LEFT", -60 + (width + 60) * p, 0) -- (its only point)
			line.shine:SetAlpha(1 - p * 0.3)
		end, function()
			line.shine:Hide()
			if times > 1 then
				sweep(times - 1)
			end
		end, true)
	end
	sweep(2)
end

-- True when the user keeps only better items in the history and this one's quality is known to be lower.
local function belowHistoryQuality(card, quality)
	quality = quality or card.quality
	local min = db.historyMinQuality or 0
	return min > 0 and quality ~= nil and quality < min
end

-- Why a decided drop leaves the history instead of staying as a row, or nil when it stays.
local function leaveHistoryReason(card)
	if belowHistoryQuality(card) then
		return "below minimum quality kept"
	elseif card.isTrash and not db.keepTrash then
		return "trash drop"
	end
end

-- The card under the cursor while it shows your roll buttons (R31). It holds still: whatever else
-- happens in the list (new drops, other drops collapsing, old rows leaving the history), layout keeps it
-- at the same spot on screen, using the scroll and, when that isn't enough, an empty gap above or below
-- the list that closes once you click, move the mouse off it, or its roll ends. Nothing waits, and the
-- order never changes because of the mouse.
local function heldCard()
	local mode = db.hoverHold
	if mode ~= "buttons" and mode ~= "window" then
		return nil -- (the default: new drops come in at the top; the button guard covers the clicks)
	end
	-- Only inside the visible list: a card can reach past the window's edge, hidden by the scroll area.
	if not (db.rollFromWindow and main and main:IsVisible() and scroll:IsMouseOver()) then
		return nil
	end
	if (main.markerUp:IsShown() and main.markerUp:IsMouseOver())
		or (main.markerDown:IsShown() and main.markerDown:IsMouseOver()) then
		return nil -- on a "more to roll" bar, not on the drop under it
	end
	for i = 1, #cards do
		local card = cards[i]
		-- (A drop not drawn yet can't be under the cursor, wherever its frame happens to be.)
		if not card.collapsed and card.layoutY and card.buttons:IsShown()
			and (mode == "window" and card.frame or card.buttons):IsMouseOver() then
			return card
		end
	end
end

local collapse, placeHeader, refreshButtons -- forward declarations

-- While layout holds a gap open for a held card: a light check (10 times a second, only then) for the
-- card letting go, so the list closes up right after.
local function waitForRelease()
	if not holdWatch then
		holdWatch = CreateFrame("Frame")
		holdWatch:SetScript("OnUpdate", Guard.wrapCoreUpdate("hold", function(self)
			local held = heldCard()
			if held ~= self.lastHeld then
				self.lastHeld = held
				requestMarkers() -- moved onto another drop: the one you left counts again
			end
			if held then
				return
			end
			self:Hide()
			relayoutPending = true
			driver:Show()
		end, 0.1)) -- (10 times a second)
	end
	holdWatch:Show()
end

-- Fills the item row's bottom line with the winner (or "All passed").
local function updateHeaderWinner(card)
	if card.rollEnded and not card.winner and not card.allPassed then
		card.winnerText:SetText("|cff888888Roll ended|r")
		card.winnerIcon:Hide()
	elseif card.allPassed then
		card.winnerText:SetText("|cffff5555All passed|r")
		card.winnerIcon:SetAtlas(STATE_ATLAS[STATE.PASS]) -- (an icon like a winner's, so the text lines up)
		card.winnerIcon:Show()
	elseif card.winner then
		local w = card.winner
		card.winnerText:SetText((w.roll and ("|cffffd100" .. w.roll .. "|r  ") or "") .. classColored(w.name, w.class))
		card.winnerIcon:SetAtlas(STATE_ATLAS[w.state] or STATE_ATLAS[STATE.GREED])
		card.winnerIcon:Show()
	end
end

-- Fades the winner in on the item row (from wherever it is, so a winner already showing doesn't flicker).
local function showHeaderWinner(card, key)
	updateHeaderWinner(card)
	local from = card.winnerText:GetAlpha()
	if from >= 1 and not tweens[card.id .. ":winner"] then
		return -- already showing (Summary and None show it before the collapse): no fade from 1 to 1
	end
	tween(card.id .. (key or ":winner"), 0.35, function(p)
		local a = from + (1 - from) * p
		card.winnerText:SetAlpha(a)
		card.winnerIcon:SetAlpha(a)
	end)
end

-- Frame pools (see "Frame reuse" below); declared here so a collapsing drop can give its lines back.
local cardPool, linePool = {}, {}

-- Gives a drop's player lines back to the pool (a compact row has none; a redraw in another "Player lines"
-- mode starts again), stopping any animation still holding one (slide-in, winner sweep) first.
local function releaseLines(card)
	local prefix = card.id .. ":"
	for key in pairs(tweens) do
		if key:sub(1, #prefix) == prefix and (key:sub(-3) == ":in" or key == prefix .. "winbg"
			or key == prefix .. "shine") then
			tweens[key] = nil
		end
	end
	for _, line in pairs(card.lines) do
		line:Hide()
		line:ClearAllPoints()
		line.entry = nil -- (the pool keeps frames, not the old drop's data)
		linePool[#linePool + 1] = line
	end
	wipe(card.lines)
	wipe(card.lineOrder)
	for g = GROUP_YOU, GROUP_PASSED do
		card.groupCount[g] = 0
	end
end

-- After the hold, fade the roll lines and shrink the card to a compact row with the winner.
collapse = function(card)
	if card.collapsed or card.dismissing then
		return
	end
	if card.bossName == false and card.encounterID and card.encounterID ~= 0 and C_LootHistory.GetInfoForEncounter then
		local ok, info = pcall(C_LootHistory.GetInfoForEncounter, card.encounterID) -- one more try for the name
		card.bossName = ok and info and safe(info.encounterName) or false
	end
	local why = leaveHistoryReason(card)
	if why then
		dismissCard(card, why) -- the winner has shown; this drop isn't kept in the history
		return
	end
	card.collapsed = true
	local keepSummary = card.linesMode == "summary" -- (stays, with hover for everyone's rolls; see targetHeight)
	if not keepSummary then
		card.lastRolls = nil -- history rows don't show the roll list
	end
	trimPending = true
	card.timer:Hide()
	card.buttons:Hide()
	card.mineIcon:Hide()
	card.mineRoll:Hide()
	placeHeader(card)
	showHeaderWinner(card, ":collapse-winner")
	if card.bossName then
		card.boss:SetText(card.bossName)
		History.fitBoss(card.boss, card.winnerText, 0)
		card.boss:Show()
		card.winnerText:SetPoint("RIGHT", card.boss, "LEFT", -6, 0)
	end
	card.collapsedAt = GetTime()
	Guard.call("history", History.record, card)
	if keepSummary then
		card.waiting:SetAlpha(0) -- (once, not every frame of the fade)
	end
	tween(card.id .. ":collapse", 0.35, function(p)
		for _, line in pairs(card.lines) do
			line:SetAlpha(1 - p)
		end
		if not keepSummary then
			card.waiting:SetAlpha(1 - p)
		end
	end, function()
		releaseLines(card) -- (a compact row keeps no player lines: up to 40 frames each in a raid)
		if not keepSummary then
			card.waiting:Hide()
		end
	end)
	resize(card)
end

local refreshSummary -- forward declaration (defined with the roll lines)

local function finish(card)
	if card.finished then
		return
	end
	card.finished = true
	if not card.demo and not card.instant then -- (a drop replayed already decided, e.g. after /reload, isn't new loot)
		Ask.lootAt = GetTime() -- (the first-use question never shows right after loot)
	end
	lastActivity = GetTime()
	card.timer:Hide()
	card.buttons:Hide()
	if card.linesMode == "all" then
		if card.winnerKey and card.lines[card.winnerKey] then
			playWinnerSweep(card, card.lines[card.winnerKey])
		end
		for _, line in pairs(card.lines) do -- anyone who never chose: "..." becomes "no roll"
			if line.entry and line.entry.state == STATE.NOROLL then
				updateLineText(card, line, line.entry)
			end
		end
	else
		-- No player lines to highlight: the winner shows on the item row straight away. (Summary: in the
		-- counts' place on the second line; they stay, unseen, for the hover.)
		card.mineIcon:Hide()
		card.mineRoll:Hide()
		placeHeader(card)
		showHeaderWinner(card)
		refreshSummary(card)
		if card.linesMode == "summary" then
			local from = card.waiting:GetAlpha()
			tween(card.id .. ":summary-out", 0.25, function(p)
				card.waiting:SetAlpha(from * (1 - p))
			end)
		end
	end
	if card.instant then
		collapse(card)
		return
	end
	local gen = card.gen
	C_Timer.After(db.holdSeconds, Guard.wrapCore("collapse", function()
		if card.gen == gen then -- the card may have been reused for another drop meanwhile
			collapse(card)
		end
	end))
end

----------------------------------------------------------------------------------------------------
-- Twins (R38): two or more copies of one item whose rolls start at the same moment. The game can't say
-- which copy's loot-history entry belongs to which roll (the links are identical, and an entry only
-- appears with its first roll), so the copies' rolls form a pool: a click on any copy uses one of your
-- open rolls for that item, and your choice shows on whichever copy the loot history reports it. A copy
-- offers buttons while it doesn't show your choice and a roll is left. Copies that start further apart
-- pair without doubt and stay ordinary. A roll is a roll ID, or a table in the demo.
----------------------------------------------------------------------------------------------------

local TWIN_WINDOW = 5 -- seconds: rolls for the same item that start this close together are twins

local function ownRoll(card)
	return card.rollID or card.demoRoll
end

-- An open roll in the pool, preferring the card's own.
local function twinOpenRoll(group, prefer)
	if prefer ~= nil and not group.used[prefer] and not group.ended[prefer] then
		return prefer
	end
	for _, roll in ipairs(group.rolls) do
		if not group.used[roll] and not group.ended[roll] then
			return roll
		end
	end
end

local function refreshTwins(group)
	for _, member in ipairs(group.members) do
		if member[1].gen == member[2] then -- (skips a card reused for another drop)
			refreshButtons(member[1])
		end
	end
end

local twinOfRoll = {} -- roll ID -> its twins group, so a roll made anywhere (Blizzard's popup too) counts
local rolledIDs = {} -- roll ID -> true once RollOnLoot was called for it, from anywhere

-- A roll already taken before the copies were joined: a click waiting for its report, or a roll the
-- game already reported (made through the window or elsewhere; its own roll is the best guess).
local function markTaken(group, card)
	local own = ownRoll(card)
	if card.clickRoll ~= nil then
		group.used[card.clickRoll] = true
	end
	if own ~= nil and (rolledIDs[own] or (card.selfReported and card.clickRoll == nil)) then
		group.used[own] = true -- rolled already (Blizzard's popup, another addon), or reported
	end
end

local function joinTwins(card, other)
	local group = other.twins
	if not group then
		group = { rolls = { ownRoll(other) }, used = {}, ended = {}, members = { { other, other.gen } } }
		other.twins = group
		markTaken(group, other)
		if type(ownRoll(other)) == "number" then
			twinOfRoll[ownRoll(other)] = group
		end
	end
	group.rolls[#group.rolls + 1] = ownRoll(card)
	group.members[#group.members + 1] = { card, card.gen }
	card.twins = group
	markTaken(group, card)
	if type(ownRoll(card)) == "number" then
		twinOfRoll[ownRoll(card)] = group
	end
	refreshTwins(group)
end

-- The loot history shows your choice on this copy. If you clicked another copy, the click moves here:
-- that copy's shown choice clears, and it offers buttons again if a roll is left.
local function twinReported(card)
	if not card.clickedState then
		-- The click to move: the copy whose pending choice matches the report, else any pending one.
		local moved
		for pass = 1, 2 do
			for _, member in ipairs(card.twins.members) do
				local other = member[1]
				if not moved and other ~= card and other.gen == member[2] and other.clickedState
					and not other.selfReported and (pass == 2 or other.clickedState == card.selfState) then
					moved = other
				end
			end
		end
		if moved then
			moved.clickedState, moved.youRolled, moved.clickRoll = nil, nil, nil
			moved.setMine(nil)
		end
	end
	refreshTwins(card.twins)
end

-- Bind-on-pickup: the game asks you to confirm a roll (CONFIRM_LOOT_ROLL). If its popup closes without
-- a confirm, no roll was made: the roll goes back (to the card's buttons, or the twins pool) and the
-- choice shown for it clears. A confirmed roll stays taken however long its report takes.
local awaitingConfirm = {} -- roll ID -> true while its confirmation is open (false: not seen open yet)
local confirmedRolls = {} -- roll ID -> true once confirmed (an auto-confirm addon may do it before we hear of it)
local confirmWatch

local function releaseRoll(rollID)
	local group = twinOfRoll[rollID]
	if group then
		group.used[rollID] = nil
	end
	for _, card in ipairs(cards) do
		if card.clickRoll == rollID and not card.selfReported then
			card.clickRoll, card.clickedState, card.youRolled = nil, nil, nil
			card.setMine(nil)
			refreshButtons(card)
		end
	end
	if group then
		refreshTwins(group)
	end
end

local function onConfirmLootRoll(rollID)
	if not StaticPopup_Visible then
		return -- can't tell when it closes; Blizzard's popups come back if the window is closed
	end
	if confirmedRolls[rollID] then
		return -- already confirmed (e.g. by an addon that auto-confirms loot warnings)
	end
	awaitingConfirm[rollID] = false
	if not confirmWatch then
		confirmWatch = CreateFrame("Frame")
		confirmWatch:SetScript("OnUpdate", Guard.wrapCoreUpdate("confirm", function(self) -- only while a confirmation is open
			if StaticPopup_Visible("CONFIRM_LOOT_ROLL") then
				for id in pairs(awaitingConfirm) do
					awaitingConfirm[id] = true -- seen open
				end
				return
			end
			self:Hide()
			for id, seen in pairs(awaitingConfirm) do
				awaitingConfirm[id] = nil
				if seen and not confirmedRolls[id] then
					releaseRoll(id) -- seen open, closed without a confirm
				end
			end
		end, 0.25)) -- (4 times a second)
	end
	confirmWatch:Show()
end

local function cardRollTypes(card)
	local rollID = card.rollID
	if not rollID and card.twins then
		local open = twinOpenRoll(card.twins, nil) -- (its own roll ended: the roll a click would use)
		rollID = type(open) == "number" and open or nil
	end
	-- (One table, filled again on each call: read at once by refreshButtons, never kept.)
	local can = ROLL_BUTTONS.can
	if not rollID or card.demo then
		can.canNeed, can.canGreed, can.canTransmog = true, true, false
		return can
	end
	local ok, _, _, _, _, _, canNeed, canGreed, _, _, _, _, _, canTransmog = pcall(GetLootRollItemInfo, rollID)
	if not ok then
		can.canNeed, can.canGreed, can.canTransmog = true, true, nil
		return can
	end
	can.canNeed, can.canGreed, can.canTransmog = canNeed, canGreed, canTransmog
	return can
end

local function createButtons(card)
	local bar = CreateFrame("Frame", nil, card.frame)
	bar:SetSize(3 * 22, 20) -- (4 * 22 on a roll that allows Transmog)
	bar:SetPoint("TOPRIGHT", card.frame, "TOPRIGHT", -4, -4)
	bar.list = {}
	bar:SetScript("OnShow", function()
		bar.shownAt = GetTime() -- (see the buttons' OnClick: a press from before this doesn't count)
		requestMarkers()
	end)
	bar:SetScript("OnHide", requestMarkers)
	-- The buttons themselves are made the first time this drop offers them (refreshButtons). With "Roll from
	-- this window" off, the default, they never are: 4 buttons and 12 textures less for every drop.
	function bar.build()
		bar.build = nil
		for i, spec in ipairs(ROLL_BUTTONS) do
			local button = CreateFrame("Button", nil, bar)
			button:SetSize(20, 20)
			button:SetPoint("RIGHT", bar, "RIGHT", -(i - 1) * 22, 0)
			button:SetNormalAtlas(spec.atlas .. "-up")
			button:SetHighlightAtlas(spec.atlas .. "-highlight")
			button:SetPushedAtlas(spec.atlas .. "-down")
			button.spec = spec
			if button.SetMotionScriptsWhileDisabled then
				button:SetMotionScriptsWhileDisabled(true) -- (a greyed-out button still says why)
			end
			-- The drop's tooltip stays (beside the window), with the button's own line at the end.
			button:SetScript("OnEnter", function(self)
				card.showTooltip(self, function(b)
					GameTooltip:AddLine(" ")
					GameTooltip:AddLine("Click: " .. spec.label, 1, 0.82, 0)
					if not b:IsEnabled() then
						GameTooltip:AddLine("Not available for this item.", 0.8, 0.8, 0.8)
					elseif card.guarded then
						GameTooltip:AddLine((tonumber(db.guardTime) or 2) > 0
							and "The list just moved: these work again in a moment (or move the mouse)."
							or "The list just moved: move the mouse to use these.", 1, 0.82, 0.2, true)
					end
				end)
			end)
			button:SetScript("OnLeave", GameTooltip_Hide)
			button:SetScript("OnMouseDown", function(self)
				self.pressedAt = GetTime()
			end)
			button:SetScript("OnClick", Guard.wrapCore("click", function(self)
				if not self:IsEnabled() then
					return -- greyed out: not available for this item
				end
				if card.guarded then
					-- the list just moved these under a still cursor: a moment, or move the mouse (History.checkGuard).
					-- A short "denied" sound says the click was heard (user, 2026-11-10; more options later).
					if PlaySound then
						pcall(PlaySound, SOUNDKIT and SOUNDKIT.UI_GARRISON_ARCHITECT_TABLE_BUILDING_PLACEMENT_ERROR or 47355)
					end
					return
				end
				-- Only a press that began after these buttons appeared counts: a click already in progress when
				-- they popped up under the cursor (a new drop, or a demo drop replaced by real loot) wasn't
				-- meant for this item. No delay otherwise. (Keyboard clicks have no press time and count.)
				local pressedAt = self.pressedAt
				self.pressedAt = nil -- each press counts once
				if pressedAt and bar.shownAt and pressedAt <= bar.shownAt then
					return
				end
				local roll = ownRoll(card)
				if card.twins then -- any open roll for this item (twins, R38)
					roll = twinOpenRoll(card.twins, roll)
					if roll == nil then
						bar:Hide()
						return
					end
					card.twins.used[roll] = true
				end
				if type(roll) == "table" then
					roll.choice = spec.type -- the demo's made-up roll
				elseif roll then
					RollOnLoot(roll, spec.type)
				end
				card.clickRoll = roll
				bar:Hide()
				-- Remember the click: updates that come before the server has your choice must not bring the
				-- buttons back or hide the choice shown below.
				card.youRolled = true
				card.clickedState = CLICK_STATE[spec.type]
				-- If no roll follows (a bind-on-pickup confirmation cancelled), onConfirmLootRoll gives it back.
				if card.linesMode ~= "all" then
					card.setMine(CLICK_STATE[spec.type]) -- your choice shows at once, where the buttons were
				else
					placeHeader(card)
				end
				if card.twins then
					refreshTwins(card.twins) -- the other copies lose their buttons if no roll is left
				end
			end))
			bar.list[#bar.list + 1] = button
		end
	end
	bar:Hide()
	return bar
end

-- Title row: item name, then the item level at the right, left of the roll buttons or your own choice
-- ("Player lines" Summary or None) when they show.
placeHeader = function(card)
	local mode = card.buttons and card.buttons:IsShown() and "buttons"
		or (card.mineIcon and card.mineIcon:IsShown() and "mine") or "plain"
	if card.headerMode == mode then
		return -- already placed for this layout
	end
	card.headerMode = mode
	card.ilvl:ClearAllPoints()
	if mode == "buttons" then
		card.ilvl:SetPoint("TOPRIGHT", card.buttons, "TOPLEFT", -4, -1)
	elseif mode == "mine" then
		card.ilvl:SetPoint("TOPRIGHT", card.mineRoll, "TOPLEFT", -4, 2) -- (left of your roll number, on line 1)
	else
		card.ilvl:SetPoint("TOPRIGHT", card.frame, "TOPRIGHT", -6, -5)
	end
end

-- Highlight for drops waiting for your roll. It shows exactly while a drop's roll buttons show (so only
-- with "Roll from this window") and goes when you roll or the roll ends. One driver animates every
-- highlighted drop; it's a child of the window, so it stops when the window hides, and it hides itself
-- when no drop is highlighted. Game textures only; a piece whose texture doesn't load stays hidden.
local Highlight = { cards = {}, count = 0, t = 0, STYLES = { "border", "timer", "sparkle", "all", "off" } }
Highlight.SPARKS = 5 -- stars per drop in the sparkle style

-- Each style's pieces are built the first time a card shows that style (cards are reused, so a few times a
-- session). Border and timer pieces sit in their own small frame, so one SetAlpha pulses all of them.
function Highlight.build(card, style)
	local hl = card.hl
	if not hl then
		hl = CreateFrame("Frame", nil, card.frame)
		hl:SetAllPoints()
		-- At the card's own level: above its text, under its roll buttons (a level up), so the gold wash never
		-- tints the buttons (2026-11-10: it made them look faded). No mouse input.
		hl:SetFrameLevel(card.frame:GetFrameLevel())
		hl:EnableMouse(false)
		hl.isHighlight = true -- (tests find it by this)
		card.hl = hl
	end
	if (style == "border" or style == "all") and not hl.border then
		-- A 2 px gold frame around the drop and a faint gold wash over it.
		hl.border = CreateFrame("Frame", nil, hl)
		hl.border:SetAllPoints()
		for _, side in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
			{ "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false } }) do
			local e = hl.border:CreateTexture(nil, "OVERLAY")
			e:SetPoint(side[1])
			e:SetPoint(side[2])
			if side[3] then e:SetHeight(2) else e:SetWidth(2) end
			e:SetColorTexture(1, 0.8, 0.2, 1)
			e:SetBlendMode("ADD")
		end
		local wash = hl.border:CreateTexture(nil, "ARTWORK")
		wash:SetAllPoints()
		wash:SetColorTexture(1, 0.75, 0.2, 0.1)
		wash:SetBlendMode("ADD")
	end
	if (style == "timer" or style == "all") and not hl.bar then
		-- A gold glow over the roll's timer bar and a spark at its moving edge (placed by the timer's OnUpdate).
		hl.bar = CreateFrame("Frame", nil, card.timer)
		hl.bar:SetPoint("TOPLEFT", -2, 3)
		hl.bar:SetPoint("BOTTOMRIGHT", 2, -3)
		local glow = hl.bar:CreateTexture(nil, "OVERLAY")
		glow:SetAllPoints()
		glow:SetColorTexture(1, 0.85, 0.3, 0.5)
		glow:SetBlendMode("ADD")
		hl.spark = hl.bar:CreateTexture(nil, "OVERLAY")
		hl.spark:SetSize(14, 18)
		hl.spark:SetBlendMode("ADD")
		if hl.spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark") == false then
			hl.sparkOk = false
			hl.spark:Hide() -- (texture missing in this client: just the glow)
		end
	end
	if (style == "sparkle" or style == "all") and not hl.stars then
		-- Small stars that twinkle in turn at spots along the drop's edge.
		hl.stars = {}
		for i = 1, Highlight.SPARKS do
			local star = hl:CreateTexture(nil, "OVERLAY")
			star:SetSize(16, 16)
			star:SetBlendMode("ADD")
			star.ok = star:SetTexture("Interface\\Cooldown\\star4") ~= false
			star:SetVertexColor(1, 0.9, 0.5)
			star:SetAlpha(0)
			star.phase = (i - 1) / Highlight.SPARKS
			star.cycle = -1
			hl.stars[i] = star
		end
	end
end

-- Shows the parts of the chosen style and hides the rest.
function Highlight.style(card, style)
	local steady = db.flashing == "off" -- Accessibility: nothing twinkles; Sparkles becomes a steady border
	if steady and style == "sparkle" then
		style = "border"
	end
	Highlight.build(card, style)
	local hl = card.hl
	local border, timer, sparkle = style == "border" or style == "all", style == "timer" or style == "all",
		(style == "sparkle" or style == "all") and not steady
	if hl.border then hl.border:SetShown(border) end
	if hl.bar then
		hl.bar:SetShown(timer)
		if hl.spark and hl.sparkOk ~= false then hl.spark:SetShown(not steady) end -- (Off: a steady glow, no moving spark)
	end
	if hl.stars then
		for _, star in ipairs(hl.stars) do
			star:SetShown(sparkle and star.ok)
			star:SetAlpha(0)
			star.cycle = -1
		end
	end
	hl.style = style
	hl:Show()
end

function Highlight.valid(style)
	for _, name in ipairs(Highlight.STYLES) do
		if name == style then return true end
	end
	return false
end

function Highlight.on(card)
	if Guard.off.highlight then
		return
	end
	local style = Highlight.valid(db.highlightRolls) and db.highlightRolls or "border"
	if style == "off" then
		Highlight.off(card)
		return
	end
	if not (card.hl and card.hl.wanted == style and card.hl.steady == (db.flashing == "off") and card.hl:IsShown()) then
		Highlight.style(card, style)
		card.hl.wanted = style -- (what was asked for; hl.style is what shows, e.g. a steady border for Sparkles)
		card.hl.steady = db.flashing == "off"
	end
	if not Highlight.cards[card] then
		Highlight.cards[card] = true
		Highlight.count = Highlight.count + 1
	end
	if not Highlight.driver then
		Highlight.driver = CreateFrame("Frame", nil, main)
		Highlight.driver:SetScript("OnUpdate", Guard.wrapUpdate("highlight", Highlight.tick, 1 / 30))
	end
	Highlight.driver:Show()
end

function Highlight.off(card)
	local hl = card.hl
	if hl then
		hl:Hide()
		hl.style, hl.wanted = nil, nil
		if hl.bar then hl.bar:Hide() end -- (on the timer bar, not inside hl)
	end
	if Highlight.cards[card] then
		Highlight.cards[card] = nil
		Highlight.count = Highlight.count - 1
	end
end

-- One gold flash of the window's edge when new loot brings it back from History (Accessibility "Flashing":
-- "persist" repeats it until you hover the window; "off" never flashes).
function History.flashWindow()
	if db.flashing == "off" or not main then
		return
	end
	local f = History.flash
	if not f then
		f = CreateFrame("Frame", nil, main)
		f:SetAllPoints(main)
		f:SetFrameLevel(main:GetFrameLevel() + 30)
		f:EnableMouse(false)
		f.isWindowFlash = true -- (tests find it by this)
		-- Trace the panel's own border: a gold, additive copy of each piece of Blizzard's frame art (same
		-- texture, coordinates and place), so the flash sits exactly on the visible border (2026-11-10: plain
		-- edges along the frame's rectangle didn't line up with the art).
		local traced = 0
		if main.NineSlice and main.NineSlice.GetRegions then
			for _, r in ipairs({ main.NineSlice:GetRegions() }) do
				if r.IsObjectType and r:IsObjectType("Texture") and r ~= main.NineSlice.Center then -- (edges only)
					local t = f:CreateTexture(nil, "OVERLAY")
					local atlas = r.GetAtlas and r:GetAtlas()
					if atlas then
						t:SetAtlas(atlas)
					else
						t:SetTexture(r:GetTexture())
					end
					if r.GetTexCoord then
						t:SetTexCoord(r:GetTexCoord()) -- (keeps the mirrored corners mirrored)
					end
					t:SetAllPoints(r)
					t:SetBlendMode("ADD")
					t:SetVertexColor(1, 0.8, 0.25)
					traced = traced + 1
				end
			end
		end
		if traced == 0 then -- no panel art in this client: plain gold edges just inside the window
			for _, side in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
				{ "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false } }) do
				local e = f:CreateTexture(nil, "OVERLAY")
				e:SetPoint(side[1])
				e:SetPoint(side[2])
				if side[3] then e:SetHeight(3) else e:SetWidth(3) end
				e:SetColorTexture(1, 0.8, 0.2, 1)
				e:SetBlendMode("ADD")
			end
		end
		History.flash = f
	end
	f:SetAlpha(0)
	f:Show()
	local function once()
		tween("main:flash", 0.9, function(p)
			f:SetAlpha(math.sin(p * math.pi))
		end, function()
			if db.flashing == "persist" and main:IsVisible() and not main:IsMouseOver() then
				once()
			else
				f:Hide()
			end
		end, true) -- (linear: an even pulse)
	end
	once()
end

-- Stops a flash at once (Flashing set to Off).
function History.stopFlash()
	if History.flash and History.flash:IsShown() then
		tweens["main:flash"] = nil
		History.flash:Hide()
	end
end

-- After the setting changes: restyle every drop that's waiting for your roll (or clear them all for "off").
function Highlight.restyle()
	for card in pairs(Highlight.cards) do
		if card.buttons:IsShown() then
			Highlight.on(card)
		else
			Highlight.off(card) -- stopped waiting since the last tick (the window may be hidden)
		end
	end
	for _, card in ipairs(cards) do
		if card.buttons and card.buttons:IsShown() then
			Highlight.on(card)
		end
	end
end

-- 30 updates a second (a slow pulse looks the same as at the full frame rate, at half the cost; the rate
-- is set where it's hooked up, in Highlight.on).
function Highlight.tick(driver, elapsed)
	Highlight.t = Highlight.t + elapsed
	local t = Highlight.t
	local level = 0.5 - 0.5 * math.cos(t / 1.2 * 2 * math.pi) -- 0 -> 1 -> 0, one breath every 1.2 s
	if db.flashing == "off" then
		level = 0.8 -- Accessibility: steady
	end
	for card in pairs(Highlight.cards) do
		local hl = card.hl
		-- Buttons gone (rolled, roll over, card reused): no highlight. Checked here as well as where the
		-- buttons hide, so no path can leave a drop glowing.
		if not (hl and card.buttons:IsShown()) then
			Highlight.off(card)
		else
			local style = hl.style
			if style == "border" or style == "all" then
				hl.border:SetAlpha(0.35 + 0.65 * level)
			end
			if style == "timer" or style == "all" then
				hl.bar:SetAlpha(0.3 + 0.7 * level)
			end
			if (style == "sparkle" or style == "all") and not hl.steady then
				for _, star in ipairs(hl.stars) do
					local x = t / 1.4 + star.phase -- each star: one twinkle every 1.4 s, in turn
					local cycle = math.floor(x)
					if cycle ~= star.cycle then -- a new twinkle: move to another spot on the edge
						star.cycle = cycle
						local along, side = math.random(), math.random(4)
						star:ClearAllPoints()
						if side <= 2 then
							star:SetPoint("CENTER", hl, side == 1 and "TOPLEFT" or "BOTTOMLEFT", along * card.frame:GetWidth(), 0)
						else
							star:SetPoint("CENTER", hl, side == 3 and "TOPLEFT" or "TOPRIGHT", 0, -along * card.frame:GetHeight())
						end
					end
					local s = math.sin((x - cycle) * math.pi) -- 0 -> 1 -> 0 over the twinkle
					star:SetAlpha(s * s * s)
				end
			end
		end
	end
	if Highlight.count == 0 then
		driver:Hide()
	end
end

refreshButtons = function(card)
	if not (db.rollFromWindow and not Guard.fallback and (card.rollID or card.demoWaitsForYou or card.twins)
		and not card.finished and not card.youRolled
		and not (card.twins and twinOpenRoll(card.twins, ownRoll(card)) == nil)) then
		-- (Runs on every update of every drop: only what's showing is hidden.)
		if card.buttons:IsShown() then
			card.buttons:Hide()
		end
		if Highlight.cards[card] then
			Guard.call("highlight", Highlight.off, card)
		end
		placeHeader(card)
		return
	end
	-- Need, Greed and Pass keep their spots on every drop, so fast clicking down the list always hits the
	-- same choice; one this item doesn't allow is greyed out instead of removed. Transmog shows (far left)
	-- only when the roll allows it.
	if card.buttons.build then
		card.buttons.build()
	end
	local can = cardRollTypes(card)
	local wide = false
	for _, button in ipairs(card.buttons.list) do
		local spec = button.spec
		local allowed = (not spec.can or can[spec.can]) and true or false
		if spec.onlyIfAllowed then
			if button.allowed ~= allowed then
				button:SetShown(allowed)
			end
			wide = allowed
		end
		if button.allowed ~= allowed then
			button.allowed = allowed
			button:SetEnabled(allowed)
			button:GetNormalTexture():SetDesaturated(not allowed)
			button:SetAlpha(allowed and 1 or 0.35)
		end
	end
	if card.buttons.wide ~= wide then
		card.buttons.wide = wide
		card.buttons:SetWidth((wide and 4 or 3) * 22)
	end
	if not card.buttons:IsShown() then
		card.buttons:Show()
	end
	if not Highlight.cards[card] then -- (a setting change restyles every drop: Highlight.restyle)
		Guard.call("highlight", Highlight.on, card)
	end
	placeHeader(card)
end

----------------------------------------------------------------------------------------------------
-- Frame reuse. WoW never frees a frame, so a long raid night would otherwise keep every drop's card
-- and roll lines in memory until a reload. Cards leaving the history (and demo cards) go back to these
-- pools, reset, and new drops take from them before creating anything.
----------------------------------------------------------------------------------------------------

local framesMade = { cards = 0, lines = 0 } -- how many were ever created (for /rollframes diag and the stress test)

-- Card fields that describe one drop; cleared when a card is reused. Frames and widgets are kept.
local DROP_FIELDS = {
	"link", "historyKey", "rollID", "rollTime", "duration", "endsAt", "finished", "collapsed", "allPassed",
	"winner", "winnerKey", "youRolled", "demoRoll", "demoWaitsForYou", "twins", "clickRoll", "rollStarted", "itemKey", "keyLink", "selfState",
	"itemName", "itemShown", "shownLink", "shownNameArg", "shownIconArg", "shownQualityArg", "ilvlSettled",
	"height", "headerMode", "timerRed", "demo", "instant", "created", "summaryPlaced", "collapsedAt", "dropMark", "guarded", "movedAt",
	"quality", "dismissing", "reserved", "hadRolls", "lastRolls", "mineState", "mineRollShown", "encounterID",
	"bossName", "isTrash", "layoutY", "listY", "summaryKey", "clickedState", "linesMode", "selfReported", "placeFrom",
	"rollEnded", "screenWas", "cancelledRoll",
}

local function acquireLine(card)
	local line = table.remove(linePool)
	if not line then
		framesMade.lines = framesMade.lines + 1
		return createLine(card)
	end
	line:SetParent(card.frame)
	line:SetPoint("RIGHT", card.frame, "RIGHT", -6, 0)
	line.slide, line.index, line.entry, line.drawn, line.group = 0, nil, nil, nil, nil
	line.bg:SetColorTexture(1, 0.82, 0.2, 0)
	line.selfBg:Hide()
	line.selfMark:Hide()
	line.check:Hide()
	line.shine:Hide()
	line.shine:SetAlpha(1)
	line:SetAlpha(1)
	line:Show()
	return line
end

-- Puts a card that has left the list back in the pool. Its generation number changes, so any timer
-- still holding the old drop (hold-then-collapse, demo steps) sees it's no longer theirs and stops.
local function releaseCard(card)
	card.gen = card.gen + 1
	local prefix = card.id .. ":"
	for key in pairs(tweens) do
		if key:sub(1, #prefix) == prefix then
			tweens[key] = nil
		end
	end
	releaseLines(card)
	if Highlight.cards[card] then
		Guard.call("highlight", Highlight.off, card) -- (its next drop starts without one)
	end
	card.lastRolls = nil -- (a raid's whole roll list: about 16 KB a card)
	card.timer:Hide()
	card.buttons:Hide()
	card.frame:Hide()
	card.frame:ClearAllPoints()
	cardPool[#cardPool + 1] = card
end

-- Fades a card out and removes it from the list (below "Minimum quality kept", or trash with
-- "Keep trash drops" off).
dismissCard = function(card, why)
	if card.dismissing then
		return
	end
	card.dismissing = true
	if card.historyKey then
		skippedHistory[card.historyKey] = card.dropMark or true
	end
	if logging() and not card.demo then
		log("skip", { historyKey = card.historyKey, quality = card.quality, why = why or "below minimum quality kept" })
	end
	card.timer:Hide()
	card.buttons:Hide()
	tween(card.id .. ":dismiss", 0.35, function(p)
		card.frame:SetAlpha(1 - p)
	end, function()
		for i, c in ipairs(cards) do
			if c == card then
				table.remove(cards, i)
				break
			end
		end
		if card.historyKey and cardsByHistory[card.historyKey] == card then
			cardsByHistory[card.historyKey] = nil
		end
		if card.rollID and cardsByRollID[card.rollID] == card then
			cardsByRollID[card.rollID] = nil
		end
		if card.demo then
			demoCardCount = demoCardCount - 1
		end
		releaseCard(card)
		relayoutPending = true
		driver:Show()
	end)
end

-- Clears what a reused card showed for its last drop. setItem, setRoll and friends fill it in again.
local function resetCard(card)
	for _, key in ipairs(DROP_FIELDS) do
		card[key] = nil
	end
	card.name:SetText("")
	card.ilvl:SetText("")
	card.timer:SetStatusBarColor(1, 0.75, 0.1)
	card.timerRed = false
	card.timer:SetValue(1)
	card.timer.step = nil
	card.winnerText:SetText("")
	card.winnerText:SetAlpha(0)
	card.winnerIcon:SetAlpha(0)
	card.winnerIcon:Hide()
	card.waiting:SetText("")
	card.waiting:SetAlpha(1)
	card.waiting:Show()
	card.buttons:SetAlpha(1) -- (a guard from its last drop)
	History.wideTimer(card) -- (a Summary drop's thin timer: back to the normal one)
	card.mineIcon:Hide()
	card.mineRoll:Hide()
	card.boss:Hide()
	card.winnerText:SetPoint("RIGHT", card.frame, "RIGHT", -6, 0)
	card.frame:Show()
end

-- The list of drops is kept newest first; layout shows it in that order or reversed (see newestAtBottom).
local function insertCard(card)
	table.insert(cards, 1, card)
end

-- The roll list for a tooltip: everyone's choice and roll (Summary and None show no player lines).
-- The rolls in a drop's tooltip: each player's choice as the same icon their line in the window shows
-- (easier to tell apart at a glance than words), then the roll.
-- In a raid only the Need rolls are listed, then one line counting the rest (40 lines would run off the
-- screen; user, 2026-11-10: a setting for this may follow, see docs/todo/RollFrames.md).
local function addRollsToTooltip(card)
	if not card.lastRolls then
		return
	end
	local raid = IsInRaid and IsInRaid()
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine(raid and "Need rolls" or "Rolls", 1, 1, 1)
	local others -- (raid) how many chose each of the rest
	for _, r in ipairs(card.lastRolls) do
		local state = safe(r.state, STATE.NOROLL)
		if raid and state ~= STATE.NEED and state ~= STATE.NEED_OFF then
			others = others or {}
			others[state] = (others[state] or 0) + 1
		else
			local choice
			if state == STATE.NOROLL then
				choice = card.finished and "no roll" or "..."
			else
				choice = "|A:" .. (STATE_ATLAS[state] or STATE_ATLAS[STATE.PASS]) .. ":14:14|a"
				if state == STATE.NEED_OFF then
					choice = "|cff999999off-spec|r " .. choice
				end
			end
			local roll = safe(r.roll)
			GameTooltip:AddDoubleLine(classColored(safe(r.playerName, "?"), safe(r.playerClass)),
				choice .. (roll and ("  " .. roll) or ""), 1, 1, 1, 0.8, 0.8, 0.8)
		end
	end
	if others then
		local parts = {}
		for _, state in ipairs({ STATE.GREED, STATE.TRANSMOG, STATE.PASS }) do
			if others[state] then
				parts[#parts + 1] = "|A:" .. STATE_ATLAS[state] .. ":14:14|a " .. others[state]
			end
		end
		if others[STATE.NOROLL] then
			parts[#parts + 1] = others[STATE.NOROLL] .. (card.finished and " no roll" or " deciding")
		end
		GameTooltip:AddLine(table.concat(parts, "   "), 0.8, 0.8, 0.8)
	end
end

local function createCard(link, opts)
	nextCardID = nextCardID + 1
	local card = table.remove(cardPool)
	local reused = card ~= nil
	if reused then
		resetCard(card)
	else
		card = { gen = 0, lines = {}, lineOrder = {}, groupCount = { 0, 0, 0, 0 } }
		framesMade.cards = framesMade.cards + 1
	end
	card.id = "card" .. nextCardID
	card.link, card.created = link, GetTime()
	card.demo, card.instant = opts and opts.demo, opts and opts.instant
	card.reserved = opts and opts.reserve or 0
	card.linesMode = currentLinesMode()
	if History.shown and GetTime() - (History.flashedAt or -100) > 3 then
		-- new loot while older drops are out: the list goes to its newest end; one flash says so (one per burst:
		-- a boss's three or four drops arrive within a second)
		History.flashedAt = GetTime()
		Guard.call("flash", History.flashWindow)
	end
	scrollToNewestPending = true -- show the new drop
	if reused then
		card.frame:SetPoint("LEFT", content, "LEFT")
		card.frame:SetPoint("RIGHT", content, "RIGHT")
		placeHeader(card)
		insertCard(card)
		card.frame:SetAlpha(0)
		tween(card.id .. ":appear", 0.3, function(p)
			card.frame:SetAlpha(p)
		end)
		resize(card, true)
		return card
	end

	local f = CreateFrame("Frame", nil, content)
	card.frame = f
	f:SetPoint("LEFT", content, "LEFT")
	f:SetPoint("RIGHT", content, "RIGHT")
	f.bg = f:CreateTexture(nil, "BACKGROUND")
	f.bg:SetAllPoints()
	f.bg:SetColorTexture(1, 1, 1, 0.05)

	local icon = CreateFrame("Button", nil, f)
	icon:SetSize(ICON, ICON)
	icon:SetPoint("TOPLEFT", 3, -3)
	icon.tex = icon:CreateTexture(nil, "ARTWORK")
	icon.tex:SetAllPoints()
	icon.border = icon:CreateTexture(nil, "OVERLAY")
	icon.border:SetPoint("TOPLEFT", -2, 2)
	icon.border:SetPoint("BOTTOMRIGHT", 2, -2)
	icon.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	icon.border:SetBlendMode("ADD")
	-- One tooltip for the whole drop, wherever the mouse is on its bar (user, 2026-11-10): the item, then
	-- everyone's rolls when the drop doesn't show them as lines. The bar only takes mouse movement, so a click
	-- still reaches the window (drag it from the list). The roll buttons keep their own small tooltips.
	-- extra: adds lines at the end (a roll button says which it is).
	local function showTooltip(self, extra)
		History.tooltipBeside(self, f)
		if card.demo then
			GameTooltip:SetText(card.itemName or "Demo item")
			GameTooltip:AddLine("Demo mode: a made-up item.", 0.8, 0.8, 0.8)
		elseif card.link then
			GameTooltip:SetHyperlink(card.link)
		else
			GameTooltip:SetText(card.itemName or "Item")
		end
		if card.linesMode ~= "all" and (not card.collapsed or card.linesMode == "summary") then
			addRollsToTooltip(card) -- no player lines on the card: the item's tooltip lists the rolls
		end
		if type(extra) == "function" then
			extra(self)
		end
		GameTooltip:Show()
	end
	card.showTooltip = showTooltip
	if f.SetMouseMotionEnabled then
		f:SetMouseMotionEnabled(true) -- (movement only: clicks go straight through to the window)
		f:SetScript("OnEnter", showTooltip)
		f:SetScript("OnLeave", GameTooltip_Hide)
	end
	icon:SetScript("OnEnter", showTooltip) -- (the icon takes clicks too: shift-click links the item)
	icon:SetScript("OnLeave", GameTooltip_Hide)
	icon:SetScript("OnClick", function()
		if card.link and IsModifiedClick() then
			HandleModifiedItemClick(card.link)
		end
	end)
	card.icon = icon

	card.name = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	card.name:SetJustifyH("LEFT")
	card.name:SetWordWrap(false)
	card.ilvl = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	card.ilvl:SetJustifyH("RIGHT") -- placed by placeHeader, once the roll buttons exist
	card.name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 6, -2) -- (relative to the level, so placed once)
	card.name:SetPoint("RIGHT", card.ilvl, "LEFT", -4, 0)

	card.timer = CreateFrame("StatusBar", nil, f)
	card.timer:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	card.timer:SetStatusBarColor(1, 0.75, 0.1)
	card.timerRed = false
	card.timer:SetHeight(4)
	card.timer:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 6, 1)
	card.timer:SetPoint("RIGHT", f, "RIGHT", -6, 0)
	card.timer:SetMinMaxValues(0, 1)
	card.timer.bg = card.timer:CreateTexture(nil, "BACKGROUND")
	card.timer.bg:SetAllPoints()
	card.timer.bg:SetColorTexture(0, 0, 0, 0.5)
	card.timer:Hide()
	card.timer:SetScript("OnUpdate", Guard.wrapUpdate("timer", function(self)
		local left, total
		if card.rollID and card.rollTime then
			local ok, ms = pcall(GetLootRollTimeLeft, card.rollID)
			left, total = ok and ms and ms / 1000, card.rollTime / 1000
		elseif card.endsAt and card.duration then
			left, total = card.endsAt - GetTime(), card.duration
		end
		if not left or not total or total <= 0 or (left <= 0 and not card.rollID) then
			self:Hide() -- (a drop known only from the loot history, its time up: no empty bar while it's decided)
			return
		end
		-- Drawn only when it moves a visible step (1/1000 of the bar): the bar creeps a few pixels a second,
		-- so redrawing every frame was most of the window's per-frame work.
		local value = math.min(1, math.max(0, left / total))
		local step = math.floor(value * 1000)
		if step ~= self.step then
			self.step = step
			self:SetValue(value)
			local hl = card.hl
			if hl and hl.style and (hl.style == "timer" or hl.style == "all") then
				hl.spark:SetPoint("CENTER", self, "LEFT", value * self:GetWidth(), 0)
			end
		end
		if left < 10 and not card.timerRed then
			card.timerRed = true
			self:SetStatusBarColor(1, 0.25, 0.2)
		end
	end, 1 / 20)) -- (20 times a second: at most a fifth of a pixel per update, and a fraction of the work)

	card.winnerIcon = f:CreateTexture(nil, "OVERLAY")
	card.winnerIcon:SetSize(14, 14)
	card.winnerIcon:SetAlpha(0)
	card.winnerText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	-- Row grid (2026-11-10): line 2's first piece starts in the item name's column (icon right + 6), on one
	-- baseline (icon bottom + 4) for the counts, the winner and the boss. The winner's 14 px choice icon sits
	-- in that column and the name follows it.
	card.winnerText:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 24, 4)
	card.winnerText:SetPoint("RIGHT", f, "RIGHT", -6, 0)
	card.winnerText:SetJustifyH("LEFT")
	card.winnerText:SetWordWrap(false)
	card.winnerText:SetAlpha(0)
	card.winnerIcon:SetPoint("RIGHT", card.winnerText, "LEFT", -4, 0)

	-- The summary line ("Player lines: Summary"): counts of each choice; hovering the drop lists everyone.
	card.waiting = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	card.waiting:SetJustifyH("LEFT")
	card.waiting:SetWordWrap(false)

	-- Your own choice and roll, where the roll buttons were ("Player lines" Summary or None).
	-- Your choice, once made: the icon exactly where the right-hand roll button was (same size and corner),
	-- your roll number just left of it.
	card.mineIcon = f:CreateTexture(nil, "ARTWORK")
	card.mineIcon:SetSize(20, 20)
	card.mineIcon:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
	card.mineRoll = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	card.mineRoll:SetPoint("RIGHT", card.mineIcon, "LEFT", -3, 0)
	card.mineIcon:Hide()
	card.mineRoll:Hide()
	card.setMine = function(state, roll)
		if card.mineState == state and card.mineRollShown == roll then
			return
		end
		card.mineState, card.mineRollShown = state, roll
		if state and state ~= STATE.NOROLL and not card.finished and card.linesMode ~= "all" then
			card.mineIcon:SetAtlas(STATE_ATLAS[state] or STATE_ATLAS[STATE.PASS])
			card.mineIcon:Show()
			card.mineRoll:SetText(state == STATE.PASS and "" or (roll and tostring(roll) or "|cff888888...|r"))
			card.mineRoll:Show()
		else
			card.mineIcon:Hide()
			card.mineRoll:Hide()
		end
		placeHeader(card)
	end

	-- The boss the drop came from, on history rows (R35). Small, right-aligned, cut short if long.
	card.boss = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	card.boss:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 7) -- (line 2's baseline: icon bottom + 4)
	card.boss:SetWidth(110)
	card.boss:SetJustifyH("RIGHT")
	card.boss:SetWordWrap(false)
	card.boss:Hide()

	card.buttons = createButtons(card)
	placeHeader(card)

	insertCard(card)
	f:SetAlpha(0)
	tween(card.id .. ":appear", 0.3, function(p)
		f:SetAlpha(p)
	end)
	resize(card, true)
	return card
end

-- Drop updates call this on every roll. When the item and its details are unchanged and the item level
-- is settled, there's nothing to redraw. Item data can arrive late, so it keeps trying until it is.
local function setItem(card, link, name, icon, quality)
	card.link = link or card.link
	if isSecret(card.link) then
		card.keyLink, card.itemKey = nil, nil -- can't be read: never pairs by item
	elseif card.keyLink ~= card.link then
		card.keyLink, card.itemKey = card.link, itemKeyFromLink(card.link)
	end
	-- Secret values can't be compared; if any input is one, always redraw (as before).
	local comparable = not (isSecret(card.link) or isSecret(name) or isSecret(icon) or isSecret(quality))
	if comparable and card.itemShown and card.shownLink == card.link and card.shownNameArg == name
		and card.shownIconArg == icon and card.shownQualityArg == quality and card.ilvlSettled then
		return
	end
	card.itemShown = comparable
	card.shownLink, card.shownNameArg, card.shownIconArg, card.shownQualityArg =
		comparable and card.link, comparable and name, comparable and icon, comparable and quality
	local itemID = itemIDFromLink(card.link)
	if not icon and itemID and C_Item and C_Item.GetItemIconByID then
		icon = C_Item.GetItemIconByID(itemID)
	end
	if not quality and itemID and C_Item and C_Item.GetItemQualityByID then
		quality = C_Item.GetItemQualityByID(itemID)
	end
	card.itemName = name or (card.link and card.link:match("%[(.-)%]")) or "Item"
	card.icon.tex:SetTexture(icon or 134400)
	if quality ~= nil and not isSecret(quality) then
		card.quality = quality
	end
	local r, g, b = qualityColor(quality)
	card.icon.border:SetVertexColor(r, g, b)
	card.name:SetText(card.itemName)
	card.name:SetTextColor(r, g, b)
	-- Item level, for gear only (recipes and containers have one too, but it means nothing there).
	-- Item data can arrive late; setItem runs again on later updates and fills it in then.
	local level
	card.ilvlSettled = false
	if card.link and C_Item and C_Item.IsEquippableItem and C_Item.GetDetailedItemLevelInfo then
		local okEquip, equippable = pcall(C_Item.IsEquippableItem, card.link)
		if okEquip and equippable and not isSecret(equippable) then
			local okLevel, value = pcall(C_Item.GetDetailedItemLevelInfo, card.link)
			if okLevel and value and not isSecret(value) and value > 0 then
				level = value
				card.ilvlSettled = quality ~= nil -- keep refreshing until the quality colour is known too
			end
		elseif okEquip and not isSecret(equippable) and C_Item.IsItemDataCachedByID then
			local okCached, cached = pcall(C_Item.IsItemDataCachedByID, card.link)
			if okCached and cached and not isSecret(cached) then
				card.ilvlSettled = quality ~= nil -- not gear and its data has loaded: no level to show
			end
		end
	end
	card.ilvl:SetText(level and ("ilvl " .. level) or "")
end

-- Adds or updates one player's line. A new player joins at the end of their group; a changed choice
-- moves the line to its new group by trading places (see moveToGroup). quiet: no slide-in
-- (the card's first list of players, or a drop shown already decided).
local function setRoll(card, key, entry, quiet)
	local line = card.lines[key]
	local isNew = not line
	if isNew then
		line = acquireLine(card)
		card.lines[key] = line
		line.slide = quiet and 0 or -18
		if not quiet then
			line:SetAlpha(0) -- (it slides and fades in; a quiet one is already at full alpha)
		end
		-- A new player goes in at the end of their group; the lines after it move down one row (usually
		-- none: the first list comes sorted, and later newcomers are rare).
		local group = lineGroup(entry)
		local counts = card.groupCount
		local pos = groupStart(card, group) + counts[group]
		table.insert(card.lineOrder, pos, key)
		counts[group] = counts[group] + 1
		line.group = group
		-- The lines from here down moved one row. Their places are set once, after the whole list (applyRolls),
		-- not once per newcomer: a first list out of group order would otherwise place lines n^2/2 times.
		for i = pos, #card.lineOrder do
			card.lines[card.lineOrder[i]].index = i
		end
		card.placeFrom = math.min(card.placeFrom or pos, pos)
	end
	line.entry = entry
	local group = lineGroup(entry)
	if group ~= line.group then
		moveToGroup(card, line, group)
	end
	updateLineText(card, line, entry)
	lastActivity = GetTime()
	if isNew and not quiet then
		tween(card.id .. ":" .. key .. ":in", 0.3, function(p)
			line.slide = -18 * (1 - p)
			line:SetAlpha(p)
			placeLine(card, line, line.index)
		end)
	end
	if isNew then
		resize(card, card.instant) -- only grows when more players are listed than the card has room for
	end
end

-- "[need] 2   [greed] 1   [pass] 3" ("Player lines: Summary"; the icons dimmed). Only rebuilt when a count changes.
-- One format per mix of counts (at most 64), made the first time that mix shows: a changed count then makes
-- no new strings (a raid's summaries change on every roll). args: scratch for the numbers.
-- Each choice is its icon (as on the player lines and in the tooltip), dimmed to 60% to sit with the grey
-- text (an icon in text can only be tinted, not made grey; trial, user 2026-11-10).
local SUMMARY_FORMATS = { args = {}, icon = function(state)
	return "|A:" .. STATE_ATLAS[state] .. ":12:12:0:0:153:153:153|a %d"
end }
local function setSummary(card, need, greed, transmog, pass)
	-- (Who's still deciding isn't counted here: the timer says the roll is on, and the tooltip shows each one.)
	local key = ((need * 64 + greed) * 64 + transmog) * 64 + pass
	if card.summaryKey == key then
		return
	end
	card.summaryKey = key
	local mix = (need > 0 and 1 or 0) + (greed > 0 and 2 or 0) + (transmog > 0 and 4 or 0) + (pass > 0 and 8 or 0)
	local format = SUMMARY_FORMATS[mix]
	if not format then
		local icons = {}
		if need > 0 then icons[#icons + 1] = SUMMARY_FORMATS.icon(STATE.NEED) end
		if greed > 0 then icons[#icons + 1] = SUMMARY_FORMATS.icon(STATE.GREED) end
		if transmog > 0 then icons[#icons + 1] = SUMMARY_FORMATS.icon(STATE.TRANSMOG) end
		if pass > 0 then icons[#icons + 1] = SUMMARY_FORMATS.icon(STATE.PASS) end
		format = #icons > 0 and table.concat(icons, "   ") or "..." -- (nobody has chosen yet)
		SUMMARY_FORMATS[mix] = format
	end
	local args, n = SUMMARY_FORMATS.args, 0
	if need > 0 then n = n + 1; args[n] = need end
	if greed > 0 then n = n + 1; args[n] = greed end
	if transmog > 0 then n = n + 1; args[n] = transmog end
	if pass > 0 then n = n + 1; args[n] = pass end
	placeSummary(card)
	card.waiting:SetFormattedText(format, unpack(args, 1, n))
end

-- One full list of players (shaped like C_LootHistory's rollInfos) drawn as "Player lines" says:
-- a line each, one summary line, or just your own choice on the item row. Every loot-history update
-- lists everyone again; lines whose player is unchanged are skipped.
local function applyRolls(card, rollInfos, quiet)
	local mode = card.linesMode
	-- Player lines only for a drop shown full size: a compact row (collapsed) has none, and neither does a drop
	-- already decided when first seen (e.g. Blizzard's replay after a /reload), which collapses at once.
	-- (A late update for a compact row used to slide a stray line in over the next drop.)
	local drawLines = not (card.collapsed or card.instant)
	if drawLines or mode == "summary" then
		card.lastRolls = rollInfos -- (a compact Summary row keeps it for its hover list)
	end
	if not card.hadRolls and #rollInfos > 0 and (card.reserved or 0) > #rollInfos and heldCard() ~= card then
		card.reserved = #rollInfos -- fewer can roll than are in the group: drop the spare rows now, not mid-roll
	end
	if #rollInfos > (card.reserved or 0) then
		card.reserved = #rollInfos
	end
	quiet = quiet or card.instant or not card.hadRolls
	card.hadRolls = card.hadRolls or #rollInfos > 0
	local wasReported = card.selfReported
	local need, greed, transmog, pass = 0, 0, 0, 0
	local sv = issecretvalue -- (read once per update: this runs for every player on every update)
	for _, r in ipairs(rollInfos) do
		local state = r.state
		if state == nil or (sv and sv(state)) then
			state = STATE.NOROLL
		end
		local isSelf = r.isSelf and true or false
		if mode == "all" then
			if drawLines then
				local name, guid, roll, class = r.playerName, r.playerGUID, r.roll, r.playerClass
				if sv then
					if name ~= nil and sv(name) then name = nil end
					if guid ~= nil and sv(guid) then guid = nil end
					if roll ~= nil and sv(roll) then roll = nil end
					if class ~= nil and sv(class) then class = nil end
				end
				name = name or "?"
				local key = guid or name
				local line = card.lines[key]
				if not (line and line.drawn and line.shownState == state and line.shownRoll == roll
					and line.shownName == name and line.shownClass == class and line.shownSelf == isSelf) then
					local entry = line and line.entry -- (an existing line's entry is updated, not replaced)
					if entry then
						entry.name, entry.class, entry.state, entry.roll, entry.isSelf = name, class, state, roll, isSelf
					else
						entry = { name = name, class = class, state = state, roll = roll, isSelf = isSelf }
					end
					setRoll(card, key, entry, quiet)
				end
			end
		else
			if state == STATE.NEED or state == STATE.NEED_OFF then
				need = need + 1
			elseif state == STATE.GREED then
				greed = greed + 1
			elseif state == STATE.TRANSMOG then
				transmog = transmog + 1
			elseif state == STATE.PASS then
				pass = pass + 1
			end
			if isSelf then
				card.setMine(state == STATE.NOROLL and card.clickedState or state, safe(r.roll))
			end
		end
		if isSelf and state ~= STATE.NOROLL then
			card.youRolled = true
			card.selfReported = true
			card.selfState = state
		end
	end
	if card.placeFrom then
		local order = card.lineOrder
		for i = card.placeFrom, #order do
			placeLine(card, card.lines[order[i]], i)
		end
		card.placeFrom = nil
	end
	if mode == "summary" then
		setSummary(card, need, greed, transmog, pass)
	end
	if card.twins and card.selfReported and not wasReported then
		twinReported(card)
	end
end

refreshSummary = function(card)
	if card.linesMode == "summary" and card.summaryKey then
		card.summaryKey = nil
		if card.lastRolls then
			applyRolls(card, card.lastRolls, true)
		end
	end
end

-- "Player lines" changed: redraw each roll in progress from its last list of players.
local function redrawLiveCards()
	for _, card in ipairs(cards) do
		if not card.collapsed then
			releaseLines(card)
			card.summaryKey, card.mineState, card.mineRollShown = nil, nil, nil
			card.mineIcon:Hide()
			card.mineRoll:Hide()
			card.waiting:SetText("")
			card.linesMode = currentLinesMode()
			local mode = card.linesMode
			if mode ~= "summary" then
				History.wideTimer(card) -- (Summary's thin timer goes back under the item name)
			end
			card.waiting:SetShown(mode == "summary")
			card.waiting:SetAlpha(1)
			if card.lastRolls then
				applyRolls(card, card.lastRolls, true)
			end
			if card.finished and mode == "summary" then
				card.waiting:SetAlpha(0) -- (decided: line 2 is the winner's, as finish leaves it)
			end
			if mode ~= "all" and card.clickedState and not card.selfReported then
				card.setMine(card.clickedState) -- clicked before the loot history listed anyone
			end
			if card.finished then
				if mode == "all" then
					card.winnerText:SetAlpha(0)
					card.winnerIcon:SetAlpha(0)
					if card.winnerKey and card.lines[card.winnerKey] then
						playWinnerSweep(card, card.lines[card.winnerKey])
					end
				else
					showHeaderWinner(card)
				end
			end
			placeHeader(card)
			resize(card)
		end
	end
end

local function setWinner(card, key, winner)
	card.winnerKey = key
	card.winner = winner
	local line = key and card.lines[key]
	if line then
		line.entry.roll = winner.roll or line.entry.roll
		updateLineText(card, line, line.entry)
	end
	finish(card)
end

local function setAllPassed(card)
	card.allPassed = true
	finish(card)
end

-- The result of a drop that had already settled as "Roll ended" (it came late): shown on its row and saved
-- in its History record.
function History.lateResult(card, winner, allPassed)
	card.rollEnded = nil
	card.winner, card.allPassed = winner, allPassed or nil
	updateHeaderWinner(card)
	for _, rec in ipairs(History.records) do
		local c = History.cardOf[rec]
		if c and c.card == card and c.gen == card.gen then
			rec.winner = card.winnerText:GetText()
			rec.atlas = allPassed and STATE_ATLAS[STATE.PASS] or (winner and (STATE_ATLAS[winner.state] or STATE_ATLAS[STATE.GREED])) or nil
			break
		end
	end
end

-- A roll that ended for you without its drop ever being decided (you left the group, or the loot history
-- never gave a result): the drop settles as "Roll ended" and leaves like any decided drop, instead of
-- staying open forever (which kept the window from fading and the first-use question from coming).
function History.settleEnded(card)
	if card.finished or card.dismissing then
		return
	end
	card.rollEnded = true
	finish(card)
end

trimHistory = function()
	-- Real rows keep the newest db.historyCount (20) of them. Demo rows do the same among themselves, as if
	-- your history were empty, so the demo shows the real trimming without ever costing a real row. (The
	-- dev stress test's rows are ordinary rows here; only the demo command's drops have a demo roll.)
	local total, real = 0, 0
	for _, card in ipairs(cards) do
		if card.collapsed then
			total = total + 1
			if not card.demoRoll then
				real = real + 1
			end
		end
	end
	local demoExcess = math.max(0, (total - real) - db.historyCount) -- the demo trims as if your history were empty
	local realExcess = math.max(0, real - db.historyCount)
	if demoExcess == 0 and realExcess == 0 then
		return
	end
	local kept = {}
	for i = #cards, 1, -1 do -- oldest first
		local card = cards[i]
		local drop = false
		if card.collapsed and card.demoRoll and demoExcess > 0 then
			drop, demoExcess = true, demoExcess - 1
		elseif card.collapsed and not card.demoRoll and realExcess > 0 then
			drop, realExcess = true, realExcess - 1
		end
		if drop then
			if card.historyKey then
				cardsByHistory[card.historyKey] = nil
				if not card.demo then
					skippedHistory[card.historyKey] = card.dropMark or true -- trimmed: a late update doesn't bring it back
				end
			end
			if card.rollID and cardsByRollID[card.rollID] == card then
				cardsByRollID[card.rollID] = nil
			end
			if card.demo then
				demoCardCount = demoCardCount - 1
			end
			releaseCard(card)
		else
			kept[#kept + 1] = card
		end
	end
	wipe(cards)
	for i = #kept, 1, -1 do
		cards[#cards + 1] = kept[i]
	end
end

local ordered = {} -- layout's scratch list, reused
local scrollReserved -- whether the list left room for the scrollbar at the last layout

-- Scroll for the held card, plus the gaps that make it reachable: a gap above when it would have to
-- scroll past the top, one below when the list isn't long enough to scroll that far.
local function fitScroll(s, natural, room)
	local topGap, bottomGap = 0, 0
	if s < 0 then
		topGap, s = -s, 0
	end
	local total = natural + topGap
	if s > math.max(0, total - room) then
		bottomGap = s + room - total
	end
	return s, topGap, bottomGap
end

local gripPlacedFor -- db.position the grip was last placed for (it's anchored to the window, so size doesn't matter)
-- Protected, wherever it's asked for (an event, the driver, the window opening, a setting, the grip): an
-- error while arranging the list brings Blizzard's popups back for the session.
layout = function()
	Guard.core("layout", Guard.layoutBody)
end
function Guard.layoutBody()
	if not main then
		return
	end
	-- The card under the cursor with your roll buttons holds still (R31). Where it is now: its distance
	-- from the top of the visible list, and from the window's bottom edge.
	local scrollBefore = scroll:GetVerticalScroll() -- (History's free-window shift adds to this)
	local held = heldCard()
	-- Where each drop is on screen before this layout, measured from the window's fixed edge, so a layout that
	-- scrolls the list or grows an attached window counts as moving drops too (the click guard).
	local heightBefore = main:GetHeight()
	for _, card in ipairs(cards) do
		card.screenWas = card.layoutY and (anchorFactor * heightBefore - card.layoutY + scrollBefore) or nil
	end
	local heldFromTop, heldFromBottom
	if held and held.layoutY then
		heldFromTop = held.layoutY - scroll:GetVerticalScroll()
		heldFromBottom = main:GetHeight() - heldFromTop
	end
	if trimPending then
		trimPending = false
		trimHistory()
	end
	-- One order, whatever the mouse does: drops in the order they arrived, each keeping its place when
	-- it's decided (it just gets shorter). New drops appear on the side the window grows from, so nothing
	-- already showing moves: attached (grows upward), newest on top; free (hangs from its top), newest
	-- at the bottom.
	wipe(ordered)
	if newestAtBottom() then
		for i = #cards, 1, -1 do
			ordered[#ordered + 1] = cards[i]
		end
	else
		for i = 1, #cards do
			ordered[i] = cards[i]
		end
	end
	local y = 0
	for _, card in ipairs(ordered) do
		card.listY = y
		y = y + (card.height or HEADER_H) + CARD_GAP
	end
	-- Older drops brought back with the clock continue the list on its older side: below the drops when
	-- attached (newest on top), above them when free (newest at the bottom), pushing the drops down.
	local histH = History.count() * History.ROW_H
	History.top = y
	if histH > 0 and newestAtBottom() then
		History.top = 0
		for _, card in ipairs(ordered) do
			card.listY = card.listY + histH
		end
	end
	y = y + histH
	local natural = math.max(y, HEADER_H)
	-- The window's height (fixed), or how tall it may grow with the drops ("Grow with drops"); then it scrolls.
	local limit = math.max(MIN_HEIGHT, (db.autoGrow and db.maxHeight or db.height) or FIXED_HEIGHT)
	if db.snapRows then
		limit = History.snapHeight(limit) -- (a height saved before snapping, or dragged without it, too)
	end
	local above = roomAbovePopups() -- R32: attached, never taller than the space above the roll popups
	if above and above < limit then
		local snapped = db.snapRows and History.snapHeight(above, true) or above
		limit = math.max(MIN_HEIGHT, snapped <= above and snapped or above) -- (never taller than the room)
	end
	local room = limit - TITLE_H - BOTTOM_PAD

	-- Keep the held card where it was: pick the scroll, plus a gap above or below the list if needed.
	local topGap, bottomGap, scrollTo, holdVisible = 0, 0, nil, nil
	if heldFromTop then
		local off = held.listY
		local maxHeight = TITLE_H + room + BOTTOM_PAD
		if anchorFactor == 1 then
			-- Attached: the window's bottom stays put, so the held drop keeps its distance from the bottom
			-- edge. If the window can be tall enough to show everything above the drop unscrolled, it is
			-- exactly that tall: rows below that no longer fit scroll out of view at the bottom, and a list
			-- that got shorter gets a gap under it. Otherwise the window stays at its limit and the scroll
			-- (plus a gap above or below) does it.
			local want = heldFromBottom + off
			if db.autoGrow and want <= maxHeight then
				local below, roomBelow = natural - off, heldFromBottom - TITLE_H - BOTTOM_PAD
				if below < roomBelow then
					bottomGap = roomBelow - below
				end
				holdVisible = want - TITLE_H - BOTTOM_PAD
				if want < MIN_HEIGHT then -- the panel can't be shorter: a gap above fills it, the drop stays put
					topGap = MIN_HEIGHT - want
					holdVisible = holdVisible + topGap
				end
				scrollTo = 0
			else
				scrollTo, topGap, bottomGap = fitScroll(off - (maxHeight - heldFromBottom), natural, room)
				bottomGap = math.max(bottomGap, room - (natural + topGap)) -- keep the window at its limit
			end
		else
			-- Free: the window's top stays put, so the held drop keeps its distance from the top of the
			-- list. Scrolled down, the scroll stays and the window shows the list from there, up to its
			-- limit (it grows or shrinks at the bottom, which doesn't move the drop).
			local s = off - heldFromTop
			if s <= 0 or not db.autoGrow then
				scrollTo, topGap, bottomGap = fitScroll(s, natural, room)
			else
				scrollTo = s
				holdVisible = math.min(room, natural - s)
				local shown = math.max(holdVisible, MIN_HEIGHT - TITLE_H - BOTTOM_PAD)
				bottomGap = math.max(0, s + shown - natural) -- enough list to stay scrolled that far
			end
		end
		waitForRelease() -- when the card lets go: any gap closes
	end
	History.top = History.top + topGap -- the older drops move with the cards (a gap above shifts both)
	for _, card in ipairs(ordered) do
		local cy = card.listY + topGap
		if card.layoutY ~= cy then -- only cards whose place changed are anchored again
			card.layoutY = cy
			card.frame:ClearAllPoints()
			card.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -cy)
			card.frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -cy)
		end
	end
	local contentHeight = natural + topGap + bottomGap
	-- Fixed (the default): always as tall as set with the grip, so the window never changes size; longer lists scroll.
	local visible = holdVisible or (not db.autoGrow and room) or math.min(contentHeight, room)
	local scrolls = contentHeight > visible + 0.5
	if heldFromTop and scrollReserved ~= nil then
		scrolls = scrollReserved -- keep the list's width while a drop is held (the scrollbar would shift it)
	end
	scrollReserved = scrolls
	-- Layout runs every frame while a height animates: each size is set only when it changed. (The window's
	-- height is compared with its live height, so a resize by the grip is never missed.)
	local sized = false
	local contentW = WIDTH - 2 * SIDE_PAD - (scrolls and scrollBar and SCROLLBAR_W or 0)
	if content.laidW ~= contentW then
		scroll:SetPoint("BOTTOMRIGHT", -(SIDE_PAD + (scrolls and scrollBar and SCROLLBAR_W or 0)), BOTTOM_PAD)
	end
	if content.laidW ~= contentW or content.laidH ~= contentHeight then
		content.laidW, content.laidH, sized = contentW, contentHeight, true
		content:SetSize(contentW, contentHeight)
	end
	-- Never shorter than MIN_HEIGHT: the panel template can't draw its border corners on a shorter frame.
	local height = main:GetHeight()
	if not (grip and grip:GetScript("OnUpdate")) then -- leave the height alone while it's being dragged
		local want = math.max(MIN_HEIGHT, TITLE_H + visible + BOTTOM_PAD)
		if want ~= height then
			height, sized = want, true
			main:SetHeight(height)
		end
	end
	local isEmpty = #ordered == 0 and histH == 0
	local demoLead = (History.demoLeadUntil and GetTime() < History.demoLeadUntil) and true or false
	if main.emptyShown ~= isEmpty or (isEmpty and main.emptyLead ~= demoLead) then
		main.emptyShown, main.emptyLead = isEmpty, demoLead
		main.empty:SetText(demoLead and "Demo starting in a few seconds" or "No loot rolls yet")
		main.emptyHint:SetText(demoLead and "" or "Group loot rolls appear here.")
		main.empty:SetShown(isEmpty)
		main.emptyHint:SetShown(isEmpty)
	end
	local demoOffer = isEmpty and not demoLead and History.canDemo()
	if main.demoButton:IsShown() ~= demoOffer then
		main.demoButton:SetShown(demoOffer)
	end
	if scrollBar then
		scrollBar:SetShown(scrolls)
	end
	if grip and gripPlacedFor ~= db.position then
		gripPlacedFor = db.position
		placeGrip()
	end
	if sized and scroll.UpdateScrollChildRect then
		scroll:UpdateScrollChildRect() -- the new range now (list and window sized), so the scroll set below isn't clamped
	end
	local range = math.max(0, contentHeight - (height - TITLE_H - BOTTOM_PAD)) -- how far the list can scroll
	if History.scrollAdd then
		-- the older drops just came or went above the drops (free window): keep the drops where they were
		scroll:SetVerticalScroll(math.max(0, math.min(range, scrollBefore + History.scrollAdd)))
		History.scrollAdd = nil
	elseif scrollTo then
		scroll:SetVerticalScroll(math.max(0, math.min(range, scrollTo)))
	elseif shownNewestAtBottom ~= nil and shownNewestAtBottom ~= newestAtBottom() then
		scrollToNewestPending = false -- the list just flipped (dragged free, Position changed): show the newest end
		scroll:SetVerticalScroll(newestAtBottom() and range or 0)
	elseif scrollToNewestPending and not (db.hoverHold == "window" and main:IsMouseOver() or heldCard()) then
		-- (By default nothing holds the list: new drops come in at the top, and the button guard covers any
		-- buttons that slide under a still cursor. "Hold the list": on roll buttons, or anywhere.)
		scrollToNewestPending = false
		scroll:SetVerticalScroll(newestAtBottom() and range or 0)
	elseif scroll:GetVerticalScroll() > range then
		scroll:SetVerticalScroll(range)
	end
	shownNewestAtBottom = newestAtBottom()
	-- Which drops moved on screen (not just in the list): those are what the click guard looks at. The drop
	-- the mouse is holding still never counts.
	local scrollNow, movedAny = scroll:GetVerticalScroll(), false
	for _, card in ipairs(ordered) do
		local was = card.screenWas
		if card ~= held and (was == nil or math.abs(anchorFactor * height - card.layoutY + scrollNow - was) > 0.5) then
			card.movedAt = GetTime()
			movedAny = true
		end
	end
	History.safePlace()
	if movedAny and main:IsMouseOver() then
		History.guardCheck = true -- next frame (positions applied): roll buttons that slid under the cursor?
		driver:Show()
	end
	Guard.call("markers", updateRollMarkers)
	if askShown then
		Guard.call("ask", Ask.place) -- the window may have grown or moved
	end
end

-- How the markers count: a drop with roll buttons whose buttons row (the top of the drop) is above or
-- below the visible part of the list.
local MARKER_H = 18
local function waitingOutOfView(card, top, view)
	if not (card.layoutY and card.buttons:IsShown()) then
		return nil
	end
	-- The roll buttons sit 4 to 24 px below the drop's top. At an edge the list can scroll past, a bar
	-- covers 18 px, so buttons there count as out of view too; at an end of the list there's no bar.
	if top > 0.5 and card.layoutY + 4 < top + MARKER_H then
		return "up"
	elseif top + view < content:GetHeight() - 0.5 and card.layoutY + 24 > top + view - MARKER_H then
		return "down"
	end
end

-- Whether the cursor is on the strip a marker covers (its edge of the list), shown or not.
local function cursorOnStrip(up) -- (the strip at the top or bottom edge of the list)
	if not GetCursorPosition then
		return false
	end
	local x, y = GetCursorPosition()
	local scale = scroll:GetEffectiveScale()
	x, y = x / scale, y / scale
	local left, right, top, bottom = scroll:GetLeft(), scroll:GetRight(), scroll:GetTop(), scroll:GetBottom()
	if not (left and right and top and bottom) or x < left or x > right then
		return false
	end
	if up then
		return y <= top and y >= top - MARKER_H
	end
	return y >= bottom and y <= bottom + MARKER_H
end

-- Waits (10 times a second, only then) for the cursor to leave a strip whose marker had to wait.
local markerWatch
local function watchStrips()
	if not markerWatch then
		markerWatch = CreateFrame("Frame")
		markerWatch:SetScript("OnUpdate", Guard.wrapUpdate("markers", function(self)
			local now = GetTime()
			local overdue = (main.markerUp.heldSince and now - main.markerUp.heldSince >= 3)
				or (main.markerDown.heldSince and now - main.markerDown.heldSince >= 3)
			if overdue or not (main:IsShown() and (cursorOnStrip(true) or cursorOnStrip(false))) then
				self:Hide()
				requestMarkers()
			end
		end, 0.1)) -- (10 times a second)
	end
	markerWatch:Show()
end

-- A marker doesn't change under the cursor: disappearing could uncover roll buttons you're about to
-- click, so it never does while the cursor is on its strip; appearing waits up to 3 s (a click on a
-- bar only scrolls). The count can change meanwhile.
local function setMarker(marker, count)
	local now = GetTime()
	local wantShown = count > 0
	-- Held back while the cursor is on its strip. Hiding always waits for the cursor to leave (hiding
	-- could uncover roll buttons under it); showing waits at most 3 s (a bar click only scrolls).
	if wantShown ~= marker:IsShown() and cursorOnStrip(marker.up)
		and (not wantShown or now - (marker.heldSince or now) < 3) then
		if wantShown then
			marker.heldSince = marker.heldSince or now
		end
		watchStrips()
		if marker:IsShown() and marker.count ~= count and count > 0 then
			marker.count = count
			marker.text:SetText(count == 1 and "1 more to roll" or (count .. " more to roll"))
		end
		return
	end
	marker.heldSince = nil
	if count > 0 then
		if marker.count ~= count then
			marker.count = count
			marker.text:SetText(count == 1 and "1 more to roll" or (count .. " more to roll"))
		end
		if not marker:IsShown() then
			marker:Show()
		end
	elseif marker:IsShown() then
		marker:Hide()
	end
end

updateRollMarkers = function()
	if not (main and main.markerUp) then
		return
	end
	local above, below = 0, 0
	if db.rollFromWindow and not Guard.fallback and main:IsShown() then
		local top, view = scroll:GetVerticalScroll(), main:GetHeight() - TITLE_H - BOTTOM_PAD
		local held = heldCard() -- the drop you're on is never "more to roll"
		if held and waitingOutOfView(held, top, view) then
			waitForRelease() -- recount once you let go of it (its release relays out, which recounts)
		end
		for _, card in ipairs(cards) do
			local where = card ~= held and waitingOutOfView(card, top, view)
			if where == "up" then
				above = above + 1
			elseif where == "down" then
				below = below + 1
			end
		end
	end
	setMarker(main.markerUp, above)
	setMarker(main.markerDown, below)
end

-- A marker was clicked: scroll the nearest waiting drop in that direction into view, clear of the marker.
scrollToWaitingFn = function(up)
	local top, view = scroll:GetVerticalScroll(), main:GetHeight() - TITLE_H - BOTTOM_PAD
	local best
	for _, card in ipairs(cards) do
		if waitingOutOfView(card, top, view) == (up and "up" or "down") then
			if not best or (up and card.layoutY > best.layoutY) or (not up and card.layoutY < best.layoutY) then
				best = card
			end
		end
	end
	if not best then
		updateRollMarkers() -- (the count was out of date)
		return
	end
	local range = math.max(0, content:GetHeight() - view)
	local target = up and (best.layoutY - 22) or (best.layoutY + HEADER_H + 22 - view)
	scroll:SetVerticalScroll(math.max(0, math.min(range, target)))
	updateRollMarkers()
end

local function showWindow()
	if tweens["main:fade"] then -- new activity during the auto-hide fade: cancel it
		tweens["main:fade"] = nil
		main:SetAlpha(1)
	end
	if not main:IsShown() then
		main:Show()
	end
	lastActivity = GetTime()
end

----------------------------------------------------------------------------------------------------
-- Blizzard's roll popups, hidden only while "Roll from this window" is on and RollFrames is healthy.
----------------------------------------------------------------------------------------------------

local function suppressBlizzard()
	if not (db.rollFromWindow and not Guard.fallback and main and main:IsShown()) then
		return false
	end
	-- Safety net: while Blizzard shows a roll RollFrames doesn't have (one left open across a /reload, or
	-- any other gap), its popups stay up, so that roll can always be made.
	local frames = GroupLootContainer and GroupLootContainer.rollFrames
	if type(frames) == "table" then
		for _, frame in pairs(frames) do
			local id = type(frame) == "table" and frame.rollID or nil
			if id ~= nil and (isSecret(id) or not (cardsByRollID[id] or twinOfRoll[id])) then
				return false
			end
		end
	end
	return true
end

local function applyBlizzardPopups()
	if not GroupLootContainer then
		return
	end
	if suppressBlizzard() then
		GroupLootContainer:Hide()
	elseif type(GroupLootContainer.rollFrames) == "table" and next(GroupLootContainer.rollFrames) ~= nil then
		GroupLootContainer:Show() -- (Blizzard leaves gaps in this list, so it's checked with next, not #)
	end
end

-- Something that shows the rolls failed: Blizzard's popups come back for the rest of the session (no
-- automatic retries; they'd make the frames come and go). The popups come first, so nothing after can
-- stop them; every later step is protected on its own.
function Guard.fail(err, where)
	if Guard.fallback then
		return
	end
	Guard.fallback = true
	if GroupLootContainer then
		pcall(GroupLootContainer.Show, GroupLootContainer)
	end
	if db and db.rollFromWindow then -- (without roll buttons in the window nothing changes for you: diag has it)
		pcall(say, "switched back to Blizzard's standard roll frames for this session because of a problem. "
			.. "Type /reload to try RollFrames again.")
	end
	Guard.note(where or "rolls", err)
	pcall(function()
		if askShown then
			hideAsk()
		end
	end)
	for _, card in ipairs(cards) do
		pcall(refreshButtons, card) -- (the window's own roll buttons go: the popups are the way to roll now)
	end
end

----------------------------------------------------------------------------------------------------
-- Diagnostics log (no player names), saved for review.
----------------------------------------------------------------------------------------------------

-- Dev builds (the local copy) log everything. The packager comments the block below out of release
-- zips, so players' builds keep DEV = false. Normal code must never depend on anything in a debug block.
local DEV = false
--@debug@
DEV = true
--@end-debug@
local LOG_MAX = 300

-- Troubleshooting log, saved with the settings (written on /reload or logout). Always on in dev builds;
-- players can turn it on with /rollframes diag log for a bug report. Never names: classes, states and rolls only.
log = function(kind, fields)
	if not (DEV or db.debugLog) then
		return
	end
	db.log = db.log or {}
	local _, instanceType = IsInInstance()
	local entry = {
		time = date("%Y-%m-%d %H:%M:%S"), kind = kind,
		combat = InCombatLockdown() or nil,
		dead = UnitIsDeadOrGhost("player") or nil,
		instance = instanceType ~= "none" and instanceType or nil,
		group = IsInRaid() and "raid" or (IsInGroup() and "party" or nil),
	}
	for k, v in pairs(fields or {}) do
		entry[k] = v
	end
	db.log[#db.log + 1] = entry
	-- Trim in batches (let it reach 375, cut back to 300 in one move) rather than shifting every entry each time.
	local n = #db.log
	if n > LOG_MAX * 1.25 then
		local excess = n - LOG_MAX
		for i = 1, n - excess do -- a plain loop: WoW's Lua 5.1 has no table-move function
			db.log[i] = db.log[i + excess]
		end
		for i = n - excess + 1, n do
			db.log[i] = nil
		end
	end
end

-- R38 pairing data (roll starts and each drop's first loot-history entry) also go to a separate, small
-- log, so a raid's many roll updates don't push them out of the main log before they're looked at.
local PAIR_LOG_MAX = 200
local function logPairing(kind, fields)
	if not (DEV or db.debugLog) then
		return
	end
	db.pairLog = db.pairLog or {}
	local entry = { time = date("%Y-%m-%d %H:%M:%S"), kind = kind }
	for k, v in pairs(fields) do
		entry[k] = v
	end
	db.pairLog[#db.pairLog + 1] = entry
	if #db.pairLog > PAIR_LOG_MAX * 1.25 then
		local n, excess = #db.pairLog, #db.pairLog - PAIR_LOG_MAX
		for i = 1, n - excess do -- a plain loop: WoW's Lua 5.1 has no table-move function
			db.pairLog[i] = db.pairLog[i + excess]
		end
		for i = n - excess + 1, n do
			db.pairLog[i] = nil
		end
	end
end

-- Whether log() will record anything. Check this before building log-only data, so players pay nothing.
logging = function()
	return DEV or (db and db.debugLog) or false
end

----------------------------------------------------------------------------------------------------
-- Real data
----------------------------------------------------------------------------------------------------

-- The oldest card for this item that's still waiting for its loot-history entry. forRoll: only cards
-- without a roll yet.
local function findPendingByItem(link, forRoll)
	local key, itemID = itemKeyFromLink(link), itemIDFromLink(link)
	if not key then
		return nil -- an unreadable link never pairs with another
	end
	-- Same item and suffix first; then the same item ID, in case a roll's link and its loot-history link
	-- ever describe the suffix differently (not seen yet; the dev log's item strings will tell).
	-- A drop that settled as "Roll ended" (History.settleEnded) only takes a loot-history entry when no other
	-- drop of that item is waiting (its own late result), never ahead of a live drop of the same item.
	for pass = 1, forRoll and 2 or 4 do
		local settled = pass > 2
		for i = #cards, 1, -1 do
			local card = cards[i]
			if not card.historyKey and not card.demo and not (forRoll and (card.rollID or card.rollStarted))
				and (card.rollEnded and true or false) == settled
				and ((pass % 2 == 1) and card.itemKey == key or (pass % 2 == 0) and itemIDFromLink(card.link) == itemID) then
				return card
			end
		end
	end
end

-- A new loot-history entry: which waiting card is it? A drop's history starts with its first roll, so two
-- drops of the same item can start in one order and get history in the other. If the entry lists your
-- choice, it's the card you clicked with that choice; otherwise the oldest waiting card.
local function findPendingForDrop(link, info)
	local key = itemKeyFromLink(link)
	if not key then
		return nil
	end
	for _, r in ipairs(info.rollInfos or {}) do
		if r.isSelf then
			local state = safe(r.state)
			if state and state ~= STATE.NOROLL then
				for i = #cards, 1, -1 do
					local c = cards[i]
					if not c.historyKey and not c.demo and not c.rollEnded and c.clickedState == state and c.itemKey == key then
						return c
					end
				end
			end
			break
		end
	end
	return findPendingByItem(link)
end

-- Removes the demo's made-up drops, so they never sit in the history next to real loot.
local demoRun = 0 -- counts demos; a demo's drops still to come check it, so clearing cancels them

local clearDemoCards -- (assigned below; History.stopDemo uses it)
History.stopDemo = function()
	clearDemoCards()
	relayoutPending = true
	driver:Show()
end
clearDemoCards = function()
	demoRun = demoRun + 1 -- drops of a demo still playing won't start any more
	History.demoLeadUntil = nil -- (the empty text goes back to normal)
	History.demoActive = nil
	if #History.demo > 0 then
		wipe(History.demo)
		if History.shown then relayoutPending = true; driver:Show() end
	end
	if demoCardCount <= 0 then
		return -- runs on every drop update; usually there's nothing to clear
	end
	demoCardCount = 0
	demoClears = demoClears + 1
	local kept, removed = {}, false
	for _, card in ipairs(cards) do
		if card.demo then
			if card.historyKey and cardsByHistory[card.historyKey] == card then
				cardsByHistory[card.historyKey] = nil
			end
			releaseCard(card)
			removed = true
		else
			kept[#kept + 1] = card
		end
	end
	if removed then
		cards = kept
		layout()
	end
end

-- Logs only (R38): the item part of a link ("item:id:enchant:...:bonus"), so the log shows whether two
-- copies of the same item can be told apart. Item strings carry no names.
local function itemStringForLog(link)
	if not link or isSecret(link) then
		return nil
	end
	return link:match("item:[%-%d:]*")
end

-- Logs only: how many cards for this item are waiting for their loot-history entry (more than one means
-- the pairing is a guess, R38).
local function waitingForItemForLog(link)
	local key, n = itemKeyFromLink(link), 0
	for _, c in ipairs(cards) do
		if key and not c.historyKey and not c.demo and c.itemKey == key then
			n = n + 1
		end
	end
	return n
end

-- One loot-history update. info has the shape of C_LootHistory.GetSortedInfoForDrop's result.
-- opts (dev stress test only): demo = made-up drop, cleared like the demo's; quiet = no log entry;
-- noOpen = don't open the window.
local function applyDropInfo(encounterID, lootListKey, info, opts)
	local historyKey = encounterID .. ":" .. lootListKey
	local link = safe(info.itemHyperlink)
	local mark = (link or "?") .. "@" .. tostring(safe(info.startTime) or "")
	local skipped = skippedHistory[historyKey]
	if skipped then
		if skipped == true or skipped == mark then
			return -- already left out of the list (faded, trimmed, cleared, or filtered out)
		end
		skippedHistory[historyKey] = nil -- the same key for a different drop: that's new loot
	end
	-- Made-up drops never take over a real drop that's waiting for its history entry.
	local card = cardsByHistory[historyKey] or (not (opts and opts.demo) and findPendingForDrop(link, info)) or nil
	local isNewCard = not card
	-- A drop that's already decided the first time it's seen (e.g. after a reload) and is below the
	-- "Minimum quality kept" setting, or trash with "Keep trash drops" off, never needs a card at all.
	if isNewCard and (info.winner or info.allPassed) then
		local skip
		if encounterID == 0 and not db.keepTrash then
			skip = "trash, decided when first seen"
		elseif (db.historyMinQuality or 0) > 0 then
			local itemID = itemIDFromLink(link)
			local quality = itemID and C_Item and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(itemID)
			if quality ~= nil and not isSecret(quality) and belowHistoryQuality(nil, quality) then
				skip = "decided when first seen"
			end
		end
		if skip then
			skippedHistory[historyKey] = mark
			if logging() and not (opts and opts.quiet) then
				log("skip", { historyKey = historyKey, why = skip })
			end
			return
		end
	end
	-- Open the window before making the card, so the new drop animates in (while hidden, it wouldn't).
	-- Real loot that adds a drop or updates one still being rolled ends a demo, so demo drops never sit
	-- next to real ones. (An update that adds nothing, e.g. a filtered item, leaves the demo alone.)
	if not (opts and opts.demo) and (isNewCard or not card.finished) then
		Guard.call("demo", clearDemoCards)
		if askShown and not (info.winner or info.allPassed) then
			Guard.call("ask", Ask.putAway) -- a roll in progress: the question waits until the rolls are over
		end
	end
	if isNewCard and not (info.winner or info.allPassed) and db.autoOpen and not (opts and opts.noOpen) then
		showWindow()
	end
	if isNewCard then
		-- Drops already decided when first seen (for example after a reload) appear collapsed.
		card = createCard(link, { instant = info.winner ~= nil or info.allPassed, demo = opts and opts.demo,
			reserve = info.rollInfos and #info.rollInfos })
		if card.demo then
			demoCardCount = demoCardCount + 1
		end
	end
	local firstEntry = card.historyKey ~= historyKey -- (for the log: this card's first loot-history entry)
	local waitingBefore = firstEntry and logging() and waitingForItemForLog(link) or nil
	card.historyKey = historyKey
	card.dropMark = mark
	cardsByHistory[historyKey] = card
	if card.encounterID ~= encounterID then
		-- Trash drops all come under encounter 0; each boss has its own (checked on a real 5-man, 2026-11-08).
		card.encounterID = encounterID
		card.isTrash = encounterID == 0
		card.bossName = false
		if encounterID ~= 0 and C_LootHistory.GetInfoForEncounter then
			local ok, encounter = pcall(C_LootHistory.GetInfoForEncounter, encounterID)
			card.bossName = ok and encounter and safe(encounter.encounterName) or false
		end
	end
	setItem(card, link)
	if not card.rollID and info.startTime and info.duration and not card.endsAt then
		-- Units not yet confirmed on Forever; logged below.
		local duration = info.duration > 1000 and info.duration / 1000 or info.duration
		card.duration = duration
		card.endsAt = GetTime() + duration
		if not info.winner and not info.allPassed and duration > 0 then
			card.timer:Show()
		end
	end

	applyRolls(card, info.rollInfos or {})
	refreshButtons(card)

	local logOn = logging() and not (opts and opts.quiet) -- only build the log's roll summary when it's recorded
	local logRolls
	if logOn then
		logRolls = {}
		for _, r in ipairs(info.rollInfos or {}) do
			logRolls[#logRolls + 1] = string.format("%s/%s/%s%s", tostring(safe(r.playerClass)),
				tostring(safe(r.state, STATE.NOROLL)), tostring(safe(r.roll)), r.isSelf and "/self" or "")
		end
	end

	if logOn and firstEntry then
		logPairing("drop", { encounterID = encounterID, lootListKey = lootListKey, item = itemStringForLog(link),
			pairedRollID = card.rollID, clicked = card.clickedState, waitingSameItem = waitingBefore,
			rolls = table.concat(logRolls, " ") })
	end
	if logOn then log("drop", {
		encounterID = encounterID, lootListKey = lootListKey, hasLink = link ~= nil,
		winner = info.winner ~= nil, allPassed = info.allPassed, isTied = info.isTied,
		startTime = info.startTime, duration = info.duration, historyTime = C_LootHistory.GetLootHistoryTime(),
		rolls = table.concat(logRolls, " "), newCard = isNewCard,
		-- R38 data, on a drop's first entry: its item string, the roll it was paired with, your click.
		item = firstEntry and itemStringForLog(link) or nil, pairedRollID = firstEntry and card.rollID or nil,
		clicked = firstEntry and card.clickedState or nil, waitingSameItem = waitingBefore
	}) end

	if card.rollEnded and (info.winner or info.allPassed) then
		local w = info.winner
		History.lateResult(card, w and { name = safe(w.playerName, "?"), class = safe(w.playerClass), roll = safe(w.roll),
			state = safe(w.state) } or nil, info.allPassed and not w)
	elseif info.winner and not card.finished then
		local w = info.winner
		local name = safe(w.playerName, "?")
		setWinner(card, safe(w.playerGUID) or name,
			{ name = name, class = safe(w.playerClass), roll = safe(w.roll), state = safe(w.state) })
	elseif info.allPassed and not card.finished then
		setAllPassed(card)
	end

end

local function onDropUpdate(encounterID, lootListKey)
	local info = C_LootHistory.GetSortedInfoForDrop(encounterID, lootListKey)
	if not info then
		return
	end
	applyDropInfo(encounterID, lootListKey, info) -- (clears the demo when it adds or updates a real drop)
end

local function onStartRoll(rollID, rollTime, ...)
	Guard.call("demo", clearDemoCards)
	if askShown then
		Guard.call("ask", Ask.putAway) -- never asked during a roll: back once the rolls are over
	end
	local okLink, link = pcall(GetLootRollItemLink, rollID)
	link = okLink and link or nil
	local card = findPendingByItem(link, true) -- (a second roll on the same item gets its own card)
	if not card then
		-- A history card for the same item may already exist without a roll ID.
		local key = itemKeyFromLink(link)
		for i = #cards, 1, -1 do -- oldest first, like findPendingByItem
			local c = cards[i]
			if key and c.historyKey and not c.rollID and not c.rollStarted and not c.finished
				and (c.itemKey == key or itemIDFromLink(c.link) == itemIDFromLink(link)) then
				card = c
				break
			end
		end
	end
	local isNew = not card
	if db.autoOpen then -- off: it stays in the background; Blizzard's popups show while it's closed
		showWindow() -- before making the card, so it animates in
	end
	-- Room for the whole group from the start: the loot history lists the players about 2 s later.
	card = card or createCard(link, { reserve = GetNumGroupMembers and GetNumGroupMembers() or 0 })
	card.rollID = rollID
	card.rollTime = rollTime
	card.rollStarted = GetTime()
	cardsByRollID[rollID] = card
	if not card.twins then -- another copy of this item started at the same moment: twins (R38)
		local key = itemKeyFromLink(link) -- (the card's own itemKey is set by setItem, further down)
		for _, other in ipairs(cards) do
			if key and other ~= card and other.rollID and other.rollStarted and not other.finished and not other.demo
				and card.rollStarted - other.rollStarted <= TWIN_WINDOW and other.itemKey == key then
				joinTwins(card, other)
				break
			end
		end
	end
	local okInfo, texture, name, _, quality = pcall(GetLootRollItemInfo, rollID)
	setItem(card, link, okInfo and name or nil, okInfo and texture or nil, okInfo and quality or nil)
	card.timer:SetStatusBarColor(1, 0.75, 0.1)
	card.timerRed = false
	card.timer:Show()
	refreshButtons(card)
	if logging() then
		-- R38 data: anything else the event carries (a loot handle could match the history's lootListKey),
		-- the item string, and how many cards for the same item are still waiting for their history.
		local extra = {}
		for i = 1, select("#", ...) do
			local v = select(i, ...)
			extra[#extra + 1] = isSecret(v) and "secret" or tostring(v)
		end
		local fields = { rollID = rollID, rollTime = rollTime, hasLink = link ~= nil, matchedCard = not isNew,
			extraArgs = #extra > 0 and table.concat(extra, " ") or nil, item = itemStringForLog(link),
			waitingSameItem = waitingForItemForLog(link),
			canTransmog = (select(14, pcall(GetLootRollItemInfo, rollID))) or nil } -- (13th value; pcall adds one)
		log("start", fields)
		logPairing("start", fields)
	end
	applyBlizzardPopups()
	Guard.watch(rollID)
end

-- Rolls already open when RollFrames starts (a /reload, relog or disconnect mid-roll) or after a loading
-- screen: START_LOOT_ROLL doesn't come again for them, so they're picked up here as if they'd just started.
-- (Until then, the safety net in suppressBlizzard keeps Blizzard's popup up for them.)
function Guard.adoptRolls()
	if not GetActiveLootRollIDs then
		return
	end
	local ok, ids = pcall(GetActiveLootRollIDs)
	if not ok or type(ids) ~= "table" then
		return
	end
	for _, id in ipairs(ids) do
		if type(id) == "number" and not isSecret(id) and not cardsByRollID[id] and not twinOfRoll[id] and not rolledIDs[id] then
			local okLeft, left = pcall(GetLootRollTimeLeft, id)
			if okLeft and type(left) == "number" and not isSecret(left) and left > 0 then
				local okTime, duration = false, nil
				if C_Loot and C_Loot.GetLootRollDuration then
					okTime, duration = pcall(C_Loot.GetLootRollDuration, id)
				end
				if not (okTime and type(duration) == "number" and not isSecret(duration) and duration >= left) then
					duration = left
				end
				if logging() then
					log("adopt", { rollID = id, left = left, duration = duration })
				end
				-- A roll cancelled a moment ago (a cancel-all on a loading screen) that's still open: its own drop.
				local again
				for _, card in ipairs(cards) do
					if card.cancelledRoll == id and not card.finished and not card.rollID then
						again = card
						break
					end
				end
				if again then
					again.rollID, again.cancelledRoll = id, nil
					cardsByRollID[id] = again
					again.timer:Show()
					refreshButtons(again)
					applyBlizzardPopups()
					Guard.watch(id)
				else
					onStartRoll(id, duration)
				end
			end
		end
	end
end

-- Watchdog (user, 2026-11-10): a roll waiting for you while Blizzard's popups are hidden must have its drop
-- in the window, placed, with roll buttons. It runs on a frame of its own (not the animation driver or the
-- once-a-second ticker, which an error could stop) and is never trigger-happy: a roll is first looked at
-- only after 3 s of real time AND 5 drawn frames since it started (so a loading screen, a freeze or 4 fps
-- can't trip it), only while it's still open, and a problem gets one rebuild and a second look a second
-- later. Only then do Blizzard's popups come back for the session (Guard.fail). Rolls that are fine are
-- looked at again once a second until they end.
Guard.watched = {} -- roll ID (dev builds: also a demo card) -> { at, frame, rebuilt, gen }
Guard.frameNo, Guard.nextLook = 0, 0 -- frames drawn while watching; seconds until the list is next looked at
function Guard.watch(subject)
	if Guard.fallback then
		return
	end
	Guard.watched[subject] = { at = GetTime(), frame = Guard.frameNo, gen = type(subject) == "table" and subject.gen or nil }
	if not Guard.watcher then
		Guard.watcher = CreateFrame("Frame")
		Guard.watcher:SetScript("OnUpdate", function(self, elapsed)
			Guard.frameNo = Guard.frameNo + 1
			Guard.nextLook = Guard.nextLook - elapsed
			if Guard.nextLook > 0 then
				return -- (looks 4 times a second; between looks a frame costs a subtraction)
			end
			Guard.nextLook = 0.25
			local ok, err = pcall(Guard.watchStep, GetTime())
			if not ok then
				self:Hide()
				Guard.fail(err, "watchdog") -- (the safety net itself failed: the safe side is Blizzard's popups)
			end
		end)
	end
	Guard.watcher:Show()
end

-- Whether a drop's buttons can be used: shown, placed in the list, in a window that's on screen.
function Guard.cardReady(card)
	if not main:IsVisible() then
		return "ok" -- the whole UI is hidden (Alt-Z, a cinematic): positions can't be read, and Blizzard's popups are hidden too
	elseif not card.frame:IsShown() then
		return "bad", "drop hidden"
	elseif not card.layoutY then
		return "bad", "drop not placed"
	elseif not card.buttons:IsShown() then
		return "bad", "no buttons"
	elseif not main:GetTop() then
		return "bad", "window not placed"
	end
	return "ok"
end

-- "done": nothing left to watch (the roll is over or made, or the window isn't hiding Blizzard's popups
-- for it); "ok": its drop has usable buttons, or your click is on its way; else "bad" and why.
function Guard.rollState(subject, w)
	if type(subject) == "table" then -- a demo drop (dev builds)
		local card = subject
		if card.gen ~= w.gen or not card.demoWaitsForYou or card.youRolled or card.finished
			or GetTime() >= (card.endsAt or 0) or not db.rollFromWindow or not main:IsShown() then
			return "done"
		end
		return Guard.cardReady(card)
	end
	local id = subject
	if rolledIDs[id] or awaitingConfirm[id] ~= nil then
		return "done"
	end
	local ok, left = pcall(GetLootRollTimeLeft, id)
	if not ok or type(left) ~= "number" or isSecret(left) or left <= 0 then
		return "done"
	end
	if not suppressBlizzard() then
		return "ok" -- Blizzard's popups are up for it (the window may hide them again later: still watched)
	end
	local group = twinOfRoll[id]
	if group then
		if group.used[id] then
			return "ok" -- clicked through one of the copies; the report is on its way
		end
		local why = "no copy has buttons"
		for _, member in ipairs(group.members) do
			if member[1].gen == member[2] then
				local state, reason = Guard.cardReady(member[1])
				if state == "ok" then
					return "ok"
				end
				why = reason
			end
		end
		return "bad", why
	end
	local card = cardsByRollID[id]
	if not card then
		-- Neither the window nor Blizzard's popups have it (a popup for it would have kept them up, above):
		-- it has ended, or the game hasn't given it a popup yet. Nothing to fall back to.
		return "done"
	end
	if card.youRolled or card.clickRoll ~= nil or card.finished then
		return "ok"
	end
	return Guard.cardReady(card)
end

-- The one rebuild before giving up: a fresh layout and the drop's buttons again. (It never makes a drop:
-- a roll with no drop is either over or still on Blizzard's popups.)
function Guard.rebuild(subject)
	if Guard.test == "watchdog" then
		return -- (dev: /rollframes fail watchdog shows what happens when the rebuild doesn't help)
	end
	local card = type(subject) == "table" and subject or cardsByRollID[subject]
	relayoutPending = false
	layout()
	if card then
		refreshButtons(card)
	end
	local group = twinOfRoll[subject]
	if group then
		refreshTwins(group)
	end
end

function Guard.watchStep(now)
	if Guard.fallback then
		wipe(Guard.watched)
	end
	for subject, w in pairs(Guard.watched) do
		if Guard.frameNo - w.frame >= 5 and now - w.at >= (w.rebuilt and 1 or 3) then
			local state, why = Guard.rollState(subject, w)
			if state == "done" then
				Guard.watched[subject] = nil
			elseif state == "ok" then
				w.at, w.frame, w.rebuilt = now - 2, Guard.frameNo, nil -- (next look in a second)
			elseif not w.rebuilt then
				w.at, w.frame, w.rebuilt = now, Guard.frameNo, true
				if logging() then
					log("watchdog", { step = "rebuild", why = why, demo = type(subject) == "table" or nil })
				end
				Guard.rebuild(subject)
			else
				Guard.watched[subject] = nil
				Guard.fail("a roll waiting for you had no usable buttons (" .. why .. ")", "watchdog")
				return
			end
		end
	end
	if next(Guard.watched) == nil then
		Guard.watcher:Hide()
	end
end

local function onCancelRoll(rollID)
	local card = cardsByRollID[rollID]
	if card then
		card.timer:Hide()
		card.buttons:Hide()
		card.cancelledRoll = rollID -- (if the game lists it as open again, Guard.adoptRolls gives it back)
		-- Its result normally follows from the loot history; if it never comes, the drop settles a little
		-- after the roll would have run out (History.settleEnded).
		if not card.finished and not card.demo then
			local gen = card.gen
			local ends = (card.rollStarted or GetTime()) + (tonumber(card.rollTime) or 0) / 1000
			C_Timer.After(math.max(5, ends - GetTime() + 10), Guard.wrapCore("settle", function()
				if card.gen == gen and not card.finished and not card.rollID then
					History.settleEnded(card)
				end
			end))
		end
		card.rollID = nil
		cardsByRollID[rollID] = nil
		if card.twins then
			card.twins.ended[rollID] = true -- out of the pool; the other copies keep theirs
			refreshTwins(card.twins)
		end
	end
	twinOfRoll[rollID] = nil
	awaitingConfirm[rollID] = nil
	confirmedRolls[rollID] = nil
	rolledIDs[rollID] = nil
	Guard.watched[rollID] = nil -- (the roll is over for you: nothing left to watch, and nothing to rebuild)
	if logging() then -- (does this also fire right after your own roll? R38 in-game check)
		local fields = { rollID = rollID, hadCard = card ~= nil, clicked = card and card.clickedState or nil,
			reported = card and card.selfReported or nil }
		log("cancel", fields)
		logPairing("cancel", fields)
	end
end

----------------------------------------------------------------------------------------------------
-- Demo mode: made-up drops play out without a group.
----------------------------------------------------------------------------------------------------

local DEMO_PLAYERS = {
	{ name = "Brakk", class = "WARRIOR" }, { name = "Elowen", class = "PRIEST" },
	{ name = "Thistle", class = "DRUID" }, { name = "Mordrin", class = "WARLOCK" },
	{ name = "You", class = "HUNTER", isSelf = true },
}
-- Two boss drops and one from trash, so boss names and "Keep trash drops" can be tried solo.
local DEMO_ITEMS = {
	{ name = "Demo Blade of Testing", icon = "Interface\\Icons\\INV_Sword_04", quality = 3, boss = "Demo Boss" },
	{ name = "Demo Chain Hauberk", icon = "Interface\\Icons\\INV_Chest_Chain_05", quality = 4, boss = "Demo Boss" },
	{ name = "Demo Grey Gloves", icon = "Interface\\Icons\\INV_Gauntlets_04", quality = 2, allPass = true },
	-- More for /rollframes demo <count>: a mix of boss and trash drops, qualities and an all-pass.
	{ name = "Demo Ring of Patience", icon = "Interface\\Icons\\INV_Jewelry_Ring_03", quality = 3, boss = "Demo Boss" },
	{ name = "Demo Leather Boots", icon = "Interface\\Icons\\INV_Boots_05", quality = 2 },
	{ name = "Demo Staff of Waiting", icon = "Interface\\Icons\\INV_Staff_08", quality = 4, boss = "Demo Boss" },
	{ name = "Demo Healing Potion", icon = "Interface\\Icons\\INV_Potion_51", quality = 1, allPass = true },
	{ name = "Demo Cloak of Drafts", icon = "Interface\\Icons\\INV_Misc_Cape_02", quality = 3, boss = "Demo Second Boss" },
	{ name = "Demo Mail Helm", icon = "Interface\\Icons\\INV_Helmet_03", quality = 3 },
	{ name = "Demo Shield of Doors", icon = "Interface\\Icons\\INV_Shield_06", quality = 4, boss = "Demo Second Boss" },
}

local function shuffled(list)
	local copy = {}
	for i, v in ipairs(list) do
		copy[i] = v
	end
	for i = #copy, 2, -1 do
		local j = math.random(i)
		copy[i], copy[j] = copy[j], copy[i]
	end
	return copy
end

-- One made-up drop, played out through the same code as real loot (applyRolls): everyone listed as
-- deciding at first, choices arriving one by one, then roll numbers and the winner.
-- opts (twins demo): ownRoll, the made-up roll this card's buttons use; simRoll, the roll whose choice
-- this drop's simulated history reports, when it isn't the card's own (two copies paired the wrong way
-- round, as can happen in a raid). Returns the card.
local function runDemoItem(item, opts)
	local card = createCard(nil, { demo = true, reserve = #DEMO_PLAYERS })
	card.demoRoll = opts and opts.ownRoll or {} -- the made-up roll the buttons use (a click sets .choice)
	local mine = opts and opts.simRoll or card.demoRoll
	local gen = card.gen -- the demo's timers stop if the card is cleared and reused meanwhile
	demoCardCount = demoCardCount + 1
	card.isTrash, card.bossName = not item.boss, item.boss or false
	setItem(card, nil, item.name, item.icon, item.quality)
	card.duration = 12
	card.endsAt = GetTime() + card.duration
	card.timer:Show()
	card.demoWaitsForYou = true
	refreshButtons(card)
	if DEV then
		Guard.watch(card) -- (dev builds watch the demo too, so /rollframes fail watchdog can be tried solo)
	end

	local players = shuffled(DEMO_PLAYERS)
	local rolls = {} -- the demo's own "loot history" list for this drop
	for i, p in ipairs(players) do
		rolls[i] = { playerName = p.name, playerGUID = "Demo-" .. p.name, playerClass = p.class,
			isSelf = p.isSelf or false, state = STATE.NOROLL }
	end
	applyRolls(card, rolls)

	local function revealAndPickWinner()
		local delay = 0
		for _, r in ipairs(rolls) do
			if r.state ~= STATE.PASS and r.state ~= STATE.NOROLL then
				delay = delay + 0.35
				C_Timer.After(delay, Guard.wrap("demo", function()
					if card.gen ~= gen then
						return
					end
					r.roll = math.random(1, 100)
					applyRolls(card, rolls)
				end))
			end
		end
		C_Timer.After(delay + 0.6, Guard.wrap("demo", function()
			if card.gen ~= gen then
				return
			end
			local best, bestRank
			for _, r in ipairs(rolls) do
				if r.state ~= STATE.PASS and r.state ~= STATE.NOROLL then
					local rank = (r.state == STATE.NEED or r.state == STATE.NEED_OFF) and 2 or 1
					if not best or rank > bestRank or (rank == bestRank and r.roll > best.roll) then
						best, bestRank = r, rank
					end
				end
			end
			if best then
				setWinner(card, best.playerGUID,
					{ name = best.playerName, class = best.playerClass, roll = best.roll, state = best.state })
			else
				setAllPassed(card)
			end
		end))
	end

	local delay = 0.4
	local remaining = #rolls
	-- With "Roll from this window" on, "You" waits for your click like a real roll (checked a few times a
	-- second), and passes if the timer runs out, as the game does.
	local waitsForYou = db.rollFromWindow
	for _, r in ipairs(rolls) do
		delay = delay + 0.5 + math.random() * 0.8
		local function takeTurn()
			if card.gen ~= gen then
				return
			end
			if r.isSelf and (waitsForYou or db.rollFromWindow) and not mine.choice and GetTime() < card.endsAt then
				C_Timer.After(0.25, Guard.wrap("demo", takeTurn))
				return
			end
			local state
			if r.isSelf and mine.choice then -- your click, on any item
				state = CLICK_STATE[mine.choice]
			elseif item.allPass then
				state = STATE.PASS
			elseif r.isSelf and (waitsForYou or db.rollFromWindow) then
				state = STATE.PASS -- the timer ran out
			else
				local x = math.random()
				state = x < 0.4 and STATE.NEED or (x < 0.8 and STATE.GREED or STATE.PASS)
			end
			if r.isSelf and not card.twins then
				card.youRolled = true
				card.buttons:Hide()
			end
			r.state = state
			applyRolls(card, rolls)
			refreshButtons(card)
			remaining = remaining - 1
			if remaining == 0 then
				card.timer:Hide()
				revealAndPickWinner()
			end
		end
		C_Timer.After(r.isSelf and waitsForYou and 0.4 or delay, Guard.wrap("demo", takeTurn))
	end
	return card
end

-- No demo in a group: real loot can arrive at any moment there, and demo drops would sit where real
-- ones appear. (Group loot rolls only exist in a group, so solo the demo can't meet real loot.) Dev
-- builds still allow it, for testing.
local function demoBlocked()
	if IsInGroup() and not DEV then
		say("the demo only runs outside a group (real loot can arrive any moment).")
		return true
	end
	return false
end

-- count: how many made-up drops (default 3, up to 20); more than the list repeats it. With more than three
-- they come every 2 seconds, so the list fills up and scrolls.
-- The empty window's "Try the demo" button: only solo (in a group the demo is blocked: real loot may come).
function History.canDemo()
	return DEV or not IsInGroup()
end

local function runDemo(count)
	if demoBlocked() then
		return
	end
	count = math.max(1, math.min(count or 3, 20))
	local gap = count > 3 and 2 or 3.5
	clearDemoCards() -- (also ends a demo still playing)
	local run = demoRun
	showWindow()
	-- Something to see in History (only when you have no real history yet; demo records leave with the demo),
	-- and 5 seconds before the first drop, to open History and watch new loot bring you back.
	if #History.records == 0 then
		for i = 4, 1, -1 do
			local item = DEMO_ITEMS[#DEMO_ITEMS - i + 1]
			local p = DEMO_PLAYERS[(i % 4) + 1]
			History.seq = History.seq + 1
			table.insert(History.demo, 1, { seq = History.seq, demo = true, name = item.name, icon = item.icon,
				quality = item.quality, boss = item.boss, at = date("%H:%M"),
				winner = "|cffffd100" .. (30 + i * 13) .. "|r  " .. classColored(p.name, p.class),
				atlas = STATE_ATLAS[i % 2 == 0 and STATE.NEED or STATE.GREED] })
		end
	end
	if History.shown then
		layout()
	end
	local lead = 2 -- (a short pause, so the window is seen opening first; user, 2026-11-10: was 5)
	History.demoActive = true -- (the X stops the demo while it's on; see History.askClear)
	History.demoLeadUntil = GetTime() + lead
	layout() -- (the empty text says the demo is starting)
	for i = 1, count do
		local item = DEMO_ITEMS[(i - 1) % #DEMO_ITEMS + 1]
		C_Timer.After(lead + (i - 1) * gap, function()
			if run == demoRun then
				Guard.call("demo", runDemoItem, item)
			end
		end)
	end
	-- No timer to clear them: like real drops they stay as history rows, and they go when the window
	-- closes (or fades out), when real loot arrives, or when another demo starts.
	local last = lead + (count - 1) * gap
	say(string.format("demo: %d made-up drop%s over about %d seconds. They go when the window closes.",
		count, count == 1 and "" or "s", math.floor(last + 20)))
end

-- The empty window's "Try the demo" button: three made-up drops (same as /rollframes demo).
function History.startDemo()
	if Guard.off.demo then
		say("the demo is off until you /reload (it hit a problem).")
		return
	end
	Guard.call("demo", runDemo, 3)
end

-- What each extra does when it switches itself off after an error (Guard.trip; History's is with History).
-- Each puts things back the way they are without that extra, so nothing is left half-drawn.
Guard.stops.highlight = function()
	for card in pairs(Highlight.cards) do
		local hl = card.hl
		if hl then
			pcall(hl.Hide, hl)
			if hl.bar then
				pcall(hl.bar.Hide, hl.bar)
			end
		end
	end
	wipe(Highlight.cards)
	Highlight.count = 0
	if Highlight.driver then
		Highlight.driver:Hide()
	end
end
Guard.stops.flash = function()
	tweens["main:flash"] = nil
	if History.flash then
		History.flash:Hide()
	end
end
Guard.stops.markers = function()
	main.markerUp:Hide()
	main.markerDown:Hide()
	if markerWatch then
		markerWatch:Hide()
	end
end
-- The button guard: no drop's buttons may stay dimmed and ignoring clicks.
Guard.stops.guard = function()
	for _, card in ipairs(cards) do
		if card.guarded then
			card.guarded = nil
			pcall(card.buttons.SetAlpha, card.buttons, 1)
		end
	end
	if History.guardWatch then
		History.guardWatch:Hide()
	end
end
Guard.stops.demo = function()
	pcall(History.stopDemo)
	pcall(clearDemoCards)
end
-- The first-use question: put away without counting as an answer (it's asked again after a /reload).
Guard.stops.ask = function()
	askPutAway = false
	if askShown then
		hideAsk()
	end
end
Guard.stops.autohide = function()
	main.countdown:Hide() -- (the window stays until closed, like a pinned one)
end
Guard.stops.chrome = function()
	main.chromeWatch:Hide()
	tweens["main:chrome"] = nil
	for _, region in pairs({ main.NineSlice, main.Bg }) do
		region:SetAlpha(1)
	end
end
Guard.stops.timer = function()
	for _, card in ipairs(cards) do
		pcall(card.timer.Hide, card.timer)
	end
end
Guard.stops.resize = function()
	grip:SetScript("OnUpdate", nil)
end

----------------------------------------------------------------------------------------------------
-- Auto-hide
----------------------------------------------------------------------------------------------------

-- Whether the window may fade now: shown, not pinned, auto-hide on, not already fading, every drop decided.
fadeEligible = function()
	if not main or not main:IsShown() or pinned or db.autoHide <= 0 or tweens["main:fade"] or askShown
		or Guard.off.autohide then
		return false
	end
	for _, card in ipairs(cards) do
		if not card.collapsed then
			return false
		end
	end
	return true
end

startFade = function()
	tween("main:fade", 0.5, function(p)
		if main:IsMouseOver() then -- the cursor came back: stop fading, start the idle time again
			tweens["main:fade"] = nil
			main:SetAlpha(1)
			lastActivity = GetTime()
			return
		end
		main:SetAlpha(1 - p)
	end, function()
		Ask.selfHide = true -- (a fade, not the player closing it)
		main:Hide()
		Ask.selfHide = nil
		main:SetAlpha(1)
		clearDemoCards() -- (OnHide does this too, but not when the whole UI was hidden as the fade ended)
		Guard.call("history", History.fadeAllDecided)
	end)
	lastActivity = GetTime() -- don't start the fade twice
end

setPinned = function(value)
	pinned = value and true or false
	refreshPin()
	if pinned and main then
		main.countdown:Hide()
	end
end

-- The pin shows only when auto-hide is on (with "Never" there's nothing to pin against).
refreshPin = function()
	if not (main and main.pin) then
		return
	end
	main.pin:SetShown(db.autoHide > 0)
	if main.hist then
		main.hist:ClearAllPoints()
		main.hist:SetPoint("RIGHT", db.autoHide > 0 and main.pin or main.closeButton or main.pin, "LEFT", -18, 0)
	end
	local transient = not pinned and db.autoHide > 0 -- this window may fade by itself
	main.chromeWatch:SetShown(transient)
	main.setChrome(transient and not (main:IsShown() and main:IsMouseOver()) and CHROME_IDLE_ALPHA or 1)
	-- Same shape both ways; the colour carries the state: gold = stays open, grey = fades when idle.
	main.pin.icon:SetDesaturated(true)
	if pinned then
		main.pin.icon:SetVertexColor(1, 0.82, 0.2)
		main.pin.icon:SetAlpha(1)
	else
		main.pin.icon:SetVertexColor(0.75, 0.75, 0.75)
		main.pin.icon:SetAlpha(0.55)
	end
end

----------------------------------------------------------------------------------------------------
-- History: drops decided this session. A decided drop stays in the list as a compact row for
-- "Finished drops stay" (db.historyFade), then fades out of the list; History (the title-bar button)
-- lists them all, newest first. The X clears both. Each record is a few strings (no frames): the
-- view reuses one row frame per visible line, so memory stays flat however long the night is.
----------------------------------------------------------------------------------------------------

-- A drop just collapsed into a history row: keep what the row shows. Real records are saved per character
-- (RollFramesHistory) and matched by the drop's mark, so the same drop seen again after a reload isn't added
-- twice. History.cardOf remembers each record's card (not saved: cards are frames), so while that card is
-- still in the list as a row, History doesn't show the drop twice.
function History.record(card)
	local mark = not card.demo and card.dropMark or nil
	-- A drop's identity: its loot-history key plus its mark (two identical items dropped together share the
	-- mark but not the key).
	local id = mark and ((card.historyKey or "?") .. "|" .. mark)
	local seen = id and History.byMark[id]
	if seen then
		History.cardOf[seen] = { card = card, gen = card.gen }
		return
	end
	History.seq = History.seq + 1
	local rec = {
		seq = History.seq, link = card.link, name = card.itemName, quality = card.quality, demo = card.demo,
		icon = card.icon.tex:GetTexture(), ilvl = card.ilvl:GetText(), winner = card.winnerText:GetText(),
		atlas = card.allPassed and STATE_ATLAS[STATE.PASS]
			or (card.winner and (STATE_ATLAS[card.winner.state] or STATE_ATLAS[STATE.GREED])) or nil,
		boss = card.bossName or nil, when = time and time() or nil, at = date("%H:%M"),
		key = card.historyKey, mark = mark,
	}
	local list = card.demo and History.demo or History.records
	table.insert(list, 1, rec)
	if id then
		History.byMark[id] = rec
	end
	History.cardOf[rec] = { card = card, gen = card.gen }
	History.trimRecords()
end

-- Window heights in whole-row steps (user, 2026-11-10): whole compact rows, plus room for the "more to roll"
-- bar below the last one (when nothing is waiting there, the next row's name peeks out instead). 38 per row
-- (a 34 px row and its 4 px gap) plus 56 (title bar 28, bottom padding 10, the bar 18): 2 rows 132, 7 rows
-- 322, 8 rows 360. Nearest step; down: the step at or below h, for a limit that mustn't be passed.
function History.snapHeight(h, down)
	local step, base = HEADER_H + CARD_GAP, TITLE_H + BOTTOM_PAD + MARKER_H
	local n = (h - base) / step
	n = down and math.floor(n + 1e-6) or math.floor(n + 0.5)
	return math.max(2, n) * step + base
end

-- A Summary drop's thin timer back to the normal one (resetCard; a switch away from Summary mid-roll).
function History.wideTimer(card)
	if card.timerThin then
		card.timerThin = nil
		card.timer:ClearAllPoints()
		card.timer:SetPoint("BOTTOMLEFT", card.icon, "BOTTOMRIGHT", 6, 1)
		card.timer:SetPoint("RIGHT", card.frame, "RIGHT", -6, 0)
		card.timer:SetHeight(4)
	end
	card.summaryPlaced = nil
end

-- Line 2 of a compact row or a History row: the winner (roll first) on the left, the boss name on the right.
-- The boss name gives way first (down to 50 px), so the roll and as much of the name as fits always show.
-- taken: room already used on the right (a History row's time).
function History.fitBoss(boss, winner, taken)
	if (boss:GetText() or "") == "" then
		boss:SetWidth(1) -- (no boss name: the winner gets the room; 1, as 0 would mean unbounded)
		return
	end
	local line = (content and content:GetWidth() or 0)
	if line <= 0 then
		line = WIDTH - 2 * SIDE_PAD
	end
	line = line - (3 + ICON + 24) - 6 - taken -- (from the winner's left edge to the row's right padding)
	local bossW = boss.GetUnboundedStringWidth and boss:GetUnboundedStringWidth() or 110
	local winnerW = winner.GetUnboundedStringWidth and winner:GetUnboundedStringWidth() or 0
	boss:SetWidth(math.max(50, math.min(bossW + 2, line - winnerW - 6)))
end

-- Item and roll tooltips open beside the window, on the side with more screen room and level with the row
-- the mouse is on, instead of at the mouse over the list (user, 2026-11-10). row: the drop or History row
-- to line up with. If the positions can't be read, it opens beside the row as before.
function History.tooltipBeside(owner, row)
	GameTooltip:SetOwner(owner, "ANCHOR_NONE")
	local placed = pcall(function()
		local ms = main:GetEffectiveScale()
		local screen = UIParent:GetRight() * UIParent:GetEffectiveScale()
		local roomLeft, roomRight = main:GetLeft() * ms, screen - main:GetRight() * ms
		-- (offsets are in the tooltip's own scale: someone may have scaled it)
		local dy = (row:GetTop() * row:GetEffectiveScale() - main:GetTop() * ms) / GameTooltip:GetEffectiveScale()
		GameTooltip:ClearAllPoints()
		if roomRight >= roomLeft then
			GameTooltip:SetPoint("TOPLEFT", main, "TOPRIGHT", 2, dy)
		else
			GameTooltip:SetPoint("TOPRIGHT", main, "TOPLEFT", -2, dy)
		end
	end)
	if not placed then
		GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	end
end

-- When a record was decided, for its row: the time today, or the date and time for an older one.
function History.when(e)
	local ok, text = pcall(function()
		if e.when and date("%Y%m%d", e.when) ~= date("%Y%m%d") then
			return date("%b %d %H:%M", e.when)
		end
		return e.at or (e.when and date("%H:%M", e.when))
	end)
	return ok and type(text) == "string" and text or e.at or ""
end

-- At login: this character's saved History, and the drops cleared before (so they don't come back from
-- Blizzard's loot history after a reload). The saved file is treated as untrusted: a game that crashed while
-- writing it may leave it unreadable (the game then gives us nothing) or odd. Every record is checked field
-- by field; anything malformed is dropped, the rest kept; if anything at all goes wrong, History starts
-- empty. History is a convenience: it must never break the window.
-- (On History, not top-level locals: the main chunk is at Lua's 200-local limit.)
History.RECORD_FIELDS = { link = "string", name = "string", quality = "number", icon = "number|string",
	ilvl = "string", winner = "string", atlas = "string", boss = "string", when = "number", at = "string",
	key = "string", mark = "string" }

function History.cleanRecord(rec)
	if type(rec) ~= "table" then
		return nil
	end
	local clean = {}
	for field, kinds in pairs(History.RECORD_FIELDS) do
		local v = rec[field]
		if v ~= nil and kinds:find(type(v), 1, true) then
			clean[field] = v
		end
	end
	if clean.when and not (clean.when > 1e9 and clean.when < 4e9) then
		clean.when = nil -- (not a plausible date: show no date rather than fail)
	end
	if clean.link and not clean.link:find("|Hitem:", 1, true) then
		clean.link = nil -- (not an item link: no tooltip from it)
	end
	if not (clean.name or clean.link) then
		return nil -- nothing to show
	end
	if clean.winner then -- (the first dev builds saved "name  roll"; rows show the roll first)
		local name, roll = clean.winner:match("^(.-)  |cffffd100(%d+)|r$")
		if name then
			clean.winner = "|cffffd100" .. roll .. "|r  " .. name
		end
	end
	return clean
end

function History.load()
	-- Starting fresh, with one gentle chat line, when the saved file is lost or damaged: this character had saved
	-- History (db.historySaved) but none came back (the game couldn't read the file), the file isn't the shape
	-- we write, or more than a few records are broken. One or two bad records are just dropped.
	local fresh = false
	-- (db.historySaved is account-wide: it lists which characters have saved History, by character ID.)
	local me = UnitGUID and UnitGUID("player")
	if RollFramesHistory == nil and me and type(db.historySaved) == "table" and db.historySaved[me] then
		fresh = true
	end
	local ok = pcall(function()
		if RollFramesHistory ~= nil and type(RollFramesHistory) ~= "table" then
			fresh = true
		end
		local saved = type(RollFramesHistory) == "table" and RollFramesHistory or {}
		local records, bad = {}, 0
		if saved.records ~= nil and type(saved.records) ~= "table" then
			fresh = true
		elseif type(saved.records) == "table" then
			for _, rec in ipairs(saved.records) do
				local clean = History.cleanRecord(rec)
				if not clean then
					bad = bad + 1
				elseif #records < History.MAX then
					clean.seq = -(#records + 1) -- (older than anything recorded this session, in saved order)
					records[#records + 1] = clean
				end
			end
		end
		if bad > 3 or (bad > 0 and bad * 4 > bad + #records) then
			fresh = true -- more than a few broken: don't trust the rest
		end
		if fresh then
			records = {}
		end
		local all = {}
		if type(saved.gone) == "table" then
			for _, g in ipairs(saved.gone) do
				if type(g) == "string" and g:find("\t", 1, true) then
					all[#all + 1] = g
				elseif type(g) == "table" and type(g.key) == "string" and type(g.mark) == "string" then
					all[#all + 1] = g.key .. "\t" .. g.mark -- (the first dev builds saved a table each)
				end
			end
		end
		local gone = {}
		for i = math.max(1, #all - 999), #all do -- the newest 1000
			gone[#gone + 1] = all[i]
		end
		RollFramesHistory = { records = records, gone = gone }
	end)
	if not ok or fresh then
		RollFramesHistory = { records = {}, gone = {} } -- start empty rather than break anything
		say("your saved loot history couldn't be read, so History is starting fresh.")
	end
	History.records = RollFramesHistory.records
	wipe(History.byMark)
	for _, rec in ipairs(History.records) do
		if rec.mark then
			History.byMark[(rec.key or "?") .. "|" .. rec.mark] = rec
		end
	end
	for _, g in ipairs(RollFramesHistory.gone) do
		local key, mark = g:match("^(.-)\t(.*)$")
		skippedHistory[key] = mark
	end
	History.trimRecords()
end

-- Drops that left History (trimmed or cleared): remembered (saved as "key<tab>mark", newest last, up to 1000) so the replay of
-- Blizzard's loot history after a reload doesn't bring them back.
function History.forget(key, mark)
	if not (key and mark) then
		return
	end
	skippedHistory[key] = mark
	local gone = RollFramesHistory and RollFramesHistory.gone
	if gone then
		gone[#gone + 1] = key .. "\t" .. mark -- (one string each: up to 1100 of them)
		if #gone > 1100 then -- trim in a batch, oldest first
			local keep = {}
			for i = #gone - 999, #gone do keep[#keep + 1] = gone[i] end
			RollFramesHistory.gone = keep
		end
	end
end

-- At logout: what gets written (records only hold strings and numbers; cards aren't saved).
function History.save()
	RollFramesHistory = RollFramesHistory or {}
	RollFramesHistory.records = History.records
	-- Lets the next login tell a lost file from a character with no History.
	local me = UnitGUID and UnitGUID("player")
	if me then
		local list = type(db.historySaved) == "table" and db.historySaved or {}
		list[me] = #History.records > 0 or nil
		db.historySaved = next(list) and list or nil
	end
end

-- History keeps (setting): the oldest records go once there are more (all: up to History.MAX).
function History.trimRecords()
	local limit = (db.historyKeep or 0) > 0 and math.min(db.historyKeep, History.MAX) or History.MAX
	for _, list in ipairs({ History.records, History.demo }) do
		for i = #list, limit + 1, -1 do
			local rec = list[i]
			if rec.mark then
				History.byMark[(rec.key or "?") .. "|" .. rec.mark] = nil
				History.forget(rec.key, rec.mark) -- (so Blizzard's replay after a reload doesn't bring it back)
			end
			list[i] = nil
		end
	end
end

-- Fills History.merged with the drops History shows (yours and the demo's, newest first), leaving out
-- those whose card is still in the list. Returns how many.
function History.list()
	local list = History.merged
	wipe(list)
	local a, b = History.records, History.demo
	local i, j = 1, 1
	while a[i] or b[j] do -- both are newest first: merge by record order
		local e
		if b[j] and (not a[i] or b[j].seq > a[i].seq) then
			e, j = b[j], j + 1
		else
			e, i = a[i], i + 1
		end
		local c = History.cardOf[e]
		if not (c and c.card.gen == c.gen) then -- (a fading card still holds its place until it's released)
			list[#list + 1] = e
		end
	end
	return #list
end

-- The clock: shows or hides the older drops in the list (they continue it on its older side). In a free
-- window that's above the drops, so the scroll moves by the same amount and the drops stay where they are.
function History.toggle(on)
	if on == History.shown or not main then
		return
	end
	local n = History.list()
	History.touch = GetTime()
	lastActivity = GetTime()
	-- (A compact row is one ROW_H step too, so a card trimmed in that layout and its row appearing cancel out;
	-- a Summary row is taller, so there a trim at that moment can shift the list a little.)
	if newestAtBottom() and n > 0 then
		History.scrollAdd = (on and 1 or -1) * n * History.ROW_H
	end
	History.shown = on
	main.hist.lit:SetShown(on)
	main.clear:SetShown(on) -- the X only shows with History
	if not on then
		History.hideRows()
	end
	History.rowAlpha = on and 0 or 1
	layout()
	if on then
		tween("history:rows", 0.3, function(p)
			History.rowAlpha = p
			for _, row in ipairs(History.rows) do row.alpha = p; row:SetAlpha(p) end
		end)
	end
end

function History.hideRows()
	for _, row in ipairs(History.rows) do
		row.entry, row.y = nil, nil
		row:Hide()
	end
end

-- The older drops age out again after "Finished drops stay" without you touching the window (a fade).
function History.ageOut()
	tween("history:rows", 0.35, function(p)
		History.rowAlpha = 1 - p
		for _, row in ipairs(History.rows) do row.alpha = 1 - p; row:SetAlpha(1 - p) end
	end, function()
		if main:IsMouseOver() then -- the mouse came in during the fade: keep them (nothing moves under it)
			History.touch = GetTime()
			History.rowAlpha = 1
			for _, row in ipairs(History.rows) do row.alpha = 1; row:SetAlpha(1) end
			return
		end
		History.toggle(false)
	end)
end

-- The X: asks first (always, since the "Ask before clearing" setting went on 2026-11-10), then clears.
function History.askClear()
	if History.demoActive then
		History.stopDemo() -- during a demo the X only ends the demo; your real history is never touched
		return
	end
	if not (StaticPopupDialogs and StaticPopup_Show) then
		History.clear()
		return
	end
	if not StaticPopupDialogs.ROLLFRAMES_CLEAR_HISTORY then
		StaticPopupDialogs.ROLLFRAMES_CLEAR_HISTORY = {
			text = "Clear the loot history?\n\nEvery decided drop leaves the list and History. Rolls in progress stay.",
			button1 = "Clear", button2 = CANCEL or "Cancel",
			OnAccept = function() History.clear() end,
			timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
		}
	end
	StaticPopup_Show("ROLLFRAMES_CLEAR_HISTORY")
end

-- /rollframes reset all (user, 2026-11-10): back to a fresh install, after a confirmation: every setting, the
-- window's position and size, the first-use question (asked again), this character's loot History and the
-- troubleshooting log; then the interface reloads, so everything starts fresh. Other characters' History is
-- saved separately and stays.
function History.askResetAll()
	if not (StaticPopupDialogs and StaticPopup_Show) then
		say("can't ask to confirm here, so nothing was reset.")
		return
	end
	if not StaticPopupDialogs.ROLLFRAMES_RESET_ALL then
		StaticPopupDialogs.ROLLFRAMES_RESET_ALL = {
			text = "Reset RollFrames completely?\n\nEvery setting (for all your characters) goes back to its default, "
				.. "the window to its starting spot, and this character's loot History is cleared. The interface reloads.",
			button1 = "Reset everything", button2 = CANCEL or "Cancel",
			OnAccept = function() History.resetAll() end,
			timeout = 0, whileDead = true, hideOnEscape = true, showAlert = true, preferredIndex = 3,
		}
	end
	StaticPopup_Show("ROLLFRAMES_RESET_ALL")
end

function History.resetAll()
	if History.demoActive then
		pcall(History.stopDemo)
	end
	pcall(History.clear) -- (remembered as cleared, so Blizzard's replay after the reload doesn't bring it back)
	local others = type(db.historySaved) == "table" and db.historySaved or nil
	for key in pairs(db) do
		db[key] = nil -- (the reload's logout then writes the empty file)
	end
	db.settingsVersion = Saved.LATEST -- (not a v1.1 file: no conversion, no update note, after the reload)
	if others then -- (other characters still have their History: keep their entries, so a lost file is noticed)
		local me = UnitGUID and UnitGUID("player")
		if me then
			others[me] = nil
		end
		db.historySaved = next(others) and others or nil
	end
	ReloadUI()
end

-- Every decided drop leaves the list and History. Rolls in progress (and drops still showing their
-- winner, about to collapse) stay.
function History.clear()
	if History.shown then
		History.toggle(false) -- (first, while the records still say how far a free window's list shifts)
	end
	-- Remembered (saved), so a reload doesn't bring them back from Blizzard's loot history.
	for _, rec in ipairs(History.records) do
		History.forget(rec.key, rec.mark)
	end
	for _, card in ipairs(cards) do
		if card.collapsed and not card.demo then
			History.forget(card.historyKey, card.dropMark)
		end
	end
	wipe(History.records)
	wipe(History.byMark)
	wipe(History.demo)
	local done = {}
	for _, card in ipairs(cards) do
		if card.collapsed then
			done[#done + 1] = card
		end
	end
	for _, card in ipairs(done) do -- (dismissing changes the list, so not while walking it)
		dismissCard(card, "cleared")
	end
	lastActivity = GetTime()
end

-- Once a second while the window shows: decided drops older than "Finished drops stay" fade out of the
-- list (they stay in History), and older drops brought back with the clock age out again after that long
-- without you touching the window. Never while the mouse is over the window, so nothing moves under it.
function History.fadeOld()
	local keep = db.historyFade or 0
	if main:IsMouseOver() then
		History.touch = GetTime()
		return
	end
	if keep <= 0 then
		return
	end
	local now, old = GetTime(), nil
	if keep > 0 and History.shown and History.touch and now - History.touch >= keep and not tweens["history:rows"] then
		History.ageOut()
	end
	for _, card in ipairs(cards) do
		if card.collapsed and not card.dismissing and card.collapsedAt and now - card.collapsedAt >= keep then
			old = old or {}
			old[#old + 1] = card
		end
	end
	if old then
		for _, card in ipairs(old) do
			dismissCard(card, "faded")
		end
	end
end

-- The window faded out by itself: every decided drop goes to History now, instead of waiting out "Finished
-- drops stay", so the next roll opens on a clean list (user, 2026-11-10). "Until cleared" keeps them, and
-- closing the window by hand changes nothing.
function History.fadeAllDecided()
	if (db.historyFade or 0) <= 0 then
		return
	end
	local done = {}
	for _, card in ipairs(cards) do
		if card.finished and not card.dismissing and not card.demo then
			done[#done + 1] = card
		end
	end
	for _, card in ipairs(done) do
		if not card.collapsed then
			collapse(card) -- (records it in History; a drop not kept there leaves on its own)
		end
		if card.collapsed and not card.dismissing then
			dismissCard(card, "faded")
		end
	end
end

-- Button guard (user, 2026-11-10): when the list moves (new loot) and a drop's roll buttons end up under a
-- cursor that didn't move, they're dimmed and ignore clicks until the mouse moves a button's width (22 px)
-- or the setting's time passes (db.guardTime; 0: the mouse must move), so someone resting the mouse there
-- isn't left wondering,
-- so a click meant for another drop can't land on them. The drop under the mouse that held still isn't
-- guarded (it didn't move). Runs one frame after a layout that moved drops, and only while guarding.
-- Ends every guard at once (the setting turned off).
function History.clearGuards()
	for _, card in ipairs(cards) do
		if card.guarded then
			card.guarded = nil
			card.buttons:SetAlpha(1)
			History.refreshButtonTip(card)
		end
	end
	if History.guardWatch then
		History.guardWatch:Hide()
	end
end

-- A roll button's tooltip says whether the guard is on, so it's drawn again when the guard starts or ends
-- (the mouse didn't move, so the button wouldn't redraw it by itself).
function History.refreshButtonTip(card)
	for _, button in ipairs(card.buttons.list) do
		if GameTooltip:IsOwned(button) then
			button:GetScript("OnEnter")(button)
			return
		end
	end
end

function History.checkGuard()
	if not db.buttonGuard then
		return
	end
	local now = GetTime()
	for _, card in ipairs(cards) do
		if card.movedAt and now - card.movedAt < 0.5 and card.buttons:IsShown() and card.buttons:IsMouseOver() then
			local x, y = GetCursorPosition()
			if card.guarded then
				-- Moved again while guarded (a third drop): the half second starts over, from where the mouse is.
				card.guarded.x, card.guarded.y, card.guarded.at = x, y, now
			else
				card.guarded = { x = x, y = y, at = now }
				card.buttons:SetAlpha(0.35)
				History.guards = (History.guards or 0) + 1
				History.refreshButtonTip(card)
			end
			if not History.guardWatch then
				History.guardWatch = CreateFrame("Frame", nil, main)
				History.guardWatch:SetScript("OnUpdate", Guard.wrapUpdate("guard", History.watchGuards))
			end
			History.guardWatch:Show()
		end
	end
end

function History.watchGuards(watch)
	local x, y = GetCursorPosition()
	local scale = main:GetEffectiveScale()
	local any = false
	for _, card in ipairs(cards) do
		local g = card.guarded
		if g then
			local moved = math.sqrt((x - g.x) ^ 2 + (y - g.y) ^ 2) / scale
			local limit = tonumber(db.guardTime) or 2
			if moved >= 22 or (limit > 0 and GetTime() - g.at >= limit) or not card.buttons:IsShown() then
				card.guarded = nil
				card.buttons:SetAlpha(1)
				History.refreshButtonTip(card)
			else
				any = true
			end
		end
	end
	if not any then
		watch:Hide()
	end
end

-- One History row frame (kept and reused: only the rows in view have one).
function History.row(i)
	local row = History.rows[i]
	if row then
		return row
	end
	local ROW_H = History.ROW_H
	row = CreateFrame("Button", nil, content)
	row.isHistoryRow = true -- (tests tell these from drops by this)
	row:SetHeight(ROW_H - CARD_GAP)
	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	row.bg:SetColorTexture(1, 1, 1, 0.035)
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(ICON, ICON)
	row.icon:SetPoint("TOPLEFT", row, "TOPLEFT", 3, -3)
	row.icon:SetDesaturated(true) -- (older drops: a little quieter than the ones in the list)
	row.ilvl = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.ilvl:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -5) -- (as on a plain drop)
	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, -2)
	row.name:SetPoint("RIGHT", row.ilvl, "LEFT", -4, 0)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)
	row.when = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.when:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -6, 7) -- (the row grid: as on the drops)
	row.boss = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.boss:SetPoint("RIGHT", row.when, "LEFT", -4, 0) -- (its own text: a shortened boss name never cuts the time)
	row.boss:SetJustifyH("RIGHT")
	row.boss:SetWordWrap(false)
	row.winner = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.winner:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 24, 4)
	row.winner:SetPoint("RIGHT", row.boss, "LEFT", -6, 0)
	row.winnerIcon = row:CreateTexture(nil, "OVERLAY")
	row.winnerIcon:SetSize(14, 14)
	row.winnerIcon:SetPoint("RIGHT", row.winner, "LEFT", -4, 0)
	row.winner:SetJustifyH("LEFT")
	row.winner:SetWordWrap(false)
	row:SetScript("OnEnter", function(self)
		local e = self.entry
		if not e then return end
		History.tooltipBeside(self, self)
		if e.demo or not e.link then
			GameTooltip:SetText(e.name or "Item")
			if e.demo then GameTooltip:AddLine("Demo mode: a made-up item.", 0.8, 0.8, 0.8) end
		else
			GameTooltip:SetHyperlink(e.link)
		end
		GameTooltip:AddLine("Decided " .. History.when(e) .. (e.boss and (" · " .. e.boss) or ""), 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", GameTooltip_Hide)
	row:SetScript("OnClick", function(self)
		local e = self.entry
		if e and e.link and not e.demo and IsModifiedClick() then
			HandleModifiedItemClick(e.link) -- shift-click links it in chat, as on the list
		end
	end)
	History.rows[i] = row
	return row
end

-- History.place, but an error there switches History off for the session instead of breaking the window
-- (and the event that drew it). History is a convenience; the rolls matter.
function History.safePlace()
	if History.shown then
		Guard.call("history", History.place)
	end
end

-- How many older drops History shows (0 while it's closed, or off after an error).
function History.count()
	if not History.shown or Guard.off.history then
		return 0
	end
	local ok, n = pcall(History.list)
	if ok then
		return n
	end
	Guard.trip("history", n)
	return 0
end

-- History switched off after an error: its rows and buttons go (back after a /reload), and the list
-- closes the space the rows had.
Guard.stops.history = function()
	History.shown = false
	pcall(History.hideRows)
	if main and main.hist then
		main.hist.lit:Hide()
		main.hist:Hide()
	end
	if main and main.clear then
		main.clear:Hide()
	end
	relayoutPending = true
	driver:Show()
end

-- Gives a frame to each History row in view (plus a few beyond each edge) and places it; called after
-- layout and on every scroll. History.merged and History.top come from the last layout.
function History.place()
	if not History.shown then
		return
	end
	local list, ROW_H = History.merged, History.ROW_H
	local n = #list
	local top = scroll:GetVerticalScroll()
	local view = main:GetHeight() - TITLE_H - BOTTOM_PAD
	local first = math.max(1, math.floor((top - History.top) / ROW_H) + 1 - 2)
	local last = math.min(n, math.floor((top + view - History.top) / ROW_H) + 1 + 2)
	-- Each position keeps its frame while it stays in view (slot = position modulo the pool), so a scroll
	-- only fills the rows that came into view, and a row is anchored again only when it moved.
	History.poolN = math.max(History.poolN or 0, last - first + 1)
	local slots = History.poolN
	History.pass = (History.pass or 0) + 1
	local pass, alpha = History.pass, History.rowAlpha or 1
	local fromBottom = newestAtBottom() -- free window: the oldest at the top, the newest next to the drops
	for k = first, last do
		local e = list[fromBottom and (n - k + 1) or k]
		local row = History.row((k - 1) % slots + 1)
		row.pass = pass
		if row.entry ~= e then
			row.entry = e
			row.icon:SetTexture(e.icon or 134400)
			row.name:SetText(e.name or "Item")
			row.name:SetTextColor(qualityColor(e.quality))
			row.ilvl:SetText(e.ilvl or "")
			row.winner:SetText(e.winner or "")
			if e.atlas then
				row.winnerIcon:SetAtlas(e.atlas)
				row.winnerIcon:Show()
			else
				row.winnerIcon:Hide()
			end
			row.when:SetText("|cff8c8c8c" .. History.when(e) .. "|r")
			row.boss:SetText(e.boss or "")
			local whenW = row.when.GetUnboundedStringWidth and row.when:GetUnboundedStringWidth() or 30
			History.fitBoss(row.boss, row.winner, whenW + 4)
		end
		local y = History.top + (k - 1) * ROW_H
		if row.y ~= y then
			row.y = y
			row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y) -- (only these two points are ever set)
			row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -y)
		end
		if row.alpha ~= alpha then
			row.alpha = alpha
			row:SetAlpha(alpha)
		end
		if not row:IsShown() then
			row:Show()
		end
	end
	for _, row in ipairs(History.rows) do
		if row.pass ~= pass and (row.entry or row:IsShown()) then
			row.entry, row.y = nil, nil
			row:Hide()
		end
	end
end

-- Once a second while the window shows. Each part is protected on its own, so an error in one can't stop
-- the others, or the ticker itself (a ticker stops for good when its function errors).
function Guard.tickHeld()
	if scrollToNewestPending and not (db.hoverHold == "window" and main:IsMouseOver() or heldCard()) then
		relayoutPending = true -- new drops came while the list was held: show them now it's let go
		driver:Show()
	end
end
function Guard.tickFade()
	if main:IsMouseOver() then
		lastActivity = GetTime() -- hovering keeps it open and restarts the idle time
	end
	-- Show the line a moment early (the ticker runs once a second) so it starts full and drains all the way.
	if fadeEligible() and db.autoHide - (GetTime() - lastActivity) <= COUNTDOWN + 1 and not main.countdown:IsShown() then
		main.countdown:Show()
	end
end
-- The empty window's "Try the demo" button follows joining or leaving a group (no layout runs for that).
function Guard.tickDemo()
	local offer = main.emptyShown and not main.emptyLead and History.canDemo() and true or false
	if main.demoButton:IsShown() ~= offer then
		main.demoButton:SetShown(offer)
	end
end
local hideTicker = C_Timer.NewTicker(1, function()
	if not main or not main:IsShown() then
		return
	end
	Guard.call("demo", Guard.tickDemo)
	Guard.core("ticker", Guard.tickHeld)
	Guard.call("history", History.fadeOld)
	Guard.call("autohide", Guard.tickFade)
end)

----------------------------------------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------------------------------------

local category
local settingObjects = {}
-- The last value of each setting we've seen (our own table, not Blizzard's setting objects), so a callback
-- that fires with nothing changed (the Options "Defaults" buttons) isn't taken for a choice.
local seenValues = {}

local function buildPanel()
	local layoutPanel
	category, layoutPanel = Settings.RegisterVerticalLayoutCategory("RollFrames")
	layoutPanel:AddInitializer(CreateSettingsListSectionHeaderInitializer("Window"))

	local function checkbox(key, name, tooltip, onChange)
		local s = Settings.RegisterAddOnSetting(category, "ROLLFRAMES_" .. key:upper(), key, db,
			Settings.VarType.Boolean, name, DEFAULTS[key])
		if onChange then
			s:SetValueChangedCallback(onChange)
		end
		settingObjects[key] = s
		return Settings.CreateCheckbox(category, s, tooltip)
	end
	local function dropdown(key, varType, name, choices, tooltip, onChange)
		local s = Settings.RegisterAddOnSetting(category, "ROLLFRAMES_" .. key:upper(), key, db, varType, name,
			DEFAULTS[key])
		if onChange then
			s:SetValueChangedCallback(onChange)
		end
		settingObjects[key] = s
		return Settings.CreateDropdown(category, s, function()
			local c = Settings.CreateControlTextContainer()
			for _, choice in ipairs(choices) do
				c:Add(choice[1], choice[2])
			end
			return c:GetData()
		end, tooltip)
	end

	checkbox("autoOpen", "Open when a roll starts",
		"Shows the window whenever a group loot roll starts. Off: it stays out of the way and keeps track "
			.. "quietly; open it yourself with /rollframes or the AddOns button, and everything is there. While "
			.. "it's closed, Blizzard's own roll popups show as usual.")
	seenValues.rollFromWindow = db.rollFromWindow
	local rollHereInit = checkbox("rollFromWindow", "Roll from this window",
		"Adds Need, Greed and Pass buttons to each drop and hides Blizzard's roll popups while the window "
			.. "is open. If RollFrames hits an error, or you close the window, Blizzard's popups come back.",
		function()
			-- A real change here, either way, is the answer to the first-use question: never asked after.
			-- (Blizzard's Settings also calls this when nothing changed, e.g. the Options "Defaults"
			-- buttons; those aren't a choice, so only a change from the last known value counts.)
			if db.rollFromWindow ~= seenValues.rollFromWindow then
				seenValues.rollFromWindow = db.rollFromWindow
				db.askedRollHere = true
				hideAsk(true) -- answered here (also releases a window the question opened)
			end
			applyBlizzardPopups() -- (first: turned off, the popups are back even if a drop below errors)
			for _, card in ipairs(cards) do
				Guard.core("setting", refreshButtons, card)
			end
		end)
	dropdown("playerLines", Settings.VarType.String, "Player lines",
		{ { "summary", "Summary" }, { "auto", "Auto (raids: Summary)" }, { "all", "Everyone" },
			{ "none", "None (item only)" } },
		"How much of each roll in progress the window shows.\n\n"
			.. "Summary (default): every drop is one steady row: the item, how many chose each (Need, Greed, Pass, "
			.. "as their icons) and your own choice. Hover the drop for everyone's rolls.\n\n"
			.. "Auto: Everyone in a party or solo, Summary in a raid, where a line for every raider would make each "
			.. "drop taller than the window.\n\n"
			.. "Everyone: a line per player with their choice and roll. You're on top, then rolls in the order they "
			.. "came in, then players still deciding (...), then passes.\n\n"
			.. "None: just the item, with your own choice and roll where the buttons were; hover the drop for "
			.. "everyone's rolls.\n\nA drop keeps the same height while its roll is open, so the roll buttons don't move.",
		function()
			redrawLiveCards()
		end)
	do
		-- Click guard: a checkbox with its time beside it (one row; Blizzard's own checkbox-and-dropdown control).
		local guardOn = Settings.RegisterAddOnSetting(category, "ROLLFRAMES_BUTTONGUARD", "buttonGuard", db,
			Settings.VarType.Boolean, "Click guard", DEFAULTS.buttonGuard)
		guardOn:SetValueChangedCallback(function()
			if not db.buttonGuard then
				History.clearGuards()
			end
		end)
		settingObjects.buttonGuard = guardOn
		local guardTime = Settings.RegisterAddOnSetting(category, "ROLLFRAMES_GUARDTIME", "guardTime", db,
			Settings.VarType.Number, "Click guard time", DEFAULTS.guardTime)
		settingObjects.guardTime = guardTime
		local function guardTimes()
			local c = Settings.CreateControlTextContainer()
			for _, t in ipairs({ { 0.5, "Half a second" }, { 1, "1 second" }, { 2, "2 seconds" }, { 3, "3 seconds" },
				{ 5, "5 seconds" }, { 0, "Until the mouse moves" } }) do
				c:Add(t[1], t[2])
			end
			return c:GetData()
		end
		local tip = "When new loot moves the list and a drop's roll buttons slide under a mouse that didn't move, "
			.. "they're dimmed and ignore clicks for a moment, so a click meant for one drop can't land on another. "
			.. "They work again after the time chosen here (default: 2 seconds), or as soon as you move the mouse.\n\n"
			.. "Until the mouse moves: no time limit; move the mouse a little and they work.\n\n"
			.. "Off: buttons work the moment they're under the mouse."
		local timeTip = "How long the guard lasts with the mouse still."
		if CreateSettingsCheckboxDropdownInitializer then
			layoutPanel:AddInitializer(CreateSettingsCheckboxDropdownInitializer(guardOn, "Click guard", tip,
				guardTime, guardTimes, "Click guard time", timeTip))
		else -- (two rows, the time greyed out while the guard is off)
			local cbInit = Settings.CreateCheckbox(category, guardOn, tip)
			local ddInit = Settings.CreateDropdown(category, guardTime, guardTimes, timeTip)
			ddInit:SetParentInitializer(cbInit, function() return db.buttonGuard end)
		end
	end
	dropdown("position", Settings.VarType.String, "Position",
		{ { "free", "Free (drag anywhere)" }, { "attached", "Above roll popups" } },
		"Free (default): until you drag it, the window sits on the right, beside the quest tracker, out of the way "
			.. "of your action bars; drag its title bar to put it anywhere.\n\n"
			.. "Above roll popups: its bottom edge sits just above Blizzard's roll popups (bottom middle of the "
			.. "screen). Dragging the window switches it to Free.",
		function()
			if db.position == "attached" then
				db.point = nil -- (back to Free later, or Defaults, starts from the starting spot)
			end
			applyPosition()
			layout() -- grip to the right corner
		end)
	checkbox("autoGrow", "Grow with drops",
		"Off (default): the window keeps one height, so it never changes size on its own; longer lists scroll, and "
			.. "(with \"Roll from this window\") a bar at the edge says when drops waiting for your roll are out of "
			.. "view. Drag the corner to set the height.\n\nOn: the window grows with its drops, up to the height you drag it to, then scrolls.",
		function()
			layout()
		end)
	local autoHideInit = dropdown("autoHide", Settings.VarType.Number, "Hide when idle after",
		{ { 0, "Never" }, { 10, "10 seconds" }, { 15, "15 seconds" }, { 30, "30 seconds" }, { 60, "60 seconds" } },
		"Fades the window once every drop is decided and nothing has happened for this long; a thin line drains "
			.. "under the title for the last few seconds. Hovering the window restarts the time, so it never fades under your mouse. A window you open "
			.. "yourself stays until you close it (the pin by the close button shows this; click it to switch).",
		function()
			refreshPin()
		end)
	layoutPanel:AddInitializer(CreateSettingsListSectionHeaderInitializer("History"))
	dropdown("historyMinQuality", Settings.VarType.Number, "Minimum quality kept",
		{ { 0, "All items" }, { 2, "Uncommon and better" }, { 3, "Rare and better" }, { 4, "Epic and better" } },
		"The lowest item quality kept in the history rows once a roll is decided.\n\nRolls for items of any "
			.. "quality always show as normal, so you can still see and roll on them. This setting only decides "
			.. "what stays in the list after the winner has shown: lower items fade out, and aren't kept in History "
			.. "(the clock) either. Every drop is still in "
			.. "Blizzard's loot history (/loot). Lowering it later doesn't bring back drops already left out.\n\n"
			.. "Good for raids with lots of green or blue drops.",
		function()
			local below = {}
			for _, card in ipairs(cards) do
				if card.collapsed and belowHistoryQuality(card) then
					below[#below + 1] = card
				end
			end
			for _, card in ipairs(below) do -- (dismissing can change the list, so not while walking it)
				dismissCard(card) -- stays in the history group while it fades, so nothing jumps
			end
		end)
	checkbox("keepTrash", "Keep trash drops",
		"On: drops from trash stay in the history, like boss loot.\n\nOff: they leave the list once their winner has "
			.. "shown, so the history keeps boss loot only. Rolls in progress always show, and every drop is still in "
			.. "Blizzard's loot history (/loot).\n\nBoss drops show the boss's name in the history either way.",
		function()
			local trash = {}
			for _, card in ipairs(cards) do
				if card.collapsed and card.isTrash and not db.keepTrash then
					trash[#trash + 1] = card
				end
			end
			for _, card in ipairs(trash) do -- (dismissing can change the list, so not while walking it)
				dismissCard(card, "trash drop")
			end
		end)
	dropdown("historyKeep", Settings.VarType.Number, "History keeps",
		{ { 50, "50 drops" }, { 100, "100 drops" }, { 250, "250 drops" }, { 500, "500 drops" } },
		"How many decided drops History (the clock in the title bar) keeps for this character. It's saved, so "
			.. "it's still there after a reload or logging out. Once there are more, the oldest go.\n\n"
			.. "Default: 100. The list itself keeps up to 20 decided rows; older ones are in History.", function()
			History.trimRecords()
			if History.shown then
				relayoutPending = true
				driver:Show()
			end
		end)

	dropdown("historyFade", Settings.VarType.Number, "Finished drops stay",
		{ { 30, "30 seconds" }, { 60, "1 minute" }, { 120, "2 minutes" }, { 300, "5 minutes" }, { 0, "Until cleared" } },
		"How long a decided drop stays in the list as a compact row before it fades out (default: 1 minute). "
			.. "The clock in the title bar brings the older drops back, continuing the list; they go again after "
			.. "the same time without you touching the window.\n\n"
			.. "Never while the mouse is over the window, so nothing moves under it. When the window fades out "
			.. "by itself, all decided drops go to History at once, so the next roll opens on a clean list.\n\n"
			.. "Until cleared: rows stay until the X in the title bar removes them (the list keeps up to 20; older "
			.. "ones are in History), even when the window fades out.")

	layoutPanel:AddInitializer(CreateSettingsListSectionHeaderInitializer("Accessibility"))
	local highlightInit = dropdown("highlightRolls", Settings.VarType.String, "Highlight drops to roll",
		{ { "border", "Gold border" }, { "timer", "Glowing timer bar" }, { "sparkle", "Sparkles" },
			{ "all", "All three" }, { "off", "Off" } },
		"Makes drops still waiting for your roll stand out, so you don't miss one. It shows only on drops with "
			.. "your roll buttons, and goes as soon as you roll or the roll ends.\n\n"
			.. "Gold border (default): a gold frame around the drop that slowly brightens and dims.\n\n"
			.. "Glowing timer bar: the roll's timer bar glows, with a spark at its moving edge.\n\n"
			.. "Sparkles: small stars twinkle around the drop's edge.\n\nAll three: all of them at once.\n\n"
			.. "Needs \"Roll from this window\".",
		function()
			Highlight.restyle()
		end)
	dropdown("flashing", Settings.VarType.String, "Flashing",
		{ { "normal", "Normal" }, { "persist", "Until noticed" }, { "off", "Off" } },
		"Normal (default): the highlight pulses, the \"more to roll\" bars pulse, the winner gets a short sweep "
			.. "(with Player lines: Everyone), and "
			.. "the window's edge flashes once when new loot brings it back from History.\n\n"
			.. "Until noticed: as Normal, but that flash repeats until you move the mouse over the window.\n\n"
			.. "Off: nothing flashes or pulses. The highlight is a steady border or bar (Sparkles becomes a steady "
			.. "border), the bars are steady, and the winner is simply highlighted.",
		function()
			if db.flashing == "off" then
				History.stopFlash()
			end
			Highlight.restyle()
		end)
	-- Greyed out unless you roll from the window. (Not SetParentInitializer: that also indents it under its
	-- parent, which sits in another section; AddModifyPredicate only greys it.)
	if highlightInit and highlightInit.AddModifyPredicate then
		highlightInit:AddModifyPredicate(function()
			return db.rollFromWindow
		end)
	end

	layoutPanel:AddInitializer(footerInitializer())
	Settings.RegisterAddOnCategory(category)
end

----------------------------------------------------------------------------------------------------
-- First-use question: "Roll from this window?" "Roll from this window" is off by default; at login
-- (and when you open the window yourself, while it's unanswered) a panel attached to the window asks,
-- with a sample drop you can click. Never while a roll is open, in combat, or with Blizzard's roll
-- popups up; never around loot. Answering, or changing the setting in Options, settles it; closing the
-- window without answering twice leaves it at "No thanks". Players who already roll from the window
-- are never asked.
----------------------------------------------------------------------------------------------------

Ask = { W = WIDTH, H = 206, sampleTime = 30 } -- (one table: the file is near Lua's 200-locals limit)
local ask -- the panel, made the first time it's needed

function Ask.anyRealDrop(live)
	for _, card in ipairs(cards) do
		if not card.demo and (not live or not card.collapsed) then
			return true
		end
	end
	return false
end

function Ask.setRollFromWindow(on)
	if settingObjects.rollFromWindow then
		settingObjects.rollFromWindow:SetValue(on) -- updates the Options page and runs its change callback
	else
		db.rollFromWindow = on
		applyBlizzardPopups()
		for _, card in ipairs(cards) do
			Guard.core("setting", refreshButtons, card)
		end
	end
end

-- Above the window if it fits; below it if the window is free and it fits there (attached, below is
-- where Blizzard's roll popups and the action bars are); otherwise over the top of the window's list.
-- (It only shows at calm moments, so the list holds only decided drops then.) Re-placed by layout.
function Ask.place()
	if not ask then
		return
	end
	local top, bottom, screenTop = main:GetTop(), main:GetBottom(), UIParent:GetTop()
	local where
	if not (top and bottom and screenTop) or top + Ask.H + 8 <= screenTop then
		where = "above"
	elseif db.position ~= "attached" and bottom - Ask.H - 8 >= ((bottomContainer() and bottomContainer():GetTop()) or 0) then
		where = "below" -- (only if it stays above the action bars)
	else
		where = "over"
	end
	if where == Ask.placedAt then
		return
	end
	Ask.placedAt = where
	ask:ClearAllPoints()
	if where == "above" then
		ask:SetPoint("BOTTOM", main, "TOP", 0, 4)
	elseif where == "below" then
		ask:SetPoint("TOP", main, "BOTTOM", 0, -4)
	else
		ask:SetPoint("TOP", main, "TOP", 0, -TITLE_H)
		-- above the list it covers, and above the window's border (Blizzard's template draws it high)
		local titleLevel = main.TitleContainer and main.TitleContainer:GetFrameLevel() or main:GetFrameLevel()
		ask:SetFrameLevel(math.max(main:GetFrameLevel() + 30, titleLevel + 10))
	end
end

function Ask.create()
	local f = CreateFrame("Frame", nil, main, "BackdropTemplate")
	ask = f
	f:SetSize(Ask.W, Ask.H)
	f:SetFrameStrata("HIGH")
	f:EnableMouse(true)
	-- Drag it like the window's title bar: it moves the window (and switches it to Free, as dragging the
	-- window does). Its buttons take their own clicks, so they never start a drag.
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self)
		self.dragging = true
		main:GetScript("OnDragStart")(main)
	end)
	f:SetScript("OnDragStop", function(self)
		self.dragging = false
		main:GetScript("OnDragStop")(main)
	end)
	f:SetScript("OnHide", function(self)
		if self.dragging then -- put away mid-drag (a fight or a roll): finish the drag properly
			self.dragging = false
			main:GetScript("OnDragStop")(main)
		end
	end)
	if f.SetBackdrop then
		f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
		f:SetBackdropColor(0.05, 0.05, 0.07, 0.95)
		f:SetBackdropBorderColor(1, 0.82, 0.2, 0.9)
	end
	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.title:SetPoint("TOPLEFT", 12, -12)
	f.title:SetText("Roll from this window?")
	f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.text:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -6)
	f.text:SetWidth(Ask.W - 24)
	f.text:SetJustifyH("LEFT")
	f.text:SetText("Need, Greed and Pass buttons go on each drop here, and Blizzard's roll popups stay "
		.. "hidden while this window is open: one clean place to see and roll. Try the sample:")

	-- The sample drop: an item, a timer and the roll buttons. Clicking only shows what would happen.
	local row = CreateFrame("Frame", nil, f)
	f.sample = row
	row:SetSize(Ask.W - 24, ICON + 6)
	row:SetPoint("TOPLEFT", f.text, "BOTTOMLEFT", 0, -8)
	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	row.bg:SetColorTexture(1, 1, 1, 0.05)
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(ICON, ICON)
	row.icon:SetPoint("LEFT", 3, 0)
	row.icon:SetTexture("Interface\\Icons\\INV_Sword_04")
	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, -2)
	row.name:SetText("Sample Blade")
	row.name:SetTextColor(0, 0.44, 0.87)
	row.timer = CreateFrame("StatusBar", nil, row)
	row.timer:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	row.timer:SetStatusBarColor(1, 0.75, 0.1)
	row.timer:SetMinMaxValues(0, 1)
	row.timer:SetHeight(4)
	row.timer:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 6, 1)
	row.timer:SetPoint("RIGHT", row, "RIGHT", -6, 0)
	row.timer.bg = row.timer:CreateTexture(nil, "BACKGROUND")
	row.timer.bg:SetAllPoints()
	row.timer.bg:SetColorTexture(0, 0, 0, 0.5)
	row.choice = row:CreateTexture(nil, "ARTWORK") -- your sample choice, where the buttons were
	row.choice:SetSize(18, 18)
	row.choice:SetPoint("TOPRIGHT", -8, -5)
	row.choice:Hide()
	row.buttons = {}
	for i, spec in ipairs(ROLL_BUTTONS) do
		if spec.type ~= 4 then -- (no Transmog in the sample)
			local b = CreateFrame("Button", nil, row)
			b:SetSize(20, 20)
			b:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4 - #row.buttons * 22, -4)
			b:SetNormalAtlas(spec.atlas .. "-up")
			b:SetHighlightAtlas(spec.atlas .. "-highlight")
			b:SetPushedAtlas(spec.atlas .. "-down")
			b:SetScript("OnClick", function()
				for _, other in ipairs(row.buttons) do
					other:Hide()
				end
				row.choice:SetAtlas(STATE_ATLAS[CLICK_STATE[spec.type]])
				row.choice:Show()
				row.timer:Hide()
				f.note:SetText("That's it: one click on the drop itself. (Nothing was rolled.)")
			end)
			row.buttons[#row.buttons + 1] = b
		end
	end
	row:SetScript("OnUpdate", Guard.wrapUpdate("ask", function(self) -- the sample's timer, only while the question shows
		local left = Ask.sampleTime - (GetTime() - (self.started or GetTime())) % Ask.sampleTime
		self.timer:SetValue(left / Ask.sampleTime)
	end, 1 / 20))
	f.note = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.note:SetPoint("TOPLEFT", row, "BOTTOMLEFT", 0, -4)
	f.note:SetWidth(Ask.W - 24)
	f.note:SetJustifyH("LEFT")

	f.yes = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.yes:SetSize(128, 22)
	f.yes:SetPoint("BOTTOMLEFT", 12, 36)
	f.yes:SetText("Yes, roll here")
	f.yes:SetScript("OnClick", function()
		db.askedRollHere = true
		Ask.setRollFromWindow(true)
		hideAsk(true)
		say("rolling from this window. Change it any time: Options > AddOns > RollFrames.")
	end)
	f.no = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.no:SetSize(128, 22)
	f.no:SetPoint("BOTTOMRIGHT", -12, 36)
	f.no:SetText("No thanks")
	f.no:SetScript("OnClick", function()
		db.askedRollHere = true
		hideAsk(true)
	end)
	f.later = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.later:SetPoint("BOTTOM", 0, 10)
	f.later:SetWidth(Ask.W - 24) -- (wraps rather than running past the panel's edges)
	f.later:SetText("Change this any time in Options > AddOns > RollFrames.")
	f:Hide()
end

function Ask.show()
	if not ask then
		Ask.create()
	end
	for _, b in ipairs(ask.sample.buttons) do
		b:Show()
	end
	ask.sample.choice:Hide()
	ask.sample.timer:Show()
	ask.sample.started = GetTime()
	ask.note:SetText("It's a sample: clicking it rolls nothing.")
	askPutAway = false -- (showing it again ends any waiting)
	Ask.placedAt = nil
	askShown = true
	layout() -- (the empty window's text gives way to the question)
	Ask.place()
	ask:Show()
	main.countdown:Hide()
end

-- answered: if the question opened (and pinned) the window itself, it can fade again like any other;
-- a window you opened yourself stays pinned. (Without it: put away for a roll, still unanswered.)
hideAsk = function(answered)
	askShown = false
	if ask then
		ask:Hide()
	end
	if main then
		relayoutPending = true -- (the empty window's text comes back)
		driver:Show()
	end
	if answered then
		askPutAway = false
		lastActivity = GetTime() -- the idle time starts now (the window doesn't vanish right after you answer)
		if Ask.pinnedIt then
			Ask.pinnedIt = false
			setPinned(false)
		end
	end
end

-- Asks if this is a calm moment and it hasn't been settled: not rolling from the window yet, no roll
-- open, not in combat. why: "login" (a few seconds after logging in), "opened" (you opened the window),
-- "again" (one put away for a roll or combat). Returns true if it asked.
maybeAsk = function(why)
	local ok, asked = pcall(Guard.run, "ask", Ask.maybe, why)
	if ok then
		return asked
	end
	Guard.trip("ask", asked)
	return false
end
function Ask.maybe(why)
	if askShown or db.askedRollHere or db.rollFromWindow or Guard.fallback or Guard.off.ask or InCombatLockdown() or Ask.anyRealDrop(true)
		or UnitIsDeadOrGhost("player") or GetTime() - (Ask.combatEnded or -100) < 5 -- (Feign Death, Vanish, a wipe)
		or GetTime() - (Ask.lootAt or -100) < 10 -- (never right after loot)
		or popupsOnScreen() then -- (Blizzard's roll popups up: a roll RollFrames may not know of, e.g. after /reload)
		return askShown
	end
	local wasHidden = not main:IsShown()
	showWindow() -- (also stops a fade already running, so the question isn't settled unseen)
	if wasHidden then
		setPinned(true) -- opened to ask: stays until answered or closed
		Ask.pinnedIt = true
		layout()
	end
	Ask.show()
	return true
end

-- Put away unanswered. For combat it comes back a few seconds after the fight (no loot involved); for
-- a roll it waits for the next time you open the window or log in (never right after loot).
function Ask.putAway(forCombat)
	if askShown then
		hideAsk()
		askPutAway = forCombat and true or false
		if Ask.pinnedIt then
			Ask.pinnedIt = false -- the window it opened is an ordinary one again (fades when idle)
			setPinned(false)
			if forCombat then -- (and doesn't stay up, empty, through the fight)
				Ask.selfHide = true -- (our own hide, not the player closing it)
				main:Hide()
				Ask.selfHide = nil
			end
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_LOGOUT")
events:SetScript("OnEvent", function(self, event, ...)
	if event == "PLAYER_LOGOUT" then
		if db then
			pcall(Saved.prune, db) -- (written to disk right after this; each step on its own, so one can't stop the other)
			if not Guard.off.history then
				pcall(History.save)
			end
		end
		return
	end
	if event == "PLAYER_LOGIN" then
		-- Protected: if setting up fails part-way, Blizzard's popups stay in charge (nothing half set up hides them).
		local ok, err = pcall(Guard.run, "login", function()
			RollFramesDB = RollFramesDB or {}
			db = RollFramesDB
			Saved.load(db) -- conversions, then only real choices are kept; the rest read as defaults
			History.load()
			createMain()
			refreshPin()
			main:HookScript("OnShow", applyBlizzardPopups)
			main:HookScript("OnHide", applyBlizzardPopups)
			-- Demo drops go when the window closes or fades out (not when the whole UI is hidden: Alt-Z).
			main:HookScript("OnHide", function()
				if not main:IsShown() then
					clearDemoCards()
				end
			end)
			if GroupLootContainer then
				GroupLootContainer:HookScript("OnShow", function(container)
					if suppressBlizzard() then
						container:Hide()
					end
				end)
				-- Attached: follow the popups when they appear (Blizzard positions them a moment later), and
				-- stay in their spot when they go.
				GroupLootContainer:HookScript("OnShow", function()
					if db.position == "attached" then
						C_Timer.After(0, Guard.wrapCore("position", function()
							if db.position == "attached" then -- unless the window was dragged meanwhile
								applyPosition()
							end
						end))
					end
				end)
				-- More popups make the container taller; remember where it ends up, so the window stays there
				-- after the popups go (its position can't be read once Blizzard has hidden it).
				if GroupLootContainer_Update then
					hooksecurefunc("GroupLootContainer_Update", Guard.wrapCore("popups", function()
						popupsOnScreen()
						if db.position == "attached" and main:IsShown() then
							relayoutPending = true -- more popups: less room above them (R32)
							driver:Show()
						end
					end))
				end
				GroupLootContainer:HookScript("OnHide", Guard.wrapCore("position", function()
					if db.position == "attached" then
						applyPosition()
					end
				end))
			end
			local ok, err = pcall(buildPanel)
			if not ok then
				say("settings panel unavailable, use /rollframes commands.", err)
			end
			self:RegisterEvent("LOOT_HISTORY_UPDATE_DROP")
			self:RegisterEvent("START_LOOT_ROLL")
			self:RegisterEvent("CANCEL_LOOT_ROLL")
			self:RegisterEvent("PLAYER_REGEN_DISABLED")
			self:RegisterEvent("PLAYER_REGEN_ENABLED")
			self:RegisterEvent("PLAYER_ENTERING_WORLD")
			main:HookScript("OnHide", function()
				local ownHide = Ask.selfHide
				Ask.selfHide = nil -- (read once and cleared here, so it can never stay set)
				if not main:IsShown() and not ownHide then
					if askShown then
						-- You closed it with the question showing: not an answer. Asked again next time you open
						-- the window or log in; the second time it's closed unanswered, it's left at "No thanks".
						db.askClosed = (db.askClosed or 0) + 1
						if db.askClosed >= 2 then
							db.askedRollHere = true
						end
						hideAsk()
					end
					askPutAway = false -- (closed while put away for combat: it waits for the next open or login)
				end
				if not main:IsShown() then
					Ask.pinnedIt = false -- (a real close; hiding the whole UI keeps it)
				end
			end)
			-- Asked at login (a few seconds in, so you see the window has arrived) while it's unanswered. In
			-- combat it waits for the fight to end; with a roll up it waits for the next open or login.
			if Saved.upgradeNote then -- (once, after an update from v1.1; REMOVE with Saved.showUpgradeNote)
				C_Timer.After(6, Guard.wrap("ask", Saved.showUpgradeNote))
			end
			C_Timer.After(4, Guard.wrap("ask", function()
				if not (db.askedRollHere or db.rollFromWindow) and not maybeAsk("login") and InCombatLockdown() then
					askPutAway = true
				end
			end))
			if ConfirmLootRoll then -- bind-on-pickup confirmation (only if a confirm can be told from a cancel)
				pcall(self.RegisterEvent, self, "CONFIRM_LOOT_ROLL")
			end
			pcall(self.RegisterEvent, self, "CANCEL_ALL_LOOT_ROLLS")
			-- Rolls made anywhere (Blizzard's popups, other addons) count against the twins pool (R38), and a
			-- confirmed bind-on-pickup roll stays taken.
			if RollOnLoot then
				hooksecurefunc("RollOnLoot", Guard.wrapCore("RollOnLoot", function(rollID)
					if rollID == nil or isSecret(rollID) then
						return
					end
					rolledIDs[rollID] = true
					local group = twinOfRoll[rollID]
					if group and not group.used[rollID] then
						group.used[rollID] = true
						refreshTwins(group)
					end
				end))
			end
			if ConfirmLootRoll then
				hooksecurefunc("ConfirmLootRoll", Guard.wrapCore("ConfirmLootRoll", function(rollID)
					if rollID ~= nil and not isSecret(rollID) then
						awaitingConfirm[rollID] = nil
						confirmedRolls[rollID] = true
					end
				end))
			end
		end)
		if not ok then
			Guard.fail(err, "login")
		end
		return
	end
	-- (Built once and kept on the frame: a new function per event was about 2 MB of garbage a raid night.)
	self.dispatch = self.dispatch or function(event, ...)
		if Guard.test == "rolls" then
			error("test failure (/rollframes fail rolls)")
		end
		if event == "LOOT_HISTORY_UPDATE_DROP" then
			onDropUpdate(...)
		elseif event == "START_LOOT_ROLL" then
			onStartRoll(...)
		elseif event == "CANCEL_LOOT_ROLL" then
			onCancelRoll(...)
		elseif event == "CONFIRM_LOOT_ROLL" then
			onConfirmLootRoll(...)
		elseif event == "PLAYER_ENTERING_WORLD" then
			Guard.adoptRolls() -- rolls still open from before a /reload or a loading screen
		elseif event == "PLAYER_REGEN_DISABLED" then
			Guard.call("ask", Ask.putAway, true) -- never in combat
		elseif event == "PLAYER_REGEN_ENABLED" then
			-- (Feign Death, Vanish or dying also end combat mid-fight: a put-away question comes back only
			-- once you've been out of combat, and alive, for 5 s; otherwise at the next open or login.)
			Ask.combatEnded = GetTime()
			if askPutAway then
				-- One try, 5 s after the fight; if it can't show then, next open or login. Only the newest
				-- end of combat counts (chain pulls), and a try that would land in the next fight waits for
				-- that fight's own end instead.
				local endedAt = Ask.combatEnded
				C_Timer.After(5.5, Guard.wrap("ask", function()
					if Ask.combatEnded ~= endedAt or InCombatLockdown() then
						return
					end
					if askPutAway and not (db.askedRollHere or db.rollFromWindow) then
						maybeAsk("again")
					end
					askPutAway = false
				end))
			end
		elseif event == "CANCEL_ALL_LOOT_ROLLS" then
			-- Every open roll ended at once (you left the group, say): each drop ends as if its roll were cancelled,
			-- so no buttons are left that roll on nothing.
			local open = {}
			for id in pairs(cardsByRollID) do
				open[#open + 1] = id
			end
			for _, id in ipairs(open) do
				onCancelRoll(id)
			end
			wipe(twinOfRoll)
			wipe(rolledIDs)
			wipe(confirmedRolls)
			wipe(awaitingConfirm)
		end
	end
	local ok, err = pcall(self.dispatch, event, ...)
	if not ok then
		Guard.fail(err, event) -- (Blizzard's popups first; the error goes to /rollframes diag and the log)
	end
end)

----------------------------------------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------------------------------------

local function diag()
	local encounters = C_LootHistory.GetAllEncounterInfos() or {}
	say("loot history encounters this session:", #encounters)
	for _, e in ipairs(encounters) do
		local drops = C_LootHistory.GetSortedDropsForEncounter(e.encounterID) or {}
		say(string.format("  %s (id %s): %d drops", tostring(safe(e.encounterName, "?")), tostring(e.encounterID),
			#drops))
	end
	say("cards:", #cards, "| log entries:", db.log and #db.log or 0, "| fallback:", tostring(Guard.fallback))
	local off = {}
	for name in pairs(Guard.off) do
		off[#off + 1] = name
	end
	table.sort(off)
	say("switched off after an error this session:", #off > 0 and table.concat(off, ", ") or "nothing")
	if db.lastError then
		say("last error:", db.lastError)
	end
	say("frames ever made:", framesMade.cards, "cards,", framesMade.lines, "lines | ready for reuse:", #cardPool,
		"cards,", #linePool, "lines")
end

--@debug@
-- Twins demo (dev builds only): two copies of one item drop at the same moment and, as can happen in a
-- raid, the loot history pairs them the wrong way round. Click a copy: your choice shows on the other
-- one, and the copy you clicked offers buttons again for your second roll (R38).
local function runDemoTwins()
	if demoBlocked() then
		return
	end
	clearDemoCards()
	showWindow()
	local rollA, rollB = {}, {}
	local item = { name = "Demo Twin Bracers", icon = "Interface\\Icons\\INV_Bracer_07", quality = 3, boss = "Demo Boss" }
	local a = runDemoItem(item, { ownRoll = rollA, simRoll = rollB })
	local b = runDemoItem(item, { ownRoll = rollB, simRoll = rollA })
	joinTwins(b, a)
	say("demo twins: two copies of one item, paired the wrong way round."
		.. (db.rollFromWindow and " Click Need on one: it shows on the other, and the one you clicked offers your second roll."
			or " Turn on \"Roll from this window\" to roll on them."))
end

-- Stress test (dev builds only): an AQ40-sized night squeezed into a few minutes, fed through the same
-- code real loot updates use (applyDropInfo). Drops arrive in boss-kill bursts; each has up to 40
-- raiders, and every time one rolls, a full update arrives listing all of them (still-deciding included),
-- as Blizzard's loot history does. Cards collapse, leave the history and are reused.
-- /rollframes stress [drops] [players] [hidden]: "hidden" runs it with the window closed.
-- Reports memory, frames ever made, pool sizes, frame times and the time spent in RollFrames's own code.
local stressRun = 0
local stressMonitor
local STRESS_CLASSES = { "WARRIOR", "PRIEST", "DRUID", "WARLOCK", "MAGE", "ROGUE", "HUNTER", "PALADIN", "SHAMAN" }
-- Real item IDs (Molten Core / Blackwing Lair / AQ40 era), so item level and tooltips go through the real
-- item APIs. Names in the links are placeholders; the game fills in item data as it loads.
local STRESS_ITEMS = { 19019, 17076, 18832, 19364, 19352, 21134, 21126, 21616, 21839, 21679 }

local function memoryKB()
	if UpdateAddOnMemoryUsage and GetAddOnMemoryUsage then
		UpdateAddOnMemoryUsage()
		return GetAddOnMemoryUsage(ADDON)
	end
	return collectgarbage("count")
end

local function stressTest(drops, players, hidden)
	stressRun = stressRun + 1
	local run = stressRun
	drops = math.max(1, math.min(drops or 400, 5000))
	players = math.max(1, math.min(players or 40, 40))
	clearDemoCards()
	if not hidden then
		setPinned(true) -- keep the window up for the whole run (an idle fade would end it)
	end
	if hidden then
		main:Hide()
	else
		showWindow()
	end
	collectgarbage("collect")
	local memStart = memoryKB()
	local cardsMade, linesMade = framesMade.cards, framesMade.lines
	local startedAt, done = GetTime(), 0
	local worst, frames, total, updateMs = 0, 0, 0, 0
	driver.profiling, driver.ms = true, 0
	local opts = { demo = true, quiet = true, noOpen = hidden }
	local clearsAtStart = demoClears -- real loot or /rollframes demo clearing the test's cards ends the run
	local encounterID = -run -- negative: can't collide with a real encounter

	-- Whole-game frame times while the test runs. Stops itself when this run ends, is replaced, or
	-- is interrupted (real loot or the demo clears the test's cards).
	local deadline
	stressMonitor = stressMonitor or CreateFrame("Frame")
	stressMonitor:SetScript("OnUpdate", function(self, elapsed)
		if run ~= stressRun or (deadline and GetTime() > deadline) then
			self:SetScript("OnUpdate", nil)
			if run == stressRun then
				driver.profiling = false
			end
			return
		end
		frames, total = frames + 1, total + elapsed
		if elapsed > worst then
			worst = elapsed
		end
	end)

	local function report(final, stopped)
		if final then
			collectgarbage("collect")
		end
		local seconds = math.max(0.001, GetTime() - startedAt)
		local codeMs = (updateMs + driver.ms) / seconds
		say(string.format("%s %d/%d drops%s | %.0fs | avg %.0f fps, worst frame %.0f ms | RollFrames code %.2f ms/s"
			.. " (updates %.2f, animation %.2f)", stopped and "stress stopped early:" or (final and "stress done:"
			or "stress:"), done, drops,
			hidden and " (window closed)" or "", seconds, frames / math.max(total, 0.001), worst * 1000, codeMs,
			updateMs / seconds, driver.ms / seconds))
		say(string.format("  memory %+.0f KB (now %.0f KB) | frames ever made: %d cards, %d lines (+%d, +%d this run)"
			.. " | in the list: %d cards | ready for reuse: %d cards, %d lines",
			memoryKB() - memStart, memoryKB(), framesMade.cards, framesMade.lines, framesMade.cards - cardsMade,
			framesMade.lines - linesMade, #cards, #cardPool, #linePool))
		if final then
			driver.profiling = false
			stressMonitor:SetScript("OnUpdate", nil)
			say("|cff33ff99Stress test finished.|r Type /reload to save the results for review.")
			log("stress", { drops = drops, done = done, stopped = stopped or nil, players = players,
				hidden = hidden or nil, seconds = math.floor(seconds),
				fps = math.floor(frames / math.max(total, 0.001)), worstMs = math.floor(worst * 1000),
				codeMsPerSec = string.format("%.2f", codeMs), updateMsPerSec = string.format("%.2f", updateMs / seconds),
				animMsPerSec = string.format("%.2f", driver.ms / seconds), memDeltaKB = math.floor(memoryKB() - memStart),
				cardsMade = framesMade.cards - cardsMade, linesMade = framesMade.lines - linesMade,
				pooledCards = #cardPool, pooledLines = #linePool, listCards = #cards })
		end
	end

	-- One full update for drop i, as the loot history would send it.
	local function sendUpdate(i, link, rolled, final)
		local rolls = {}
		local best, bestRoll
		for p = 1, players do
			local entry = { playerName = "Raider" .. p, playerGUID = "Stress-" .. p,
				playerClass = STRESS_CLASSES[p % #STRESS_CLASSES + 1], isSelf = p == 1 }
			if rolled[p] then
				local pass = p % 7 == 0
				entry.state = pass and STATE.PASS or (p % 2 == 0 and STATE.NEED or STATE.GREED)
				entry.roll = not pass and (p * 37 + i) % 100 + 1 or nil
				if entry.roll and (not bestRoll or entry.roll > bestRoll) then
					best, bestRoll = entry, entry.roll
				end
			else
				entry.state = STATE.NOROLL
			end
			rolls[p] = entry
		end
		local info = { itemHyperlink = link, rollInfos = rolls, startTime = 0, duration = 3 }
		if final then
			if best then
				info.winner = best
			else
				info.allPassed = true
			end
		end
		local t0 = debugprofilestop()
		applyDropInfo(encounterID, i, info, opts)
		updateMs = updateMs + debugprofilestop() - t0
	end

	local function interrupted()
		if run == stressRun and demoClears ~= clearsAtStart then
			say("stress: stopped (the window closed, real loot arrived, or a demo started). Numbers so far:")
			report(true, true)
			stressRun = stressRun + 1 -- ends this run: its timers and monitor all check stressRun
		end
		return run ~= stressRun
	end

	local function oneDrop(i)
		if interrupted() then
			return
		end
		local id = STRESS_ITEMS[i % #STRESS_ITEMS + 1]
		local link = "|cffa335ee|Hitem:" .. id .. "::::::::60:::::|h[Stress item " .. id .. "]|h|r"
		local rolled = {}
		sendUpdate(i, link, rolled, false)
		local card = cardsByHistory[encounterID .. ":" .. i]
		local gen = card and card.gen
		local function stillOurs()
			return not interrupted() and card and card.gen == gen
		end
		for p = 1, players do
			C_Timer.After(math.random() * 2.5, function()
				if stillOurs() then
					rolled[p] = true
					sendUpdate(i, link, rolled, false)
				end
			end)
		end
		C_Timer.After(3, function()
			if not stillOurs() then
				return
			end
			sendUpdate(i, link, rolled, true)
			done = done + 1
			if done % 100 == 0 and done < drops then
				report(false)
			end
			if done == drops then
				C_Timer.After(db.holdSeconds + 2, function()
					if not interrupted() then
						report(true)
						clearDemoCards()
						stressRun = stressRun + 1 -- this run is over
					end
				end)
			end
		end)
	end

	-- Boss kills: bursts of up to 6 drops at once, one burst every 1.5 seconds.
	local t = 0
	for i = 1, drops do
		C_Timer.After(t, function()
			oneDrop(i)
		end)
		if i % 6 == 0 then
			t = t + 1.5
		end
	end
	deadline = GetTime() + t + db.holdSeconds + 30
	say(string.format("stress: %d drops x %d raiders over about %.0f s%s. Reports every 100 drops; /reload to stop.",
		drops, players, t + 3, hidden and ", window closed" or ""))
end
--@end-debug@

-- Add-on compartment (the AddOns button by the minimap): left-click shows or hides the window,
-- right-click opens the settings. Named in the TOC, so these three must stay global.
function RollFrames_OnAddonCompartmentClick(_, button)
	if button == "RightButton" then
		if category then
			Settings.OpenToCategory(category:GetID())
		end
	elseif main and main:IsShown() and not tweens["main:fade"] then
		main:Hide()
	elseif main then
		showWindow()
		setPinned(true) -- opened by hand: stays until closed
		layout()
		maybeAsk("opened")
	end
end

function RollFrames_OnAddonCompartmentEnter(_, menuButton)
	GameTooltip:SetOwner(menuButton, "ANCHOR_LEFT")
	GameTooltip:SetText("RollFrames", 1, 1, 1)
	local open = 0
	for _, card in ipairs(cards) do
		if not card.collapsed then
			open = open + 1
		end
	end
	if open > 0 then
		GameTooltip:AddLine(string.format("%d roll%s in progress", open, open == 1 and "" or "s"), 1, 0.82, 0)
	end
	GameTooltip:AddLine("Left-click: show or hide the window", 0.8, 0.8, 0.8)
	GameTooltip:AddLine("Right-click: settings", 0.8, 0.8, 0.8)
	GameTooltip:Show()
end

function RollFrames_OnAddonCompartmentLeave()
	GameTooltip:Hide()
end

SLASH_ROLLFRAMES1 = "/rollframes"
SlashCmdList.ROLLFRAMES = function(input)
	if not db or not main then
		return -- not loaded yet (before login)
	end
	local command = strtrim(input or ""):lower()
	if command == "demo" or command:match("^demo%s+%d+$") then
		if Guard.off.demo then
			say("the demo is off until you /reload (it hit a problem).")
		else
			Guard.call("demo", runDemo, tonumber(command:match("%d+")) or 3)
		end
	elseif command == "options" and category then
		Settings.OpenToCategory(category:GetID())
	elseif command == "reset all" then
		History.askResetAll()
	elseif command == "reset" then
		db.position = nil -- (the defaults: free, on the right beside the quest tracker)
		db.point = nil
		db.maxHeight = nil
		db.height = nil
		applyPosition()
		layout()
		say("window position and size reset (on the right, beside the quest tracker).")
	elseif command == "blizzard" then
		ToggleLootHistoryFrame()
	elseif command == "diag" then
		diag()
	elseif command == "diag log" then
		db.debugLog = not db.debugLog
		say("troubleshooting log:", db.debugLog and "on (saved with your settings; no names)" or "off")
	--@debug@
	elseif command == "log" then
		local entries = db.log or {}
		say(#entries, "log entries (newest last; /reload saves them for review):")
		for i = math.max(1, #entries - 19), #entries do
			local e, extra = entries[i], {}
			for k, v in pairs(e) do
				if k ~= "time" and k ~= "kind" then
					extra[#extra + 1] = k .. "=" .. tostring(v)
				end
			end
			table.sort(extra)
			say(e.time:sub(12), e.kind, table.concat(extra, " "))
		end
	elseif command == "log clear" then
		db.log = {}
		say("log cleared.")
	elseif command == "highlight" or command:match("^highlight%s") then
		-- Try the highlight styles: "/rollframes highlight" goes to the next one, or name it (border, timer,
		-- sparkle, all, off). Same as the setting.
		local want = command:match("^highlight%s+(%a+)$")
		if want and not Highlight.valid(want) then
			say("highlight styles:", table.concat(Highlight.STYLES, ", "))
			return
		end
		if not want then
			local styles, at = Highlight.STYLES, 0
			for i, name in ipairs(styles) do if name == db.highlightRolls then at = i end end
			want = styles[at % #styles + 1]
		end
		if settingObjects.highlightRolls then
			settingObjects.highlightRolls:SetValue(want) -- (also updates an open Options page; calls restyle)
		else
			db.highlightRolls = want
		end
		Highlight.restyle()
		say("highlight:", want, db.rollFromWindow and "" or "(turn on Roll from this window to see it)")
	elseif command == "demo twins" then
		runDemoTwins()
	elseif command:match("^fail") then
		-- Try a fail-safe: "/rollframes fail <part>" makes that part error from now on (until "fail off" or a
		-- /reload). Core parts bring Blizzard's popups back; extras switch themselves off quietly (see diag).
		local parts = { "rolls", "layout", "click", "collapse", "watchdog", "animations", "highlight", "flash",
			"markers", "history", "demo", "guard", "ask", "autohide", "chrome", "timer", "resize" }
		local part = command:match("^fail%s+(%a+)$")
		if part == "off" then
			Guard.test = nil
			say("test failures off.")
			return
		end
		local known = false
		for _, name in ipairs(parts) do
			known = known or name == part
		end
		if not known then
			say("/rollframes fail <part>, one of:", table.concat(parts, ", "), "(or off)")
			return
		end
		Guard.test = part
		if part == "watchdog" then
			-- A drop waiting for your roll loses its buttons and the rebuild doesn't bring them back: after
			-- about 4 s the watchdog switches to Blizzard's popups (try it with the demo and Roll from this window).
			local hidden = 0
			for _, card in ipairs(cards) do
				if card.buttons:IsShown() then
					card.buttons:Hide()
					hidden = hidden + 1
				end
			end
			if hidden == 0 then
				Guard.test = nil
				say("no drop is waiting for your roll: start the demo (with Roll from this window on), then try again.")
				return
			end
		end
		say("test: " .. part .. " fails from now on (dev builds only). /rollframes fail off stops it; /reload resets.")
	elseif command == "ask" then
		-- Show the first-use question any time, to try it. (Answering it, or closing the window, records
		-- your answer in your own settings, like a player's.)
		if not main:IsShown() then
			showWindow()
			setPinned(true)
			Ask.pinnedIt = true
			layout()
		end
		Ask.show()
	elseif command:match("^stress") then
		local drops, players = command:match("^stress%s*(%d*)%s*(%d*)")
		stressTest(tonumber(drops), tonumber(players), command:find("hidden", 1, true) ~= nil)
	--@end-debug@
	elseif command == "" then
		if main:IsShown() and not tweens["main:fade"] then
			main:Hide()
		else
			showWindow()
			setPinned(true) -- opened by hand: stays until closed
			layout()
			maybeAsk("opened")
		end
	else
		say("commands: /rollframes (show or hide) | demo [count] | options | reset (window spot and size) | reset all (everything, after asking) | blizzard | diag")
	end
end
