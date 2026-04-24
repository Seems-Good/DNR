-- ============================================================
--  DoNotRelease
--  Shows a large pulsing "PLEASE DO NOT RELEASE" warning when
--  the player dies inside an instance while in a group.
--
--  /dnr config  — opens the addon's settings panel in the
--                 Game Menu → Options → AddOns tab.
--
--  Midnight API notes:
--    * Uses C_PartyInfo.IsInGroup() where available, falls back
--      to the global IsInGroup() for pre-Midnight clients.
--    * Uses IsInInstance() rather than deprecated GetCurrentMapAreaID().
--    * PLAYER_DEAD / PLAYER_ALIVE / PLAYER_UNGHOST are stable
--      events carried forward through Midnight.
--
--  Animation notes:
--    * Pulse is alpha-only, driven by OnUpdate + math.sin.
--      SetScale() was removed: it forces a full pixel-geometry
--      recalc every frame which causes visible jitter at 60+ fps.
--      Alpha changes are GPU-composited with zero layout cost.
--
--  Localization notes:
--    * All user-facing strings live in DoNotReleaseL (see Locale/).
--    * Locale files are loaded first via the .toc.
--
--  Performance fixes (v1.0.1):
--    [FIX-1] pulseTime now wraps via % PULSE_PERIOD to prevent
--            float precision loss over long sessions.
--    [FIX-2] /dnr test auto-hides after TEST_DURATION seconds
--            (unless the player is genuinely dead in an instance)
--            so the OnUpdate loop can't be left running forever.
--    [FIX-3] GROUP_ROSTER_UPDATE is debounced: the event fires in
--            rapid bursts on roster changes; a 0.25 s C_Timer.After
--            collapses each burst into a single ShouldWarn() check.
--    [FIX-4] sizeSlider OnValueChanged now guards with a dirty-check
--            (val ~= last) so dragging doesn't call SetFont every
--            frame while the thumb is stationary between steps.
--    [FIX-5] onUpdate now self-terminates: on every frame it checks
--            ShouldWarn() and calls HideWarning() if conditions are no
--            longer met. Previously onUpdate ran blind until an external
--            event (PLAYER_ALIVE, PLAYER_UNGHOST, SettingsPanel:OnHide)
--            called HideWarning() — if those events didn't fire the loop
--            ran forever, causing constant CPU draw. A previewMode flag
--            exempts intentional shows (settings buttons, /dnr test).
--            PLAYER_ENTERING_WORLD is also deferred by 0.5 s to avoid
--            acting on a transient UnitIsDead() state after a load screen.
-- ============================================================

-- ── Locale shorthand ─────────────────────────────────────────────────────────
DoNotReleaseL = DoNotReleaseL or {}
local L = DoNotReleaseL

-- ── SavedVariables defaults ───────────────────────────────────────────────────
local DB_DEFAULTS = {
    posX         = 0,
    posY         = 120,
    colorR       = 1,
    colorG       = 0.1,
    colorB       = 0.1,
    warningText  = "PLEASE DO NOT RELEASE",
    fontSize     = 64,
    fontFace     = "Fonts\\FRIZQT__.TTF",
    releaseGuard = "timer",   -- "off" | "timer" (set timer as default)
}

local MAX_TEXT_LEN  = 32
local FONT_SIZE_MIN = 32
local FONT_SIZE_MAX = 96

-- [FIX-2] How long (seconds) the test preview stays visible before
-- auto-hiding. Only hides if the player isn't genuinely dead in an instance.
local TEST_DURATION = 10

local FONT_PRESETS = {
    { key = "FONT_DEFAULT", file = "Fonts\\FRIZQT__.TTF" },
    { key = "FONT_CLEAN",   file = "Fonts\\ARIALN.TTF"   },
    { key = "FONT_FANCY",   file = "Fonts\\MORPHEUS.TTF" },
    { key = "FONT_RUNIC",   file = "Fonts\\SKURRI.TTF"   },
}

local COLOR_PRESETS = {
    { key = "COLOR_RED",    r = 1,   g = 0.1,  b = 0.1 },
    { key = "COLOR_ORANGE", r = 1,   g = 0.55, b = 0.0 },
    { key = "COLOR_YELLOW", r = 1,   g = 1,    b = 0.0 },
    { key = "COLOR_WHITE",  r = 1,   g = 1,    b = 1   },
    { key = "COLOR_CYAN",   r = 0.0, g = 1,    b = 1   },
}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function PlayerIsInInstance()
    local inInstance, instanceType = IsInInstance()
    return inInstance
        and instanceType ~= "none"
        and instanceType ~= "pvp"
        and instanceType ~= "arena"
end

-- Resolve the best available IsInGroup implementation once at load time.
local _isInGroup
if C_PartyInfo and C_PartyInfo.IsInGroup then
    _isInGroup = function()
        return C_PartyInfo.IsInGroup(LE_PARTY_CATEGORY_HOME)
            or C_PartyInfo.IsInGroup(LE_PARTY_CATEGORY_INSTANCE)
    end
else
    _isInGroup = function() return IsInGroup() or IsInRaid() end
end

local function ShouldWarn()
    return UnitIsDead("player") and _isInGroup() and PlayerIsInInstance()
end

-- ── Warning frame ─────────────────────────────────────────────────────────────

local DNR = CreateFrame("Frame", "DoNotReleaseFrame", UIParent)
DNR:SetSize(800, 200)
DNR:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
DNR:SetFrameStrata("HIGH")
DNR:SetFrameLevel(100)
DNR:Hide()

local label = DNR:CreateFontString(nil, "OVERLAY")
label:SetPoint("CENTER", DNR, "CENTER", 0, 0)
label:SetFont("Fonts\\FRIZQT__.TTF", 64, "OUTLINE")
label:SetTextColor(1, 0.1, 0.1, 1)
label:SetShadowColor(1, 0.55, 0, 1)
label:SetShadowOffset(0, 0)
label:SetText(L["WARNING_TEXT"] or "PLEASE DO NOT RELEASE")

-- ── Smooth Pulse (alpha only) ─────────────────────────────────────────────────

local _sin         = math.sin
local _pi2         = math.pi * 2
local _floor       = math.floor
local _ceil        = math.ceil
local PULSE_PERIOD = 1.5
local ALPHA_MIN    = 0.35
local ALPHA_MAX    = 1.00
local ALPHA_MID    = (ALPHA_MAX + ALPHA_MIN) / 2
local ALPHA_AMP    = (ALPHA_MAX - ALPHA_MIN) / 2
local PHASE_OFFSET = math.pi / 2
local pulseTime    = 0
local previewMode  = false

local function HideWarning() -- forward decl for onUpdate
    previewMode = false
    DNR:Hide()
end

local function onUpdate(self, elapsed)
    if not previewMode and not ShouldWarn() then
        HideWarning()
        return
    end
    pulseTime = (pulseTime + elapsed) % PULSE_PERIOD
    self:SetAlpha(ALPHA_MID + ALPHA_AMP * _sin(
        pulseTime * _pi2 / PULSE_PERIOD + PHASE_OFFSET))
end

DNR:SetScript("OnShow", function(self)
    pulseTime = 0
    self:SetScript("OnUpdate", onUpdate)
end)

DNR:SetScript("OnHide", function(self)
    self:SetScript("OnUpdate", nil)
    self:SetAlpha(1)
end)

-- ── DB helpers ────────────────────────────────────────────────────────────────

local function ApplySavedPosition()
    if not DoNotReleaseDB then return end
    DNR:ClearAllPoints()
    DNR:SetPoint("CENTER", UIParent, "CENTER", DoNotReleaseDB.posX, DoNotReleaseDB.posY)
end

local function ApplySavedColor()
    if not DoNotReleaseDB then return end
    label:SetTextColor(DoNotReleaseDB.colorR, DoNotReleaseDB.colorG, DoNotReleaseDB.colorB, 1)
end

local function ApplySavedText()
    if not DoNotReleaseDB then return end
    local t = DoNotReleaseDB.warningText
    label:SetText((t and t ~= "") and t or DB_DEFAULTS.warningText)
end

local function ApplySavedFont()
    if not DoNotReleaseDB then return end
    label:SetFont(
        DoNotReleaseDB.fontFace or DB_DEFAULTS.fontFace,
        DoNotReleaseDB.fontSize or DB_DEFAULTS.fontSize,
        "OUTLINE")
end

local function SavePosition()
    if not DoNotReleaseDB then return end
    local x, y   = DNR:GetCenter()
    local cx, cy = UIParent:GetCenter()
    if not x or not cx then return end
    DoNotReleaseDB.posX = x - cx
    DoNotReleaseDB.posY = y - cy
end

-- ── Show / Hide ───────────────────────────────────────────────────────────────

local function ShowWarning()
    if ShouldWarn() then DNR:Show() end
end

-- ── Drag support ──────────────────────────────────────────────────────────────

local function EnableDNRDrag()
    DNR:SetMovable(true)
    DNR:EnableMouse(true)
    DNR:RegisterForDrag("LeftButton")
    DNR:SetScript("OnDragStart", function(self) self:StartMoving() end)
    DNR:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
        print("|cFFFF4444" .. (L["ADDON_TAG"] or "DoNotRelease") .. ":|r "
            .. (L["CONFIG_SAVED"] or "Settings saved."))
    end)
end

local function DisableDNRDrag()
    DNR:SetMovable(false)
    DNR:EnableMouse(false)
    DNR:SetScript("OnDragStart", nil)
    DNR:SetScript("OnDragStop", nil)
end

-- ── Release Guard ────────────────────────────────────────────────────────────
--
--  Modes (stored in DoNotReleaseDB.releaseGuard):
--    "off"   – no intervention; stock Release Spirit popup works normally.
--    "timer" – show our own N‑second countdown frame on top; when it
--              finishes (or is canceled), reveal the native DEATH popup.
--

local RELEASE_TIMER_SECS = 5

-- ─── Timer overlay frame (covers native popup) ───────────────────────────────

local timerFrame = CreateFrame("Frame", "DNRTimerFrame", UIParent, "BasicFrameTemplate")
timerFrame:SetSize(300, 130)
timerFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
timerFrame:SetFrameStrata("DIALOG")
timerFrame:SetFrameLevel(250)  -- above native StaticPopup
timerFrame:Hide()
timerFrame:SetMovable(true)
timerFrame:EnableMouse(true)
timerFrame:RegisterForDrag("LeftButton")
timerFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
timerFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

local timerLabel = timerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
timerLabel:SetPoint("CENTER", timerFrame, "CENTER", 0, 18)

local timerCancelBtn = CreateFrame("Button", nil, timerFrame, "UIPanelButtonTemplate")
timerCancelBtn:SetSize(140, 26)
timerCancelBtn:SetPoint("BOTTOM", timerFrame, "BOTTOM", 0, 14)
timerCancelBtn:SetText(L["TIMER_CANCEL"] or "Cancel")

local timerRemaining = 0
local timerTicker    = nil

-- Save original StaticPopup_Show once, then override later.
local _origStaticPopupShow = StaticPopup_Show

local function StopReleaseTimerInternal()
    if timerTicker then
        timerTicker:Cancel()
        timerTicker = nil
    end
    timerFrame:Hide()
end

-- core behavior for "timer finished" or "user canceled": hide overlay,
-- then immediately show Blizzard's DEATH popup.
local function FinishTimerAndShowNative()
    StopReleaseTimerInternal()
    if _origStaticPopupShow then
        _origStaticPopupShow("DEATH")
    end
end

timerCancelBtn:SetScript("OnClick", function()
    FinishTimerAndShowNative()
end)

-- X button uses the same behavior as Cancel.
timerFrame:SetScript("OnHide", function(self)
    -- If the frame is being hidden while the timer is still active,
    -- treat it as a cancel and show the native popup.
    if timerTicker then
        FinishTimerAndShowNative()
    end
end)

local function StartReleaseTimerOverlay()
    -- Start a fresh timer; do NOT show native popup yet.
    StopReleaseTimerInternal()
    timerRemaining = RELEASE_TIMER_SECS
    timerLabel:SetText(string.format(
        L["TIMER_RELEASING_IN"] or "Release available in %d…",
        timerRemaining
    ))
    timerFrame:Show()

    timerTicker = C_Timer.NewTicker(1, function()
        timerRemaining = timerRemaining - 1
        if timerRemaining <= 0 then
            -- Timer completed: behave exactly like Cancel.
            FinishTimerAndShowNative()
        else
            timerLabel:SetText(string.format(
                L["TIMER_RELEASING_IN"] or "Release available in %d…",
                timerRemaining
            ))
        end
    end, RELEASE_TIMER_SECS)
end

-- ─── Hook the stock Release Spirit popup ──────────────────────────────────────
--
-- For timer: suppress native DEATH at first and show our overlay timer.
--

StaticPopup_Show = function(which, ...)
    local db = DoNotReleaseDB
    if which == "DEATH" and db and db.releaseGuard == "timer" then
        StartReleaseTimerOverlay()
        return
    end

    if _origStaticPopupShow then
        return _origStaticPopupShow(which, ...)
    end
end

-- Clean up guard UIs when the player revives.
local function HideGuardFrames()
    StopReleaseTimerInternal()
end

-- ── Settings canvas panel ─────────────────────────────────────────────────────
-- (unchanged from your original file; only minor formatting differences)

local DNRCategory

local function BuildSettingsCanvas()
    local W     = 600
    local PAD   = 20
    local BTN_H = 26
    local y     = -10

    local outer = CreateFrame("Frame")
    outer:SetSize(W, 600)
    outer:Hide()

    local scrollFrame = CreateFrame("ScrollFrame", "DoNotReleaseScrollFrame", outer, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT",     outer, "TOPLEFT",      0,  0)
    scrollFrame:SetPoint("BOTTOMRIGHT", outer, "BOTTOMRIGHT", -26, 0)

    local canvas = CreateFrame("Frame", nil, scrollFrame)
    canvas:SetSize(W - 30, 800)
    scrollFrame:SetScrollChild(canvas)

    local function place(widget, xOff, width, height)
        widget:ClearAllPoints()
        widget:SetPoint("TOPLEFT", canvas, "TOPLEFT", xOff or PAD, y)
        if width  then widget:SetWidth(width)  end
        if height then widget:SetHeight(height) end
    end

    local function addGap(px) y = y - px end

    local function sectionHeader(key, fallback)
        local fs = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        place(fs, PAD)
        fs:SetText(L[key] or fallback)
        addGap(26)
    end

    local function divider()
        local line = canvas:CreateTexture(nil, "ARTWORK")
        line:SetColorTexture(0.3, 0.3, 0.3, 0.5)
        line:SetPoint("TOPLEFT",  canvas, "TOPLEFT",  PAD,  y)
        line:SetPoint("TOPRIGHT", canvas, "TOPRIGHT", -PAD, y)
        line:SetHeight(1)
        addGap(14)
    end

    local HALF_W = math.floor((W - PAD * 2 - 8) / 2)

    -- Position
    sectionHeader("CONFIG_POS_SECTION", "Position")

    local showBtn = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
    showBtn:SetSize(HALF_W, BTN_H)
    showBtn:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, y)
    showBtn:SetText(L["CONFIG_SHOW_WARNING"] or "Show Warning")

    local hideBtn = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
    hideBtn:SetSize(HALF_W, BTN_H)
    hideBtn:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD + HALF_W + 8, y)
    hideBtn:SetText(L["CONFIG_HIDE_WARNING"] or "Hide Warning")
    addGap(BTN_H + 8)

    local dragBtn = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
    dragBtn:SetSize(HALF_W, BTN_H)
    dragBtn:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, y)
    dragBtn:SetText(L["CONFIG_DRAG_HINT"] or "Drag to reposition")

    local resetBtn = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
    resetBtn:SetSize(HALF_W, BTN_H)
    resetBtn:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD + HALF_W + 8, y)
    resetBtn:SetText(L["CONFIG_RESET_POS"] or "Reset Position")
    addGap(BTN_H + 18)
    divider()

    -- Warning Color
    sectionHeader("CONFIG_COLOR_TITLE", "Warning Color")

    for i, preset in ipairs(COLOR_PRESETS) do
        local col = (i - 1) % 2
        local row = math.floor((i - 1) / 2)
        local pb = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
        pb:SetSize(HALF_W, BTN_H)
        pb:SetPoint("TOPLEFT", canvas, "TOPLEFT",
            PAD + col * (HALF_W + 8),
            y - row * (BTN_H + 4))
        pb:SetText(L[preset.key] or preset.key)

        local r, g, b = preset.r, preset.g, preset.b
        local pfs = pb:GetFontString()
        if pfs then pfs:SetTextColor(r, g, b, 1) end
        pb:SetScript("OnClick", function()
            if not DoNotReleaseDB then return end
            DoNotReleaseDB.colorR, DoNotReleaseDB.colorG, DoNotReleaseDB.colorB = r, g, b
            label:SetTextColor(r, g, b, 1)
            print("|cFFFF4444" .. (L["ADDON_TAG"] or "DoNotRelease") .. ":|r "
                .. (L["CONFIG_SAVED"] or "Settings saved."))
        end)
    end

    addGap(_ceil(#COLOR_PRESETS / 2) * (BTN_H + 4) + 18)
    divider()

    -- Warning Text
    sectionHeader("CONFIG_TEXT_TITLE", "Warning Text")

    local editBox = CreateFrame("EditBox", "DoNotReleaseTextInput", canvas, "InputBoxTemplate")
    editBox:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD + 6, y)
    editBox:SetWidth(W - PAD * 2 - 12)
    editBox:SetHeight(BTN_H)
    editBox:SetMaxLetters(MAX_TEXT_LEN)
    editBox:SetAutoFocus(false)
    editBox:SetText(DoNotReleaseDB and DoNotReleaseDB.warningText or DB_DEFAULTS.warningText)
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    addGap(BTN_H + 6)

    local charCount = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    charCount:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD + 6, y)
    charCount:SetTextColor(0.6, 0.6, 0.6, 1)

    local function updateCounter()
        charCount:SetText(#editBox:GetText() .. " / " .. MAX_TEXT_LEN)
    end
    updateCounter()
    editBox:SetScript("OnTextChanged", function() updateCounter() end)
    addGap(20)

    local setBtn = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
    setBtn:SetSize(HALF_W, BTN_H)
    setBtn:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, y)
    setBtn:SetText(L["CONFIG_TEXT_SET"] or "Set")

    local resetTextBtn = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
    resetTextBtn:SetSize(HALF_W, BTN_H)
    resetTextBtn:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD + HALF_W + 8, y)
    resetTextBtn:SetText(L["CONFIG_TEXT_RESET"] or "Reset Text")
    addGap(BTN_H + 18)
    divider()

    -- Font Size
    sectionHeader("CONFIG_SIZE_TITLE", "Font Size")

    local sizeSlider = CreateFrame("Slider", "DoNotReleaseOptsSizeSlider", canvas, "OptionsSliderTemplate")
    sizeSlider:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD + 8, y)
    sizeSlider:SetWidth(W - PAD * 2 - 16)
    sizeSlider:SetMinMaxValues(FONT_SIZE_MIN, FONT_SIZE_MAX)
    sizeSlider:SetValueStep(2)
    sizeSlider:SetObeyStepOnDrag(true)
    sizeSlider:SetValue(DoNotReleaseDB and DoNotReleaseDB.fontSize or DB_DEFAULTS.fontSize)
    DoNotReleaseOptsSizeSliderLow:SetText(FONT_SIZE_MIN .. "pt")
    DoNotReleaseOptsSizeSliderHigh:SetText(FONT_SIZE_MAX .. "pt")
    DoNotReleaseOptsSizeSliderText:SetText("")

    local sizeValue = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sizeValue:SetPoint("BOTTOM", sizeSlider, "TOP", 0, 4)

    local function refreshSizeLabel(v)
        sizeValue:SetText(_floor(v + 0.5) .. "pt")
    end
    refreshSizeLabel(sizeSlider:GetValue())

    local lastSliderSize = DoNotReleaseDB and DoNotReleaseDB.fontSize or DB_DEFAULTS.fontSize
    sizeSlider:SetScript("OnValueChanged", function(self, val)
        if not DoNotReleaseDB then return end
        local size = _floor(val + 0.5)
        refreshSizeLabel(size)
        if size == lastSliderSize then return end
        lastSliderSize = size
        DoNotReleaseDB.fontSize = size
        label:SetFont(DoNotReleaseDB.fontFace or DB_DEFAULTS.fontFace, size, "OUTLINE")
    end)
    addGap(54)
    divider()

    -- Font Face
    sectionHeader("CONFIG_FONT_TITLE", "Font")

    for i, preset in ipairs(FONT_PRESETS) do
        local col = (i - 1) % 2
        local row = math.floor((i - 1) / 2)
        local fb = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
        fb:SetSize(HALF_W, BTN_H)
        fb:SetPoint("TOPLEFT", canvas, "TOPLEFT",
            PAD + col * (HALF_W + 8),
            y - row * (BTN_H + 4))
        fb:SetText(L[preset.key] or preset.key)

        local fs = fb:GetFontString()
        if fs then fs:SetFont(preset.file, 13, "OUTLINE") end

        local fFile = preset.file
        fb:SetScript("OnClick", function()
            if not DoNotReleaseDB then return end
            DoNotReleaseDB.fontFace = fFile
            label:SetFont(fFile, DoNotReleaseDB.fontSize or DB_DEFAULTS.fontSize, "OUTLINE")
            print("|cFFFF4444" .. (L["ADDON_TAG"] or "DoNotRelease") .. ":|r "
                .. (L["CONFIG_SAVED"] or "Settings saved."))
        end)
    end

    addGap(_ceil(#FONT_PRESETS / 2) * (BTN_H + 4) + 16)
    divider()

    -- Release Guard
    sectionHeader("CONFIG_GUARD_TITLE", "Release Guard")

    local guardDesc = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    guardDesc:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, y)
    guardDesc:SetWidth(W - PAD * 2)
    guardDesc:SetJustifyH("LEFT")
    guardDesc:SetTextColor(0.72, 0.72, 0.72, 1)
    guardDesc:SetText(L["CONFIG_GUARD_DESC"]
        or "Intercept the Release Spirit button with a confirmation dialog or countdown timer.")
    addGap(32)

    local GUARD_MODES = {
        { key = "CONFIG_GUARD_OFF",     mode = "off",     label = "Off"            },
        -- Remove option for confirm menu in settings/options (used for testing does not need to be exposed)
        --{ key = "CONFIG_GUARD_CONFIRM", mode = "confirm", label = "Confirm Dialog" },
        { key = "CONFIG_GUARD_TIMER",   mode = "timer",   label = "Timer (" .. RELEASE_TIMER_SECS .. "s)" },
    }

    local guardBtns = {}
    local function refreshGuardButtons()
        local current = DoNotReleaseDB and DoNotReleaseDB.releaseGuard or "off"
        for _, info in ipairs(guardBtns) do
            if info.mode == current then
                info.btn:SetText("|cFFFFD700[x] " .. (L[info.key] or info.label) .. "|r")
            else
                info.btn:SetText(L[info.key] or info.label)
            end
        end
    end

    for i, gm in ipairs(GUARD_MODES) do
        local col = (i - 1) % 3
        local colW = math.floor((W - PAD * 2 - 8) / 3)
        local gb = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
        gb:SetSize(colW, BTN_H)
        gb:SetPoint("TOPLEFT", canvas, "TOPLEFT",
            PAD + col * (colW + 4), y)
        gb:SetText(L[gm.key] or gm.label)
        table.insert(guardBtns, { btn = gb, mode = gm.mode, key = gm.key, label = gm.label })

        local modeVal = gm.mode
        gb:SetScript("OnClick", function()
            if not DoNotReleaseDB then return end
            DoNotReleaseDB.releaseGuard = modeVal
            refreshGuardButtons()
            if modeVal == "off" then HideGuardFrames() end
            print("|cFFFF4444" .. (L["ADDON_TAG"] or "DoNotRelease") .. ":|r "
                .. (L["CONFIG_SAVED"] or "Settings saved."))
        end)
    end
    addGap(BTN_H + 18)

    local function fline(text, indent)
        local fs = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD + (indent or 0), y)
        fs:SetTextColor(0.72, 0.72, 0.72, 1)
        fs:SetText(text)
        addGap(18)
    end


    fline("|cFFFFD700DoNotRelease:|r |cFF4DA6FF[SeemsGood/DNR]|r"
        .. "  -  " .. (L["FOOTER_BUGS"] or "Report bugs on GitHub."))
    addGap(4)

    fline("|cFFFFD700" .. (L["FOOTER_OTHER_ADDONS"] or "Other Addons") .. "|r")
    fline("|cFFFFD700AccountPlayed:|r Playtime by Class - |cFF4DA6FF[Jeremy-Gstein/AccountPlayed]|r", 8)
    fline("|cFFFFD700AccountRepaired:|r Repair Cost Statistics - |cFF4DA6FF[Seems-Good/AccountRepaired]|r", 8)
    fline("|cFFFFD700DjLust:|r Bloodlust Music+Animations - |cFF4DA6FF[Jeremy-Gstein/DjLust]|r", 8)
    fline("|cFFFFD700ShodoQoL:|r Evoker QoL Settings/Macros - |cFF4DA6FF[Seems-Good/shodoqol]|r", 8)
    addGap(4)

    fline(L["FOOTER_SUPPORT"] or "Like these projects? Share feedback or donate <3")
    fline("|cFFFF6644Ko-fi:|r |cFF4DA6FFko-fi.com/j51b5|r"
        .. "    |cFFFF6644Web:|r |cFF4DA6FFhttps://seemsgood.org|r"
        .. "    |cFFFF6644Email:|r |cFF4DA6FFjeremy51b5@pm.me|r")
    addGap(10)

    outer:SetScript("OnShow", function()
        if not DoNotReleaseDB then return end
        editBox:SetText(label:GetText() or DB_DEFAULTS.warningText)
        updateCounter()
        local sz = DoNotReleaseDB.fontSize or DB_DEFAULTS.fontSize
        lastSliderSize = sz
        sizeSlider:SetValue(sz)
        refreshSizeLabel(sz)
        refreshGuardButtons()
    end)

    if SettingsPanel then
        SettingsPanel:HookScript("OnHide", function()
            DisableDNRDrag()
            if not ShouldWarn() then HideWarning() end
        end)
    end

    showBtn:SetScript("OnClick", function()
        previewMode = true
        DNR:Show()
    end)

    hideBtn:SetScript("OnClick", function()
        DisableDNRDrag()
        HideWarning()
    end)

    dragBtn:SetScript("OnClick", function()
        previewMode = true
        DNR:Show()
        EnableDNRDrag()
        print("|cFFFF4444" .. (L["ADDON_TAG"] or "DoNotRelease") .. ":|r "
            .. (L["CONFIG_DRAG_INLINE_MSG"] or "Drag the warning text, then release to save."))
    end)

    resetBtn:SetScript("OnClick", function()
        if not DoNotReleaseDB then return end
        DoNotReleaseDB.posX = DB_DEFAULTS.posX
        DoNotReleaseDB.posY = DB_DEFAULTS.posY
        ApplySavedPosition()
        print("|cFFFF4444" .. (L["ADDON_TAG"] or "DoNotRelease") .. ":|r "
            .. (L["CONFIG_POS_RESET_MSG"] or "Position reset to default."))
    end)

    setBtn:SetScript("OnClick", function()
        if not DoNotReleaseDB then return end
        local raw = strtrim(editBox:GetText())
        if raw == "" then
            print("|cFFFF4444" .. (L["ADDON_TAG"] or "DoNotRelease") .. ":|r "
                .. (L["CONFIG_TEXT_EMPTY_ERR"] or "Text cannot be empty."))
            return
        end
        DoNotReleaseDB.warningText = raw
        label:SetText(raw)
        ApplySavedFont()
        editBox:ClearFocus()
        print("|cFFFF4444" .. (L["ADDON_TAG"] or "DoNotRelease") .. ":|r "
            .. (L["CONFIG_SAVED"] or "Settings saved."))
    end)

    resetTextBtn:SetScript("OnClick", function()
        if not DoNotReleaseDB then return end
        DoNotReleaseDB.warningText = DB_DEFAULTS.warningText
        label:SetText(DB_DEFAULTS.warningText)
        ApplySavedFont()
        editBox:SetText(label:GetText() or DB_DEFAULTS.warningText)
        updateCounter()
        print("|cFFFF4444" .. (L["ADDON_TAG"] or "DoNotRelease") .. ":|r "
            .. (L["CONFIG_TEXT_RESET_MSG"] or "Warning text reset to default."))
    end)

    return outer
end

local function RegisterSettingsPanel()
    if not (Settings and Settings.RegisterCanvasLayoutCategory) then
        print("|cFFFF4444" .. (L["ADDON_TAG"] or "DoNotRelease") .. ":|r "
            .. (L["CONFIG_API_UNAVAILABLE"] or "Settings API unavailable on this client version."))
        return
    end
    local canvas = BuildSettingsCanvas()
    DNRCategory = Settings.RegisterCanvasLayoutCategory(canvas, L["ADDON_TAG"] or "DoNotRelease")
    Settings.RegisterAddOnCategory(DNRCategory)
end

local function OpenConfig()
    if DNRCategory and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(DNRCategory:GetID())
    else
        print("|cFFFF4444" .. (L["ADDON_TAG"] or "DoNotRelease") .. ":|r "
            .. (L["CONFIG_API_UNAVAILABLE"] or "Settings API unavailable on this client version."))
    end
end

-- ── Event Handling ────────────────────────────────────────────────────────────

local rosterUpdatePending = false

local eventFrame = CreateFrame("Frame", "DoNotReleaseEvents")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_DEAD")
eventFrame:RegisterEvent("PLAYER_ALIVE")
eventFrame:RegisterEvent("PLAYER_UNGHOST")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == "DoNotRelease" then
        self:UnregisterEvent("ADDON_LOADED")
        DoNotReleaseDB = DoNotReleaseDB or {}
        for k, v in pairs(DB_DEFAULTS) do
            if DoNotReleaseDB[k] == nil then
                DoNotReleaseDB[k] = v
            end
        end
        ApplySavedPosition()
        ApplySavedColor()
        ApplySavedText()
        ApplySavedFont()
        RegisterSettingsPanel()

    elseif event == "PLAYER_DEAD" then
        C_Timer.After(0.3, ShowWarning)

    elseif event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        HideWarning()
        HideGuardFrames()
        DisableDNRDrag()

    elseif event == "GROUP_ROSTER_UPDATE" then
        if rosterUpdatePending then return end
        rosterUpdatePending = true
        C_Timer.After(0.25, function()
            rosterUpdatePending = false
            if DNR:IsShown() and not ShouldWarn() then
                HideWarning()
            end
        end)

    elseif event == "PLAYER_ENTERING_WORLD" then
        HideWarning()
        C_Timer.After(0.5, function()
            if ShouldWarn() then ShowWarning() end
        end)
    end
end)

-- ── Slash Commands ────────────────────────────────────────────────────────────

SLASH_DONOTRELEASE1 = "/dnr"
SlashCmdList["DONOTRELEASE"] = function(msg)
    local cmd = strtrim(msg):lower()
    if cmd == "test" then
        previewMode = true
        DNR:Show()
        print("|cFFFF4444" .. (L["ADDON_TAG"] or "DoNotRelease") .. ":|r "
            .. (L["SLASH_TEST_MSG"] or "Test mode – warning shown."))
        C_Timer.After(TEST_DURATION, function()
            if not ShouldWarn() then HideWarning() end
        end)
    elseif cmd == "hide" then
        HideWarning()
        print("|cFFFF4444" .. (L["ADDON_TAG"] or "DoNotRelease") .. ":|r "
            .. (L["SLASH_HIDE_MSG"] or "Warning hidden."))
    elseif cmd == "config" then
        OpenConfig()
    else
        print("|cFFFF4444" .. (L["ADDON_TAG"] or "DoNotRelease") .. "|r  —  |cFFFFD700"
            .. (L["SLASH_HELP"] or "/dnr test  |  /dnr hide  |  /dnr config") .. "|r")
    end
end
