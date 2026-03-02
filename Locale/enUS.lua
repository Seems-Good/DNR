-- ============================================================
--  DoNotRelease – Locale: enUS
--  All user-facing strings for the English (US) client.
--  To add a new locale, copy this file, rename it (e.g. deDE.lua),
--  and replace the right-hand values with translated text.
-- ============================================================
local locale = GetLocale()
if locale ~= "enUS" and locale ~= "enGB" then return end

DoNotReleaseL = DoNotReleaseL or {}
local L = DoNotReleaseL

-- ── Warning overlay ──────────────────────────────────────────
L["WARNING_TEXT"]               = "PLEASE DO NOT RELEASE"

-- ── Addon tag (used in print() prefix) ──────────────────────
L["ADDON_TAG"]                  = "DoNotRelease"

-- ── Slash-command feedback ───────────────────────────────────
L["SLASH_HELP"]                 = "/dnr test  |  /dnr hide  |  /dnr config"
L["SLASH_TEST_MSG"]             = "Test mode \226\128\148 warning shown."
L["SLASH_HIDE_MSG"]             = "Warning hidden."

-- ── Config panel ─────────────────────────────────────────────
L["CONFIG_TITLE"]               = "DoNotRelease Config"
L["CONFIG_DRAG_HINT"]           = "Drag to reposition"
L["CONFIG_COLOR_TITLE"]         = "Warning Color"
L["CONFIG_CLOSE"]               = "Close"
L["CONFIG_RESET_POS"]           = "Reset Position"
L["CONFIG_SAVED"]               = "Settings saved."
L["CONFIG_POS_RESET_MSG"]       = "Position reset to default."
L["COLOR_RED"]                  = "Red (default)"
L["COLOR_ORANGE"]               = "Orange"
L["COLOR_YELLOW"]               = "Yellow"
L["COLOR_WHITE"]                = "White"
L["COLOR_CYAN"]                 = "Cyan"
