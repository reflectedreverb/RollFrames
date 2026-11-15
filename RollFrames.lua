-- RollFrames: live group loot rolls in one Blizzard-style window.
-- Data: C_LootHistory plus START_LOOT_ROLL for the roll timer and RollOnLoot buttons.
-- Commands: /rollframes | demo | options | size | reset | reset all | blizzard | diag | diag log

local ADDON = "RollFrames"
-- "" leaves the footer blank.
local FOOTER = "ReflectedReverb Addons"

-- Blizzard's plain header, no InitFrame/Resetter of our own: the settings list reads a row's Resetter outside
-- its taint barrier, and the next list drawn (Social's Discord row) is then blocked and blamed on us.
local function footerInitializer()
	return CreateSettingsListSectionHeaderInitializer("|cff8c8c8c" .. FOOTER .. "|r")
end

-- Layout
local WIDTH = 300
local SIDE_PAD = 10
local TITLE_H = 28
local BOTTOM_PAD = 10
local CARD_GAP = 4
local HEADER_H = 34 -- grows with roll button size: Scale.setRows
local ICON = 28
local LINE_H = 18
-- Heights are whole snap steps: 56 + rows * ROW_H (History.snapHeight).
local MAX_HEIGHT = 550 -- db.maxHeight default: 13 rows
local FIXED_HEIGHT = 322 -- db.height default: 7 rows, or 2 live 5-man drops
-- Two compact rows: any shorter and Blizzard's panel template draws broken corners.
local MIN_HEIGHT = TITLE_H + 2 * HEADER_H + CARD_GAP + BOTTOM_PAD

-- Enum.EncounterLootDropRollState: NeedMainSpec 0, NeedOffSpec 1, Transmog 2, Greed 3, NoRoll 4, Pass 5.
local STATE = { NEED = 0, NEED_OFF = 1, TRANSMOG = 2, GREED = 3, NOROLL = 4, PASS = 5 }
local STATE_ATLAS = {
	[0] = "lootroll-toast-icon-need-up", [1] = "lootroll-toast-icon-need-up",
	[2] = "lootroll-toast-icon-transmog-up", [3] = "lootroll-toast-icon-greed-up",
	[5] = "lootroll-toast-icon-pass-up",
}
-- RollOnLoot roll types. Left to right on screen: Need, Greed, Pass, as on Blizzard's roll popup (Need on
-- the left, Pass on the right), always in these spots. `spot` counts from the right edge. Transmog goes to
-- the left of Need, shown only on a roll that allows it (none seen on Forever so far), so the others never move.
local ROLL_BUTTONS = {
	{ type = 1, atlas = "lootroll-toast-icon-need", label = "Need", can = "canNeed", spot = 2 },
	{ type = 2, atlas = "lootroll-toast-icon-greed", label = "Greed", can = "canGreed", spot = 1 },
	{ type = 0, atlas = "lootroll-toast-icon-pass", label = "Pass", spot = 0 },
	{ type = 4, atlas = "lootroll-toast-icon-transmog", label = "Transmog", can = "canTransmog", onlyIfAllowed = true, spot = 3 },
}
ROLL_BUTTONS.can = {} -- what the current roll allows (see cardRollTypes)

-- Line order in a card. Lines only trade places, so one choice moves two lines at most.
local GROUP_YOU, GROUP_ROLLED, GROUP_DECIDING, GROUP_PASSED = 1, 2, 3, 4
-- A roll button's choice as the loot history reports it.
local CLICK_STATE = { [1] = STATE.NEED, [2] = STATE.GREED, [4] = STATE.TRANSMOG, [0] = STATE.PASS }

local DEFAULTS = {
	autoOpen = true,
	rollFromWindow = false,
	-- "auto" (Everyone in parties, Summary in raids), "all", "summary" or "none"
	playerLines = "summary",
	-- Drops waiting for your roll (their roll buttons show, so only with rollFromWindow): "border" (a pulsing
	-- gold frame), "timer" (the timer bar glows, with a spark at its edge), "sparkle", "all" or "off".
	highlightRolls = "border",
	hoverGlow = true, -- Accessibility: a gold glow behind the roll button under the mouse
	-- Off (or flashing "off"): no sweep; your wins keep a tint.
	resultSweep = true,
	noMotion = false, -- "No animations": everything at once, nothing flashes, pulses or sweeps
	-- "small" (20 px), "medium" (25), "large" (28) or "xlarge" (32, Blizzard's popup size): Scale.LOOK
	rollButtons = "medium",
	-- Accessibility: "normal" (pulses, sweeps, one flash when new loot brings the window back from History),
	-- "persist" (that flash repeats until you hover the window) or "off" (nothing flashes or pulses).
	flashing = "normal",
	keepTrash = true, -- false: drops from trash (encounter 0) leave the history once decided
	position = "free", -- internal; "attached" (above Blizzard's popups) is no longer offered
	-- Internal, no longer in Options. Kept as values because tests still use them.
	newOrder = "top", -- new drops appear "top" (older below, History under them) or "bottom"
	hoverHold = "off", -- what holds the list under the mouse: "off", "buttons" or "window"
	holdSeconds = 5, -- how long a decided drop shows its result before it becomes a history row
	-- Click guard: roll buttons that slide under a still cursor (the list moved) ignore clicks, dimmed, for
	-- guardTime seconds or until the mouse moves a button's width (guardTime 0: only when the mouse moves).
	buttonGuard = true,
	guardTime = 2,
	autoHide = 15, -- seconds after the last activity; 0 = never
	historyCount = 20, -- decided rows kept in the list (fixed; the rest are in History)
	historyKeep = 100, -- decided drops History keeps (saved per character across reloads): 50/100/250/500
	historyFade = 60, -- seconds a decided drop stays in the list before it fades into History; 0 = until cleared
	historyMinQuality = 0, -- 0 = keep every item in the history; 2/3/4 = uncommon/rare/epic and better
	-- Fixed height (db.height) unless autoGrow: then it grows with its drops up to db.maxHeight.
	autoGrow = false,
	height = FIXED_HEIGHT,
	-- Corner drags move a whole row at a time.
	snapDrag = false,
	itemTooltip = "drop", -- where a drop's item tooltip shows: "drop" (anywhere on it) or "icon" (its icon only)
	buttonTips = true, -- a small tip by the roll button under the mouse (its roll, why not, the guard)
	tooltipGameSpot = false, -- "Tooltips at game's spot": item tooltips at the game's own place, not beside the window
	maxHeight = MAX_HEIGHT,
	windowSize = 100, -- Window size: percent, 75 to 200; the whole window scales (text, icons, rows)
}

-- Saved settings hold only real choices: an unset one reads the current default, so defaults can change
-- freely. Add a Saved.MIGRATIONS step only for a rename or changed meaning.
local Saved = {
	-- Saved values that aren't settings. Any other non-setting key is removed at login.
	STATE = { point = true, log = true, pairLog = true, askedRollHere = true, askClosed = true, debugLog = true,
		demoHidden = true, -- ("Don't show this again" under the empty window's demo button)
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
end
-- v1.2 -> v1.3: "Above roll popups" left Options; a window kept there moves to the starting spot.
Saved.MIGRATIONS[3] = function(db)
	if rawget(db, "position") == "attached" then
		db.position, db.point = nil, nil
	end
end
Saved.LATEST = 3

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
	-- A damaged file mustn't reach the game's own calls: the window's spot goes to SetPoint, the size to Blizzard's
	-- slider. Unusable values are dropped (the default, or the starting spot, instead).
	local point = rawget(db, "point")
	if point ~= nil and not (type(point) == "table" and type(point[1]) == "string" and type(point[2]) == "string"
		and type(point[3]) == "number" and type(point[4]) == "number") then
		db.point = nil
	end
	for key, default in pairs(DEFAULTS) do -- (every setting: a value of the wrong type is dropped)
		local v = rawget(db, key)
		if v ~= nil and type(v) ~= type(default) then
			db[key] = nil
		end
	end
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
-- History (the clock in the title bar): records of drops decided this session, newest first, shown as
-- rows continuing the list; only rows in view have a frame. Demo drops keep their own records.
-- Functions live on History because the file is at Lua's 200-locals limit.
local History = { records = {}, demo = {}, merged = {}, rows = {}, shown = false, top = 0, seq = 0,
	MAX = 500, ROW_H = HEADER_H + CARD_GAP,
	byMark = {}, -- drop mark (item link @ start time) -> its record, so a drop seen again (a reload) isn't added twice
	cardOf = setmetatable({}, { __mode = "k" }), -- record -> { card, gen } while its card may still be listed
}

-- Roll buttons in the window: "Roll from this window", except in controller mode, where the game sends every roll
-- to its own gamepad roll list (Blizzard's GamepadGroupLootRollFrame; RollFrames never hides it), so buttons here
-- would only duplicate it. The setting keeps its value and applies again without a controller.
function History.rollsHere()
	if not db.rollFromWindow then
		return false
	end
	if not (InputUtil and InputUtil.IsGamepadUIEnabled) then
		return true
	end
	local ok, pad = pcall(InputUtil.IsGamepadUIEnabled)
	return not (ok and pad)
end
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
	-- Hidden window: jump to the end (animating while closed cost 29 ms/s in the stress test).
	-- Same when animations are off after errors (Guard.animationFailed).
	if Guard.off.animations or (db and db.noMotion) or (main and not main:IsVisible()) then
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
	-- (Work queued this frame for the next, e.g. by the layout above, keeps it running.)
	local shown = main and main:IsShown()
	if next(tweens) == nil and not History.guardCheck and not ((relayoutPending or markersDirty) and shown) then
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

-- Flashing Off, or No animations: nothing flashes, pulses or sweeps.
function History.noFlash()
	return db.flashing == "off" or db.noMotion == true
end

-- "No animations" switched on: every Lua animation still running ends where it would (as after errors).
function History.finishTweens()
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

-- Native fades: an Alpha animation the engine plays, so nothing runs per frame. The region's own alpha is
-- set to the end value at once and the animation shows the way there; `done` runs on a timer, so it runs
-- even if the region hides meanwhile. A fade over a fade starts where the first had got to. Anything that
-- sets a fading region's alpha directly goes through History.setAlpha, or the animation would cover it.
function History.fadeOf(region)
	local fade = region.rfFade
	if fade or History.noFade then
		return fade
	end
	local ok, made = pcall(function()
		local group = region:CreateAnimationGroup()
		local anim = group:CreateAnimation("Alpha")
		anim:SetSmoothing("OUT")
		return { group = group, anim = anim, token = 0 }
	end)
	if not ok then
		History.noFade = true -- (this client can't: alphas are set at once from now on)
		return nil
	end
	region.rfFade = made
	return made
end

-- The alpha on screen: part way through a fade, where it has got to.
function History.shownAlpha(region)
	local fade = region.rfFade
	if fade and fade.group:IsPlaying() then
		local ok, p = pcall(fade.anim.GetSmoothProgress, fade.anim)
		if ok and type(p) == "number" then
			return fade.from + (fade.to - fade.from) * p
		end
	end
	return region:GetAlpha()
end

function History.stopFade(region)
	local fade = region.rfFade
	if fade then
		fade.token = fade.token + 1 -- (its `done` won't run)
		-- Always: a fade on a frame hidden mid-play is paused, not playing, and would hold its alpha
		-- when the frame is reused (a pooled player line came back invisible).
		fade.group:Stop()
	end
end

function History.setAlpha(region, alpha)
	if region.rfFade then
		History.stopFade(region)
	end
	region:SetAlpha(alpha)
end


-- A drop row and its player lines fade in Lua, not with the engine. When an engine fade on a frame starts, plays
-- and ends, the game puts back the alpha of what's inside it: parts that had faded before go back to that fade's
-- alpha, and alpha set while it plays is undone when it ends. Reused player lines came back invisible and Click
-- guard's dim was lost. Engine fades are for single parts and for frames whose contents never change alpha.
-- from: where it starts (default: where it is).
function History.fadeRow(card, to, duration, done, from)
	local f = card.frame
	from = from or f:GetAlpha()
	if from ~= to and main and main:IsVisible() and not (db and db.noMotion) and not Guard.off.animations then
		f:SetAlpha(from) -- (now: the tween's first step is next frame)
	end
	tween(card.id .. ":rowfade", duration, function(p)
		f:SetAlpha(from + (to - from) * p)
	end, done)
end

function History.fadeLinesOut(card)
	local from = {}
	for _, line in pairs(card.lines) do
		from[line] = line:GetAlpha()
	end
	if next(from) == nil then
		return
	end
	tween(card.id .. ":linesout", 0.35, function(p)
		for line, a in pairs(from) do
			line:SetAlpha(a * (1 - p))
		end
	end)
end

function History.fade(region, to, duration, done, from)
	from = from or History.shownAlpha(region)
	History.stopFade(region)
	local fade = from ~= to and not Guard.off.animations and not (db and db.noMotion) and main and main:IsVisible()
		and History.fadeOf(region)
	region:SetAlpha(to)
	if fade then
		fade.from, fade.to = from, to
		fade.anim:SetFromAlpha(from)
		fade.anim:SetToAlpha(to)
		fade.anim:SetDuration(duration)
		fade.group:Play()
	end
	if not done then
		return
	end
	if not fade then
		local ok, err = pcall(done) -- (no fade: at once, as a tween in a hidden window)
		if not ok then
			Guard.animationFailed(err)
		end
		return
	end
	local token = fade.token
	C_Timer.After(duration, function()
		if fade.token == token then
			local ok, err = pcall(done)
			if not ok then
				Guard.animationFailed(err)
			end
		end
	end)
end

----------------------------------------------------------------------------------------------------
-- Main window
----------------------------------------------------------------------------------------------------

-- Recount the "more to roll" markers next frame.
local function requestMarkers()
	markersDirty = true
	driver:Show()
end

-- Window size. The window's own units are the screen's times its scale, so a position or height read
-- from another frame (the popups, the screen) is converted before it's used as the window's offset or
-- compared with the window's height.
local Scale = { MIN = 75, MAX = 200 }
function Scale.get()
	local size = tonumber(db.windowSize) or 100 -- (saved data is untrusted)
	if size ~= size then
		size = 100 -- (not a number)
	end
	return math.max(Scale.MIN, math.min(Scale.MAX, size)) / 100
end
-- A length in `frame`'s units, in the window's.
function Scale.toMain(frame, v)
	return v * frame:GetEffectiveScale() / main:GetEffectiveScale()
end
-- The screen's height in the window's units.
function Scale.screenHeight()
	return Scale.toMain(UIParent, UIParent:GetHeight())
end

-- Roll button sizes. The rows grow by `extra` so the timer bar keeps running under the buttons.
Scale.LOOK = {
	-- glow: the hover glow's square (its visible part is smaller).
	-- 2 px between buttons, the 4 px timer bar 2 px under them; the icon grows with the row to keep 3 px
	-- above and below.
	small = { size = 20, step = 22, top = -4, glow = 28, extra = 0 }, -- (v1.2's buttons; icon 28)
	medium = { size = 25, step = 27, top = -3, glow = 35, extra = 3, icon = 31 }, -- (meets the 24 px guideline)
	large = { size = 28, step = 30, top = -3, glow = 40, extra = 6, icon = 34 },
	-- Blizzard's own popup size (32 px buttons, Forever's GroupLootFrame.xml; its icon is a little bigger, 34).
	xlarge = { size = 32, step = 34, top = -3, glow = 45, extra = 10, icon = 38 },
}
Scale.extra = 0
Scale.iconSize = ICON -- a look with `icon` grows it
-- The Roll buttons setting's choices, in order.
Scale.CHOICES = { { "small", "Small" }, { "medium", "Medium" }, { "large", "Large" }, { "xlarge", "Extra large" } }
function Scale.look()
	-- Without "Roll from this window" there are no buttons: rows as v1.2's. An unknown saved value: the default.
	if not History.rollsHere() then
		return Scale.LOOK.small
	end
	return type(db.rollButtons) == "string" and Scale.LOOK[db.rollButtons] or Scale.LOOK[DEFAULTS.rollButtons]
end
-- The row height for the current look; true if it changed.
function Scale.setRows()
	local look = Scale.look()
	local extra, icon = look.extra, look.icon or ICON
	if extra == Scale.extra and icon == Scale.iconSize then
		return false
	end
	Scale.extra, Scale.iconSize = extra, icon
	HEADER_H = 34 + extra
	MIN_HEIGHT = TITLE_H + 2 * HEADER_H + CARD_GAP + BOTTOM_PAD
	History.ROW_H = HEADER_H + CARD_GAP
	return true
end
-- Where the 4 px timer bar sits (Player lines Everyone and None): beside the icon's bottom, under the roll
-- buttons; with bigger ones, 2 px below them. (Summary's thin timer runs along the row's bottom edge anyway.)
function Scale.placeTimer(card)
	card.timer:ClearAllPoints()
	card.timer:SetPoint("BOTTOMLEFT", card.icon, "BOTTOMRIGHT", 6, Scale.timerY())
	card.timer:SetPoint("RIGHT", card.frame, "RIGHT", -6, 0)
	card.timer:SetHeight(4)
end
-- The hover glow and each button's own hover highlight, for every roll button of a drop: lit only on
-- the button under the mouse, never while the click guard holds the drop, and back as soon as it lets go
-- with the mouse still there. Run when the guard starts or ends and when the buttons show or hide; OnEnter
-- and OnLeave handle ordinary hovering.
function Scale.refreshGlow(card)
	if not card.buttons then
		return -- (the bar hides once while it's made, before the drop has it)
	end
	local guarded = card.guarded and true or false
	for _, button in ipairs(card.buttons.list) do
		local lit = db.hoverGlow and button.glow.ok and not guarded and button:IsEnabled() and button:IsVisible()
			and button:IsMouseOver() and true or false
		if button.glow:IsShown() ~= lit then
			button.glow:SetShown(lit)
		end
		if button.dimmedHighlight ~= guarded then
			button.dimmedHighlight = guarded
			local highlight = button:GetHighlightTexture()
			if highlight then
				highlight:SetAlpha(guarded and 0 or 1)
			end
		end
	end
end

-- The 4 px timer bar's offset from the icon's bottom: 1 in a 34 px row; in a taller one, 2 px under the
-- buttons (its bottom `top - size - 6` from the row's top).
function Scale.timerY()
	local look = Scale.look()
	return Scale.extra > 0 and (look.top - look.size - 3 + Scale.iconSize) or 1
end
-- Line 2's baseline (the winner, the boss name, the time), from the row's bottom: the icon's bottom + 4.
function Scale.lineTwo()
	return 35 + Scale.extra - Scale.iconSize
end

-- A drop's roll buttons and the parts of its row that depend on the row's height.
function Scale.styleCard(card)
	local look, bar = Scale.look(), card.buttons
	bar:ClearAllPoints()
	bar:SetPoint("TOPRIGHT", card.frame, "TOPRIGHT", -4, look.top)
	bar:SetSize((bar.wide and 4 or 3) * look.step, look.size)
	for _, button in ipairs(bar.list) do
		button:SetSize(look.size, look.size)
		button:ClearAllPoints()
		button:SetPoint("RIGHT", bar, "RIGHT", -button.spec.spot * look.step, 0)
		button.glow:SetSize(look.glow, look.glow)
	end
	card.boss:SetPoint("BOTTOMRIGHT", card.frame, "BOTTOMRIGHT", -6, Scale.lineTwo())
	-- Your choice takes the right-hand button's place, at its size.
	card.mineIcon:SetSize(look.size, look.size)
	History.placeMine(card, look)
	if card.icon:GetWidth() ~= Scale.iconSize then
		card.icon:SetSize(Scale.iconSize, Scale.iconSize)
	end
	if card.timerThin then
		card.timer:ClearAllPoints() -- (Summary's thin timer starts under the name, past the icon)
		card.timer:SetPoint("BOTTOMLEFT", card.frame, "BOTTOMLEFT", Scale.iconSize + 9, 3)
		card.timer:SetPoint("RIGHT", card.frame, "RIGHT", -6, 0)
	else
		Scale.placeTimer(card)
	end
	card.look = look
	card.headerMode = nil -- (the item level's spot depends on the size: placed again, Scale.restyleRows)
end

-- By the top-left corner, so a height change grows or shrinks the window downward.
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
		local es = GroupLootContainer:GetEffectiveScale() -- (kept in screen pixels: the window's size may change)
		lastPopupSpot[1], lastPopupSpot[2] = x * es, top * es
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
		local es = main:GetEffectiveScale()
		main:SetPoint("BOTTOM", UIParent, "BOTTOMLEFT", lastPopupSpot[1] / es, lastPopupSpot[2] / es + 8)
	elseif db.position == "attached" and bottomContainer() then
		main:SetPoint("BOTTOM", bottomContainer(), "TOP", 0, 8)
	elseif db.position == "attached" then
		main:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, Scale.toMain(UIParent, 220))
	elseif db.point then
		main:SetPoint(db.point[1], UIParent, db.point[2], db.point[3], db.point[4])
	else
		-- Free and never dragged: beside the quest tracker, a little above the middle, out of the way
		-- of the action bars. Placed fresh each time until dragged.
		local x = Scale.toMain(UIParent, -300) -- (screen units, so a bigger Window size starts in the same spot)
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
		main:SetPoint("TOPRIGHT", UIParent, "RIGHT", x, Scale.toMain(UIParent, 120))
	end
end

-- Where new drops appear (db.newOrder, internal; "top" by default).
local function newestAtBottom()
	return db.newOrder == "bottom"
end

-- in the attached spot the window grows upward from just above the roll popups; it may only grow
-- to the top of the screen, so the game never has to push it down over the popups. Returns the height
-- available, or nil when the window isn't attached.
local function roomAbovePopups()
	if db.position ~= "attached" then
		return nil
	end
	local bottom -- (the popups' top, in the window's units)
	if popupsOnScreen() then
		bottom = Scale.toMain(GroupLootContainer, GroupLootContainer:GetTop())
	elseif lastPopupSpot then
		bottom = lastPopupSpot[2] / main:GetEffectiveScale()
	elseif bottomContainer() then
		bottom = Scale.toMain(bottomContainer(), bottomContainer():GetTop())
	else
		bottom = Scale.toMain(UIParent, 220)
	end
	local top = UIParent:GetTop()
	return top and (Scale.toMain(UIParent, top) - bottom - 8 - 10) or nil
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
	-- At rest in Blizzard's window layer (MEDIUM, with the character and bag windows), so Options (HIGH) is always in
	-- front: in HIGH it stayed over Options (the panel template's title bar has frame level 510, which Options'
	-- click-to-front can't pass). While a drop waits for your roll it goes up to the roll popups' layer
	-- (History.updateStrata).
	main:SetFrameStrata("MEDIUM")
	main:SetToplevel(true)
	main:SetClampedToScreen(true)
	main:SetMovable(true)
	main:EnableMouse(true)
	main:RegisterForDrag("LeftButton")
	main:SetScript("OnMouseDown", function(self)
		self.pressY = select(2, GetCursorPosition())
	end)
	main:SetScript("OnDragStart", function()
		if History.DRAG_ANYWHERE or History.inTitleBar() then
			History.startMove()
		end
	end)
	main:SetScript("OnDragStop", Guard.wrapCore("move", function(self)
		if not self.moving then
			return -- (a drag that didn't start in the title bar)
		end
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
		titleText = title
	end
	-- Blizzard's own close button for this panel art: its size and corner offsets are the ones Blizzard's windows
	-- use (a plain one sat past the corner). Older clients without it: the plain one.
	local okClose, close = pcall(CreateFrame, "Button", nil, main, "UIPanelCloseButtonDefaultAnchors")
	if not (okClose and close) then
		close = CreateFrame("Button", nil, main, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", 2, 1)
	end
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
			GameTooltip:AddLine("Click to let it hide when idle.", nil, nil, nil, true)
		else
			GameTooltip:SetText("Hides when idle", 1, 1, 1)
			GameTooltip:AddLine(string.format("Hides after %d seconds idle (never under the mouse). Click to keep it open.",
				db.autoHide), nil, nil, nil, true)
		end
		GameTooltip:AddLine("Time: Options, Hide when idle after", 0.6, 0.6, 0.6, true)
		GameTooltip:Show()
	end)
	pin:SetScript("OnLeave", GameTooltip_Hide)
	main.pin = pin

	-- Clear: an X left of the clock (History.placeClock places both).
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
			GameTooltip:AddLine("Removes the made-up drops. Your History isn't touched.", nil, nil, nil, true)
			GameTooltip:Show()
			return
		end
		GameTooltip:SetText("Clear History", 1, 1, 1)
		GameTooltip:AddLine("Removes this character's finished drops from the list and History. Asks first.",
			nil, nil, nil, true)
		GameTooltip:AddLine("Rolls in progress stay.", 0.6, 0.6, 0.6, true)
		GameTooltip:Show()
	end)
	clear:SetScript("OnLeave", GameTooltip_Hide)
	main.clear = clear

	-- History (the clock): shows or hides the drops decided earlier, continuing the list.
	local hist = CreateFrame("Button", nil, main)
	hist:SetSize(16, 16)
	hist:SetPoint("RIGHT", pin, "LEFT", -18, 0) -- (History.placeClock sets its final spot)
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
		GameTooltip:SetText("History", 1, 1, 1)
		if History.shown then
			GameTooltip:AddLine("Click to hide the older drops.", nil, nil, nil, true)
		else
			GameTooltip:AddLine("Shows this character's older drops in the list.", nil, nil, nil, true)
			local fade = tonumber(db.historyFade) or 0
			if fade > 0 then
				GameTooltip:AddLine("They leave again after " .. (fade >= 60 and (fade / 60 .. (fade == 60 and " minute" or " minutes"))
					or (fade .. " seconds")) .. " untouched.", 0.6, 0.6, 0.6, true)
			end
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
	local chromeTarget = 1
	local function setChrome(target)
		if target == chromeTarget then
			return
		end
		chromeTarget = target
		for _, region in ipairs(chrome) do
			History.fade(region, target, 0.25)
		end
	end
	main.setChrome = setChrome
	local watch = CreateFrame("Frame", nil, main)
	-- (10 times a second while the window shows: the chrome of a window that can fade by itself, and the resize
	-- corner, shown only while the mouse is over the window.)
	watch:SetScript("OnUpdate", Guard.wrapUpdate("chrome", function()
		local over = main:IsMouseOver()
		if main.chromeTransient then
			setChrome(over and 1 or CHROME_IDLE_ALPHA)
		end
		History.showGrip(over)
	end, 0.1))
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
	main.empty:SetPoint("TOP", scroll, "TOP", 0, -40) -- (spaced down from the title)
	main.empty:SetText("No loot rolls yet")
	main.emptyHint = main:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	main.emptyHint:SetPoint("TOP", main.empty, "BOTTOM", 0, -4)
	main.emptyHint:SetWidth(WIDTH - 2 * SIDE_PAD - 8) -- wraps inside the window
	main.emptyHint:SetWordWrap(true)
	main.emptyHint:SetJustifyH("CENTER")
	main.emptyHint:SetText("Group loot rolls appear here.")
	-- Shown only while the list is empty and the demo can run (solo).
	main.demoButton = CreateFrame("Button", nil, main, "UIPanelButtonTemplate")
	main.demoButton:SetSize(120, 22)
	main.demoButton:SetPoint("TOP", main.emptyHint, "BOTTOM", 0, -10)
	main.demoButton:SetText("Try the demo")
	main.demoButton:SetScript("OnClick", function()
		History.startDemo()
	end)
	main.demoButton:SetScript("OnEnter", function(self)
		History.tooltipBeside(self, self) -- (beside the window: below the button it covered the link under it)
		GameTooltip:SetText("Try the demo", 1, 1, 1)
		GameTooltip:AddLine("Three made-up drops play out here. Nothing is rolled.", nil, nil, nil, true)
		GameTooltip:AddLine("Also: /rollframes demo", 0.6, 0.6, 0.6, true)
		GameTooltip:Show()
	end)
	main.demoButton:SetScript("OnLeave", GameTooltip_Hide)
	main.demoButton:Hide()
	-- Retires the demo offer for good (saved; /rollframes reset all brings it back).
	local hide = CreateFrame("Button", nil, main)
	main.demoHide = hide
	hide.text = hide:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	hide.text:SetPoint("CENTER")
	hide.text:SetText("Don't show this again")
	local textWidth = hide.text:GetStringWidth()
	hide:SetSize((type(textWidth) == "number" and textWidth > 0 and textWidth or 110) + 12, 18)
	hide:SetPoint("TOP", main.demoButton, "BOTTOM", 0, -8)
	hide:SetScript("OnEnter", function(self)
		self.text:SetTextColor(1, 1, 1)
		History.tooltipBeside(self, self)
		GameTooltip:SetText("Don't show this again", 1, 1, 1)
		GameTooltip:AddLine("Hides this on all your characters.", nil, nil, nil, true)
		GameTooltip:AddLine("Still runs with: /rollframes demo", 0.6, 0.6, 0.6, true) -- (own line: never split mid-command)
		GameTooltip:Show()
	end)
	hide:SetScript("OnLeave", function(self)
		self.text:SetTextColor(1, 0.82, 0)
		GameTooltip_Hide()
	end)
	hide:SetScript("OnClick", Guard.wrap("demo", function()
		History.retireDemoOffer()
	end))
	hide:Hide()
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local range = self:GetVerticalScrollRange()
		self:SetVerticalScroll(math.max(0, math.min(range, self:GetVerticalScroll() - delta * 40)))
	end)

	-- "More to roll" markers at the list's edges while drops with your roll buttons are scrolled out of
	-- view there; a click scrolls to the next one.
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
			GameTooltip:SetText("Drops waiting for your roll", 1, 1, 1)
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
			if History.noFlash() then
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
			-- In the window's right padding (8 px bar, 10 px padding), so rows keep their width; stops above
			-- the resize grip.
			bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 1, 0)
			bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 1, 8)
			if pcall(ScrollUtil.InitScrollFrameWithScrollBar, scroll, bar) then
				scrollBar = bar
				bar:Hide() -- (until the list scrolls: layout)
				bar.wanted = false
				-- Track and thumb only: the arrows are 17 px wide on the 8 px bar, so they reached
				-- over the rows and onto the resize grip. The wheel, dragging the thumb and clicking the track scroll.
				pcall(function()
					for _, stepper in ipairs({ bar.Back, bar.Forward }) do
						if stepper then
							stepper:Hide()
							stepper:EnableMouse(false)
							hooksecurefunc(stepper, "Show", stepper.Hide) -- (if the bar ever shows them again)
						end
					end
					if bar.Track then
						bar.Track:ClearAllPoints()
						bar.Track:SetPoint("TOP")
						bar.Track:SetPoint("BOTTOM")
						-- It's thin: the grab zone reaches 3 px left (still 2 px clear of the roll buttons). The
						-- thumb lights up when the mouse is in it, so what you see matches what you can grab.
						bar.Track:SetHitRectInsets(-3, 0, 0, 0)
						if bar.Track.Thumb then
							bar.Track.Thumb:SetHitRectInsets(-3, 0, 0, 0)
						end
					end
					bar:SetFrameLevel(content:GetFrameLevel() + 5) -- (above the rows' edge it reaches over)
				end)
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

	-- Resize grip: bottom-right when free; top-left when attached, so it grows away from the popups.
	grip = CreateFrame("Button", nil, main)
	grip:SetSize(16, 16)
	grip:SetFrameLevel((main.TitleContainer and main.TitleContainer:GetFrameLevel() or main:GetFrameLevel()) + 5)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	-- While dragging, the corner moves with the mouse, which slips on and off it: its hover (tooltip, outline)
	-- would flicker, so it's held until the mouse is let go, the highlight locked on.
	grip:SetScript("OnEnter", function(self)
		if self:GetScript("OnUpdate") then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Drag to resize", 1, 1, 1)
		GameTooltip:AddLine(db.autoGrow and "Sets how tall it can grow (the outline); then it scrolls."
			or "Sets the window's height; longer lists scroll.", nil, nil, nil, true)
		if db.snapDrag then
			GameTooltip:AddLine("Moves a whole row at a time.", nil, nil, nil, true)
		end
		GameTooltip:AddLine("/rollframes reset: default size and spot", 0.6, 0.6, 0.6, true)
		GameTooltip:Show()
	end)
	grip:SetScript("OnLeave", function(self)
		if self:GetScript("OnUpdate") then
			return
		end
		GameTooltip_Hide()
		History.showLimit(false, 0)
	end)
	grip:HookScript("OnEnter", function(self)
		if not self:GetScript("OnUpdate") then
			History.showLimit(true)
		end
	end)
	grip:SetScript("OnMouseDown", function(self)
		if Guard.off.resize then
			return -- (switched off after an error: no drag that can't run)
		end
		GameTooltip_Hide()
		self:LockHighlight()
		local _, cursorY = GetCursorPosition()
		self.startY, self.startHeight = cursorY, main:GetHeight()
		if db.autoGrow and main.growLimit and main.growLimit > self.startHeight then
			-- Growing with its drops: the drag starts from the limit, not the shorter current window, which opens
			-- to the limit while you drag.
			self.startHeight = main.growLimit
			main:SetHeight(self.startHeight)
		end
		History.showLimit(true)
		self:SetScript("OnUpdate", Guard.wrapUpdate("resize", function()
			local _, y = GetCursorPosition()
			local delta = (y - self.startY) / main:GetEffectiveScale()
			if db.position ~= "attached" then
				delta = -delta -- the grip is at the bottom: dragging down makes it taller
			end
			local maxAllowed = math.max(MIN_HEIGHT, math.min(Scale.screenHeight() - 40, roomAbovePopups() or math.huge))
			local key = db.autoGrow and "maxHeight" or "height" -- the limit when growing; else the fixed height
			local h = math.max(MIN_HEIGHT, math.min(maxAllowed, self.startHeight + delta))
			if db.snapDrag then -- "Snap to whole rows": a row at a time, at each halfway point
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
			if main.limit and main.limit:IsShown() then
				main.limit:SetHeight(db[key]) -- (the outline follows the drag)
			end
		end))
	end)
	grip:SetScript("OnMouseUp", function(self)
		local dragged = self:GetScript("OnUpdate") ~= nil
		self:SetScript("OnUpdate", nil)
		self:UnlockHighlight()
		if dragged and self:IsMouseOver() then
			self:GetScript("OnEnter")(self) -- (its hover was held during the drag)
		end
		layout() -- shrinks back to the drops if they need less than the new limit
		if main.limit and main.limit:IsShown() then
			main.limit:SetHeight(main.growLimit or main:GetHeight()) -- (the limit stays outlined; the window shrinks)
		end
		History.showLimit(false, 0.6) -- (lingers a moment; stays while the mouse is still on the corner)
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

	main:SetScale(Scale.get())
	applyPosition()
end

-- Sets the window to the Window size setting. A dragged window keeps its top-left corner where it is
-- on screen: its saved offsets are in the window's own units, so they're converted to the new size.
-- Attached and never-dragged windows are placed fresh by applyPosition.
function Scale.apply()
	local new, old = Scale.get(), main:GetScale()
	if math.abs(new - old) < 0.001 then
		return
	end
	local p = db.point
	if db.position ~= "attached" and type(p) == "table" and tonumber(p[3]) and tonumber(p[4]) then
		db.point = { p[1], p[2], p[3] * old / new, p[4] * old / new }
	end
	main:SetScale(new)
	applyPosition()
	layout() -- (also re-places the first-use question and the grip)
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
	if mode == "auto" then
		return IsInRaid() and "summary" or "all"
	elseif mode ~= "all" and mode ~= "summary" and mode ~= "none" then
		return "summary" -- (damaged or unknown saved value)
	end
	return mode
end

-- A card's height while its roll is open. It's set by how many players can roll, not by how many have
-- chosen, so it doesn't change as people roll. "reserved" is the most players listed so far, or
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

local function resize(card, instant)
	local to = targetHeight(card)
	if card.height == to then
		return
	end
	local from = card.height or to
	if instant or from == to then
		tweens[card.id .. ":height"] = nil -- (one still running would finish at its old target: Scale.restyleRows)
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
	line:SetPoint("TOPLEFT", card.frame, "TOPLEFT", Scale.iconSize + 12 + (line.slide or 0), -(HEADER_H + (i - 1) * LINE_H))
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

local function placeSummary(card)
	if card.summaryPlaced then
		return
	end
	card.summaryPlaced = true
	-- On the item row's second line (where the winner goes once it's decided), with the roll's timer as a
	-- thin line along the bottom edge under it, so a Summary row keeps one compact height.
	card.waiting:ClearAllPoints()
	card.waiting:SetPoint("BOTTOMLEFT", card.icon, "BOTTOMRIGHT", 6, 4) -- (line 2's column and baseline; the thin timer is below)
	card.waiting:SetPoint("RIGHT", card.frame, "RIGHT", -6, 0)
	if not card.timerThin then
		card.timerThin = true -- (kept across reuse; resetCard puts the normal timer back)
		card.timer:ClearAllPoints()
		card.timer:SetPoint("BOTTOMLEFT", card.frame, "BOTTOMLEFT", Scale.iconSize + 9, 3) -- (above the highlight's 2 px border)
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
	line.bg:SetColorTexture(1, 0.82, 0.2, 0.28) -- (the winner's gold; shown by its alpha, so it can fade natively)
	line.bg:SetAlpha(0)
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
		-- Chosen, no number yet; once the roll is over, a choice that never got one shows "-", not "..." (still
		-- waiting): a Greed when someone needed (only the Need choices roll), or a number the game kept hidden.
		line.roll:SetText(done and "|cff888888-|r" or "|cff888888...|r")
	end
end

-- A soft band crossing `parent`, `times` times (0.7 s each). Kept inside the parent: frames don't clip,
-- so a band starting left of the row drew over the window's edge and flickered.
function History.sweepBand(key, band, parent, width, times)
	local W = 60
	local shownWidth -- (only set again when it changes: at the two ends; mid-row it's 60 throughout)
	local function place(p)
		local x = -W + (width + W) * p
		local left, right = math.max(0, x), math.min(width, x + W)
		if right - left < 1 then
			if band:IsShown() then
				band:Hide()
			end
			return
		end
		band:SetPoint("LEFT", parent, "LEFT", left, 0) -- (its only point: one call a frame)
		local w = math.floor(right - left) -- (down: never past the row's edge)
		if w ~= shownWidth then
			shownWidth = w
			band:SetWidth(w)
		end
		if not band:IsShown() then
			band:Show()
		end
	end
	local function run(n)
		band:ClearAllPoints()
		band:SetHeight(parent:GetHeight() > 0 and parent:GetHeight() or HEADER_H)
		shownWidth = nil
		place(0)
		tween(key, 0.7, function(p)
			place(p)
			band:SetAlpha(1 - p * 0.3)
		end, function()
			band:Hide()
			if n > 1 then
				run(n - 1)
			end
		end, true)
	end
	run(times)
end

-- Native sweep: an AnimationGroup moves the band, so nothing runs per frame. It slides inside a frame
-- that clips to its target, so it can start and end outside it. Sweep frames are pooled (borrowed
-- for 0.7 s), not one per row or line. Clients without it use History.sweepBand.
History.sweepPool = {}
function History.takeSweep()
	local sweep = table.remove(History.sweepPool)
	if sweep or History.noNativeSweep then
		return sweep
	end
	local ok, made = pcall(function()
		local clip = CreateFrame("Frame", nil, main)
		clip:SetClipsChildren(true)
		local mover = CreateFrame("Frame", nil, clip)
		local band = mover:CreateTexture(nil, "OVERLAY")
		band:SetAllPoints()
		band:SetTexture("Interface\\Buttons\\WHITE8X8")
		band:SetBlendMode("ADD")
		local group = mover:CreateAnimationGroup()
		local move = group:CreateAnimation("Translation")
		move:SetDuration(0.7)
		local fade = group:CreateAnimation("Alpha")
		fade:SetFromAlpha(1)
		fade:SetToAlpha(0.7)
		fade:SetDuration(0.7)
		local sweep = { clip = clip, mover = mover, band = band, group = group, move = move }
		local function done()
			History.giveBackSweep(sweep)
		end
		group:SetScript("OnFinished", done)
		group:SetScript("OnStop", done)
		return sweep
	end)
	if not ok then
		History.noNativeSweep = true -- (this client can't: the Lua sweep from now on)
		return nil
	end
	return made
end

function History.giveBackSweep(sweep)
	if not sweep.target then
		return -- (already back)
	end
	if sweep.target.rfSweep == sweep then
		sweep.target.rfSweep = nil
	end
	sweep.target = nil
	sweep.mover:Hide()
	sweep.clip:Hide()
	History.sweepPool[#History.sweepPool + 1] = sweep
end

-- One sweep across `target` (a row or a player line), in the given colour: native where it can, else the Lua
-- band `fallback`, coloured here.
function History.playSweep(key, target, fallback, width, r, g, b, a)
	History.stopSweep(target)
	if not (main and main:IsVisible()) then
		return -- (nobody can see it: a closed window, or the UI hidden)
	end
	local sweep = History.takeSweep()
	if not sweep then
		if not pcall(fallback.SetGradient, fallback, "HORIZONTAL", CreateColor(r, g, b, 0), CreateColor(r, g, b, a)) then
			fallback:SetColorTexture(r, g, b, a * 0.6)
		end
		History.sweepBand(key, fallback, target, width, 1)
		return
	end
	sweep.target, target.rfSweep = target, sweep
	sweep.clip:SetParent(target)
	sweep.clip:ClearAllPoints()
	sweep.clip:SetAllPoints(target)
	if not pcall(sweep.band.SetGradient, sweep.band, "HORIZONTAL", CreateColor(r, g, b, 0), CreateColor(r, g, b, a)) then
		sweep.band:SetColorTexture(r, g, b, a * 0.6)
	end
	sweep.mover:ClearAllPoints()
	sweep.mover:SetPoint("TOPRIGHT", target, "TOPLEFT") -- (starts just left of it, clipped out of sight)
	sweep.mover:SetPoint("BOTTOMRIGHT", target, "BOTTOMLEFT")
	sweep.mover:SetWidth(60)
	sweep.move:SetOffset(width + 60, 0)
	sweep.clip:Show()
	sweep.mover:Show()
	sweep.group:Play()
end

function History.stopSweep(target)
	local sweep = target.rfSweep
	if sweep then
		sweep.group:Stop()
		History.giveBackSweep(sweep) -- (in case Stop fired nothing: it wasn't playing yet)
	end
end

-- A 100: the action-button proc glow (Blizzard's flipbooks, played by the engine) on the choice icon: the
-- burst, three turns of the loop, the last fading. Pooled like the sweep. Flashing Off: the still glow
-- Blizzard uses when it tones proc glows down, for the same time.
History.GLOW_LOOPS = 3
History.glowPool = {}
function History.takeGlow()
	local glow = table.remove(History.glowPool)
	if glow or History.noGlow then
		return glow
	end
	local ok, made = pcall(function()
		local f = CreateFrame("Frame", nil, main)
		local burst = f:CreateTexture(nil, "OVERLAY")
		burst:SetAtlas("UI-HUD-ActionBar-Proc-Start-Flipbook")
		burst:SetPoint("CENTER")
		burst:SetAlpha(0)
		local loop = f:CreateTexture(nil, "OVERLAY")
		loop:SetAtlas("UI-HUD-ActionBar-Proc-Loop-Flipbook")
		loop:SetAllPoints()
		loop:SetAlpha(0)
		local still = f:CreateTexture(nil, "OVERLAY")
		still:SetAtlas("UI-HUD-RotationHelper-ProcAltGlow")
		still:SetPoint("CENTER")
		local group = f:CreateAnimationGroup()
		group:SetToFinalAlpha(true)
		local function alpha(tex, order, from, to, duration)
			local a = group:CreateAnimation("Alpha")
			a:SetTarget(tex)
			a:SetOrder(order)
			a:SetFromAlpha(from)
			a:SetToAlpha(to)
			a:SetDuration(duration or 0.001)
		end
		local function flip(tex, order, duration)
			local a = group:CreateAnimation("FlipBook")
			a:SetTarget(tex)
			a:SetOrder(order)
			a:SetDuration(duration)
			a:SetFlipBookRows(6)
			a:SetFlipBookColumns(5)
			a:SetFlipBookFrames(30)
			a:SetFlipBookFrameWidth(0)
			a:SetFlipBookFrameHeight(0)
		end
		-- (Blizzard's timing: a 0.7 s burst, then a 1 s loop.)
		alpha(burst, 1, 1, 1)
		flip(burst, 2, 0.7)
		alpha(burst, 3, 1, 0)
		alpha(loop, 3, 1, 1)
		for i = 1, History.GLOW_LOOPS do
			flip(loop, 3 + i, 1)
		end
		alpha(loop, 3 + History.GLOW_LOOPS, 1, 0, 1)
		local glow = { frame = f, burst = burst, loop = loop, still = still, group = group }
		local function done()
			History.giveBackGlow(glow)
		end
		group:SetScript("OnFinished", done)
		group:SetScript("OnStop", done)
		return glow
	end)
	if not ok then
		History.noGlow = true -- (this client can't: no glow from now on)
		return nil
	end
	return made
end

function History.giveBackGlow(glow)
	if not glow.target then
		return -- (already back)
	end
	if glow.target.rfGlow == glow then
		glow.target.rfGlow = nil
	end
	glow.target = nil
	glow.frame:Hide()
	History.glowPool[#History.glowPool + 1] = glow
end

function History.stopGlow(icon)
	local glow = icon.rfGlow
	if glow then
		glow.group:Stop()
		History.giveBackGlow(glow)
	end
end

function History.playGlow(icon)
	History.stopGlow(icon)
	if not (main and main:IsVisible() and icon:IsShown()) then
		return
	end
	local glow = History.takeGlow()
	if not glow then
		return
	end
	glow.token = (glow.token or 0) + 1 -- (a still glow's timer ends only its own play)
	glow.target, icon.rfGlow = icon, glow
	local s = icon:GetWidth() > 0 and icon:GetWidth() or 14
	local f = glow.frame
	f:SetParent(icon:GetParent())
	f:SetFrameLevel(icon:GetParent():GetFrameLevel() + 5)
	f:ClearAllPoints()
	f:SetPoint("CENTER", icon)
	f:SetSize(s * 1.4, s * 1.4) -- (Blizzard's sizes, for a 45 px button: this frame 1.4x, the burst 150 px)
	glow.burst:SetSize(s * 150 / 45, s * 150 / 45)
	f:Show()
	if History.noFlash() then
		glow.burst:SetAlpha(0)
		glow.loop:SetAlpha(0)
		local info = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("UI-HUD-RotationHelper-ProcAltGlow")
		if info and info.width then
			glow.still:SetSize(info.width * s / 45, info.height * s / 45)
		else
			glow.still:SetSize(s * 1.6, s * 1.6)
		end
		glow.still:Show()
		local token = glow.token
		C_Timer.After(0.7 + History.GLOW_LOOPS, function()
			if glow.target == icon and glow.token == token then
				History.giveBackGlow(glow)
			end
		end)
		return
	end
	glow.still:Hide()
	glow.group:Play()
end

-- Every 100 the drop shows when its roll ends: on the player lines (Detailed), else the winner's.
function History.glowHundreds(card)
	if card.instant then
		return -- (decided before a reload: not new)
	end
	if card.linesMode == "all" then
		for _, line in pairs(card.lines) do
			local e = line.entry
			if e and tonumber(e.roll) == 100 and e.state ~= STATE.PASS then
				History.playGlow(line.icon)
			end
		end
	elseif card.winner and tonumber(card.winner.roll) == 100 then
		History.playGlow(card.winnerIcon)
	end
end

local function playWinnerSweep(card, line)
	line.check:Show()
	if History.noFlash() or not db.resultSweep then -- highlighted at once, no sweep
		History.setAlpha(line.bg, 1)
		return
	end
	-- The line's gold comes in once the sweep has crossed it, not during.
	History.setAlpha(line.bg, 0)
	local gen = card.gen
	C_Timer.After(0.7, function()
		if card.gen == gen and line.entry and card.winnerKey and card.lines[card.winnerKey] == line then
			History.fade(line.bg, 1, 0.3)
		end
	end)
	local width = line:GetWidth() > 0 and line:GetWidth() or (WIDTH - Scale.iconSize - 40)
	History.playSweep(card.id .. ":shine", line, line.shine, width, 1, 0.85, 0.4, 0.7) -- (one pass)
end

-- MEDIUM normally (Options, in HIGH, stays in front). While a drop waits for your roll, DIALOG,
-- the roll popups' layer, so nothing ordinary covers it.
function History.updateStrata()
	if not main then
		return
	end
	local waiting = false
	if History.rollsHere() and not Guard.fallback then
		for _, card in ipairs(cards) do
			if card.buttons and card.buttons:IsShown() and card.frame:IsShown() and not card.dismissing then
				waiting = true
				break
			end
		end
	end
	local want = waiting and "DIALOG" or "MEDIUM"
	if main.strataNow ~= want then
		main.strataNow = want
		main:SetFrameStrata(want)
		if waiting then
			main:Raise()
		end
	end
end

-- The empty window's text block: the two lines, and the demo offer under them when it shows.
function History.emptyBlockH()
	local offer = not db.demoHidden and History.canDemo()
	return offer and 88 or 30 -- (14 + 4 + 12, then 10 + 22 + 8 + 18 for the button and the link)
end

-- With "Grow with drops", the height the window may grow to is a promise of screen space,
-- but the window is usually shorter. While the corner is dragged or hovered, a faint outline shows that height;
-- after a drag the window shrinks to its drops and the outline lingers a moment, then fades.
function History.showLimit(on, hold)
	if not (main and grip) then
		return
	end
	local dragging = grip:GetScript("OnUpdate") ~= nil
	if on and db.autoGrow then
		local o = main.limit
		if not o then
			o = CreateFrame("Frame", nil, main)
			o:SetFrameLevel(math.max(0, main:GetFrameLevel() - 1))
			o:EnableMouse(false)
			o.fill = o:CreateTexture(nil, "BACKGROUND")
			o.fill:SetAllPoints()
			o.fill:SetColorTexture(1, 1, 1, 0.04)
			for _, side in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
				{ "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false } }) do
				local e = o:CreateTexture(nil, "BORDER")
				e:SetPoint(side[1])
				e:SetPoint(side[2])
				if side[3] then e:SetHeight(1) else e:SetWidth(1) end
				e:SetColorTexture(1, 1, 1, 0.45)
			end
			main.limit = o
		end
		o:ClearAllPoints()
		if anchorFactor == 1 then -- (grows upward)
			o:SetPoint("BOTTOMLEFT", main, "BOTTOMLEFT")
			o:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT")
		else
			o:SetPoint("TOPLEFT", main, "TOPLEFT")
			o:SetPoint("TOPRIGHT", main, "TOPRIGHT")
		end
		o:SetHeight(dragging and main:GetHeight() or main.growLimit or main:GetHeight())
		History.limitGen = (History.limitGen or 0) + 1
		History.setAlpha(o, 1)
		o:Show()
		return
	end
	local o = main.limit
	if not (o and o:IsShown()) or dragging or (grip:IsMouseOver() and db.autoGrow) then
		return
	end
	History.limitGen = (History.limitGen or 0) + 1
	local gen = History.limitGen
	local function fade()
		if gen ~= History.limitGen then
			return -- (shown again meanwhile)
		end
		History.fade(o, 0, 0.3, function()
			o:Hide()
		end)
	end
	if (hold or 0) > 0 then
		C_Timer.After(hold, fade)
	else
		fade()
	end
end

-- The resize corner shows while the mouse is over the window (or a drag is on), fading in and out.
function History.showGrip(over)
	if not grip then
		return
	end
	local want = (over or grip:GetScript("OnUpdate") ~= nil) and 1 or 0
	if History.gripWant == want then
		return
	end
	History.gripWant = want
	History.fade(grip, want, 0.2)
end

-- The clock (History) sits over the Need column (the leftmost roll button) at every Roll buttons size, so the
-- title bar lines up with the drops below; without roll buttons, over Medium's. Placed from the
-- close button (Blizzard's, at its own corner offsets), so it shares the title bar's middle line.
function History.placeClock()
	local hist, close = main and main.hist, main and main.closeButton
	if not (hist and close) then
		return
	end
	local look = History.rollsHere() and Scale.look() or Scale.LOOK.medium
	local needCenter = SIDE_PAD + 4 + 2 * look.step + look.size / 2 -- (from the window's right edge)
	local _, _, _, closeX = close:GetPoint(1)
	local closeW = close:GetWidth()
	if type(closeW) ~= "number" or closeW <= 0 or closeW > 40 then
		closeW = 24
	end
	local closeLeft = (tonumber(closeX) or 0) - closeW -- (its left edge, from the window's right edge)
	-- The clear X hugs the clock's left (it belongs to History and shows only with it). With big roll buttons
	-- that reaches the title, so the clock moves over Greed, the X still beside it.
	local titleW = main.titleText and main.titleText.GetStringWidth and main.titleText:GetStringWidth()
	if type(titleW) ~= "number" or titleW <= 0 then
		titleW = 60
	end
	local titleRight = (WIDTH - 30 - 24) / 2 + 24 - titleW / 2 -- (the title's right end, from the window's right edge)
	local clockCenter = needCenter
	if needCenter + 8 + 4 + 14 + 4 > titleRight then
		clockCenter = SIDE_PAD + 4 + look.step + look.size / 2 -- Greed
	end
	hist:ClearAllPoints()
	hist:SetPoint("RIGHT", close, "LEFT", (8 - clockCenter) - closeLeft, 0) -- (16 px: its right edge 8 past the centre)
	local clear = main.clear
	if clear then
		clear:ClearAllPoints()
		clear:SetPoint("RIGHT", hist, "LEFT", -4, 0)
	end
end

-- The Summary counts line: one text per choice in a fixed column (Need, Greed, Pass, then rare
-- Transmog), so a column always holds the same choice. SetText("") clears it, like the old single text.
History.COUNT_COLUMN = 30 -- px per column: a 12 px icon, a space and up to two digits (a raid's 40)
History.COUNT_STATES = { STATE.NEED, STATE.GREED, STATE.PASS, STATE.TRANSMOG }
function History.countsLine(parent)
	local line = CreateFrame("Frame", nil, parent)
	line:SetHeight(12)
	line.slots = {}
	for i, state in ipairs(History.COUNT_STATES) do
		local slot = line:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		slot:SetPoint("BOTTOMLEFT", line, "BOTTOMLEFT", (i - 1) * History.COUNT_COLUMN, 0)
		slot:SetJustifyH("LEFT")
		slot:SetWordWrap(false)
		slot.shownText = "" -- (starts blank)
		slot.icon = "|A:" .. STATE_ATLAS[state] .. ":12:12:0:0:153:153:153|a "
		line.slots[i] = slot
	end
	line.dots = line:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall") -- ("..." before anyone has chosen)
	line.dots:SetPoint("BOTTOMLEFT")
	local function put(slot, n) -- (only a changed count is written)
		local text = n > 0 and (slot.icon .. n) or ""
		if slot.shownText ~= text then
			slot.shownText = text
			slot:SetText(text)
		end
	end
	function line:SetCounts(need, greed, pass, transmog)
		put(self.slots[1], need)
		put(self.slots[2], greed)
		put(self.slots[3], pass)
		put(self.slots[4], transmog)
		local dots = (need + greed + pass + transmog) > 0 and "" or "..."
		if self.dots.shownText ~= dots then
			self.dots.shownText = dots
			self.dots:SetText(dots)
		end
	end
	function line:SetText(text) -- (only ever "": clear; pieces already blank are left alone)
		for _, slot in ipairs(self.slots) do
			if slot.shownText ~= "" then
				slot.shownText = ""
				slot:SetText("")
			end
		end
		text = text or ""
		if self.dots.shownText ~= text then
			self.dots.shownText = text
			self.dots:SetText(text)
		end
	end
	return line
end

-- Your wins keep a faint gold tint once they're compact rows, and in History:
-- WIN_TINT while the result shows, KEPT_TINT after. One colour for both, here.
History.WIN_COLOR = { 1, 0.82, 0.2 }
History.WIN_TINT, History.KEPT_TINT = 0.18, 0.10
function History.setTint(texture, alpha)
	local c = History.WIN_COLOR
	History.setAlpha(texture, 1)
	texture:SetColorTexture(c[1], c[2], c[3], alpha)
	texture.rfLevel = alpha
end

-- The tint's level is its colour's alpha times its own. A change fades its own alpha (natively), with the
-- colour at the higher of the two levels.
function History.tintLevel(texture)
	return texture:IsShown() and (texture.rfLevel or 0) * History.shownAlpha(texture) or 0
end

function History.fadeTint(texture, to, duration, done)
	local from = History.tintLevel(texture)
	local top = math.max(from, to)
	if top <= 0 then
		History.setTint(texture, 0)
		if done then done() end
		return
	end
	History.setTint(texture, top)
	History.fade(texture, to / top, duration, done, from / top)
end

-- Result sweep across a row without player lines: gold plus a lasting tint for your win, grey for
-- someone else's. Flashing Off or sweeps off: no motion (your win still gets the tint).
function History.playRowSweep(card, lost)
	local f = card.frame
	if not card.winTint then -- (made the first time this card shows a result sweep; kept for reuse)
		card.winTint = f:CreateTexture(nil, "BACKGROUND", nil, 1)
		card.winTint:SetAllPoints()
		card.rowShine = f:CreateTexture(nil, "OVERLAY")
		card.rowShine:SetTexture("Interface\\Buttons\\WHITE8X8")
		card.rowShine:SetBlendMode("ADD")
		if not pcall(card.rowShine.SetGradient, card.rowShine, "HORIZONTAL",
			CreateColor(1, 0.85, 0.4, 0), CreateColor(1, 0.85, 0.4, 0.7)) then
			card.rowShine:SetColorTexture(1, 0.85, 0.4, 0.4)
		end
	end
	if card.rowShine:IsShown() then
		card.rowShine:Hide()
	end
	-- Someone else won: a grey band, no tint. Yours: gold, and the tint. (The band's colour is set by
	-- History.playSweep, only if this client needs the Lua band.)
	local shade = lost and 0.75 or nil
	-- No motion: Flashing Off, sweeps turned off, or nobody can see it (a closed window: the end state at once).
	local still = History.noFlash() or not db.resultSweep or not (main and main:IsVisible())
	if lost then
		card.winTint:Hide()
		if still then
			return -- (the row already says who won)
		end
	else
		card.winTint:Show()
		if still then
			History.setTint(card.winTint, History.WIN_TINT)
			return
		end
		-- The tint comes in once the sweep has crossed the row, not during.
		History.setTint(card.winTint, 0)
		local gen = card.gen
		C_Timer.After(0.7, function()
			if card.gen == gen and not card.collapsed and card.winTint:IsShown() then
				History.fadeTint(card.winTint, History.WIN_TINT, 0.3)
			end
		end)
	end
	local width = f:GetWidth() > 0 and f:GetWidth() or (WIDTH - 2 * SIDE_PAD)
	History.playSweep(card.id .. ":rowshine", f, card.rowShine, width, shade or 1, shade or 0.85, shade or 0.4,
		lost and 0.45 or 0.7)
end

-- A drop you won becoming a compact row: its tint settles to the kept one (fading), made here if the drop
-- never swept (Everyone, sweeps off, or decided before a reload).
function History.keepWinTint(card)
	History.stopSweep(card.frame)
	if not card.winTint then
		card.winTint = card.frame:CreateTexture(nil, "BACKGROUND", nil, 1)
		card.winTint:SetAllPoints()
		card.rowShine = card.frame:CreateTexture(nil, "OVERLAY")
		card.rowShine:SetTexture("Interface\\Buttons\\WHITE8X8")
		card.rowShine:SetBlendMode("ADD")
		card.rowShine:Hide()
	end
	if card.instant then
		card.winTint:Show()
		History.setTint(card.winTint, History.KEPT_TINT)
		return
	end
	History.fadeTint(card.winTint, History.KEPT_TINT, 0.35) -- (from where it is: hidden counts as none)
	card.winTint:Show()
end

-- The win tint and sweep off. When the row collapses the tint fades out like the window's other fades;
-- a card going back to the pool clears at once.
function History.clearRowSweep(card, fade)
	History.stopSweep(card.frame)
	if not card.winTint then
		return
	end
	tweens[card.id .. ":rowshine"] = nil
	if card.rowShine:IsShown() then
		card.rowShine:Hide()
	end
	if not card.winTint:IsShown() then
		return -- (no tint to clear: most drops; a tint is set again before it shows)
	end
	if fade and History.tintLevel(card.winTint) > 0 then
		History.fadeTint(card.winTint, 0, 0.35, function()
			card.winTint:Hide()
		end)
	else
		card.winTint:Hide()
		History.setTint(card.winTint, 0)
	end
end

-- True when the player keeps only better items in the history and this one's quality is known to be lower.
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

-- The card under the cursor while it shows your roll buttons. It holds still: whatever else
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
	if not (History.rollsHere() and main and main:IsVisible() and scroll:IsMouseOver()) then
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
		end, 0.1))
	end
	holdWatch:Show()
end

-- The winner line in two columns: the roll left-aligned in a fixed box right after the icon, the name after it, so names line up
-- down the list whatever the numbers. text is the combined "<roll>  <name>" kept in History records; without a
-- roll ("All passed", "Winner unknown") the text starts where the roll box does.
History.ROLL_W, History.ROLL_W3 = 13, 18 -- two-digit and "100" boxes, until measured (History.rollWidth)
-- Boxes measured in the game's font: the column fits "100", numbers right-aligned in it.
function History.rollWidth(fs)
	if not History.rollMeasured then
		local ok, two, three = pcall(function()
			fs:SetText("99")
			local a = fs:GetStringWidth()
			fs:SetText("100")
			local b = fs:GetStringWidth()
			fs:SetText("")
			return a, b
		end)
		if ok and type(two) == "number" and two > 0 and type(three) == "number" and three > 0 then
			History.ROLL_W, History.ROLL_W3 = math.ceil(two) + 1, math.ceil(three) + 1
			History.rollMeasured = true
		end
	end
	return History.ROLL_W
end
History.ROLL_COLUMN = false -- roll and name as one text; true: the roll in its own column (dev: /rollframes columns)
-- Your choice's icon takes the right-hand button's spot; "…" and then your roll sit centred in the column
-- left of it (the Greed button's), so they line up down the list whatever their width.
function History.placeMine(card, look)
	look = look or card.look or Scale.look()
	if card.mineStep == look.step and card.mineTop == look.top then
		return -- (unchanged: your roll updates often)
	end
	card.mineStep, card.mineTop = look.step, look.top
	card.mineIcon:ClearAllPoints()
	card.mineIcon:SetPoint("TOPRIGHT", card.frame, "TOPRIGHT", -4, look.top)
	card.mineRoll:ClearAllPoints()
	card.mineRoll:SetPoint("CENTER", card.frame, "TOPRIGHT", -4 - look.step - look.size / 2, look.top - look.size / 2)
end

-- The roll ended: your choice and roll fade out with the result sweep (gone as it finishes), or in 0.3 s
-- without one. The item level moves to the row's edge only after, so it never slides over them.
function History.fadeMine(card)
	if not card.mineIcon:IsShown() or card.instant or not main:IsVisible() then
		card.mineIcon:Hide()
		card.mineRoll:Hide()
		placeHeader(card)
		return
	end
	if card.mineState ~= STATE.PASS and card.mineRollShown == nil then
		card.mineRoll:SetText("|cff888888-|r") -- (a choice that never got a number, as on its player line)
	end
	local sweeps = card.winner and db.resultSweep and not History.noFlash()
	local gen = card.gen
	local function gone() -- (their alphas are set back when they show again: setMine)
		if card.gen == gen and card.finished then
			card.mineIcon:Hide()
			card.mineRoll:Hide()
			placeHeader(card)
		end
	end
	local duration = sweeps and 0.7 or 0.3
	History.fade(card.mineIcon, 0, duration, gone, 0.35) -- (from their resting alphas: no reads)
	History.fade(card.mineRoll, 0, duration, nil, 1)
end

-- The window moves only from its title bar, so a near miss of the resize corner (or any edge) doesn't drag
-- it away. DRAG_ANYWHERE: the whole window, for a frameless style.
History.DRAG_ANYWHERE = false
function History.inTitleBar()
	local top = main:GetTop()
	local y = main.pressY -- (where the press was: the drag starts a few pixels later)
	if not y then
		y = select(2, GetCursorPosition())
	end
	if not (top and y) then
		return true
	end
	return y / main:GetEffectiveScale() >= top - TITLE_H
end

function History.startMove()
	db.position = "free"
	main:StartMoving()
	main.moving = true -- (see the window's OnHide: a drag cut short by the window hiding still ends)
end

-- Shift-click links, Ctrl-click previews. In combat the game won't open a window for an addon ("Interface
-- action failed"), so a click that would have to open the dressing room does nothing; one already open
-- still takes the item.
function History.itemClick(link)
	if InCombatLockdown() and not IsModifiedClick("CHATLINK")
		and not (IsModifiedClick("DRESSUP") and DressUpFrame and DressUpFrame:IsShown()) then
		return
	end
	HandleModifiedItemClick(link)
end

function History.setWinnerLine(rollFS, nameFS, anchor, text)
	local icon = rollFS.choiceIcon
	if icon and icon.inColumn ~= History.ROLL_COLUMN then
		-- (beside the text it precedes: an empty roll text has no height, so beside it the icon sits low)
		icon.inColumn = History.ROLL_COLUMN
		icon:ClearAllPoints()
		if History.ROLL_COLUMN then
			icon:SetPoint("RIGHT", rollFS, "LEFT", -2, 0)
		else
			icon:SetPoint("RIGHT", nameFS, "LEFT", -4, 0)
		end
	end
	if nameFS.lineText == text then
		return -- (unchanged: updates come often)
	end
	nameFS.lineText = text
	if not History.ROLL_COLUMN then
		if rollFS.hasText then -- (only after the column layout was tried: dev builds)
			rollFS.hasText = nil
			rollFS:SetText("")
		end
		nameFS:SetText(text or "")
		if not nameFS.plainPlaced then
			nameFS.plainPlaced = true
			nameFS:SetPoint("BOTTOMLEFT", anchor, "BOTTOMRIGHT", 24, 4)
		end
		return
	end
	nameFS.plainPlaced = nil
	local roll, name = (text or ""):match("^|cffffd100(%d+)|r  (.*)$")
	local box = History.ROLL_W3 -- (room for "100"; the numbers sit right-aligned in it, so their last digits line up)
	rollFS:SetWidth(box)
	rollFS:SetText(roll or "")
	rollFS.hasText = roll ~= nil
	nameFS:SetText(name or text or "")
	nameFS:SetPoint("BOTTOMLEFT", anchor, "BOTTOMRIGHT", roll and (22 + box + 3) or 22, 4)
end

-- Fills the item row's bottom line with the winner (or "All passed").
local function updateHeaderWinner(card)
	if card.rollEnded and not card.winner and not card.allPassed then
		card.winnerFull = "|cff888888Winner unknown|r"
		card.winnerIcon:Hide()
	elseif card.allPassed then
		card.winnerFull = "|cffff5555All passed|r"
		card.winnerIcon:SetAtlas(STATE_ATLAS[STATE.PASS]) -- (an icon like a winner's, so the text lines up)
		card.winnerIcon:Show()
	elseif card.winner then
		local w = card.winner
		card.winnerFull = (w.roll and ("|cffffd100" .. w.roll .. "|r  ") or "") .. classColored(w.name, w.class)
			.. (w.isSelf and " |A:common-icon-checkmark:12:12|a" or "") -- (yours: not by colour alone)
		card.winnerIcon:SetAtlas(STATE_ATLAS[w.state] or STATE_ATLAS[STATE.GREED])
		card.winnerIcon:Show()
	end
	History.setWinnerLine(card.winnerRoll, card.winnerText, card.icon, card.winnerFull)
end

-- Fades the winner in on the item row (from wherever it is, so a winner already showing doesn't flicker).
local function showHeaderWinner(card)
	updateHeaderWinner(card)
	if card.winnerText:GetAlpha() >= 1 then
		return -- showing, or fading in (Summary and None show it before the collapse)
	end
	local from = History.shownAlpha(card.winnerText)
	History.fade(card.winnerText, 1, 0.35, nil, from)
	History.fade(card.winnerRoll, 1, 0.35, nil, from)
	History.fade(card.winnerIcon, 1, 0.35, nil, from)
end

-- Frame pools (see "Frame reuse" below); declared here so a collapsing drop can give its lines back.
local cardPool, linePool = {}, {}

-- Gives a drop's player lines back to the pool (a compact row has none; a redraw in another "Player lines"
-- mode starts again), stopping any animation still holding one (slide-in, winner sweep) first.
local function releaseLines(card)
	local prefix = card.id .. ":"
	for key in pairs(tweens) do
		if key:sub(1, #prefix) == prefix and (key:sub(-3) == ":in" or key == prefix .. "winbg"
			or key == prefix .. "shine" or key == prefix .. "linesout") then
			tweens[key] = nil
		end
	end
	for _, line in pairs(card.lines) do
		History.stopGlow(line.icon)
		History.stopFade(line)
		History.stopFade(line.bg)
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
	if card.winner and card.winner.isSelf then
		History.keepWinTint(card) -- (yours: a faint tint stays)
	else
		History.clearRowSweep(card, true)
	end
	local keepSummary = card.linesMode == "summary" -- (its counts line stays, see targetHeight)
	-- (lastRolls stays in every mode: hovering a finished drop lists its rolls)
	trimPending = true
	driver:Show() -- (the trim runs there, even with the window hidden)
	card.timer:Hide()
	card.buttons:Hide()
	card.mineIcon:Hide()
	card.mineRoll:Hide()
	placeHeader(card)
	showHeaderWinner(card)
	if card.bossName then
		card.boss:SetText(card.bossName)
		History.fitBoss(card.boss, card.winnerText, 0)
		card.boss:Show()
		card.winnerText:SetPoint("RIGHT", card.boss, "LEFT", -6, 0)
	end
	card.collapsedAt = GetTime()
	Guard.call("history", History.record, card)
	if keepSummary then
		History.setAlpha(card.waiting, 0)
	else
		History.fade(card.waiting, 0, 0.35)
	end
	-- A late player still sliding in: settle it, or its slide-in and the fade-out would both set its alpha.
	local prefix = card.id .. ":"
	for key in pairs(tweens) do
		if key:sub(1, #prefix) == prefix and key:sub(-3) == ":in" then
			tweens[key] = nil
		end
	end
	for _, line in pairs(card.lines) do
		if line.slide and line.slide ~= 0 then
			line.slide = 0
			placeLine(card, line, line.index)
		end
	end
	History.fadeLinesOut(card)
	local gen = card.gen
	local function done()
		if card.gen == gen and card.collapsed then
			releaseLines(card) -- (a compact row keeps no player lines: up to 40 frames each in a raid)
			if not keepSummary then
				card.waiting:Hide()
			end
		end
	end
	if Guard.off.animations or db.noMotion or not main:IsVisible() then
		done() -- (nothing to see: the lines go back to the pool now)
	else
		C_Timer.After(0.35, done)
	end
	resize(card)
end

local refreshSummary -- forward declaration (defined with the roll lines)

local function finish(card)
	if card.finished then
		return
	end
	card.finished = true
	if card.demo then
		History.checkDemoDone() -- (the last made-up drop decided: the demo leaves a little later)
	end
	if not card.demo and not card.instant then -- (a drop replayed already decided, e.g. after /reload, isn't new loot)
		Ask.lootAt = GetTime() -- (the first-use question never shows right after loot)
	end
	lastActivity = GetTime()
	card.timer:Hide()
	card.buttons:Hide()
	if card.linesMode == "all" then
		History.fadeMine(card) -- (as in the other views: gone with the result sweep)
		if card.winnerKey and card.lines[card.winnerKey] then
			playWinnerSweep(card, card.lines[card.winnerKey])
		end
		for _, line in pairs(card.lines) do -- "..." becomes "no roll" (never chose) or "-" (chose, no number)
			if line.entry and line.entry.state ~= STATE.PASS and not line.entry.roll then
				updateLineText(card, line, line.entry)
			end
		end
	else
		-- No player lines to highlight: the winner shows on the item row straight away. (Summary: in the
		-- counts' place on the second line; they stay, unseen, for the hover.)
		History.fadeMine(card)
		showHeaderWinner(card)
		refreshSummary(card)
		if card.winner and not card.instant then
			History.playRowSweep(card, not card.winner.isSelf) -- (gold for your win, grey for someone else's)
		end
		if card.linesMode == "summary" then
			History.fade(card.waiting, 0, 0.25)
		end
	end
	History.glowHundreds(card)
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
-- Twins: two or more copies of one item whose rolls start at the same moment. The game can't say
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
		-- Prefer the copy whose pending choice matches the report, else any pending one.
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

-- Bind-on-pickup rolls need a confirm (CONFIRM_LOOT_ROLL). If its popup closes without one, no roll was
-- made: the roll goes back to the buttons or twins pool. A confirmed roll stays taken until reported.
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
		return
	end
	awaitingConfirm[rollID] = false
	if not confirmWatch then
		confirmWatch = CreateFrame("Frame")
		confirmWatch:SetScript("OnUpdate", Guard.wrapCoreUpdate("confirm", function(self) -- only while a confirmation is open
			if StaticPopup_Visible("CONFIRM_LOOT_ROLL") then
				for id in pairs(awaitingConfirm) do
					awaitingConfirm[id] = true
				end
				return
			end
			self:Hide()
			for id, seen in pairs(awaitingConfirm) do
				awaitingConfirm[id] = nil
				if seen and not confirmedRolls[id] then
					releaseRoll(id)
				end
			end
		end, 0.25))
	end
	confirmWatch:Show()
end

local function cardRollTypes(card)
	local rollID = card.rollID
	if not rollID and card.twins then
		local open = twinOpenRoll(card.twins, nil) -- own roll ended: the one a click would use
		rollID = type(open) == "number" and open or nil
	end
	-- Shared scratch table, refilled each call: callers must not keep it.
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
	local look = Scale.look() -- restyled later by Scale.styleCard
	bar:SetSize(3 * look.step, look.size) -- (4 steps on a roll that allows Transmog)
	bar:SetPoint("TOPRIGHT", card.frame, "TOPRIGHT", -4, look.top)
	bar.list = {}
	bar:SetScript("OnShow", function()
		bar.shownAt = GetTime() -- OnClick ignores presses from before this
		Scale.refreshGlow(card) -- (a reused drop: its last guard's dimmed highlight back)
		History.updateStrata()
		requestMarkers()
	end)
	bar:SetScript("OnHide", function()
		local hovered = History.hoverButton
		if hovered and hovered:GetParent() == bar then -- (only this drop's: another's may be under the mouse)
			History.hoverButton = nil
			History.hideButtonTip()
		end
		Scale.refreshGlow(card) -- (hidden: unlit, so a reused drop's buttons come back unlit)
		History.updateStrata()
		requestMarkers()
	end)
	-- Built lazily by refreshButtons: with "Roll from this window" off (the default) they never are.
	function bar.build()
		bar.build = nil
		for _, spec in ipairs(ROLL_BUTTONS) do
			local button = CreateFrame("Button", nil, bar)
			local look = Scale.look() -- the card may have been restyled since the bar was made
			button:SetSize(look.size, look.size)
			button:SetPoint("RIGHT", bar, "RIGHT", -spec.spot * look.step, 0)
			button:SetNormalAtlas(spec.atlas .. "-up")
			button:SetHighlightAtlas(spec.atlas .. "-highlight")
			button:SetPushedAtlas(spec.atlas .. "-down")
			button.spec = spec
			-- Hover glow (accessibility): shows which button a click will hit. Not on a disabled or guarded one.
			button.glow = button:CreateTexture(nil, "BACKGROUND")
			button.glow:SetPoint("CENTER")
			button.glow:SetSize(look.glow, look.glow)
			button.glow:SetBlendMode("ADD")
			button.glow:SetVertexColor(1, 0.8, 0.2, 0.9)
			button.glow.ok = button.glow:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight") ~= false
			button.glow:Hide()
			if button.SetMotionScriptsWhileDisabled then
				button:SetMotionScriptsWhileDisabled(true) -- (a greyed-out button still says why)
			end
			-- Two tooltips: the drop's item tooltip stays (as over the rest of the drop, unless it's on the icon
			-- only), and a small tip by the button says which roll it is, why not, or the guard.
			button:SetScript("OnEnter", function(self)
				-- also rerun by History.refreshButtonTip when the guard changes under a still mouse
				self.glow:SetShown(db.hoverGlow and self.glow.ok and self:IsEnabled() and not card.guarded or false)
				History.hoverButton = self
				if db.itemTooltip ~= "icon" then
					card.showTooltip(self)
					if not db.buttonTips and card.guarded and self:IsEnabled() then -- (no tip: the item tooltip says it)
						GameTooltip:AddLine(History.guardLine(), 1, 0.82, 0.2, true)
						GameTooltip:Show()
					end
				end
				History.showButtonTip(self, card, spec)
			end)
			button:SetScript("OnLeave", function(self)
				self.glow:Hide()
				if History.hoverButton == self then
					History.hoverButton = nil
				end
				GameTooltip_Hide()
				History.hideButtonTip()
			end)
			button:SetScript("OnMouseDown", function(self)
				self.pressedAt = GetTime()
			end)
			button:SetScript("OnClick", Guard.wrapCore("click", function(self)
				if not self:IsEnabled() then
					return
				end
				if card.guarded then
					-- Moved under a still cursor (History.checkGuard); a "denied" sound says the click was heard.
					if PlaySound then
						pcall(PlaySound, SOUNDKIT and SOUNDKIT.UI_GARRISON_ARCHITECT_TABLE_BUILDING_PLACEMENT_ERROR or 47355)
					end
					return
				end
				-- Only a press that began after the buttons appeared counts: one already in progress when they
				-- popped up under the cursor wasn't meant for this item. Keyboard clicks have no press time and count.
				local pressedAt = self.pressedAt
				self.pressedAt = nil
				if pressedAt and bar.shownAt and pressedAt <= bar.shownAt then
					return
				end
				local roll = ownRoll(card)
				if card.twins then -- any open roll for this item
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
				-- A cancelled bind-on-pickup confirm gives it back (releaseRoll).
				card.setMine(CLICK_STATE[spec.type])
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

-- Item level sits left of the roll buttons or your choice when shown, else at the right edge.
placeHeader = function(card)
	local mode = card.buttons and card.buttons:IsShown() and "buttons"
		or (card.mineIcon and card.mineIcon:IsShown() and "mine") or "plain"
	if card.headerMode == mode then
		return
	end
	card.headerMode = mode
	card.ilvl:ClearAllPoints()
	if mode == "buttons" then
		card.ilvl:SetPoint("TOPRIGHT", card.buttons, "TOPLEFT", -4, -1)
	elseif mode == "mine" then
		-- Where it was beside the buttons (they're hidden, still in place), so it doesn't move when you roll.
		card.ilvl:SetPoint("TOPRIGHT", card.buttons, "TOPLEFT", -4, -1)
	else
		card.ilvl:SetPoint("TOPRIGHT", card.frame, "TOPRIGHT", -6, -5)
	end
end

-- Highlight for drops waiting for your roll: shown exactly while their roll buttons are. One driver
-- animates them all; a child of the window, so it stops when the window hides. A piece whose texture
-- doesn't load stays hidden.
local Highlight = { cards = {}, count = 0, STYLES = { "border", "timer", "sparkle", "all", "off" } }
Highlight.SPARKS = 5 -- stars per drop in the sparkle style

-- Pieces are built the first time a card shows a style. Border and timer pieces sit in their own frame,
-- so one SetAlpha pulses them.
function Highlight.build(card, style)
	local hl = card.hl
	if not hl then
		hl = CreateFrame("Frame", nil, card.frame)
		hl:SetAllPoints()
		-- At the card's own level, under its roll buttons: the gold wash made them look faded.
		hl:SetFrameLevel(card.frame:GetFrameLevel())
		hl:EnableMouse(false)
		hl.isHighlight = true -- (tests find it by this)
		hl:SetScript("OnShow", function() -- (the window shown again: start its animations again)
			if hl.wanted and not hl.styling then
				Highlight.style(card, hl.wanted)
			end
		end)
		card.hl = hl
	end
	if (style == "border" or style == "all") and not hl.border then
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
		-- The spark is placed by the timer's OnUpdate.
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
		hl.stars = {}
		for i = 1, Highlight.SPARKS do
			local star = hl:CreateTexture(nil, "OVERLAY")
			star:SetSize(16, 16)
			star:SetBlendMode("ADD")
			star.ok = star:SetTexture("Interface\\Cooldown\\star4") ~= false
			star:SetVertexColor(1, 0.9, 0.5)
			star:SetAlpha(0)
			star.phase = (i - 1) / Highlight.SPARKS
			hl.stars[i] = star
		end
	end
end

function Highlight.style(card, style)
	local steady = History.noFlash() -- Accessibility: nothing twinkles; Sparkles becomes a steady border
	if steady and style == "sparkle" then
		style = "border"
	end
	Highlight.build(card, style)
	local hl = card.hl
	hl.styling = true
	local border, timer, sparkle = style == "border" or style == "all", style == "timer" or style == "all",
		(style == "sparkle" or style == "all") and not steady
	if hl.border then
		hl.border:SetShown(border)
		Highlight.breathe(hl.border, border, steady, 0.35)
	end
	if hl.bar then
		hl.bar:SetShown(timer)
		Highlight.breathe(hl.bar, timer, steady, 0.3)
		if hl.spark and hl.sparkOk ~= false then hl.spark:SetShown(not steady) end -- (Off: a steady glow, no moving spark)
	end
	if hl.stars then
		for _, star in ipairs(hl.stars) do
			star:SetShown(sparkle and star.ok)
			Highlight.twinkle(card, star, sparkle and star.ok)
		end
	end
	hl.style = style
	hl:Show()
	hl.styling = nil
end

-- The pulse and the twinkles are animations the engine plays: nothing runs per frame. Each starts at the
-- clock's phase (Play's offset), so drops waiting together breathe together.
Highlight.BREATH, Highlight.TWINKLE = 1.2, 1.4 -- seconds: one pulse; one star's twinkle

function Highlight.loop(region, steps, onLoop)
	local ok, group = pcall(function()
		local g = region:CreateAnimationGroup()
		g:SetLooping("REPEAT")
		for order, step in ipairs(steps) do
			local a = g:CreateAnimation("Alpha")
			a:SetOrder(order)
			a:SetFromAlpha(step[1])
			a:SetToAlpha(step[2])
			a:SetDuration(step[3])
			a:SetSmoothing(step[4])
		end
		if onLoop then
			g:SetScript("OnLoop", onLoop)
		end
		return g
	end)
	return ok and group or false
end

function Highlight.play(group, period, phase)
	group:Stop()
	group:Play(false, ((GetTime() / period + (phase or 0)) % 1) * period)
end

-- Border and timer glow: from `low` to full and back, once a breath. Flashing Off (or no animations in
-- this client): steady, where the pulse spends most of its time.
function Highlight.breathe(frame, on, steady, low)
	if frame.rfPulse == nil then
		local half = Highlight.BREATH / 2
		frame.rfPulse = Highlight.loop(frame, { { low, 1, half, "IN_OUT" }, { 1, low, half, "IN_OUT" } })
	end
	local pulse = frame.rfPulse
	if pulse then
		pulse:Stop()
	end
	frame:SetAlpha(low + (1 - low) * 0.8)
	if on and not steady and pulse then
		Highlight.play(pulse, Highlight.BREATH)
	end
end

-- A star: fades in and out once a twinkle, moving to another spot on the edge between twinkles.
function Highlight.twinkle(card, star, on)
	if star.rfTwinkle == nil then
		local half = Highlight.TWINKLE / 2
		star.rfTwinkle = Highlight.loop(star, { { 0, 1, half, "IN" }, { 1, 0, half, "OUT" } }, function()
			Highlight.placeStar(card, star)
		end)
	end
	local twinkle = star.rfTwinkle
	if twinkle then
		twinkle:Stop()
	end
	star:SetAlpha(0)
	if on and twinkle then
		Highlight.placeStar(card, star)
		Highlight.play(twinkle, Highlight.TWINKLE, star.phase)
	end
end

function Highlight.placeStar(card, star)
	local along, side = math.random(), math.random(4)
	star:ClearAllPoints()
	if side <= 2 then
		star:SetPoint("CENTER", card.hl, side == 1 and "TOPLEFT" or "BOTTOMLEFT", along * card.frame:GetWidth(), 0)
	else
		star:SetPoint("CENTER", card.hl, side == 3 and "TOPLEFT" or "TOPRIGHT", 0, -along * card.frame:GetHeight())
	end
end

-- Stops what Highlight.style started (a hidden frame's animations would only wait).
function Highlight.still(hl)
	for _, frame in ipairs({ hl.border or false, hl.bar or false }) do
		if frame and frame.rfPulse then
			frame.rfPulse:Stop()
		end
	end
	for _, star in ipairs(hl.stars or {}) do
		if star.rfTwinkle then
			star.rfTwinkle:Stop()
		end
	end
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
	if not (card.hl and card.hl.wanted == style and card.hl.steady == (History.noFlash()) and card.hl:IsShown()) then
		Highlight.style(card, style)
		card.hl.wanted = style -- (what was asked for; hl.style is what shows, e.g. a steady border for Sparkles)
		card.hl.steady = History.noFlash()
	end
	if not Highlight.cards[card] then
		Highlight.cards[card] = true
		Highlight.count = Highlight.count + 1
	end
	if not card.buttons.rfHighlightHook then
		-- Buttons gone (rolled, roll over, card reused): no highlight. Here as well as where the buttons hide,
		-- so no path can leave a drop glowing.
		card.buttons.rfHighlightHook = true
		card.buttons:HookScript("OnHide", function(buttons)
			if not buttons:IsShown() and Highlight.cards[card] then
				Guard.call("highlight", Highlight.off, card)
			end
		end)
	end
end

function Highlight.off(card)
	local hl = card.hl
	if hl then
		Highlight.still(hl)
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
	if History.noFlash() or not main then
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
		-- texture, coordinates and place), so the flash sits exactly on the visible border (plain edges
		-- along the frame's rectangle didn't line up with the art).
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
		pcall(function() -- (the engine plays the pulse; a client without it gets the Lua one)
			local group = f:CreateAnimationGroup()
			for order, step in ipairs({ { 0, 1, "OUT" }, { 1, 0, "IN" } }) do
				local a = group:CreateAnimation("Alpha")
				a:SetOrder(order)
				a:SetFromAlpha(step[1])
				a:SetToAlpha(step[2])
				a:SetDuration(0.45)
				a:SetSmoothing(step[3])
			end
			f.pulse = group
		end)
	end
	f.token = (f.token or 0) + 1
	local token = f.token
	f:SetAlpha(0)
	f:Show()
	local function again()
		if f.token ~= token then
			return
		end
		if db.flashing == "persist" and main:IsVisible() and not main:IsMouseOver() then
			History.pulseFlash(f, again)
		else
			f:Hide()
		end
	end
	History.pulseFlash(f, again)
end

-- One 0.9 s pulse of the window's flash, then `after`.
function History.pulseFlash(f, after)
	if f.pulse then
		f.pulse:Stop()
		f.pulse:Play()
		C_Timer.After(0.9, after)
	else
		tween("main:flash", 0.9, function(p)
			f:SetAlpha(math.sin(p * math.pi))
		end, after, true) -- (linear: an even pulse)
	end
end

function History.endFlash()
	local f = History.flash
	if f then
		f.token = (f.token or 0) + 1
		tweens["main:flash"] = nil
		if f.pulse then
			f.pulse:Stop()
		end
		f:Hide()
	end
end

-- Stops a flash at once (Flashing set to Off).
function History.stopFlash()
	if History.flash and History.flash:IsShown() then
		History.endFlash()
	end
end

-- After the setting changes: restyle every drop that's waiting for your roll (or clear them all for "off").
function Highlight.restyle()
	for card in pairs(Highlight.cards) do
		if card.buttons:IsShown() then
			Highlight.on(card)
		else
			Highlight.off(card) -- stopped waiting (the window may be hidden)
		end
	end
	for _, card in ipairs(cards) do
		if card.buttons and card.buttons:IsShown() then
			Highlight.on(card)
		end
	end
end

refreshButtons = function(card)
	if not (History.rollsHere() and not Guard.fallback and (card.rollID or card.demoWaitsForYou or card.twins)
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
			if not allowed then
				button.glow:Hide()
			end
			button:GetNormalTexture():SetDesaturated(not allowed)
			button:SetAlpha(allowed and 1 or 0.35)
		end
	end
	if card.buttons.wide ~= wide then
		card.buttons.wide = wide
		card.buttons:SetWidth((wide and 4 or 3) * Scale.look().step)
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
-- Frame reuse. WoW never frees a frame, so cards leaving the list go back to pools and new drops take
-- from them first.
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
	-- On its drop's layer, just above it: the window changes layer and raises itself while a roll waits (v1.3),
	-- and a hidden pooled line could keep an old layer or level and be drawn under the drop (names gone).
	-- Detailed view only: no other view pools player lines.
	line:SetFrameStrata(card.frame:GetFrameStrata())
	line:SetFrameLevel(card.frame:GetFrameLevel() + 1)
	line:SetPoint("RIGHT", card.frame, "RIGHT", -6, 0)
	line.slide, line.index, line.entry, line.drawn, line.group = 0, nil, nil, nil, nil
	History.setAlpha(line.bg, 0)
	line.selfBg:Hide()
	line.selfMark:Hide()
	line.check:Hide()
	line.shine:Hide()
	line.shine:SetAlpha(1)
	History.stopSweep(line) -- (a pooled line: no sweep left running from its last drop)
	History.setAlpha(line, 1)
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
	History.stopGlow(card.winnerIcon)
	for _, region in ipairs({ card.frame, card.waiting, card.winnerText, card.winnerRoll, card.winnerIcon, card.mineIcon,
		card.mineRoll }) do
		History.stopFade(region) -- (their `done` was the old drop's)
	end
	if Highlight.cards[card] then
		Guard.call("highlight", Highlight.off, card)
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
	if card.historyKey and not card.demo then
		skippedHistory[card.historyKey] = card.dropMark or true
	end
	if logging() and not card.demo then
		log("skip", { historyKey = card.historyKey, quality = card.quality, why = why or "below minimum quality kept" })
	end
	card.timer:Hide()
	card.buttons:Hide()
	History.fadeRow(card, 0, 0.35, function()
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
	History.clearRowSweep(card)
	if card.buttons.wide then -- (the last drop allowed Transmog; the item level sits beside this bar)
		card.buttons.wide = false
		card.buttons:SetWidth(3 * (card.look or Scale.look()).step)
	end
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
	card.winnerText.lineText = nil
	History.setAlpha(card.winnerText, 0)
	if card.winnerRoll.hasText then
		card.winnerRoll.hasText = nil
		card.winnerRoll:SetText("")
	end
	History.setAlpha(card.winnerRoll, 0)
	card.winnerFull = nil
	History.setAlpha(card.winnerIcon, 0)
	card.winnerIcon:Hide()
	card.waiting:SetText("")
	History.setAlpha(card.waiting, 1)
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

-- In a raid only Need rolls are listed, then one line counting the rest (40 lines would run off the screen).
local function addRollsToTooltip(card)
	if not card.lastRolls then
		return
	end
	local raid = IsInRaid and IsInRaid()
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine(raid and "Need rolls" or "Rolls", 1, 1, 1)
	local others -- (raid) how many chose each of the rest
	local listed = 0
	for _, r in ipairs(card.lastRolls) do
		local state = safe(r.state, STATE.NOROLL)
		if raid and state ~= STATE.NEED and state ~= STATE.NEED_OFF then
			others = others or {}
			others[state] = (others[state] or 0) + 1
		else
			local choice
			if state == STATE.NOROLL then
				choice = card.finished and "no roll" or "deciding"
			else
				choice = "|A:" .. (STATE_ATLAS[state] or STATE_ATLAS[STATE.PASS]) .. ":14:14|a"
				if state == STATE.NEED_OFF then
					choice = "|cff999999off-spec|r " .. choice
				end
			end
			local roll = safe(r.roll)
			-- Number before icon, so the icons line up on the right edge.
			GameTooltip:AddDoubleLine(classColored(safe(r.playerName, "?"), safe(r.playerClass)),
				(roll and (roll .. "  ") or "") .. choice, 1, 1, 1, 0.8, 0.8, 0.8)
			listed = listed + 1
		end
	end
	if raid and listed == 0 then
		GameTooltip:AddLine("No Need rolls", 0.6, 0.6, 0.6)
	end
	if others then
		local parts = {}
		for _, state in ipairs({ STATE.GREED, STATE.TRANSMOG, STATE.PASS }) do
			if others[state] then
				parts[#parts + 1] = "|A:" .. STATE_ATLAS[state] .. ":14:14|a " .. others[state]
			end
		end
		if others[STATE.NOROLL] then
			parts[#parts + 1] = (card.finished and "no roll " or "deciding ") .. others[STATE.NOROLL]
		end
		GameTooltip:AddLine("Others: " .. table.concat(parts, "   "), 0.8, 0.8, 0.8)
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
		-- One flash per burst: a boss's drops arrive within a second.
		History.flashedAt = GetTime()
		Guard.call("flash", History.flashWindow)
	end
	scrollToNewestPending = true
	if reused then
		card.frame:SetPoint("LEFT", content, "LEFT")
		card.frame:SetPoint("RIGHT", content, "RIGHT")
		placeHeader(card)
		insertCard(card)
		History.fadeRow(card, 1, 0.3, nil, 0)
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
	icon:SetSize(Scale.iconSize, Scale.iconSize)
	icon:SetPoint("TOPLEFT", 3, -3)
	icon.tex = icon:CreateTexture(nil, "ARTWORK")
	icon.tex:SetAllPoints()
	icon.border = icon:CreateTexture(nil, "OVERLAY")
	icon.border:SetPoint("TOPLEFT", -2, 2)
	icon.border:SetPoint("BOTTOMRIGHT", 2, -2)
	icon.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	icon.border:SetBlendMode("ADD")
	-- One tooltip for the whole drop (or only its icon: "Item tooltip"). The bar takes mouse motion only, so
	-- clicks reach the window (drag it from the list).
	local function showTooltip(self)
		History.tooltipBeside(self, f)
		if card.demo and not card.link then
			GameTooltip:SetText(card.itemName or "Demo item")
			GameTooltip:AddLine("Demo mode: a made-up item.", 0.8, 0.8, 0.8)
		elseif card.link then
			GameTooltip:SetHyperlink(card.link)
			if card.demo then
				GameTooltip:AddLine("Demo mode: nothing is rolled.", 0.8, 0.8, 0.8)
			end
		else
			GameTooltip:SetText(card.itemName or "Item")
		end
		if card.linesMode ~= "all" or card.collapsed then
			addRollsToTooltip(card) -- no player lines showing: the item's tooltip lists the rolls
		end
		if card.rollEnded and not card.winner and not card.allPassed then
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("The game didn't say who won. Blizzard's loot history (/loot) may show it.",
				0.6, 0.6, 0.6, true)
		end
		GameTooltip:Show()
	end
	card.showTooltip = showTooltip
	if f.SetMouseMotionEnabled then
		f:SetMouseMotionEnabled(true) -- (movement only: clicks go straight through to the window)
		f:SetScript("OnEnter", function(self)
			if db.itemTooltip ~= "icon" then
				showTooltip(self)
			end
		end)
		f:SetScript("OnLeave", GameTooltip_Hide)
	end
	icon:SetScript("OnEnter", showTooltip) -- (the icon takes clicks too: shift-click links the item)
	icon:SetScript("OnLeave", GameTooltip_Hide)
	icon:SetScript("OnClick", function()
		if card.link and IsModifiedClick() then
			History.itemClick(card.link)
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
	card.timer:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 6, Scale.timerY()) -- (as Scale.placeTimer)
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
	History.setAlpha(card.winnerIcon, 0)
	card.winnerText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	-- Row grid: line 2's first piece starts in the item name's column (icon right + 6), on one
	-- baseline (icon bottom + 4) for the counts, the winner and the boss. The winner's 14 px choice icon sits
	-- in that column and the name follows it.
	card.winnerText:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 24, 4)
	card.winnerText:SetPoint("RIGHT", f, "RIGHT", -6, 0)
	card.winnerText:SetJustifyH("LEFT")
	card.winnerText:SetWordWrap(false)
	History.setAlpha(card.winnerText, 0)
	card.winnerRoll = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	card.winnerRoll:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 22, 4)
	card.winnerRoll:SetWidth(History.rollWidth(card.winnerRoll))
	card.winnerRoll:SetJustifyH("RIGHT")
	History.setAlpha(card.winnerRoll, 0)
	card.winnerRoll.choiceIcon = card.winnerIcon -- (anchored by History.setWinnerLine)

	-- Summary line: one column per choice, so counts line up across rows.
	card.waiting = History.countsLine(f)

	-- Your choice (Summary or None): the icon in the right-hand button's spot, your roll in the column left of it.
	card.mineIcon = f:CreateTexture(nil, "ARTWORK")
	card.mineIcon:SetSize(Scale.look().size, Scale.look().size) -- (follows Roll buttons: Scale.styleCard)
	card.mineIcon:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, Scale.look().top)
	-- Greyed, as a roll button that can't be clicked: it's only an indicator now.
	card.mineIcon:SetDesaturated(true)
	card.mineIcon:SetAlpha(0.35)
	card.mineRoll = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	card.mineRoll:SetJustifyH("CENTER")
	History.placeMine(card)
	card.mineIcon:Hide()
	card.mineRoll:Hide()
	card.setMine = function(state, roll)
		if card.mineState == state and card.mineRollShown == roll then
			return
		end
		card.mineState, card.mineRollShown = state, roll
		if state and state ~= STATE.NOROLL and not card.finished then
			History.placeMine(card)
			-- (A fade, or animations off after errors, may have left them at 0. The game keeps 0.35 as 0.3499...)
			if not card.mineIcon:IsShown() and math.abs(card.mineIcon:GetAlpha() - 0.35) > 0.01 then
				History.setAlpha(card.mineIcon, 0.35)
				History.setAlpha(card.mineRoll, 1)
			end
			card.mineIcon:SetAtlas(STATE_ATLAS[state] or STATE_ATLAS[STATE.PASS])
			card.mineIcon:Show()
			card.mineRoll:SetText(state == STATE.PASS and "" or (roll and tostring(roll) or "|cff888888...|r"))
			-- Detailed: your roll is on your own line, in the roll column with everyone's; only the icon here.
			card.mineRoll:SetShown(card.linesMode ~= "all")
		else
			card.mineIcon:Hide()
			card.mineRoll:Hide()
		end
		placeHeader(card)
	end

	-- The boss the drop came from, on history rows.
	card.boss = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	card.boss:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, Scale.lineTwo()) -- (line 2's baseline: icon bottom + 4)
	card.boss:SetWidth(110)
	card.boss:SetJustifyH("RIGHT")
	card.boss:SetWordWrap(false)
	card.boss:Hide()

	card.buttons = createButtons(card)
	card.look = Scale.look() -- (built in it; Scale.restyleRows restyles on a change)
	placeHeader(card)

	insertCard(card)
	History.fadeRow(card, 1, 0.3, nil, 0)
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
	-- Secret values can't be compared; if any input is one, always redraw.
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
	-- Gear only: recipes and containers have an item level too, but it means nothing there.
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
			History.setAlpha(line, 0) -- (it slides and fades in; a quiet one is already at full alpha)
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

-- Summary counts; redrawn only when a count changes.
local function setSummary(card, need, greed, transmog, pass)
	-- (Who's still deciding isn't counted here: the timer says the roll is on, and the tooltip shows each one.)
	local key = ((need * 64 + greed) * 64 + transmog) * 64 + pass
	if card.summaryKey == key then
		return
	end
	card.summaryKey = key
	placeSummary(card)
	card.waiting:SetCounts(need, greed, pass, transmog)
end

-- One full list of players (shaped like C_LootHistory's rollInfos) drawn as "Player lines" says:
-- a line each, one summary line, or just your own choice on the item row. Every loot-history update
-- lists everyone again; lines whose player is unchanged are skipped.
local function applyRolls(card, rollInfos, quiet)
	local mode = card.linesMode
	-- No player lines on a compact row, or on a drop already decided when first seen (it collapses at once):
	-- a late update would slide a stray line in over the next drop.
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
		end
		if isSelf then -- (every view: your choice takes the buttons' place)
			card.setMine(state == STATE.NOROLL and card.clickedState or state, safe(r.roll))
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

-- Roll buttons changed, or "Roll from this window" switched: every drop, pooled drop and History
-- row takes the new look and row height at once, then the list is laid out again.
function Scale.restyleRows()
	History.placeClock() -- (it follows the Need column)
	local rowsChanged = Scale.setRows()
	for _, list in ipairs({ cards, cardPool }) do
		for _, card in ipairs(list) do
			if card.look ~= Scale.look() or rowsChanged then
				Scale.styleCard(card)
				if list == cards then
					placeHeader(card) -- (the item level beside your choice: its spot follows the size)
				end
			end
		end
	end
	if not rowsChanged then
		return
	end
	for _, card in ipairs(cards) do
		for i, key in ipairs(card.lineOrder) do
			local line = card.lines[key]
			if line then
				placeLine(card, line, i) -- (the lines start under the taller or shorter item row)
			end
		end
		resize(card, true)
	end
	for _, row in pairs(History.rows) do
		row:SetHeight(History.ROW_H - CARD_GAP)
		row.when:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -6, Scale.lineTwo())
		row.icon:SetSize(Scale.iconSize, Scale.iconSize)
	end
	trimPending = true
	layout()
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
			History.setAlpha(card.waiting, 1)
			if card.lastRolls then
				applyRolls(card, card.lastRolls, true)
			end
			if card.finished and mode == "summary" then
				History.setAlpha(card.waiting, 0) -- (decided: line 2 is the winner's, as finish leaves it)
			end
			if card.clickedState and not card.selfReported then
				card.setMine(card.clickedState) -- clicked before the loot history listed anyone
			end
			if card.finished then
				if mode == "all" then
					History.setAlpha(card.winnerText, 0)
					History.setAlpha(card.winnerRoll, 0)
					History.setAlpha(card.winnerIcon, 0)
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
			rec.winner = card.winnerFull
			rec.atlas = allPassed and STATE_ATLAS[STATE.PASS] or (winner and (STATE_ATLAS[winner.state] or STATE_ATLAS[STATE.GREED])) or nil
			rec.mine = History.mineOf(winner) -- (a late result you won is yours too)
			break
		end
	end
	if winner and winner.isSelf and card.collapsed then
		History.keepWinTint(card) -- (its compact row gets the kept tint)
	end
end

-- A roll that ended for you without its drop ever being decided (you left the group, or the loot history
-- never gave a result): the drop settles as "Roll ended", or it would stay open and keep the window from
-- fading.
function History.settleEnded(card)
	if card.finished or card.dismissing then
		return
	end
	card.rollEnded = true
	finish(card)
end

trimHistory = function()
	-- Real rows keep the newest db.historyCount. Demo rows trim the same way among themselves, so the demo
	-- never costs a real row. (Stress-test rows count as real: only demo drops have a demoRoll.)
	local total, real = 0, 0
	for _, card in ipairs(cards) do
		if card.collapsed then
			total = total + 1
			if not card.demoRoll then
				real = real + 1
			end
		end
	end
	local demoExcess = math.max(0, (total - real) - db.historyCount)
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
	-- The card under the cursor with your roll buttons holds still. Where it is now: its distance
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
	if y > 0 then
		y = y - CARD_GAP -- (no gap after the last row: the window's padding follows it, as at the sides)
	end
	local natural = math.max(y, HEADER_H)
	-- The window's height (fixed), or how tall it may grow with the drops ("Grow with drops"); then it scrolls.
	-- (Exactly as set: nothing resizes the window on its own. Only the limits below can shorten it.)
	local limit = math.max(MIN_HEIGHT, tonumber(db.autoGrow and db.maxHeight or db.height) or FIXED_HEIGHT)
	local above = roomAbovePopups() -- attached, never taller than the space above the roll popups
	if above and above < limit then
		local snapped = db.snapDrag and History.snapHeight(above, true) or above
		limit = math.max(MIN_HEIGHT, snapped <= above and snapped or above) -- (never taller than the room)
	end
	local screen = Scale.screenHeight() - 40 -- never taller than the screen (a big Window size)
	if limit > screen then
		local snapped = db.snapDrag and History.snapHeight(screen, true) or screen
		limit = math.max(MIN_HEIGHT, snapped <= screen and snapped or screen)
	end
	main.growLimit = limit -- (the outline shows it while the corner is dragged or hovered)
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
	-- The empty window's text (and the demo offer) sit a little way down; a window that grows with its drops is
	-- tall enough to hold them, and a short fixed one moves them up, so they never spill out.
	local block = History.emptyBlockH()
	if #ordered == 0 and histH == 0 then
		if db.autoGrow then
			visible = math.min(room, math.max(visible, block + 50))
		end
		local top = math.max(5, math.min(40, math.floor((visible - block - 10) / 2)))
		if main.emptyTop ~= top then
			main.emptyTop = top
			main.empty:SetPoint("TOP", scroll, "TOP", 0, -top)
		end
	end
	local scrolls = contentHeight > visible + 0.5
	if heldFromTop and scrollReserved ~= nil then
		scrolls = scrollReserved -- keep the list's width while a drop is held (the scrollbar would shift it)
	end
	scrollReserved = scrolls
	-- Layout runs every frame while a height animates: each size is set only when it changed. (The window's
	-- height is compared with its live height, so a resize by the grip is never missed.)
	local sized = false
	-- The rows never change width, so nothing shifts when the scrollbar appears (roll buttons included):
	-- the scrollbar sits in the window's right padding, not in the rows' room.
	local contentW = WIDTH - 2 * SIDE_PAD
	if content.laidW ~= contentW then
		scroll:SetPoint("BOTTOMRIGHT", -SIDE_PAD, BOTTOM_PAD)
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
	local older = #History.records > 0
	if main.emptyShown ~= isEmpty or (isEmpty and (main.emptyLead ~= demoLead or main.emptyOlder ~= older)) then
		main.emptyShown, main.emptyLead, main.emptyOlder = isEmpty, demoLead, older
		-- After a session of looting the list empties into History: say so, rather than "No loot rolls yet".
		main.empty:SetText(demoLead and "Demo starting…" or (older and "No rolls in progress" or "No loot rolls yet"))
		main.emptyHint:SetText(demoLead and "" or (older and "Older drops: History (the clock)." or "Group loot rolls appear here."))
		main.empty:SetShown(isEmpty)
		main.emptyHint:SetShown(isEmpty)
	end
	History.setDemoOffer(isEmpty and not demoLead and History.canDemo())
	if scrollBar and scrollBar.wanted ~= scrolls then
		scrollBar.wanted = scrolls
		local from = scrollBar:IsShown() and History.shownAlpha(scrollBar) or 0
		if scrolls then
			scrollBar:Show()
		end
		History.fade(scrollBar, scrolls and 1 or 0, 0.25, function()
			if not scrollBar.wanted then
				scrollBar:Hide()
			end
		end, from)
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
	-- At an edge the list can scroll past, a marker covers MARKER_H, so buttons there count as out of view;
	-- at an end of the list there's no marker.
	local look = card.look or Scale.look()
	if top > 0.5 and card.layoutY - look.top < top + MARKER_H then
		return "up"
	elseif top + view < content:GetHeight() - 0.5 and card.layoutY - look.top + look.size > top + view - MARKER_H then
		return "down"
	end
end

-- Whether the cursor is on the strip a marker covers (its edge of the list), shown or not.
local function cursorOnStrip(up)
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
		end, 0.1))
	end
	markerWatch:Show()
end

-- A marker doesn't change under the cursor: disappearing could uncover roll buttons you're about to
-- click, so it never does while the cursor is on its strip; appearing waits up to 3 s (a click on a
-- bar only scrolls). The count can change meanwhile.
local function setMarker(marker, count)
	local now = GetTime()
	local wantShown = count > 0
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
	if History.rollsHere() and not Guard.fallback and main:IsShown() then
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
	if not (History.rollsHere() and not Guard.fallback and main and main:IsShown()) then
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
	pcall(History.updateStrata) -- (Blizzard's popups have the roll now: back to the normal layer)
	if db and History.rollsHere() then -- (without roll buttons in the window nothing changes for you: diag has it)
		pcall(say, "something went wrong, so for now you roll in Blizzard's roll popups. /reload to roll from this "
			.. "window again (/rollframes diag has details for a bug report).")
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

-- Twins pairing data (roll starts and each drop's first loot-history entry) also go to a separate, small
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
	-- describe the suffix differently.
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

-- Logs only (twins): the item part of a link ("item:id:enchant:...:bonus"), so the log shows whether two
-- copies of the same item can be told apart. Item strings carry no names.
local function itemStringForLog(link)
	if not link or isSecret(link) then
		return nil
	end
	return link:match("item:[%-%d:]*")
end

-- Logs only: how many cards for this item are waiting for their loot-history entry (more than one means
-- the pairing is a guess).
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
		-- Already decided when first seen: appears collapsed.
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
		-- Trash drops all come under encounter 0.
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
		-- Units (ms or s) unconfirmed on Forever: guessed by size; logged below.
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
		-- Twins data, on a drop's first entry: its item string, the roll it was paired with, your click.
		item = firstEntry and itemStringForLog(link) or nil, pairedRollID = firstEntry and card.rollID or nil,
		clicked = firstEntry and card.clickedState or nil, waitingSameItem = waitingBefore
	}) end

	if card.rollEnded and (info.winner or info.allPassed) then
		local w = info.winner
		History.lateResult(card, w and { name = safe(w.playerName, "?"), class = safe(w.playerClass), roll = safe(w.roll),
			state = safe(w.state), isSelf = safe(w.isSelf) == true } or nil, info.allPassed and not w)
	elseif info.winner and not card.finished then
		local w = info.winner
		local name = safe(w.playerName, "?")
		setWinner(card, safe(w.playerGUID) or name,
			{ name = name, class = safe(w.playerClass), roll = safe(w.roll), state = safe(w.state), isSelf = safe(w.isSelf) == true })
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
	if not card.twins then -- another copy of this item started at the same moment: twins
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
		-- Twins data: anything else the event carries (a loot handle could match the history's lootListKey),
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

-- Watchdog: a roll waiting for you while Blizzard's popups are hidden must have its drop placed, with
-- roll buttons. Own frame (an error could stop the driver or ticker). First look after 3 s AND 5 drawn
-- frames (loading screens, freezes, low fps); a problem gets one rebuild and a second look a second later,
-- then Blizzard's popups come back for the session (Guard.fail). Fine rolls are rechecked once a second.
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
			or GetTime() >= (card.endsAt or 0) or not History.rollsHere() or not main:IsShown() then
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
	if logging() then
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
	{ name = "Demo Blade of Testing", icon = "Interface\\Icons\\INV_Sword_04", quality = 3, boss = "Demo Boss",
		topRoll = true }, -- (its winner rolls 100, so the widest roll shows in the demo)
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
	card.demoRoll = opts and opts.ownRoll or {} -- a click sets .choice
	local mine = opts and opts.simRoll or card.demoRoll
	local gen = card.gen -- the demo's timers stop if the card is cleared and reused meanwhile
	demoCardCount = demoCardCount + 1
	card.isTrash, card.bossName = not item.boss, item.boss or false
	if item.link then -- (a real item: its name, icon and quality come from the link)
		setItem(card, item.link)
	else
		setItem(card, nil, item.name, item.icon, item.quality)
	end
	card.duration = 12
	card.endsAt = GetTime() + card.duration
	card.timer:Show()
	card.demoWaitsForYou = true
	refreshButtons(card)
	if DEV then
		Guard.watch(card) -- so /rollframes fail watchdog can be tried solo
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
		local top -- (topRoll: the roll that will win gets 100: a Need if any, else a Greed)
		if item.topRoll then
			for _, r in ipairs(rolls) do
				if not top and (r.state == STATE.NEED or r.state == STATE.NEED_OFF) then top = r end
			end
			for _, r in ipairs(rolls) do
				if not top and r.state == STATE.GREED then top = r end
			end
		end
		-- As the game does: when anyone needs, only the Need choices roll (Greed and Transmog get no number).
		local needed = false
		for _, r in ipairs(rolls) do
			if r.state == STATE.NEED or r.state == STATE.NEED_OFF then needed = true end
		end
		for _, r in ipairs(rolls) do
			local getsRoll = r.state ~= STATE.PASS and r.state ~= STATE.NOROLL
				and (not needed or r.state == STATE.NEED or r.state == STATE.NEED_OFF)
			if getsRoll then
				delay = delay + 0.35
				C_Timer.After(delay, Guard.wrap("demo", function()
					if card.gen ~= gen then
						return
					end
					r.roll = r == top and 100 or math.random(1, 99)
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
				if r.roll and r.state ~= STATE.PASS and r.state ~= STATE.NOROLL then
					local rank = (r.state == STATE.NEED or r.state == STATE.NEED_OFF) and 2 or 1
					if not best or rank > bestRank or (rank == bestRank and r.roll > best.roll) then
						best, bestRank = r, rank
					end
				end
			end
			if best then
				setWinner(card, best.playerGUID,
					{ name = best.playerName, class = best.playerClass, roll = best.roll, state = best.state, isSelf = best.isSelf })
			else
				setAllPassed(card)
			end
		end))
	end

	local delay = 0.4
	local remaining = #rolls
	-- Rolling here, "You" waits for the click (polled) and passes when the timer runs out, as the game does.
	local waitsForYou = History.rollsHere()
	for _, r in ipairs(rolls) do
		delay = delay + 0.5 + math.random() * 0.8
		local function takeTurn()
			if card.gen ~= gen then
				return
			end
			if r.isSelf and (waitsForYou or History.rollsHere()) and not mine.choice and GetTime() < card.endsAt then
				C_Timer.After(0.25, Guard.wrap("demo", takeTurn))
				return
			end
			local state
			if r.isSelf and mine.choice then -- your click, on any item
				state = CLICK_STATE[mine.choice]
			elseif item.allPass then
				state = STATE.PASS
			elseif r.isSelf and (waitsForYou or History.rollsHere()) then
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

-- Solo only: in a group, real loot can arrive any moment and land among demo drops.
local function demoBlocked()
	if IsInGroup() and not DEV then
		say("the demo only runs when you're not in a group (real loot could arrive at any moment).")
		return true
	end
	return false
end

function History.canDemo()
	return DEV or not IsInGroup()
end

-- A retire fade already under way finishes on its own.
function History.setDemoOffer(on)
	on = on and not db.demoHidden and true or false
	if History.demoOfferWanted == on or History.demoRetiring then
		return
	end
	History.demoOfferWanted = on
	local parts = { main.demoButton, main.demoHide }
	if History.noFlash() or not main:IsVisible() then
		for _, part in ipairs(parts) do
			History.setAlpha(part, 1)
			part:SetShown(on)
		end
		return
	end
	for i, part in ipairs(parts) do
		part:Show()
		History.fade(part, on and 1 or 0, 0.25, i == 1 and function()
			for _, each in ipairs(parts) do
				History.setAlpha(each, 1)
				each:SetShown(History.demoOfferWanted)
			end
		end or nil, on and 0 or 1)
	end
end

-- "Don't show this again": db is account-wide, so it's gone on every character; the chat line keeps
-- /rollframes demo findable.
function History.retireDemoOffer()
	if db.demoHidden then
		return
	end
	db.demoHidden = true
	History.demoOfferWanted = false
	GameTooltip_Hide()
	local parts = { main.demoButton, main.demoHide }
	local function gone()
		History.demoRetiring = nil
		for _, part in ipairs(parts) do
			part:Hide()
			History.setAlpha(part, 1)
		end
	end
	if History.noFlash() then
		gone()
	else
		History.demoRetiring = true
		for i, part in ipairs(parts) do
			History.fade(part, 0, 0.3, i == 1 and gone or nil, History.shownAlpha(part))
		end
	end
	say("demo button hidden on all your characters. Try it any time with /rollframes demo.")
end

-- items: what the drops are (default DEMO_ITEMS); dev builds can pass real ones (/rollframes demo real).
local function runDemo(count, items)
	if demoBlocked() then
		return
	end
	count = math.max(1, math.min(count or 3, 20))
	local gap = count > 3 and 2 or 3.5
	clearDemoCards() -- (also ends a demo still playing)
	local run = demoRun
	showWindow()
	-- Sample History records, only when there's none yet; they leave with the demo.
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
	History.demoLeft = count -- (drops still to come; History.checkDemoDone)
	local lead = 2 -- (a short pause, so the window is seen opening first)
	History.demoActive = true -- (the X stops the demo while it's on; see History.askClear)
	History.demoLeadUntil = GetTime() + lead
	layout() -- (the empty text says the demo is starting)
	for i = 1, count do
		local list = items and #items > 0 and items or DEMO_ITEMS
		local item = list[(i - 1) % #list + 1]
		C_Timer.After(lead + (i - 1) * gap, function()
			if run == demoRun then
				History.demoLeft = math.max(0, (History.demoLeft or 1) - 1)
				Guard.call("demo", runDemoItem, item)
			end
		end)
	end
	local last = lead + (count - 1) * gap
	local drops = count .. (items and #items > 0 and " drop" or " made-up drop") .. (count == 1 and "" or "s")
		.. (items and #items > 0 and " with items from your History" or "")
	if History.rollsHere() then
		say("demo: " .. drops .. "; roll on them like real loot (nothing is really rolled). They fade out a little "
			.. "after the last one.")
	else
		say(string.format("demo: %s over about %d seconds. They fade out a little after the last one.", drops,
			math.floor((last + 10) / 5 + 0.5) * 5))
	end
end

-- Once every demo drop has come and been decided, its rows and records go a little later, so the demo
-- never sits among real loot (a pinned window never closes).
History.DEMO_LINGER = 15 -- seconds
function History.checkDemoDone()
	if (History.demoLeft or 0) > 0 then
		return
	end
	for _, card in ipairs(cards) do
		if card.demo and not card.finished and not card.dismissing then
			return
		end
	end
	local run = demoRun
	local function later()
		if run ~= demoRun or not (main and main:IsShown()) then
			return -- (cleared, another demo started, or the window closed: closing clears them)
		end
		if not pinned and (tonumber(db.autoHide) or 0) > 0 then
			return -- (a window that fades out by itself takes the demo with it, never showing an empty list first)
		end
		if main:IsMouseOver() then
			C_Timer.After(2, later) -- (never under the mouse: the player may be reading them)
			return
		end
		Guard.call("demo", History.endDemo)
	end
	C_Timer.After(History.DEMO_LINGER, later)
end

function History.endDemo()
	History.demoLeft = nil
	History.demoActive = nil
	local demo = {}
	for _, card in ipairs(cards) do
		if card.demo and not card.dismissing then
			demo[#demo + 1] = card
		end
	end
	for _, card in ipairs(demo) do -- (dismissing can change the list at once: a hidden window)
		dismissCard(card, "demo over")
	end
	if #History.demo > 0 then
		wipe(History.demo)
		relayoutPending = true
		driver:Show()
	end
end

-- The empty window's "Try the demo" button: three made-up drops (same as /rollframes demo).
function History.startDemo()
	if Guard.off.demo then
		say("the demo hit a problem and is off until you /reload.")
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
			pcall(Highlight.still, hl)
			pcall(hl.Hide, hl)
			if hl.bar then
				pcall(hl.bar.Hide, hl.bar)
			end
		end
	end
	wipe(Highlight.cards)
	Highlight.count = 0
end
Guard.stops.flash = function()
	History.endFlash()
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
			pcall(Scale.refreshGlow, card)
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
	if grip then
		History.setAlpha(grip, 1) -- (its fades ran from the chrome watch)
	end
	for _, region in pairs({ main.NineSlice, main.Bg }) do
		History.setAlpha(region, 1)
	end
end
Guard.stops.timer = function()
	for _, card in ipairs(cards) do
		pcall(card.timer.Hide, card.timer)
	end
end
Guard.stops.resize = function()
	grip:SetScript("OnUpdate", nil)
	grip:UnlockHighlight()
end

----------------------------------------------------------------------------------------------------
-- Auto-hide
----------------------------------------------------------------------------------------------------

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
	History.placeClock()
	local transient = not pinned and db.autoHide > 0 -- this window may fade by itself
	main.chromeTransient = transient
	main.chromeWatch:Show() -- (also shows the resize corner on hover; a child: stops with the window)
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

-- Real records are saved per character and matched by drop mark, so a drop replayed after a reload isn't
-- added twice. cardOf (not saved: cards are frames) keeps History from repeating a drop still in the list.
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
		-- (true: your win, kept tinted; false: someone else's, so cleanRecord's backfill skips it; nil: no winner yet)
		mine = History.mineOf(card.winner),
		icon = card.icon.tex:GetTexture(), ilvl = card.ilvl:GetText(), winner = card.winnerFull,
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

-- Heights where the list ends exactly at a row's bottom edge, for the current row height (it grows with the
-- roll buttons): n rows and the n - 1 gaps between them. Two rows is the window's minimum (MIN_HEIGHT).
-- Nearest step; down: the step at or below h, for a limit.
function History.snapHeight(h, down)
	local step, base = HEADER_H + CARD_GAP, TITLE_H + BOTTOM_PAD - CARD_GAP
	local n = (h - base) / step
	n = down and math.floor(n + 1e-6) or math.floor(n + 0.5)
	return math.max(2, n) * step + base
end

-- A Summary drop's thin timer back to the normal one (resetCard; a switch away from Summary mid-roll).
function History.wideTimer(card)
	if card.timerThin then
		card.timerThin = nil
		Scale.placeTimer(card)
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
	line = line - (3 + Scale.iconSize + 24) - 6 - taken -- (from the winner's left edge to the row's right padding)
	local bossW = boss.GetUnboundedStringWidth and boss:GetUnboundedStringWidth() or 110
	local winnerW = winner.GetUnboundedStringWidth and winner:GetUnboundedStringWidth() or 0
	boss:SetWidth(math.max(50, math.min(bossW + 2, line - winnerW - 6)))
end

-- Tooltips open beside the window, on the side with more screen room, level with row (a drop, a History row,
-- the empty window's buttons). They hang from a small point on the row, out at the window's edge, with a corner anchor type: the
-- game's comparison tooltips follow the anchor type (further out on that side), and when they don't fit, the
-- game's slide moves the tooltip sideways only (with offsets from the hovered frame, it dropped them and jumped
-- onto the window). "Tooltips at game's spot": the game's own place instead. History.tipFor: what it's for.
function History.tooltipBeside(forFrame, row)
	History.tipFor = forFrame
	if db.tooltipGameSpot and GameTooltip_SetDefaultAnchor then
		GameTooltip_SetDefaultAnchor(GameTooltip, forFrame)
		return
	end
	local placed = pcall(function()
		local point = History.tipPoint
		if not point then
			point = CreateFrame("Frame", nil, main)
			point:SetSize(1, 1)
			-- The tooltip's owner is this point, so it doesn't hide with the frame it's for: hide it then.
			point:SetScript("OnUpdate", function(self)
				if not GameTooltip:IsShown() or not GameTooltip:IsOwned(self) then
					self:Hide() -- (closed, or another tooltip took over: nothing to watch)
				elseif History.tipFor and not History.tipFor:IsVisible() then
					GameTooltip:Hide()
					self:Hide()
				end
			end)
			History.tipPoint = point
		end
		local ms, rs = main:GetEffectiveScale(), row:GetEffectiveScale()
		local screen = UIParent:GetRight() * UIParent:GetEffectiveScale()
		local roomLeft, roomRight = main:GetLeft() * ms, screen - main:GetRight() * ms
		-- Hung from the row (so it follows the row when the list moves), out at the window's edge.
		point:ClearAllPoints()
		if roomRight >= roomLeft then
			point:SetPoint("BOTTOMRIGHT", row, "TOPRIGHT", (main:GetRight() * ms - row:GetRight() * rs) / rs + 2, 0)
			GameTooltip:SetOwner(point, "ANCHOR_BOTTOMRIGHT")
		else
			point:SetPoint("BOTTOMLEFT", row, "TOPLEFT", (main:GetLeft() * ms - row:GetLeft() * rs) / rs - 2, 0)
			GameTooltip:SetOwner(point, "ANCHOR_BOTTOMLEFT")
		end
		point:Show() -- (its watch runs only while its tooltip shows)
	end)
	if not placed then
		GameTooltip:SetOwner(forFrame, "ANCHOR_RIGHT")
	end
end

-- The small tip by the roll button under the mouse (Blizzard's roll popup has one): the roll's name, why it
-- can't be chosen, or Click guard. Its own tooltip (Blizzard's template), so the item tooltip can stay up.
-- "Roll button tooltips" off: none.
function History.showButtonTip(button, card, spec)
	if not db.buttonTips then
		History.hideButtonTip()
		return
	end
	local tip = History.buttonTip
	if tip == nil then
		local ok, made = pcall(CreateFrame, "GameTooltip", "RollFramesButtonTooltip", UIParent, "GameTooltipTemplate")
		tip = ok and made or false -- (no template in this client: no tips)
		History.buttonTip = tip
	end
	if not tip then
		return
	end
	tip:SetOwner(button, "ANCHOR_RIGHT")
	tip:SetText(spec.label, 1, 1, 1)
	if not button:IsEnabled() then
		tip:AddLine("You can't choose " .. spec.label .. " on this item.", 1, 0.13, 0.13, true)
	elseif card.guarded then
		tip:AddLine(History.guardLine(), 1, 0.82, 0.2, true)
	end
	tip:Show()
end

function History.guardLine()
	return (tonumber(db.guardTime) or 2) > 0 and "The list just moved. Move the mouse, or wait a moment, to roll."
		or "The list just moved. Move the mouse to roll."
end

function History.hideButtonTip()
	if History.buttonTip then
		History.buttonTip:Hide()
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

-- Saved History is untrusted: a crash while writing can leave it unreadable (the game then gives us nil)
-- or odd. Each record is checked field by field and malformed ones dropped; on any error History starts
-- empty, never breaking the window.
-- (On History, not top-level locals: the main chunk is at Lua's 200-local limit.)
History.RECORD_FIELDS = { link = "string", name = "string", quality = "number", icon = "number|string",
	ilvl = "string", winner = "string", atlas = "string", boss = "string", when = "number", at = "string",
	key = "string", mark = "string", mine = "boolean" }

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
	-- No "mine" (older saves): decided once from the winner's name, then saved. The game's isSelf wins where known.
	if (clean.mine == nil or (clean.mine == false and History.recheckMine)) and clean.winner then
		local me = History.myName
		if me == nil then
			local ok, name = pcall(UnitName, "player")
			me = ok and type(name) == "string" and not isSecret(name) and name ~= "" and name or false
			History.myName = me
		end
		if me then
			-- Winner text is "<roll>  <name>": the name may have two parts here (first and last), and UnitName may
			-- give only the first.
			local plain = clean.winner:gsub("|A.-|a", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
			local name = plain:match("^%s*%d*%s*(.-)%s*$") or ""
			clean.mine = name == me or name:sub(1, #me + 1) == me .. " "
		end
	end
	return clean
end

function History.load()
	-- Fresh start, with one chat line, when the file is lost (db.historySaved says this character had
	-- History but none came back), the wrong shape, or more than a few records are broken.
	local fresh = false
	-- (db.historySaved is account-wide: which characters, by GUID, have saved History.)
	local me = UnitGUID and UnitGUID("player")
	if RollFramesHistory == nil and me and type(db.historySaved) == "table" and db.historySaved[me] then
		fresh = true
	end
	local ok = pcall(function()
		if RollFramesHistory ~= nil and type(RollFramesHistory) ~= "table" then
			fresh = true
		end
		local saved = type(RollFramesHistory) == "table" and RollFramesHistory or {}
		-- Name checks made before two-part names were handled are made again, once.
		History.recheckMine = saved.mineCheck ~= 2
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
		RollFramesHistory = { records = records, gone = gone, mineCheck = 2 }
	end)
	if not ok or fresh then
		RollFramesHistory = { records = {}, gone = {}, mineCheck = 2 } -- start empty rather than break anything
		say("this character's saved History couldn't be read (the file may be damaged), so it starts empty.")
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
	main.clear:SetShown(on)
	if not on then
		History.hideRows()
	end
	History.rowAlpha = on and 0 or 1
	History.ageing = nil
	History.ageGen = (History.ageGen or 0) + 1 -- (an age-out under way is over)
	layout()
	if on then
		History.rowAlpha = 1
		for _, row in ipairs(History.rows) do
			row.alpha = 1
			History.fade(row, 1, 0.3, nil, 0)
		end
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
	History.ageing = true
	History.ageGen = (History.ageGen or 0) + 1
	local gen = History.ageGen
	History.rowAlpha = 0
	for _, row in ipairs(History.rows) do
		row.alpha = 0
		History.fade(row, 0, 0.35)
	end
	C_Timer.After(0.35, Guard.wrap("history", function()
		if History.ageGen ~= gen then
			return
		end
		History.ageing = nil
		if main:IsMouseOver() then -- the mouse came in during the fade: keep them (nothing moves under it)
			History.touch = GetTime()
			History.rowAlpha = 1
			for _, row in ipairs(History.rows) do row.alpha = 1; History.setAlpha(row, 1) end
			return
		end
		History.toggle(false)
	end))
end

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
			text = "Clear History?\n\nThis character's finished drops leave the list and History for good. Rolls in progress stay.",
			button1 = "Clear", button2 = CANCEL or "Cancel",
			OnAccept = function() History.clear() end,
			timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
		}
	end
	StaticPopup_Show("ROLLFRAMES_CLEAR_HISTORY")
end

-- /rollframes reset all: back to a fresh install after a reload. Other characters' History is saved
-- separately and stays.
function History.askResetAll()
	if not (StaticPopupDialogs and StaticPopup_Show) then
		say("couldn't show the confirmation, so nothing was reset.")
		return
	end
	if not StaticPopupDialogs.ROLLFRAMES_RESET_ALL then
		StaticPopupDialogs.ROLLFRAMES_RESET_ALL = {
			text = "Reset RollFrames completely?\n\nEvery setting goes back to its default on all your characters, and the "
				.. "window to its starting spot. This character's History is cleared, and the first-use question and demo "
				.. "come back. The interface reloads.",
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

-- (Not `w and (w.isSelf and true or false) or nil`: someone else's win would read nil, and a reload's
-- backfill could then mark it yours.)
function History.mineOf(winner)
	if not winner then
		return nil
	end
	return winner.isSelf and true or false
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
	relayoutPending = true -- (an empty window's text names History; it's gone now)
	driver:Show()
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
	if keep > 0 and History.shown and History.touch and now - History.touch >= keep and not History.ageing then
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
-- drops stay", so the next roll opens on a clean list. "Until cleared" keeps them, and
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

-- Click guard: when the list moves and a drop's roll buttons slide under a still cursor, they dim and
-- ignore clicks until the mouse moves a button's width (22 px) or db.guardTime passes (0: until it
-- moves), so a click meant for another drop can't land on them. checkGuard runs one frame after a
-- layout that moved drops.
-- clearGuards: ends every guard at once (the setting turned off).
function History.clearGuards()
	for _, card in ipairs(cards) do
		if card.guarded then
			card.guarded = nil
			card.buttons:SetAlpha(1)
			Scale.refreshGlow(card)
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
		if History.hoverButton == button then
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
				Scale.refreshGlow(card) -- no glow or hover highlight while guarded (not only through the tooltip)
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
				Scale.refreshGlow(card) -- the glow and highlight back on the button under the mouse
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
	row.winTint = row:CreateTexture(nil, "BACKGROUND", nil, 1) -- (your win: the kept tint)
	row.winTint:SetAllPoints()
	History.setTint(row.winTint, History.KEPT_TINT)
	row.winTint:Hide()
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(Scale.iconSize, Scale.iconSize)
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
	row.when:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -6, Scale.lineTwo()) -- (the row grid: as on the drops)
	row.boss = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.boss:SetPoint("RIGHT", row.when, "LEFT", -4, 0) -- (its own text: a shortened boss name never cuts the time)
	row.boss:SetJustifyH("RIGHT")
	row.boss:SetWordWrap(false)
	row.winner = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.winner:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 24, 4)
	row.winner:SetPoint("RIGHT", row.boss, "LEFT", -6, 0)
	row.winRoll = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.winRoll:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 22, 4)
	row.winRoll:SetWidth(History.rollWidth(row.winRoll))
	row.winRoll:SetJustifyH("RIGHT")
	row.winnerIcon = row:CreateTexture(nil, "OVERLAY")
	row.winnerIcon:SetSize(14, 14)
	row.winRoll.choiceIcon = row.winnerIcon
	row.winner:SetJustifyH("LEFT")
	row.winner:SetWordWrap(false)
	row:SetScript("OnEnter", function(self)
		local e = self.entry
		if not e then return end
		History.tooltipBeside(self, self)
		if not e.link then
			GameTooltip:SetText(e.name or "Item")
			if e.demo then GameTooltip:AddLine("Demo mode: a made-up item.", 0.8, 0.8, 0.8) end
		else
			GameTooltip:SetHyperlink(e.link)
			if e.demo then GameTooltip:AddLine("Demo mode: nothing was rolled.", 0.8, 0.8, 0.8) end
		end
		GameTooltip:AddLine("Decided " .. History.when(e) .. (e.boss and (" · " .. e.boss) or ""), 0.6, 0.6, 0.6)
		if e.winner and e.winner ~= "" then
			GameTooltip:AddLine(e.winner, 1, 1, 1) -- (the row cuts a long name or boss short)
		end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", GameTooltip_Hide)
	row:SetScript("OnClick", function(self)
		local e = self.entry
		if e and e.link and not e.demo and IsModifiedClick() then
			History.itemClick(e.link) -- shift-click links it in chat, as on the list
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
			-- (yours, but saved before the winner text carried the checkmark: added here, so it never relies on colour)
			local check = e.mine == true and e.winner and not e.winner:find("common-icon-checkmark", 1, true)
			History.setWinnerLine(row.winRoll, row.winner, row.icon,
				(e.winner or "") .. (check and " |A:common-icon-checkmark:12:12|a" or ""))
			if row.winTint:IsShown() ~= (e.mine == true) then
				row.winTint:SetShown(e.mine == true)
			end
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
			History.setAlpha(row, alpha)
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
	History.setDemoOffer(main.emptyShown and not main.emptyLead and History.canDemo())
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

-- A setting indented under `parent` and greyed while `active()` is false. Not SetParentInitializer: it
-- writes the `parentInitializer` field, which the Options search reads unprotected, so an addon's value
-- there taints the search and the game blocks Blizzard's own Discord row. The indent and the live greying
-- go through the GetParentInitializer method, which this provides instead.
function History.under(init, parent, active)
	if init.AddModifyPredicate then
		init:AddModifyPredicate(active)
	end
	if parent and init.GetParentInitializer then
		init.GetParentInitializer = function()
			return parent
		end
	end
end


local category
local settingObjects = {}
-- The last value of each setting we've seen (our own table, not Blizzard's setting objects), so a callback
-- that fires with nothing changed (the Options "Defaults" buttons) isn't taken for a choice.
local seenValues = {}

local function buildPanel()
	local layoutPanel
	category, layoutPanel = Settings.RegisterVerticalLayoutCategory("RollFrames")

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

	layoutPanel:AddInitializer(CreateSettingsListSectionHeaderInitializer("Rolling"))
	checkbox("autoOpen", "Open when a roll starts",
		"Shows the window when a group loot roll starts (default: on).\n\n"
			.. "Off: the window stays closed but keeps track. Open it with the AddOns button by the minimap.\n\n"
			.. "Also: /rollframes")
	seenValues.rollFromWindow = db.rollFromWindow
	local rollHereInit = checkbox("rollFromWindow", "Roll from this window",
		"Puts Need, Greed and Pass buttons on each drop (default: off).\n\n"
			.. "While the window is open, Blizzard's roll popups stay hidden. Close the window and they come back.\n\n"
			.. "If RollFrames hits a problem, Blizzard's popups take over until you reload the UI.\n\n"
			.. "With a controller, you roll in the game's own gamepad roll list instead.",
		function()
			-- A real change, either way, answers the first-use question (seenValues: not a "Defaults" no-op).
			if db.rollFromWindow ~= seenValues.rollFromWindow then
				seenValues.rollFromWindow = db.rollFromWindow
				db.askedRollHere = true
				hideAsk(true) -- answered here (also releases a window the question opened)
			end
			applyBlizzardPopups() -- (first: turned off, the popups are back even if a drop below errors)
			Guard.core("setting", Scale.restyleRows) -- (Large roll buttons only apply with this on)
			for _, card in ipairs(cards) do
				Guard.core("setting", refreshButtons, card)
			end
		end)
	local bigInit = dropdown("rollButtons", Settings.VarType.String, "Roll button size",
		Scale.CHOICES,
		"How big the Need, Greed and Pass buttons are.\n\n"
			.. "Small: compact.\n"
			.. "Medium (default): easier to hit.\n"
			.. "Large: easier still.\n"
			.. "Extra large: Blizzard's own size.\n\n"
			.. "Bigger buttons make rows taller.\n\n"
			.. "Needs \"Roll from this window\".",
		function()
			Guard.core("setting", Scale.restyleRows)
		end)
	local highlightInit = dropdown("highlightRolls", Settings.VarType.String, "Highlight drops to roll",
		{ { "border", "Gold border" }, { "timer", "Glowing timer bar" }, { "sparkle", "Sparkles" },
			{ "all", "All three" }, { "off", "Off" } },
		"Makes drops waiting for your roll stand out. It goes as soon as you roll or the roll ends.\n\n"
			.. "Gold border (default): a gold frame that slowly brightens and dims.\n"
			.. "Glowing timer bar: the timer bar glows, with a spark at its edge.\n"
			.. "Sparkles: twinkling stars around it.\n"
			.. "All three: the border, the timer bar and the sparkles together.\n"
			.. "Off: no highlight.\n\n"
			.. "Needs \"Roll from this window\".",
		function()
			Highlight.restyle()
		end)
	local glowInit = checkbox("hoverGlow", "Glow on hovered buttons",
		"Shows a soft gold glow behind the roll button under the mouse, so you can see which one you'll click "
			.. "(default: on).\n\n"
			.. "No glow on a greyed-out button, or while Click guard holds the buttons.\n\n"
			.. "Needs \"Roll from this window\".",
		function()
			for _, card in ipairs(cards) do
				Scale.refreshGlow(card) -- (on or off at once, under the mouse; nothing else, not the tooltips)
			end
		end)
	local guardInit -- (indented under "Roll from this window", below)
	do
		-- Click guard: a checkbox, and its time on the row under it.
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
			for _, t in ipairs({ { 0.5, "0.5 seconds" }, { 1, "1 second" }, { 2, "2 seconds" }, { 3, "3 seconds" },
				{ 5, "5 seconds" }, { 0, "Until the mouse moves" } }) do
				c:Add(t[1], t[2])
			end
			return c:GetData()
		end
		local tip = "Stops misclicks when the list moves.\n\n"
			.. "If a drop's roll buttons slide under a mouse that didn't move, they dim and ignore clicks. Move the "
			.. "mouse, or wait the time chosen here, and they work again (default: on, 2 seconds).\n\n"
			.. "Until the mouse moves: no time limit.\n"
			.. "Off: the buttons work at once.\n\n"
			.. "Needs \"Roll from this window\"."
		local timeTip = "How long the buttons stay dimmed if the mouse doesn't move.\n\nNeeds \"Click guard\"."
		-- Two rows, not Blizzard's checkbox-and-dropdown row: that row isn't searchable (no single setting to
		-- take a name from), and lining its dropdown up meant a Resetter (see footerInitializer).
		local cbInit = Settings.CreateCheckbox(category, guardOn, tip)
		guardInit = cbInit
		local ddInit = Settings.CreateDropdown(category, guardTime, guardTimes, timeTip)
		-- (Blizzard re-checks a row when its parent changes: right whenever the page opens; a live switch of
		-- Roll from this window shows on the time row the next time the page is drawn.)
		History.under(ddInit, cbInit, function() return db.rollFromWindow and db.buttonGuard end)
	end
	layoutPanel:AddInitializer(CreateSettingsListSectionHeaderInitializer("Window"))
	-- (Saved key and values keep the old "Player lines" names, so choices carry over.)
	dropdown("playerLines", Settings.VarType.String, "View",
		{ { "summary", "Compact" }, { "auto", "Auto (raids: Compact)" }, { "all", "Detailed" },
			{ "none", "Items only" } },
		"What each roll shows while open.\n\n"
			.. "Compact (default): one row per drop, with how many chose Need, Greed and Pass, and your own choice.\n\n"
			.. "Auto: Detailed in a party or solo, Compact in a raid.\n\n"
			.. "Detailed: a line per player with their choice and roll. You're first, then rolls as they come in, "
			.. "then players still deciding, then passes.\n\n"
			.. "Items only: just the item, with your own choice and roll.\n\n"
			.. "Hover a drop (or its icon, with Item tooltip: Item icon only) to see the rolls. In a raid, that shows the "
			.. "Need rolls.",
		function()
			redrawLiveCards()
		end)
	-- (No Position setting: saved "attached" choices move to the starting spot, Saved.MIGRATIONS[3].)
	do
		local size = Settings.RegisterAddOnSetting(category, "ROLLFRAMES_WINDOWSIZE", "windowSize", db,
			Settings.VarType.Number, "Window size", DEFAULTS.windowSize)
		size:SetValueChangedCallback(function()
			Guard.core("setting", Scale.apply)
		end)
		settingObjects.windowSize = size
		local tip = "Makes the whole window bigger or smaller: text, icons, roll buttons and rows (default: 100%).\n\n"
			.. "The window keeps its place and stays on screen.\n\n"
			.. "Also: /rollframes size 150"
		if Settings.CreateSlider and Settings.CreateSliderOptions then
			local options = Settings.CreateSliderOptions(Scale.MIN, Scale.MAX, 5)
			local label = MinimalSliderWithSteppersMixin and MinimalSliderWithSteppersMixin.Label
			if options.SetLabelFormatter and label and label.Right then
				options:SetLabelFormatter(label.Right, function(value)
					return string.format("%d%%", value)
				end)
			end
			Settings.CreateSlider(category, size, options, tip)
		else
			Settings.CreateDropdown(category, size, function()
				local c = Settings.CreateControlTextContainer()
				for _, pct in ipairs({ 75, 90, 100, 110, 125, 150, 175, 200 }) do
					c:Add(pct, pct .. "%")
				end
				return c:GetData()
			end, tip)
		end
	end
	checkbox("autoGrow", "Grow with drops",
		"Off (default): the window keeps one height, and longer lists scroll. Drag its corner to set the height.\n\n"
			.. "On: the window grows with its drops, up to the height you drag it to, then scrolls.",
		function()
			layout()
		end)
	checkbox("snapDrag", "Snap to whole rows",
		"On: dragging the window's corner moves a whole row at a time, so the list never ends on a cut-off row.\n\n"
			.. "Off (default): the corner goes exactly where you drag it.")
	local autoHideInit = dropdown("autoHide", Settings.VarType.Number, "Hide when idle after",
		{ { 0, "Never" }, { 10, "10 seconds" }, { 15, "15 seconds" }, { 30, "30 seconds" }, { 60, "60 seconds" } },
		"Hides the window, with a short fade, when every roll has ended and nothing happens for this long "
			.. "(default: 15 seconds). A thin line under the title counts down the last seconds.\n\n"
			.. "The time restarts while your mouse is over the window.\n\n"
			.. "A window you open yourself stays until you close it. Click the pin by the close button to switch.\n\n"
			.. "Never: it stays until you close it.",
		function()
			refreshPin()
		end)
	layoutPanel:AddInitializer(CreateSettingsListSectionHeaderInitializer("History"))
	dropdown("historyFade", Settings.VarType.Number, "Finished drops stay",
		{ { 30, "30 seconds" }, { 60, "1 minute" }, { 120, "2 minutes" }, { 300, "5 minutes" }, { 0, "Until cleared" } },
		"How long a finished drop stays in the list before it moves to History, the clock in the title bar "
			.. "(default: 1 minute).\n\n"
			.. "Nothing moves while your mouse is over the window. If the window hides by itself, finished drops go to "
			.. "History at once, so the next roll starts on a clean list.\n\n"
			.. "Until cleared: up to 20 stay. Clear them with History's X.")
	dropdown("historyMinQuality", Settings.VarType.Number, "Minimum quality kept",
		{ { 0, "All items" }, { 2, "Uncommon and better" }, { 3, "Rare and better" }, { 4, "Epic and better" } },
		"After a roll ends, drops below this quality fade from the list and aren't kept in History "
			.. "(default: All items).\n\n"
			.. "Rolls in progress always show, whatever the quality.\n\n"
			.. "Every drop is still in Blizzard's loot history (/loot). Lowering this doesn't bring back drops "
			.. "already left out.",
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
		"On (default): drops from trash stay in the list and in History, like boss loot.\n\n"
			.. "Off: when its roll ends, a trash drop fades from the list and isn't kept in History. It's still in "
			.. "Blizzard's loot history (/loot).\n\n"
			.. "Boss drops show the boss's name.",
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
		"How many finished drops History keeps for this character (default: 100). History is the clock in the "
			.. "title bar.\n\n"
			.. "It's saved, so it's still there after a reload or logging out. When it's full, the oldest go.", function()
			History.trimRecords()
			if History.shown then
				relayoutPending = true
				driver:Show()
			end
		end)


	layoutPanel:AddInitializer(CreateSettingsListSectionHeaderInitializer("Tooltips"))
	dropdown("itemTooltip", Settings.VarType.String, "Item tooltip",
		{ { "drop", "Whole drop" }, { "icon", "Item icon only" } },
		"Where a drop shows its item's tooltip, beside the window at the drop's top.\n\n"
			.. "Whole drop (default): anywhere on the drop. It stays up as you move to the roll buttons.\n\n"
			.. "Item icon only: only the item's icon, as on Blizzard's roll popup.\n\n"
			.. "Comparing with what you have equipped follows the game: hold Shift, unless the game is set to always "
			.. "compare.")
	checkbox("buttonTips", "Roll button tooltips",
		"On (default): a small tip by the roll button under your mouse says which roll it is, why you can't "
			.. "choose it, or that the list just moved.\n\n"
			.. "Off: no tip. The item's tooltip still shows, with Click guard's line while it holds.\n\n"
			.. "Applies when Roll from this window is on.")
	checkbox("tooltipGameSpot", "Tooltips at game's spot",
		"On: the tooltips that open beside the window (a drop's item, a History row, the empty window's buttons) open "
			.. "where the game shows its own (bottom right, unless you've moved them). Tooltip addons that move "
			.. "tooltips apply here too.\n\n"
			.. "Off (default): beside the window, level with the drop.\n\n"
			.. "The small tips by the roll buttons stay by the buttons.")

	layoutPanel:AddInitializer(CreateSettingsListSectionHeaderInitializer("Motion and flashing"))
	checkbox("noMotion", "No animations",
		"Everything appears, changes and goes at once: no fades, slides, sweeps, pulses or flashes "
			.. "(default: off).\n\n"
			.. "The roll timers still count down.\n\n"
			.. "While it's on, Flashing and Sweep when a roll ends have no effect.",
		function()
			if db.noMotion then
				History.finishTweens()
				History.stopFlash()
			end
			Highlight.restyle()
		end)
	local flashInit = dropdown("flashing", Settings.VarType.String, "Flashing",
		{ { "normal", "Normal" }, { "persist", "Until noticed" }, { "off", "Off" } },
		"Normal (default): highlights and the \"more to roll\" bars pulse. If new loot arrives while History is "
			.. "open, the window's edge flashes once.\n\n"
			.. "Until noticed: as Normal, but that flash repeats until you move the mouse over the window.\n\n"
			.. "Off: nothing flashes, pulses or sweeps. Highlights and bars stay steady; Sparkles shows as a gold border.",
		function()
			if db.flashing == "off" then
				History.stopFlash()
			end
			Highlight.restyle()
		end)
	local sweepInit = checkbox("resultSweep", "Sweep when a roll ends",
		"A soft band crosses the drop once when its roll ends (default: on).\n\n"
			.. "Compact and Items only: gold if you win, grey if someone else does.\n"
			.. "Detailed: gold on the winner's line.\n\n"
			.. "Off: no sweep (your wins keep a tint).\n\n"
			.. "Greyed while Flashing is Off: nothing sweeps then.")
	if sweepInit and flashInit then
		History.under(sweepInit, flashInit, function()
			return db.flashing ~= "off"
		end)
	end
	local function rollingHere()
		return db.rollFromWindow
	end
	for _, init in ipairs({ bigInit, highlightInit, glowInit, guardInit }) do
		if init then
			History.under(init, rollHereInit, rollingHere)
		end
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

-- (H: the sample drop shows the default roll button size, whose row may be taller: Scale.LOOK.)
Ask = { W = WIDTH, H = 206 + Scale.LOOK[DEFAULTS.rollButtons].extra, sampleTime = 30 } -- (one table: the file is near Lua's 200-locals limit)
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
		Guard.core("setting", Scale.restyleRows) -- (Large roll buttons only apply with this on)
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
	screenTop = screenTop and Scale.toMain(UIParent, screenTop) -- (in the window's units: Window size)
	local barsTop = bottomContainer() and Scale.toMain(bottomContainer(), bottomContainer():GetTop()) or 0
	local where
	if not (top and bottom and screenTop) or top + Ask.H + 8 <= screenTop then
		where = "above"
	elseif db.position ~= "attached" and bottom - Ask.H - 8 >= barsTop then
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
	f:SetFrameStrata(main:GetFrameStrata()) -- (the window's layer: never over Options when the window isn't)
	f:EnableMouse(true)
	-- Drag it like the window's title bar: it moves the window (and switches it to Free, as dragging the
	-- window does). Its buttons take their own clicks, so they never start a drag.
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self)
		self.dragging = true
		History.startMove()
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
	f.text:SetText("Adds Need, Greed and Pass buttons to each drop here. Blizzard's roll popups stay hidden while "
		.. "this window is open, and come back when you close it. Try the sample:")

	-- The sample drop: an item, a timer and the roll buttons. Clicking only shows what would happen.
	local row = CreateFrame("Frame", nil, f)
	f.sample = row
	local look = Scale.LOOK[DEFAULTS.rollButtons] -- (the sample shows the buttons at the default size)
	row:SetSize(Ask.W - 24, 34 + look.extra)
	row:SetPoint("TOPLEFT", f.text, "BOTTOMLEFT", 0, -8)
	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	row.bg:SetColorTexture(1, 1, 1, 0.05)
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(look.icon or ICON, look.icon or ICON)
	row.icon:SetPoint("TOPLEFT", 3, -3)
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
	row.timer:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 6,
		look.extra > 0 and (look.top - look.size - 3 + (look.icon or ICON)) or 1) -- (2 px under the buttons, as Scale.timerY)
	row.timer:SetPoint("RIGHT", row, "RIGHT", -6, 0)
	row.timer.bg = row.timer:CreateTexture(nil, "BACKGROUND")
	row.timer.bg:SetAllPoints()
	row.timer.bg:SetColorTexture(0, 0, 0, 0.5)
	row.choice = row:CreateTexture(nil, "ARTWORK") -- your sample choice, where the buttons were
	row.choice:SetSize(look.size, look.size) -- (exactly where Pass was, at its size, as on a real drop)
	row.choice:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, look.top)
	row.choice:Hide()
	row.buttons = {}
	for _, spec in ipairs(ROLL_BUTTONS) do
		if spec.type ~= 4 then -- (no Transmog in the sample)
			local b = CreateFrame("Button", nil, row)
			b:SetSize(look.size, look.size)
			b:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4 - spec.spot * look.step, look.top)
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
				f.note:SetText("That's it: one click on the drop. Nothing was rolled.")
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
		say("Roll from this window is on. Change it any time in Options > AddOns > RollFrames (Rolling).")
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
	f.later:SetText("Change it any time: Options > AddOns > RollFrames, Roll from this window.")
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
	if askShown or db.askedRollHere or History.rollsHere() or Guard.fallback or Guard.off.ask or InCombatLockdown() or Ask.anyRealDrop(true)
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
			-- A size that's no longer offered or a damaged one: back to the
			-- default, so the Options dropdown shows a real choice, not "Custom".
			if rawget(db, "rollButtons") ~= nil and not Scale.LOOK[rawget(db, "rollButtons")] then
				db.rollButtons = nil
			end
			Scale.setRows() -- (row height for the bigger roll buttons, before anything is built)
			History.load()
			createMain()
			refreshPin()
			main:HookScript("OnShow", applyBlizzardPopups)
			-- Controller mode switched on or off (INPUT_DEVICE_INTERFACE_TRANSITION): roll buttons go or come back.
			-- The plain event, not InputUtil's callbacks, which would write into Blizzard's own tables.
			function History.controllerChanged()
				applyBlizzardPopups()
				Scale.restyleRows()
				for _, card in ipairs(cards) do
					refreshButtons(card)
				end
				History.updateStrata()
				History.placeClock()
			end
			pcall(self.RegisterEvent, self, "INPUT_DEVICE_INTERFACE_TRANSITION")
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
							relayoutPending = true -- more popups: less room above them
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
				pcall(Guard.note, "settings", err)
				say("the settings page couldn't load. Your settings still apply; try /reload. /rollframes diag shows "
					.. "the error for a bug report.")
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
			C_Timer.After(4, Guard.wrap("ask", function()
				if not (db.askedRollHere or History.rollsHere()) and not maybeAsk("login") and InCombatLockdown() then
					askPutAway = true
				end
			end))
			if ConfirmLootRoll then -- bind-on-pickup confirmation (only if a confirm can be told from a cancel)
				pcall(self.RegisterEvent, self, "CONFIRM_LOOT_ROLL")
			end
			pcall(self.RegisterEvent, self, "CANCEL_ALL_LOOT_ROLLS")
			-- Rolls made anywhere (Blizzard's popups, other addons) count against the twins pool, and a
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
		elseif event == "INPUT_DEVICE_INTERFACE_TRANSITION" then
			History.controllerChanged()
		elseif event == "PLAYER_REGEN_DISABLED" then
			Guard.call("ask", Ask.putAway, true) -- never in combat
		elseif event == "PLAYER_REGEN_ENABLED" then
			-- Feign Death, Vanish or dying also end combat mid-fight, so a put-away question gets one try 5 s
			-- later, only if this is still the newest combat end (chain pulls); else next open or login.
			Ask.combatEnded = GetTime()
			if askPutAway then
				local endedAt = Ask.combatEnded
				C_Timer.After(5.5, Guard.wrap("ask", function()
					if Ask.combatEnded ~= endedAt or InCombatLockdown() then
						return
					end
					if askPutAway and not (db.askedRollHere or History.rollsHere()) then
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
	local version = "?"
	pcall(function()
		local get = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
		version = get and get(ADDON, "Version") or "?"
	end)
	local views = { summary = "Compact", auto = "Auto", all = "Detailed", none = "Items only" }
	local here = History.rollsHere()
	local pad = db.rollFromWindow and not here -- (on, but controller mode: the game's gamepad roll list)
	say(string.format("status for a bug report (no names): version %s | View: %s | Roll from this window: %s | "
		.. "window size %d%%", tostring(version), views[db.playerLines] or "?",
		db.rollFromWindow and (pad and "on (controller mode)" or "on") or "off", math.floor(Scale.get() * 100 + 0.5)))
	say("rolling in:", Guard.fallback and "Blizzard's popups (after an error)"
		or (here and "this window" or (pad and "the game's gamepad roll list (controller mode)"
			or "Blizzard's popups (Roll from this window is off)")))
	local encounters = C_LootHistory.GetAllEncounterInfos() or {}
	say("Blizzard's loot history this session:", #encounters, #encounters == 1 and "boss" or "bosses")
	for _, e in ipairs(encounters) do
		local drops = C_LootHistory.GetSortedDropsForEncounter(e.encounterID) or {}
		say(string.format("  %s (id %s): %d drops", tostring(safe(e.encounterName, "?")), tostring(e.encounterID),
			#drops))
	end
	say("drops in the window:", #cards, "| troubleshooting log:", db.debugLog and "on" or "off", "(" ..
		(db.log and #db.log or 0) .. " entries)")
	local off = {}
	for name in pairs(Guard.off) do
		off[#off + 1] = name
	end
	table.sort(off)
	say("turned off after an error this session:", #off > 0 and table.concat(off, ", ") or "nothing")
	if db.lastError then
		say("last error:", db.lastError)
	end
	say("frames made:", framesMade.cards, "drop rows,", framesMade.lines, "player lines | spare:", #cardPool, "rows,",
		#linePool, "lines")
end

--@debug@
-- Twins demo (dev builds only): two copies of one item drop at the same moment and, as can happen in a
-- raid, the loot history pairs them the wrong way round. Click a copy: your choice shows on the other
-- one, and the copy you clicked offers buttons again for your second roll.
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
		.. (History.rollsHere() and " Click Need on one: it shows on the other, and the one you clicked offers your second roll."
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
		if not card.finished and not card.demo then -- (rolls really open: not the demo, not a winner still showing)
			open = open + 1
		end
	end
	if open > 0 then
		GameTooltip:AddLine(string.format("%d roll%s in progress", open, open == 1 and "" or "s"), 1, 0.82, 0)
	end
	GameTooltip:AddLine("Left-click: show or hide the window", 0.8, 0.8, 0.8)
	GameTooltip:AddLine("Right-click: Options", 0.8, 0.8, 0.8)
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
			say("the demo hit a problem and is off until you /reload.")
		else
			Guard.call("demo", runDemo, tonumber(command:match("%d+")) or 3)
		end
	elseif command == "options" and not category then
		say("the settings page isn't available this session; try /reload.")
	elseif command == "options" and category then
		Settings.OpenToCategory(category:GetID())
	elseif command == "reset all" then
		History.askResetAll()
	elseif command == "reset" then
		db.position = nil -- (the defaults: free, on the right beside the quest tracker)
		db.point = nil
		db.maxHeight = nil
		db.height = nil
		if settingObjects.windowSize then
			settingObjects.windowSize:SetValue(DEFAULTS.windowSize) -- (an open Options page follows)
		end
		db.windowSize = nil
		main:SetScale(Scale.get())
		applyPosition()
		layout()
		say("window back to its starting spot (right side, beside the quest tracker), starting height and 100% size.")
	elseif command == "size" or command:match("^size%s") then
		local want = tonumber(command:match("^size%s+(%d+)%%?$"))
		if not want then
			say("window size: " .. math.floor(Scale.get() * 100 + 0.5) .. "%. Change it with /rollframes size 75-200, "
				.. "or in Options > AddOns > RollFrames (Window).")
			return
		end
		local asked = want
		want = math.max(Scale.MIN, math.min(Scale.MAX, math.floor(want / 5 + 0.5) * 5)) -- (the slider's steps)
		if settingObjects.windowSize then
			settingObjects.windowSize:SetValue(want) -- (calls Scale.apply; an open Options page follows)
		else
			db.windowSize = want
		end
		Scale.apply()
		local why = asked > Scale.MAX and " (largest is 200%)" or asked < Scale.MIN and " (smallest is 75%)"
			or asked ~= want and " (sizes go in steps of 5)" or ""
		say("window size: " .. want .. "%" .. why)
	elseif command == "blizzard" then
		ToggleLootHistoryFrame()
	elseif command == "diag" then
		diag()
	elseif command == "diag log" then
		db.debugLog = not db.debugLog
		say(db.debugLog and "troubleshooting log on (no names). It's saved when you /reload or log out; /rollframes diag "
			.. "log turns it off." or "troubleshooting log off.")
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
	elseif command == "buttons" or command:match("^buttons%s") then
		-- "/rollframes buttons" cycles the sizes, or name one. Same as the setting.
		local want = command:match("^buttons%s+(%S+)$")
		local at = 0
		for i, choice in ipairs(Scale.CHOICES) do
			if choice[1] == (want or db.rollButtons) then at = i end
		end
		if want and at == 0 then
			local names = {}
			for _, choice in ipairs(Scale.CHOICES) do names[#names + 1] = choice[1] end
			say("roll button sizes:", table.concat(names, ", "))
			return
		end
		want = want or Scale.CHOICES[at % #Scale.CHOICES + 1][1]
		if settingObjects.rollButtons then
			settingObjects.rollButtons:SetValue(want) -- (also updates an open Options page; restyles)
		else
			db.rollButtons = want
			Guard.core("setting", Scale.restyleRows)
		end
		local look = Scale.LOOK[want] or Scale.look() -- (the chosen size, even with Roll from this window off)
		say("roll buttons:", want, "(" .. look.size .. " px, " .. (look.step - look.size) .. " px apart, rows +"
			.. look.extra .. ")", History.rollsHere() and "" or "(turn on Roll from this window to see them)")
	elseif command == "demo real" or command:match("^demo real%s+%d+$") then
		-- The demo with real items from this character's History (tooltips, item levels, Shift comparisons),
		-- in the demo's usual order of boss, trash, 100 and all-pass drops. Made-up items when History has none.
		local seen, real = {}, {}
		for _, rec in ipairs(History.records) do
			local link = rec.link
			if type(link) == "string" and not isSecret(link) and link:find("|Hitem:", 1, true) and not seen[link] then
				seen[link] = true
				real[#real + 1] = link
			end
		end
		for i = #real, 2, -1 do -- (a different mix each time)
			local j = math.random(i)
			real[i], real[j] = real[j], real[i]
		end
		local count = math.max(1, math.min(tonumber(command:match("%d+")) or 3, 20))
		local items = {}
		for i = 1, math.min(count, #real) do
			local base = DEMO_ITEMS[(i - 1) % #DEMO_ITEMS + 1]
			items[i] = { link = real[i], boss = base.boss, topRoll = base.topRoll, allPass = base.allPass }
		end
		if #items == 0 then
			say("demo real: no items in this character's History yet, so the made-up ones.")
		end
		if Guard.off.demo then
			say("the demo hit a problem and is off until you /reload.")
		else
			Guard.call("demo", runDemo, count, items)
		end
	elseif command == "lines" then
		-- Troubleshooting Detailed view: each listed drop's player lines (counts, visibility, alpha, fades).
		-- No names: line numbers only.
		local ghosts = 0 -- (a pooled drop still showing would be a drop on screen that isn't listed below)
		for _, c in ipairs(cardPool) do
			if c.frame:IsShown() then ghosts = ghosts + 1 end
		end
		say("player lines per drop (View: " .. tostring(db.playerLines) .. ", No animations: " .. tostring(db.noMotion)
			.. ", drops listed " .. #cards .. ", pooled drops still showing " .. ghosts .. "):")
		for i, card in ipairs(cards) do
			local n, shown, vis, low, fades, paused, offCard, under = 0, 0, 0, 1, 0, 0, 0, 0
			local strata, tiny, noText, nameLow, unplaced = 0, 0, 0, 1, 0
			for _, line in pairs(card.lines) do
				n = n + 1
				if line:GetFrameLevel() <= card.frame:GetFrameLevel() then under = under + 1 end
				if line:GetFrameStrata() ~= card.frame:GetFrameStrata() then strata = strata + 1 end
				if (line:GetWidth() or 0) < 1 or (line:GetHeight() or 0) < 1 then tiny = tiny + 1 end
				if (line.name:GetText() or "") == "" then noText = noText + 1 end
				if not line.name:IsVisible() then nameLow = 0 end
				if not line:GetPoint(1) then unplaced = unplaced + 1 end
				if line:IsShown() then shown = shown + 1 end
				if line:IsVisible() then vis = vis + 1 end
				low = math.min(low, line:GetAlpha(), line.name:GetAlpha())
				if line:GetParent() ~= card.frame then offCard = offCard + 1 end
				local f = line.rfFade
				if f and f.group:IsPlaying() then fades = fades + 1 end
				if f and f.group.IsPaused and f.group:IsPaused() then paused = paused + 1 end
			end
			say(string.format("%d: %s, mode %s, height %d, frame alpha %.2f, lines %d (shown %d, visible %d, lowest alpha %.2f, "
				.. "fading %d, paused %d, not on this drop %d, under the drop %d), reserved %s, collapsed %s, pooled lines %d", i,
				card.demo and "demo" or "real", tostring(card.linesMode), math.floor(card.frame:GetHeight() + 0.5),
				card.frame:GetAlpha(), n, shown, vis, n > 0 and low or 1, fades, paused, offCard, under, tostring(card.reserved),
				tostring(card.collapsed), #linePool))
			say(string.format("   drop layer %s level %d; lines on another layer %d, no size %d, no name text %d, name not visible %s, "
				.. "unanchored %d", card.frame:GetFrameStrata(), card.frame:GetFrameLevel(), strata, tiny, noText,
				nameLow == 0 and "yes" or "no", unplaced))
			-- Where the game actually draws them, the alpha it draws them with, and any engine animation on them.
			local function call(f, method)
				local ok, a, b, c, d = pcall(f[method] or function() end, f)
				if ok then return a, b, c, d end
			end
			local cl, cb, cw, ch = call(card.frame, "GetRect")
			local sl, sb, sw, sh = call(scroll, "GetRect")
			local outside, offScreen, effLow, anims = 0, 0, 1, 0
			local first
			for _, key in ipairs(card.lineOrder) do
				local line = card.lines[key]
				if line then
					local l, b, w, h = call(line, "GetRect")
					first = first or { l, b, w, h }
					if not (l and cl) or l + w < cl or l > cl + cw or b + h < cb or b > cb + ch then outside = outside + 1 end
					if not (l and sl) or l + w < sl or l > sl + sw or b + h < sb or b > sb + sh then offScreen = offScreen + 1 end
					effLow = math.min(effLow, call(line, "GetEffectiveAlpha") or 1, call(line.name, "GetEffectiveAlpha") or 1)
					for _, g in ipairs({ call(line, "GetAnimationGroups") }) do
						if g:IsPlaying() then anims = anims + 1 end
					end
				end
			end
			local dropAnims = 0
			for _, g in ipairs({ call(card.frame, "GetAnimationGroups") }) do
				if g:IsPlaying() then dropAnims = dropAnims + 1 end
			end
			local function num(v) return v and string.format("%.0f", v) or "?" end
			say(string.format("   drop at %s,%s %sx%s; first line at %s,%s %sx%s; lines outside the drop %d, outside the list %d, "
				.. "lowest drawn alpha %.2f, line animations playing %d, drop animations playing %d",
				num(cl), num(cb), num(cw), num(ch), num(first and first[1]), num(first and first[2]), num(first and first[3]),
				num(first and first[4]), outside, offScreen, effLow, anims, dropAnims))
		end
	elseif command == "columns" then
		-- Try the winner line with the roll in its own column, and back.
		History.ROLL_COLUMN = not History.ROLL_COLUMN
		for _, card in ipairs(cards) do
			card.winnerText.lineText = nil
			if card.winnerFull then
				History.setWinnerLine(card.winnerRoll, card.winnerText, card.icon, card.winnerFull)
			end
		end
		for _, row in pairs(History.rows) do
			row.winner.lineText = nil
		end
		relayoutPending = true
		driver:Show()
		say("winner roll column:", History.ROLL_COLUMN and "on" or "off")
	elseif command == "highlight" or command:match("^highlight%s") then
		-- "/rollframes highlight" cycles the styles, or name one. Same as the setting.
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
		say("highlight:", want, History.rollsHere() and "" or "(turn on Roll from this window to see it)")
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
		say("commands: /rollframes (show or hide) | demo [1-20] | options | size [75-200] | reset (window spot and size) "
			.. "| reset all (everything, asks first) | blizzard (Blizzard's loot history) | diag (status for bug reports) "
			.. "| diag log (troubleshooting log on/off)")
	end
end
