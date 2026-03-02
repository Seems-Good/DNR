-- ============================================================
--  DoNotRelease
--  Shows a large pulsing "PLEASE DO NOT RELEASE" warning when
--  the player dies inside an instance while in a group.
--
--  /dnr config  — opens a panel to reposition the frame and
--                 change the warning text colour. Both settings
--                 persist across sessions via SavedVariables
--                 (DoNotReleaseDB, declared in the .toc).
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
-- NOTE: No hardcoded fallback strings here. All strings must be supplied by a
-- Locale/*.lua file loaded before this file in the .toc. If a locale file is
-- missing, the addon will still work but string keys will be shown as-is.
DoNotReleaseL = DoNotReleaseL or {}
local L = DoNotReleaseL

-- ── SavedVariables defaults ───────────────────────────────────────────────────
-- DoNotReleaseDB is declared in the .toc as a SavedVariables entry.
-- We initialise it in ADDON_LOADED so the SV system has already populated it.
local DB_DEFAULTS = {
    posX   = 0,
    posY   = 120,
    colorR = 1,
    colorG = 0.1,
    colorB = 0.1,
}

-- Colour presets referenced by the config panel.
-- Each entry: { labelKey, r, g, b }
local COLOR_PRESETS = {
    { key = "COLOR_RED",    r = 1,    g = 0.1,  b = 0.1 },
    { key = "COLOR_ORANGE", r = 1,    g = 0.55, b = 0.0 },
    { key = "COLOR_YELLOW", r = 1,    g = 1,    b = 0.0 },
    { key = "COLOR_WHITE",  r = 1,    g = 1,    b = 1   },
    { key = "COLOR_CYAN",   r = 0.0,  g = 1,    b = 1   },
}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function PlayerIsInInstance()
    local inInstance, instanceType = IsInInstance()
    return inInstance
        and instanceType ~= "none"
        and instanceType ~= "pvp"
        and instanceType ~= "arena"
end

local function PlayerIsInGroup()
    if C_PartyInfo and C_PartyInfo.IsInGroup then
        return C_PartyInfo.IsInGroup(LE_PARTY_CATEGORY_HOME)
            or C_PartyInfo.IsInGroup(LE_PARTY_CATEGORY_INSTANCE)
    end
    return IsInGroup() or IsInRaid()
end

local function ShouldWarn()
    return UnitIsDead("player") and PlayerIsInGroup() and PlayerIsInInstance()
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
local PULSE_PERIOD = 1.5
local ALPHA_MIN    = 0.35
local ALPHA_MAX    = 1.00
local ALPHA_MID    = (ALPHA_MAX + ALPHA_MIN) / 2   -- 0.675
local ALPHA_AMP    = (ALPHA_MAX - ALPHA_MIN) / 2   -- 0.325
local PHASE_OFFSET = math.pi / 2

local pulseTime = 0

local function onUpdate(self, elapsed)
    pulseTime = pulseTime + elapsed
    self:SetAlpha(ALPHA_MID + ALPHA_AMP * math.sin(
        pulseTime * (2 * math.pi) / PULSE_PERIOD + PHASE_OFFSET))
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

--- Apply the saved position from DoNotReleaseDB to DNR.
-- SetUserPlaced(false) clears the absolute-position flag that WoW sets after a
-- drag, allowing SetPoint to take effect immediately and correctly.
local function ApplySavedPosition()
    if not DoNotReleaseDB then return end
    DNR:ClearAllPoints()
    DNR:SetPoint("CENTER", UIParent, "CENTER", DoNotReleaseDB.posX, DoNotReleaseDB.posY)
end

--- Apply the saved text colour from DoNotReleaseDB to the label.
local function ApplySavedColor()
    if not DoNotReleaseDB then return end
    label:SetTextColor(DoNotReleaseDB.colorR, DoNotReleaseDB.colorG, DoNotReleaseDB.colorB, 1)
end

--- Persist DNR's current screen position into DoNotReleaseDB.
-- After WoW's drag system moves a frame it stores absolute coords internally.
-- We read those back as a CENTER offset from UIParent so they survive resolution changes.
local function SavePosition()
    if not DoNotReleaseDB then return end
    -- GetCenter() returns screen pixels; UIParent:GetCenter() is the screen midpoint.
    local x, y   = DNR:GetCenter()
    local cx, cy = UIParent:GetCenter()
    if not x or not cx then return end
    DoNotReleaseDB.posX = x - cx
    DoNotReleaseDB.posY = y - cy
end

-- ── Show / Hide ───────────────────────────────────────────────────────────────

local function ShowWarning()
    if ShouldWarn() then
        DNR:Show()
    end
end

local function HideWarning()
    DNR:Hide()
end

-- ── Config Panel ──────────────────────────────────────────────────────────────
-- Built lazily on first /dnr config call.
-- Layout uses fixed pixel offsets from the panel TOPLEFT so nothing can drift.

local configFrame
local DisableDNRDrag  -- forward declaration

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

DisableDNRDrag = function()
    DNR:SetMovable(false)
    DNR:EnableMouse(false)
    DNR:SetScript("OnDragStart", nil)
    DNR:SetScript("OnDragStop", nil)
end

local function BuildConfigPanel()
    if configFrame then return end

    -- Panel is 300 wide × 330 tall — big enough for all rows with room to spare.
    local W, H = 300, 330
    local PAD  = 20   -- left/right padding inside the panel
    local BTN_H = 26  -- standard button height
    local y = -40     -- cursor: offset from TOPLEFT, advances downward (negative)

    local BACKDROP = {
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    }

    configFrame = CreateFrame("Frame", "DoNotReleaseConfig", UIParent, "BackdropTemplate")
    configFrame:SetSize(W, H)
    configFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    configFrame:SetFrameStrata("DIALOG")
    configFrame:SetFrameLevel(200)
    configFrame:SetBackdrop(BACKDROP)
    configFrame:SetBackdropColor(0, 0, 0, 0.92)
    configFrame:SetMovable(true)
    configFrame:EnableMouse(true)
    configFrame:RegisterForDrag("LeftButton")
    configFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    configFrame:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
    configFrame:Hide()

    -- ── Helper: place a widget at the current y cursor ────────────────────────
    local function place(widget, xOff, width, height)
        widget:ClearAllPoints()
        widget:SetPoint("TOPLEFT", configFrame, "TOPLEFT", xOff or PAD, y)
        if width  then widget:SetWidth(width)   end
        if height then widget:SetHeight(height) end
    end

    local function addGap(px) y = y - px end

    -- ── Title ─────────────────────────────────────────────────────────────────
    local title = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", configFrame, "TOP", 0, -14)
    title:SetText(L["CONFIG_TITLE"] or "DoNotRelease Config")

    -- ── Section: Reposition ───────────────────────────────────────────────────
    addGap(10) -- y = -40 already set above, but the title takes up ~20px so start content at -50
    y = -50

    local posHeader = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    place(posHeader, PAD)
    posHeader:SetText("|cFFFFD700" .. "Position" .. "|r")
    addGap(20)

    -- "Click then drag the warning" button — full width minus padding
    local dragBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
    place(dragBtn, PAD, W - PAD * 2, BTN_H)
    dragBtn:SetText(L["CONFIG_DRAG_HINT"] or "Click, then drag warning text")
    addGap(BTN_H + 6)

    local resetBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
    place(resetBtn, PAD, W - PAD * 2, BTN_H)
    resetBtn:SetText(L["CONFIG_RESET_POS"] or "Reset Position")
    addGap(BTN_H + 14)

    -- ── Section: Color ────────────────────────────────────────────────────────
    local colorHeader = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    place(colorHeader, PAD)
    colorHeader:SetText("|cFFFFD700" .. (L["CONFIG_COLOR_TITLE"] or "Warning Color") .. "|r")
    addGap(20)

    -- Two columns of color buttons, each (W/2 - PAD - 4) wide
    local COL_W = math.floor((W - PAD * 2 - 8) / 2)  -- 116 at W=300
    for i, preset in ipairs(COLOR_PRESETS) do
        local col = (i - 1) % 2          -- 0 = left, 1 = right
        local row = math.floor((i - 1) / 2)

        local pb = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
        pb:SetSize(COL_W, BTN_H)
        pb:SetPoint("TOPLEFT", configFrame, "TOPLEFT",
            PAD + col * (COL_W + 8),
            y - row * (BTN_H + 4))
        pb:SetText(L[preset.key] or preset.key)

        -- Colour the button's font string to preview the colour.
        -- We set it on every relevant font state because UIPanelButtonTemplate
        -- owns the FontString and resets it on mouse events.
        local r, g, b = preset.r, preset.g, preset.b
        local function tintBtn()
            local fs = pb:GetFontString()
            if fs then fs:SetTextColor(r, g, b, 1) end
        end
        tintBtn()
        pb:SetScript("OnShow",   tintBtn)
        pb:SetScript("OnEnable", tintBtn)

        pb:SetScript("OnClick", function()
            if not DoNotReleaseDB then
                print("|cFFFF4444DoNotRelease:|r DB not ready — make sure DoNotReleaseDB is in your .toc SavedVariables.")
                return
            end
            DoNotReleaseDB.colorR = r
            DoNotReleaseDB.colorG = g
            DoNotReleaseDB.colorB = b
            -- Apply directly to label as well as via helper (belt-and-braces)
            label:SetTextColor(r, g, b, 1)
            print("|cFFFF4444" .. (L["ADDON_TAG"] or "DoNotRelease") .. ":|r "
                .. (L["CONFIG_SAVED"] or "Settings saved."))
        end)
    end

    -- Advance cursor past the color button rows
    local colorRows = math.ceil(#COLOR_PRESETS / 2)
    addGap(colorRows * (BTN_H + 4) + 14)

    -- ── Close button — centred at bottom ──────────────────────────────────────
    local closeBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
    closeBtn:SetSize(100, BTN_H)
    closeBtn:SetPoint("BOTTOM", configFrame, "BOTTOM", 0, 16)
    closeBtn:SetText(L["CONFIG_CLOSE"] or "Close")
    closeBtn:SetScript("OnClick", function()
        DisableDNRDrag()
        if not ShouldWarn() then HideWarning() end
        configFrame:Hide()
    end)

    -- ── Button callbacks ──────────────────────────────────────────────────────
    dragBtn:SetScript("OnClick", function()
        DNR:Show()
        EnableDNRDrag()
        print("|cFFFF4444" .. (L["ADDON_TAG"] or "DoNotRelease")
            .. ":|r Drag the warning text, then release to save.")
    end)

    resetBtn:SetScript("OnClick", function()
        if not DoNotReleaseDB then return end
        DoNotReleaseDB.posX = DB_DEFAULTS.posX
        DoNotReleaseDB.posY = DB_DEFAULTS.posY
        ApplySavedPosition()
        print("|cFFFF4444" .. (L["ADDON_TAG"] or "DoNotRelease") .. ":|r "
            .. (L["CONFIG_POS_RESET_MSG"] or "Position reset to default."))
    end)

    configFrame:SetScript("OnHide", function()
        DisableDNRDrag()
        if not ShouldWarn() then HideWarning() end
    end)
end

local function OpenConfig()
    BuildConfigPanel()
    DNR:Show()
    configFrame:Show()
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
        -- Initialise SavedVariables: fill in any keys missing from an older DB.
        DoNotReleaseDB = DoNotReleaseDB or {}
        for k, v in pairs(DB_DEFAULTS) do
            if DoNotReleaseDB[k] == nil then
                DoNotReleaseDB[k] = v
            end
        end
        ApplySavedPosition()
        ApplySavedColor()

    elseif event == "PLAYER_DEAD" then
        C_Timer.After(0.3, ShowWarning)

    elseif event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        HideWarning()

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

-- ── Slash Commands (/dnr test | /dnr hide | /dnr config) ─────────────────────

SLASH_DONOTRELEASE1 = "/dnr"
SlashCmdList["DONOTRELEASE"] = function(msg)
    local cmd = strtrim(msg):lower()
    if cmd == "test" then
        DNR:Show()
        print("|cFFFF4444" .. (L["ADDON_TAG"] or "DoNotRelease") .. ":|r " .. (L["SLASH_TEST_MSG"] or "Test mode — warning shown."))
    elseif cmd == "hide" then
        HideWarning()
        print("|cFFFF4444" .. (L["ADDON_TAG"] or "DoNotRelease") .. ":|r " .. (L["SLASH_HIDE_MSG"] or "Warning hidden."))
    elseif cmd == "config" then
        OpenConfig()
    else
        print("|cFFFF4444" .. (L["ADDON_TAG"] or "DoNotRelease") .. "|r  —  |cFFFFD700" .. (L["SLASH_HELP"] or "/dnr test  |  /dnr hide  |  /dnr config") .. "|r")
    end
end
