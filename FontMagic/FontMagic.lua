-- FontMagic.lua
local addonName = ...

-- safe loader: C_AddOns.LoadAddOn (Retail ≥11.0.2) or legacy LoadAddOn
local safeLoadAddOn
if type(C_AddOns) == "table" and type(C_AddOns.LoadAddOn) == "function" then
    safeLoadAddOn = C_AddOns.LoadAddOn
elseif type(LoadAddOn) == "function" then
    safeLoadAddOn = LoadAddOn
else
    safeLoadAddOn = function() end
end
local ADDON_PATH = "Interface\\AddOns\\" .. addonName .. "\\"
-- Name of the optional addon supplying user fonts
local CUSTOM_ADDON = "FontMagicCustomFonts"
-- Default path for custom fonts shipped by the companion addon
local CUSTOM_PATH  = "Interface\\AddOns\\" .. CUSTOM_ADDON .. "\\Custom\\"

-- Try to load the companion addon so its global table becomes available
pcall(safeLoadAddOn, CUSTOM_ADDON)
-- If loaded, prefer its reported path in case the folder was moved/renamed
if type(FontMagicCustomFonts) == "table" and type(FontMagicCustomFonts.PATH) == "string" then
    CUSTOM_PATH = FontMagicCustomFonts.PATH
end
-- detect whether the BackdropTemplate mixin exists (Retail only)
local backdropTemplate = (BackdropTemplateMixin and "BackdropTemplate") or nil

-- String helpers ------------------------------------------------------------
local function __fmTrim(s)
    if type(s) ~= "string" then return "" end
    return (s:match("^%s*(.-)%s*$")) or s
end

local function __fmStripFontExt(fname)
    if type(fname) ~= "string" then return "" end
    local base = fname
    base = base:gsub("%.[Tt][Tt][Ff]$", ""):gsub("%.[Oo][Tt][Ff]$", ""):gsub("%.[Tt][Tt][Cc]$", "")
    base = base:gsub("%s+$", "")
    return base
end

-- Make font labels shorter by removing common style/weight suffixes like Bold/Italic/etc.
-- This only affects what users SEE in dropdowns; the underlying font file selection remains unchanged.
local __fmSTYLE_TOKENS = {
    ["regular"] = true, ["normal"] = true, ["book"] = true, ["roman"] = true,
    ["medium"] = true, ["semibold"] = true, ["demibold"] = true, ["demi"] = true, ["semi"] = true,
    ["bold"] = true, ["extrabold"] = true, ["ultrabold"] = true, ["extra"] = true, ["ultra"] = true,
    ["black"] = true, ["heavy"] = true,
    ["light"] = true, ["thin"] = true, ["hairline"] = true,
    ["italic"] = true, ["oblique"] = true,
    ["condensed"] = true, ["narrow"] = true, ["compressed"] = true,
    ["expanded"] = true, ["extended"] = true,
    ["outline"] = true,
}

local function __fmShortenFontLabel(label)
    if type(label) ~= "string" or label == "" then return "" end

    local s = label

    -- Strip extension if someone passed a filename by mistake
    s = s:gsub("%.[Tt][Tt][Ff]$", ""):gsub("%.[Oo][Tt][Ff]$", ""):gsub("%.[Tt][Tt][Cc]$", "")

    -- Normalize separators
    s = s:gsub("[_%-]+", " ")

    -- Add spaces for common CamelCase boundaries (e.g. CalibriBold -> Calibri Bold)
    s = s:gsub("([%l])([%u])", "%1 %2")
    s = s:gsub("([%a])(%d)", "%1 %2")
    s = s:gsub("(%d)([%a])", "%1 %2")

    -- Treat parentheses as plain separators (e.g. "Roboto (Bold)" -> "Roboto  Bold")
    s = s:gsub("[%(%)]", " ")

    -- Collapse whitespace
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

    -- Tokenize and remove trailing style tokens
    local tokens = {}
    for w in s:gmatch("%S+") do
        tokens[#tokens + 1] = w
    end

    local function isStyleToken(tok)
        if not tok then return false end
        local t = tok:lower():gsub("[^%w]+", "")
        if t == "" then return true end
        if __fmSTYLE_TOKENS[t] then return true end
        if t:match("^%d+$") then return true end
        return false
    end

    while #tokens > 0 and isStyleToken(tokens[#tokens]) do
        table.remove(tokens)
    end

    local out = table.concat(tokens, " ")
    if out == "" then
        -- If we stripped everything somehow, fall back to the normalized label
        out = s
    end
    return out
end


local function GetCVarInfoCompat(name)
    -- WoW has shipped multiple shapes for GetCVarInfo over the years:
    --  1) multiple return values (value, defaultValue, ...)
    --  2) a single info table with fields like .value and .defaultValue
    -- This normalizes both into (value, defaultValue, ...)
    if type(C_CVar) == "table" and type(C_CVar.GetCVarInfo) == "function" then
        local a, b, c, d, e, f, g = C_CVar.GetCVarInfo(name)
        if type(a) == "table" then
            return a.value, a.defaultValue, a.isStoredServerAccount, a.isStoredServerCharacter, a.isLockedFromUser, a.isSecure, a.isReadOnly
        end
        return a, b, c, d, e, f, g
    end
    if type(GetCVarInfo) == "function" then
        local a, b, c, d, e, f, g = GetCVarInfo(name)
        return a, b, c, d, e, f, g
    end
    return nil
end

local function GetCVarString(cvar)
    -- Prefer GetCVarInfo so we can fall back to the default value when the
    -- current value hasn't been initialized/synced yet (common with server-stored CVars).
    local value, defaultValue = GetCVarInfoCompat(cvar)
    if value ~= nil then
        return value
    end
    if defaultValue ~= nil then
        return defaultValue
    end

    if type(C_CVar) == "table" and type(C_CVar.GetCVar) == "function" then
        local ok, v = pcall(C_CVar.GetCVar, cvar)
        if ok and v ~= nil then
            return v
        end
    end

    if type(GetCVar) == "function" then
        local ok, v = pcall(GetCVar, cvar)
        if ok and v ~= nil then
            return v
        end
    end

    if type(C_CVar) == "table" and type(C_CVar.GetCVarDefault) == "function" then
        local ok, def = pcall(C_CVar.GetCVarDefault, cvar)
        if ok and def ~= nil then
            return def
        end
    end

    if type(GetCVarDefault) == "function" then
        local ok, def = pcall(GetCVarDefault, cvar)
        if ok and def ~= nil then
            return def
        end
    end

    return nil
end

local function DoesCVarExist(cvar)
    local value, defaultValue = GetCVarInfoCompat(cvar)
    if value ~= nil or defaultValue ~= nil then
        return true
    end

    if type(C_CVar) == "table" and type(C_CVar.GetCVarDefault) == "function" then
        local ok, def = pcall(C_CVar.GetCVarDefault, cvar)
        if ok and def ~= nil then
            return true
        end
    end

    if type(GetCVarDefault) == "function" then
        local ok, def = pcall(GetCVarDefault, cvar)
        if ok and def ~= nil then
            return true
        end
    end

    if type(C_CVar) == "table" and type(C_CVar.GetCVar) == "function" then
        local ok, v = pcall(C_CVar.GetCVar, cvar)
        if ok and v ~= nil then
            return true
        end
    end

    if type(GetCVar) == "function" then
        local ok, v = pcall(GetCVar, cvar)
        if ok and v ~= nil then
            return true
        end
    end

    return false
end

-- Console command / CVar resolution ------------------------------------------
-- In some Retail builds (notably late 12.0 hotfixes), a number of Floating Combat
-- Text settings appear as renamed CVars (often with a _v2 suffix) and/or as
-- console commands. To keep FontMagic working across Retail + Classic-era
-- clients, we resolve by consulting the console command list when available,
-- and fall back to traditional CVar queries otherwise.

local _consoleCommandIndex = nil  -- [commandName] = commandType (0 == CVar)
local _consoleCommandMeta = nil   -- [commandName] = { commandType = number|nil, minValue = number|nil, maxValue = number|nil }

local function BuildConsoleCommandIndex()
    if _consoleCommandIndex then
        return _consoleCommandIndex
    end

    _consoleCommandIndex = {}
    _consoleCommandMeta = {}

    local getAll = nil
    if type(C_Console) == "table" and type(C_Console.GetAllCommands) == "function" then
        getAll = C_Console.GetAllCommands
    elseif type(ConsoleGetAllCommands) == "function" then
        getAll = ConsoleGetAllCommands
    end

    if getAll then
        local ok, list = pcall(getAll)
        if ok and type(list) == "table" then
            for _, info in ipairs(list) do
                if type(info) == "table" then
                    local name = info.command or info.name
                    local ct = info.commandType
                    if type(name) == "string" then
                        _consoleCommandIndex[name] = ct
                        _consoleCommandMeta[name] = {
                            commandType = ct,
                            minValue = tonumber(info.minValue),
                            maxValue = tonumber(info.maxValue),
                        }
                    end
                elseif type(info) == "string" then
                    -- Very old clients sometimes return names only; assume CVar.
                    _consoleCommandIndex[info] = 0
                    _consoleCommandMeta[info] = {
                        commandType = 0,
                        minValue = nil,
                        maxValue = nil,
                    }
                end
            end
        end
    end

    return _consoleCommandIndex
end

local function RefreshConsoleCommandIndex()
    _consoleCommandIndex = nil
    _consoleCommandMeta = nil
    return BuildConsoleCommandIndex()
end

local function FindBestConsoleMatch(base)
    local idx = BuildConsoleCommandIndex()
    if type(idx) ~= "table" then return nil, nil end
    if type(base) ~= "string" or base == "" then return nil, nil end

    local lbase = base:lower()
    local bestName, bestType, bestScore = nil, nil, nil

    for name, ct in pairs(idx) do
        if type(name) == "string" then
            local lname = name:lower()
            if lname == lbase then
                return name, ct
            end

            local score = nil
            if lname:sub(1, #lbase) == lbase then
                -- strong match if it starts with the base
                score = 1000 - (#name - #base)
            else
                local pos = lname:find(lbase, 1, true)
                if pos then
                    -- weaker match if it merely contains the base
                    score = 500 - (#name - #base) - (pos - 1)
                end
            end

            if score and (bestScore == nil or score > bestScore) then
                bestScore = score
                bestName = name
                bestType = ct
            end
        end
    end

    return bestName, bestType
end

local function ResolveConsoleSetting(cvarOrCandidates)
    -- Returns: (name, commandType) where commandType is from Enum.ConsoleCommandType
    -- (0 == CVar). For older clients without an index, commandType will be 0 when
    -- a CVar exists and nil otherwise.
    local idx = BuildConsoleCommandIndex()

    local function tryName(name)
        if type(name) ~= "string" then return nil, nil end

        -- Prefer console index when available (covers renamed CVars and non-CVar commands)
        -- Prefer console index when available, but if the CVar API can see the name,
-- treat it as a CVar. The console list can misclassify real CVars as non-CVar commands.
        if idx and idx[name] ~= nil then
            if DoesCVarExist(name) then
                return name, 0
            end
            return name, idx[name]
        end

        -- Fallback: treat as CVar if the CVar API can see it.
        if DoesCVarExist(name) then
            return name, 0
        end

        return nil, nil
    end

    local function tryFuzzy(name)
        if type(name) ~= "string" or name == "" then return nil, nil end
        local base = name:gsub("_[vV]%d+$", "")
        local bestName, bestCt = FindBestConsoleMatch(base)
        if bestName then
            return tryName(bestName)
        end
        return nil, nil
    end

    if type(cvarOrCandidates) == "string" then
        local n, ct = tryName(cvarOrCandidates)
        if n then return n, ct end

        local base = cvarOrCandidates:gsub("_[vV]%d+$", "")
        local variants = {
            cvarOrCandidates .. "_v2",
            cvarOrCandidates .. "_V2",
            cvarOrCandidates .. "_v3",
            cvarOrCandidates .. "_V3",
        }

        if base ~= cvarOrCandidates then
            table.insert(variants, base)
            table.insert(variants, base .. "_v2")
            table.insert(variants, base .. "_V2")
            table.insert(variants, base .. "_v3")
            table.insert(variants, base .. "_V3")
        end

        for _, v in ipairs(variants) do
            n, ct = tryName(v)
            if n then return n, ct end
        end

        n, ct = tryFuzzy(cvarOrCandidates)
        if n then return n, ct end

        for _, v in ipairs(variants) do
            n, ct = tryFuzzy(v)
            if n then return n, ct end
        end

        return nil, nil
    end

    if type(cvarOrCandidates) == "table" then
        for _, candidate in ipairs(cvarOrCandidates) do
            local n, ct = tryName(candidate)
            if n then return n, ct end
        end

        for _, candidate in ipairs(cvarOrCandidates) do
            local n, ct = tryFuzzy(candidate)
            if n then return n, ct end
        end
    end

    return nil, nil
end

local function ResolveConsoleSettingTargets(cvarOrCandidates)
    -- Returns a de-duplicated list of settings that can be written for a feature.
    -- This helps across client builds that expose both legacy and v2 names.
    local out, seen = {}, {}

    local function addResolved(name, commandType)
        if type(name) ~= "string" or name == "" then return end
        local key = name .. "#" .. tostring(commandType or "nil")
        if seen[key] then return end
        seen[key] = true
        out[#out + 1] = { name = name, commandType = commandType }
    end

    local function addFrom(candidate)
        local n, ct = ResolveConsoleSetting(candidate)
        if n then
            addResolved(n, ct)
        end
    end

    if type(cvarOrCandidates) == "string" then
        addFrom(cvarOrCandidates)
        local base = cvarOrCandidates:gsub("_[vV]%d+$", "")
        if base ~= cvarOrCandidates then
            addFrom(base)
        else
            addFrom(base .. "_v2")
            addFrom(base .. "_V2")
            addFrom(base .. "_v3")
            addFrom(base .. "_V3")
        end
    elseif type(cvarOrCandidates) == "table" then
        for _, candidate in ipairs(cvarOrCandidates) do
            addFrom(candidate)
        end
    end

    return out
end

local SetCVarString -- forward declaration (used before definition)
local function ApplyConsoleSetting(name, commandType, value)
    if not name then return end
    value = tostring(value)

    if commandType == nil or commandType == 0 then
        -- CVar
        SetCVarString(name, value)
        return
    end

    -- Console command/script (ConsoleExec is /console)
    if type(ConsoleExec) == "function" then
        pcall(ConsoleExec, name .. " " .. value, false)
    end
end

local function ResolveCVarName(cvarOrCandidates)
    -- Backwards-compatible wrapper: returns the resolved name (CVar OR console command),
    -- or nil if nothing appropriate can be found on this client.
    local n = ResolveConsoleSetting(cvarOrCandidates)
    return n
end

local function GetResolvedSettingNumber(candidates, fallback)
    local n = ResolveCVarName(candidates)
    if not n then return fallback end
    local v = tonumber(GetCVarString(n))
    if v == nil then return fallback end
    return v
end


SetCVarString = function(cvar, value)
    if type(C_CVar) == "table" and type(C_CVar.SetCVar) == "function" then
        pcall(C_CVar.SetCVar, cvar, value)
        return
    end
    if type(SetCVar) == "function" then
        pcall(SetCVar, cvar, value)
    end
end

--[[
    ---------------------------------------------------------------------------
    Compatibility shim for Dragonflight/Midnight settings API (patch ≥10.0.0).

    Starting in Dragonflight (10.0) and continuing through the Midnight 12.0
    pre‑patch, Blizzard removed the old Interface Options panel APIs such as
    InterfaceOptions_AddCategory.  Addons must now register their option
    panels using the new Settings API.  To maintain backwards compatibility
    with older clients and automatically support retail 12.0, we define
    InterfaceOptions_AddCategory when it is missing.  The implementation
    mirrors an example from the official forums: when the function does not
    exist we construct a canvas layout category via Settings.RegisterCanvasLayoutCategory
    and register it using Settings.RegisterAddOnCategory.

    This wrapper returns the newly created category object so callers can
    inspect or store it if desired.  On older clients where the original
    InterfaceOptions_AddCategory exists, we simply call through.
    ---------------------------------------------------------------------------
--]]
do
    local originalAddCategory = InterfaceOptions_AddCategory
    if originalAddCategory == nil and type(Settings) == "table" then
        local hasCanvasCategory = type(Settings.RegisterCanvasLayoutCategory) == "function"
        local hasAddOnCategory = type(Settings.RegisterAddOnCategory) == "function"
        local hasGetCategory = type(Settings.GetCategory) == "function"
        local hasSubcategory = type(Settings.RegisterCanvasLayoutSubcategory) == "function"

        -- Define a shim for InterfaceOptions_AddCategory using the Settings API
        InterfaceOptions_AddCategory = function(frame)
            -- Respect missing frame inputs
            if not frame then return end

            -- Some clients expose a partial Settings table. If required methods are
            -- absent, fail safely rather than throwing an error during panel registration.
            if not hasCanvasCategory then
                return nil
            end

            local panelName = tostring(frame.name or addonName or "FontMagic")

            -- If this panel has a parent, register it as a sub‑category of
            -- the parent's settings entry.  Otherwise register a top‑level
            -- category.  The new API requires us to supply both a name and
            -- display name; we use frame.name for both as per the forums example
            --.
            local category, parentCategory
            if frame.parent and hasGetCategory and hasSubcategory then
                parentCategory = Settings.GetCategory(frame.parent)
                if parentCategory then
                    local subcategory = select(1, Settings.RegisterCanvasLayoutSubcategory(parentCategory, frame, panelName, panelName))
                    if not subcategory then return nil end
                    subcategory.ID = panelName
                    return subcategory
                end
            end
            -- Register a top‑level category.  RegisterAddOnCategory makes it
            -- appear in the "AddOns" section of the Settings panel
            category = select(1, Settings.RegisterCanvasLayoutCategory(frame, panelName, panelName))
            if category then
                category.ID = panelName
                if hasAddOnCategory then
                    Settings.RegisterAddOnCategory(category)
                end
            end
            return category
        end
    end
end
--[[
  ---------------------------------------------------------------------------
    Font Detection
    Instead of checking for numbered fonts like 1.ttf, 2.ttf, etc. we now look
    for actual font files organised into folders. Each folder corresponds to a
    themed group of fonts. The table below lists the relative font file names
    shipped with the addon. Detection is performed at load time so missing
    files are ignored gracefully.
  ---------------------------------------------------------------------------
--]]

-- SavedDB defaults
local FM_DB_SCHEMA_VERSION = 2

local FM_MINIMAP_RADIUS_OFFSET_DEFAULT = 10
local FM_MINIMAP_RADIUS_OFFSET_MIN = -4
local FM_MINIMAP_RADIUS_OFFSET_MAX = 28

local function ClampNumber(v, minV, maxV)
    if type(v) ~= "number" then return minV end
    if v < minV then return minV end
    if v > maxV then return maxV end
    return v
end

local function NormalizeAngleDegrees(v)
    local n = tonumber(v) or 0
    n = n % 360
    if n < 0 then n = n + 360 end
    return n
end

if type(FontMagicDB) ~= "table" then
    -- Default placement for the minimap button is the bottom-left corner
    -- (approximately 225 degrees around the minimap).  This avoids the
    -- initial position being hidden beneath default UI elements on a fresh
    -- installation, particularly in WoW Classic.
    FontMagicDB = {
        minimapAngle = 225,
        minimapHide = false,
        minimapRadiusOffset = FM_MINIMAP_RADIUS_OFFSET_DEFAULT,
    }
elseif FontMagicDB.minimapAngle == nil then
    -- In case a previous version created the DB without this key, ensure a
    -- sensible default.
    FontMagicDB.minimapAngle = 225
    if FontMagicDB.minimapHide == nil then FontMagicDB.minimapHide = false end
elseif FontMagicDB.minimapHide == nil then
    -- Ensure the hide flag exists for old DB versions
    FontMagicDB.minimapHide = false
end

if type(FontMagicDB.minimapRadiusOffset) ~= "number" then
    FontMagicDB.minimapRadiusOffset = FM_MINIMAP_RADIUS_OFFSET_DEFAULT
else
    FontMagicDB.minimapRadiusOffset = ClampNumber(FontMagicDB.minimapRadiusOffset, FM_MINIMAP_RADIUS_OFFSET_MIN, FM_MINIMAP_RADIUS_OFFSET_MAX)
end

if type(FontMagicDB.schemaVersion) ~= "number" then
    FontMagicDB.schemaVersion = FM_DB_SCHEMA_VERSION
elseif FontMagicDB.schemaVersion < FM_DB_SCHEMA_VERSION then
    -- Reserved migration hook for future schema upgrades.
    FontMagicDB.schemaVersion = FM_DB_SCHEMA_VERSION
end

local function EnsureTableField(tbl, key)
    if type(tbl) ~= "table" then return {} end
    if type(tbl[key]) ~= "table" then
        tbl[key] = {}
    end
    return tbl[key]
end

-- Favorites (account-wide): a set of saved font keys like "Fun/Pepsi.ttf".
-- Stored in the main DB so favorites persist across characters.
EnsureTableField(FontMagicDB, "favorites")

if type(FontMagicPCDB) ~= "table" then
    FontMagicPCDB = {}
end

-- forward declare so slash commands can toggle visibility before creation
local minimapButton

-- Combat text settings are account-wide in WoW (CVars), so store overrides account-wide too.
-- These are treated as *overrides*: if a value is absent/nil, FontMagic will not change the
-- game's setting and the UI will simply reflect whatever WoW is currently set to.
EnsureTableField(FontMagicDB, "combatOverrides")
EnsureTableField(FontMagicDB, "extraCombatOverrides")
EnsureTableField(FontMagicDB, "incomingOverrides")
if FontMagicDB.showExtraCombatToggles == nil then FontMagicDB.showExtraCombatToggles = false end

-- Combat font targeting/rendering defaults.
if FontMagicDB.applyToWorldText == nil then FontMagicDB.applyToWorldText = true end
if FontMagicDB.applyToScrollingText == nil then FontMagicDB.applyToScrollingText = true end
if type(FontMagicDB.scrollingTextOutlineMode) ~= "string" or FontMagicDB.scrollingTextOutlineMode == "" then
    FontMagicDB.scrollingTextOutlineMode = ""
end
if FontMagicDB.scrollingTextMonochrome == nil then FontMagicDB.scrollingTextMonochrome = false end
if type(FontMagicDB.scrollingTextShadowOffset) ~= "number" then FontMagicDB.scrollingTextShadowOffset = 1 end
local FLOATING_GRAVITY_CANDIDATES = { "WorldTextGravity_v2", "WorldTextGravity_V2", "WorldTextGravity", "floatingCombatTextGravity_v2", "floatingCombatTextGravity_V2", "floatingCombatTextGravity" }
local FLOATING_FADE_CANDIDATES = { "WorldTextRampDuration_v2", "WorldTextRampDuration_V2", "WorldTextRampDuration", "floatingCombatTextRampDuration_v2", "floatingCombatTextRampDuration_V2", "floatingCombatTextRampDuration" }

if type(FontMagicDB.floatingTextGravity) ~= "number" then
    FontMagicDB.floatingTextGravity = GetResolvedSettingNumber(FLOATING_GRAVITY_CANDIDATES, 1.0)
end
if type(FontMagicDB.floatingTextFadeDuration) ~= "number" then
    FontMagicDB.floatingTextFadeDuration = GetResolvedSettingNumber(FLOATING_FADE_CANDIDATES, 1.0)
end

-- Migration: older versions stored combat overrides per-character. Move them into the account DB.
do
    local migrated = false

    local function MergeMissing(dest, src)
        if type(dest) ~= "table" or type(src) ~= "table" then return false end
        local changed = false
        for k, v in pairs(src) do
            if dest[k] == nil then
                dest[k] = v
                changed = true
            end
        end
        return changed
    end

    if type(FontMagicPCDB) == "table" then
        if MergeMissing(FontMagicDB.combatOverrides, FontMagicPCDB.combatOverrides) then
            migrated = true
        end
        if MergeMissing(FontMagicDB.extraCombatOverrides, FontMagicPCDB.extraCombatOverrides) then
            migrated = true
        end
        if MergeMissing(FontMagicDB.incomingOverrides, FontMagicPCDB.incomingOverrides) then
            migrated = true
        end

        FontMagicPCDB.combatOverrides = nil
        FontMagicPCDB.extraCombatOverrides = nil
        FontMagicPCDB.incomingOverrides = nil
    end

    -- If combat text was previously hidden by the old main checkbox (per-character override),
    -- clear it so we don't unexpectedly keep combat text disabled after upgrade.
    if migrated and type(FontMagicDB.combatOverrides) == "table" then
        FontMagicDB.combatOverrides["enableFloatingCombatText"] = nil
    end
end


local COMBAT_FONT_GROUPS = {
    ["Popular"] = {
        path  = ADDON_PATH .. "Popular\\",
        fonts = {
            "Pepsi.ttf", "bignoodletitling.ttf", "Expressway.ttf", "Bangers.ttf", "PTSansNarrow-Bold.ttf", "Roboto Condensed Bold.ttf",
            "NotoSans_Condensed-Bold.ttf", "Roboto-Bold.ttf", "AlteHaasGroteskBold.ttf", "CalibriBold.ttf", "Orbitron.ttf", "Prototype.ttf",
            "914Solid.ttf", "Halo.ttf", "Proxima Nova Condensed Bold.ttf", "Comfortaa-Bold.ttf", "Andika-Bold.ttf", "lemon-milk.ttf",
            "Good Brush.ttf"
        },
    },
    ["Clean & Readable"] = {
        path  = ADDON_PATH .. "Easy-to-Read\\",
        fonts = {
            "BauhausRegular.ttf", "Diogenes.ttf", "Junegull.ttf", "SF-Pro.ttf", "Solange.ttf", "Takeaway.ttf"
        },
    },
    ["Bold & Impact"] = {
        path  = ADDON_PATH .. "BoldImpact\\",
        fonts = {
            "DieDieDie.ttf", "graff.ttf", "Green Fuz.otf", "modernwarfare.ttf", "Skratchpunk.ttf", "Skullphabet.ttf",
            "Trashco.ttf", "Whiplash.ttf"
        },
    },
    ["Fantasy & RP"] = {
        path  = ADDON_PATH .. "Fun\\",
        fonts = {
            "Acadian.ttf", "akash.ttf", "Caesar.ttf", "ComicRunes.ttf", "crygords.ttf", "Deltarune.ttf",
            "Elven.ttf", "Gunung.ttf", "Guroes.ttf", "HarryP.ttf", "Hobbit.ttf", "Kting.ttf",
            "leviathans.ttf", "MystikOrbs.ttf", "Odinson.ttf", "ParryHotter.ttf", "Pau.ttf", "Pokemon.ttf",
            "Runic.ttf", "Runy.ttf", "Ruritania.ttf", "Spongebob.ttf", "The Centurion .ttf", "VTKS.ttf",
            "WaltographUI.ttf", "Wasser.ttf", "Wickedmouse.ttf", "WKnight.ttf", "Zombie.ttf"
        },
    },
    ["Sci-Fi & Tech"] = {
        path  = ADDON_PATH .. "Future\\",
        fonts = {
            "04b.ttf", "albra.TTF", "Audiowide.ttf", "continuum.ttf", "dalek.ttf", "Digital.ttf",
            "Exocet.ttf", "Galaxyone.ttf", "pf_tempesta_seven.ttf", "Price.ttf", "RaceSpace.ttf", "RushDriver.ttf",
            "Terminator.ttf"
        },
    },
    ["Random"] = {
        path  = ADDON_PATH .. "Random\\",
        fonts = {
            "accidentalpres.ttf", "animeace.ttf", "Barriecito.ttf", "baskethammer.ttf", "ChopSic.ttf", "college.ttf",
            "Disko.ttf", "Dmagic.ttf", "edgyh.ttf", "edkies.ttf", "FastHand.ttf", "figtoen.ttf",
            "font2.ttf", "Fraks.ttf", "Ginko.ttf", "Homespun.ttf", "IKARRG.TTF", "JJSTS.TTF",
            "Ktingw.ttf", "Melted.ttf", "Midorima.ttf", "Munsteria.ttf", "Rebuffed.TTF", "Shiruken.ttf",
            "shog.ttf", "Starcine.ttf", "Stentiga.ttf", "tsuchigumo.ttf", "WhoAsksSatan.ttf"
        },
    },
    ["Custom"] = {
        path  = CUSTOM_PATH,
        -- custom fonts are provided by the optional FontMagicCustomFonts addon
        -- they reside in its Custom folder rather than this addon's
        fonts = {}, -- populated below
    },
}


-- Populate the expected custom font names (1.ttf .. 20.ttf)
do
    local t = COMBAT_FONT_GROUPS["Custom"].fonts
    for i = 1, 20 do
        t[i] = i .. ".ttf"
    end
end

-- Cache loaded fonts to allow previewing in the options panel
local cachedFonts, existsFonts = {}, {}
local __fmFontCacheId = 0
local hasCustomFonts = false -- tracks whether any custom font could be loaded
for group, data in pairs(COMBAT_FONT_GROUPS) do
    cachedFonts[group] = {}
    existsFonts[group] = {}
    for _, fname in ipairs(data.fonts) do
        local path = data.path .. fname
        __fmFontCacheId = __fmFontCacheId + 1
        local f = CreateFont(addonName .. "CacheFont" .. __fmFontCacheId)
        -- safely attempt to load the font; missing or invalid files
        -- should not throw errors during detection
        local ok = pcall(function() f:SetFont(path, 32, "") end)
        local loaded = ok and f:GetFont()
        if loaded and loaded:lower():find(fname:lower(), 1, true) then
            existsFonts[group][fname] = true
            cachedFonts[group][fname] = { font = f, path = path }
            if group == "Custom" then
                hasCustomFonts = true
            end
        else
            existsFonts[group][fname] = false
        end
    end
end

local originalInfo = {}

-- cache Blizzard's default combat text fonts so we can revert the preview
-- when the user presses the "Default" button. these paths are populated once
-- the relevant globals become available (usually when Blizzard_CombatText loads)
local blizzDefaultDamageFont
local blizzDefaultCombatFont

-- ---------------------------------------------------------------------------
-- Combat text font application
-- ---------------------------------------------------------------------------

-- Capture Blizzard's default combat text font paths so we can restore them later.
-- In some clients these globals aren't populated until Blizzard_CombatText loads,
-- so we also refresh them during PLAYER_LOGIN / Blizzard_CombatText load.
local DEFAULT_DAMAGE_TEXT_FONT = (type(DAMAGE_TEXT_FONT) == "string" and DAMAGE_TEXT_FONT) or nil
local DEFAULT_COMBAT_TEXT_FONT = (type(COMBAT_TEXT_FONT)  == "string" and COMBAT_TEXT_FONT)  or nil
local DEFAULT_FONT_PATH = DEFAULT_DAMAGE_TEXT_FONT or DEFAULT_COMBAT_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

local function CaptureBlizzardDefaultFonts()
    if not DEFAULT_DAMAGE_TEXT_FONT and type(DAMAGE_TEXT_FONT) == "string" then
        DEFAULT_DAMAGE_TEXT_FONT = DAMAGE_TEXT_FONT
    end
    if not DEFAULT_COMBAT_TEXT_FONT and type(COMBAT_TEXT_FONT) == "string" then
        DEFAULT_COMBAT_TEXT_FONT = COMBAT_TEXT_FONT
    end
    if not DEFAULT_FONT_PATH or DEFAULT_FONT_PATH == "" then
        DEFAULT_FONT_PATH = DEFAULT_DAMAGE_TEXT_FONT or DEFAULT_COMBAT_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
    end
end

local function GroupHasFont(grp, fname)
    local data = COMBAT_FONT_GROUPS and COMBAT_FONT_GROUPS[grp]
    if type(data) == "table" and type(data.fonts) == "table" then
        for _, f in ipairs(data.fonts) do
            if f == fname then return true end
        end
    end
    return false
end

-- Convert a saved key like "Fun/Pepsi.ttf" to an on-disk font path.
-- Also supports legacy keys that only stored the filename.
local function ResolveFontPathFromKey(key)
    if type(key) ~= "string" or key == "" then return nil end

    local grp, fname = key:match("^(.*)/([^/]+)$")
    if grp and fname and COMBAT_FONT_GROUPS[grp] and type(COMBAT_FONT_GROUPS[grp].path) == "string" then
        -- If the group still owns this filename, use it. Otherwise treat as legacy and try to migrate by filename.
        if GroupHasFont(grp, fname) then
            return COMBAT_FONT_GROUPS[grp].path .. fname, grp, fname
        end
    end

    -- Legacy / migration: key may be only a filename (or a group that no longer exists).
    local only = key:match("([^/]+)$")
    if only and (only:lower():match("%.ttf$") or only:lower():match("%.otf$")) then
        for g, data in pairs(COMBAT_FONT_GROUPS) do
            if type(data) == "table" and type(data.path) == "string" and type(data.fonts) == "table" then
                for _, f in ipairs(data.fonts) do
                    if f == only then
                        return data.path .. f, g, f
                    end
                end
            end
        end
    end

    return nil
end

-- Try to apply the combat text font immediately
local function CanonicalizeFontKey(key)
    local _, grp, fname = ResolveFontPathFromKey(key)
    if grp and fname then
        return grp .. "/" .. fname
    end
    return nil
end

local function MigrateSavedFontKeys()
    if type(FontMagicDB) ~= "table" then return end
    if FontMagicDB.__fmPopularFolderMigrationDone then return end

    -- Selected font
    if type(FontMagicDB.selectedFont) == "string" and FontMagicDB.selectedFont ~= "" then
        local canon = CanonicalizeFontKey(FontMagicDB.selectedFont)
        if canon then
            FontMagicDB.selectedFont = canon
        else
            -- Saved selection no longer exists; fall back safely to Default
            FontMagicDB.selectedFont = ""
        end
    end

    -- Favorites
    if type(FontMagicDB.favorites) == "table" then
        local out = {}
        for key, on in pairs(FontMagicDB.favorites) do
            if on == true then
                local canon = CanonicalizeFontKey(key)
                if canon then
                    out[canon] = true
                end
            end
        end
        FontMagicDB.favorites = out
    end

    FontMagicDB.__fmPopularFolderMigrationDone = true
end

-- by updating the globals and
-- any common FontObjects that already exist in the current client.
local SCROLLING_TEXT_FONT_OBJECTS = {
    "CombatTextFont", "CombatTextFontOutline", "DamageFont", "DamageFontOutline",
    "CombatTextFontNormal", "CombatTextFontSmall", "DamageTextFont", "DamageTextFontOutline",
    "DamageNumberFont", "CombatDamageFont", "CombatHealingAbsorbGlowFont", "WorldFont",
}

local defaultScrollingTextFonts = {}
local preview, editBox, previewHeaderFS
local ForcePreviewTextRedraw

local function CaptureDefaultScrollingTextFonts()
    for _, name in ipairs(SCROLLING_TEXT_FONT_OBJECTS) do
        local obj = _G and _G[name]
        if obj and type(obj.GetFont) == "function" and defaultScrollingTextFonts[name] == nil then
            local fPath, fSize, fFlags = obj:GetFont()
            local ox, oy = 1, -1
            if type(obj.GetShadowOffset) == "function" then
                local sx, sy = obj:GetShadowOffset()
                if sx ~= nil and sy ~= nil then
                    ox, oy = sx, sy
                end
            end
            defaultScrollingTextFonts[name] = {
                path = fPath,
                size = fSize,
                flags = fFlags,
                shadowX = ox,
                shadowY = oy,
            }
        end
    end
end

local function BuildScrollingTextFontFlags()
    if not (FontMagicDB and FontMagicDB.applyToScrollingText) then
        return ""
    end

    local parts = {}
    local outline = FontMagicDB.scrollingTextOutlineMode
    if outline == "OUTLINE" or outline == "THICKOUTLINE" then
        table.insert(parts, outline)
    end
    if FontMagicDB.scrollingTextMonochrome then
        table.insert(parts, "MONOCHROME")
    end
    return table.concat(parts, ",")
end

local function RestoreDefaultScrollingTextFonts()
    CaptureDefaultScrollingTextFonts()
    for _, name in ipairs(SCROLLING_TEXT_FONT_OBJECTS) do
        local obj = _G and _G[name]
        local state = defaultScrollingTextFonts[name]
        if obj and state and type(obj.SetFont) == "function" and type(state.path) == "string" and state.path ~= "" then
            pcall(obj.SetFont, obj, state.path, state.size or 25, state.flags or "")
            if type(obj.SetShadowOffset) == "function" then
                pcall(obj.SetShadowOffset, obj, state.shadowX or 1, state.shadowY or -1)
            end
        end
    end
end

local function ApplyWorldTextFontPath(path)
    local effective = path
    if not (FontMagicDB and FontMagicDB.applyToWorldText) then
        effective = DEFAULT_DAMAGE_TEXT_FONT or DEFAULT_COMBAT_TEXT_FONT or DEFAULT_FONT_PATH
    end

    if type(effective) == "string" and effective ~= "" then
        _G.DAMAGE_TEXT_FONT = effective
        _G.COMBAT_TEXT_FONT = effective
    end
end

local function ApplyScrollingTextFontPath(path)
    CaptureDefaultScrollingTextFonts()
    if not (FontMagicDB and FontMagicDB.applyToScrollingText) then
        RestoreDefaultScrollingTextFonts()
        return
    end

    if type(path) ~= "string" or path == "" then
        return
    end

    local flags = BuildScrollingTextFontFlags()
    local shadowOffset = tonumber(FontMagicDB and FontMagicDB.scrollingTextShadowOffset) or 0
    for _, name in ipairs(SCROLLING_TEXT_FONT_OBJECTS) do
        local obj = _G and _G[name]
        local state = defaultScrollingTextFonts[name]
        if obj and type(obj.SetFont) == "function" then
            local size = (state and state.size) or 25
            pcall(obj.SetFont, obj, path, size, flags)
            if type(obj.SetShadowOffset) == "function" then
                if shadowOffset <= 0 then
                    pcall(obj.SetShadowOffset, obj, 0, 0)
                else
                    pcall(obj.SetShadowOffset, obj, shadowOffset, -shadowOffset)
                end
            end
        end
    end
end

local function ApplyCombatTextFontPath(path)
    if type(path) ~= "string" or path == "" then return end
    ApplyWorldTextFontPath(path)
    ApplyScrollingTextFontPath(path)
end

local FLOATING_GRAVITY_FALLBACK_MIN, FLOATING_GRAVITY_FALLBACK_MAX = 0.00, 2.00
local FLOATING_FADE_FALLBACK_MIN, FLOATING_FADE_FALLBACK_MAX = 0.10, 3.00
local FLOATING_MOTION_STEP = 0.05

local function ResolveFloatingMotionUIState()
    local gravityName = ResolveCVarName(FLOATING_GRAVITY_CANDIDATES)
    local fadeName = ResolveCVarName(FLOATING_FADE_CANDIDATES)
    local gravitySupported = (gravityName ~= nil)
    local fadeSupported = (fadeName ~= nil)

    local gravityMin, gravityMax = FLOATING_GRAVITY_FALLBACK_MIN, FLOATING_GRAVITY_FALLBACK_MAX
    local fadeMin, fadeMax = FLOATING_FADE_FALLBACK_MIN, FLOATING_FADE_FALLBACK_MAX

    if gravitySupported then
        local lo, hi = ResolveNumericRange(gravityName)
        if lo ~= nil and hi ~= nil then
            gravityMin, gravityMax = lo, hi
        end
    end
    if fadeSupported then
        local lo, hi = ResolveNumericRange(fadeName)
        if lo ~= nil and hi ~= nil then
            fadeMin, fadeMax = lo, hi
        end
    end

    return {
        gravityName = gravityName,
        fadeName = fadeName,
        gravitySupported = gravitySupported,
        fadeSupported = fadeSupported,
        gravityMin = gravityMin,
        gravityMax = gravityMax,
        fadeMin = fadeMin,
        fadeMax = fadeMax,
    }
end

local function ResolveMotionClampRange(candidates, fallbackMin, fallbackMax)
    local name = ResolveCVarName(candidates)
    if name then
        local lo, hi = ResolveNumericRange(name)
        if lo ~= nil and hi ~= nil then
            return lo, hi
        end
    end
    return fallbackMin, fallbackMax
end

local function QuantizeFloatingMotionValue(v, minVal, maxVal)
    local lo, hi = NormalizeSliderBounds(minVal, maxVal, minVal, maxVal)
    local step = NormalizeSliderStep(FLOATING_MOTION_STEP, lo, hi)
    local snapped = math.floor((((tonumber(v) or lo) - lo) / step) + 0.5) * step + lo
    if snapped < lo then snapped = lo end
    if snapped > hi then snapped = hi end

    local decimals = GetSliderDisplayDecimals(step, lo, hi)
    local mult = 10 ^ decimals
    return math.floor(snapped * mult + 0.5) / mult, decimals
end

local function ApplyFloatingTextMotionSettings()
    local function clamp(v, lo, hi)
        if v < lo then return lo end
        if v > hi then return hi end
        return v
    end

    local gravityCandidates = FLOATING_GRAVITY_CANDIDATES
    local fadeCandidates = FLOATING_FADE_CANDIDATES

    local gravityTargets = ResolveConsoleSettingTargets(gravityCandidates)
    local fadeTargets = ResolveConsoleSettingTargets(fadeCandidates)

    local gravityMin, gravityMax = ResolveMotionClampRange(gravityCandidates, FLOATING_GRAVITY_FALLBACK_MIN, FLOATING_GRAVITY_FALLBACK_MAX)
    local fadeMin, fadeMax = ResolveMotionClampRange(fadeCandidates, FLOATING_FADE_FALLBACK_MIN, FLOATING_FADE_FALLBACK_MAX)

    if #gravityTargets > 0 and FontMagicDB and type(FontMagicDB.floatingTextGravity) == "number" then
        local g, gDecimals = QuantizeFloatingMotionValue(FontMagicDB.floatingTextGravity, gravityMin, gravityMax)
        g = clamp(g, gravityMin, gravityMax)
        FontMagicDB.floatingTextGravity = g
        local formatted = string.format("%0." .. tostring(gDecimals) .. "f", g)
        for _, target in ipairs(gravityTargets) do
            ApplyConsoleSetting(target.name, target.commandType, formatted)
        end
    end
    if #fadeTargets > 0 and FontMagicDB and type(FontMagicDB.floatingTextFadeDuration) == "number" then
        local f, fDecimals = QuantizeFloatingMotionValue(FontMagicDB.floatingTextFadeDuration, fadeMin, fadeMax)
        f = clamp(f, fadeMin, fadeMax)
        FontMagicDB.floatingTextFadeDuration = f
        local formatted = string.format("%0." .. tostring(fDecimals) .. "f", f)
        for _, target in ipairs(fadeTargets) do
            ApplyConsoleSetting(target.name, target.commandType, formatted)
        end
    end
end

local function RefreshPreviewRendering()
    if not preview then return end

    local applies = FontMagicDB and FontMagicDB.applyToScrollingText
    local off = tonumber(FontMagicDB and FontMagicDB.scrollingTextShadowOffset) or 0
    if preview.SetShadowOffset then
        if applies then
            if off <= 0 then
                pcall(preview.SetShadowOffset, preview, 0, 0)
            else
                pcall(preview.SetShadowOffset, preview, off, -off)
            end
        else
            pcall(preview.SetShadowOffset, preview, 1, -1)
        end
    end

    if preview.GetFont and preview.SetFont then
        local pPath, pSize = preview:GetFont()
        if type(pPath) == "string" and pPath ~= "" and type(pSize) == "number" then
            local flags = applies and BuildScrollingTextFontFlags() or ""
            pcall(preview.SetFont, preview, pPath, pSize, flags)
        end
    end

    ForcePreviewTextRedraw()
end

local function ApplySavedCombatFont()
    if type(FontMagicDB) ~= "table" then return end
    local key = FontMagicDB.selectedFont
    if type(key) ~= "string" or key == "" then
        local def = DEFAULT_DAMAGE_TEXT_FONT or DEFAULT_COMBAT_TEXT_FONT or DEFAULT_FONT_PATH or "Fonts\\FRIZQT__.TTF"
        ApplyCombatTextFontPath(def)
        return
    end

    local path, grp, fname = ResolveFontPathFromKey(key)
    if (not path) and type(FontMagicDB.selectedFontPath) == "string" and FontMagicDB.selectedFontPath ~= "" then
        -- Keep a direct path fallback so a previously-selected font can still
        -- be restored if group/file catalog names change between releases.
        path = FontMagicDB.selectedFontPath
    end
    if not path then
        -- Saved selection no longer exists; fall back to Default safely.
        FontMagicDB.selectedFont = ""
        local def = GetBlizzardDefaultCombatTextFont and GetBlizzardDefaultCombatTextFont() or DEFAULT_DAMAGE_TEXT_FONT or DEFAULT_COMBAT_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
        ApplyCombatTextFontPath(def)
        return
    end

    -- If we resolved via migration, update the stored key to the canonical form.
    if grp and fname then
        local canon = grp .. "/" .. fname
        if key ~= canon then
            FontMagicDB.selectedFont = canon
        end
    end

    FontMagicDB.selectedFontPath = path

    ApplyCombatTextFontPath(path)
end

-- Initial capture + apply as early as possible
CaptureBlizzardDefaultFonts()
ApplySavedCombatFont()


-- 2) MAIN WINDOW
local frame = CreateFrame("Frame", addonName .. "Frame", UIParent, backdropTemplate)
--
-- The options window previously lacked a border and used uneven padding
-- around its contents.  Here we keep all the widgets exactly where they
-- were defined and instead only change the outer frame so that it provides
-- an even buffer on every side and a simple border for clarity.
--
-- Constants control the visual spacing and border width so adjustments can
-- be made in a single location.
local PAD       = 20   -- distance from the outer edge to the nearest widget
local BORDER    = 12   -- thickness of the decorative border
local HEADER_H  = 40   -- space reserved for the InterfaceOptions header
local PREVIEW_W = 320  -- width of preview and edit boxes
-- Checkbox column width. Adjusted to ensure the combined width of the two
-- columns plus the spacing between them equals the preview width. The
-- preview box is 320px wide and we want 16px of spacing between the two
-- columns, leaving 304px for the columns themselves. 304/2 = 152.
local CB_COL_W  = 152  -- checkbox column width
local DD_COL_W  = 200  -- width allocated for each dropdown column

-- Dropdown layout (shared by the window and menu builders)
local DD_COLS      = 2    -- number of dropdowns per row
local DD_MARGIN_X  = 12   -- left/right inner margin for dropdown columns
local DD_WIDTH     = 160  -- UIDropDownMenu_SetWidth value

-- UI spacing tweaks
-- These values are intentionally centralized so we can keep the layout
-- balanced while ensuring the lowest checkbox row never collides with the
-- bottom action buttons.
local CONTENT_NUDGE_Y = 12  -- shifts the whole lower section up slightly
local CHECK_BASE_Y    = -12 -- offset of the first checkbox row under the edit box
local CHECK_ROW_H     = 30  -- vertical spacing between checkbox rows
local CHECK_COL_GAP   = 16  -- spacing between left/right checkbox columns

-- The existing widgets already expect roughly 20px from the top-left
-- of the frame, so we simply expand the overall frame to ensure the same
-- distance on the remaining sides as well.
-- Widen the frame slightly so dropdown menus and other widgets have
-- adequate padding on both sides. This prevents the second column of
-- dropdowns from touching or overlapping the right border when the
-- window is scaled.
-- Compute the window width from the dropdown grid so the columns are
-- perfectly padded on both sides when using 3 dropdowns per row.
local INNER_W = DD_WIDTH + (DD_MARGIN_X * 2) + ((DD_COLS - 1) * DD_COL_W)
local COLLAPSED_W = INNER_W + PAD * 2
local LEFT_PANEL_X = math.floor((COLLAPSED_W - PREVIEW_W) / 2 + 0.5)
frame.__fmCollapsedW = COLLAPSED_W
frame:SetSize(COLLAPSED_W, 500 + PAD * 2)
frame:SetPoint("CENTER")
frame:SetBackdrop({
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile     = true, tileSize = 32,
    edgeSize = BORDER,
    insets   = { left = PAD - BORDER, right = PAD - BORDER,
                 top  = PAD - BORDER, bottom = PAD - BORDER },
})
-- Darker, more opaque background so text stays readable even over bright scenes.
frame:SetBackdropColor(0, 0, 0, 0.92)
frame:EnableMouse(true)
frame:SetMovable(true)
if frame.SetClampedToScreen then pcall(frame.SetClampedToScreen, frame, true) end
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    if self.GetParent and self:GetParent() == UIParent and FontMagicDB and self.GetLeft and self.GetTop then
        local l, t = self:GetLeft(), self:GetTop()
        if type(l) == "number" and type(t) == "number" then
            FontMagicDB.windowPos = { left = l, top = t }
        end
    end
end)
frame:Hide()
frame.name = "FontMagic"

-- Anchor frame used to keep the left-side controls (Apply/Reset/Close/Expand) fixed
-- when the window expands to show the optional Combat Options panel.
local leftAnchor = CreateFrame("Frame", nil, frame)
leftAnchor:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
leftAnchor:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
leftAnchor:SetWidth(frame.__fmCollapsedW or frame:GetWidth() or 0)
frame.__fmLeftAnchor = leftAnchor

-- allow ESC key to close the frame
if UISpecialFrames then
    tinsert(UISpecialFrames, frame:GetName())
end

-- Register the options panel only once (prevents duplicate categories in Retail Settings).
local _optionsRegistered = false
local function RegisterOptionsCategory()
    if _optionsRegistered then return end
    if type(InterfaceOptions_AddCategory) == "function" then
        local ok = pcall(InterfaceOptions_AddCategory, frame)
        if ok then
            _optionsRegistered = true
        end
    end
end

local function SetDropdownTextCompat(dd, text)
    if not dd then return end
    if type(UIDropDownMenu_SetText) == "function" then
        pcall(UIDropDownMenu_SetText, dd, text)
    elseif dd.SetText then
        dd:SetText(text)
    end
end

-- 3) COMMON WIDGET HELPERS ---------------------------------------------------
local _cbId = 0

local function GetCheckButtonLabelFS(cb)
    if not cb then return nil end
    -- Modern clients: cb.Text. Older templates: cb.text.
    local fs = cb.Text or cb.text
    if fs and fs.SetText then return fs end

    -- Fallback: scan regions for the first FontString.
    if cb.GetRegions then
        local regions = { cb:GetRegions() }
        for _, r in ipairs(regions) do
            if r and r.GetObjectType and r:GetObjectType() == "FontString" then
                return r
            end
        end
    end
    return nil
end

local function SetCheckButtonLabel(cb, label)
    local fs = GetCheckButtonLabelFS(cb)
    if fs then
        fs:SetText(label or "")
        cb.__fmLabelFS = fs
    end
end

local function SetCheckButtonLabelColor(cb, r, g, b)
    local fs = cb and (cb.__fmLabelFS or GetCheckButtonLabelFS(cb))
    if fs and fs.SetTextColor then
        fs:SetTextColor(r, g, b)
        cb.__fmLabelFS = fs
    end
end

local function CreateCheckbox(parent, label, x, y, checked, onClick)
    _cbId = _cbId + 1
    local cb = CreateFrame("CheckButton", addonName .. "CB" .. _cbId, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", x, y)
    SetCheckButtonLabel(cb, label)

    -- Tighten label spacing: keep the text directly to the right of the checkbox on all clients.
    do
        local fs = cb and (cb.__fmLabelFS or GetCheckButtonLabelFS(cb))
        if fs and fs.ClearAllPoints and fs.SetPoint then
            fs:ClearAllPoints()
            fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
            if fs.SetJustifyH then fs:SetJustifyH("LEFT") end
            cb.__fmLabelFS = fs
        end
    end

    cb:SetChecked(checked and true or false)
    if onClick then cb:SetScript("OnClick", onClick) end
    return cb
end


-- 4) FONT DROPDOWNS ---------------------------------------------------------
local dropdowns = {}
local mainShowCombatTextCB
-- holds a font selection made via the dropdowns but not yet applied
local pendingFont
local SyncPreviewToAppliedFont
local UpdatePendingStateText
local RefreshPreviewTextFromEditBox


-- Favorites helpers ---------------------------------------------------------
local function EnsureFavorites()
    if type(FontMagicDB) ~= "table" then FontMagicDB = {} end
    if type(FontMagicDB.favorites) ~= "table" then
        FontMagicDB.favorites = {}
    end
    return FontMagicDB.favorites
end

local function IsFavorite(key)
    local favs = EnsureFavorites()
    return favs[key] == true
end

local function ToggleFavorite(key)
    local favs = EnsureFavorites()
    if favs[key] == true then
        favs[key] = nil
    else
        favs[key] = true
    end
end

-- Select a font key as the current (pending) selection and update the preview.
-- Used when a user clicks the favorite star so the UI still previews what they just favorited.
local SetPreviewFont
local UpdatePreviewHeaderText
-- Incremented on every preview font change. Used to cancel any queued next-frame
-- sizing pass so a stale preview (e.g. from a font you only *previewed*) can't
-- overwrite the currently-applied font after the window is closed/reopened.
local __fmPreviewToken = 0
local function SelectFontKey(key)
    if type(key) ~= "string" or key == "" then return end

    -- Prefer updating the dropdown that is currently open (if it's ours), otherwise the group dropdown.
    local open = _G and _G.UIDROPDOWNMENU_OPEN_MENU
    local targetDD
    if open and open.__fmGroup and dropdowns[open.__fmGroup] == open then
        targetDD = open
    end

    local function ApplySelectionPreviewByKey(selectionKey, opts)
        opts = opts or {}
        local grp, fname = selectionKey:match("^(.*)/([^/]+)$")
        if not grp or not fname then return false end

        local display = __fmStripFontExt(tostring(fname))

        if opts.clearAllDropDownLabels and type(UIDropDownMenu_SetText) == "function" then
            for _, d2 in pairs(dropdowns) do
                pcall(UIDropDownMenu_SetText, d2, "Select Font")
            end
        end

        if opts.setPending then
            pendingFont = selectionKey
            if UpdatePendingStateText then UpdatePendingStateText() end
        end

        local dd = opts.targetDropDown or dropdowns[grp]
        if dd and type(UIDropDownMenu_SetText) == "function" then
            local label = opts.labelText or display
            pcall(UIDropDownMenu_SetText, dd, label)
        elseif dd and dd.SetText then
            local label = opts.labelText or display
            dd:SetText(label)
        end

        local cache = cachedFonts and cachedFonts[grp] and cachedFonts[grp][fname]
        if cache then
            SetPreviewFont(cache)
            if UpdatePreviewHeaderText then UpdatePreviewHeaderText(display, cache.path, false) end
        else
            local path = ResolveFontPathFromKey(selectionKey)
            if path then
                SetPreviewFont(GameFontNormalLarge or (preview and preview.GetFontObject and preview:GetFontObject()), path)
                if UpdatePreviewHeaderText then UpdatePreviewHeaderText(display, path, false) end
            end
        end

        if RefreshPreviewTextFromEditBox then
            RefreshPreviewTextFromEditBox()
        end

        return true
    end

    local grp, fname = key:match("^(.*)/([^/]+)$")
    local display = fname and __fmStripFontExt(tostring(fname)) or nil
    ApplySelectionPreviewByKey(key, {
        setPending = true,
        clearAllDropDownLabels = true,
        targetDropDown = targetDD,
        labelText = (targetDD and targetDD.__fmGroup == "Favorites" and display and grp) and (display .. " (" .. grp .. ")") or display,
    })
end

-- Safely add buttons to UIDropDownMenu across Classic/Retail variants.
local function SafeAddDropDownButton(info, level)
    if type(UIDropDownMenu_AddButton) ~= "function" then return end
    local ok = pcall(UIDropDownMenu_AddButton, info, level)
    if not ok then
        pcall(UIDropDownMenu_AddButton, info)
    end
end

-- Attach a small clickable star to a dropdown list entry button.
local FM_FAV_TEX_ON  = "Interface\\AddOns\\FontMagic\\Media\\FM_FavStar_Filled.tga"
local FM_FAV_TEX_OFF = "Interface\\AddOns\\FontMagic\\Media\\FM_FavStar_Outline.tga"

local UpdateFavoriteStar

local function AttachFavoriteStar(menuButton)
    if not menuButton then return end
    if menuButton.__fmStar then return end

    local star = CreateFrame("Button", nil, menuButton)
    star:SetSize(16, 16)
    star:SetPoint("RIGHT", menuButton, "RIGHT", -6, 0)
    star:RegisterForClicks("LeftButtonUp")

    local icon = star:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    star.icon = icon

    -- Slightly increase visibility on hover without relying on unicode glyphs
    -- (many default UI fonts do not contain ★/☆ on older clients).
    star:SetScript("OnEnter", function(self)
        if not self.__fmKey then return end
        self.__fmHover = true
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local key = self.__fmKey
        GameTooltip:SetText((key and IsFavorite(key)) and "Remove from Favorites" or "Add to Favorites")
        GameTooltip:Show()
        if self.icon then
            self.icon:SetAlpha(1)
        end
    end)
    star:SetScript("OnLeave", function(self)
        self.__fmHover = false
        if GameTooltip and GameTooltip.Hide then
            GameTooltip:Hide()
        end
        -- restore the non-hover alpha for the current state
        local key = self.__fmKey
        if self.icon then
            if key and IsFavorite(key) then
                self.icon:SetAlpha(1)
            else
                self.icon:SetAlpha(0.75)
            end
        end
    end)

    star:SetScript("OnClick", function(self)
        local key = self.__fmKey
        if not key then return end

        ToggleFavorite(key)
        local nowFav = IsFavorite(key)

        -- If we removed a favorite while browsing the Favorites dropdown, do not
        -- force-select it (that makes it look like it still belongs there).
        local open = _G and _G.UIDROPDOWNMENU_OPEN_MENU
        local inFavMenu = (open and open.__fmGroup == "Favorites") and true or false

        if nowFav or not inFavMenu then
            -- Adding a favorite (or toggling anywhere outside Favorites): keep the
            -- existing "select + preview" behavior so the change is visible.
            SelectFontKey(key)
        else
            -- Removed from Favorites while inside Favorites: clear the Favorites
            -- dropdown label only if it was showing this key.
            local shouldClear = (pendingFont == key) or (FontMagicDB and FontMagicDB.selectedFont == key)
            local removedPending = (pendingFont == key)
            local selectedWasRemoved = (FontMagicDB and FontMagicDB.selectedFont == key)

            if pendingFont == key then
                pendingFont = nil
                if UpdatePendingStateText then UpdatePendingStateText() end
            end

            if shouldClear and dropdowns and dropdowns["Favorites"] then
                if type(UIDropDownMenu_SetText) == "function" then
                    pcall(UIDropDownMenu_SetText, dropdowns["Favorites"], "Select Font")
                elseif dropdowns["Favorites"].SetText then
                    dropdowns["Favorites"]:SetText("Select Font")
                end
            end

            if (removedPending or selectedWasRemoved) and type(SyncPreviewToAppliedFont) == "function" then
                pcall(SyncPreviewToAppliedFont)
            end
        end

        -- refresh this button's star state immediately
        if self:GetParent() then
            UpdateFavoriteStar(self:GetParent(), key)
        end

        -- Favorites list is built on dropdown open; closing is the safest way to ensure it refreshes everywhere.
        if type(CloseDropDownMenus) == "function" then
            CloseDropDownMenus()
        end
    end)


    -- Constrain the entry label so it does not run underneath the star.
    local labelFS = menuButton.GetFontString and menuButton:GetFontString()
    if labelFS and not menuButton.__fmTextConstrained then
        labelFS:ClearAllPoints()
        labelFS:SetPoint("LEFT", menuButton, "LEFT", 24, 0)
        labelFS:SetPoint("RIGHT", star, "LEFT", -4, 0)
        labelFS:SetJustifyH("LEFT")
        menuButton.__fmTextConstrained = true
    end

    menuButton.__fmStar = star
end

UpdateFavoriteStar = function(menuButton, key)
    if not menuButton or not menuButton.__fmStar then return end
    local star = menuButton.__fmStar
    star.__fmKey = key

    -- UIDropDownMenu recycles list buttons. If this row is a disabled placeholder
    -- (e.g. "No favorites yet"), hide any previously-attached star.
    if (not key) or (menuButton.IsEnabled and not menuButton:IsEnabled()) then
        star.__fmKey = nil
        if star.EnableMouse then star:EnableMouse(false) end
        if star.Hide then star:Hide() end
        return
    end
    if star.EnableMouse then star:EnableMouse(true) end
    if star.Show then star:Show() end

    local fav = (IsFavorite(key)) and true or false
    if star.icon then
        if fav then
            star.icon:SetTexture(FM_FAV_TEX_ON)
            star.icon:SetVertexColor(1, 0.82, 0)
            star.icon:SetAlpha(1)
        else
            star.icon:SetTexture(FM_FAV_TEX_OFF)
            star.icon:SetVertexColor(0.75, 0.75, 0.75)
            star.icon:SetAlpha(star.__fmHover and 1 or 0.75)
        end
    end
end

local function GetDropDownListButton(level, index)
    return _G and _G["DropDownList" .. tostring(level) .. "Button" .. tostring(index)] or nil
end

local __fmClearMenuButtonHoverPreview
local __fmClearMenuButtonFavoriteDecorations

local function ClearDropDownListDecorations(level)
    if type(level) ~= "number" then return end
    local listFrame = _G and _G["DropDownList" .. tostring(level)]
    local count = tonumber(listFrame and listFrame.numButtons) or 0
    if count <= 0 then return end

    for i = 1, count do
        local btn = GetDropDownListButton(level, i)
        if btn then
            __fmClearMenuButtonHoverPreview(btn)
            __fmClearMenuButtonFavoriteDecorations(btn)
        end
    end
end

local function ClearDropDownButtonsFrom(level, startIndex)
    if type(level) ~= "number" then return end
    local listFrame = _G and _G["DropDownList" .. tostring(level)]
    local count = tonumber(listFrame and listFrame.numButtons) or 0
    if count <= 0 then return end

    local first = tonumber(startIndex) or 1
    if first < 1 then first = 1 end

    for i = first, count do
        local btn = GetDropDownListButton(level, i)
        if btn then
            __fmClearMenuButtonHoverPreview(btn)
            if btn.__fmStar then
                UpdateFavoriteStar(btn, nil)
            end
        end
    end
end

local function GetStepDecimals(step)
    local decimals = 0
    local n = tonumber(step)
    local str = tostring((n ~= nil) and n or "")
    if str:find("e") or str:find("E") then
        str = string.format("%.6f", n or 0)
    end
    local frac = str:match("%f[%d]%.(%d+)")
    if frac then
        decimals = #frac
    end
    if decimals < 0 then decimals = 0 end
    if decimals > 6 then decimals = 6 end
    return decimals
end

local function GetNumberDecimals(n)
    if type(n) ~= "number" then
        n = tonumber(n)
    end
    if n == nil then return 0 end

    local str = tostring(n)
    if str:find("e") or str:find("E") then
        str = string.format("%.6f", n)
    end
    local frac = str:match("%f[%d]%.(%d+)")
    if not frac then return 0 end

    local decimals = #frac
    if decimals > 6 then decimals = 6 end
    return decimals
end

local function GetSliderDisplayDecimals(step, minVal, maxVal)
    local d = GetStepDecimals(step)
    local dMin = GetNumberDecimals(minVal)
    local dMax = GetNumberDecimals(maxVal)
    if dMin > d then d = dMin end
    if dMax > d then d = dMax end
    if d > 6 then d = 6 end
    return d
end

local function NumbersNearlyEqual(a, b, tolerance)
    local x = tonumber(a)
    local y = tonumber(b)
    if x == nil or y == nil then
        return false
    end

    local eps = tonumber(tolerance) or 0.000001
    return math.abs(x - y) <= eps
end

local function NormalizeSliderRange(minVal, maxVal, fallbackMin, fallbackMax)
    local lo = tonumber(minVal)
    local hi = tonumber(maxVal)
    local fLo = tonumber(fallbackMin)
    local fHi = tonumber(fallbackMax)

    if lo == nil then lo = fLo end
    if hi == nil then hi = fHi end
    if lo == nil then lo = 0 end
    if hi == nil then hi = lo end
    if hi < lo then
        lo, hi = hi, lo
    end

    return lo, hi
end

local function NormalizeSliderBounds(minVal, maxVal, fallbackMin, fallbackMax)
    local lo, hi = NormalizeSliderRange(minVal, maxVal, fallbackMin, fallbackMax)
    if lo == hi then
        hi = lo + 0.000001
    end
    return lo, hi
end

-- Slider snapping helper used by both the main combat-text scale slider and
-- floating-text motion sliders. This keeps endpoint behavior consistent across
-- clients where floating-point drag updates can otherwise miss min/max labels.
local function SnapSliderToStep(v, minVal, maxVal, step)
    minVal = tonumber(minVal) or 0
    maxVal = tonumber(maxVal) or minVal
    if maxVal < minVal then
        minVal, maxVal = maxVal, minVal
    end

    step = tonumber(step) or 1
    if step <= 0 then
        step = 1
    end

    if type(v) ~= "number" then
        v = tonumber(v) or minVal
    end

    -- Endpoint snapping uses half-step tolerance so users can always reach
    -- exact min/max even when drag updates jitter around the ends.
    local range = math.max(maxVal - minVal, 0)
    local epsilon = math.max(math.min(step * 0.5, range * 0.5), 0.000001)
    if math.abs(v - minVal) <= epsilon then
        return minVal
    end
    if math.abs(maxVal - v) <= epsilon then
        return maxVal
    end

    local snapped = math.floor(((v - minVal) / step) + 0.5) * step + minVal
    snapped = math.max(minVal, math.min(maxVal, snapped))

    local precision = GetSliderDisplayDecimals(step, minVal, maxVal)
    local mult = 10 ^ precision
    snapped = math.floor(snapped * mult + 0.5) / mult

    -- Guard against floating-point drift around endpoints (for example values
    -- like 1.999999 when max is 2.0). This keeps UI labels and persisted values
    -- perfectly aligned with the actual clamped range.
    if math.abs(snapped - minVal) <= epsilon then
        snapped = minVal
    elseif math.abs(maxVal - snapped) <= epsilon then
        snapped = maxVal
    end

    return snapped
end

local function NormalizeSliderStep(step, minVal, maxVal)
    local safeStep = tonumber(step)
    if safeStep == nil or safeStep <= 0 then
        safeStep = 1
    end

    local range = math.abs((tonumber(maxVal) or 0) - (tonumber(minVal) or 0))
    if range > 0 then
        safeStep = math.min(safeStep, range)
    end

    return safeStep
end

local function ResolveNumericRangeFromConsole(name)
    if type(name) ~= "string" or name == "" then return nil, nil end

    local idx = BuildConsoleCommandIndex()
    if type(idx) ~= "table" or idx[name] == nil then return nil, nil end

    local meta = type(_consoleCommandMeta) == "table" and _consoleCommandMeta[name] or nil
    if type(meta) == "table" then
        local lo = tonumber(meta.minValue)
        local hi = tonumber(meta.maxValue)
        if lo ~= nil and hi ~= nil and hi >= lo then
            return lo, hi
        end
    end

    return nil, nil
end

local function ResolveNumericRangeFromCVarInfo(name)
    if type(name) ~= "string" or name == "" then return nil, nil end

    local getInfo = nil
    if type(C_CVar) == "table" and type(C_CVar.GetCVarInfo) == "function" then
        getInfo = C_CVar.GetCVarInfo
    elseif type(GetCVarInfo) == "function" then
        getInfo = GetCVarInfo
    end
    if not getInfo then return nil, nil end

    local ok, a, b, c, d, e, f, g, h, i = pcall(getInfo, name)
    if not ok then
        return nil, nil
    end

    local lo, hi
    if type(a) == "table" then
        lo = tonumber(a.minValue or a.min)
        hi = tonumber(a.maxValue or a.max)
    else
        -- On some older client branches GetCVarInfo returns discrete values.
        -- If min/max are present they are trailing values (commonly positions 8/9).
        lo = tonumber(h)
        hi = tonumber(i)
    end

    if lo ~= nil and hi ~= nil and hi >= lo then
        return lo, hi
    end

    return nil, nil
end

local function ResolveNumericRange(name)
    if type(name) ~= "string" or name == "" then return nil, nil end

    -- Prefer Settings metadata first when available (Retail Settings panel).
    if type(Settings) == "table" and type(Settings.GetSetting) == "function" then
        local ok, setting = pcall(Settings.GetSetting, name)
        if ok and type(setting) == "table" then
            local opts = nil
            if type(setting.GetOptions) == "function" then
                local okOpts, data = pcall(setting.GetOptions, setting)
                if okOpts and type(data) == "table" then
                    opts = data
                end
            end

            local lo = tonumber((opts and (opts.minValue or opts.min)) or setting.minValue or setting.min)
            local hi = tonumber((opts and (opts.maxValue or opts.max)) or setting.maxValue or setting.max)
            if lo ~= nil and hi ~= nil and hi >= lo then
                return NormalizeSliderRange(lo, hi)
            end
        end
    end

    -- Fall back to CVar metadata where available.
    local lo, hi = ResolveNumericRangeFromCVarInfo(name)
    if lo ~= nil and hi ~= nil then
        return NormalizeSliderRange(lo, hi)
    end

    -- Final fallback: console command metadata.
    local cLo, cHi = ResolveNumericRangeFromConsole(name)
    if cLo ~= nil and cHi ~= nil then
        return NormalizeSliderRange(cLo, cHi)
    end
    return nil, nil
end

local function SetSliderObeyStepCompat(slider, obey)
    if slider and type(slider.SetObeyStepOnDrag) == "function" then
        pcall(slider.SetObeyStepOnDrag, slider, obey and true or false)
    end
end

--[[
    Apply a font to the preview field.

    The original implementation assumed fontObj was always valid. During early
    loading however, "GameFontNormalLarge" may not yet exist which triggered
    the reported "attempt to index local 'fontObj'" error. To make the function
    robust we guard against nil values and gracefully fall back when loading via
    the font path fails.

    NOTE: Some font files report incorrect metrics on the same frame they are
    first applied (the client may still be loading the face). To ensure the
    preview size normalizes immediately (no "select twice" behavior), we do the
    fit-to-bounds sizing pass on the next frame.
--]]

-- Next-frame helper (compatible across Classic/Retail; avoids relying on C_Timer).
local __fmNextFrameFrame
local __fmNextFrameQueue
local function __fmRunNextFrame(fn)
    if type(fn) ~= "function" then return end
    if not __fmNextFrameFrame then
        __fmNextFrameQueue = {}
        __fmNextFrameFrame = CreateFrame("Frame")
        __fmNextFrameFrame:Hide()
        __fmNextFrameFrame:SetScript("OnUpdate", function(self)
            self:Hide()
            local q = __fmNextFrameQueue or {}
            __fmNextFrameQueue = {}
            for i = 1, #q do
                pcall(q[i])
            end
        end)
    end
    table.insert(__fmNextFrameQueue, fn)
    __fmNextFrameFrame:Show()
end




-- Hover preview for font dropdown items --------------------------------------
-- Shows a small tooltip-like window near the cursor rendering the hovered font name
-- in its own face, so users can browse without clicking each entry.

local __fmHoverPrevFrame, __fmHoverPrevText
local __fmHoverPrevToken = 0
local __fmHoverPrevFollowUntil = 0
local FM_HOVER_PREVIEW_FOLLOW_DURATION = 0.9

local function __fmGetCursorScaled()
    if type(GetCursorPosition) ~= "function" then return 0, 0 end
    local x, y = GetCursorPosition()
    local scale = 1
    if UIParent and UIParent.GetEffectiveScale then
        scale = UIParent:GetEffectiveScale() or 1
    end
    if scale == 0 then scale = 1 end
    return (x or 0) / scale, (y or 0) / scale
end

local function __fmPositionHoverPreview(f)
    if not (f and UIParent and UIParent.GetWidth and UIParent.GetHeight) then return end
    local x, y = __fmGetCursorScaled()
    local uiW = UIParent:GetWidth() or 0
    local uiH = UIParent:GetHeight() or 0
    local w  = f:GetWidth()  or 0
    local h  = f:GetHeight() or 0

    -- Preferred placement: to the right and slightly above the cursor.
    local offsetX, offsetY = 18, 18
    local left = x + offsetX
    local top  = y + offsetY

    -- If near the right edge, flip to the left of the cursor.
    if (left + w) > (uiW - 6) then
        left = x - offsetX - w
    end
    -- Clamp to screen bounds (a little inset keeps border visible).
    if left < 6 then left = 6 end
    if (left + w) > (uiW - 6) then left = (uiW - w - 6) end

    -- Keep within vertical bounds.
    if top > (uiH - 6) then
        top = uiH - 6
    end
    if (top - h) < 6 then
        -- Try placing below the cursor if we're too high.
        top = y - offsetY
        if (top - h) < 6 then
            top = h + 6
        end
    end

    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
end

local function __fmEnsureHoverPreviewFrame()
    if __fmHoverPrevFrame then return __fmHoverPrevFrame end

    local f = CreateFrame("Frame", addonName .. "HoverPreview", UIParent, backdropTemplate)
    f:SetSize(260, 46)
    f:SetFrameStrata("TOOLTIP")
    f:SetClampedToScreen(true)
    f:EnableMouse(false)

    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile     = true, tileSize = 16,
            edgeSize = 12,
            insets   = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        f:SetBackdropColor(0, 0, 0, 0.92)
        if f.SetBackdropBorderColor then
            f:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)
        end
    end

    local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:ClearAllPoints()
    fs:SetPoint("CENTER", f, "CENTER", 0, -1)
    fs:SetWidth((f:GetWidth() or 260) - 14)
    fs:SetJustifyH("CENTER")
    if fs.SetJustifyV then pcall(fs.SetJustifyV, fs, "MIDDLE") end

    f.text = fs
    f:Hide()

    f.__fmFollowCursor = true
    f:SetScript("OnUpdate", function(self, elapsed)
        if not self:IsShown() then return end

        if self.__fmFollowCursor then
            __fmPositionHoverPreview(self)
            if type(GetTime) == "function" and GetTime() >= (__fmHoverPrevFollowUntil or 0) then
                self.__fmFollowCursor = false
            end
        end
    end)

    __fmHoverPrevFrame = f
    __fmHoverPrevText  = fs
    return f
end

local function __fmHideHoverPreview()
    __fmHoverPrevToken = (__fmHoverPrevToken or 0) + 1
    if __fmHoverPrevFrame then
        __fmHoverPrevFrame:Hide()
    end
end

local function __fmShowHoverPreview(display, path, flags)
    if type(display) ~= "string" or display == "" then return end
    if type(path) ~= "string" or path == "" then return end

    local f = __fmEnsureHoverPreviewFrame()
    if not (f and f.text) then return end

    local fs = f.text
    fs:SetText(display)

    -- Use a conservative starter size; we'll fit-to-bounds next frame.
    local baseObj = GameFontNormalLarge or GameFontNormal or GameFontHighlight
    local _, _, baseFlags = (baseObj and baseObj.GetFont and baseObj:GetFont())
    local flagsToUse = flags or baseFlags or ""

    local ok = false
    if fs.SetFont then
        ok = pcall(fs.SetFont, fs, path, 18, flagsToUse)
        if (not ok) and flagsToUse ~= "" then
            ok = pcall(fs.SetFont, fs, path, 18, "")
            if ok then flagsToUse = "" end
        end
    end
    if (not ok) and fs.SetFontObject and baseObj then
        pcall(fs.SetFontObject, fs, baseObj)
    end

    __fmHoverPrevToken = (__fmHoverPrevToken or 0) + 1
    local myToken = __fmHoverPrevToken

    __fmRunNextFrame(function()
        if myToken ~= __fmHoverPrevToken then return end
        if not (__fmHoverPrevFrame and __fmHoverPrevFrame.IsShown and __fmHoverPrevFrame:IsShown()) then return end
        if not (__fmHoverPrevText and __fmHoverPrevText.SetFont and __fmHoverPrevText.GetStringWidth and __fmHoverPrevText.GetStringHeight) then return end

        local maxW = (__fmHoverPrevFrame:GetWidth() or 260) - 16
        local maxH = (__fmHoverPrevFrame:GetHeight() or 46) - 16
        if maxW < 40 then maxW = 200 end
        if maxH < 16 then maxH = 24 end

        local function trySize(sz)
            local ok2 = pcall(__fmHoverPrevText.SetFont, __fmHoverPrevText, path, sz, flagsToUse)
            if not ok2 and flagsToUse ~= "" then
                ok2 = pcall(__fmHoverPrevText.SetFont, __fmHoverPrevText, path, sz, "")
                if ok2 then flagsToUse = "" end
            end
            if not ok2 then return false end
            __fmHoverPrevText:SetText(display)
            local w = __fmHoverPrevText:GetStringWidth() or 0
            local h = __fmHoverPrevText:GetStringHeight() or 0
            return (w <= maxW and h <= maxH)
        end

        local low, high = 10, 28
        local best = 14
        while low <= high do
            local mid = math.floor((low + high) / 2)
            if trySize(mid) then
                best = mid
                low = mid + 1
            else
                high = mid - 1
            end
        end
        trySize(best)
    end)

    __fmPositionHoverPreview(f)
    if type(GetTime) == "function" then
        __fmHoverPrevFollowUntil = GetTime() + FM_HOVER_PREVIEW_FOLLOW_DURATION
    else
        __fmHoverPrevFollowUntil = 0
    end
    f.__fmFollowCursor = true
    f:Show()
end

local function __fmAttachHoverPreviewToMenuButton(btn, display, cache)
    if not btn then return end
    if type(display) ~= "string" or display == "" then return end

    local path, flags
    if type(cache) == "table" then
        path  = cache.path
        flags = cache.flags
    end
    if type(path) ~= "string" or path == "" then return end

    btn.__fmHoverPrevName  = display
    btn.__fmHoverPrevPath  = path
    btn.__fmHoverPrevFlags = flags

    if btn.HookScript and not btn.__fmHoverPrevHooked then
        btn:HookScript("OnEnter", function(self)
            if self.__fmHoverPrevPath then
                __fmShowHoverPreview(self.__fmHoverPrevName or "", self.__fmHoverPrevPath, self.__fmHoverPrevFlags)
            end
        end)
        btn:HookScript("OnLeave", function()
            __fmHideHoverPreview()
        end)
        btn.__fmHoverPrevHooked = true
    end
end

__fmClearMenuButtonHoverPreview = function(btn)
    if not btn then return end
    btn.__fmHoverPrevName  = nil
    btn.__fmHoverPrevPath  = nil
    btn.__fmHoverPrevFlags = nil
end

__fmClearMenuButtonFavoriteDecorations = function(btn)
    if not btn then return end
    if btn.__fmStar then
        UpdateFavoriteStar(btn, nil)
    end
end

local function GetCurrentPreviewFontPath()
    local key = pendingFont or (FontMagicDB and FontMagicDB.selectedFont)
    local path = ResolveFontPathFromKey(key)
    if type(path) == "string" and path ~= "" then
        return path
    end
    return DEFAULT_DAMAGE_TEXT_FONT or DEFAULT_COMBAT_TEXT_FONT or DEFAULT_FONT_PATH
end

-- Ensure we never leave the hover preview orphaned if menus close without an OnLeave (rare but possible).
if type(hooksecurefunc) == "function" then
    if type(CloseDropDownMenus) == "function" then
        pcall(hooksecurefunc, "CloseDropDownMenus", __fmHideHoverPreview)
    end
    if type(UIDropDownMenu_HideDropDownMenu) == "function" then
        pcall(hooksecurefunc, "UIDropDownMenu_HideDropDownMenu", __fmHideHoverPreview)
    end
    if type(ToggleDropDownMenu) == "function" then
        pcall(hooksecurefunc, "ToggleDropDownMenu", function()
            __fmHideHoverPreview()
        end)
    end
end

-- Force a redraw of the preview text (some clients won't repaint an unchanged string
-- immediately after SetFont/SetFontObject until the text changes).
ForcePreviewTextRedraw = function()
    if not (preview and type(preview.SetText) == "function") then return end

    local txt = ""
    if editBox and type(editBox.GetText) == "function" then
        txt = tostring(editBox:GetText() or "")
    elseif type(preview.GetText) == "function" then
        txt = tostring(preview:GetText() or "")
    end

    local cur = ""
    if type(preview.GetText) == "function" then
        cur = tostring(preview:GetText() or "")
    end

    if txt ~= cur then
        preview:SetText(txt)
    else
        preview:SetText(txt .. " ")
        preview:SetText(txt)
    end
end

SetPreviewFont = function(fontObj, path)
    -- allow passing the cached font table directly
    if type(fontObj) == "table" then
        path    = fontObj.path or path
        fontObj = fontObj.font
    end

    -- Some clients (or earlier calls to SetFont) can leave preview:GetFontObject() nil.
    -- We still want preview updates to work even when no FontObject is available.
    local baseObj = fontObj
    if not (baseObj and type(baseObj.GetFont) == "function") then
        baseObj = GameFontNormalLarge or GameFontNormal or GameFontHighlight or (preview and preview.GetFontObject and preview:GetFontObject())
    end

    local baseFlags = ""
    if baseObj and type(baseObj.GetFont) == "function" then
        local _, _, f = baseObj:GetFont()
        if type(f) == "string" then
            baseFlags = f
        end
    end

    local function GetCurrentPreviewText()
        if editBox and editBox.GetText then
            return tostring(editBox:GetText() or "")
        end
        if preview and preview.GetText then
            return tostring(preview:GetText() or "")
        end
        return ""
    end

    -- If we have an explicit file path, apply it and normalize size so all fonts
    -- appear visually consistent inside the preview box (fit-to-bounds).
    if path and preview and type(preview.SetFont) == "function" then
        local flagsToUse = baseFlags


        local function tryApply(sz, flags)
            local ok = pcall(preview.SetFont, preview, path, sz, flags)
            if not ok then return false end

            -- Do not trust the return value from SetFont: different clients / objects
            -- return different values (or nothing), and some apply the face asynchronously.
            -- If we can't confirm immediately, we still proceed and normalize next frame.
            if preview and type(preview.GetFont) == "function" then
                local curPath = preview:GetFont()
                if type(curPath) == "string" then
                    local want = tostring(path)
                    if curPath:lower() == want:lower() then
                        return true
                    end
                    local wantFile = want:match("([^\\/:]+)$")
                    if wantFile and curPath:lower():find(wantFile:lower(), 1, true) then
                        return true
                    end
                end
            end

            return true
        end

        -- Force the face to load immediately with a sensible starter size.
        local applied = tryApply(24, flagsToUse)
        if not applied then
            applied = tryApply(24, "")
            if applied then
                flagsToUse = ""
            end
        end

        if not applied then
            -- If the client refuses to load this font path, fall back to a base FontObject.
            if preview and type(preview.SetFontObject) == "function" and baseObj then
                pcall(preview.SetFontObject, preview, baseObj)
            end
            -- Ensure text is still visible.
            if preview and preview.SetText then
                ForcePreviewTextRedraw()
            end
            return
        end

        -- Ensure the current preview text is displayed immediately.
        if preview and preview.SetText then
            ForcePreviewTextRedraw()
        end

        __fmPreviewToken = (__fmPreviewToken or 0) + 1
        local myToken = __fmPreviewToken

        __fmRunNextFrame(function()
            if myToken ~= __fmPreviewToken then return end
            if not preview or type(preview.SetFont) ~= "function" then return end

            -- Use the preview's parent (the preview box) for sizing.
            local parent = (preview.GetParent and preview:GetParent()) or nil
            local maxW, maxH = 0, 0
            local padX, padY = 14, 16
            if parent and parent.GetWidth and parent.GetHeight then
                maxW = (parent:GetWidth() or 0) - padX
                maxH = (parent:GetHeight() or 0) - padY
            end
            if maxW <= 0 then maxW = (preview.GetWidth and preview:GetWidth()) or 300 end
            if maxH <= 0 then maxH = (preview.__fmMaxH or 44) end
            if maxH < 18 then maxH = 18 end

            if preview.SetWordWrap then
                pcall(preview.SetWordWrap, preview, false)
            end

            -- Measure off-screen so we never blank or replace the user's preview text.
            local measure = preview.__fmMeasure
            if not measure and parent and parent.CreateFontString then
                measure = parent:CreateFontString(nil, "OVERLAY")
                measure:Hide()
                preview.__fmMeasure = measure
            end

            local sample = "H8g"

            local function trySize(sz)
                if myToken ~= __fmPreviewToken then return false end

                if measure and type(measure.SetFont) == "function" then
                    local ok, ret = pcall(measure.SetFont, measure, path, sz, flagsToUse)
                    if not ok or ret == nil or ret == false then return false end
                    if measure.SetText then
                        measure:SetText(sample)
                    end
                    local w = (measure.GetStringWidth and measure:GetStringWidth()) or 0
                    local h = (measure.GetStringHeight and measure:GetStringHeight()) or 0
                    return (w <= maxW and h <= (maxH - 2))
                end

                -- Fallback: if we cannot create a measure string, temporarily measure on the preview.
                local old = GetCurrentPreviewText()
                if preview.SetText then preview:SetText(sample) end
                local ok, ret = pcall(preview.SetFont, preview, path, sz, flagsToUse)
                local w = (preview.GetStringWidth and preview:GetStringWidth()) or 0
                local h = (preview.GetStringHeight and preview:GetStringHeight()) or 0
                if preview.SetText then preview:SetText(old) end
                if not ok or ret == nil or ret == false then return false end
                return (w <= maxW and h <= (maxH - 2))
            end

            -- Find the largest size that fits (binary search).
            local low, high = 8, 90
            local best = 8
            if not trySize(best) then best = 8 end
            while low <= high do
                local mid = math.floor((low + high) / 2)
                if trySize(mid) then
                    best = mid
                    low = mid + 1
                else
                    high = mid - 1
                end
            end

            if myToken ~= __fmPreviewToken then return end
            pcall(preview.SetFont, preview, path, best, flagsToUse)

            -- Force a redraw of the preview text even if it hasn't changed.
            if preview and preview.SetText then
                local finalText = GetCurrentPreviewText()
                local curText = ""
                if preview.GetText then curText = tostring(preview:GetText() or "") end
                if finalText ~= curText then
                    preview:SetText(finalText)
                else
                    -- Some clients won't redraw if the string is identical.
                    preview:SetText(finalText .. " ")
                    preview:SetText(finalText)
                end
            end
        end)

        RefreshPreviewRendering()
        return
    end

    -- Fall back to using the font object if explicit path loading is not available.
    if preview and type(preview.SetFontObject) == "function" and baseObj then
        pcall(preview.SetFontObject, preview, baseObj)
        if preview and preview.SetText then
            ForcePreviewTextRedraw()
        end
    end
    RefreshPreviewRendering()
end



-- Update the font-name label above the preview box so it always reflects what is being previewed.
local __fmHeaderToken = 0
UpdatePreviewHeaderText = function(displayText, fontPath, isDefault)
    if not previewHeaderFS then return end

    local text = "Default"
    if not isDefault and type(displayText) == "string" and displayText ~= "" then
        text = displayText
    end
    if previewHeaderFS.SetText then
        previewHeaderFS:SetText(text)
    end

    local path = fontPath
    if type(path) ~= "string" or path == "" then
        CaptureBlizzardDefaultFonts()
        path = DEFAULT_DAMAGE_TEXT_FONT or DEFAULT_COMBAT_TEXT_FONT or DEFAULT_FONT_PATH or "Fonts\\FRIZQT__.TTF"
    end
    if type(path) ~= "string" or path == "" then return end

    local baseObj = GameFontNormal or GameFontNormalLarge or (preview and preview.GetFontObject and preview:GetFontObject())
    local _, baseSize, baseFlags = (baseObj and baseObj.GetFont and baseObj:GetFont())
    local flagsToUse = baseFlags or ""
    local starterSize = tonumber(baseSize) or 14
    if starterSize < 12 then starterSize = 12 end
    if starterSize > 18 then starterSize = 18 end

    if type(previewHeaderFS.SetFont) ~= "function" then
        if previewHeaderFS.SetFontObject and baseObj then
            pcall(previewHeaderFS.SetFontObject, previewHeaderFS, baseObj)
        end
        return
    end

    -- Attempt an immediate apply so it doesn't remain at a tiny fallback size.
    do
        local ok = pcall(previewHeaderFS.SetFont, previewHeaderFS, path, starterSize, flagsToUse)
        if not ok and flagsToUse ~= "" then
            ok = pcall(previewHeaderFS.SetFont, previewHeaderFS, path, starterSize, "")
            if ok then
                flagsToUse = ""
            end
        end
        if not ok and previewHeaderFS.SetFontObject and baseObj then
            pcall(previewHeaderFS.SetFontObject, previewHeaderFS, baseObj)
        end
    end

    __fmHeaderToken = (__fmHeaderToken or 0) + 1
    local myToken = __fmHeaderToken

    __fmRunNextFrame(function()
        if myToken ~= __fmHeaderToken then return end
        if not previewHeaderFS or type(previewHeaderFS.SetFont) ~= "function" then return end

        local maxW = ((previewHeaderFS.GetWidth and previewHeaderFS:GetWidth()) or (PREVIEW_W or 320)) - 12
        if maxW < 40 then maxW = (PREVIEW_W or 320) - 12 end
        local maxH = 18

        local function trySize(sz)
            local ok = pcall(previewHeaderFS.SetFont, previewHeaderFS, path, sz, flagsToUse)
            if not ok and flagsToUse ~= "" then
                ok = pcall(previewHeaderFS.SetFont, previewHeaderFS, path, sz, "")
                if ok then
                    flagsToUse = ""
                end
            end
            if not ok then return false end

            local w = (previewHeaderFS.GetStringWidth and previewHeaderFS:GetStringWidth()) or 0
            local h = (previewHeaderFS.GetStringHeight and previewHeaderFS:GetStringHeight()) or 0
            return (w <= maxW and h <= maxH)
        end

        local low, high = 8, 22
        local best = 12
        while low <= high do
            local mid = math.floor((low + high) / 2)
            if trySize(mid) then
                best = mid
                low = mid + 1
            else
                high = mid - 1
            end
        end
        trySize(best)
    end)
end

-- Dropdowns for each font group arranged neatly in two columns
-- Displayed dropdown order; the "Custom" category replaces the old "Default"
-- dropdown to allow users to provide their own fonts.
local order = {"Favorites", "Popular", "Clean & Readable", "Bold & Impact", "Fantasy & RP", "Sci-Fi & Tech", "Custom", "Random"}
-- "Popular" is driven by the /Popular folder (authoritative).
-- Optional display-name overrides for cleaner dropdown labels.
local FONT_LABEL_OVERRIDES = {
    ["bignoodletitling.ttf"]             = "Big Noodle Titling",
    ["PTSansNarrow-Bold.ttf"]            = "PT Sans Narrow (Bold)",
    ["NotoSans_Condensed-Bold.ttf"]      = "Noto Sans Condensed (Bold)",
    ["Roboto Condensed Bold.ttf"]        = "Roboto Condensed (Bold)",
    ["Roboto-Bold.ttf"]                  = "Roboto (Bold)",
    ["CalibriBold.ttf"]                  = "Calibri (Bold)",
    ["AlteHaasGroteskBold.ttf"]          = "Alte Haas Grotesk (Bold)",
    ["Proxima Nova Condensed Bold.ttf"]  = "Proxima Nova Condensed (Bold)",
    ["lemon-milk.ttf"]                   = "Lemon Milk",
}

local FONT_LABEL_OVERRIDES_L = {}
for k, v in pairs(FONT_LABEL_OVERRIDES) do
    if type(k) == "string" then
        FONT_LABEL_OVERRIDES_L[k:lower()] = v
    end
end

local function DisplayNameForFont(fname)
    if type(fname) ~= "string" or fname == "" then return "" end
    local base = __fmStripFontExt(fname)
    local lower = fname:lower()
    local label = FONT_LABEL_OVERRIDES[fname] or FONT_LABEL_OVERRIDES_L[lower] or base
    return __fmShortenFontLabel(label)
end

local function GetCustomFontsInstallHint()
    local prettyPath = tostring(CUSTOM_PATH or "Interface\\AddOns\\FontMagicCustomFonts\\Custom\\")
    return "Install " .. CUSTOM_ADDON .. ", add .ttf/.otf files in\n" .. prettyPath .. "\nthen /reload."
end

local lastDropdown
for idx, grp in ipairs(order) do
    local dd = CreateFrame("Frame", addonName .. grp:gsub("[^%w]", "") .. "DD", frame, "UIDropDownMenuTemplate")
    dd.__fmGroup = grp
    local row = math.floor((idx-1)/DD_COLS)
    local col = (idx-1) % DD_COLS

    -- If the last row is not full, center the remaining dropdown for a cleaner look.
    local remainder = #order % DD_COLS
    local x = DD_MARGIN_X + col * DD_COL_W
    if remainder == 1 and idx == #order and grp ~= "Custom" then
        x = DD_MARGIN_X + (DD_COL_W / 2)
    end

-- place dropdowns below the InterfaceOptions title text
    -- shift dropdowns slightly so left and right margins are even
    -- Position each dropdown in its own column.  We reduce the default
    -- horizontal margin from 16px to 12px so that the combined width of the
    -- two dropdowns, the spacing between them and the left/right margins add
    -- up symmetrically across the options window.  Without this adjustment
    -- the rightmost dropdown sits flush against the frame border.
    dd:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -(HEADER_H + row*50) + 8)
    UIDropDownMenu_SetWidth(dd, DD_WIDTH)
    dropdowns[grp] = dd
    if idx == #order then
        lastDropdown = dd -- remember last dropdown for layout anchoring
    end

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    -- position label so its left edge aligns with the dropdown
    label:ClearAllPoints()
    label:SetPoint("BOTTOM", dd, "TOP", 0, 3)
    -- Use the frame's GetWidth() method to obtain the dropdown width.
    -- UIDropDownMenu_GetWidth has been removed in Dragonflight and older
    -- globals may not return a valid number. GetWidth() is available on all
    -- frames and ensures a numeric width is returned.
    label:SetWidth(dd:GetWidth())
    label:SetJustifyH("CENTER")
    label:SetText(grp)

    if grp == "Custom" then
        dd:SetScript("OnEnter", function(self)
            if not hasCustomFonts then
                ShowTooltip(self, "ANCHOR_RIGHT", "Custom fonts are provided by the optional FontMagicCustomFonts addon.", GetCustomFontsInstallHint())
            end
        end)
        dd:SetScript("OnLeave", HideTooltip)
    end

    UIDropDownMenu_Initialize(dd, function()
        local level = UIDROPDOWNMENU_MENU_LEVEL or 1
        ClearDropDownListDecorations(level)
        local added = false
        local buttonIndex = 0

        if grp == "Favorites" then
            local favs = EnsureFavorites()
            local favList = {}
            for key, on in pairs(favs) do
                if on == true then
                    -- Parse using the last '/' so legacy groups with slashes are handled.
                    local g, f = key:match("^(.*)/([^/]+)$")
                    if g and f and existsFonts[g] and existsFonts[g][f] and cachedFonts[g] and cachedFonts[g][f] then
                        local display = DisplayNameForFont(f)
                        table.insert(favList, { key = key, grp = g, fname = f, display = display })
                    end
                end
            end
            table.sort(favList, function(a, b)
                return (a.display:lower() .. a.key) < (b.display:lower() .. b.key)
            end)

            for _, item in ipairs(favList) do
                added = true
                buttonIndex = buttonIndex + 1

                local info = UIDropDownMenu_CreateInfo()
                local cache = cachedFonts[item.grp][item.fname]
                info.text = item.display .. " (" .. item.grp .. ")"
                info.func = function()
                    SelectFontKey(item.key)
                end
                local selected = pendingFont or FontMagicDB.selectedFont
                info.checked = (selected == item.key)
                SafeAddDropDownButton(info, level)

                local mb = GetDropDownListButton(level, buttonIndex)
                if mb then
                    AttachFavoriteStar(mb)
                    UpdateFavoriteStar(mb, item.key)
                    __fmAttachHoverPreviewToMenuButton(mb, item.display, cache)
                end
            end
        else
            local groupData = COMBAT_FONT_GROUPS[grp]
            if type(groupData) == "table" and type(groupData.fonts) == "table" then
                for _, fname in ipairs(groupData.fonts) do
                if existsFonts[grp][fname] then
                    added = true
                    buttonIndex = buttonIndex + 1

                    local info = UIDropDownMenu_CreateInfo()
                    local display = DisplayNameForFont(fname)
                    local cache  = cachedFonts[grp][fname]
                    local key    = grp .. "/" .. fname

                    info.text = display
                    info.func = function()
                        SelectFontKey(key)
                    end
                    local selected = pendingFont or FontMagicDB.selectedFont
                    info.checked = (selected == key)
                    SafeAddDropDownButton(info, level)

                    local mb = GetDropDownListButton(level, buttonIndex)
                    if mb then
                        AttachFavoriteStar(mb)
                        UpdateFavoriteStar(mb, key)
                        __fmAttachHoverPreviewToMenuButton(mb, display, cache)
                    end
                end
            end
            end
        end
        if not added then
            local info = UIDropDownMenu_CreateInfo()
            if grp == "Favorites" then
                info.text = "No favorites yet"
            elseif grp == "Custom" and not hasCustomFonts then
                info.text = "No custom fonts found (install FontMagicCustomFonts)"
            else
                info.text = "No font detected"
            end
            info.disabled = true
            SafeAddDropDownButton(info, level)

            if grp == "Custom" and not hasCustomFonts then
                local hint = UIDropDownMenu_CreateInfo()
                hint.text = GetCustomFontsInstallHint()
                hint.disabled = true
                SafeAddDropDownButton(hint, level)
            end

            -- This entry is a disabled placeholder; ensure any recycled menu button
            -- doesn't show a leftover favorite star from a previous dropdown open.
            ClearDropDownButtonsFrom(level, buttonIndex + 1)
        else
            -- Even when this menu has entries, UIDropDownMenu may recycle extra
            -- buttons from previous opens. Clear any stale hover-preview/favorite
            -- handlers from the unused tail so rows never retain old behavior.
            ClearDropDownButtonsFrom(level, buttonIndex + 1)
        end
    end)
end

-- 5) SCALE SLIDER -----------------------------------------------------------
local scaleLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
-- Centre the combat text size label beneath the last row of dropdowns.  We
-- calculate how many rows of dropdowns exist (three columns per row) and
-- position the label relative to the top of the frame so it always sits
-- centred horizontally regardless of whether the last dropdown falls in the
-- left or right column.  The vertical offset accounts for the header
-- height, the number of dropdown rows and additional padding.
do
    local rows = math.ceil(#order / DD_COLS)
    -- Nudge the whole lower section up slightly so the checkbox block stays
    -- comfortably above the bottom action buttons.
    local y = -(HEADER_H + rows * 50) - 20 + CONTENT_NUDGE_Y + 6
    scaleLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", LEFT_PANEL_X, y)
end
scaleLabel:SetWidth(PREVIEW_W)
scaleLabel:SetJustifyH("CENTER")
scaleLabel:SetText("Combat Text Size:")

local slider = CreateFrame("Slider", addonName .. "ScaleSlider", frame, "OptionsSliderTemplate")
-- Match the width of the preview/edit boxes so the slider aligns perfectly
-- with the elements below.  A wider slider improves balance within the
-- options window.
slider:SetSize(PREVIEW_W, 16)
-- Anchor the slider below the combat text size label and centre it
-- horizontally.  This eliminates the previous left‑anchored layout which
-- appeared off centre.
slider:SetPoint("TOP", scaleLabel, "BOTTOM", 0, -8) -- temporary; we'll re-anchor after creating the value label

-- The OptionsSliderTemplate adds its own "Text" label which can overlap with
-- our custom scale value and the "Combat Text Size" label. Hide it for a
-- cleaner, more predictable layout across versions.
do
    local sliderText = slider.Text or _G[slider:GetName() .. "Text"]
    if sliderText and sliderText.Hide then
        sliderText:Hide()
    end

    -- Re-anchor the built-in Low/High labels flush with the ends of the bar.
    local low = _G[slider:GetName() .. "Low"]
    local high = _G[slider:GetName() .. "High"]
    if low and high then
        if low.ClearAllPoints then low:ClearAllPoints() end
        if high.ClearAllPoints then high:ClearAllPoints() end
        if low.SetPoint then low:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 0, -2) end
        if high.SetPoint then high:SetPoint("TOPRIGHT", slider, "BOTTOMRIGHT", 0, -2) end
    end
end

local function GetCombatTextScaleCVar()
    -- Blizzard renamed a number of Floating Combat Text settings in late 12.0 hotfixes
    -- (often appending a _v2 suffix). In some builds these also appear as console
    -- commands. Resolve the correct name/type at runtime.
    local candidates = {
        "WorldTextScale_v2",
        "WorldTextScale_V2",
        "WorldTextScale",
        "floatingCombatTextScale_v2",
        "floatingCombatTextScale_V2",
        "floatingCombatTextScale",
    }

    local name, commandType = ResolveConsoleSetting(candidates)
    if name then
        local value = GetCVarString(name)
        return name, commandType, value
    end

    return nil, nil, nil
end


local SCALE_FALLBACK_MIN, SCALE_FALLBACK_MAX, SCALE_STEP = 0.5, 5.0, 0.1
local scaleMin, scaleMax = SCALE_FALLBACK_MIN, SCALE_FALLBACK_MAX
local scaleStep = NormalizeSliderStep(SCALE_STEP, SCALE_FALLBACK_MIN, SCALE_FALLBACK_MAX)
local scaleDecimals = GetSliderDisplayDecimals(scaleStep, SCALE_FALLBACK_MIN, SCALE_FALLBACK_MAX)

local scaleCVar, scaleCVarCommandType, scaleCVarValue = GetCombatTextScaleCVar()
local scaleSupported = scaleCVar ~= nil

local scaleValue = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
scaleValue:ClearAllPoints()
scaleValue:SetWidth(PREVIEW_W)
scaleValue:SetJustifyH("CENTER")

-- Put the numeric value on its own line between the label and the slider so it
-- can never overlap the label text (the overlap shown in your screenshot).
scaleValue:SetPoint("TOP", scaleLabel, "BOTTOM", 0, -6)

-- Now that the value label exists, anchor the slider beneath it.
slider:ClearAllPoints()
slider:SetPoint("TOP", scaleValue, "BOTTOM", 0, -10)

local lastAppliedScale

local function UpdateScale(val)
    if not scaleSupported then return end
    val = SnapSliderToStep(val, scaleMin, scaleMax, scaleStep)

    if not NumbersNearlyEqual(lastAppliedScale, val, 0.000001) then
        lastAppliedScale = val
        ApplyConsoleSetting(scaleCVar, scaleCVarCommandType, tostring(val))
    end

    scaleValue:SetText(string.format("%0." .. tostring(scaleDecimals) .. "f", val))
end

local function RefreshScaleControl()
    scaleCVar, scaleCVarCommandType, scaleCVarValue = GetCombatTextScaleCVar()
    scaleSupported = scaleCVar ~= nil

    if scaleSupported then
        local discoveredMin, discoveredMax = ResolveNumericRange(scaleCVar)
        scaleMin, scaleMax = NormalizeSliderBounds(discoveredMin, discoveredMax, SCALE_FALLBACK_MIN, SCALE_FALLBACK_MAX)
        scaleStep = NormalizeSliderStep(SCALE_STEP, scaleMin, scaleMax)
        scaleDecimals = GetSliderDisplayDecimals(scaleStep, scaleMin, scaleMax)

        slider:SetMinMaxValues(scaleMin, scaleMax)
        slider:SetValueStep(scaleStep)
        SetSliderObeyStepCompat(slider, false)
        local low = _G[slider:GetName() .. "Low"]
        local high = _G[slider:GetName() .. "High"]
        local scaleEndpointFmt = "%0." .. tostring(scaleDecimals) .. "f"
        if low then low:SetText(string.format(scaleEndpointFmt, scaleMin)) end
        if high then high:SetText(string.format(scaleEndpointFmt, scaleMax)) end
        slider:Enable()
        scaleLabel:SetTextColor(1, 1, 1)
        local currentScale = tonumber(scaleCVarValue)
            or tonumber(GetCVarString(scaleCVar)) or 1.0
        local snappedScale = SnapSliderToStep(currentScale, scaleMin, scaleMax, scaleStep)
        lastAppliedScale = snappedScale
        slider:SetValue(snappedScale)
        scaleValue:SetText(string.format(scaleEndpointFmt, snappedScale))
        local settingScaleValue = false
        slider:SetScript("OnValueChanged", function(self, val)
            local snapped = SnapSliderToStep(val, scaleMin, scaleMax, scaleStep)
            if not settingScaleValue and math.abs((tonumber(val) or snapped) - snapped) > 0.00001 then
                settingScaleValue = true
                self:SetValue(snapped)
                settingScaleValue = false
            end
            scaleValue:SetText(string.format(scaleEndpointFmt, snapped))
            UpdateScale(snapped)
        end)
        slider:SetScript("OnMouseUp", function(self)
            local snapped = SnapSliderToStep(self:GetValue(), scaleMin, scaleMax, scaleStep)
            self:SetValue(snapped)
            UpdateScale(snapped)
        end)
        slider:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Drag to adjust combat text size", 1, 1, 1)
            GameTooltip:AddLine(string.format("Range: %0." .. tostring(scaleDecimals) .. "f to %0." .. tostring(scaleDecimals) .. "f", scaleMin, scaleMax), 0.9, 0.9, 0.9)
            GameTooltip:Show()
        end)
    else
        lastAppliedScale = nil
        slider:Disable()
        scaleLabel:SetTextColor(0.5, 0.5, 0.5)
        local low = _G[slider:GetName() .. "Low"]
        local high = _G[slider:GetName() .. "High"]
        if low then low:SetText("") end
        if high then high:SetText("") end
        scaleValue:SetText("|cff888888N/A|r")
        slider:SetScript("OnValueChanged", nil)
        slider:SetScript("OnMouseUp", nil)
        slider:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Combat text size is unavailable in this game client.", nil, nil, nil, nil, true)
            GameTooltip:Show()
        end)
    end
    slider:SetScript("OnLeave", GameTooltip_Hide)
end

RefreshScaleControl()

-- 6) PREVIEW & EDIT ---------------------------------------------------------
local PREVIEW_BOX_H = 84

-- Fixed-size preview "textbox" so the preview area stays consistent between fonts.
local previewBox = CreateFrame("Frame", addonName .. "PreviewBox", frame, backdropTemplate)
previewBox:SetSize(PREVIEW_W, PREVIEW_BOX_H)
previewBox:ClearAllPoints()
previewBox:SetPoint("TOP", slider, "BOTTOM", 0, -30)
previewBox:SetBackdrop({
    bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile     = true, tileSize = 16,
    edgeSize = 12,
    insets   = { left = 3, right = 3, top = 3, bottom = 3 },
})
-- Darker preview background improves contrast against bright scenes.
previewBox:SetBackdropColor(0, 0, 0, 0.55)
previewBox:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)

-- Font name label above the preview box (renders using the selected font)
previewHeaderFS = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
previewHeaderFS:SetPoint("BOTTOM", previewBox, "TOP", 0, 6)
previewHeaderFS:SetWidth(PREVIEW_W - 10)
previewHeaderFS:SetJustifyH("CENTER")
previewHeaderFS:SetText("Default")

-- Ensure no preview text bleeds outside the box on any client
if previewBox.SetClipsChildren then pcall(previewBox.SetClipsChildren, previewBox, true) end

preview = previewBox:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
preview:ClearAllPoints()
-- Nudge down slightly: some decorative fonts draw a few pixels above their
-- reported ascent and can otherwise clip at the very top when the box clips.
preview:SetPoint("CENTER", previewBox, "CENTER", 0, -1)
preview:SetWidth(PREVIEW_W - 10)
preview:SetJustifyH("CENTER")
if preview.SetJustifyV then pcall(preview.SetJustifyV, preview, "MIDDLE") end
preview:SetText("12345")
-- Conservative fallback height budget for clients that return 0 sizes while hidden.
preview.__fmMaxH = PREVIEW_BOX_H - 16

-- Apply a default preview font. GameFontNormalLarge should normally exist,
-- but we fall back to the current FontObject if it does not to avoid errors.
SetPreviewFont(GameFontNormalLarge or (preview.GetFontObject and preview:GetFontObject()), DEFAULT_FONT_PATH)
if UpdatePreviewHeaderText then UpdatePreviewHeaderText("Default", DEFAULT_FONT_PATH, true) end

editBox = CreateFrame("EditBox", addonName .. "PreviewEdit", frame, "InputBoxTemplate")
editBox:SetSize(PREVIEW_W, 24)
editBox:ClearAllPoints()
editBox:SetPoint("TOP", previewBox, "BOTTOM", 0, -8)
editBox:SetAutoFocus(false)
editBox:SetText("12345")
editBox:SetScript("OnTextChanged", function(self) preview:SetText(self:GetText()) end)

RefreshPreviewTextFromEditBox = function()
    if editBox and preview and editBox.GetText and preview.SetText then
        local txt = editBox:GetText() or ""
        preview:SetText("")
        preview:SetText(txt)
    end
end

-- Discard un-applied font previews whenever the window closes.
-- This ensures that reopening the addon always reflects the *currently applied*
-- combat text font (saved in FontMagicDB, or Blizzard default when none is saved),
-- and prevents a rare race where a queued next-frame sizing pass from a preview
-- can overwrite the correct font after reopening.
SyncPreviewToAppliedFont = function()
    if not (preview and editBox) then return end

    local key = FontMagicDB and FontMagicDB.selectedFont
    local path, grp, fname
    local label, isDef = "Default", true

    if type(key) == "string" and key ~= "" then
        path, grp, fname = ResolveFontPathFromKey(key)
        if fname then
            label = DisplayNameForFont(fname)
            isDef = false
        end
    end

    if type(path) ~= "string" or path == "" then
        CaptureBlizzardDefaultFonts()
        path = DEFAULT_DAMAGE_TEXT_FONT or DEFAULT_COMBAT_TEXT_FONT or DEFAULT_FONT_PATH or "Fonts\\FRIZQT__.TTF"
        label, isDef = "Default", true
    end

    if SetPreviewFont then
        SetPreviewFont(GameFontNormalLarge or (preview.GetFontObject and preview:GetFontObject()), path)
    end
    if UpdatePreviewHeaderText then
        UpdatePreviewHeaderText(label, path, isDef)
    end
    if preview.SetText and editBox.GetText then
        preview:SetText(editBox:GetText() or "")
    end
end

frame:SetScript("OnHide", function()
    pendingFont = nil
    -- Cancel any queued sizing pass that was scheduled by a previewed font.
    __fmPreviewToken = (__fmPreviewToken or 0) + 1

    if frame.__fmResetDialog and frame.__fmResetDialog.Hide then
        frame.__fmResetDialog:Hide()
    end

    -- Put the preview back to the actually applied font so reopening is consistent.
    pcall(SyncPreviewToAppliedFont)
end)
-- 7) COMBAT TEXT OPTIONS (EXPANDABLE PANEL) --------------------------------

-- Right-side expandable panel
local isExpanded = false
local RIGHT_PANEL_W = PREVIEW_W + 52
local PANEL_GAP = 16
local incomingInit = false

-- Collapsible combat text options button (integrated label + arrow for a cleaner look)
local expandBtn = CreateFrame("Button", addonName .. "ExpandBtn", frame, "UIPanelButtonTemplate")
expandBtn:SetSize(260, 24)
expandBtn:SetPoint("BOTTOMRIGHT", (frame.__fmLeftAnchor or frame), "BOTTOMRIGHT", -16, 44)

local function UpdateExpandToggleText()
    local txt = isExpanded and "Hide Combat Text Options <" or "Show Combat Text Options >"
    if expandBtn and expandBtn.SetText then
        expandBtn:SetText(txt)
    end
    -- If the tooltip is currently shown for this button, update immediately.
    if GameTooltip and GameTooltip.GetOwner and GameTooltip:GetOwner() == expandBtn then
        GameTooltip:SetText(txt, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end
end

UpdateExpandToggleText()

expandBtn:SetFrameStrata("HIGH")
expandBtn:SetFrameLevel((frame:GetFrameLevel() or 0) + 50)
expandBtn:SetScript("OnEnter", function(self)
    ShowTooltip(self, "ANCHOR_RIGHT", isExpanded and "Combat Text Options <" or "Combat Text Options >")
end)
expandBtn:SetScript("OnLeave", HideTooltip)

-- Container + scroll area (hidden when collapsed)
local combatPanel = CreateFrame("Frame", addonName .. "CombatPanel", frame, backdropTemplate)
combatPanel:ClearAllPoints()
combatPanel:SetPoint("TOPLEFT", frame, "TOPRIGHT", PANEL_GAP, -HEADER_H)
combatPanel:SetPoint("BOTTOMLEFT", frame, "BOTTOMRIGHT", PANEL_GAP, 80) -- leave room for the expand toggle above Close
combatPanel:SetWidth(RIGHT_PANEL_W)
combatPanel:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
})
-- Darker/less translucent so the list remains readable over bright scenes.
combatPanel:SetBackdropColor(0, 0, 0, 0.92)
combatPanel:SetFrameStrata("HIGH")
combatPanel:SetFrameLevel((frame:GetFrameLevel() or 0) + 40)
combatPanel:Hide()


local combatPopShadow = frame:CreateTexture(nil, "BACKGROUND")
combatPopShadow:SetPoint("TOPLEFT", combatPanel, "TOPLEFT", -PANEL_GAP, 0)
combatPopShadow:SetPoint("BOTTOMLEFT", combatPanel, "BOTTOMLEFT", -PANEL_GAP, 0)
combatPopShadow:SetWidth(PANEL_GAP)
combatPopShadow:SetColorTexture(0, 0, 0, 0.25)
combatPopShadow:Hide()

local combatDivider = combatPanel:CreateTexture(nil, "ARTWORK")
combatDivider:SetPoint("TOPLEFT", combatPanel, "TOPLEFT", 0, 0)
combatDivider:SetPoint("BOTTOMLEFT", combatPanel, "BOTTOMLEFT", 0, 0)
combatDivider:SetWidth(1)
combatDivider:SetColorTexture(1, 1, 1, 0.12)


local combatTitle = combatPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
combatTitle:SetPoint("TOPLEFT", combatPanel, "TOPLEFT", 10, -8)
combatTitle:SetText("Combat Text Options")

combatMetadataRefreshBtn = CreateFrame("Button", nil, combatPanel, "UIPanelButtonTemplate")
combatMetadataRefreshBtn:SetSize(130, 20)
combatMetadataRefreshBtn:SetPoint("TOPRIGHT", combatPanel, "TOPRIGHT", -10, -6)
combatMetadataRefreshBtn:SetText("Refresh setting data")
combatMetadataRefreshBtn:SetScript("OnClick", function()
    RefreshCombatMetadataAndUI()
end)
AttachTooltip(combatMetadataRefreshBtn, "Refresh setting data", "Re-reads combat setting metadata from the current client. Use this if slider ranges look wrong after login, then /reload if needed.")

combatMetadataStatusFS = combatPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
combatMetadataStatusFS:SetPoint("TOPLEFT", combatPanel, "TOPLEFT", 10, -24)
combatMetadataStatusFS:SetPoint("RIGHT", combatMetadataRefreshBtn, "LEFT", -8, 0)
combatMetadataStatusFS:SetJustifyH("LEFT")
combatMetadataStatusFS:SetText("If any slider range looks incorrect, click Refresh setting data once.")

local combatScroll = CreateFrame("ScrollFrame", addonName .. "CombatScroll", combatPanel, "UIPanelScrollFrameTemplate")
combatScroll:SetPoint("TOPLEFT", combatPanel, "TOPLEFT", 8, -50)
combatScroll:SetPoint("BOTTOMRIGHT", combatPanel, "BOTTOMRIGHT", -30, 10)

local combatContent = CreateFrame("Frame", nil, combatScroll)
combatContent:SetPoint("TOPLEFT", 0, 0)
combatContent:SetSize(PREVIEW_W + 18, 1)
combatScroll:SetScrollChild(combatContent)

combatScroll:EnableMouseWheel(true)
combatScroll:SetScript("OnMouseWheel", function(self, delta)
    local step = 40
    local newOffset = self:GetVerticalScroll() - delta * step
    if newOffset < 0 then newOffset = 0 end
    local max = self:GetVerticalScrollRange()
    if newOffset > max then newOffset = max end
    self:SetVerticalScroll(newOffset)
end)

-- ---------------------------------------------------------------------------
-- Combat text toggle definitions
-- ---------------------------------------------------------------------------

local function MakeCVarCandidates(primary, ...)
    local t = { primary }
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if v and v ~= "" then table.insert(t, v) end
    end
    if type(primary) == "string" then
        table.insert(t, primary .. "_v2")
        table.insert(t, primary .. "_V2")
        table.insert(t, primary .. "_v3")
        table.insert(t, primary .. "_V3")
    end
    return t
end

local COMBAT_BOOL_DEFS = {
    -- Core
    { key="enableFloatingCombatText",  candidates={ "enableFloatingCombatText", "enableCombatText" },
      label="Show combat text",
      tip="Turns Blizzard\'s floating combat text on or off (numbers and messages shown in the world).\n\nThis does not affect the combat log." },

    -- Outgoing (numbers shown over enemies / targets)
    { key="combatDamage",             candidates=MakeCVarCandidates("floatingCombatTextCombatDamage"),
      label="Outgoing Damage",
      tip="Shows damage numbers over hostile targets when you deal damage." },

    { key="combatHealing",            candidates=MakeCVarCandidates("floatingCombatTextCombatHealing"),
      label="Outgoing Healing",
      tip="Shows healing numbers over the target when you heal them." },

    { key="combatHealingAbsorbSelf",  candidates=MakeCVarCandidates("floatingCombatTextCombatHealingAbsorbSelf"),
      label="Shields (On You)",
      tip="Shows a message when you gain an absorb shield (e.g., Power Word: Shield)." },

    { key="combatHealingAbsorbTarget", candidates=MakeCVarCandidates("floatingCombatTextCombatHealingAbsorbTarget"),
      label="Shields (On Target)",
      tip="Shows the amount of absorb shield you apply to your target." },

    { key="periodicDamage",           candidates={ "floatingCombatTextCombatLogPeriodicSpells", "floatingCombatTextPeriodicDamage" },
      label="Periodic Damage",
      tip="Shows damage from periodic effects (DoTs) like Rend or Shadow Word: Pain." },

    { key="petDamage",                candidates={ "floatingCombatTextPetMeleeDamage", "floatingCombatTextPetDamage" },
      label="Pet Damage (Melee)",
      tip="Shows damage caused by your pet\'s melee attacks." },

    { key="petSpellDamage",           candidates=MakeCVarCandidates("floatingCombatTextPetSpellDamage"),
      label="Pet Damage (Spells)",
      tip="Shows damage caused by your pet\'s spells and special abilities." },

    -- Defensive / informational
    { key="dodgeParryMiss",           candidates=MakeCVarCandidates("floatingCombatTextDodgeParryMiss"),
      label="Avoidance (Dodge/Parry/Miss)",
      tip="Shows when attacks against you are dodged, parried, or miss." },

    { key="damageReduction",          candidates=MakeCVarCandidates("floatingCombatTextDamageReduction"),
      label="Damage Reduction (Resists)",
      tip="Shows when you resist taking damage from attacks or spells." },

    { key="reactives",                candidates=MakeCVarCandidates("floatingCombatTextReactives"),
      label="Spell Alerts",
      tip="Shows alerts when certain important events occur.\n\n(If you already use a modern proc-alert system, this may be redundant.)" },

    { key="combatState",              candidates=MakeCVarCandidates("floatingCombatTextCombatState"),
      label="Enter/Leave Combat",
      tip="Shows a message when you enter or leave combat." },

    { key="lowManaHealth",            candidates=MakeCVarCandidates("floatingCombatTextLowManaHealth"),
      label="Low Mana & Health",
      tip="Shows a warning when you fall below 20% mana or health." },

    { key="energyGains",              candidates=MakeCVarCandidates("floatingCombatTextEnergyGains"),
      label="Resource Gains",
      tip="Shows instant gains of resources like mana, rage, energy, chi, and similar." },

    { key="periodicEnergyGains",      candidates=MakeCVarCandidates("floatingCombatTextPeriodicEnergyGains"),
      label="Periodic Resource Gains",
      tip="Shows periodic (regen/tick) gains of resources like mana, rage, and energy." },

    { key="honorGains",               candidates=MakeCVarCandidates("floatingCombatTextHonorGains"),
      label="Honor Gains",
      tip="Shows the honor you gain from killing other players." },

    { key="repChanges",               candidates=MakeCVarCandidates("floatingCombatTextRepChanges"),
      label="Reputation Changes",
      tip="Shows a message when you gain or lose reputation with a faction." },

    { key="comboPoints",              candidates=MakeCVarCandidates("floatingCombatTextComboPoints"),
      label="Combo Points",
      tip="Shows your current combo point count each time you gain a combo point." },

    { key="auras",                    candidates=MakeCVarCandidates("floatingCombatTextAuras"),
      label="Auras Gained/Lost",
      tip="Shows a message when you gain or lose a buff or debuff." },

    { key="friendlyHealers",          candidates=MakeCVarCandidates("floatingCombatTextFriendlyHealers"),
      label="Friendly Healer Names",
      tip="Shows the name of a friendly caster when they heal you." },

    { key="spellMechanics",           candidates=MakeCVarCandidates("floatingCombatTextSpellMechanics"),
      label="Effects (On Your Target)",
      tip="Displays effect messages (e.g., Silence and Snare) on your current target." },

    { key="spellMechanicsOther",      candidates=MakeCVarCandidates("floatingCombatTextSpellMechanicsOther"),
      label="Effects (Other Players\' Targets)",
      tip="Displays effect messages (e.g., Silence and Snare) on other players\' targets.\n\nThis can add a lot of extra text in groups/raids." },

    { key="allSpellMechanics",        candidates=MakeCVarCandidates("floatingCombatTextAllSpellMechanics"),
      label="Effects (All)",
      tip="Shows all available effect messages related to spell mechanics.\n\nIf you\'re seeing duplicates, disable this and use the more specific Effects options instead." },
}

local DEF_BY_KEY = {}
for _, d in ipairs(COMBAT_BOOL_DEFS) do DEF_BY_KEY[d.key] = d end

-- extra boolean CVars that match floatingCombatText* but aren't in our curated list
local EXTRA_CVAR_PREFIX = "floatingCombatText"
local EXTRA_BLACKLIST = {
    -- curated / already exposed (avoid duplicates)
    enableFloatingCombatText = true,
    enableCombatText = true,

    floatingCombatTextCombatDamage = true,
    floatingCombatTextCombatHealing = true,
    floatingCombatTextCombatHealingAbsorbSelf = true,
    floatingCombatTextCombatHealingAbsorbTarget = true,

    floatingCombatTextCombatLogPeriodicSpells = true,
    floatingCombatTextPeriodicDamage = true,

    floatingCombatTextPetMeleeDamage = true,
    floatingCombatTextPetDamage = true,
    floatingCombatTextPetSpellDamage = true,

    floatingCombatTextDodgeParryMiss = true,
    floatingCombatTextDamageReduction = true,
    floatingCombatTextReactives = true,
    floatingCombatTextCombatState = true,
    floatingCombatTextLowManaHealth = true,
    floatingCombatTextEnergyGains = true,
    floatingCombatTextPeriodicEnergyGains = true,
    floatingCombatTextHonorGains = true,
    floatingCombatTextRepChanges = true,
    floatingCombatTextComboPoints = true,
    floatingCombatTextAuras = true,
    floatingCombatTextFriendlyHealers = true,
    floatingCombatTextSpellMechanics = true,
    floatingCombatTextSpellMechanicsOther = true,
    floatingCombatTextAllSpellMechanics = true,

    -- known non-useful / off-topic for this add-on
    floatingCombatTextCombatDamageStyle = true, -- no longer used in modern clients
    enablePetBattleCombatText = true,
    enablePetBattleFloatingCombatText = true,
}

-- Forward declaration so earlier functions can call this helper before its definition below.
local CollectExtraBoolCombatTextCVars

local function PrettyCVarLabel(cvar)
    local s = tostring(cvar or "")
    -- Hide internal version suffixes like _v2/_v3 from user-facing labels.
    s = s:gsub("_[vV]%d+$", "")
    s = s:gsub("^floatingCombatText", "")
    s = s:gsub("([A-Z])", " %1")
    s = s:gsub("_", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("%s+", " ")
    if s == "" then s = tostring(cvar) end
    return s
end

-- Human-readable explanations for extra floatingCombatText* CVars (advanced section).
-- These are not guaranteed to exist on every WoW client; anything unmapped will fall back to a generic explanation.
local EXTRA_CVAR_EXPLANATIONS = {
    floatingCombatTextDodgeParryMiss      = "Shows Dodge / Parry / Miss messages as floating combat text.",
    floatingCombatTextDamageReduction     = "Shows absorbs, blocks, resists, and other damage reduction messages as floating combat text.",
    floatingCombatTextReactives           = "Shows reactive proc messages (for example: 'Overpower!' / 'Revenge!') as floating combat text (when supported).",
    floatingCombatTextCombatState         = "Shows combat state notifications (entering/leaving combat) as floating combat text.",
    floatingCombatTextLowManaHealth       = "Shows low health/mana warnings as floating combat text.",
    floatingCombatTextEnergyGains         = "Shows resource gains (mana/rage/energy/runic power, etc.) as floating combat text.",
    floatingCombatTextPeriodicEnergyGains = "Shows periodic resource gains (from buffs/regen) as floating combat text.",
    floatingCombatTextHonorGains          = "Shows honor gains as floating combat text (when supported).",
    floatingCombatTextRepChanges          = "Shows reputation changes as floating combat text (when supported).",
    floatingCombatTextComboPoints         = "Shows combo point changes as floating combat text (when supported).",
    floatingCombatTextAuras               = "Shows aura notifications (gains/fades) as floating combat text (when supported).",
    floatingCombatTextFriendlyHealers     = "Shows friendly healer messages as floating combat text (when supported).",
    floatingCombatTextSpellMechanics      = "Shows spell mechanic messages (like 'Interrupted', 'Immune', 'Dispelled') as floating combat text (when supported).",
    floatingCombatTextSpellMechanicsOther = "Shows additional spell mechanic messages as floating combat text (when supported).",
    floatingCombatTextAllSpellMechanics   = "Shows a broader set of spell mechanic messages as floating combat text (when supported).",
}

local function GetExtraCombatTextCVarTooltip(cvar)
    local name = tostring(cvar or "")
    local base = name:gsub("_[vV]%d+$", "")
    local expl = EXTRA_CVAR_EXPLANATIONS[name] or EXTRA_CVAR_EXPLANATIONS[base]

    if not expl then
        local pretty = PrettyCVarLabel(base)
        if pretty and pretty ~= "" then
            expl = "Advanced combat text option detected on this client: toggles \"" .. pretty .. "\"."
        else
            expl = "Advanced combat text option detected on this client."
        end
    end

    expl = expl .. "\n\nAvailability and behavior vary by WoW version and UI mods. If you're unsure, leave this at Blizzard's default."
    if name ~= "" then
        expl = expl .. "\n\nTechnical name: " .. name
    end
    return expl
end


local function GetLiveBoolCVar(name)
    local v = GetCVarString(name)
    if v == nil then return nil end
    local n = tonumber(v)
    if n ~= nil then return n == 1 end
    v = tostring(v):lower()
    return (v == "1" or v == "true" or v == "on")
end

local function ShowTooltip(owner, anchor, header, body)
    if not (GameTooltip and owner) then return end
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    GameTooltip:SetText(header or "", 1, 1, 1, 1, true)
    if body and body ~= "" then
        GameTooltip:AddLine(body, 0.9, 0.9, 0.9, true)
    end
    GameTooltip:Show()
end

local function HideTooltip()
    if GameTooltip then
        GameTooltip:Hide()
    end
end

local function AttachTooltip(widget, header, body)
    if not widget then return end
    widget:SetScript("OnEnter", function(self)
        ShowTooltip(self, "ANCHOR_RIGHT", header, body)
    end)
    widget:SetScript("OnLeave", HideTooltip)
end

-- Incoming damage/healing toggles (implemented via COMBAT_TEXT_TYPE_INFO filtering where available)
local function EnsureIncomingReady()
    if incomingInit then return true end

    -- try to load Blizzard_CombatText so COMBAT_TEXT_TYPE_INFO exists on clients that ship it as a load-on-demand addon
    if type(safeLoadAddOn) == "function" then
        pcall(safeLoadAddOn, "Blizzard_CombatText")
    end

    if type(COMBAT_TEXT_TYPE_INFO) ~= "table" then
        return false
    end

    incomingInit = true

    -- capture Blizzard's baseline tables so we can restore after temporary overrides
    originalInfo = originalInfo or {}
    for k, v in pairs(COMBAT_TEXT_TYPE_INFO) do
        originalInfo[k] = v
    end
    originalInfo.PERIODIC_HEAL      = COMBAT_TEXT_TYPE_INFO.PERIODIC_HEAL
    originalInfo.PERIODIC_HEAL_CRIT = COMBAT_TEXT_TYPE_INFO.PERIODIC_HEAL_CRIT

    return true
end

local function SetIncomingDamageEnabled(enabled)
    if not EnsureIncomingReady() then return end
    if type(COMBAT_TEXT_TYPE_INFO) ~= "table" then return end

    if not enabled then
        COMBAT_TEXT_TYPE_INFO.DAMAGE = nil
        COMBAT_TEXT_TYPE_INFO.DAMAGE_CRIT = nil
        COMBAT_TEXT_TYPE_INFO.SPELL_DAMAGE = nil
        COMBAT_TEXT_TYPE_INFO.SPELL_DAMAGE_CRIT = nil
    else
        COMBAT_TEXT_TYPE_INFO.DAMAGE = originalInfo.DAMAGE
        COMBAT_TEXT_TYPE_INFO.DAMAGE_CRIT = originalInfo.DAMAGE_CRIT
        COMBAT_TEXT_TYPE_INFO.SPELL_DAMAGE = originalInfo.SPELL_DAMAGE
        COMBAT_TEXT_TYPE_INFO.SPELL_DAMAGE_CRIT = originalInfo.SPELL_DAMAGE_CRIT
    end
end

local function SetIncomingHealingEnabled(enabled)
    if not EnsureIncomingReady() then return end
    if type(COMBAT_TEXT_TYPE_INFO) ~= "table" then return end

    if not enabled then
        COMBAT_TEXT_TYPE_INFO.HEAL = nil
        COMBAT_TEXT_TYPE_INFO.HEAL_CRIT = nil
        COMBAT_TEXT_TYPE_INFO.PERIODIC_HEAL = nil
        COMBAT_TEXT_TYPE_INFO.PERIODIC_HEAL_CRIT = nil
    else
        COMBAT_TEXT_TYPE_INFO.HEAL = originalInfo.HEAL
        COMBAT_TEXT_TYPE_INFO.HEAL_CRIT = originalInfo.HEAL_CRIT
        COMBAT_TEXT_TYPE_INFO.PERIODIC_HEAL = originalInfo.PERIODIC_HEAL
        COMBAT_TEXT_TYPE_INFO.PERIODIC_HEAL_CRIT = originalInfo.PERIODIC_HEAL_CRIT
    end
end

local function ApplyIncomingOverrides()
    if type(FontMagicDB) ~= "table" or type(FontMagicDB.incomingOverrides) ~= "table" then return end
    if not EnsureIncomingReady() then return end

    if FontMagicDB.incomingOverrides.incomingDamage ~= nil then
        SetIncomingDamageEnabled(FontMagicDB.incomingOverrides.incomingDamage and true or false)
    end
    if FontMagicDB.incomingOverrides.incomingHealing ~= nil then
        SetIncomingHealingEnabled(FontMagicDB.incomingOverrides.incomingHealing and true or false)
    end
end

local function ApplyCombatOverrides()
    if type(FontMagicDB) == "table" and type(FontMagicDB.combatOverrides) == "table" then
        for key, val in pairs(FontMagicDB.combatOverrides) do
            local def = DEF_BY_KEY[key]
            if def then
                local n, ct = ResolveConsoleSetting(def.candidates)
                if n and ct == 0 then
                    ApplyConsoleSetting(n, ct, val and "1" or "0")
                end
            end
        end
    end

    if type(FontMagicDB) == "table" and type(FontMagicDB.extraCombatOverrides) == "table" then
        for cvar, val in pairs(FontMagicDB.extraCombatOverrides) do
            local n, ct = ResolveConsoleSetting(cvar)
            if n and ct == 0 then
                ApplyConsoleSetting(n, ct, val and "1" or "0")
            end
        end
    end
end



-- Best-effort: raise Blizzard floating combat text above nameplates.
-- This is not a CVar; it adjusts frame strata/level at runtime and restores it when disabled.
local combatTextLayerBackup = {}

local function ApplyCombatTextAboveNameplatesNow(want)
    local names = { "CombatText", "CombatTextFrame", "FloatingCombatTextFrame" }

    for _, n in ipairs(names) do
        local f = _G and _G[n]
        if f and type(f.SetFrameStrata) == "function" then
            if want then
                if not combatTextLayerBackup[n] then
                    local okS, s = pcall(f.GetFrameStrata, f)
                    local okL, l = pcall(f.GetFrameLevel, f)
                    combatTextLayerBackup[n] = { strata = okS and s or nil, level = okL and l or nil }
                end
                -- Put combat text above most nameplate add-ons (best-effort).
                pcall(f.SetFrameStrata, f, "TOOLTIP")
                if type(f.SetFrameLevel) == "function" and type(f.GetFrameLevel) == "function" then
                    local lvl = f:GetFrameLevel() or 0
                    if lvl < 10000 then pcall(f.SetFrameLevel, f, 10000) end
                end
            else
                local b = combatTextLayerBackup[n]
                if b then
                    if b.strata then pcall(f.SetFrameStrata, f, b.strata) end
                    if b.level and type(f.SetFrameLevel) == "function" then pcall(f.SetFrameLevel, f, b.level) end
                end
            end
        end
    end
end

local function ApplyCombatTextAboveNameplates(enabled)
    local want = (enabled and true or false)
    ApplyCombatTextAboveNameplatesNow(want)

    -- Some nameplate add-ons (and Blizzard nameplates) adjust strata after load.
    -- Re-apply shortly after enabling so combat text reliably stays in front.
    if want and type(C_Timer) == "table" and type(C_Timer.After) == "function" then
        C_Timer.After(0.2, function()
            if FontMagicDB and FontMagicDB.combatTextAboveNameplates then
                ApplyCombatTextAboveNameplatesNow(true)
            end
        end)
        C_Timer.After(1.0, function()
            if FontMagicDB and FontMagicDB.combatTextAboveNameplates then
                ApplyCombatTextAboveNameplatesNow(true)
            end
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Combat text master toggle (Show/Hide combat text without losing per-type settings)
-- ---------------------------------------------------------------------------

local function GetCombatTextMasterSettingList()
    -- Returns a list of settings we can toggle for the "Show combat text" master checkbox.
    -- These are usually CVars (commandType == 0), but on some clients the console index
    -- can classify real CVars as non-CVar console commands. We still include those so the
    -- master toggle stays usable across versions (/console can set them).
    local list, seen = {}, {}

    local function addSetting(name, commandType)
        if not name or commandType == nil then return end
        if seen[name] then return end
        seen[name] = true
        table.insert(list, { name = name, ct = commandType })
    end

    for _, def in ipairs(COMBAT_BOOL_DEFS) do
        local n, ct = ResolveConsoleSetting(def.candidates)
        if n and ct ~= nil then
            addSetting(n, ct)
        end
    end

    local extras = CollectExtraBoolCombatTextCVars()
    for _, cvar in ipairs(extras) do
        local n, ct = ResolveConsoleSetting(cvar)
        if n and ct ~= nil then
            addSetting(n, ct)
        end
    end

    return list
end

local function IsCombatTextMasterSupported()
    if EnsureIncomingReady() then
        return true
    end
    local list = GetCombatTextMasterSettingList()
    return (#list > 0)
end

local function IsCombatTextMasterCurrentlyEnabled()
    -- If FontMagic hid combat text via the master toggle, reflect that immediately.
    if FontMagicDB and FontMagicDB.combatMasterOffByFontMagic and type(FontMagicDB.combatMasterSnapshot) == "table" then
        return false
    end

    local gateIsTrue = false
    local gateIsFalse = false
    local sawAny = false

    -- Some clients use enableFloatingCombatText while others use enableCombatText.
    -- Treat the gate as a strong signal, but not a hard requirement (some builds can still
    -- show certain combat text types even when the gate is off).
    do
        local gateDef = DEF_BY_KEY and DEF_BY_KEY["enableFloatingCombatText"]
        local candidates = (gateDef and gateDef.candidates) or MakeCVarCandidates("enableFloatingCombatText", "enableCombatText")
        local n, ct = ResolveConsoleSetting(candidates)
        if n and ct == 0 then
            local v = GetLiveBoolCVar(n)
            if v ~= nil then
                sawAny = true
                if v == true then gateIsTrue = true end
                if v == false then gateIsFalse = true end
            end
        end
    end

    -- If any readable combat text toggle is on, we consider combat text enabled.
    for _, entry in ipairs(GetCombatTextMasterSettingList()) do
        if entry and entry.ct == 0 and entry.name then
            local v = GetLiveBoolCVar(entry.name)
            if v ~= nil then
                sawAny = true
            end
            if v == true then
                return true
            end
        end
    end

    -- Incoming combat text can be implemented via COMBAT_TEXT_TYPE_INFO on some clients.
    if EnsureIncomingReady() and type(COMBAT_TEXT_TYPE_INFO) == "table" then
        local dmgEnabled = (COMBAT_TEXT_TYPE_INFO.DAMAGE ~= nil or COMBAT_TEXT_TYPE_INFO.SPELL_DAMAGE ~= nil)
        local healEnabled = (COMBAT_TEXT_TYPE_INFO.HEAL ~= nil or COMBAT_TEXT_TYPE_INFO.PERIODIC_HEAL ~= nil)
        if dmgEnabled or healEnabled then
            return true
        end
    end

    if gateIsTrue then
        return true
    end

    -- If we observed at least one relevant value and none were on, treat as disabled.
    if gateIsFalse and sawAny then
        return false
    end

    -- If no values are reportable yet (or we only have non-readable console commands),
    -- default to enabled so the UI doesn't show an unchecked box while combat text is visible.
    if not sawAny then
        return true
    end

    return false
end

local function CaptureCombatTextMasterSnapshot()
    FontMagicDB = FontMagicDB or {}
    local snap = { cvars = {}, incoming = {} }

    -- Best-effort: if we can't read a setting (console-command style), store a value that
    -- will turn it back on when the user re-enables combat text.
    local wasEnabled = IsCombatTextMasterCurrentlyEnabled() and true or false

    for _, entry in ipairs(GetCombatTextMasterSettingList()) do
        if entry and entry.name then
            local val = GetCVarString(entry.name)

            -- If it isn't readable but it's toggle-able via /console, preserve "on" vs "off"
            -- at the coarse level so we can restore something sensible.
            if val == nil and entry.ct ~= 0 then
                val = wasEnabled and "1" or "0"
            end

            snap.cvars[entry.name] = val
        end
    end

    if EnsureIncomingReady() and type(COMBAT_TEXT_TYPE_INFO) == "table" then
        snap.incoming.damage = (COMBAT_TEXT_TYPE_INFO.DAMAGE ~= nil or COMBAT_TEXT_TYPE_INFO.SPELL_DAMAGE ~= nil) and true or false
        snap.incoming.heal   = (COMBAT_TEXT_TYPE_INFO.HEAL ~= nil or COMBAT_TEXT_TYPE_INFO.PERIODIC_HEAL ~= nil) and true or false
    end

    FontMagicDB.combatMasterSnapshot = snap
    FontMagicDB.combatMasterOffByFontMagic = true
end

local function ApplyCombatTextMasterDisabled()
    for _, entry in ipairs(GetCombatTextMasterSettingList()) do
        if entry and entry.name then
            local n, ct = ResolveConsoleSetting(entry.name)
            if n and ct ~= nil then
                ApplyConsoleSetting(n, ct, "0")
            end
        end
    end

    if EnsureIncomingReady() then
        SetIncomingDamageEnabled(false)
        SetIncomingHealingEnabled(false)
    end
end

local function ApplyCombatTextMasterEnabledFromSnapshot(snap)
    if type(snap) ~= "table" or type(snap.cvars) ~= "table" then
        return false
    end

    local appliedAny = false

    for name, val in pairs(snap.cvars) do
        if val ~= nil then
            local n, ct = ResolveConsoleSetting(name)
            if n and ct ~= nil then
                ApplyConsoleSetting(n, ct, tostring(val))
                appliedAny = true
            end
        end
    end

    if EnsureIncomingReady() and type(snap.incoming) == "table" then
        local did = false
        if snap.incoming.damage ~= nil then
            SetIncomingDamageEnabled(snap.incoming.damage and true or false)
            did = true
        end
        if snap.incoming.heal ~= nil then
            SetIncomingHealingEnabled(snap.incoming.heal and true or false)
            did = true
        end
        if did then
            appliedAny = true
        end
    end

    return appliedAny
end

local function ApplyCombatTextMasterEnabledBaseline()
    -- Best-effort baseline so "Show combat text" actually shows something on most clients.
    do
        local gateDef = DEF_BY_KEY and DEF_BY_KEY["enableFloatingCombatText"]
        local candidates = (gateDef and gateDef.candidates) or MakeCVarCandidates("enableFloatingCombatText", "enableCombatText")
        local gateName, gateCt = ResolveConsoleSetting(candidates)
        if gateName and gateCt ~= nil then
            ApplyConsoleSetting(gateName, gateCt, "1")
        end
    end

    local dmgDef = DEF_BY_KEY and DEF_BY_KEY["combatDamage"]
    if dmgDef then
        local n, ct = ResolveConsoleSetting(dmgDef.candidates)
        if n and ct ~= nil then ApplyConsoleSetting(n, ct, "1") end
    end

    local healDef = DEF_BY_KEY and DEF_BY_KEY["combatHealing"]
    if healDef then
        local n, ct = ResolveConsoleSetting(healDef.candidates)
        if n and ct ~= nil then ApplyConsoleSetting(n, ct, "1") end
    end
end

local function SetCombatTextMasterEnabled(wantEnabled)
    if not IsCombatTextMasterSupported() then
        return
    end

    FontMagicDB = FontMagicDB or {}

    if wantEnabled then
        local snap = FontMagicDB.combatMasterSnapshot
        local restored = ApplyCombatTextMasterEnabledFromSnapshot(snap)
        if not restored then
            ApplyCombatTextMasterEnabledBaseline()
        end
        FontMagicDB.combatMasterSnapshot = nil
        FontMagicDB.combatMasterOffByFontMagic = nil
    else
        if not (FontMagicDB.combatMasterOffByFontMagic and type(FontMagicDB.combatMasterSnapshot) == "table") then
            CaptureCombatTextMasterSnapshot()
        end
        ApplyCombatTextMasterDisabled()
    end
end

local function UpdateMainCombatCheckboxes()
    if mainShowCombatTextCB and mainShowCombatTextCB.SetChecked then
        if not IsCombatTextMasterSupported() then
            if mainShowCombatTextCB.Disable then pcall(mainShowCombatTextCB.Disable, mainShowCombatTextCB) end
            -- If we can't control it on this client, default to showing it as enabled so the
            -- checkbox doesn't look "wrong" on first load.
            mainShowCombatTextCB:SetChecked(IsCombatTextMasterCurrentlyEnabled() and true or false)
        else
            if mainShowCombatTextCB.Enable then pcall(mainShowCombatTextCB.Enable, mainShowCombatTextCB) end
            mainShowCombatTextCB:SetChecked(IsCombatTextMasterCurrentlyEnabled() and true or false)
        end
    end
end

-- ---------------------------------------------------------------------------
-- UI builder
-- ---------------------------------------------------------------------------

local combatWidgets = {}
local BuildCombatOptionsUI
local RefreshCombatMetadataAndUI
local combatMetadataStatusFS
local combatMetadataRefreshBtn

local function ClearCombatWidgets()
    for _, w in ipairs(combatWidgets) do
        if w and w.Hide then w:Hide() end
        if w and w.SetParent then w:SetParent(nil) end
    end
    combatWidgets = {}
end

local function AddHeader(textLine, y)
    local fs = combatContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", combatContent, "TOPLEFT", 0, y)
    fs:SetPoint("TOPRIGHT", combatContent, "TOPRIGHT", -10, 0)
    fs:SetJustifyH("LEFT")
    fs:SetText(textLine)
    table.insert(combatWidgets, fs)
    return y - 18
end

local function AddSectionNote(y, textLine)
    local fs = combatContent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", combatContent, "TOPLEFT", 0, y)
    fs:SetPoint("TOPRIGHT", combatContent, "TOPRIGHT", -10, 0)
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    fs:SetTextColor(0.72, 0.72, 0.72)
    fs:SetText(textLine)
    table.insert(combatWidgets, fs)
    return y - 24
end

local function CreateOptionCheckbox(col, y, label, checked, onClick, tip)
    local x = (col == 0) and 0 or (CB_COL_W + CHECK_COL_GAP)
    local cb = CreateCheckbox(combatContent, label, 0, 0, checked, onClick)
    cb:ClearAllPoints()
    cb:SetPoint("TOPLEFT", combatContent, "TOPLEFT", x, y)

    -- Constrain the label so the two checkbox columns never overlap.
    local fs = cb and (cb.__fmLabelFS or GetCheckButtonLabelFS(cb))
    if fs then
        -- Use a slightly smaller font so longer labels still fit nicely.
        if fs.SetFontObject and type(GameFontHighlightSmall) ~= "nil" then
            pcall(fs.SetFontObject, fs, GameFontHighlightSmall)
        end
        if fs.SetWidth then fs:SetWidth(CB_COL_W - 34) end
        if fs.SetJustifyH then fs:SetJustifyH("LEFT") end
        if fs.SetWordWrap then fs:SetWordWrap(true) end
    end

    if tip then AttachTooltip(cb, label, tip) end
    table.insert(combatWidgets, cb)
    return cb
end

local function CreateOptionDropdown(y, label, selectedValue, values, onSelect, tip, enabled, disabledHint, hoverPreviewBuilder)
    if enabled == nil then enabled = true end

    local title = combatContent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    title:SetPoint("TOPLEFT", combatContent, "TOPLEFT", 0, y)
    title:SetText(label)
    if not enabled then
        title:SetTextColor(0.5, 0.5, 0.5)
    end
    table.insert(combatWidgets, title)

    local dd = CreateFrame("Frame", nil, combatContent, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", title, "BOTTOMLEFT", -14, -4)
    UIDropDownMenu_SetWidth(dd, CB_COL_W * 2 + CHECK_COL_GAP - 48)
    UIDropDownMenu_Initialize(dd, function(self, level)
        level = level or 1
        if level ~= 1 then return end
        ClearDropDownListDecorations(level)
        local buttonIndex = 0
        for _, infoData in ipairs(values) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = infoData.text
            info.checked = (selectedValue == infoData.value)
            info.disabled = not enabled
            info.func = function()
                if not enabled then return end
                onSelect(infoData.value)
                BuildCombatOptionsUI()
            end
            SafeAddDropDownButton(info, level)

            buttonIndex = buttonIndex + 1
            local mb = GetDropDownListButton(level, buttonIndex)
            if mb then
                __fmClearMenuButtonFavoriteDecorations(mb)

                local hoverDisplay, hoverPath, hoverFlags
                if type(hoverPreviewBuilder) == "function" then
                    hoverDisplay, hoverPath, hoverFlags = hoverPreviewBuilder(infoData)
                end

                if type(hoverPath) == "string" and hoverPath ~= "" then
                    __fmAttachHoverPreviewToMenuButton(mb, hoverDisplay or infoData.text, {
                        path = hoverPath,
                        flags = hoverFlags,
                    })
                else
                    __fmClearMenuButtonHoverPreview(mb)
                end
            end
        end
    end)

    local selectedText = values[1] and values[1].text or ""
    for _, infoData in ipairs(values) do
        if infoData.value == selectedValue then
            selectedText = infoData.text
            break
        end
    end
    UIDropDownMenu_SetText(dd, selectedText)
    if not enabled and type(UIDropDownMenu_DisableDropDown) == "function" then
        pcall(UIDropDownMenu_DisableDropDown, dd)
    end
    if tip then
        if enabled then
            AttachTooltip(dd, label, tip)
        else
            AttachTooltip(dd, label, tip .. "\n\n" .. (disabledHint or "Not available on this client."))
        end
    end
    table.insert(combatWidgets, dd)
    return dd
end

local function CreateOptionSlider(y, key, label, minVal, maxVal, step, value, onChange, tip, enabled, disabledHint, liveApply)
    if enabled == nil then enabled = true end
    if liveApply == nil then liveApply = true end
    minVal, maxVal = NormalizeSliderBounds(minVal, maxVal, 0, 1)
    step = NormalizeSliderStep(step, minVal, maxVal)

    local fs = combatContent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", combatContent, "TOPLEFT", 0, y)
    fs:SetText(label)
    if not enabled then
        fs:SetTextColor(0.5, 0.5, 0.5)
    end
    table.insert(combatWidgets, fs)

    local valText = combatContent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    valText:SetPoint("TOPRIGHT", combatContent, "TOPRIGHT", -10, y)
    table.insert(combatWidgets, valText)

    local s = CreateFrame("Slider", addonName .. "Combat" .. key .. "Slider", combatContent, "OptionsSliderTemplate")
    s:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 8, -6)
    s:SetWidth(CB_COL_W * 2 + CHECK_COL_GAP - 30)
    s:SetMinMaxValues(minVal, maxVal)
    s:SetValueStep(step)
    -- Keep drag movement smooth on clients where obey-step dragging can feel
    -- clicky for decimal steps (for example 0.05). We still snap in code.
    SetSliderObeyStepCompat(s, false)
    local low = _G[s:GetName() .. "Low"]
    local high = _G[s:GetName() .. "High"]
    local decimals = GetSliderDisplayDecimals(step, minVal, maxVal)
    local endpointFmt = "%0." .. tostring(decimals) .. "f"
    if low then
        low:SetText(string.format(endpointFmt, minVal))
        low:ClearAllPoints()
        low:SetPoint("TOPLEFT", s, "BOTTOMLEFT", 0, -2)
    end
    if high then
        high:SetText(string.format(endpointFmt, maxVal))
        high:ClearAllPoints()
        high:SetPoint("TOPRIGHT", s, "BOTTOMRIGHT", -8, -2)
    end
    local t = s.Text or _G[s:GetName() .. "Text"]
    if t and t.Hide then t:Hide() end

    local fmt = "%0." .. tostring(decimals) .. "f"
    local rangeHint = string.format("\n\nRange: " .. endpointFmt .. " to " .. endpointFmt, minVal, maxVal)

    local function setVal(v)
        local snapped = SnapSliderToStep(v, minVal, maxVal, step)
        valText:SetText(string.format(fmt, snapped))
        if value == nil then
            value = snapped
        end
        return snapped
    end

    local settingValue = false
    local pendingCommitValue
    local isDragging = false
    local lastAppliedValue

    local function applyIfChanged(v)
        if lastAppliedValue ~= nil and NumbersNearlyEqual(lastAppliedValue, v, 0.000001) then
            return v
        end
        lastAppliedValue = v
        onChange(v)
        return v
    end

    local function commitValue(v)
        local rounded = setVal(v)
        pendingCommitValue = rounded
        applyIfChanged(rounded)
        return rounded
    end

    s:SetScript("OnValueChanged", function(self, v)
        if not enabled then return end
        local rounded = setVal(v)
        pendingCommitValue = rounded
        if not settingValue and math.abs((tonumber(v) or rounded) - rounded) > 0.00001 then
            settingValue = true
            self:SetValue(rounded)
            settingValue = false
        end
        if liveApply then
            applyIfChanged(rounded)
        elseif not isDragging then
            -- Keyboard/controller adjustments do not fire OnMouseUp.
            applyIfChanged(rounded)
        end
    end)

    -- Explicitly enable mouse interaction and commit a snapped value after drag.
    -- This keeps sliders responsive while ensuring exact stepped persistence.
    s:EnableMouse(true)
    s:SetScript("OnMouseDown", function()
        if not enabled then return end
        isDragging = true
    end)
    s:SetScript("OnMouseUp", function(self)
        if not enabled then return end
        isDragging = false
        local rounded = commitValue(self:GetValue())
        self:SetValue(rounded)
    end)

    s:SetScript("OnHide", function(self)
        if not enabled or liveApply then return end
        isDragging = false
        if pendingCommitValue == nil then return end
        local rounded = SnapSliderToStep(pendingCommitValue, minVal, maxVal, step)
        pendingCommitValue = nil
        applyIfChanged(rounded)
        settingValue = true
        self:SetValue(rounded)
        settingValue = false
    end)

    local initial = setVal(value)
    settingValue = true
    s:SetValue(initial)
    settingValue = false

    if enabled then
        s:Enable()
        if tip then AttachTooltip(s, label, tip .. rangeHint) end
    else
        valText:SetText("|cff888888N/A|r")
        if low then low:SetText("") end
        if high then high:SetText("") end
        s:Disable()
        if tip then AttachTooltip(s, label, tip .. rangeHint .. "\n\n" .. (disabledHint or "Not available on this client.")) end
    end

    table.insert(combatWidgets, s)
    return s
end

CollectExtraBoolCombatTextCVars = function()
    -- Collect additional floatingCombatText* boolean CVars that exist on this client
    -- but are not already represented by our curated definitions. We only include
    -- CVars that are real (commandType == 0) and whose current value is clearly
    -- boolean ("0" or "1") so we don't surface unrelated numeric settings.
    --
    -- Some clients expose both a base CVar and a version-suffixed variant (e.g. _v2).
    -- When multiple variants exist for the same base, prefer the highest version.
    local idx = BuildConsoleCommandIndex()
    local chosen = {} -- [baseName] = bestVariantName

    local function baseName(name)
        return (tostring(name or ""):gsub("_[vV]%d+$", ""))
    end

    local function versionNum(name)
        local v = tostring(name or ""):match("_[vV](%d+)$")
        return tonumber(v) or 0
    end

    if type(idx) == "table" then
        for name, ct in pairs(idx) do
            if type(name) == "string"
                and ct == 0
                and name:sub(1, #EXTRA_CVAR_PREFIX) == EXTRA_CVAR_PREFIX
            then
                local base = baseName(name)

                -- If the base CVar is already covered by our curated list, don't surface
                -- any of its variants here either.
                if not EXTRA_BLACKLIST[name] and not EXTRA_BLACKLIST[base] then
                    local v = GetCVarString(name)
                    if v == "0" or v == "1" then
                        local prev = chosen[base]
                        if not prev then
                            chosen[base] = name
                        else
                            if versionNum(name) > versionNum(prev) then
                                chosen[base] = name
                            end
                        end
                    end
                end
            end
        end
    end

    local extras = {}
    for _, name in pairs(chosen) do
        table.insert(extras, name)
    end
    table.sort(extras)
    return extras
end

BuildCombatOptionsUI = function()
    ClearCombatWidgets()

    local y = 0
    local row = 0

    local function place()
        local col = (row % 2 == 0) and 0 or 1
        local yy = y - math.floor(row / 2) * CHECK_ROW_H
        row = row + 1
        return col, yy
    end

    local masterOff = (FontMagicDB and FontMagicDB.combatMasterOffByFontMagic and type(FontMagicDB.combatMasterSnapshot) == "table") and true or false
    local snap = masterOff and FontMagicDB and FontMagicDB.combatMasterSnapshot or nil

    if masterOff then
        y = AddHeader("Note", y - 2)
        local note = combatContent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        note:SetPoint("TOPLEFT", combatContent, "TOPLEFT", 0, y)
        note:SetWidth(CB_COL_W * 2 + CHECK_COL_GAP - 10)
        note:SetJustifyH("LEFT")
        note:SetJustifyV("TOP")
        note:SetText("Combat text is currently hidden by the main \"Show combat text\" toggle. Enable it in the main panel to edit these options.")
        table.insert(combatWidgets, note)
        y = y - 26
    end

    y = AddHeader("Combat text visibility", y - 2)
    row = 0

    for _, def in ipairs(COMBAT_BOOL_DEFS) do
        if def.key ~= "enableFloatingCombatText" then
            local n, ct = ResolveConsoleSetting(def.candidates)
            if n and ct == 0 then
                local override = FontMagicDB.combatOverrides and FontMagicDB.combatOverrides[def.key]
                local live = GetLiveBoolCVar(n)
                local checked = (override ~= nil) and (override and true or false) or (live and true or false)

                if masterOff and type(snap) == "table" and type(snap.cvars) == "table" and snap.cvars[n] ~= nil then
                    checked = (tonumber(snap.cvars[n]) == 1) and true or false
                end

                local c, yy = place()
                local cb = CreateOptionCheckbox(c, yy, def.label, checked, function(self)
                    local newVal = self:GetChecked() and true or false
                    if type(FontMagicDB.combatOverrides) ~= "table" then FontMagicDB.combatOverrides = {} end
                    FontMagicDB.combatOverrides[def.key] = newVal
                    ApplyConsoleSetting(n, ct, newVal and "1" or "0")
                end, def.tip)

                if masterOff and cb and cb.Disable then pcall(cb.Disable, cb) end
            end
        end
    end

    y = y - (math.ceil(row / 2) * CHECK_ROW_H) - 10

    y = AddHeader("Where FontMagic applies your combat font", y)
    y = AddSectionNote(y, "Choose exactly which combat text systems should use the selected FontMagic font.")
    local applyWorld = FontMagicDB and FontMagicDB.applyToWorldText and true or false
    local applyScrolling = FontMagicDB and FontMagicDB.applyToScrollingText and true or false

    CreateOptionCheckbox(0, y, "World-space floating numbers", applyWorld, function(self)
        FontMagicDB = FontMagicDB or {}
        FontMagicDB.applyToWorldText = self:GetChecked() and true or false
        ApplySavedCombatFont()
        BuildCombatOptionsUI()
    end, "Uses your selected FontMagic font for floating numbers shown above units in the 3D game world.")

    CreateOptionCheckbox(1, y, "Scrolling combat text feed", applyScrolling, function(self)
        FontMagicDB = FontMagicDB or {}
        FontMagicDB.applyToScrollingText = self:GetChecked() and true or false
        ApplySavedCombatFont()
        RefreshPreviewRendering()
        BuildCombatOptionsUI()
    end, "Uses your selected FontMagic font for Blizzard's scrolling combat text near your character.")

    y = y - CHECK_ROW_H - 10

    y = AddHeader("Text rendering style (scrolling combat text)", y)
    y = AddSectionNote(y, "Fine-tune edge sharpness and shadow behavior for scrolling combat text only.")
    local outlineChoices = {
        { text = "None", value = "" },
        { text = "Standard outline", value = "OUTLINE" },
        { text = "Heavy outline", value = "THICKOUTLINE" },
    }
    CreateOptionDropdown(y, "Edge style", FontMagicDB and FontMagicDB.scrollingTextOutlineMode or "", outlineChoices, function(val)
        FontMagicDB = FontMagicDB or {}
        FontMagicDB.scrollingTextOutlineMode = val
        ApplySavedCombatFont()
        RefreshPreviewRendering()
    end,
    "Adjusts border thickness for scrolling combat text characters.",
    FontMagicDB and FontMagicDB.applyToScrollingText,
    "Enable 'Scrolling combat text feed' to change this setting.",
    function(infoData)
        local path = GetCurrentPreviewFontPath()
        local flags = ""
        if infoData and (infoData.value == "OUTLINE" or infoData.value == "THICKOUTLINE") then
            flags = infoData.value
        end
        if FontMagicDB and FontMagicDB.scrollingTextMonochrome then
            flags = (flags ~= "") and (flags .. ",MONOCHROME") or "MONOCHROME"
        end
        return "12345", path, flags
    end)

    local monoCB = CreateOptionCheckbox(1, y - 34, "Monochrome rendering", FontMagicDB and FontMagicDB.scrollingTextMonochrome and true or false, function(self)
        FontMagicDB = FontMagicDB or {}
        FontMagicDB.scrollingTextMonochrome = self:GetChecked() and true or false
        ApplySavedCombatFont()
        RefreshPreviewRendering()
    end, "Forces monochrome glyph rendering for scrolling combat text. Helpful for cleaner edges on some fonts.")
    if not (FontMagicDB and FontMagicDB.applyToScrollingText) and monoCB and monoCB.Disable then
        pcall(monoCB.Disable, monoCB)
    end

    CreateOptionSlider(y - 64, "Shadow", "Shadow distance", 0, 4, 1,
        tonumber(FontMagicDB and FontMagicDB.scrollingTextShadowOffset) or 1,
        function(v)
            FontMagicDB = FontMagicDB or {}
            FontMagicDB.scrollingTextShadowOffset = v
            ApplySavedCombatFont()
            RefreshPreviewRendering()
        end,
        "Sets how far the shadow sits from the text. Use 0 to disable shadow rendering.",
        FontMagicDB and FontMagicDB.applyToScrollingText,
        "Enable 'Scrolling combat text feed' to change this setting."
    )

    y = y - 130

    if EnsureIncomingReady() then
        y = AddHeader("Incoming message filters", y)

        local dmgEnabled = (type(COMBAT_TEXT_TYPE_INFO) == "table") and
            (COMBAT_TEXT_TYPE_INFO.DAMAGE ~= nil or COMBAT_TEXT_TYPE_INFO.SPELL_DAMAGE ~= nil)
        local healEnabled = (type(COMBAT_TEXT_TYPE_INFO) == "table") and
            (COMBAT_TEXT_TYPE_INFO.HEAL ~= nil or COMBAT_TEXT_TYPE_INFO.PERIODIC_HEAL ~= nil)

        local oDmg = FontMagicDB.incomingOverrides and FontMagicDB.incomingOverrides.incomingDamage
        local oHeal = FontMagicDB.incomingOverrides and FontMagicDB.incomingOverrides.incomingHealing

        local showDmg = (oDmg ~= nil) and oDmg or dmgEnabled
        local showHeal = (oHeal ~= nil) and oHeal or healEnabled

        if masterOff and type(snap) == "table" and type(snap.incoming) == "table" then
            if snap.incoming.damage ~= nil then showDmg = snap.incoming.damage and true or false end
            if snap.incoming.heal ~= nil then showHeal = snap.incoming.heal and true or false end
        end

        local cb1 = CreateOptionCheckbox(0, y, "Show Incoming Damage", showDmg, function(self)
            local newVal = self:GetChecked() and true or false
            if type(FontMagicDB.incomingOverrides) ~= "table" then FontMagicDB.incomingOverrides = {} end
            FontMagicDB.incomingOverrides.incomingDamage = newVal
            SetIncomingDamageEnabled(newVal)
        end, "Shows or hides scrolling combat text for damage you take.\n\n(Only available on clients that load Blizzard_CombatText.)")

        local cb2 = CreateOptionCheckbox(1, y, "Show Incoming Healing", showHeal, function(self)
            local newVal = self:GetChecked() and true or false
            if type(FontMagicDB.incomingOverrides) ~= "table" then FontMagicDB.incomingOverrides = {} end
            FontMagicDB.incomingOverrides.incomingHealing = newVal
            SetIncomingHealingEnabled(newVal)
        end, "Shows or hides scrolling combat text for healing you receive.\n\n(Only available on clients that load Blizzard_CombatText.)")

        if masterOff then
            if cb1 and cb1.Disable then pcall(cb1.Disable, cb1) end
            if cb2 and cb2.Disable then pcall(cb2.Disable, cb2) end
        end

        y = y - CHECK_ROW_H - 10
    end

    y = AddHeader("Floating text motion", y)
    y = AddSectionNote(y, "Tune movement behavior for world-space floating numbers. Changes apply immediately when supported.")
    local motionState = ResolveFloatingMotionUIState()
    local gravitySupported = motionState.gravitySupported
    local fadeSupported = motionState.fadeSupported
    local gravityMin, gravityMax = motionState.gravityMin, motionState.gravityMax
    local fadeMin, fadeMax = motionState.fadeMin, motionState.fadeMax

    if not gravitySupported or not fadeSupported then
        local unavailable = combatContent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        unavailable:SetPoint("TOPLEFT", combatContent, "TOPLEFT", 0, y)
        if not gravitySupported and not fadeSupported then
            unavailable:SetText("These motion controls are unavailable in this game client.")
        elseif not gravitySupported then
            unavailable:SetText("Gravity is unavailable in this game client.")
        else
            unavailable:SetText("Fade timing is unavailable in this game client.")
        end
        unavailable:SetTextColor(0.7, 0.7, 0.7)
        table.insert(combatWidgets, unavailable)
        y = y - 20
    end

    CreateOptionSlider(y, "Gravity", "Motion gravity", gravityMin, gravityMax, FLOATING_MOTION_STEP,
        tonumber(FontMagicDB and FontMagicDB.floatingTextGravity) or 1.0,
        function(v)
            FontMagicDB = FontMagicDB or {}
            FontMagicDB.floatingTextGravity = v
            ApplyFloatingTextMotionSettings()
        end,
        "Controls arc intensity while world-space numbers move upward and settle.",
        gravitySupported,
        "Gravity control is unavailable on this client version.",
        false
    )

    CreateOptionSlider(y - 54, "Fade", "Fade duration", fadeMin, fadeMax, FLOATING_MOTION_STEP,
        tonumber(FontMagicDB and FontMagicDB.floatingTextFadeDuration) or 1.0,
        function(v)
            FontMagicDB = FontMagicDB or {}
            FontMagicDB.floatingTextFadeDuration = v
            ApplyFloatingTextMotionSettings()
        end,
        "Controls how long world-space numbers remain visible before fading.",
        fadeSupported,
        "Fade duration control is unavailable on this client version.",
        false
    )

    y = y - 120

    local extras = CollectExtraBoolCombatTextCVars()
    if #extras > 0 then
        local showExtras = (FontMagicDB and FontMagicDB.showExtraCombatToggles) and true or false

        local toggle = CreateOptionCheckbox(0, y, "Show extra combat text toggles", showExtras, function(self)
            FontMagicDB = FontMagicDB or {}
            FontMagicDB.showExtraCombatToggles = self:GetChecked() and true or false
            BuildCombatOptionsUI()
        end, "Reveals additional, less common combat text options detected on this client.\n\nThese vary by WoW version and may do nothing in some clients. If you're unsure, leave this off.")

        if masterOff and toggle and toggle.Disable then pcall(toggle.Disable, toggle) end

        y = y - CHECK_ROW_H - 6

        if showExtras then
            y = AddHeader("Other (Advanced)", y)
            row = 0
            for _, cvar in ipairs(extras) do
                local n, ct = ResolveConsoleSetting(cvar)
                if n and ct == 0 then
                    local override = FontMagicDB.extraCombatOverrides and FontMagicDB.extraCombatOverrides[cvar]
                    local live = GetLiveBoolCVar(n)
                    local checked = (override ~= nil) and (override and true or false) or (live and true or false)

                    if masterOff and type(snap) == "table" and type(snap.cvars) == "table" and snap.cvars[n] ~= nil then
                        checked = (tonumber(snap.cvars[n]) == 1) and true or false
                    end

                    local c, yy = place()
                    local tip = GetExtraCombatTextCVarTooltip(cvar)
                    local cb = CreateOptionCheckbox(c, yy, PrettyCVarLabel(cvar), checked, function(self)
                        local newVal = self:GetChecked() and true or false
                        if type(FontMagicDB.extraCombatOverrides) ~= "table" then FontMagicDB.extraCombatOverrides = {} end
                        FontMagicDB.extraCombatOverrides[cvar] = newVal
                        ApplyConsoleSetting(n, ct, newVal and "1" or "0")
                    end, tip)

                    if masterOff and cb and cb.Disable then pcall(cb.Disable, cb) end
                end
            end

            y = y - (math.ceil(row / 2) * CHECK_ROW_H) - 10
        end
    end

    y = AddHeader("UI (Advanced)", y)
    local above = (FontMagicDB and FontMagicDB.combatTextAboveNameplates) and true or false
    CreateOptionCheckbox(0, y, "Combat text in front of nameplates", above, function(self)
        FontMagicDB = FontMagicDB or {}
        local v = self:GetChecked() and true or false
        FontMagicDB.combatTextAboveNameplates = v
        ApplyCombatTextAboveNameplates(v)
    end, "Makes Blizzard floating combat text draw in front of nameplates by raising its frame strata/level.\n\nBest-effort: works best with third-party nameplate add-ons. This only changes draw order (layering), not where the text appears. On many clients it also affects Blizzard nameplates, but some versions/UI setups may show little or no change. Some UI/add-ons may still cover it.")

    y = y - CHECK_ROW_H - 6

    local needed = -y + 20
    combatContent:SetHeight(math.max(needed, combatScroll:GetHeight()))
end


local function RefreshCombatTextCVars()
    if combatPanel and combatPanel:IsShown() then
        BuildCombatOptionsUI()
    end
end

RefreshCombatMetadataAndUI = function()
    RefreshConsoleCommandIndex()
    RefreshCombatTextCVars()

    if combatMetadataStatusFS and combatMetadataStatusFS.SetText then
        combatMetadataStatusFS:SetText("Metadata refreshed for this session.")
    end
end

local function SetExpanded(expand)
    local want = (expand and true or false)
    if want == isExpanded then return end

    isExpanded = want
    if UpdateExpandToggleText then UpdateExpandToggleText() end

    if isExpanded then
        if combatPanel and combatPanel.Show then combatPanel:Show() end
        BuildCombatOptionsUI()
    else
        if combatPanel and combatPanel.Hide then combatPanel:Hide() end
    end
end

expandBtn:SetScript("OnClick", function()
    SetExpanded(not isExpanded)
end)

-- 8) APPLY & DEFAULT BUTTONS ----------------------------------------------- -----------------------------------------------
local applyBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
-- Match the width of the Default button for consistency
applyBtn:SetSize(100, 22)
-- Position slightly closer to the bottom border now that the
-- overall frame height has been reduced
-- keep the action buttons in place or slightly lower so they no longer
-- overlap the lowest checkboxes
applyBtn:SetPoint("BOTTOMLEFT", 16, 12)
applyBtn:SetText("Apply")


-- Main quick toggles (kept out of the expanded panel for clarity)
mainShowCombatTextCB = CreateCheckbox(frame, "Show Combat Text", 0, 0, true,
    function(self)
        if not IsCombatTextMasterSupported() then
            UpdateMainCombatCheckboxes()
            return
        end
        local want = self:GetChecked() and true or false
        SetCombatTextMasterEnabled(want)
        RefreshCombatTextCVars()
    end
)
mainShowCombatTextCB:ClearAllPoints()
-- Keep this quick toggle above the action buttons and away from the expandable panel toggle.
mainShowCombatTextCB:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 44)
do
    local fs = mainShowCombatTextCB and (mainShowCombatTextCB.__fmLabelFS or GetCheckButtonLabelFS(mainShowCombatTextCB))
    if fs and fs.SetWidth then fs:SetWidth(240) end
    if fs and fs.SetJustifyH then fs:SetJustifyH("LEFT") end
    if fs and fs.SetWordWrap then fs:SetWordWrap(false) end
end
AttachTooltip(mainShowCombatTextCB, "Show Combat Text",
    "Shows or hides Blizzard floating combat text without losing your per-type settings.\n\n" ..
    "When you hide it, FontMagic stores your current combat text settings and restores them when you enable it again.")

local pendingStateFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
pendingStateFS:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 34)
pendingStateFS:SetPoint("RIGHT", applyBtn, "RIGHT", 0, 0)
pendingStateFS:SetJustifyH("LEFT")

local function SetApplyButtonPulse(enabled)
    if not applyBtn then return end

    if not applyBtn.__fmPulseAG and applyBtn.CreateAnimationGroup then
        local ag = applyBtn:CreateAnimationGroup()
        local fadeOut = ag:CreateAnimation("Alpha")
        fadeOut:SetOrder(1)
        fadeOut:SetDuration(0.35)
        fadeOut:SetFromAlpha(1)
        fadeOut:SetToAlpha(0.55)

        local fadeIn = ag:CreateAnimation("Alpha")
        fadeIn:SetOrder(2)
        fadeIn:SetDuration(0.35)
        fadeIn:SetFromAlpha(0.55)
        fadeIn:SetToAlpha(1)
        ag:SetLooping("REPEAT")

        applyBtn.__fmPulseAG = ag
    end

    local ag = applyBtn.__fmPulseAG
    if enabled then
        if ag and not ag:IsPlaying() then
            ag:Play()
        end
    else
        if ag and ag:IsPlaying() then
            ag:Stop()
        end
        applyBtn:SetAlpha(1)
    end
end

UpdatePendingStateText = function()
    local selected = FontMagicDB and FontMagicDB.selectedFont
    local hasPending = type(pendingFont) == "string" and pendingFont ~= "" and pendingFont ~= selected
    if hasPending then
        pendingStateFS:SetText("|cffffd200Preview active - click Apply to save|r")
    else
        pendingStateFS:SetText("|cff8f8f8fApplied font is up to date|r")
    end
    SetApplyButtonPulse(hasPending)
end
UpdatePendingStateText()

applyBtn:SetScript("OnClick", function()
    -- use the pending selection if the user picked a font but hasn't applied yet
    local selection = pendingFont or (FontMagicDB and FontMagicDB.selectedFont)
    if selection and type(selection) == "string" and selection ~= "" then
        FontMagicDB.selectedFont = selection
        pendingFont = nil
        if UpdatePendingStateText then UpdatePendingStateText() end

        local path = ResolveFontPathFromKey(selection)
        if path then
            FontMagicDB.selectedFontPath = path
            -- Best-effort immediate apply (helps on /reload). A relog is still the
            -- most reliable way to ensure combat text picks it up across clients.
            ApplyCombatTextFontPath(path)
            print("|cFF00FF00[FontMagic]|r Combat font saved. Log out to character select and back in to apply.")
            if UIErrorsFrame and UIErrorsFrame.AddMessage then
                UIErrorsFrame:AddMessage("FontMagic: relog to apply the new combat font.", 1, 1, 0)
            end
        else
            print("|cFFFF3333[FontMagic]|r Could not apply that font (file not found).")
            if UIErrorsFrame and UIErrorsFrame.AddMessage then
                UIErrorsFrame:AddMessage("FontMagic: that font could not be loaded.", 1, 0.2, 0.2)
            end
        end
        return
    end

    -- No selection: clear and restore defaults
    if FontMagicDB then FontMagicDB.selectedFont = nil end
    if FontMagicDB then FontMagicDB.selectedFontPath = nil end
    CaptureBlizzardDefaultFonts()
    local defaultPath = DEFAULT_DAMAGE_TEXT_FONT or DEFAULT_COMBAT_TEXT_FONT or DEFAULT_FONT_PATH or "Fonts\\FRIZQT__.TTF"
    ApplyCombatTextFontPath(defaultPath)
    -- Also update the preview + header so the UI matches what will be applied on relog.
    SetPreviewFont(GameFontNormalLarge or (preview and preview.GetFontObject and preview:GetFontObject()), defaultPath)
    if UpdatePreviewHeaderText then UpdatePreviewHeaderText("Default", defaultPath, true) end
    if preview and editBox and preview.SetText and editBox.GetText then
        preview:SetText(editBox:GetText() or "")
    end
    if UpdatePendingStateText then UpdatePendingStateText() end
    print("|cFF00FF00[FontMagic]|r Default combat font restored. Log out to character select and back in to apply.")
end)

local defaultBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
defaultBtn:SetSize(100,22)
defaultBtn:SetPoint("LEFT", applyBtn, "RIGHT", 8, 0)
defaultBtn:SetText("Reset")

AttachTooltip(defaultBtn, "Reset", "Restore Blizzard defaults. Choose what to reset.")

-- Reset dialog (font-only / combat-options-only / everything)
local resetDialog = CreateFrame("Frame", addonName .. "ResetDialog", UIParent, backdropTemplate)
resetDialog:SetFrameStrata("DIALOG")
resetDialog:SetToplevel(true)
resetDialog:SetSize(420, 220)
resetDialog:SetPoint("CENTER")
resetDialog:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 8, right = 8, top = 8, bottom = 8 }
})
-- More opaque so the dialog remains readable when something bright is behind it.
resetDialog:SetBackdropColor(0, 0, 0, 0.95)
if resetDialog.SetBackdropBorderColor then
    resetDialog:SetBackdropBorderColor(0.8, 0.8, 0.8, 1)
end
resetDialog:EnableMouse(true)
resetDialog:SetMovable(true)
resetDialog:RegisterForDrag("LeftButton")
resetDialog:SetScript("OnDragStart", function(self) self:StartMoving() end)
resetDialog:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
resetDialog:Hide()
frame.__fmResetDialog = resetDialog

-- Allow closing the dialog with Escape and keep it on-screen
if resetDialog and resetDialog.GetName and type(UISpecialFrames) == "table" then
    local n = resetDialog:GetName()
    if n then
        local exists = false
        for _, v in ipairs(UISpecialFrames) do
            if v == n then exists = true break end
        end
        if not exists then
            table.insert(UISpecialFrames, n)
        end
    end
end
if resetDialog and resetDialog.SetClampedToScreen then
    resetDialog:SetClampedToScreen(true)
end


local resetTitle = resetDialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
resetTitle:SetPoint("TOP", 0, -18)
resetTitle:SetText("Reset FontMagic")

local resetBody = resetDialog:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
resetBody:SetPoint("TOPLEFT", 18, -52)
resetBody:SetPoint("TOPRIGHT", -18, -52)
resetBody:SetPoint("BOTTOMLEFT", 18, 128)
resetBody:SetPoint("BOTTOMRIGHT", -18, 128)
resetBody:SetJustifyH("LEFT")
resetBody:SetJustifyV("TOP")
resetBody:SetText("Choose what you want to reset.\n\n• Font only: clears your selected font and preview state.\n• Combat options only: removes FontMagic overrides so WoW settings behave normally.\n• Everything: does both.")

local function ResetFontOnly()
    -- Preserve minimap settings
    local keepAngle = FontMagicDB and FontMagicDB.minimapAngle
    local keepHide  = FontMagicDB and FontMagicDB.minimapHide
    local keepRadius = FontMagicDB and FontMagicDB.minimapRadiusOffset

    FontMagicDB = FontMagicDB or {}
    FontMagicDB.selectedFont = nil
    FontMagicDB.selectedFontPath = nil
    FontMagicDB.selectedGroup = nil
    FontMagicDB.minimapAngle = keepAngle
    FontMagicDB.minimapHide  = keepHide
    FontMagicDB.minimapRadiusOffset = keepRadius
    FontMagicDB.applyToWorldText = true
    FontMagicDB.applyToScrollingText = true
    FontMagicDB.scrollingTextOutlineMode = ""
    FontMagicDB.scrollingTextMonochrome = false
    FontMagicDB.scrollingTextShadowOffset = 1

    FontMagicPCDB = FontMagicPCDB or {}
    FontMagicPCDB.selectedGroup = nil
    FontMagicPCDB.selectedFont  = nil

    pendingFont = nil
    if UpdatePendingStateText then UpdatePendingStateText() end

    -- Ensure we know the true Blizzard defaults for THIS client.
    CaptureBlizzardDefaultFonts()
    local defaultPath = DEFAULT_DAMAGE_TEXT_FONT or DEFAULT_COMBAT_TEXT_FONT or DEFAULT_FONT_PATH or "Fonts\\FRIZQT__.TTF"

    -- Reset dropdown labels
    for _, group in ipairs(order) do
        local dd = dropdowns[group]
        if dd then
            if type(UIDropDownMenu_SetText) == "function" then
                pcall(UIDropDownMenu_SetText, dd, "Select Font")
            elseif dd.SetText then
                dd:SetText("Select Font")
            end
        end
    end

    -- Reset preview font (keep the preview text as-is).
    SetPreviewFont(GameFontNormalLarge or (preview and preview.GetFontObject and preview:GetFontObject()), defaultPath)
    if UpdatePreviewHeaderText then UpdatePreviewHeaderText("Default", defaultPath, true) end
    __fmRunNextFrame(function()
        if preview and editBox and preview.SetText and editBox.GetText then
            preview:SetText(editBox:GetText() or "")
        end
    end)
    if editBox and editBox.ClearFocus then
        editBox:ClearFocus()
    end
    if editBox and preview and editBox.GetText and preview.SetText then
        local txt = editBox:GetText() or ""
        preview:SetText("")
        preview:SetText(txt)
    end

    -- Reset the actual combat text font back to Blizzard's default for this client.
    ApplyCombatTextFontPath(defaultPath)
    RefreshPreviewRendering()
    RefreshCombatTextCVars()
end

local function ResetCombatOptionsOnly()
    FontMagicDB = FontMagicDB or {}

    -- Clear saved overrides so they no longer re-apply on login.
    FontMagicDB.combatOverrides = {}
    FontMagicDB.extraCombatOverrides = {}
    FontMagicDB.incomingOverrides = {}
    FontMagicDB.combatMasterSnapshot = nil
    FontMagicDB.combatMasterOffByFontMagic = nil
    FontMagicDB.applyToWorldText = true
    FontMagicDB.applyToScrollingText = true
    FontMagicDB.scrollingTextOutlineMode = ""
    FontMagicDB.scrollingTextMonochrome = false
    FontMagicDB.scrollingTextShadowOffset = 1

    local function ResetBoolCVarToDefault(name)
        if not name then return end
        if not DoesCVarExist(name) then return end

        -- Prefer the engine reset (most accurate to this client build)
        if type(C_CVar) == "table" and type(C_CVar.ResetCVar) == "function" then
            pcall(C_CVar.ResetCVar, name)
            return
        end

        -- Fallback: set to reported default
        local d
        if type(C_CVar) == "table" and type(C_CVar.GetCVarDefault) == "function" then
            local ok, v = pcall(C_CVar.GetCVarDefault, name)
            if ok then d = v end
        end
        if d == nil and type(GetCVarDefault) == "function" then
            local ok, v = pcall(GetCVarDefault, name)
            if ok then d = v end
        end
        if d ~= nil then
            ApplyConsoleSetting(name, 0, d)
        end
    end

    -- Reset curated combat text toggles to their real defaults (this client).
    for _, def in ipairs(COMBAT_BOOL_DEFS) do
        local n, ct = ResolveConsoleSetting(def.candidates)
        if n and ct == 0 then
            ResetBoolCVarToDefault(n)
        end
    end

    -- Reset any additional floatingCombatText* boolean CVars we surfaced under Advanced.
    local extras = CollectExtraBoolCombatTextCVars()
    for _, cvar in ipairs(extras) do
        local n, ct = ResolveConsoleSetting(cvar)
        if n and ct == 0 then
            ResetBoolCVarToDefault(n)
        end
    end

    -- Reset combat text scale (slider) to its real default (if supported on this client).
    do
        local name, ct = GetCombatTextScaleCVar()
        if name then
            if type(C_CVar) == "table" and type(C_CVar.ResetCVar) == "function" and ct == 0 then
                pcall(C_CVar.ResetCVar, name)
            else
                local d
                if type(C_CVar) == "table" and type(C_CVar.GetCVarDefault) == "function" then
                    local ok, v = pcall(C_CVar.GetCVarDefault, name)
                    if ok then d = v end
                end
                if d == nil and type(GetCVarDefault) == "function" then
                    local ok, v = pcall(GetCVarDefault, name)
                    if ok then d = v end
                end
                if d ~= nil then
                    ApplyConsoleSetting(name, ct, d)
                end
            end
        end
    end

    -- Reset floating text motion CVars to client defaults.
    do
        local function ResetNumericCVarToDefault(candidates)
            local name, ct = ResolveConsoleSetting(candidates)
            if not name then return nil end
            if type(C_CVar) == "table" and type(C_CVar.ResetCVar) == "function" and ct == 0 then
                pcall(C_CVar.ResetCVar, name)
            else
                local d
                if type(C_CVar) == "table" and type(C_CVar.GetCVarDefault) == "function" then
                    local ok, v = pcall(C_CVar.GetCVarDefault, name)
                    if ok then d = v end
                end
                if d == nil and type(GetCVarDefault) == "function" then
                    local ok, v = pcall(GetCVarDefault, name)
                    if ok then d = v end
                end
                if d ~= nil then
                    ApplyConsoleSetting(name, ct, d)
                end
            end
            return tonumber(GetCVarString(name))
        end

        local gravityCandidates = FLOATING_GRAVITY_CANDIDATES
        local fadeCandidates = FLOATING_FADE_CANDIDATES

        local g = ResetNumericCVarToDefault(gravityCandidates)
        local f = ResetNumericCVarToDefault(fadeCandidates)

        -- Keep SavedVariables synchronized even when a client does not expose
        -- one of these CVars. This guarantees reset buttons restore defaults in UI.
        FontMagicDB.floatingTextGravity = g or GetResolvedSettingNumber(gravityCandidates, 1.0)
        FontMagicDB.floatingTextFadeDuration = f or GetResolvedSettingNumber(fadeCandidates, 1.0)
    end

    -- Restore Blizzard's default incoming damage/healing tables (where supported).
    if EnsureIncomingReady() and type(COMBAT_TEXT_TYPE_INFO) == "table" and type(originalInfo) == "table" then
        local keys = {
            "DAMAGE", "DAMAGE_CRIT", "SPELL_DAMAGE", "SPELL_DAMAGE_CRIT",
            "HEAL", "HEAL_CRIT", "PERIODIC_HEAL", "PERIODIC_HEAL_CRIT",
        }
        for _, k in ipairs(keys) do
            COMBAT_TEXT_TYPE_INFO[k] = originalInfo[k]
        end
    end

    -- Reset account-wide layering tweak (combat text above nameplates).
    FontMagicDB.combatTextAboveNameplates = false
    ApplyCombatTextAboveNameplates(false)

    -- Refresh UI + slider values immediately.
    RefreshScaleControl()
    RefreshCombatTextCVars()
    UpdateMainCombatCheckboxes()
end

local function ResetEverything()
    ResetFontOnly()
    ResetCombatOptionsOnly()
end

local resetFontBtn = CreateFrame("Button", nil, resetDialog, "UIPanelButtonTemplate")
resetFontBtn:SetSize(160, 22)
resetFontBtn:SetPoint("BOTTOMLEFT", 18, 54)
resetFontBtn:SetText("Reset Font Only")
AttachTooltip(resetFontBtn, "Reset font only", "Restore Blizzard\'s default combat text font.")
resetFontBtn:SetScript("OnClick", function()
    ResetFontOnly()
    resetDialog:Hide()
end)

local resetCombatBtn = CreateFrame("Button", nil, resetDialog, "UIPanelButtonTemplate")
resetCombatBtn:SetSize(160, 22)
resetCombatBtn:SetPoint("BOTTOMRIGHT", -18, 54)
resetCombatBtn:SetText("Reset Combat Options")
AttachTooltip(resetCombatBtn, "Reset combat options", "Clear FontMagic combat text overrides and restore Blizzard defaults.")
resetCombatBtn:SetScript("OnClick", function()
    ResetCombatOptionsOnly()
    resetDialog:Hide()
end)

local resetAllBtn = CreateFrame("Button", nil, resetDialog, "UIPanelButtonTemplate")
resetAllBtn:SetSize(160, 22)
resetAllBtn:SetPoint("BOTTOM", 0, 92)
resetAllBtn:SetText("Reset Everything")
AttachTooltip(resetAllBtn, "Reset everything", "Restore Blizzard defaults for both fonts and combat text options.")
resetAllBtn:SetScript("OnClick", function()
    ResetEverything()
    resetDialog:Hide()
end)

local resetCancelBtn = CreateFrame("Button", nil, resetDialog, "UIPanelButtonTemplate")
resetCancelBtn:SetSize(120, 22)
resetCancelBtn:SetPoint("BOTTOM", 0, 18)
resetCancelBtn:SetText(CANCEL or "Cancel")
AttachTooltip(resetCancelBtn, "Cancel", "Close this dialog without making changes.")
resetCancelBtn:SetScript("OnClick", function() resetDialog:Hide() end)

defaultBtn:SetScript("OnClick", function()
    if resetDialog:IsShown() then
        resetDialog:Hide()
    else
        resetDialog:Show()
    end
end)

-- 11) CLOSE BUTTON
local closeBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
closeBtn:SetSize(80, 24)
-- Align with the Apply button and use the reduced
-- bottom spacing
closeBtn:SetPoint("BOTTOMRIGHT", (frame.__fmLeftAnchor or frame), "BOTTOMRIGHT", -16, 12)
-- Keep the expand toggle neatly above Close
if expandBtn and expandBtn.ClearAllPoints and expandBtn.SetPoint then
    expandBtn:ClearAllPoints()
    expandBtn:SetPoint("BOTTOMRIGHT", closeBtn, "TOPRIGHT", 0, 6)
end
closeBtn:SetText("Close")
closeBtn:SetScript("OnClick", function() frame:Hide() end)
closeBtn:SetScript("OnEnter", function(self)
    ShowTooltip(self, "ANCHOR_RIGHT", "Close this window")
end)
closeBtn:SetScript("OnLeave", HideTooltip)

-- 12) SLASH COMMANDS & DROPDOWN
SLASH_FCT1, SLASH_FCT2 = "/FCT", "/fct"
SLASH_FCT3, SLASH_FCT4 = "/FLOAT", "/float"
SLASH_FCT5, SLASH_FCT6 = "/FLOATING", "/floating"
SLASH_FCT7, SLASH_FCT8 = "/FLOATINGTEXT", "/floatingtext"

local function PrepareFontMagicWindowForDisplay()
    if not frame then return end

    -- Restore saved position (standalone only)
    if frame.GetParent and frame:GetParent() == UIParent and FontMagicDB and type(FontMagicDB.windowPos) == "table" then
        local p = FontMagicDB.windowPos
        if type(p.left) == "number" and type(p.top) == "number" then
            frame:ClearAllPoints()
            frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", p.left, p.top)
        end
    end

    -- Ensure the config window is on top when opened standalone.
    if frame.GetParent and frame:GetParent() == UIParent then
        if frame.SetToplevel then frame:SetToplevel(true) end
        if frame.SetFrameStrata then frame:SetFrameStrata("FULLSCREEN_DIALOG") end
        if frame.SetFrameLevel then frame:SetFrameLevel(1000) end
        if frame.Raise then frame:Raise() end

        if combatPanel and combatPanel.SetFrameStrata then
            combatPanel:SetFrameStrata("FULLSCREEN_DIALOG")
            if combatPanel.SetFrameLevel and frame.GetFrameLevel then
                combatPanel:SetFrameLevel((frame:GetFrameLevel() or 1000) + 20)
            end
        end
        if expandBtn and expandBtn.SetFrameStrata then
            expandBtn:SetFrameStrata("FULLSCREEN_DIALOG")
            if expandBtn.SetFrameLevel and frame.GetFrameLevel then
                expandBtn:SetFrameLevel((frame:GetFrameLevel() or 1000) + 30)
            end
        end
        if resetDialog and resetDialog.SetFrameStrata then
            resetDialog:SetFrameStrata("FULLSCREEN_DIALOG")
        end
    end

    -- Apply account-wide combat text layer preference immediately.
    if FontMagicDB and FontMagicDB.combatTextAboveNameplates then
        ApplyCombatTextAboveNameplates(true)
    else
        ApplyCombatTextAboveNameplates(false)
    end

    UpdateMainCombatCheckboxes()
end

local function PrintCombatSettingsDebugReport()
    print("|cFF00FF00[FontMagic]|r Combat setting diagnostics (resolved targets):")

    local function PrintLine(label, candidates)
        local targets = ResolveConsoleSettingTargets(candidates)
        if type(targets) ~= "table" or #targets == 0 then
            print(string.format("|cFF00FF00[FontMagic]|r  - %s: unresolved on this client", label))
            return
        end

        local first = targets[1]
        local value = GetCVarString(first.name)
        local commandKind = (first.commandType == nil or first.commandType == 0) and "CVar" or "Console"
        print(string.format("|cFF00FF00[FontMagic]|r  - %s: %s (%s) = %s", label, first.name, commandKind, tostring(value)))
    end

    PrintLine("Show combat text", { "enableFloatingCombatText", "enableCombatText" })
    PrintLine("Combat text scale", { "floatingCombatTextScale", "floatingCombatTextScale_v2", "floatingCombatTextScale_V2" })
    PrintLine("World text gravity", FLOATING_GRAVITY_CANDIDATES)
    PrintLine("World text fade", FLOATING_FADE_CANDIDATES)

    for _, def in ipairs(COMBAT_BOOL_DEFS) do
        PrintLine(def.label or def.key or "(unknown)", def.candidates)
    end
end

SlashCmdList["FCT"] = function(msg)
    -- normalise message for case-insensitive matching and remove whitespace
    msg = tostring(msg or ""):match("^%s*(.-)%s*$"):lower()

    local radiusValue = msg:match("^radius%s+([%+%-]?%d+)$")
    if radiusValue then
        local n = tonumber(radiusValue)
        if n then
            FontMagicDB.minimapRadiusOffset = ClampNumber(n, FM_MINIMAP_RADIUS_OFFSET_MIN, FM_MINIMAP_RADIUS_OFFSET_MAX)
            if minimapButton then
                PositionMinimapButton(minimapButton, FontMagicDB.minimapAngle)
            end
            print(string.format("|cFF00FF00[FontMagic]|r Minimap icon radius offset set to %d.", FontMagicDB.minimapRadiusOffset))
            return
        end
    end

    if msg == "hide" then
        if minimapButton then minimapButton:Hide() end
        FontMagicDB.minimapHide = true
        print("|cFF00FF00[FontMagic]|r Minimap icon hidden. Use /float show to restore.")
        return
    elseif msg == "show" then
        if not minimapButton then
            CreateMinimapButton()
        end
        if minimapButton then minimapButton:Show() end
        FontMagicDB.minimapHide = false
        return
    elseif msg == "status" or msg == "debug" then
        PrintCombatSettingsDebugReport()
        return
    elseif msg == "help" then
        print("|cFF00FF00[FontMagic]|r Commands: /float, /float hide, /float show, /float status, /float radius <" .. FM_MINIMAP_RADIUS_OFFSET_MIN .. " to " .. FM_MINIMAP_RADIUS_OFFSET_MAX .. ">")
        return
    end

    if frame:IsShown() then
        frame:Hide()
        return
    end

    pendingFont = nil -- discard any un-applied selection
    if UpdatePendingStateText then UpdatePendingStateText() end

    for _, d in pairs(dropdowns) do
        SetDropdownTextCompat(d, "Select Font")
    end
    if FontMagicDB.selectedFont then
        -- parse using the last '/' to support group names that contain
        -- slashes from older categories.
        local grp,fname = FontMagicDB.selectedFont:match("^(.*)/([^/]+)$")
        if grp and fname and dropdowns[grp] and existsFonts[grp][fname] then
            UIDropDownMenu_SetText(dropdowns[grp], __fmStripFontExt(fname))
            -- If this font is favorited, also reflect it in the Favorites dropdown.
            if dropdowns["Favorites"] and IsFavorite(FontMagicDB.selectedFont) then
                UIDropDownMenu_SetText(dropdowns["Favorites"], __fmStripFontExt(fname))
            end
            local cache = cachedFonts[grp][fname]
            if cache then
                SetPreviewFont(cache)
                if UpdatePreviewHeaderText then
                    UpdatePreviewHeaderText(__fmStripFontExt(fname), cache.path, false)
                end
            end
        end
    else
        -- no saved font means use the UI's default
        SetPreviewFont(GameFontNormalLarge or preview:GetFontObject(), DEFAULT_FONT_PATH)
        if UpdatePreviewHeaderText then UpdatePreviewHeaderText("Default", DEFAULT_FONT_PATH, true) end
    end
    preview:SetText(editBox:GetText())
    PrepareFontMagicWindowForDisplay()
    frame:Show()

    -- Ensure the preview is correctly sized the first time the window is shown.
    -- Some clients report widget sizes slightly differently before the frame is visible.
    __fmRunNextFrame(function()
        if not (frame and frame.IsShown and frame:IsShown()) then return end

        local key = FontMagicDB and FontMagicDB.selectedFont
        local path
        if key and type(key) == "string" and key ~= "" then
            path = ResolveFontPathFromKey(key)
        end
        if not path then
            CaptureBlizzardDefaultFonts()
            path = DEFAULT_DAMAGE_TEXT_FONT or DEFAULT_COMBAT_TEXT_FONT or DEFAULT_FONT_PATH or "Fonts\\FRIZQT__.TTF"
        end

        SetPreviewFont(GameFontNormalLarge or (preview and preview.GetFontObject and preview:GetFontObject()), path)

        if UpdatePreviewHeaderText then
            local label = "Default"
            local isDef = true
            if key and type(key) == "string" and key ~= "" then
                local _, f = key:match("^(.*)/([^/]+)$")
                if f then
                    label = __fmStripFontExt(f)
                    isDef = false
                end
            end
            UpdatePreviewHeaderText(label, path, isDef)
        end

        if preview and editBox and preview.SetText and editBox.GetText then
            preview:SetText(editBox:GetText() or "")
        end
    end)
end

-- 13) MINIMAP ICON -----------------------------------------------------------

-- helper to position the minimap button at a specific angle
local function PositionMinimapButton(btn, angle)
    if not (btn and Minimap and Minimap.GetWidth and Minimap.GetHeight and btn.GetWidth and btn.GetHeight) then return end

    local shape = "ROUND"
    if type(GetMinimapShape) == "function" then
        local ok, s = pcall(GetMinimapShape)
        if ok and type(s) == "string" and s ~= "" then
            shape = s
        end
    end

    local a = math.rad(NormalizeAngleDegrees(angle or 0))
    local offset = ClampNumber(tonumber(FontMagicDB and FontMagicDB.minimapRadiusOffset) or FM_MINIMAP_RADIUS_OFFSET_DEFAULT, FM_MINIMAP_RADIUS_OFFSET_MIN, FM_MINIMAP_RADIUS_OFFSET_MAX)
    local hw = (Minimap:GetWidth() or 140) * 0.5
    local hh = (Minimap:GetHeight() or 140) * 0.5

    local bx = (btn:GetWidth() or 20) * 0.5
    local by = (btn:GetHeight() or 20) * 0.5
    local xr, yr

    -- If a square-ish minimap skin is active, keep the button on the frame bounds
    -- instead of forcing a circle so it doesn't collide with nearby UI elements.
    if shape == "SQUARE" or shape == "CORNER-TOPLEFT" or shape == "CORNER-TOPRIGHT" or shape == "CORNER-BOTTOMLEFT" or shape == "CORNER-BOTTOMRIGHT" or shape == "SIDE-LEFT" or shape == "SIDE-RIGHT" or shape == "SIDE-TOP" or shape == "SIDE-BOTTOM" or shape == "TRICORNER-TOPLEFT" or shape == "TRICORNER-TOPRIGHT" or shape == "TRICORNER-BOTTOMLEFT" or shape == "TRICORNER-BOTTOMRIGHT" then
        xr = hw + offset - bx
        yr = hh + offset - by
    else
        local base = math.min(hw, hh)
        xr = base + offset - bx
        yr = base + offset - by
    end

    xr = math.max(8, xr)
    yr = math.max(8, yr)

    local x = math.cos(a) * xr
    local y = math.sin(a) * yr

    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- Cross-version atan2 (some clients expose math.atan2, others rely on math.atan(y,x))
local function SafeAtan2(y, x)
    if type(math.atan2) == "function" then
        return math.atan2(y, x)
    end
    if type(math.atan) == "function" then
        local ok, v = pcall(math.atan, y, x)
        if ok and v ~= nil then
            return v
        end
        if x == 0 then
            if y > 0 then return math.pi / 2 end
            if y < 0 then return -math.pi / 2 end
            return 0
        end
        return math.atan(y / x)
    end
    local gatan2 = _G and _G.atan2
    if type(gatan2) == "function" then
        return gatan2(y, x)
    end
    return 0
end

local function UpdateMinimapButtonDrag(self)
    local now = GetTime and GetTime() or 0
    local last = self.__fmLastDragUpdate or 0
    if now > 0 and (now - last) < 0.016 then
        return
    end
    self.__fmLastDragUpdate = now

    local mx, my = GetCursorPosition()
    local scale = (Minimap and Minimap.GetEffectiveScale and Minimap:GetEffectiveScale()) or 1
    mx, my = mx / scale, my / scale
    local cx, cy = Minimap:GetCenter()
    if not (cx and cy) then return end
    local dx, dy = mx - cx, my - cy

    local ang = NormalizeAngleDegrees(math.deg(SafeAtan2(dy, dx)))
    FontMagicDB.minimapAngle = ang
    PositionMinimapButton(self, ang)
end

local function CreateMinimapButton()
    if minimapButton then return minimapButton end
    if not (Minimap and type(CreateFrame) == "function") then return nil end

    minimapButton = CreateFrame("Button", addonName .. "MinimapButton", Minimap)
    minimapButton:SetSize(20, 20)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(8)

    -- icon (masked to a circle)
    local iconTex = minimapButton:CreateTexture(nil, "BACKGROUND")
    iconTex:SetTexture(ADDON_PATH .. "FontMagic_MinimapIcon_Best_64.tga")
    iconTex:SetAllPoints(minimapButton)
    if iconTex.SetMaskTexture then
        -- Use a double-backslash path to avoid Lua escape sequences removing the backslashes.
        -- Without escaping, a single \M would remove the backslash and break the path.
        iconTex:SetMaskTexture("Interface\\Minimap\\UI-Minimap-Mask")
    end

    -- ring overlay
    local ring = minimapButton:CreateTexture(nil, "OVERLAY")
    ring:SetTexture(ADDON_PATH .. "FontMagic_MinimapRing_Best_64.tga")
    local w, h = minimapButton:GetSize()
    ring:SetSize(w * 1.5, h * 1.5)
    ring:SetAlpha(0.85)
    iconTex:SetAlpha(0.95)
    ring:SetPoint("CENTER", minimapButton, "CENTER", 0, 0)

    -- Use a double-backslash path to avoid Lua escape sequences removing the backslashes.
    minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    minimapButton:EnableMouse(true)
    minimapButton:SetHitRectInsets(-6, -6, -6, -6)
    minimapButton:RegisterForClicks("LeftButtonUp")
    minimapButton:RegisterForDrag("LeftButton")
    minimapButton:SetScript("OnClick", function()
        if SlashCmdList and SlashCmdList["FCT"] then
            SlashCmdList["FCT"]()
        end
    end)

    minimapButton:SetScript("OnDragStart", function(self)
        self.isMoving = true
        self.__fmLastDragUpdate = 0
        self:SetScript("OnUpdate", UpdateMinimapButtonDrag)
    end)
    minimapButton:SetScript("OnDragStop", function(self)
        self.isMoving = false
        self:SetScript("OnUpdate", nil)
        PositionMinimapButton(self, FontMagicDB and FontMagicDB.minimapAngle)
    end)

    minimapButton:SetScript("OnEnter", function(self)
        ShowTooltip(self, "ANCHOR_LEFT", "FontMagic")
        if ring then ring:SetAlpha(1.0) end
        if iconTex then iconTex:SetAlpha(1.0) end
    end)
    minimapButton:SetScript("OnLeave", function()
        HideTooltip()
        if ring then ring:SetAlpha(0.85) end
        if iconTex then iconTex:SetAlpha(0.95) end
    end)

    PositionMinimapButton(minimapButton, FontMagicDB and FontMagicDB.minimapAngle)
    if FontMagicDB and FontMagicDB.minimapHide then
        minimapButton:Hide()
    end

    return minimapButton
end

-- ---------------------------------------------------------------------------
-- Combat text override bootstrap
-- ---------------------------------------------------------------------------

local function ApplyAllSavedOverrides()
    ApplyCombatOverrides()
    ApplyIncomingOverrides()
    ApplyFloatingTextMotionSettings()

    -- If combat text was hidden via the master toggle, keep it hidden across relogs.
    if FontMagicDB and FontMagicDB.combatMasterOffByFontMagic and type(FontMagicDB.combatMasterSnapshot) == "table" then
        ApplyCombatTextMasterDisabled()
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("CVAR_UPDATE")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

local didFirstWorldApply = false

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "PLAYER_LOGIN" then
        -- Build console index, register options, then apply only the saved overrides.
        RefreshConsoleCommandIndex()
        MigrateSavedFontKeys()
        RegisterOptionsCategory()
        CaptureBlizzardDefaultFonts()
        ApplySavedCombatFont()
        ApplyAllSavedOverrides()
        RefreshCombatTextCVars()
        -- Apply account-wide layering preference
        if FontMagicDB and FontMagicDB.combatTextAboveNameplates then
            ApplyCombatTextAboveNameplates(true)
        else
            ApplyCombatTextAboveNameplates(false)
        end

        UpdateMainCombatCheckboxes()
        CreateMinimapButton()
        if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
            C_Timer.After(0.2, UpdateMainCombatCheckboxes)
            C_Timer.After(1.0, UpdateMainCombatCheckboxes)
        end


    elseif event == "ADDON_LOADED" then
        -- SavedVariables are guaranteed to be available on our own ADDON_LOADED.
        -- Apply the saved font as early as possible so Blizzard combat text picks it up
        -- during its initialization (some clients cache the font before PLAYER_LOGIN).
        if arg1 == addonName then
            MigrateSavedFontKeys()
            CaptureBlizzardDefaultFonts()
            ApplySavedCombatFont()
            ApplyFloatingTextMotionSettings()
        end

        -- If Blizzard_CombatText loads after us, re-apply incoming overrides (if any).
        if arg1 == "Blizzard_CombatText" then
            MigrateSavedFontKeys()
            CaptureBlizzardDefaultFonts()
            ApplySavedCombatFont()
            ApplyIncomingOverrides()
            RefreshCombatTextCVars()
        end

    elseif event == "CVAR_UPDATE" then
        -- Keep UI in sync if the user changes settings via the default Options UI.
        RefreshCombatTextCVars()

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Some clients reinitialize combat text assets late in the login flow.
        -- Re-apply once on first world entry so the saved font survives relogs.
        if not didFirstWorldApply then
            didFirstWorldApply = true
            CaptureBlizzardDefaultFonts()
            ApplySavedCombatFont()
            ApplyFloatingTextMotionSettings()
        end
    end
end)
