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

local function TAG()
    return "|cFFFF4444" .. (L["PRETTY_ADDON_TAG"] or "DoNotRelease") .. ":|r "
end

-- ── SavedVariables defaults ─────────────────────────────────────────────────
local DB_DEFAULTS = {
    posX         = 0,
    posY         = 120,
    colorR       = 1,
    colorG       = 0.1,
    colorB       = 0.1,
    warningText  = "PLEASE DO NOT RELEASE",
    fontSize     = 64,
    fontFace     = "Fonts\\FRIZQT__.TTF",
    releaseGuard = "timer", -- "off" | "timer" | "twofactor" | "code" | "totp"
    totpSecret   = nil,
}

local MAX_TEXT_LEN  = 32
local FONT_SIZE_MIN = 32
local FONT_SIZE_MAX = 96
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

local VERSION = "@project-version@"

-- ── Helpers ─────────────────────────────────────────────────────────────────
local function PlayerIsInInstance()
    local inInstance, instanceType = IsInInstance()
    return inInstance
        and instanceType ~= "none"
        and instanceType ~= "pvp"
        and instanceType ~= "arena"
end

local _isInGroup
if C_PartyInfo and C_PartyInfo.IsInGroup then
    _isInGroup = function()
        return C_PartyInfo.IsInGroup(LE_PARTY_CATEGORY_HOME)
            or C_PartyInfo.IsInGroup(LE_PARTY_CATEGORY_INSTANCE)
    end
else
    _isInGroup = function()
        return IsInGroup() or IsInRaid()
    end
end

local function ShouldWarn()
    return UnitIsDead("player") and _isInGroup() and PlayerIsInInstance()
end

-- ── Warning frame ───────────────────────────────────────────────────────────
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

-- ── Smooth Pulse (alpha only) ───────────────────────────────────────────────
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

local function HideWarning()
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

-- ── DB helpers ──────────────────────────────────────────────────────────────
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
        "OUTLINE"
    )
end

local function SavePosition()
    if not DoNotReleaseDB then return end
    local x, y = DNR:GetCenter()
    local cx, cy = UIParent:GetCenter()
    if not x or not cx then return end
    DoNotReleaseDB.posX = x - cx
    DoNotReleaseDB.posY = y - cy
end

-- ── Show / Hide ─────────────────────────────────────────────────────────────
local function ShowWarning()
    if ShouldWarn() then DNR:Show() end
end

-- ── Drag support ────────────────────────────────────────────────────────────
local function EnableDNRDrag()
    DNR:SetMovable(true)
    DNR:EnableMouse(true)
    DNR:RegisterForDrag("LeftButton")
    DNR:SetScript("OnDragStart", function(self) self:StartMoving() end)
    DNR:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
        print(TAG() .. (L["CONFIG_SAVED"] or "Settings saved."))
    end)
end

local function DisableDNRDrag()
    DNR:SetMovable(false)
    DNR:EnableMouse(false)
    DNR:SetScript("OnDragStart", nil)
    DNR:SetScript("OnDragStop", nil)
end

-- ── Release Guard ───────────────────────────────────────────────────────────
local RELEASE_TIMER_SECS = 5

local timerFrame = CreateFrame("Frame", "DNRTimerFrame", UIParent, "BasicFrameTemplate")
timerFrame:SetSize(300, 130)
timerFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
timerFrame:SetFrameStrata("DIALOG")
timerFrame:SetFrameLevel(250)
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
local timerTicker = nil
local _origStaticPopupShow = StaticPopup_Show

local function StopReleaseTimerInternal()
    if timerTicker then
        timerTicker:Cancel()
        timerTicker = nil
    end
    timerFrame:Hide()
end

local function FinishTimerAndShowNative()
    StopReleaseTimerInternal()
    if _origStaticPopupShow then
        _origStaticPopupShow("DEATH")
    end
end

timerCancelBtn:SetScript("OnClick", FinishTimerAndShowNative)

timerFrame:SetScript("OnHide", function()
    if timerTicker then
        FinishTimerAndShowNative()
    end
end)

local function StartReleaseTimerOverlay()
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
            FinishTimerAndShowNative()
        else
            timerLabel:SetText(string.format(
                L["TIMER_RELEASING_IN"] or "Release available in %d…",
                timerRemaining
            ))
        end
    end, RELEASE_TIMER_SECS)
end

-- ─── Random code overlay ────────────────────────────────────────────────────
local tfFrame = CreateFrame("Frame", "DNRTwoFactorFrame", UIParent, "BasicFrameTemplate")
tfFrame:SetSize(320, 190)
tfFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
tfFrame:SetFrameStrata("DIALOG")
tfFrame:SetFrameLevel(250)
tfFrame:Hide()
tfFrame:SetMovable(true)
tfFrame:EnableMouse(true)
tfFrame:RegisterForDrag("LeftButton")
tfFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
tfFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

local tfTitle = tfFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
tfTitle:SetPoint("TOP", tfFrame, "TOP", 0, -28)
tfTitle:SetText(L["TF_TITLE"] or "Two-Factor Release")

local tfInstr = tfFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
tfInstr:SetPoint("TOP", tfTitle, "BOTTOM", 0, -6)
tfInstr:SetTextColor(0.8, 0.8, 0.8, 1)
tfInstr:SetText(L["TF_INSTRUCTION"] or "Type the code below to release:")

local tfCodeLabel = tfFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
tfCodeLabel:SetPoint("TOP", tfInstr, "BOTTOM", 0, -8)
tfCodeLabel:SetFont("Fonts\\FRIZQT__.TTF", 28, "OUTLINE")
tfCodeLabel:SetTextColor(1, 0.82, 0.0, 1)

local tfInput = CreateFrame("EditBox", "DNRTwoFactorInput", tfFrame, "InputBoxTemplate")
tfInput:SetSize(120, 28)
tfInput:SetPoint("TOP", tfCodeLabel, "BOTTOM", 0, -10)
tfInput:SetMaxLetters(4)
tfInput:SetAutoFocus(false)
tfInput:SetNumeric(true)

local tfFeedback = tfFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
tfFeedback:SetPoint("TOP", tfInput, "BOTTOM", 0, -4)
tfFeedback:SetTextColor(1, 0.2, 0.2, 1)
tfFeedback:SetText("")

local tfConfirmBtn = CreateFrame("Button", nil, tfFrame, "UIPanelButtonTemplate")
tfConfirmBtn:SetSize(130, 26)
tfConfirmBtn:SetPoint("BOTTOMLEFT", tfFrame, "BOTTOMLEFT", 14, 14)
tfConfirmBtn:SetText(L["TF_CONFIRM"] or "Confirm")

local tfCancelBtn = CreateFrame("Button", nil, tfFrame, "UIPanelButtonTemplate")
tfCancelBtn:SetSize(130, 26)
tfCancelBtn:SetPoint("BOTTOMRIGHT", tfFrame, "BOTTOMRIGHT", -14, 14)
tfCancelBtn:SetText(L["TF_CANCEL"] or "Cancel")

local tfCurrentCode = ""

local function GenerateTwoFactorCode()
    return string.format("%04d", math.random(0, 9999))
end

local function StopTwoFactorInternal()
    tfFrame:Hide()
    tfInput:SetText("")
    tfFeedback:SetText("")
    tfInput:ClearFocus()
end

local function FinishTwoFactorAndShowNative()
    StopTwoFactorInternal()
    if _origStaticPopupShow then
        _origStaticPopupShow("DEATH")
    end
end

local function AttemptTwoFactorConfirm()
    local entered = strtrim(tfInput:GetText())
    if entered == tfCurrentCode then
        FinishTwoFactorAndShowNative()
    else
        tfFeedback:SetText(L["TF_WRONG_CODE"] or "Incorrect code — try again.")
        tfInput:SetText("")
        tfInput:SetFocus()
    end
end

tfConfirmBtn:SetScript("OnClick", AttemptTwoFactorConfirm)
tfInput:SetScript("OnEnterPressed", AttemptTwoFactorConfirm)
tfCancelBtn:SetScript("OnClick", FinishTwoFactorAndShowNative)

tfFrame:SetScript("OnHide", function()
    if tfCurrentCode ~= "" then
        tfCurrentCode = ""
        tfInput:SetText("")
        tfFeedback:SetText("")
        tfInput:ClearFocus()
        if _origStaticPopupShow then
            _origStaticPopupShow("DEATH")
        end
    end
end)

local function StartTwoFactorOverlay()
    tfCurrentCode = GenerateTwoFactorCode()
    tfCodeLabel:SetText(tfCurrentCode)
    tfInput:SetText("")
    tfFeedback:SetText("")
    tfFrame:Show()
    tfInput:SetFocus()
end

-- ─── TOTP overlay ────────────────────────────────────────────────────────────
local totpFrame = CreateFrame("Frame", "DNRTotpFrame", UIParent, "BasicFrameTemplate")
totpFrame:SetSize(340, 210)
totpFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
totpFrame:SetFrameStrata("DIALOG")
totpFrame:SetFrameLevel(250)
totpFrame:Hide()
totpFrame:SetMovable(true)
totpFrame:EnableMouse(true)
totpFrame:RegisterForDrag("LeftButton")
totpFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
totpFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

local totpTitle = totpFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
totpTitle:SetPoint("TOP", totpFrame, "TOP", 0, -28)
totpTitle:SetText(L["TOTP_TITLE"] or "Authenticator Required")

local totpInstr = totpFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
totpInstr:SetPoint("TOP", totpTitle, "BOTTOM", 0, -6)
totpInstr:SetTextColor(0.8, 0.8, 0.8, 1)
totpInstr:SetText(L["TOTP_INSTRUCTION"] or "Enter the 6-digit code from your authenticator:")

local totpCountdown = totpFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
totpCountdown:SetPoint("TOP", totpInstr, "BOTTOM", 0, -4)
totpCountdown:SetTextColor(0.6, 0.6, 0.6, 1)

local totpInput = CreateFrame("EditBox", "DNRTotpInput", totpFrame, "InputBoxTemplate")
totpInput:SetSize(140, 28)
totpInput:SetPoint("TOP", totpCountdown, "BOTTOM", 0, -10)
totpInput:SetMaxLetters(6)
totpInput:SetAutoFocus(false)
totpInput:SetNumeric(true)

local totpFeedback = totpFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
totpFeedback:SetPoint("TOP", totpInput, "BOTTOM", 0, -4)
totpFeedback:SetTextColor(1, 0.2, 0.2, 1)
totpFeedback:SetText("")

local totpConfirmBtn = CreateFrame("Button", nil, totpFrame, "UIPanelButtonTemplate")
totpConfirmBtn:SetSize(140, 26)
totpConfirmBtn:SetPoint("BOTTOMLEFT", totpFrame, "BOTTOMLEFT", 14, 14)
totpConfirmBtn:SetText(L["TOTP_CONFIRM"] or "Confirm")

local totpCancelBtn = CreateFrame("Button", nil, totpFrame, "UIPanelButtonTemplate")
totpCancelBtn:SetSize(140, 26)
totpCancelBtn:SetPoint("BOTTOMRIGHT", totpFrame, "BOTTOMRIGHT", -14, 14)
totpCancelBtn:SetText(L["TOTP_CANCEL"] or "Cancel")

local totpCountdownAccum = 0
totpFrame:SetScript("OnUpdate", function(self, elapsed)
    totpCountdownAccum = totpCountdownAccum + elapsed
    if totpCountdownAccum >= 1 then
        totpCountdownAccum = 0
        if DNR_TOTP then
            totpCountdown:SetText(string.format(
                L["TOTP_REFRESH"] or "Code refreshes in %ds",
                DNR_TOTP.SecondsRemaining()
            ))
        end
    end
end)

local totpSessionActive = false

local function StopTotpInternal()
    totpSessionActive = false
    totpFrame:Hide()
    totpInput:SetText("")
    totpFeedback:SetText("")
    totpInput:ClearFocus()
end

local function FinishTotpAndShowNative()
    StopTotpInternal()
    if _origStaticPopupShow then
        _origStaticPopupShow("DEATH")
    end
end

local function AttemptTotpConfirm()
    local db = DoNotReleaseDB
    if not DNR_TOTP or not db or not db.totpSecret or db.totpSecret == "" then
        FinishTotpAndShowNative()
        return
    end
    if DNR_TOTP.Verify(db.totpSecret, strtrim(totpInput:GetText())) then
        FinishTotpAndShowNative()
    else
        totpFeedback:SetText(L["TOTP_WRONG_CODE"] or "Incorrect code — try again.")
        totpInput:SetText("")
        totpInput:SetFocus()
    end
end

totpConfirmBtn:SetScript("OnClick", AttemptTotpConfirm)
totpInput:SetScript("OnEnterPressed", AttemptTotpConfirm)
totpCancelBtn:SetScript("OnClick", FinishTotpAndShowNative)

totpFrame:SetScript("OnHide", function()
    if totpSessionActive then
        local wasActive = totpSessionActive
        totpSessionActive = false
        totpInput:SetText("")
        totpFeedback:SetText("")
        totpInput:ClearFocus()
        if wasActive and _origStaticPopupShow then
            _origStaticPopupShow("DEATH")
        end
    end
end)

local function StartTotpOverlay()
    totpSessionActive = true
    totpCountdownAccum = 0
    totpInput:SetText("")
    totpFeedback:SetText("")
    if DNR_TOTP then
        totpCountdown:SetText(string.format(
            L["TOTP_REFRESH"] or "Code refreshes in %ds",
            DNR_TOTP.SecondsRemaining()
        ))
    end
    totpFrame:Show()
    totpInput:SetFocus()
end

StaticPopup_Show = function(which, ...)
    local db = DoNotReleaseDB
    if which == "DEATH" and db then
        local guard = db.releaseGuard or "off"
        if guard == "timer" then
            StartReleaseTimerOverlay()
            return
        elseif guard == "twofactor" or guard == "code" then
            StartTwoFactorOverlay()
            return
        elseif guard == "totp" then
            if DNR_TOTP and db.totpSecret and db.totpSecret ~= "" then
                StartTotpOverlay()
                return
            else
                print(TAG() .. (L["TOTP_NO_SECRET"] or "No TOTP secret configured. Set one up in /dnr config."))
            end
        end
    end
    if _origStaticPopupShow then
        return _origStaticPopupShow(which, ...)
    end
end

local function HideGuardFrames()
    StopReleaseTimerInternal()

    tfCurrentCode = ""
    tfInput:SetText("")
    tfFeedback:SetText("")
    tfInput:ClearFocus()
    tfFrame:Hide()

    totpSessionActive = false
    totpInput:SetText("")
    totpFeedback:SetText("")
    totpInput:ClearFocus()
    totpFrame:Hide()
end

-- ── Settings canvas panel ───────────────────────────────────────────────────
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
    scrollFrame:SetPoint("TOPLEFT", outer, "TOPLEFT", 0, 0)
    scrollFrame:SetPoint("BOTTOMRIGHT", outer, "BOTTOMRIGHT", -26, 0)

    local canvas = CreateFrame("Frame", nil, scrollFrame)
    canvas:SetSize(W - 30, 1100)
    scrollFrame:SetScrollChild(canvas)

    local function place(widget, xOff, width, height)
        widget:ClearAllPoints()
        widget:SetPoint("TOPLEFT", canvas, "TOPLEFT", xOff or PAD, y)
        if width then widget:SetWidth(width) end
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
        line:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, y)
        line:SetPoint("TOPRIGHT", canvas, "TOPRIGHT", -PAD, y)
        line:SetHeight(1)
        addGap(14)
    end

    local function fline(text, indent)
        local fs = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD + (indent or 0), y)
        fs:SetTextColor(0.72, 0.72, 0.72, 1)
        fs:SetText(text)
        addGap(18)
    end

    local HALF_W = _floor((W - PAD * 2 - 8) / 2)

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
        local row = _floor((i - 1) / 2)
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
            print(TAG() .. (L["CONFIG_SAVED"] or "Settings saved."))
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

    -- Font
    sectionHeader("CONFIG_FONT_TITLE", "Font")

    for i, preset in ipairs(FONT_PRESETS) do
        local col = (i - 1) % 2
        local row = _floor((i - 1) / 2)
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
            print(TAG() .. (L["CONFIG_SAVED"] or "Settings saved."))
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
        { key = "CONFIG_GUARD_OFF",       mode = "off",  label = "Off" },
        { key = "CONFIG_GUARD_TIMER",     mode = "timer", label = "Timer (" .. RELEASE_TIMER_SECS .. "s)" },
        { key = "CONFIG_GUARD_CODE",      mode = "code", label = "Random Code" },
        { key = "CONFIG_GUARD_TOTP",      mode = "totp", label = "Two-Factor" },
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
        local col = (i - 1) % 2
        local row = _floor((i - 1) / 2)
        local gb = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
        gb:SetSize(HALF_W, BTN_H)
        gb:SetPoint("TOPLEFT", canvas, "TOPLEFT",
            PAD + col * (HALF_W + 8),
            y - row * (BTN_H + 4))
        gb:SetText(L[gm.key] or gm.label)
        table.insert(guardBtns, { btn = gb, mode = gm.mode, key = gm.key, label = gm.label })

        local modeVal = gm.mode
        gb:SetScript("OnClick", function()
            if not DoNotReleaseDB then return end
            DoNotReleaseDB.releaseGuard = modeVal
            refreshGuardButtons()
            if modeVal == "off" then HideGuardFrames() end
            print(TAG() .. (L["CONFIG_SAVED"] or "Settings saved."))
        end)
    end
    addGap(2 * (BTN_H + 4) + 18)
    divider()

    -- TOTP Authenticator Setup
    sectionHeader("CONFIG_TOTP_TITLE", "TOTP Authenticator Setup")

    local totpDescLabel = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    totpDescLabel:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, y)
    totpDescLabel:SetWidth(W - PAD * 2)
    totpDescLabel:SetJustifyH("LEFT")
    totpDescLabel:SetTextColor(0.72, 0.72, 0.72, 1)
    totpDescLabel:SetText(L["CONFIG_TOTP_DESC"]
        or "Pair with Google Authenticator, Authy, or any TOTP app. Choose \"Enter setup key\" in your app.")
    addGap(40)

    local totpKeyLabel = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    totpKeyLabel:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, y)
    totpKeyLabel:SetTextColor(0.72, 0.72, 0.72, 1)
    totpKeyLabel:SetText(L["CONFIG_TOTP_SECRET_LABEL"] or "Your secret key (keep this private!):")
    addGap(18)

    local totpKeyDisplay = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    totpKeyDisplay:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD + 4, y)
    totpKeyDisplay:SetFont("Fonts\\FRIZQT__.TTF", 15, "OUTLINE")
    totpKeyDisplay:SetTextColor(1, 0.82, 0.0, 1)
    totpKeyDisplay:SetText(L["CONFIG_TOTP_NO_SECRET"] or "(none - click Generate below)")

    local totpRevealBtn = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
    totpRevealBtn:SetSize(80, BTN_H)
    totpRevealBtn:SetPoint("LEFT", totpKeyDisplay, "RIGHT", 10, 0)
    totpRevealBtn:SetText(L["CONFIG_TOTP_REVEAL"] or "Reveal")

    local secretVisible = false
    addGap(24)

    local s1 = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    s1:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, y)
    s1:SetTextColor(0.72, 0.72, 0.72, 1)
    s1:SetText(L["CONFIG_TOTP_STEP1"] or "1. Open your authenticator app → Add account → Enter a setup key")
    addGap(16)

    local s2 = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    s2:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, y)
    s2:SetTextColor(0.72, 0.72, 0.72, 1)
    s2:SetText(L["CONFIG_TOTP_STEP2"] or "2. Account: DoNotRelease, Key type: Time-based")
    addGap(16)

    local s3 = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    s3:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, y)
    s3:SetTextColor(0.72, 0.72, 0.72, 1)
    s3:SetText(L["CONFIG_TOTP_STEP3"] or "3. Copy the secret key above into the app, then verify below:")
    addGap(22)

    local totpVerifyInput = CreateFrame("EditBox", "DNRTotpVerifyInput", canvas, "InputBoxTemplate")
    totpVerifyInput:SetSize(100, BTN_H)
    totpVerifyInput:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD + 6, y)
    totpVerifyInput:SetMaxLetters(6)
    totpVerifyInput:SetAutoFocus(false)
    totpVerifyInput:SetNumeric(true)

    local totpVerifyBtn = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
    totpVerifyBtn:SetSize(110, BTN_H)
    totpVerifyBtn:SetPoint("LEFT", totpVerifyInput, "RIGHT", 8, 0)
    totpVerifyBtn:SetText(L["CONFIG_TOTP_VERIFY_BTN"] or "Test Code")

    local totpStatus = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    totpStatus:SetPoint("LEFT", totpVerifyBtn, "RIGHT", 10, 0)
    totpStatus:SetText("")
    addGap(BTN_H + 14)

    local totpGenBtn = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
    totpGenBtn:SetSize(HALF_W, BTN_H)
    totpGenBtn:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, y)
    totpGenBtn:SetText(L["CONFIG_TOTP_GENERATE"] or "Generate New Secret")
    addGap(BTN_H + 6)

    local totpWarnFs = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    totpWarnFs:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, y)
    totpWarnFs:SetWidth(W - PAD * 2)
    totpWarnFs:SetJustifyH("LEFT")
    totpWarnFs:SetTextColor(1, 0.55, 0.1, 1)
    totpWarnFs:SetText(L["CONFIG_TOTP_REGEN_WARN"]
        or "(!) Regenerating invalidates any existing authenticator pairing.")
    addGap(28)
    divider()

    -- Footer
    fline("|cFFFFD700DoNotRelease:|r |cFF4DA6FF[SeemsGood/DNR]|r - "
        .. (L["FOOTER_BUGS"] or "Report bugs on GitHub."))
    addGap(4)
    fline("|cFFFFD700" .. (L["FOOTER_OTHER_ADDONS"] or "Other Addons") .. "|r")
    fline("|cFFFFD700AccountPlayed:|r Playtime by Class - |cFF4DA6FF[Jeremy-Gstein/AccountPlayed]|r", 8)
    fline("|cFFFFD700AccountRepaired:|r Repair Cost Statistics - |cFF4DA6FF[Seems-Good/AccountRepaired]|r", 8)
    fline("|cFFFFD700DjLust:|r Bloodlust Music+Animations - |cFF4DA6FF[Jeremy-Gstein/DjLust]|r", 8)
    fline("|cFFFFD700ShodoQoL:|r Evoker QoL Settings/Macros - |cFF4DA6FF[Seems-Good/shodoqol]|r", 8)
    addGap(4)
    fline(L["FOOTER_SUPPORT"] or "Like these projects? Share feedback or donate <3")
    fline("|cFFFF6644Ko-fi:|r |cFF4DA6FFko-fi.com/j51b5|r"
        .. " |cFFFF6644Web:|r |cFF4DA6FFhttps://seemsgood.org|r"
        .. " |cFFFF6644Email:|r |cFF4DA6FFjeremy51b5@pm.me|r")
    addGap(10)

    -- TOTP callbacks
    local function getFormattedSecret()
        local db = DoNotReleaseDB
        if not db or not db.totpSecret or db.totpSecret == "" then
            return nil
        end
        if DNR_TOTP then
            return DNR_TOTP.FormatSecret(db.totpSecret)
        end
        return db.totpSecret
    end

    local function refreshTotpSection()
        local db = DoNotReleaseDB
        if not db then return end

        if db.totpSecret and db.totpSecret ~= "" then
            if secretVisible then
                totpKeyDisplay:SetText(getFormattedSecret())
                totpRevealBtn:SetText(L["CONFIG_TOTP_HIDE"] or "Hide")
            else
                local fmt = getFormattedSecret() or ""
                totpKeyDisplay:SetText((fmt:gsub("%S", "*")))
                totpRevealBtn:SetText(L["CONFIG_TOTP_REVEAL"] or "Reveal")
            end
            totpGenBtn:SetText(L["CONFIG_TOTP_REGENERATE"] or "Regenerate Secret")
        else
            totpKeyDisplay:SetText(L["CONFIG_TOTP_NO_SECRET"] or "(none - click Generate below)")
            totpRevealBtn:SetText(L["CONFIG_TOTP_REVEAL"] or "Reveal")
            totpGenBtn:SetText(L["CONFIG_TOTP_GENERATE"] or "Generate New Secret")
        end

        totpStatus:SetText("")
        totpVerifyInput:SetText("")
    end

    totpRevealBtn:SetScript("OnClick", function()
        secretVisible = not secretVisible
        refreshTotpSection()
    end)

    totpGenBtn:SetScript("OnClick", function()
        local db = DoNotReleaseDB
        if not db or not DNR_TOTP then return end
        db.totpSecret = DNR_TOTP.GenerateSecret(16)
        secretVisible = false
        refreshTotpSection()
        print(TAG() .. "New TOTP secret generated.")
    end)

    local function doVerify()
        local db = DoNotReleaseDB
        if not DNR_TOTP or not db or not db.totpSecret or db.totpSecret == "" then
            totpStatus:SetTextColor(1, 0.2, 0.2, 1)
            totpStatus:SetText(L["CONFIG_TOTP_NO_SECRET_ERR"] or "Generate a secret first.")
            return
        end

        local input = strtrim(totpVerifyInput:GetText())
        if DNR_TOTP.Verify(db.totpSecret, input) then
            totpStatus:SetTextColor(0.2, 1, 0.2, 1)
            totpStatus:SetText(L["CONFIG_TOTP_VERIFY_OK"] or "Code verified!")
            totpVerifyInput:SetText("")
        else
            totpStatus:SetTextColor(1, 0.2, 0.2, 1)
            totpStatus:SetText(L["CONFIG_TOTP_VERIFY_FAIL"] or "Wrong code. Check time sync.")
            totpVerifyInput:SetText("")
        end
    end

    totpVerifyBtn:SetScript("OnClick", doVerify)
    totpVerifyInput:SetScript("OnEnterPressed", function(self)
        doVerify()
        self:ClearFocus()
    end)

    outer:SetScript("OnShow", function()
        local db = DoNotReleaseDB
        if not db then return end
        editBox:SetText(label:GetText() or DB_DEFAULTS.warningText)
        updateCounter()
        local sz = db.fontSize or DB_DEFAULTS.fontSize
        lastSliderSize = sz
        sizeSlider:SetValue(sz)
        refreshSizeLabel(sz)
        refreshGuardButtons()
        refreshTotpSection()
    end)

    if SettingsPanel then
        SettingsPanel:HookScript("OnHide", function()
            DisableDNRDrag()
            if not ShouldWarn() then
                HideWarning()
            end
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
        print(TAG() .. (L["CONFIG_DRAG_INLINE_MSG"] or "Drag the warning text, then release to save."))
    end)

    resetBtn:SetScript("OnClick", function()
        if not DoNotReleaseDB then return end
        DoNotReleaseDB.posX = DB_DEFAULTS.posX
        DoNotReleaseDB.posY = DB_DEFAULTS.posY
        ApplySavedPosition()
        print(TAG() .. (L["CONFIG_POS_RESET_MSG"] or "Position reset to default."))
    end)

    setBtn:SetScript("OnClick", function()
        if not DoNotReleaseDB then return end
        local raw = strtrim(editBox:GetText())
        DoNotReleaseDB.warningText = raw
        label:SetText(raw)
        ApplySavedFont()
        editBox:ClearFocus()
        print(TAG() .. (L["CONFIG_SAVED"] or "Settings saved."))
    end)

    resetTextBtn:SetScript("OnClick", function()
        if not DoNotReleaseDB then return end
        DoNotReleaseDB.warningText = DB_DEFAULTS.warningText
        label:SetText(DB_DEFAULTS.warningText)
        ApplySavedFont()
        editBox:SetText(label:GetText() or DB_DEFAULTS.warningText)
        updateCounter()
        print(TAG() .. (L["CONFIG_TEXT_RESET_MSG"] or "Warning text reset to default."))
    end)

    return outer
end

local function RegisterSettingsPanel()
    if not (Settings and Settings.RegisterCanvasLayoutCategory) then
        print(TAG() .. (L["CONFIG_API_UNAVAILABLE"] or "Settings API unavailable on this client version."))
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
        print(TAG() .. (L["CONFIG_API_UNAVAILABLE"] or "Settings API unavailable on this client version."))
    end
end

-- ── Event Handling ───────────────────────────────────────────────────────────
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
        if DoNotReleaseDB.releaseGuard == "twofactor" then
            DoNotReleaseDB.releaseGuard = "code"
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

-- ── Slash Commands ───────────────────────────────────────────────────────────
SLASH_DONOTRELEASE1 = "/dnr"
SlashCmdList["DONOTRELEASE"] = function(msg)
    local cmd = strtrim(msg):lower()
    if cmd == "test" then
        previewMode = true
        DNR:Show()
        print(TAG() .. (L["SLASH_TEST_MSG"] or "Test mode - warning shown."))
        C_Timer.After(TEST_DURATION, function()
            if not ShouldWarn() then HideWarning() end
        end)
    elseif cmd == "hide" then
        HideWarning()
        print(TAG() .. (L["SLASH_HIDE_MSG"] or "Warning hidden."))
    elseif cmd == "config" then
        OpenConfig()
    else
        print("|cFFFF4444" .. (L["PRETTY_ADDON_TAG"] or "DoNotRelease") .. "|r - |cFFFFD700"
            .. (L["SLASH_HELP"] or "/dnr test | /dnr hide | /dnr config") .. "|r")
    end
end
