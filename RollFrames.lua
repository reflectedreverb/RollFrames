-- RollFrames: live group loot rolls in one Blizzard-style window.
-- Each drop gets a card. While rolls are open, every player's choice appears as it arrives
-- (your own line first, then in the order they chose), with roll numbers as they're revealed and a "Waiting on" line. When a
-- winner is picked, their line is highlighted with a sweep, the rolls stay a few seconds, then the
-- card collapses to a compact row: item (hover for tooltip) and winner.
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
-- RollOnLoot roll types.
local ROLL_BUTTONS = {
	{ type = 1, atlas = "lootroll-toast-icon-need", label = "Need", can = "canNeed" },
	{ type = 2, atlas = "lootroll-toast-icon-greed", label = "Greed", can = "canGreed" },
	{ type = 4, atlas = "lootroll-toast-icon-transmog", label = "Transmog", can = "canTransmog" },
	{ type = 0, atlas = "lootroll-toast-icon-pass", label = "Pass" },
}

local DEFAULTS = {
	autoOpen = true,
	rollFromWindow = false,
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
local scrollToTopPending = false -- a new drop arrived: show the top of the list when the mouse isn't over it
local cards = {} -- newest first
local cardsByHistory = {} -- "encounterID:lootListKey" -> card
local trimPending = true -- history needs trimming at the next layout (a card collapsed, or the setting changed)
local demoCardCount = 0 -- demo cards currently in the list
local demoClears = 0 -- counts clearDemoCards runs, so the dev stress test can tell it was interrupted
local cardsByRollID = {}
local skippedHistory = {} -- "encounterID:lootListKey" of drops left out of the history; later updates are ignored
local dismissCard -- forward declaration (defined with the frame pool)
local nextCardID, nextOrder = 0, 0
local fallback = false -- set if RollFrames errors while handling rolls; Blizzard's popups come back
local lastActivity = 0
local layout -- forward declaration
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
		main:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
	end
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

	-- Blizzard's slim scrollbar when this client has it; otherwise the mouse wheel alone scrolls.
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
			local maxAllowed = math.max(MIN_HEIGHT, UIParent:GetHeight() - 40)
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
		if relayoutPending then
			relayoutPending = false
			layout()
		end
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

local function cardRollTypes(card)
	if not card.rollID or card.demo then
		return { canNeed = true, canGreed = true, canTransmog = false }
	end
	local ok, _, _, _, _, _, canNeed, canGreed, _, _, _, _, _, canTransmog = pcall(GetLootRollItemInfo, card.rollID)
	if not ok then
		return { canNeed = true, canGreed = true }
	end
	return { canNeed = canNeed, canGreed = canGreed, canTransmog = canTransmog }
end

local function expandedHeight(card)
	local lines = #card.lineOrder
	local waiting = card.waitingText and 1 or 0
	return HEADER_H + (lines + waiting) * LINE_H + 6
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

local function placeLine(card, line, i)
	line.index = i
	line:ClearAllPoints()
	line:SetPoint("TOPLEFT", card.frame, "TOPLEFT", ICON + 12 + (line.slide or 0), -(HEADER_H + (i - 1) * LINE_H))
	line:SetPoint("RIGHT", card.frame, "RIGHT", -6, 0)
end

-- The "Waiting on" line sits under the roll lines; it only moves when a roll line is added.
local function placeWaiting(card)
	local count = #card.lineOrder
	if card.waitingPlacedFor == count then
		return
	end
	card.waitingPlacedFor = count
	card.waiting:ClearAllPoints()
	card.waiting:SetPoint("TOPLEFT", card.frame, "TOPLEFT", ICON + 14, -(HEADER_H + count * LINE_H + 2))
	card.waiting:SetPoint("RIGHT", card.frame, "RIGHT", -6, 0)
end

local function createLine(card)
	local line = CreateFrame("Frame", nil, card.frame)
	line:SetHeight(LINE_H)
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
	if line.shown and line.shownState == entry.state and line.shownName == entry.name
		and line.shownClass == entry.class and line.shownRoll == entry.roll and line.shownSelf == isSelf then
		return
	end
	line.shown, line.shownState, line.shownName, line.shownClass, line.shownRoll, line.shownSelf =
		true, entry.state, entry.name, entry.class, entry.roll, isSelf
	if entry.state == STATE.NOROLL then
		line.icon:Hide() -- your own line before you choose: no icon yet
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
		line.roll:SetText("|cff888888...|r") -- like everyone's until numbers come in; no icon = not chosen yet
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

-- After the hold, fade the roll lines and shrink the card to a compact row with the winner.
-- True when the user keeps only better items in the history and this one's quality is known to be lower.
local function belowHistoryQuality(card, quality)
	quality = quality or card.quality
	local min = db.historyMinQuality or 0
	return min > 0 and quality ~= nil and quality < min
end

local function collapse(card)
	if card.collapsed or card.dismissing then
		return
	end
	if belowHistoryQuality(card) then
		dismissCard(card) -- the winner has shown; this item isn't kept in the history
		return
	end
	card.collapsed = true
	trimPending = true
	updateHeaderWinner(card)
	card.timer:Hide()
	card.buttons:Hide()
	tween(card.id .. ":collapse", 0.35, function(p)
		for _, line in pairs(card.lines) do
			line:SetAlpha(1 - p)
		end
		card.waiting:SetAlpha(1 - p)
		card.winnerText:SetAlpha(p)
		card.winnerIcon:SetAlpha(p)
	end, function()
		for _, line in pairs(card.lines) do
			line:Hide()
		end
		card.waiting:Hide()
		card.waitingHit:Hide()
	end)
	resize(card)
end

local function finish(card)
	if card.finished then
		return
	end
	card.finished = true
	lastActivity = GetTime()
	if card.winnerKey and card.lines[card.winnerKey] then
		playWinnerSweep(card, card.lines[card.winnerKey])
	end
	card.timer:Hide()
	card.buttons:Hide()
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

local function createButtons(card)
	local bar = CreateFrame("Frame", nil, card.frame)
	bar:SetSize(4 * 22, 20)
	bar:SetPoint("TOPRIGHT", card.frame, "TOPRIGHT", -4, -4)
	bar.list = {}
	for i, spec in ipairs(ROLL_BUTTONS) do
		local button = CreateFrame("Button", nil, bar)
		button:SetSize(20, 20)
		button:SetPoint("RIGHT", bar, "RIGHT", -(i - 1) * 22, 0)
		button:SetNormalAtlas(spec.atlas .. "-up")
		button:SetHighlightAtlas(spec.atlas .. "-highlight")
		button:SetPushedAtlas(spec.atlas .. "-down")
		button.spec = spec
		button:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText(spec.label)
			GameTooltip:Show()
		end)
		button:SetScript("OnLeave", GameTooltip_Hide)
		button:SetScript("OnClick", function()
			if card.demo then
				card.demoChoice = spec.type
			elseif card.rollID then
				RollOnLoot(card.rollID, spec.type)
			end
			bar:Hide()
		end)
		bar.list[#bar.list + 1] = button
	end
	bar:Hide()
	return bar
end

-- Title row: item name, then the item level at the right, left of the roll buttons when they show.
local function placeHeader(card)
	local withButtons = card.buttons and card.buttons:IsShown() and true or false
	if card.headerWithButtons == withButtons then
		return -- already placed for this layout
	end
	card.headerWithButtons = withButtons
	card.ilvl:ClearAllPoints()
	if withButtons then
		card.ilvl:SetPoint("TOPRIGHT", card.buttons, "TOPLEFT", -4, -1)
	else
		card.ilvl:SetPoint("TOPRIGHT", card.frame, "TOPRIGHT", -6, -5)
	end
	card.name:ClearAllPoints()
	card.name:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 6, -2)
	card.name:SetPoint("RIGHT", card.ilvl, "LEFT", -4, 0)
end

local function refreshButtons(card)
	if not (db.rollFromWindow and not fallback and (card.rollID or card.demoWaitsForYou) and not card.finished
		and not card.youRolled) then
		card.buttons:Hide()
		placeHeader(card)
		return
	end
	local can = cardRollTypes(card)
	local x = 0
	for i = #card.buttons.list, 1, -1 do
		local button = card.buttons.list[i]
		local spec = button.spec
		local allowed = not spec.can or can[spec.can]
		button:SetShown(allowed)
	end
	-- Re-pack visible buttons from the right.
	for _, button in ipairs(card.buttons.list) do
		if button:IsShown() then
			button:ClearAllPoints()
			button:SetPoint("RIGHT", card.buttons, "RIGHT", -x, 0)
			x = x + 22
		end
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
	"winner", "winnerKey", "youRolled", "demoChoice", "demoWaitsForYou", "waitingText", "waitingNames",
	"itemName", "itemShown", "shownLink", "shownNameArg", "shownIconArg", "shownQualityArg", "ilvlSettled",
	"height", "headerWithButtons", "timerRed", "demo", "instant", "created", "waitingPlacedFor", "coloredNames",
	"quality", "dismissing",
}

local function acquireLine(card)
	local line = table.remove(linePool)
	if not line then
		framesMade.lines = framesMade.lines + 1
		return createLine(card)
	end
	line:SetParent(card.frame)
	line.slide, line.index, line.entry, line.shown = 0, nil, nil, nil
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
	card.timer:Hide()
	card.buttons:Hide()
	card.frame:Hide()
	card.frame:ClearAllPoints()
	cardPool[#cardPool + 1] = card
end

-- Fades a card out and removes it from the list (an item below the "Minimum quality kept" setting).
dismissCard = function(card)
	if card.dismissing then
		return
	end
	card.dismissing = true
	if card.historyKey then
		skippedHistory[card.historyKey] = true
	end
	if logging() and not card.demo then
		log("skip", { historyKey = card.historyKey, quality = card.quality, why = "below minimum quality kept" })
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
	card.frame:Show()
end

local function createCard(link, opts)
	nextCardID = nextCardID + 1
	local card = table.remove(cardPool)
	local reused = card ~= nil
	if reused then
		resetCard(card)
	else
		card = { gen = 0, lines = {}, lineOrder = {} }
		framesMade.cards = framesMade.cards + 1
	end
	card.id = "card" .. nextCardID
	card.link, card.created = link, GetTime()
	card.demo, card.instant = opts and opts.demo, opts and opts.instant
	scrollToTopPending = true -- new drops go on top; show them
	if reused then
		card.frame:SetPoint("LEFT", content, "LEFT")
		card.frame:SetPoint("RIGHT", content, "RIGHT")
		placeHeader(card)
		table.insert(cards, 1, card)
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
	card.winnerText:SetAlpha(0)
	card.winnerIcon:SetPoint("RIGHT", card.winnerText, "LEFT", -4, 0)

	card.waiting = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	card.waiting:SetJustifyH("LEFT")
	card.waiting:SetWordWrap(false)
	-- Hover the "Waiting on" line to see every name, even when it only shows a count.
	card.waitingHit = CreateFrame("Frame", nil, f)
	card.waitingHit:SetPoint("TOPLEFT", card.waiting, "TOPLEFT")
	card.waitingHit:SetPoint("BOTTOMRIGHT", card.waiting, "BOTTOMRIGHT")
	card.waitingHit:EnableMouse(true)
	card.waitingHit:SetScript("OnEnter", function(self)
		if not card.waitingNames or #card.waitingNames == 0 then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Waiting on", 1, 1, 1)
		for _, name in ipairs(card.waitingNames) do
			GameTooltip:AddLine(name)
		end
		GameTooltip:Show()
	end)
	card.waitingHit:SetScript("OnLeave", GameTooltip_Hide)
	card.waitingHit:Hide()

	card.buttons = createButtons(card)
	placeHeader(card)

	table.insert(cards, 1, card)
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

-- Adds or updates one player's roll; new players slide in under the earlier ones.
local function setRoll(card, key, entry)
	local line = card.lines[key]
	local isNew = not line
	if isNew then
		nextOrder = nextOrder + 1
		line = acquireLine(card)
		card.lines[key] = line
		line.slide = card.instant and 0 or -18 -- instant cards skip the slide-in
		line:SetAlpha(card.instant and 1 or 0)
		if entry.isSelf and #card.lineOrder > 0 then
			-- Your own roll goes on top. The lines already there move down one row: once per card, only
			-- when you roll (a line still sliding in carries on at its new row).
			table.insert(card.lineOrder, 1, key)
			for i = 2, #card.lineOrder do
				placeLine(card, card.lines[card.lineOrder[i]], i)
			end
		else
			card.lineOrder[#card.lineOrder + 1] = key
		end
	end
	line.entry = entry
	updateLineText(card, line, entry)
	if isNew then
		-- Everyone else is added at the bottom: existing lines don't move, so only the new one is placed.
		placeLine(card, line, entry.isSelf and 1 or #card.lineOrder)
		placeWaiting(card)
	end
	lastActivity = GetTime()
	if isNew and not card.instant then
		tween(card.id .. ":" .. key .. ":in", 0.3, function(p)
			line.slide = -18 * (1 - p)
			line:SetAlpha(p)
			placeLine(card, line, line.index)
		end)
	elseif isNew then
		line.slide = 0
		line:SetAlpha(1)
	end
	if isNew then
		resize(card, card.instant)
	end
end

-- "Waiting on: A, B" when the names fit; otherwise "Waiting on 3 players". Hover lists everyone.
local function setWaiting(card, names)
	placeWaiting(card)
	if #names == 0 or card.finished then
		if card.waitingText or card.waitingNames then
			card.waitingText = nil
			card.waitingNames = nil
			card.waiting:SetText("")
			card.waitingHit:Hide()
		end
		resize(card, card.instant)
		return
	end
	card.waitingNames = names -- the hover list always gets the newest names
	-- Ten or more names never fit on the line (even 2-letter names come to more than its width), so skip
	-- building and measuring the full list and show the count straight away.
	if #names >= 10 then
		local text = string.format("Waiting on %d players", #names)
		if text ~= card.waitingText then
			card.waitingText = text
			card.waiting:SetText(text)
			card.waitingHit:Show()
			resize(card, card.instant)
		end
		return
	end
	local text = "Waiting on: " .. table.concat(names, ", ")
	if text == card.waitingText then
		return -- same people still deciding: nothing on screen changes
	end
	card.waitingText = text
	card.waiting:SetText(text)
	card.waitingHit:Show()
	do
		local truncated
		if card.waiting.IsTruncated then
			truncated = card.waiting:IsTruncated()
		else
			truncated = #names > 2
		end
		if truncated then
			card.waiting:SetText(string.format("Waiting on %d player%s", #names, #names == 1 and "" or "s"))
		end
	end
	resize(card, card.instant)
end

local function setWinner(card, key, winner)
	card.winnerKey = key
	card.winner = winner
	local line = key and card.lines[key]
	if line then
		line.entry.roll = winner.roll or line.entry.roll
		updateLineText(card, line, line.entry)
	end
	setWaiting(card, {})
	finish(card)
end

local function setAllPassed(card)
	card.allPassed = true
	setWaiting(card, {})
	finish(card)
end

trimHistory = function()
	local kept, collapsedCount = {}, 0
	for _, card in ipairs(cards) do
		if card.collapsed then
			collapsedCount = collapsedCount + 1
		end
		if card.collapsed and collapsedCount > db.historyCount then
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
	cards = kept
end

local ordered = {} -- layout's scratch list, reused
local gripPlacedFor -- db.position the grip was last placed for (it's anchored to the window, so size doesn't matter)
layout = function()
	if not main then
		return
	end
	if trimPending then
		trimPending = false
		trimHistory()
	end
	wipe(ordered)
	for _, card in ipairs(cards) do
		if not card.collapsed then
			ordered[#ordered + 1] = card
		end
	end
	for _, card in ipairs(cards) do
		if card.collapsed then
			ordered[#ordered + 1] = card
		end
	end
	local y = 0
	for _, card in ipairs(ordered) do
		card.frame:ClearAllPoints()
		card.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
		card.frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -y)
		y = y + (card.height or HEADER_H) + CARD_GAP
	end
	-- Grow with the drops up to the user's height limit; beyond that the list scrolls.
	local contentHeight = math.max(y, HEADER_H)
	local limit = math.max(MIN_HEIGHT, db.maxHeight or MAX_HEIGHT)
	local room = limit - TITLE_H - BOTTOM_PAD
	-- Fixed height: always as tall as set with the grip, so the window never changes size; longer lists scroll.
	local visible = db.fixedHeight and room or math.min(contentHeight, room)
	local scrolls = contentHeight > visible + 0.5
	scroll:SetPoint("BOTTOMRIGHT", -(SIDE_PAD + (scrolls and scrollBar and SCROLLBAR_W or 0)), BOTTOM_PAD)
	content:SetSize(WIDTH - 2 * SIDE_PAD - (scrolls and scrollBar and SCROLLBAR_W or 0), contentHeight)
	-- Never shorter than MIN_HEIGHT: the panel template can't draw its border corners on a shorter frame.
	if not (grip and grip:GetScript("OnUpdate")) then -- leave the height alone while it's being dragged
		main:SetHeight(math.max(MIN_HEIGHT, TITLE_H + visible + BOTTOM_PAD))
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
	if scrollToTopPending and not main:IsMouseOver() then
		scrollToTopPending = false
		scroll:SetVerticalScroll(0)
	elseif scroll:GetVerticalScroll() > scroll:GetVerticalScrollRange() then
		scroll:SetVerticalScroll(scroll:GetVerticalScrollRange())
	end
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

-- Whether log() will record anything. Check this before building log-only data, so players pay nothing.
logging = function()
	return DEV or (db and db.debugLog) or false
end

----------------------------------------------------------------------------------------------------
-- Real data
----------------------------------------------------------------------------------------------------

local function findPendingByItem(link)
	local itemID = itemIDFromLink(link)
	for _, card in ipairs(cards) do
		if not card.historyKey and not card.demo and itemIDFromLink(card.link) == itemID then
			return card
		end
	end
end

-- Removes the demo's made-up drops, so they never sit in the history next to real loot.
local function clearDemoCards()
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
	local card = cardsByHistory[historyKey] or (not (opts and opts.demo) and findPendingByItem(link)) or nil
	local isNewCard = not card
	-- A drop that's already decided the first time it's seen (e.g. after a reload) and is below the
	-- "Minimum quality kept" setting never needs a card at all.
	if isNewCard and (info.winner or info.allPassed) and (db.historyMinQuality or 0) > 0 then
		local itemID = itemIDFromLink(link)
		local quality = itemID and C_Item and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(itemID)
		if quality ~= nil and not isSecret(quality) and belowHistoryQuality(nil, quality) then
			skippedHistory[historyKey] = true
			if logging() and not (opts and opts.quiet) then
				log("skip", { historyKey = historyKey, quality = quality, why = "decided when first seen" })
			end
			return
		end
	end
	-- Open the window before making the card, so the new drop animates in (while hidden, it wouldn't).
	if isNewCard and not (info.winner or info.allPassed) and db.autoOpen and not (opts and opts.noOpen) then
		showWindow()
	end
	if isNewCard then
		-- Drops already decided when first seen (for example after a reload) appear collapsed.
		card = createCard(link, { instant = info.winner ~= nil or info.allPassed, demo = opts and opts.demo })
		if card.demo then
			demoCardCount = demoCardCount + 1
		end
	end
	card.historyKey = historyKey
	cardsByHistory[historyKey] = card
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

	local waiting, logRolls = {}, {}
	local logOn = logging() and not (opts and opts.quiet) -- only build the log's roll summary when it's recorded
	-- Every update lists everyone again. Players whose roll is already shown as-is are skipped, and each
	-- name is class-coloured once per drop, so a 40-person roll costs little per update.
	local colored = card.coloredNames
	if not colored then
		colored = {}
		card.coloredNames = colored
	end
	for _, r in ipairs(info.rollInfos or {}) do
		local name = safe(r.playerName, "?")
		local key = safe(r.playerGUID) or name
		local state = safe(r.state, STATE.NOROLL)
		local class = safe(r.playerClass)
		if state == STATE.NOROLL and r.isSelf then
			-- Your own line sits on top from the start ("..."), so choosing fills it in place.
			local line = card.lines[key]
			if not (line and line.shown and line.shownState == state) then
				setRoll(card, key, { name = name, class = class, state = state, isSelf = true })
			end
		elseif state == STATE.NOROLL then
			local shown = colored[key]
			if not shown then
				shown = classColored(name, class)
				if class then -- keep it only once the class is known, so a late class still gets its colour
					colored[key] = shown
				end
			end
			waiting[#waiting + 1] = shown
		else
			local roll, isSelf = safe(r.roll), r.isSelf and true or false
			local line = card.lines[key]
			if not (line and line.shown and line.shownState == state and line.shownRoll == roll
				and line.shownName == name and line.shownClass == class and line.shownSelf == isSelf) then
				setRoll(card, key, { name = name, class = class, state = state, roll = roll, isSelf = isSelf })
			end
		end
		if r.isSelf and state ~= STATE.NOROLL then
			card.youRolled = true
		end
		if logOn then
			logRolls[#logRolls + 1] = string.format("%s/%s/%s%s", tostring(safe(r.playerClass)), tostring(state),
				tostring(safe(r.roll)), r.isSelf and "/self" or "")
		end
	end
	setWaiting(card, waiting)
	refreshButtons(card)

	if logOn then log("drop", {
		encounterID = encounterID, lootListKey = lootListKey, hasLink = link ~= nil,
		winner = info.winner ~= nil, allPassed = info.allPassed, isTied = info.isTied,
		startTime = info.startTime, duration = info.duration, historyTime = C_LootHistory.GetLootHistoryTime(),
		rolls = table.concat(logRolls, " "), newCard = isNewCard,
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
	clearDemoCards()
	applyDropInfo(encounterID, lootListKey, info)
end

local function onStartRoll(rollID, rollTime)
	clearDemoCards()
	local okLink, link = pcall(GetLootRollItemLink, rollID)
	link = okLink and link or nil
	local card = findPendingByItem(link)
	if not card then
		-- A history card for the same item may already exist without a roll ID.
		for _, c in ipairs(cards) do
			if c.historyKey and not c.rollID and not c.finished and itemIDFromLink(c.link) == itemIDFromLink(link) then
				card = c
				break
			end
		end
	end
	local isNew = not card
	if db.autoOpen then -- off: it stays in the background; Blizzard's popups show while it's closed
		showWindow() -- before making the card, so it animates in
	end
	card = card or createCard(link)
	card.rollID = rollID
	card.rollTime = rollTime
	cardsByRollID[rollID] = card
	local okInfo, texture, name, _, quality = pcall(GetLootRollItemInfo, rollID)
	setItem(card, link, okInfo and name or nil, okInfo and texture or nil, okInfo and quality or nil)
	card.timer:SetStatusBarColor(1, 0.75, 0.1)
	card.timerRed = false
	card.timer:Show()
	refreshButtons(card)
	if logging() then
		log("start", { rollID = rollID, rollTime = rollTime, hasLink = link ~= nil, matchedCard = not isNew })
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
local DEMO_ITEMS = {
	{ name = "Demo Blade of Testing", icon = "Interface\\Icons\\INV_Sword_04", quality = 3 },
	{ name = "Demo Chain Hauberk", icon = "Interface\\Icons\\INV_Chest_Chain_05", quality = 4 },
	{ name = "Demo Grey Gloves", icon = "Interface\\Icons\\INV_Gauntlets_04", quality = 2, allPass = true },
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

local function runDemoItem(item)
	local card = createCard(nil, { demo = true })
	local gen = card.gen -- the demo's timers stop if the card is cleared and reused meanwhile
	demoCardCount = demoCardCount + 1
	setItem(card, nil, item.name, item.icon, item.quality)
	card.duration = 12
	card.endsAt = GetTime() + card.duration
	card.timer:Show()
	card.demoWaitsForYou = true
	refreshButtons(card)

	local players = shuffled(DEMO_PLAYERS)
	local chosen = {}
	local function waitingNames()
		local names = {}
		for _, p in ipairs(players) do
			if not chosen[p.name] and not p.isSelf then -- "You" has its own line on top
				names[#names + 1] = classColored(p.name, p.class)
			end
		end
		return names
	end
	for _, p in ipairs(players) do
		if p.isSelf then -- your line is there from the start, "...", like a real roll
			setRoll(card, p.name, { name = p.name, class = p.class, state = STATE.NOROLL, isSelf = true })
		end
	end
	setWaiting(card, waitingNames())

	local function revealAndPickWinner()
		local best, bestState
		local order = {}
		for _, key in ipairs(card.lineOrder) do
			order[#order + 1] = key
		end
		local delay = 0
		for _, key in ipairs(order) do
			local line = card.lines[key]
			if line.entry.state ~= STATE.PASS and line.entry.state ~= STATE.NOROLL then
				delay = delay + 0.35
				C_Timer.After(delay, function()
					if card.gen ~= gen then
						return
					end
					line.entry.roll = math.random(1, 100)
					updateLineText(card, line, line.entry)
				end)
			end
		end
		C_Timer.After(delay + 0.6, function()
			if card.gen ~= gen then
				return
			end
			for _, key in ipairs(order) do
				local e = card.lines[key].entry
				if e.state ~= STATE.PASS and e.state ~= STATE.NOROLL then
					local rank = (e.state == STATE.GREED) and 1 or 2
					if not best or rank > bestState or (rank == bestState and e.roll > card.lines[best].entry.roll) then
						best, bestState = key, rank
					end
				end
			end
			if best then
				local e = card.lines[best].entry
				setWinner(card, best, { name = e.name, class = e.class, roll = e.roll, state = e.state })
			else
				setAllPassed(card)
			end
		end)
	end

	local delay = 0.4
	local remaining = #players
	-- With "Roll from this window" on, "You" waits for your click like a real roll (checked a few times a
	-- second), and passes if the timer runs out, as the game does.
	local waitsForYou = db.rollFromWindow
	for _, p in ipairs(players) do
		delay = delay + 0.5 + math.random() * 0.8
		local function takeTurn()
			if card.gen ~= gen then
				return
			end
			if p.isSelf and waitsForYou and not card.demoChoice and GetTime() < card.endsAt then
				C_Timer.After(0.25, takeTurn)
				return
			end
			local state
			if p.isSelf and card.demoChoice then -- your click, on any item
				state = ({ [1] = STATE.NEED, [2] = STATE.GREED, [4] = STATE.TRANSMOG, [0] = STATE.PASS })[card.demoChoice]
			elseif item.allPass then
				state = STATE.PASS
			elseif p.isSelf and waitsForYou then
				state = STATE.PASS -- the timer ran out
			else
				local r = math.random()
				state = r < 0.4 and STATE.NEED or (r < 0.8 and STATE.GREED or STATE.PASS)
			end
			if p.isSelf then
				card.youRolled = true
				card.buttons:Hide()
			end
			chosen[p.name] = true
			setRoll(card, p.name, { name = p.name, class = p.class, state = state, isSelf = p.isSelf })
			setWaiting(card, waitingNames())
			remaining = remaining - 1
			if remaining == 0 then
				card.timer:Hide()
				revealAndPickWinner()
			end
		end
		C_Timer.After(p.isSelf and waitsForYou and 0.4 or delay, takeTurn)
	end
end

local demoRun = 0

local function runDemo()
	demoRun = demoRun + 1
	local run = demoRun
	clearDemoCards()
	showWindow()
	for i, item in ipairs(DEMO_ITEMS) do
		C_Timer.After((i - 1) * 3.5, function()
			if run == demoRun then
				runDemoItem(item)
			end
		end)
	end
	-- The demo's drops are decided by about 20 s; clear them once the last one has shown its result.
	C_Timer.After(20 + db.holdSeconds + 10, function()
		if run == demoRun then
			clearDemoCards()
		end
	end)
	say("demo: three made-up drops will play out over about 20 seconds, then clear.")
end

----------------------------------------------------------------------------------------------------
-- Auto-hide
----------------------------------------------------------------------------------------------------

-- Whether the window may fade now: shown, not pinned, auto-hide on, not already fading, every drop decided.
fadeEligible = function()
	if not main or not main:IsShown() or pinned or db.autoHide <= 0 or tweens["main:fade"] then
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
		if main:IsMouseOver() then -- the cursor came back: stop fading and start the idle time again
			tweens["main:fade"] = nil
			main:SetAlpha(1)
			lastActivity = GetTime()
			return
		end
		main:SetAlpha(1 - p)
	end, function()
		main:Hide()
		main:SetAlpha(1)
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
	if main:IsMouseOver() then
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
		Settings.CreateCheckbox(category, s, tooltip)
		settingObjects[key] = s
	end
	local function dropdown(key, varType, name, choices, tooltip, onChange)
		local s = Settings.RegisterAddOnSetting(category, "ROLLFRAMES_" .. key:upper(), key, db, varType, name,
			DEFAULTS[key])
		if onChange then
			s:SetValueChangedCallback(onChange)
		end
		Settings.CreateDropdown(category, s, function()
			local c = Settings.CreateControlTextContainer()
			for _, choice in ipairs(choices) do
				c:Add(choice[1], choice[2])
			end
			return c:GetData()
		end, tooltip)
		settingObjects[key] = s
	end

	checkbox("autoOpen", "Open when a roll starts",
		"Shows the window whenever a group loot roll starts. Off: it stays out of the way and keeps track "
			.. "quietly; open it yourself with /rollframes or the AddOns button, and everything is there. While "
			.. "it's closed, Blizzard's own roll popups show as usual.")
	checkbox("rollFromWindow", "Roll from this window",
		"Adds Need, Greed and Pass buttons to each drop and hides Blizzard's roll popups while the window "
			.. "is open. If RollFrames hits an error, or you close the window, Blizzard's popups come back.",
		function()
			for _, card in ipairs(cards) do
				refreshButtons(card)
			end
			applyBlizzardPopups()
		end)
	dropdown("position", Settings.VarType.String, "Position",
		{ { "attached", "Attached to roll popups" }, { "free", "Free (drag anywhere)" } },
		"Attached sits above Blizzard's roll popups. Dragging the window switches it to Free.",
		function()
			applyPosition()
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
	dropdown("autoHide", Settings.VarType.Number, "Hide when idle after",
		{ { 0, "Never" }, { 10, "10 seconds" }, { 15, "15 seconds" }, { 30, "30 seconds" }, { 60, "60 seconds" } },
		"Fades the window once every drop is decided and nothing has happened for this long; a thin line drains "
			.. "under the title for the last few seconds. Hovering the window restarts the time. A window you open "
			.. "yourself stays until you close it (the pin by the close button shows this; click it to switch).",
		function()
			refreshPin()
		end)
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
		createMain()
		refreshPin()
		main:HookScript("OnShow", applyBlizzardPopups)
		main:HookScript("OnHide", applyBlizzardPopups)
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
		return
	end
	local ok, err = pcall(function(...)
		if event == "LOOT_HISTORY_UPDATE_DROP" then
			onDropUpdate(...)
		elseif event == "START_LOOT_ROLL" then
			onStartRoll(...)
		elseif event == "CANCEL_LOOT_ROLL" then
			onCancelRoll(...)
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
	demoRun = demoRun + 1 -- cancels a demo still playing, so its delayed clean-up can't cut into the test
	drops = math.max(1, math.min(drops or 400, 5000))
	players = math.max(1, math.min(players or 40, 40))
	clearDemoCards()
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
			say("stress: stopped, because real loot or the demo cleared its drops. Numbers so far:")
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
		runDemo()
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
		end
	else
		say("commands: /rollframes (show or hide) | demo | options | reset | blizzard | diag")
	end
end
