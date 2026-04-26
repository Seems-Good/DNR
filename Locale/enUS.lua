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
local VERSION = "v1.3.0"

-- ── Warning overlay ───────────────────────────────────────────────────────────
L["WARNING_TEXT"]               = "PLEASE DO NOT RELEASE"

-- ── Addon tag (used in print() prefix) ───────────────────────────────────────
L["ADDON_TAG"]                  = "DoNotRelease"
L["PRETTY_ADDON_TAG"]           = "DoNotRelease-(" .. VERSION .. ")"

-- ── Slash-command feedback ────────────────────────────────────────────────────
L["SLASH_HELP"]                 = "/dnr test  |  /dnr hide  |  /dnr config"
L["SLASH_TEST_MSG"]             = "Test mode \226\128\148 warning shown."
L["SLASH_HIDE_MSG"]             = "Warning hidden."

-- ── Config panel — general ────────────────────────────────────────────────────
L["CONFIG_TITLE"]               = "DoNotRelease Config"
L["CONFIG_CLOSE"]               = "Close"
L["CONFIG_SAVED"]               = "Settings saved."
L["CONFIG_DB_NOT_READY"]        = "DB not ready \226\128\148 make sure DoNotReleaseDB is in your .toc SavedVariables."

-- ── Config panel — position section ──────────────────────────────────────────
L["CONFIG_POS_SECTION"]         = "Position"
L["CONFIG_DRAG_HINT"]           = "Drag to reposition"
L["CONFIG_DRAG_INLINE_MSG"]     = "Drag the warning text, then release to save."
L["CONFIG_RESET_POS"]           = "Reset Position"
L["CONFIG_POS_RESET_MSG"]       = "Position reset to default."
L["CONFIG_SHOW_WARNING"]        = "Show Warning"
L["CONFIG_HIDE_WARNING"]        = "Hide Warning"

-- ── Config panel — color section ─────────────────────────────────────────────
L["CONFIG_COLOR_TITLE"]         = "Warning Color"
L["COLOR_RED"]                  = "Red (default)"
L["COLOR_ORANGE"]               = "Orange"
L["COLOR_YELLOW"]               = "Yellow"
L["COLOR_GREEN"]                = "Green"
L["COLOR_WHITE"]                = "White"
L["COLOR_CYAN"]                 = "Cyan"

-- ── Config panel — warning text section ──────────────────────────────────────
L["CONFIG_TEXT_TITLE"]          = "Warning Text"
L["CONFIG_TEXT_SET"]            = "Set"
L["CONFIG_TEXT_RESET"]          = "Reset Text"
L["CONFIG_TEXT_RESET_MSG"]      = "Warning text reset to default."
L["CONFIG_TEXT_EMPTY_ERR"]      = "Text cannot be empty."

-- ── Config panel — font size section ─────────────────────────────────────────
L["CONFIG_SIZE_TITLE"]          = "Font Size"

-- ── Config panel — font face section ─────────────────────────────────────────
L["CONFIG_FONT_TITLE"]          = "Font"
L["FONT_DEFAULT"]               = "Default"
L["FONT_CLEAN"]                 = "Clean"
L["FONT_FANCY"]                 = "Fancy"
L["FONT_RUNIC"]                 = "Runic"

-- ── Fallback (pre-Dragonflight clients without Settings API) ──────────────────
L["CONFIG_API_UNAVAILABLE"]     = "Settings API unavailable on this client version."

-- ── Footer ────────────────────────────────────────────────────────────────────
L["FOOTER_BUGS"]                = "Report bugs on GitHub."
L["FOOTER_OTHER_ADDONS"]        = "Other Addons"
L["FOOTER_SUPPORT"]             = "Like these projects? Share feedback or donate <3"
