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
local MAX_HEIGHT = 560 -- default for the user's height limit (db.maxHeight), set by dragging the resize grip
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
	playerLines = "auto",
	hoverHoldsFade = true, -- hovering the window restarts the idle time
	keepTrash = true, -- false: drops from trash (encounter 0) leave the history once decided
	position = "attached", -- or "free"
	holdSeconds = 5,
	autoHide = 15, -- seconds after the last activity; 0 = never
	historyCount = 10,
	historyMinQuality = 0, -- 0 = keep every item in the history; 2/3/4 = uncommon/rare/epic and better
	fixedHeight = false, -- true: always the height set with the grip (longer lists scroll); false: grows with drops
	maxHeight = MAX_HEIGHT, -- the window grows with its drops up to this height, then scrolls
}

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
local skippedHistory = {} -- "encounterID:lootListKey" of drops left out of the history; later updates are ignored
local dismissCard -- forward declaration (defined with the frame pool)
local nextCardID = 0
local fallback = false -- set if RollFrames errors while handling rolls; Blizzard's popups come back
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

local function classColored(name, class)
	local color = class and (C_ClassColor and C_ClassColor.GetClassColor(class) or RAID_CLASS_COLORS[class])
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
	if main and not main:IsVisible() then
		tweens[key] = nil
		fn(1)
		if done then
			done()
		end
		driver:Show() -- one frame, so a pending history trim still runs while hidden (the driver does it)
		return
	end
	tweens[key] = { duration = math.max(duration, 0.01), elapsed = 0, fn = fn, done = done, linear = linear }
	driver:Show()
end

local relayoutPending = false
local finished = {} -- scratch list of tweens that ended this frame, emptied after each use
-- Time spent in the driver, measured only while the dev stress test sets `profiling` (off otherwise).
local profiling, driverMs = false, 0
local trimHistory -- forward declaration (defined with the cards)
driver:SetScript("OnUpdate", function(self, elapsed)
	local profileStart = profiling and debugprofilestop()
	-- Start clean every frame, so an error in some tween's finish step last frame can't leave entries behind.
	wipe(finished)
	for key, t in pairs(tweens) do
		t.elapsed = t.elapsed + elapsed
		local p = math.min(1, t.elapsed / t.duration)
		t.fn(t.linear and p or easeOut(p))
		if p >= 1 then
			finished[#finished + 1] = key
		end
	end
	for i = 1, #finished do
		local key = finished[i]
		finished[i] = nil
		local t = tweens[key]
		tweens[key] = nil
		if t and t.done then
			t.done()
		end
	end
	-- While the window is hidden, a relayout waits: the window lays itself out once when it opens.
	-- Trimming the history doesn't wait, so cards still go back for reuse with the window closed.
	if relayoutPending and main and main:IsShown() then
		relayoutPending = false
		layout()
	elseif trimPending and not (main and main:IsShown()) then
		trimPending = false
		trimHistory()
	end
	if markersDirty and main and main:IsShown() then
		markersDirty = false
		updateRollMarkers()
	end
	if profileStart then
		driverMs = driverMs + debugprofilestop() - profileStart
	end
	if next(tweens) == nil then
		self:Hide()
	end
end)

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
		main:SetPoint("TOP", UIParent, "CENTER", 0, 320) -- free, never dragged: by its top, so it grows downward
	end
end

-- Which end of the list new drops appear at: the side the window grows from (see layout).
local function newestAtBottom()
	return anchorFactor ~= 1 -- attached grows upward: newest on top; free grows downward: newest at the bottom
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
	end)
	main:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		savePosition()
		applyPosition() -- anchor by the saved top-left corner (the window is free now)
		layout() -- grip to its corner for a free window
	end)
	main:Hide()

	local titleText = main.TitleContainer and main.TitleContainer.TitleText
	if titleText then
		titleText:SetText("Loot Rolls")
	else
		local title = main:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		title:SetPoint("TOP", 0, -8)
		title:SetText("Loot Rolls")
	end
	local close = CreateFrame("Button", nil, main, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 2, 1)

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
	countdown:SetScript("OnUpdate", function(self)
		if db.hoverHoldsFade and main:IsMouseOver() then
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
	end)
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
	local since = 0
	watch:SetScript("OnUpdate", function(_, elapsed)
		since = since + elapsed
		if since < 0.1 then
			return
		end
		since = 0
		setChrome(main:IsMouseOver() and 1 or CHROME_IDLE_ALPHA)
	end)
	watch:Hide()
	main.chromeWatch = watch
	main:HookScript("OnHide", function()
		if not main:IsShown() then -- closed itself; not just hidden with the whole UI (Alt-Z, cinematics)
			setPinned(false) -- the next window opened by a roll fades as usual
		end
	end)

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
	main.emptyHint:SetText("Group loot rolls appear here. Try /rollframes demo")
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
		m:SetScript("OnClick", function(self)
			scrollToWaitingFn(self.up)
		end)
		-- Pulse: one slow breath every 1.6 s (only runs while the bar shows).
		m:SetScript("OnUpdate", function(self, elapsed)
			self.t = ((self.t or 0) + elapsed) % 1.6
			local level = 0.5 - 0.5 * math.cos(self.t / 1.6 * 2 * math.pi) -- 0 -> 1 -> 0
			self.glow:SetAlpha(0.16 * level)
			self.line:SetAlpha(0.45 + 0.55 * level)
		end)
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
		self:SetScript("OnUpdate", function()
			local _, y = GetCursorPosition()
			local delta = (y - self.startY) / main:GetEffectiveScale()
			if db.position ~= "attached" then
				delta = -delta -- the grip is at the bottom: dragging down makes it taller
			end
			local maxAllowed = math.max(MIN_HEIGHT, math.min(UIParent:GetHeight() - 40, roomAbovePopups() or math.huge))
			db.maxHeight = math.floor(math.max(MIN_HEIGHT, math.min(maxAllowed, self.startHeight + delta)))
			main:SetHeight(db.maxHeight)
		end)
	end)
	grip:SetScript("OnMouseUp", function(self)
		self:SetScript("OnUpdate", nil)
		layout() -- shrinks back to the drops if they need less than the new limit
	end)

	-- Catch up on any relayout that waited while the window was hidden, before its first visible frame.
	main:HookScript("OnShow", function()
		if db.position == "attached" then
			applyPosition() -- the popups' spot may have changed, or not been known at login
		end
		scrollToNewestPending = true -- open at the newest drops (and the rolls in progress); older ones are a scroll away
		relayoutPending = false
		layout()
	end)

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
		return HEADER_H + LINE_H + 6
	end
	return HEADER_H + math.max(#card.lineOrder, card.reserved or 0) * LINE_H + 6
end

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
	card.waiting:ClearAllPoints()
	card.waiting:SetPoint("TOPLEFT", card.frame, "TOPLEFT", ICON + 14, -(HEADER_H + 2))
	card.waiting:SetPoint("RIGHT", card.frame, "RIGHT", -6, 0)
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
	if line.shown and line.shownState == entry.state and line.shownName == entry.name
		and line.shownClass == entry.class and line.shownRoll == entry.roll and line.shownSelf == isSelf
		and line.shownDone == done then
		return
	end
	line.shown, line.shownState, line.shownName, line.shownClass, line.shownRoll, line.shownSelf, line.shownDone =
		true, entry.state, entry.name, entry.class, entry.roll, isSelf, done
	-- Passes are dimmed: they sit at the bottom and matter least.
	local alpha = entry.state == STATE.PASS and 0.55 or 1
	line.name:SetAlpha(alpha)
	line.icon:SetAlpha(alpha)
	if entry.state == STATE.NOROLL then
		line.icon:Hide() -- not chosen yet: no icon
	else
		line.icon:SetAtlas(STATE_ATLAS[entry.state] or STATE_ATLAS[STATE.PASS])
		line.icon:Show()
	end
	local name = classColored(entry.name, entry.class)
	if entry.state == STATE.NEED_OFF then
		name = name .. " |cff999999(off-spec)|r"
	end
	line.name:SetText(name)
	line.selfBg:SetShown(isSelf)
	line.selfMark:SetShown(isSelf)
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
	tween(card.id .. ":winbg", 0.4, function(p)
		line.bg:SetColorTexture(1, 0.82, 0.2, 0.28 * p)
	end)
	local width = line:GetWidth() > 0 and line:GetWidth() or (WIDTH - ICON - 40)
	local function sweep(times)
		line.shine:Show()
		tween(card.id .. ":shine", 0.7, function(p)
			line.shine:ClearAllPoints()
			line.shine:SetPoint("LEFT", line, "LEFT", -60 + (width + 60) * p, 0)
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
		if not card.collapsed and card.layoutY and card.buttons:IsShown() and card.frame:IsMouseOver() then
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
		local since = 0
		holdWatch:SetScript("OnUpdate", function(self, elapsed)
			since = since + elapsed
			if since < 0.1 then
				return
			end
			since = 0
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
		end)
	end
	holdWatch:Show()
end

-- Fills the item row's bottom line with the winner (or "All passed").
local function updateHeaderWinner(card)
	if card.allPassed then
		card.winnerText:SetText("|cffff5555All passed|r")
		card.winnerIcon:Hide()
	elseif card.winner then
		local w = card.winner
		card.winnerText:SetText(classColored(w.name, w.class) .. (w.roll and ("  |cffffd100" .. w.roll .. "|r") or ""))
		card.winnerIcon:SetAtlas(STATE_ATLAS[w.state] or STATE_ATLAS[STATE.GREED])
		card.winnerIcon:Show()
	end
end

-- Fades the winner in on the item row (from wherever it is, so a winner already showing doesn't flicker).
local function showHeaderWinner(card, key)
	updateHeaderWinner(card)
	local from = card.winnerText:GetAlpha()
	tween(card.id .. (key or ":winner"), 0.35, function(p)
		local a = from + (1 - from) * p
		card.winnerText:SetAlpha(a)
		card.winnerIcon:SetAlpha(a)
	end)
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
	card.lastRolls = nil -- history rows don't show the roll list
	trimPending = true
	card.timer:Hide()
	card.buttons:Hide()
	card.mineIcon:Hide()
	card.mineRoll:Hide()
	placeHeader(card)
	if card.bossName then
		-- The boss name takes what it needs (up to 110 px); the winner's name is cut short before it.
		card.boss:SetText(card.bossName)
		local w = card.boss.GetUnboundedStringWidth and card.boss:GetUnboundedStringWidth()
		card.boss:SetWidth(math.min(110, (w or 110) + 2))
		card.boss:Show()
		card.winnerText:SetPoint("RIGHT", card.boss, "LEFT", -6, 0)
	end
	showHeaderWinner(card, ":collapse-winner")
	tween(card.id .. ":collapse", 0.35, function(p)
		for _, line in pairs(card.lines) do
			line:SetAlpha(1 - p)
		end
		card.waiting:SetAlpha(1 - p)
	end, function()
		for _, line in pairs(card.lines) do
			line:Hide()
		end
		card.waiting:Hide()
		card.waitingHit:Hide()
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
		-- No player lines to highlight: the winner shows on the item row straight away.
		card.mineIcon:Hide()
		card.mineRoll:Hide()
		placeHeader(card)
		showHeaderWinner(card)
		refreshSummary(card)
	end
	if card.instant then
		collapse(card)
		return
	end
	local gen = card.gen
	C_Timer.After(db.holdSeconds, function()
		if card.gen == gen then -- the card may have been reused for another drop meanwhile
			collapse(card)
		end
	end)
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
		local since = 0
		confirmWatch:SetScript("OnUpdate", function(self, elapsed) -- only while a confirmation is open
			since = since + elapsed
			if since < 0.25 then
				return
			end
			since = 0
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
		end)
	end
	confirmWatch:Show()
end

local function cardRollTypes(card)
	local rollID = card.rollID
	if not rollID and card.twins then
		local open = twinOpenRoll(card.twins, nil) -- (its own roll ended: the roll a click would use)
		rollID = type(open) == "number" and open or nil
	end
	if not rollID or card.demo then
		return { canNeed = true, canGreed = true, canTransmog = false }
	end
	local ok, _, _, _, _, _, canNeed, canGreed, _, _, _, _, _, canTransmog = pcall(GetLootRollItemInfo, rollID)
	if not ok then
		return { canNeed = true, canGreed = true }
	end
	return { canNeed = canNeed, canGreed = canGreed, canTransmog = canTransmog }
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
		button:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText(spec.label)
			if not self:IsEnabled() then
				GameTooltip:AddLine("Not available for this item.", 0.8, 0.8, 0.8)
			end
			GameTooltip:Show()
		end)
		button:SetScript("OnLeave", GameTooltip_Hide)
		button:SetScript("OnMouseDown", function(self)
			self.pressedAt = GetTime()
		end)
		button:SetScript("OnClick", function(self)
			if not self:IsEnabled() then
				return -- greyed out: not available for this item
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
		end)
		bar.list[#bar.list + 1] = button
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
		card.ilvl:SetPoint("TOPRIGHT", card.mineIcon, "TOPLEFT", -4, -1)
	else
		card.ilvl:SetPoint("TOPRIGHT", card.frame, "TOPRIGHT", -6, -5)
	end
	card.name:ClearAllPoints()
	card.name:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 6, -2)
	card.name:SetPoint("RIGHT", card.ilvl, "LEFT", -4, 0)
end

refreshButtons = function(card)
	if not (db.rollFromWindow and not fallback and (card.rollID or card.demoWaitsForYou or card.twins)
		and not card.finished and not card.youRolled
		and not (card.twins and twinOpenRoll(card.twins, ownRoll(card)) == nil)) then
		card.buttons:Hide()
		placeHeader(card)
		return
	end
	-- Need, Greed and Pass keep their spots on every drop, so fast clicking down the list always hits the
	-- same choice; one this item doesn't allow is greyed out instead of removed. Transmog shows (far left)
	-- only when the roll allows it.
	local can = cardRollTypes(card)
	local wide = false
	for _, button in ipairs(card.buttons.list) do
		local spec = button.spec
		local allowed = (not spec.can or can[spec.can]) and true or false
		if spec.onlyIfAllowed then
			button:SetShown(allowed)
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
	card.buttons:Show()
	placeHeader(card)
end

----------------------------------------------------------------------------------------------------
-- Frame reuse. WoW never frees a frame, so a long raid night would otherwise keep every drop's card
-- and roll lines in memory until a reload. Cards leaving the history (and demo cards) go back to these
-- pools, reset, and new drops take from them before creating anything.
----------------------------------------------------------------------------------------------------

local cardPool, linePool = {}, {}
local framesMade = { cards = 0, lines = 0 } -- how many were ever created (for /rollframes diag and the stress test)

-- Card fields that describe one drop; cleared when a card is reused. Frames and widgets are kept.
local DROP_FIELDS = {
	"link", "historyKey", "rollID", "rollTime", "duration", "endsAt", "finished", "collapsed", "allPassed",
	"winner", "winnerKey", "youRolled", "demoRoll", "demoWaitsForYou", "twins", "clickRoll", "rollStarted", "itemKey", "keyLink", "selfState",
	"itemName", "itemShown", "shownLink", "shownNameArg", "shownIconArg", "shownQualityArg", "ilvlSettled",
	"height", "headerMode", "timerRed", "demo", "instant", "created", "summaryPlaced",
	"quality", "dismissing", "reserved", "hadRolls", "lastRolls", "mineState", "mineRollShown", "encounterID",
	"bossName", "isTrash", "layoutY", "listY", "summaryKey", "clickedState", "linesMode", "selfReported",
}

local function acquireLine(card)
	local line = table.remove(linePool)
	if not line then
		framesMade.lines = framesMade.lines + 1
		return createLine(card)
	end
	line:SetParent(card.frame)
	line:SetPoint("RIGHT", card.frame, "RIGHT", -6, 0)
	line.slide, line.index, line.entry, line.shown, line.group = 0, nil, nil, nil, nil
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
	for _, line in pairs(card.lines) do
		line:Hide()
		line:ClearAllPoints()
		linePool[#linePool + 1] = line
	end
	wipe(card.lines)
	wipe(card.lineOrder)
	for g = GROUP_YOU, GROUP_PASSED do
		card.groupCount[g] = 0
	end
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
		skippedHistory[card.historyKey] = true
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
	card.winnerText:SetText("")
	card.winnerText:SetAlpha(0)
	card.winnerIcon:SetAlpha(0)
	card.winnerIcon:Hide()
	card.waiting:SetText("")
	card.waiting:SetAlpha(1)
	card.waiting:Show()
	card.waitingHit:Hide()
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
local CHOICE_LABEL = { [0] = "Need", [1] = "Need (off-spec)", [2] = "Transmog", [3] = "Greed", [4] = "...", [5] = "Pass" }
local function addRollsToTooltip(card)
	if not card.lastRolls then
		return
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Rolls", 1, 1, 1)
	for _, r in ipairs(card.lastRolls) do
		local state = safe(r.state, STATE.NOROLL)
		local label = CHOICE_LABEL[state] or "?"
		if state == STATE.NOROLL and card.finished then
			label = "no roll"
		end
		local roll = safe(r.roll)
		GameTooltip:AddDoubleLine(classColored(safe(r.playerName, "?"), safe(r.playerClass)),
			label .. (roll and ("  " .. roll) or ""), 1, 1, 1, 0.8, 0.8, 0.8)
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
	icon:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if card.demo then
			GameTooltip:SetText(card.itemName or "Demo item")
			GameTooltip:AddLine("Demo mode: a made-up item.", 0.8, 0.8, 0.8)
		elseif card.link then
			GameTooltip:SetHyperlink(card.link)
		end
		if card.linesMode ~= "all" and not card.collapsed then
			addRollsToTooltip(card) -- no player lines on the card: the item's tooltip lists the rolls
		end
		GameTooltip:Show()
	end)
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
	card.timer:SetScript("OnUpdate", function(self)
		local left, total
		if card.rollID and card.rollTime then
			local ok, ms = pcall(GetLootRollTimeLeft, card.rollID)
			left, total = ok and ms and ms / 1000, card.rollTime / 1000
		elseif card.endsAt and card.duration then
			left, total = card.endsAt - GetTime(), card.duration
		end
		if not left or not total or total <= 0 then
			self:Hide()
			return
		end
		self:SetValue(math.max(0, left / total))
		if left < 10 and not card.timerRed then
			card.timerRed = true
			self:SetStatusBarColor(1, 0.25, 0.2)
		end
	end)

	card.winnerIcon = f:CreateTexture(nil, "OVERLAY")
	card.winnerIcon:SetSize(14, 14)
	card.winnerIcon:SetAlpha(0)
	card.winnerText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	card.winnerText:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 26, 2)
	card.winnerText:SetPoint("RIGHT", f, "RIGHT", -6, 0)
	card.winnerText:SetJustifyH("LEFT")
	card.winnerText:SetWordWrap(false)
	card.winnerText:SetAlpha(0)
	card.winnerIcon:SetPoint("RIGHT", card.winnerText, "LEFT", -4, 0)

	-- The summary line ("Player lines: Summary"): counts of each choice; hover it for the full list.
	card.waiting = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	card.waiting:SetJustifyH("LEFT")
	card.waiting:SetWordWrap(false)
	card.waitingHit = CreateFrame("Frame", nil, f)
	card.waitingHit:SetPoint("TOPLEFT", card.waiting, "TOPLEFT")
	card.waitingHit:SetPoint("BOTTOMRIGHT", card.waiting, "BOTTOMRIGHT")
	card.waitingHit:EnableMouse(true)
	card.waitingHit:SetScript("OnEnter", function(self)
		if not card.lastRolls then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(card.itemName or "Rolls", 1, 1, 1)
		addRollsToTooltip(card)
		GameTooltip:Show()
	end)
	card.waitingHit:SetScript("OnLeave", GameTooltip_Hide)
	card.waitingHit:Hide()

	-- Your own choice and roll, where the roll buttons were ("Player lines" Summary or None).
	card.mineRoll = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	card.mineRoll:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -7)
	card.mineIcon = f:CreateTexture(nil, "ARTWORK")
	card.mineIcon:SetSize(18, 18)
	card.mineIcon:SetPoint("RIGHT", card.mineRoll, "LEFT", -3, 0)
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
	card.boss:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 5)
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
		line:SetAlpha(quiet and 1 or 0)
		-- A new player goes in at the end of their group; the lines after it move down one row (usually
		-- none: the first list comes sorted, and later newcomers are rare).
		local group = lineGroup(entry)
		local counts = card.groupCount
		local pos = groupStart(card, group) + counts[group]
		table.insert(card.lineOrder, pos, key)
		counts[group] = counts[group] + 1
		line.group = group
		for i = pos, #card.lineOrder do
			placeLine(card, card.lines[card.lineOrder[i]], i)
		end
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

-- "Need 2 · Greed 1 · Pass 3 · 2 deciding" ("Player lines: Summary"). Only rebuilt when a count changes.
local function setSummary(card, need, greed, transmog, pass, deciding)
	local done = card.finished and 1 or 0
	local key = ((((need * 64 + greed) * 64 + transmog) * 64 + pass) * 64 + deciding) * 2 + done
	if card.summaryKey == key then
		return
	end
	card.summaryKey = key
	local parts = {}
	if need > 0 then parts[#parts + 1] = "Need " .. need end
	if greed > 0 then parts[#parts + 1] = "Greed " .. greed end
	if transmog > 0 then parts[#parts + 1] = "Transmog " .. transmog end
	if pass > 0 then parts[#parts + 1] = "Pass " .. pass end
	if deciding > 0 then parts[#parts + 1] = deciding .. (card.finished and " no roll" or " deciding") end
	placeSummary(card)
	card.waiting:SetText(table.concat(parts, " \194\183 "))
	card.waitingHit:Show()
end

-- One full list of players (shaped like C_LootHistory's rollInfos) drawn as "Player lines" says:
-- a line each, one summary line, or just your own choice on the item row. Every loot-history update
-- lists everyone again; lines whose player is unchanged are skipped.
local function applyRolls(card, rollInfos, quiet)
	card.lastRolls = rollInfos
	local mode = card.linesMode
	if not card.hadRolls and #rollInfos > 0 and (card.reserved or 0) > #rollInfos and heldCard() ~= card then
		card.reserved = #rollInfos -- fewer can roll than are in the group: drop the spare rows now, not mid-roll
	end
	if #rollInfos > (card.reserved or 0) then
		card.reserved = #rollInfos
	end
	quiet = quiet or card.instant or not card.hadRolls
	card.hadRolls = card.hadRolls or #rollInfos > 0
	local wasReported = card.selfReported
	local need, greed, transmog, pass, deciding = 0, 0, 0, 0, 0
	for _, r in ipairs(rollInfos) do
		local state = safe(r.state, STATE.NOROLL)
		local isSelf = r.isSelf and true or false
		if mode == "all" then
			local name = safe(r.playerName, "?")
			local key = safe(r.playerGUID) or name
			local roll, class = safe(r.roll), safe(r.playerClass)
			local line = card.lines[key]
			if not (line and line.shown and line.shownState == state and line.shownRoll == roll
				and line.shownName == name and line.shownClass == class and line.shownSelf == isSelf) then
				setRoll(card, key, { name = name, class = class, state = state, roll = roll, isSelf = isSelf }, quiet)
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
			else
				deciding = deciding + 1
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
	if mode == "summary" then
		setSummary(card, need, greed, transmog, pass, deciding)
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
			-- Stop animations still holding these lines (slide-in, winner sweep) before they go back to the pool.
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
				linePool[#linePool + 1] = line
			end
			wipe(card.lines)
			wipe(card.lineOrder)
			for g = GROUP_YOU, GROUP_PASSED do
				card.groupCount[g] = 0
			end
			card.summaryKey, card.mineState, card.mineRollShown = nil, nil, nil
			card.mineIcon:Hide()
			card.mineRoll:Hide()
			card.waiting:SetText("")
			card.waitingHit:Hide()
			card.linesMode = currentLinesMode()
			local mode = card.linesMode
			card.waiting:SetShown(mode == "summary")
			if card.lastRolls then
				applyRolls(card, card.lastRolls, true)
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

trimHistory = function()
	-- Real rows keep the newest "History length" of them. Demo rows do the same among themselves, as if
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
layout = function()
	if not main then
		return
	end
	-- The card under the cursor with your roll buttons holds still (R31). Where it is now: its distance
	-- from the top of the visible list, and from the window's bottom edge.
	local held = heldCard()
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
	local natural = math.max(y, HEADER_H)
	-- Grow with the drops up to the user's height limit; beyond that the list scrolls.
	local limit = math.max(MIN_HEIGHT, db.maxHeight or MAX_HEIGHT)
	local above = roomAbovePopups() -- R32: attached, never taller than the space above the roll popups
	if above and above < limit then
		limit = math.max(MIN_HEIGHT, above)
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
			if not db.fixedHeight and want <= maxHeight then
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
			if s <= 0 or db.fixedHeight then
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
	-- Fixed height: always as tall as set with the grip, so the window never changes size; longer lists scroll.
	local visible = holdVisible or (db.fixedHeight and room) or math.min(contentHeight, room)
	local scrolls = contentHeight > visible + 0.5
	if heldFromTop and scrollReserved ~= nil then
		scrolls = scrollReserved -- keep the list's width while a drop is held (the scrollbar would shift it)
	end
	scrollReserved = scrolls
	scroll:SetPoint("BOTTOMRIGHT", -(SIDE_PAD + (scrolls and scrollBar and SCROLLBAR_W or 0)), BOTTOM_PAD)
	content:SetSize(WIDTH - 2 * SIDE_PAD - (scrolls and scrollBar and SCROLLBAR_W or 0), contentHeight)
	-- Never shorter than MIN_HEIGHT: the panel template can't draw its border corners on a shorter frame.
	local height = main:GetHeight()
	if not (grip and grip:GetScript("OnUpdate")) then -- leave the height alone while it's being dragged
		height = math.max(MIN_HEIGHT, TITLE_H + visible + BOTTOM_PAD)
		main:SetHeight(height)
	end
	main.empty:SetShown(#ordered == 0)
	main.emptyHint:SetShown(#ordered == 0)
	if scrollBar then
		scrollBar:SetShown(scrolls)
	end
	if grip and gripPlacedFor ~= db.position then
		gripPlacedFor = db.position
		placeGrip()
	end
	if scroll.UpdateScrollChildRect then
		scroll:UpdateScrollChildRect() -- the new range now (list and window sized), so the scroll set below isn't clamped
	end
	local range = math.max(0, contentHeight - (height - TITLE_H - BOTTOM_PAD)) -- how far the list can scroll
	if scrollTo then
		scroll:SetVerticalScroll(math.max(0, math.min(range, scrollTo)))
	elseif shownNewestAtBottom ~= nil and shownNewestAtBottom ~= newestAtBottom() then
		scrollToNewestPending = false -- the list just flipped (dragged free, Position changed): show the newest end
		scroll:SetVerticalScroll(newestAtBottom() and range or 0)
	elseif scrollToNewestPending and not main:IsMouseOver() then
		scrollToNewestPending = false
		scroll:SetVerticalScroll(newestAtBottom() and range or 0)
	elseif scroll:GetVerticalScroll() > range then
		scroll:SetVerticalScroll(range)
	end
	shownNewestAtBottom = newestAtBottom()
	updateRollMarkers()
	if askShown then
		Ask.place() -- the window may have grown or moved
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
		local since = 0
		markerWatch:SetScript("OnUpdate", function(self, elapsed)
			since = since + elapsed
			if since < 0.1 then
				return
			end
			since = 0
			local now = GetTime()
			local overdue = (main.markerUp.heldSince and now - main.markerUp.heldSince >= 3)
				or (main.markerDown.heldSince and now - main.markerDown.heldSince >= 3)
			if overdue or not (main:IsShown() and (cursorOnStrip(true) or cursorOnStrip(false))) then
				self:Hide()
				requestMarkers()
			end
		end)
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
	if db.rollFromWindow and not fallback and main:IsShown() then
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
	return db.rollFromWindow and not fallback and main and main:IsShown()
end

local function applyBlizzardPopups()
	if not GroupLootContainer then
		return
	end
	if suppressBlizzard() then
		GroupLootContainer:Hide()
	elseif GroupLootContainer.rollFrames and #GroupLootContainer.rollFrames > 0 then
		GroupLootContainer:Show()
	end
end

local function enterFallback(err)
	if fallback then
		return
	end
	fallback = true
	if askShown then
		hideAsk()
	end
	say("hit an error, so Blizzard's roll popups are back for this session:", tostring(err))
	if GroupLootContainer then
		GroupLootContainer:Show()
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
		table.move(db.log, excess + 1, n, 1)
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
		table.move(db.pairLog, excess + 1, n, 1)
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
	for pass = 1, 2 do
		for i = #cards, 1, -1 do
			local card = cards[i]
			if not card.historyKey and not card.demo and not (forRoll and card.rollID)
				and (pass == 1 and card.itemKey == key or pass == 2 and itemIDFromLink(card.link) == itemID) then
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
					if not c.historyKey and not c.demo and c.clickedState == state and c.itemKey == key then
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

local function clearDemoCards()
	demoRun = demoRun + 1 -- drops of a demo still playing won't start any more
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
	if skippedHistory[historyKey] then
		return -- already left out of the history ("Minimum quality kept")
	end
	local link = safe(info.itemHyperlink)
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
			skippedHistory[historyKey] = true
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
		clearDemoCards()
		if askShown and not (info.winner or info.allPassed) then
			Ask.putAway() -- a roll in progress: the question waits until the rolls are over
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

	if info.winner and not card.finished then
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
	clearDemoCards()
	if askShown then
		Ask.putAway() -- never asked during a roll: back once the rolls are over
	end
	local okLink, link = pcall(GetLootRollItemLink, rollID)
	link = okLink and link or nil
	local card = findPendingByItem(link, true) -- (a second roll on the same item gets its own card)
	if not card then
		-- A history card for the same item may already exist without a roll ID.
		local key = itemKeyFromLink(link)
		for i = #cards, 1, -1 do -- oldest first, like findPendingByItem
			local c = cards[i]
			if key and c.historyKey and not c.rollID and not c.finished
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
end

local function onCancelRoll(rollID)
	local card = cardsByRollID[rollID]
	if card then
		card.timer:Hide()
		card.buttons:Hide()
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
				C_Timer.After(delay, function()
					if card.gen ~= gen then
						return
					end
					r.roll = math.random(1, 100)
					applyRolls(card, rolls)
				end)
			end
		end
		C_Timer.After(delay + 0.6, function()
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
		end)
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
			if r.isSelf and waitsForYou and not mine.choice and GetTime() < card.endsAt then
				C_Timer.After(0.25, takeTurn)
				return
			end
			local state
			if r.isSelf and mine.choice then -- your click, on any item
				state = CLICK_STATE[mine.choice]
			elseif item.allPass then
				state = STATE.PASS
			elseif r.isSelf and waitsForYou then
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
		C_Timer.After(r.isSelf and waitsForYou and 0.4 or delay, takeTurn)
	end
	return card
end

-- No demo in a group: real loot can arrive at any moment there, and demo drops would sit where real
-- ones appear. (Group loot rolls only exist in a group, so solo the demo can't meet real loot.) Dev
-- builds still allow it, for testing.
local function demoBlocked()
	if IsInGroup() and not DEV then
		say("leave your group to try the demo; real loot can arrive any moment.")
		return true
	end
	return false
end

-- count: how many made-up drops (default 3, up to 20); more than the list repeats it. With more than three
-- they come every 2 seconds, so the list fills up and scrolls.
local function runDemo(count)
	if demoBlocked() then
		return
	end
	count = math.max(1, math.min(count or 3, 20))
	local gap = count > 3 and 2 or 3.5
	clearDemoCards() -- (also ends a demo still playing)
	local run = demoRun
	showWindow()
	for i = 1, count do
		local item = DEMO_ITEMS[(i - 1) % #DEMO_ITEMS + 1]
		C_Timer.After((i - 1) * gap, function()
			if run == demoRun then
				runDemoItem(item)
			end
		end)
	end
	-- No timer to clear them: like real drops they stay as history rows, and they go when the window
	-- closes (or fades out), when real loot arrives, or when another demo starts.
	local last = (count - 1) * gap
	say(string.format("demo: %d made-up drop%s over about %d seconds. They go when the window closes.", count,
		count == 1 and "" or "s", math.floor(last + 20)))
end

----------------------------------------------------------------------------------------------------
-- Auto-hide
----------------------------------------------------------------------------------------------------

-- Whether the window may fade now: shown, not pinned, auto-hide on, not already fading, every drop decided.
fadeEligible = function()
	if not main or not main:IsShown() or pinned or db.autoHide <= 0 or tweens["main:fade"] or askShown then
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
		if db.hoverHoldsFade and main:IsMouseOver() then -- the cursor came back: stop fading, start the idle time again
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

local hideTicker = C_Timer.NewTicker(1, function()
	if not main or not main:IsShown() then
		return
	end
	if db.hoverHoldsFade and main:IsMouseOver() then
		lastActivity = GetTime() -- hovering keeps it open and restarts the idle time
	end
	-- Show the line a moment early (the ticker runs once a second) so it starts full and drains all the way.
	if fadeEligible() and db.autoHide - (GetTime() - lastActivity) <= COUNTDOWN + 1 and not main.countdown:IsShown() then
		main.countdown:Show()
	end
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
	checkbox("rollFromWindow", "Roll from this window",
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
			for _, card in ipairs(cards) do
				refreshButtons(card)
			end
			applyBlizzardPopups()
		end)
	dropdown("playerLines", Settings.VarType.String, "Player lines",
		{ { "auto", "Auto (raids: Summary)" }, { "all", "Everyone" }, { "summary", "Summary" },
			{ "none", "None (item only)" } },
		"How much of each roll in progress the window shows.\n\n"
			.. "Auto (default): Everyone in a party or solo, Summary in a raid, where a line for every raider would "
			.. "make each drop taller than the window.\n\n"
			.. "Everyone: a line per player with their choice and roll. You're on top, then rolls in the order they "
			.. "came in, then players still deciding (...), then passes.\n\n"
			.. "Summary: one line with the counts (Need 2, Greed 1, Pass 3, 2 deciding); hover it for everyone's rolls.\n\n"
			.. "None: just the item, with your own choice and roll where the buttons were; hover the item for "
			.. "everyone's rolls.\n\nA drop keeps the same height while its roll is open, so the roll buttons don't move.",
		function()
			redrawLiveCards()
		end)
	dropdown("position", Settings.VarType.String, "Position",
		{ { "attached", "Attached to roll popups" }, { "free", "Free (drag anywhere)" } },
		"Attached sits above Blizzard's roll popups. Dragging the window switches it to Free.",
		function()
			applyPosition()
			layout() -- grip to the right corner
		end)
	checkbox("fixedHeight", "Fixed window height",
		"On: the window always stays the height you set by dragging its corner, so it never changes size; "
			.. "longer lists scroll. Off: it grows with its drops up to that height, then scrolls.",
		function()
			layout()
		end)
	dropdown("holdSeconds", Settings.VarType.Number, "Show rolls after a winner",
		{ { 3, "3 seconds" }, { 5, "5 seconds" }, { 8, "8 seconds" }, { 10, "10 seconds" } },
		"How long the full roll list stays before the drop collapses to a compact row with the winner.")
	local autoHideInit = dropdown("autoHide", Settings.VarType.Number, "Hide when idle after",
		{ { 0, "Never" }, { 10, "10 seconds" }, { 15, "15 seconds" }, { 30, "30 seconds" }, { 60, "60 seconds" } },
		"Fades the window once every drop is decided and nothing has happened for this long; a thin line drains "
			.. "under the title for the last few seconds. Hovering the window restarts the time (see below). A window you open "
			.. "yourself stays until you close it (the pin by the close button shows this; click it to switch).",
		function()
			refreshPin()
		end)
	local hoverInit = checkbox("hoverHoldsFade", "Hovering stops the fade",
		"On: while the mouse is over the window, the idle time starts again, so it never fades under your cursor."
			.. "\n\nOff: the idle time keeps counting and the window fades even while you hover it.\n\n"
			.. "Either way it turns solid while you hover it.")
	if hoverInit and hoverInit.SetParentInitializer and autoHideInit then
		hoverInit:SetParentInitializer(autoHideInit, function()
			return db.autoHide > 0 -- greyed out with "Never"
		end)
	end
	layoutPanel:AddInitializer(CreateSettingsListSectionHeaderInitializer("History"))
	dropdown("historyMinQuality", Settings.VarType.Number, "Minimum quality kept",
		{ { 0, "All items" }, { 2, "Uncommon and better" }, { 3, "Rare and better" }, { 4, "Epic and better" } },
		"The lowest item quality kept in the history rows once a roll is decided.\n\nRolls for items of any "
			.. "quality always show as normal, so you can still see and roll on them. This setting only decides "
			.. "what stays in the list after the winner has shown: lower items fade out. Every drop is still in "
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
	dropdown("historyCount", Settings.VarType.Number, "History length",
		{ { 5, "5 drops" }, { 10, "10 drops" }, { 20, "20 drops" } },
		"How many finished drops stay listed, as compact rows, under the rolls in progress. Older ones leave "
			.. "the list; Blizzard's loot history (/rollframes blizzard) still has them.", function()
			trimPending, relayoutPending = true, true
			driver:Show() -- apply it now, whether or not the window is open
		end)

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
		for _, card in ipairs(cards) do
			refreshButtons(card)
		end
		applyBlizzardPopups()
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
	row:SetScript("OnUpdate", function(self) -- the sample's timer, only while the question shows
		local left = Ask.sampleTime - (GetTime() - (self.started or GetTime())) % Ask.sampleTime
		self.timer:SetValue(left / Ask.sampleTime)
	end)
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
	Ask.place()
	ask:Show()
	askShown = true
	main.countdown:Hide()
end

-- answered: if the question opened (and pinned) the window itself, it can fade again like any other;
-- a window you opened yourself stays pinned. (Without it: put away for a roll, still unanswered.)
hideAsk = function(answered)
	askShown = false
	if ask then
		ask:Hide()
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
	if askShown or db.askedRollHere or db.rollFromWindow or fallback or InCombatLockdown() or Ask.anyRealDrop(true)
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
events:SetScript("OnEvent", function(self, event, ...)
	if event == "PLAYER_LOGIN" then
		RollFramesDB = RollFramesDB or {}
		db = RollFramesDB
		for key, value in pairs(DEFAULTS) do
			if db[key] == nil then
				db[key] = value
			end
		end
		db.newestAt = nil -- (a dev-only override from testing v1.1; no longer used)
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
					C_Timer.After(0, function()
						if db.position == "attached" then -- unless the window was dragged meanwhile
							applyPosition()
						end
					end)
				end
			end)
			-- More popups make the container taller; remember where it ends up, so the window stays there
			-- after the popups go (its position can't be read once Blizzard has hidden it).
			if GroupLootContainer_Update then
				hooksecurefunc("GroupLootContainer_Update", function()
					popupsOnScreen()
					if db.position == "attached" and main:IsShown() then
						relayoutPending = true -- more popups: less room above them (R32)
						driver:Show()
					end
				end)
			end
			GroupLootContainer:HookScript("OnHide", function()
				if db.position == "attached" then
					applyPosition()
				end
			end)
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
		C_Timer.After(4, function()
			if not (db.askedRollHere or db.rollFromWindow) and not maybeAsk("login") and InCombatLockdown() then
				askPutAway = true
			end
		end)
		if ConfirmLootRoll then -- bind-on-pickup confirmation (only if a confirm can be told from a cancel)
			pcall(self.RegisterEvent, self, "CONFIRM_LOOT_ROLL")
		end
		pcall(self.RegisterEvent, self, "CANCEL_ALL_LOOT_ROLLS")
		-- Rolls made anywhere (Blizzard's popups, other addons) count against the twins pool (R38), and a
		-- confirmed bind-on-pickup roll stays taken.
		if RollOnLoot then
			hooksecurefunc("RollOnLoot", function(rollID)
				if rollID ~= nil and not isSecret(rollID) then
					rolledIDs[rollID] = true
				end
				local group = twinOfRoll[rollID]
				if group and not group.used[rollID] then
					group.used[rollID] = true
					refreshTwins(group)
				end
			end)
		end
		if ConfirmLootRoll then
			hooksecurefunc("ConfirmLootRoll", function(rollID)
				awaitingConfirm[rollID] = nil
				if rollID ~= nil and not isSecret(rollID) then
					confirmedRolls[rollID] = true
				end
			end)
		end
		return
	end
	local ok, err = pcall(function(...)
		if event == "LOOT_HISTORY_UPDATE_DROP" then
			onDropUpdate(...)
		elseif event == "START_LOOT_ROLL" then
			onStartRoll(...)
		elseif event == "CANCEL_LOOT_ROLL" then
			onCancelRoll(...)
		elseif event == "CONFIRM_LOOT_ROLL" then
			onConfirmLootRoll(...)
		elseif event == "PLAYER_REGEN_DISABLED" then
			Ask.putAway(true) -- never in combat
		elseif event == "PLAYER_REGEN_ENABLED" then
			-- (Feign Death, Vanish or dying also end combat mid-fight: a put-away question comes back only
			-- once you've been out of combat, and alive, for 5 s; otherwise at the next open or login.)
			Ask.combatEnded = GetTime()
			if askPutAway then
				-- One try, 5 s after the fight; if it can't show then, next open or login. Only the newest
				-- end of combat counts (chain pulls), and a try that would land in the next fight waits for
				-- that fight's own end instead.
				local endedAt = Ask.combatEnded
				C_Timer.After(5.5, function()
					if Ask.combatEnded ~= endedAt or InCombatLockdown() then
						return
					end
					if askPutAway and not (db.askedRollHere or db.rollFromWindow) then
						maybeAsk("again")
					end
					askPutAway = false
				end)
			end
		elseif event == "CANCEL_ALL_LOOT_ROLLS" then
			wipe(twinOfRoll)
			wipe(rolledIDs)
			wipe(confirmedRolls)
			wipe(awaitingConfirm)
		end
	end, ...)
	if not ok then
		log("error", { event = event, error = tostring(err) })
		enterFallback(err)
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
	say("cards:", #cards, "| log entries:", db.log and #db.log or 0, "| fallback:", tostring(fallback))
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
	profiling, driverMs = true, 0
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
				profiling = false
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
		local codeMs = (updateMs + driverMs) / seconds
		say(string.format("%s %d/%d drops%s | %.0fs | avg %.0f fps, worst frame %.0f ms | RollFrames code %.2f ms/s"
			.. " (updates %.2f, animation %.2f)", stopped and "stress stopped early:" or (final and "stress done:"
			or "stress:"), done, drops,
			hidden and " (window closed)" or "", seconds, frames / math.max(total, 0.001), worst * 1000, codeMs,
			updateMs / seconds, driverMs / seconds))
		say(string.format("  memory %+.0f KB (now %.0f KB) | frames ever made: %d cards, %d lines (+%d, +%d this run)"
			.. " | in the list: %d cards | ready for reuse: %d cards, %d lines",
			memoryKB() - memStart, memoryKB(), framesMade.cards, framesMade.lines, framesMade.cards - cardsMade,
			framesMade.lines - linesMade, #cards, #cardPool, #linePool))
		if final then
			profiling = false
			stressMonitor:SetScript("OnUpdate", nil)
			say("|cff33ff99Stress test finished.|r Type /reload to save the results for review.")
			log("stress", { drops = drops, done = done, stopped = stopped or nil, players = players,
				hidden = hidden or nil, seconds = math.floor(seconds),
				fps = math.floor(frames / math.max(total, 0.001)), worstMs = math.floor(worst * 1000),
				codeMsPerSec = string.format("%.2f", codeMs), updateMsPerSec = string.format("%.2f", updateMs / seconds),
				animMsPerSec = string.format("%.2f", driverMs / seconds), memDeltaKB = math.floor(memoryKB() - memStart),
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
	if command == "demo" then
		runDemo(3)
	elseif command:match("^demo%s+%d+$") then
		runDemo(tonumber(command:match("%d+")))
	elseif command == "options" and category then
		Settings.OpenToCategory(category:GetID())
	elseif command == "reset" then
		db.position = "attached"
		db.point = nil
		db.maxHeight = MAX_HEIGHT
		applyPosition()
		layout()
		say("window position and size reset (attached to the loot roll popups).")
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
	elseif command == "demo twins" then
		runDemoTwins()
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
		say("commands: /rollframes (show or hide) | demo [count] | options | reset | blizzard | diag")
	end
end
