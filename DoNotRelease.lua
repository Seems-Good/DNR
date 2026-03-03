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
-- ============================================================

-- ── Locale shorthand ─────────────────────────────────────────────────────────
DoNotReleaseL = DoNotReleaseL or {}
local L = DoNotReleaseL

-- ── SavedVariables defaults ───────────────────────────────────────────────────
local DB_DEFAULTS = {
    posX        = 0,
    posY        = 120,
    colorR      = 1,
    colorG      = 0.1,
    colorB      = 0.1,
    warningText = "PLEASE DO NOT RELEASE",
    fontSize    = 64,
    fontFace    = "Fonts\\FRIZQT__.TTF",
}

local MAX_TEXT_LEN  = 32
local FONT_SIZE_MIN = 32
local FONT_SIZE_MAX = 96

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

-- Resolve the best available IsInGroup implementation once at load time,
-- avoiding repeated nil-checks and global table lookups on every ShouldWarn call.
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
-- math.sin / math.pi are localized to avoid global table lookups every frame.
local _sin         = math.sin
local _pi2         = math.pi * 2
local PULSE_PERIOD = 1.5
local ALPHA_MIN    = 0.35
local ALPHA_MAX    = 1.00
local ALPHA_MID    = (ALPHA_MAX + ALPHA_MIN) / 2
local ALPHA_AMP    = (ALPHA_MAX - ALPHA_MIN) / 2
local PHASE_OFFSET = math.pi / 2
local pulseTime    = 0

local function onUpdate(self, elapsed)
    pulseTime = pulseTime + elapsed
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

local function HideWarning()
    DNR:Hide()
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

-- ── Settings canvas panel ─────────────────────────────────────────────────────
-- Registered with Settings.RegisterCanvasLayoutCategory so it appears under
-- Game Menu → Options → AddOns, alongside other addons like BugSack.
-- Built once in ADDON_LOADED (after DB is ready), then handed to the API.

local DNRCategory  -- the registered Settings.Category handle

local function BuildSettingsCanvas()
    -- WoW's options panel provides ~623 px of usable width.
    local W     = 600
    local PAD   = 20
    local BTN_H = 26
    local y     = -10  -- cursor offset from TOPLEFT, grows negative downward

    -- Outer frame that WoW hands to the Settings API
    local outer = CreateFrame("Frame")
    outer:SetSize(W, 600)

    local scrollFrame = CreateFrame("ScrollFrame", "DoNotReleaseScrollFrame", outer, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT",     outer, "TOPLEFT",      0,  0)
    scrollFrame:SetPoint("BOTTOMRIGHT", outer, "BOTTOMRIGHT", -26, 0)

    local canvas = CreateFrame("Frame", nil, scrollFrame)
    canvas:SetSize(W - 30, 800)
    scrollFrame:SetScrollChild(canvas)
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

    -- Shared column width used throughout the panel.
    local HALF_W = math.floor((W - PAD * 2 - 8) / 2)

    -- ── Position ──────────────────────────────────────────────────────────────
    sectionHeader("CONFIG_POS_SECTION", "Position")

    -- Row 1: Show / Hide — lets the user preview changes while Options is open.
    local showBtn = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
    showBtn:SetSize(HALF_W, BTN_H)
    showBtn:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, y)
    showBtn:SetText(L["CONFIG_SHOW_WARNING"] or "Show Warning")

    local hideBtn = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
    hideBtn:SetSize(HALF_W, BTN_H)
    hideBtn:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD + HALF_W + 8, y)
    hideBtn:SetText(L["CONFIG_HIDE_WARNING"] or "Hide Warning")
    addGap(BTN_H + 8)

    -- Row 2: Drag | Reset Position
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

    -- ── Warning Color ─────────────────────────────────────────────────────────
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
        local function tintBtn()
            local fs = pb:GetFontString()
            if fs then fs:SetTextColor(r, g, b, 1) end
        end
        tintBtn()
        pb:SetScript("OnShow",   tintBtn)
        pb:SetScript("OnEnable", tintBtn)
        pb:SetScript("OnClick", function()
            if not DoNotReleaseDB then return end
            DoNotReleaseDB.colorR, DoNotReleaseDB.colorG, DoNotReleaseDB.colorB = r, g, b
            label:SetTextColor(r, g, b, 1)
            print("|cFFFF4444" .. (L["ADDON_TAG"] or "DoNotRelease") .. ":|r "
                .. (L["CONFIG_SAVED"] or "Settings saved."))
        end)
    end

    addGap(math.ceil(#COLOR_PRESETS / 2) * (BTN_H + 4) + 18)  -- color rows
    divider()

    -- ── Warning Text ──────────────────────────────────────────────────────────
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

    -- ── Font Size ─────────────────────────────────────────────────────────────
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
    DoNotReleaseOptsSizeSliderText:SetText("")  -- we use our own readout

    local sizeValue = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sizeValue:SetPoint("BOTTOM", sizeSlider, "TOP", 0, 4)

    local function refreshSizeLabel(v)
        sizeValue:SetText(math.floor(v + 0.5) .. "pt")
    end
    refreshSizeLabel(sizeSlider:GetValue())

    sizeSlider:SetScript("OnValueChanged", function(self, val)
        if not DoNotReleaseDB then return end
        local size = math.floor(val + 0.5)
        DoNotReleaseDB.fontSize = size
        label:SetFont(DoNotReleaseDB.fontFace or DB_DEFAULTS.fontFace, size, "OUTLINE")
        refreshSizeLabel(size)
    end)
    addGap(54)
    divider()

    -- ── Font Face ─────────────────────────────────────────────────────────────
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

        -- Set font once at creation. No need for OnShow/OnEnable hooks
        -- since UIPanelButtonTemplate does not reset the font face.
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

    addGap(math.ceil(#FONT_PRESETS / 2) * (BTN_H + 4) + 16)
    -- ── Footer ────────────────────────────────────────────────────────────────
    local function fline(text, indent)
        local fs = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD + (indent or 0), y)
        fs:SetTextColor(0.72, 0.72, 0.72, 1)
        fs:SetText(text)
        addGap(18)
    end

    fline("|cFFFFD700Jeremy-Gstein|r"
        .. "  \226\128\148  DoNotRelease: |cFF4DA6FF[SeemsGood/DNR]|r"
        .. "  \226\128\148  " .. (L["FOOTER_BUGS"] or "Report bugs on GitHub."))
    addGap(4)

    fline("|cFFFFD700" .. (L["FOOTER_OTHER_ADDONS"] or "Other Addons") .. "|r")

    fline("|cFFFFD700AccountPlayed|r \226\128\148 Playtime by class  |cFF4DA6FF[Jeremy-Gstein/AccountPlayed]|r", 8)
    fline("|cFFFFD700HydroHomieReminder|r \226\128\148 Frost Mage elemental alerts  |cFF4DA6FF[Seems-Good/HydroHomieReminder]|r", 8)
    fline("|cFFFFD700SilvermoonStimming|r \226\128\148 Lap tracker  |cFF4DA6FF[Jeremy-Gstein/SilvermoonStimming]|r", 8)
    fline("|cFFFFD700DjLust|r \226\128\148 Bloodlust animations  |cFF4DA6FF[Jeremy-Gstein/DjLust]|r", 8)
    fline("|cFFFFD700C-Inspect|r \226\128\148 Ctrl+Click to inspect gear  |cFF4DA6FF[Jeremy-Gstein/C-Inspect]|r", 8)
    addGap(4)

    fline(L["FOOTER_SUPPORT"] or "Like these projects? Share feedback or donate <3 \226\157\164")
    fline("|cFFFF6644Ko-fi:|r |cFF4DA6FFko-fi.com/j51b5|r"
        .. "    |cFFFF6644Web:|r |cFF4DA6FFseemsgood.org|r"
        .. "    |cFFFF6644Email:|r |cFF4DA6FFjeremy51b5@pm.me|r")
    addGap(10)

    -- Sync controls whenever the panel becomes visible.
    -- outer:OnShow fires when WoW navigates to our category page.
    outer:SetScript("OnShow", function()
        if not DoNotReleaseDB then return end
        -- Read text directly from the label — it always reflects the current
        -- saved value since ApplySavedText() is called at load and on every change.
        -- This avoids the InputBoxTemplate deferred-render timing issue entirely.
        editBox:SetText(label:GetText() or DB_DEFAULTS.warningText)
        updateCounter()
        local sz = DoNotReleaseDB.fontSize or DB_DEFAULTS.fontSize
        sizeSlider:SetValue(sz)
        refreshSizeLabel(sz)
    end)

    -- Clean up when the Options window itself is closed.
    -- HookScript is non-destructive: chains after any existing OnHide.
    -- Fires however the user closes Options (X button, Escape, clicking away).
    if SettingsPanel then
        SettingsPanel:HookScript("OnHide", function()
            DisableDNRDrag()
            if not ShouldWarn() then HideWarning() end
        end)
    end

    -- ── Button callbacks ──────────────────────────────────────────────────────
    showBtn:SetScript("OnClick", function()
        DNR:Show()
    end)

    hideBtn:SetScript("OnClick", function()
        DisableDNRDrag()
        HideWarning()
    end)

    dragBtn:SetScript("OnClick", function()
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
        ApplySavedFont()  -- re-apply after SetText to guard against font reset
        editBox:ClearFocus()
        print("|cFFFF4444" .. (L["ADDON_TAG"] or "DoNotRelease") .. ":|r "
            .. (L["CONFIG_SAVED"] or "Settings saved."))
    end)

    resetTextBtn:SetScript("OnClick", function()
        if not DoNotReleaseDB then return end
        DoNotReleaseDB.warningText = DB_DEFAULTS.warningText
        label:SetText(DB_DEFAULTS.warningText)
        -- Re-apply font after SetText: WoW can reset a FontString's font
        -- back to its inherited template when SetText is called on display
        -- fonts (MORPHEUS, SKURRI). This keeps the slider working correctly.
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

local eventFrame = CreateFrame("Frame", "DoNotReleaseEvents")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_DEAD")
eventFrame:RegisterEvent("PLAYER_ALIVE")
eventFrame:RegisterEvent("PLAYER_UNGHOST")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == "DoNotRelease" then
        -- Unregister immediately — this event fires for every addon at startup.
        -- No reason to keep checking arg1 for every subsequent addon load.
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
        DisableDNRDrag()

    elseif event == "GROUP_ROSTER_UPDATE" then
        if DNR:IsShown() and not ShouldWarn() then
            HideWarning()
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        if ShouldWarn() then
            ShowWarning()
        else
            HideWarning()
        end
    end
end)

-- ── Slash Commands ────────────────────────────────────────────────────────────

SLASH_DONOTRELEASE1 = "/dnr"
SlashCmdList["DONOTRELEASE"] = function(msg)
    local cmd = strtrim(msg):lower()
    if cmd == "test" then
        DNR:Show()
        print("|cFFFF4444" .. (L["ADDON_TAG"] or "DoNotRelease") .. ":|r "
            .. (L["SLASH_TEST_MSG"] or "Test mode \226\128\148 warning shown."))
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
