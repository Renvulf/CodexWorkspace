--[[
  NiceClock.lua
  Display a macOS-style clock in bottom-left with a seed icon and minimap icon,
  plus a tabbed settings panel with Clock Settings, Alarm, Quality of Life,
  Track, and Combat sections.
  Author: Renvulf

  IMPORTANT:
    Do NOT remove or omit any sections when updating this file:
      * Clock Settings Panel
      * Alarm Panel
      * Quality of Life Panel
      * Track Panel
      * Combat Panel
      * Combat Text Size Slider Section
    All changes should be additive and clearly marked.
--]]

-- Retrieve our addon name; the second return (addonTable) is unused
local addonName = ...
local legacyTimeDB = _G.TimeDB
local legacyTimePerCharDB = _G.TimePerCharDB

NiceClockDB = NiceClockDB or {}                -- global settings across characters
NiceClockPerCharDB = NiceClockPerCharDB or {}  -- per-character settings

if next(NiceClockDB) == nil and type(legacyTimeDB) == "table" then
  NiceClockDB = legacyTimeDB
end

if next(NiceClockPerCharDB) == nil and type(legacyTimePerCharDB) == "table" then
  NiceClockPerCharDB = legacyTimePerCharDB
end

-- ─── Combat Fonts Detection ──────────────────────────────────────────────────
-- Font groups with their respective font files. These correspond to the folders
-- inside the addon directory.
local COMBAT_FONT_GROUPS = {
  ["Fun"] = {
    path  = "Interface\\AddOns\\NiceClock\\Fun\\",
    fonts = {
      -- Existing fonts
      "04b.ttf", "Barriecito.ttf", "Green Fuz.otf", "Guroes.ttf",
      "Melted.ttf", "Munsteria.ttf", "Runic.ttf", "Skullphabet.ttf",
      "WhoAsksSatan.ttf", "Wickedmouse.ttf", "edkies.ttf", "graff.ttf",
      -- Newly added fonts
      "Dmagic.ttf", "Elven.ttf", "Gunung.ttf", "Heorot.ttf",
      "Kiyrand.ttf", "Kting.ttf", "Odinson.ttf", "Pau.ttf",
      "WKnight.ttf", "Wasser.ttf",
    },
  },
  ["Future"] = {
    path  = "Interface\\AddOns\\NiceClock\\Future\\",
    fonts = {
      -- Existing fonts
      "914Solid.ttf", "ChopSic.ttf", "Digital.ttf", "FastHand.ttf",
      "Orbitron.ttf", "Pepsi.ttf", "RaceSpace.ttf", "RushDriver.ttf",
      -- Newly added fonts
      "KArabia.ttf", "Magicbrush.ttf", "Moog.ttf", "Techdelight.ttf",
    },
  },
  ["Movie/Game"] = {
    -- Directory renamed from Movie:Game to avoid the colon
    path  = "Interface\\AddOns\\NiceClock\\MovieGame\\",
    fonts = {
      -- Existing fonts
      "Deltarune.ttf", "Halo.ttf", "HarryP.ttf", "Pokemon.ttf",
      "Spongebob.ttf", "Terminator.ttf", "modernwarfare.ttf",
      -- Newly added fonts
      "BElschool.ttf", "Briar.ttf", "Enchant.ttf", "Fanaisie.ttf",
      "Firstorder.ttf", "Hobbit.ttf", "Ktingw.ttf", "Lumos.ttf",
      "Ruritania.ttf", "Sabily.ttf", "Starburst.ttf", "The Centurion .ttf",
      "Vanilla.ttf", "Wonderland.ttf",
    },
  },
  ["Easy-to-Read"] = {
    path  = "Interface\\AddOns\\NiceClock\\Easy-to-Read\\",
    fonts = {
      -- Existing fonts
      "AlteHaasGroteskBold.ttf", "Expressway.ttf", "NotoSans_Condensed-Bold.ttf",
      "PTSansNarrow-Bold.ttf", "Prototype.ttf", "Roboto-Bold.ttf",
      "SF-Pro.ttf", "accidentalpres.ttf", "bignoodletitling.ttf",
      "continuum.ttf", "pf_tempesta_seven.ttf",
      -- Newly added fonts
      "2cute.ttf", "Acadian.ttf", "Rockybilly.ttf", "SShiny.ttf",
      "Wmelody.ttf", "Youngserif.ttf",
    },
  },
  ["Custom"] = {
    -- Folder for user provided fonts. We support up to twenty numbered fonts
    -- named 1.ttf through 20.ttf. Users may place their own files here. Some
    -- earlier versions of the addon referred to this directory as
    -- "Custom(1-20)" while the repository also ships a "CombatFonts" folder.
    -- To cover all cases we attempt to load numbered fonts from any of these
    -- locations.
    paths = {
      "Interface\\AddOns\\NiceClock\\Custom\\",
      "Interface\\AddOns\\NiceClock\\CombatFonts\\",
      "Interface\\AddOns\\NiceClock\\Custom(1-20)\\",
    },
    fonts = {},
  },
}

-- Populate custom font list with numbered file names
for i = 1, 20 do
  table.insert(COMBAT_FONT_GROUPS["Custom"].fonts, i .. ".ttf")
end

-- Store Blizzard’s original combat-text fonts so we can restore them
local ORIGINAL_DAMAGE_TEXT_FONT = _G["DAMAGE_TEXT_FONT"]
local ORIGINAL_COMBAT_TEXT_FONT = _G["COMBAT_TEXT_FONT"]

-- Cache fonts so they can be previewed in the options panel
local combatFontCache  = {}
local combatFontExists = {}
for group, data in pairs(COMBAT_FONT_GROUPS) do
  combatFontCache[group]  = {}
  combatFontExists[group] = {}
  local basePaths = data.paths or {data.path}
  for _, fname in ipairs(data.fonts) do
    local fontObj, relPath, absPath
    for _, base in ipairs(basePaths) do
      local path = base .. fname
      local f    = CreateFont(addonName .. "CombatFont" .. group .. fname)
      f:SetFont(path, 20, "")
      local loaded = f:GetFont()
      if loaded and loaded:lower():find(fname:lower(), 1, true) then
        fontObj = f
        if group == "Custom" then
          -- Always save using the virtual Custom/ prefix so dropdown logic
          -- remains stable regardless of the actual folder used.
          relPath = "Custom/" .. fname
        else
          relPath = path:match("Interface\\AddOns\\NiceClock\\(.+)$") or (group .. "/" .. fname)
          relPath = relPath:gsub("\\", "/")
        end
        absPath = path
        break
      end
    end
    if fontObj then
      combatFontExists[group][fname] = true
      combatFontCache[group][fname]  = {font=fontObj, relative=relPath, path=absPath}
    else
      combatFontExists[group][fname] = false
    end
  end
end

-- ─── Frame & Font Path ────────────────────────────────────────────────────────
local frame        = CreateFrame("Frame", "NiceClockFrame", UIParent)
local FONT_FOLDER  = "Interface\\AddOns\\NiceClock\\ClockFonts\\"
local AVAILABLE_FONTS = {
  -- Complete list of fonts found in ClockFonts
  "Acadian",
  "Digital",
  "Elven",
  "Gunung",
  "Hobbit",
  "Kting",
  "Ktingw",
  "Monster",
  "Odinson",
  "Orbitron",
  "Roboto",
  "Ruritania",
  "SF-Pro-Regular",
  "The Centurion ",
}

-- ─── Global Defaults ───────────────────────────────────────────────────────────
local DEFAULTS = {
  fontSize            = 20,
  showDate            = true,
  is24h               = false,
  showSeconds         = false,
  fontName            = "SF-Pro-Regular",
  fontColor           = {1,1,1,1},
  -- RGB animation default
  rgbClock           = false,
  -- Wave animation default (formerly "bounce")
  waveClock          = false,
  minimapAnchorPoint  = "TOPLEFT",
  minimapRelativePoint= "TOPLEFT",
  minimapX            = 0,
  minimapY            = 0,
  allowMove           = true,
  hideClock           = false,
  -- Hide the small icon beside the clock by default on first install.
  -- Users can re-enable it in Clock Settings.
  hideIcon            = true,
  alarmTime           = "",    -- Added default alarm time
  alarmReminder       = "",    -- Added default reminder text
  alarmTimestamp      = 0,     -- epoch when relative alarm should trigger
  alarms             = {},    -- table of pending alarms
  alarmDuration      = 20,    -- seconds alarm stays active
  -- BEGIN FEATURE: server time and hourly chime defaults
  useServerTime       = false,
  hourlyChime         = false,
  timezoneOffset      = 0, -- hours difference from local/server time
  -- END FEATURE
  -- BEGIN TRACKING DEFAULTS
  trackSession        = false,
  trackDay            = false,
  trackWeek           = false,
  trackMonth          = false,
  trackYear           = false,
  trackTooltip        = false,
  dayDate             = "",    -- date identifier for daily tracking
  daySeconds          = 0,     -- accumulated seconds for current day
  weekID              = "",    -- week identifier for weekly tracking
  weekSeconds         = 0,     -- accumulated seconds for current week
  monthID             = "",    -- month identifier for current month
  monthSeconds        = 0,     -- accumulated seconds for current month
  yearID              = "",    -- year identifier for current year
  yearSeconds         = 0,     -- accumulated seconds for current year
  -- Per-character /played totals (keyed by "Name-Realm").
  -- This only accumulates for characters that you log into with NiceClock enabled.
  playedByCharacter   = {},
  -- END TRACKING DEFAULTS
}
for k, v in pairs(DEFAULTS) do
  if NiceClockDB[k] == nil then NiceClockDB[k] = v end
end

-- Ensure tracking tables exist even on upgraded installs.
if type(NiceClockDB.playedByCharacter) ~= "table" then
  NiceClockDB.playedByCharacter = {}
end

-- Migrate legacy single alarm fields to new alarm table
if NiceClockDB.alarms == nil then NiceClockDB.alarms = {} end
do
  local h, m = (NiceClockDB.alarmTime or ""):match("^(%d?%d):(%d%d)$")
  if h and m then
    table.insert(NiceClockDB.alarms, {hour = tonumber(h), min = tonumber(m), text = NiceClockDB.alarmReminder or ""})
  end
  if NiceClockDB.alarmTimestamp and NiceClockDB.alarmTimestamp > 0 then
    table.insert(NiceClockDB.alarms, {timestamp = NiceClockDB.alarmTimestamp, text = NiceClockDB.alarmReminder or ""})
  end
  NiceClockDB.alarmTime = ""
  NiceClockDB.alarmTimestamp = 0
  NiceClockDB.alarmReminder = ""
end

-- Backward compatibility: migrate old bounceClock setting to waveClock
if NiceClockDB.waveClock == nil and NiceClockDB.bounceClock ~= nil then
  NiceClockDB.waveClock = NiceClockDB.bounceClock
  NiceClockDB.bounceClock = nil
end

-- ─── Per-Character QoL & Combat Defaults ──────────────────────────────────────
local PERCHAR_DEFAULTS = {
  hideTracker    = false,
  trackerScale   = 1,
  enable3dPortraits = false,
  autoSellJunk   = false,
  fastAutoLoot   = false,
  combatHealing  = tonumber(GetCVar("floatingCombatTextCombatHealing")) == 1,
  combatDamage   = tonumber(GetCVar("floatingCombatTextCombatDamage")) == 1,
  petDamage      = tonumber(GetCVar("floatingCombatTextPetMeleeDamage")) == 1,
  periodicDamage = tonumber(GetCVar("floatingCombatTextPeriodicDamage")) == 1,
  combatFont     = nil,  -- e.g. "3.ttf"
}
for k, v in pairs(PERCHAR_DEFAULTS) do
  if NiceClockPerCharDB[k] == nil then NiceClockPerCharDB[k] = v end
end

-- ─── Preload All Clock Fonts ─────────────────────────────────────────────────
-- must come *after* DEFAULTS so NiceClockDB.fontSize is valid
for _, fname in ipairs(AVAILABLE_FONTS) do
  local path = FONT_FOLDER .. fname .. ".ttf"
  local preloadFont = CreateFont(addonName.."PreloadFont"..fname)
  preloadFont:SetFont(path, NiceClockDB.fontSize, "")  -- empty-string flags
end

-- WoW already exposes the realm clock, so we no longer track a manual
-- difference between local and server time. Instead we query the game for the
-- current server hour/minute when needed.
local function GetServerClock()
  if C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime then
    local t = C_DateAndTime.GetCurrentCalendarTime()
    local sec = GetServerTime and GetServerTime() or time()
    return t.hour, t.minute, math.floor(sec % 60)
  elseif GetGameTime then
    local h, m = GetGameTime()
    local sec = GetServerTime and GetServerTime() or time()
    return h, m, math.floor(sec % 60)
  else
    -- Fallback: use local clock
    return tonumber(date("%H")), tonumber(date("%M")), tonumber(date("%S"))
  end
end

-- ─── Helper: format seconds as "Xh Ym" ────────────────────────────────────────
function frame:FormatSeconds(sec)
  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  return string.format("%dh %dm", h, m)
end

-- Helper: format a large duration (seconds) as "Xd HH:MM:SS".
-- Used for total /played displays.
function frame:FormatPlayedSeconds(sec)
  sec = tonumber(sec) or 0
  if sec < 0 then sec = 0 end

  local days = math.floor(sec / 86400)
  local rem  = sec % 86400
  local h    = math.floor(rem / 3600)
  rem        = rem % 3600
  local m    = math.floor(rem / 60)
  local s    = rem % 60

  if days > 0 then
    return string.format("%dd %02d:%02d:%02d", days, h, m, s)
  end
  return string.format("%02d:%02d:%02d", h, m, s)
end

-- Build a stable per-character key for tables.
function frame:GetPlayerKey()
  local name, realm = UnitFullName and UnitFullName("player") or nil
  if not name then name = UnitName("player") end
  if not realm or realm == "" then realm = GetRealmName and GetRealmName() or "" end
  if realm and realm ~= "" then
    return name .. "-" .. realm
  end
  return name or ""
end

-- Current character /played that increases while logged in.
-- We store the last reported total from TIME_PLAYED_MSG and add elapsed session time.
function frame:GetCurrentCharacterPlayedSeconds()
  local base = tonumber(self.playedBaseSeconds)
  local at   = tonumber(self.playedReceivedAt)
  if not base or not at then
    -- Fallback: show last stored snapshot (stays static until a fresh snapshot arrives).
    local key = self:GetPlayerKey()
    local stored = key and NiceClockDB.playedByCharacter and NiceClockDB.playedByCharacter[key]
    if type(stored) == "number" then
      return stored
    end
    return nil
  end

  -- Use GetTime() (time since login) when available to avoid issues if system time changes.
  local now = (GetTime and GetTime()) or time()
  local delta = now - at
  if delta < 0 then delta = 0 end

  -- /played totals are integer seconds.
  return base + math.floor(delta)
end

-- All-character /played total, summing only characters that have been logged
-- into with NiceClock enabled.
function frame:GetAllTrackedCharactersPlayedSeconds()
  local tbl = NiceClockDB.playedByCharacter
  if type(tbl) ~= "table" then
    NiceClockDB.playedByCharacter = {}
    tbl = NiceClockDB.playedByCharacter
  end

  local sum, count = 0, 0
  for _, v in pairs(tbl) do
    if type(v) == "number" then
      sum = sum + v
      count = count + 1
    end
  end

  -- Add current-session growth for the current character (so it ticks upward).
  local key = self:GetPlayerKey()
  local cur = self:GetCurrentCharacterPlayedSeconds()
  if cur and key then
    if type(tbl[key]) == "number" then
      sum = sum + (cur - tbl[key])
    else
      -- If we have a live value but no stored snapshot yet, still include it.
      sum = sum + cur
      count = count + 1
    end
  end

  return sum, count
end

-- Build a stable-width sample string for sizing the frame when seconds are shown.
-- This prevents the entire frame from shifting if it's anchored by CENTER.
function frame:BuildStableTimeSample()
  local parts = {}
  if NiceClockDB.showDate then
    -- Use a representative 3-letter day/month and a 2-digit day-of-month for max width.
    tinsert(parts, "Wed")
    tinsert(parts, "Sep")
    tinsert(parts, "30")
  end

  local timeStr
  if NiceClockDB.showSeconds then
    timeStr = "88:88:88"
  else
    timeStr = "88:88"
  end
  tinsert(parts, timeStr)

  if not NiceClockDB.is24h then
    tinsert(parts, "PM")
  end

  return table.concat(parts, " ")
end

-- Resize the clock frame to fit the current (or stable sample) text.
-- When seconds are shown, we use the stable sample to avoid jitter.
function frame:UpdateClockFrameSize()
  if not self.fs then return end

  local iconSize = (NiceClockDB.fontSize or DEFAULTS.fontSize) * 2
  local gap      = -10
  local pad      = 10

  local showIcon = (not NiceClockDB.hideClock) and (not NiceClockDB.hideIcon)
  local leftInset = showIcon and (iconSize + gap) or 0

  -- Measure text width using an invisible fontstring with identical font settings.
  if not self.measureFS then
    self.measureFS = frame:CreateFontString(nil, "OVERLAY")
    self.measureFS:SetAlpha(0)
    self.measureFS:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  end

  local fontFile = FONT_FOLDER .. (NiceClockDB.fontName or DEFAULTS.fontName) .. ".ttf"
  pcall(self.measureFS.SetFont, self.measureFS, fontFile, NiceClockDB.fontSize, "")

  -- Always measure using a stable sample string. This prevents the clock frame
  -- from "breathing" as digits change (seconds/minutes/hours) and keeps the
  -- click/drag area consistent.
  local measureText = self:BuildStableTimeSample()
  self.measureFS:SetText(measureText)

  -- Round to whole pixels to avoid tiny per-frame width differences.
  local textWidth = math.ceil(self.measureFS:GetStringWidth() or 0)
  local frameWidth = leftInset + textWidth + pad
  local frameHeight = showIcon and (iconSize + pad) or (NiceClockDB.fontSize + pad)
  frame:SetSize(frameWidth, frameHeight)
end

-- ─── Hitbox / Drag Area Reliability ──────────────────────────────────────────
-- BEGIN FIX: Post-login hitbox sizing (drag works on first login)
-- Some clients can report a 0/near-0 font width for a frame or two immediately
-- after PLAYER_LOGIN, leaving the clock frame's click/drag hitbox extremely small
-- even though the text is visible. We re-measure briefly to ensure the hitbox
-- matches the visible clock text without requiring any settings changes.
function frame:EnsureClockHitbox()
  if self._ensureClockHitboxRunning then return end
  if not self.fs then return end
  if NiceClockDB.hideClock then return end

  self._ensureClockHitboxRunning = true
  local tries = 0

  local function HitboxTooSmall()
    local w, h = self:GetSize()
    -- At our minimum font size, even a short time string is wider/taller than this.
    return (not w or not h or w < 25 or h < 15)
  end

  if C_Timer and C_Timer.After then
    local function Step()
      tries = tries + 1
      self:UpdateClockFrameSize()

      if (not HitboxTooSmall()) or tries >= 60 then
        self._ensureClockHitboxRunning = nil
        return
      end

      C_Timer.After(0, Step)
    end

    -- Start on the next frame so fonts have had a chance to finalize.
    C_Timer.After(0, Step)
  else
    -- Fallback: keep trying via OnUpdate if C_Timer isn't available
    local prevOnUpdate = self:GetScript("OnUpdate")
    self:SetScript("OnUpdate", function(me, elapsed)
      if prevOnUpdate then
        pcall(prevOnUpdate, me, elapsed)
      end

      tries = tries + 1
      me:UpdateClockFrameSize()

      if (not HitboxTooSmall()) or tries >= 60 then
        me:SetScript("OnUpdate", prevOnUpdate)
        me._ensureClockHitboxRunning = nil
      end
    end)
  end
end
-- END FIX

-- Helper to play sounds across API versions
--
-- Play a sound file and return its handle if available. WoW's sound API has
-- changed signatures over time, so we defensively check each return value and
-- only propagate a numeric sound handle.
--
local function SafePlaySound(path)
  local h1, h2

  if C_Sound and C_Sound.PlaySoundFile then
    h1, h2 = C_Sound.PlaySoundFile(path, "Master")
  elseif PlaySoundFile then
    local ok; ok, h1, h2 = pcall(PlaySoundFile, path, "Master")
    if not ok then h1, h2 = nil, nil end
  elseif PlaySound then
    pcall(PlaySound, SOUNDKIT.RAID_WARNING, "Master")
    return nil
  end

  -- Prefer the second return (Retail), otherwise the first if numeric
  if type(h2) == "number" then return h2 end
  if type(h1) == "number" then return h1 end
  return nil
end

-- Helper to stop sounds started with SafePlaySound
local function SafeStopSound(handle)
  if type(handle) ~= "number" then return end

  if C_Sound and C_Sound.StopSoundFile then
    C_Sound.StopSoundFile(handle)
  elseif C_Sound and C_Sound.StopSound then
    C_Sound.StopSound(handle)
  elseif StopSoundFile then
    StopSoundFile(handle)
  elseif StopSound then
    StopSound(handle)
  end
end

-- Utility: show tracking tooltip anchored to a frame
function frame:ShowTrackingTooltip(anchor)
  if not NiceClockDB.trackTooltip then return end
  GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
  local now = time()
  local sessionElapsed = now - (self.sessionStart or now)
  if NiceClockDB.trackSession then
    GameTooltip:AddLine("Session: " .. self:FormatSeconds(sessionElapsed))
  end
  if NiceClockDB.trackDay then
    local dayTotal = (NiceClockDB.daySeconds or 0) + sessionElapsed
    GameTooltip:AddLine("Today: " .. self:FormatSeconds(dayTotal))
  end
  if NiceClockDB.trackWeek then
    local weekTotal = (NiceClockDB.weekSeconds or 0) + sessionElapsed
    GameTooltip:AddLine("This Week: " .. self:FormatSeconds(weekTotal))
  end
  if NiceClockDB.trackMonth then
    local monthTotal = (NiceClockDB.monthSeconds or 0) + sessionElapsed
    GameTooltip:AddLine("This Month: " .. self:FormatSeconds(monthTotal))
  end
  if NiceClockDB.trackYear then
    local yearTotal = (NiceClockDB.yearSeconds or 0) + sessionElapsed
    GameTooltip:AddLine("This Year: " .. self:FormatSeconds(yearTotal))
  end
  GameTooltip:Show()
end

-- BEGIN FEATURE: helper for local time with optional timezone offset
local function GetLocalTimeValue(fmt)
  local ts = time()
  if NiceClockDB.timezoneOffset and NiceClockDB.timezoneOffset ~= 0 then
    ts = ts + NiceClockDB.timezoneOffset * 3600
  end
  return date(fmt, ts)
end
-- END FEATURE

-- Small utility to create a checkbutton with sane defaults
local function CreateCheckbox(parent, name, label, x, y, checked, onClick, onEnter, onLeave, relativeTo, relativePoint, point)
  local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
  point = point or "TOPLEFT"
  relativePoint = relativePoint or point
  relativeTo = relativeTo or parent
  cb:SetPoint(point, relativeTo, relativePoint, x, y)
  cb.text:SetText(label)
  cb:SetChecked(checked)
  if onClick then cb:SetScript("OnClick", onClick) end
  if onEnter then cb:SetScript("OnEnter", onEnter) end
  if onLeave then cb:SetScript("OnLeave", onLeave) end
  return cb
end

-- ─── Quality of Life Modules ────────────────────────────────────────────────
local portraitManager = {
  enabled = false,
  portraits = {},
  forbidden = {
    ["AchievementFrameComparisonHeaderPortrait"] = true,
  },
  minSize = 30,
}

function portraitManager:CreateModel(texture, unit)
  local parent = texture:GetParent()
  local model = CreateFrame("PlayerModel", nil, parent)
  model:SetAllPoints(texture)
  model:SetFrameLevel((parent and parent.GetFrameLevel and parent:GetFrameLevel() or 0) + 1)
  if model.SetModelDrawLayer and texture.GetDrawLayer then
    model:SetModelDrawLayer(texture:GetDrawLayer() or "ARTWORK")
  end
  model:Hide()

  local data = {
    model = model,
    unit = unit,
  }
  self.portraits[texture] = data

  if parent and parent.HookScript then
    parent:HookScript("OnShow", function()
      if portraitManager.enabled then
        portraitManager:UpdateTexture(texture, unit, true)
      end
    end)
  end

  return data
end

function portraitManager:IsAllowed(texture, unit)
  if not self.enabled then return false end
  if not texture or not unit or not UnitExists(unit) then return false end
  if texture.noNiceClockPortrait then return false end
  local name = texture:GetName()
  if name and self.forbidden[name] then return false end
  local w = texture:GetWidth() or 0
  local h = texture:GetHeight() or 0
  if w < self.minSize or h < self.minSize then return false end
  return true
end

function portraitManager:UpdateTexture(texture, unit, force)
  if not texture or not unit then return end
  local data = self.portraits[texture]
  if not data then
    data = self:CreateModel(texture, unit)
  end
  data.unit = unit

  if self:IsAllowed(texture, unit) then
    data.model:SetUnit(unit)
    data.model:SetPortraitZoom(1)
    if data.model.SetCamDistanceScale then
      data.model:SetCamDistanceScale(1)
    end
    if data.model.SetRotation then
      data.model:SetRotation(0)
    end
    data.model:Show()
    texture:Hide()
  else
    if data.model then data.model:Hide() end
    texture:Show()
  end
end

function portraitManager:RefreshAll()
  for texture, data in pairs(self.portraits) do
    self:UpdateTexture(texture, data.unit, true)
  end
end

function portraitManager:SetEnabled(enabled)
  self.enabled = enabled and true or false
  self:RefreshAll()
end

-- ─── Clock Core ───────────────────────────────────────────────────────────────
function frame:RestartTicker()
  if self.ticker then self.ticker:Cancel() end
  local interval = NiceClockDB.showSeconds and 1 or 60
  self.ticker = C_Timer.NewTicker(interval, function() self:UpdateTime() end)
end

-- Start color cycling for RGB clock
function frame:StartRGBTicker()
  if self.rgbTicker then self.rgbTicker:Cancel() end
  local alpha = (NiceClockDB.fontColor and NiceClockDB.fontColor[4]) or 1
  self.rgbAngle = 0                               -- track angle for new strings
  local function applyColor(angle)
    local r = (math.sin(angle) + 1) / 2
    local g = (math.sin(angle + 2 * math.pi / 3) + 1) / 2
    local b = (math.sin(angle + 4 * math.pi / 3) + 1) / 2
    self.rgbColor = {r, g, b, alpha}              -- store current color for wave strings
    self.fs:SetTextColor(r, g, b, alpha)
    if self.icon then self.icon:SetVertexColor(r, g, b, alpha) end
    if self.shadows then
      for _, s in ipairs(self.shadows) do
        s:SetTextColor(r, g, b, alpha * 0.3)
      end
    end
    if self.waveStrings then
      for _, ws in ipairs(self.waveStrings) do
        ws:SetTextColor(r, g, b, alpha)
      end
    end
  end

  -- Apply the initial color immediately to avoid flashes
  applyColor(self.rgbAngle)

  self.rgbTicker = C_Timer.NewTicker(0.05, function()
    self.rgbAngle = (self.rgbAngle or 0) + math.pi * 0.05
    applyColor(self.rgbAngle)
  end)
end

-- Stop RGB color cycling
function frame:StopRGBTicker()
  if self.rgbTicker then
    self.rgbTicker:Cancel()
    self.rgbTicker = nil
    self.rgbAngle = nil
    self.rgbColor = nil
  end
end

-- Start per-digit wave animation
function frame:StartWaveTicker()
  if self.waveTicker then self.waveTicker:Cancel() end
  local amp   = math.max(2, math.floor(NiceClockDB.fontSize * 0.2))
  local angle = 0
  local phase = 0.4
  self.waveTicker = C_Timer.NewTicker(0.05, function()
    angle = angle + 0.2
    if self.waveStrings then
      for i, ws in ipairs(self.waveStrings) do
        local offset = math.sin(angle + i * phase) * amp
        ws.currentOffset = offset
        ws:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", ws.baseX, (ws.baseY or 0) + offset)
      end
    end
  end)
end

-- Stop wave animation
function frame:StopWaveTicker()
  if self.waveTicker then
    self.waveTicker:Cancel()
    self.waveTicker = nil
  end
end

function frame:UpdateTime()
  local parts = {}
  if NiceClockDB.showDate then
    -- Date elements always use the local clock
    tinsert(parts, date("%a"))
    tinsert(parts, date("%b"))
    tinsert(parts, tostring(tonumber(date("%e"))))
  end

  if NiceClockDB.useServerTime then
    local h, m, s = GetServerClock()
    local hr
    if NiceClockDB.is24h then
      hr = string.format("%02d", h)
    else
      local disp = h % 12
      if disp == 0 then disp = 12 end
      hr = tostring(disp)
    end
    local min = string.format("%02d", m)
    if NiceClockDB.showSeconds then
      local sec = string.format("%02d", s)
      tinsert(parts, string.format("%s:%s:%s", hr, min, sec))
    else
      tinsert(parts, string.format("%s:%s", hr, min))
    end
    if not NiceClockDB.is24h then
      tinsert(parts, h < 12 and "AM" or "PM")
    end
  else
    local hr  = NiceClockDB.is24h and GetLocalTimeValue("%H") or GetLocalTimeValue("%I"):gsub("^0", "")
    local min = GetLocalTimeValue("%M")
    if NiceClockDB.showSeconds then
      tinsert(parts, string.format("%s:%s:%s", hr, min, GetLocalTimeValue("%S")))
    else
      tinsert(parts, string.format("%s:%s", hr, min))
    end
    if not NiceClockDB.is24h then
      tinsert(parts, GetLocalTimeValue("%p"))
    end
  end

  local text = table.concat(parts, " ")
  self.fs:SetText(text)
  if self.shadows then
    for _, s in ipairs(self.shadows) do
      s:SetText(text)
    end
  end
  -- Handle wave display
  if NiceClockDB.waveClock and not NiceClockDB.hideClock then
    self:UpdateWaveStrings(text)
    self.fs:Hide()
  else
    if self.waveStrings then
      for _, ws in ipairs(self.waveStrings) do ws:Hide() end
    end
    if not NiceClockDB.hideClock then self.fs:Show() end
  end
  -- BEGIN FEATURE: update LDB feed
  if self.dataObject then
    self.dataObject.text = text
  end
  -- END FEATURE

  -- Do not resize the frame every tick (can cause visible "jitter"/shifting).
  -- We size the frame in ApplySettings() using a stable sample string.
end

-- Update or create per-character font strings for wave effect
function frame:UpdateWaveStrings(text)
  self.waveStrings = self.waveStrings or {}
  local fontFile = FONT_FOLDER .. (NiceClockDB.fontName or DEFAULTS.fontName) .. ".ttf"
  local c = NiceClockDB.fontColor or {1,1,1,1}
  -- When RGB mode is active, use the current RGB color for new strings
  if NiceClockDB.rgbClock and type(self.rgbColor) == "table" then
    c = self.rgbColor
  end

  local iconSize = NiceClockDB.fontSize * 2
  local gap      = -10
  local showIcon = (not NiceClockDB.hideClock) and (not NiceClockDB.hideIcon)
  local startX   = showIcon and (iconSize + gap) or 0
  local x = startX
  for i = 1, #text do
    local ch = text:sub(i,i)
    local fs = self.waveStrings[i]
    if not fs then
      fs = frame:CreateFontString(nil, "OVERLAY")
      self.waveStrings[i] = fs
      fs.baseY = 0
      fs.currentOffset = 0
    end
    fs:SetFont(fontFile, NiceClockDB.fontSize, "")
    fs:SetTextColor(unpack(c)) -- color already adjusted above
    fs:SetText(ch)
    fs:Show()
    fs:ClearAllPoints()
    fs.baseX = x
    local yPos = (fs.baseY or 0) + (fs.currentOffset or 0)
    fs:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", x, yPos)
    x = x + fs:GetStringWidth()
  end
  for j = #text + 1, #self.waveStrings do
    self.waveStrings[j]:Hide()
  end
end

function frame:ApplySettings()
  -- The frame components may not exist during very early loading
  if not self.fs then return end
  if NiceClockDB.fontSize < 15 then NiceClockDB.fontSize = 15 end

  local fontFile = FONT_FOLDER .. (NiceClockDB.fontName or DEFAULTS.fontName) .. ".ttf"

  -- ── BEGIN FIX: Apply font and force redraw immediately ───────────────────
  -- Safely set the new font, then clear & re‐set the text to force the UI to redraw
  local style = ""
  pcall(self.fs.SetFont, self.fs, fontFile, NiceClockDB.fontSize, style)
  local currentText = self.fs:GetText()
  self.fs:SetText("")                -- clear the text
  self.fs:SetText(currentText)       -- reset it, forcing an immediate redraw
  -- ── END FIX ─────────────────────────────────────────────────────────────

  local c = NiceClockDB.fontColor
  if type(c)~="table" or #c<4 then c={1,1,1,1}; NiceClockDB.fontColor=c end
  -- Stop any existing RGB ticker before applying color changes
  self:StopRGBTicker()

  self.fs:SetTextColor(unpack(c))
  if self.icon then self.icon:SetVertexColor(unpack(c)) end

  -- Disable Blizzard shadow; halo handled via extra FontStrings
  self.fs:SetShadowColor(0, 0, 0, 0)
  self.fs:SetShadowOffset(0, 0)

  -- Update shadow font strings (used previously for glow effect)
  if self.shadows then
    for _, s in ipairs(self.shadows) do
      pcall(s.SetFont, s, fontFile, NiceClockDB.fontSize, "")
      s:SetShadowColor(0, 0, 0, 0)
      s:SetShadowOffset(0, 0)
      s:SetTextColor(c[1], c[2], c[3], 0.3)
      -- Glow feature removed – always hide the shadow strings
      s:Hide()
    end
  end

  -- Start RGB color cycling if requested
  if NiceClockDB.rgbClock then self:StartRGBTicker() end

  local iconSize = NiceClockDB.fontSize * 2
  local gap      = -10
  local descent  = -math.floor(NiceClockDB.fontSize * 0.19)
  local pad      = 10

  local showIcon = (not NiceClockDB.hideClock) and (not NiceClockDB.hideIcon)
  local leftInset = showIcon and (iconSize + gap) or 0

  self.fs:ClearAllPoints()
  self.fs:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", leftInset, 0)

  if self.icon then
    self.icon:SetSize(iconSize, iconSize)
    self.icon:ClearAllPoints()
    if showIcon then
      self.icon:SetPoint("BOTTOMRIGHT", self.fs, "BOTTOMLEFT", -gap, descent)
      self.icon:Show()
    else
      self.icon:Hide()
    end
  end

  if self.iconButton then
    self.iconButton:SetShown(showIcon)
  end

  -- Update the text before sizing so the frame matches the current settings.
  self:UpdateTime()
  self:UpdateClockFrameSize()

  if NiceClockDB.hideClock then
    self.fs:Hide()
  else
    -- If wave mode is enabled, UpdateTime hides the main fs and draws waveStrings.
    if not NiceClockDB.waveClock then self.fs:Show() end
  end

  self:RestartTicker()

  -- Manage wave ticker based on setting
  self:StopWaveTicker()
  if NiceClockDB.waveClock and not NiceClockDB.hideClock then
    self:StartWaveTicker()
  end
end

-- ─── Draggable / Click-Through Logic ──────────────────────────────────────────
function frame:ApplyMoveSettings()
  frame:ClearAllPoints()
  if NiceClockDB.positionPoint then
    frame:SetPoint(NiceClockDB.positionPoint, UIParent,
                   NiceClockDB.positionRelPoint, NiceClockDB.positionX, NiceClockDB.positionY)
  else
    -- BEGIN FIX: better default placement on first install
    -- Show the clock near the top-center so it is not hidden by action bars on older clients.
    frame:SetPoint("TOP", UIParent, "TOP", 0, -30)
    -- END FIX
  end

  if frame.fs then frame.fs:EnableMouse(false) end
  if frame.icon then frame.icon:EnableMouse(false) end

  if NiceClockDB.allowMove then
    frame:EnableMouse(true); frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
      self:StopMovingOrSizing()
      local p,_,rp,x,y = self:GetPoint()
      NiceClockDB.positionPoint    = p
      NiceClockDB.positionRelPoint = rp
      NiceClockDB.positionX        = x
      NiceClockDB.positionY        = y
    end)

    if frame.iconButton then
      -- BEGIN FIX: Ensure iconButton drives the frame move when toggled
      frame.iconButton:SetMovable(true)
      frame.iconButton:RegisterForDrag("LeftButton")
      frame.iconButton:SetScript("OnDragStart", function(self)
        frame:StartMoving()
      end)
      frame.iconButton:SetScript("OnDragStop", function(self)
        frame:StopMovingOrSizing()
        local p,_,rp,x,y = frame:GetPoint()
        NiceClockDB.positionPoint    = p
        NiceClockDB.positionRelPoint = rp
        NiceClockDB.positionX        = x
        NiceClockDB.positionY        = y
      end)
      -- END FIX
    end
  else
    frame:EnableMouse(false); frame:SetMovable(false)
    frame:RegisterForDrag(); frame:SetScript("OnDragStart", nil)
    frame:SetScript("OnDragStop",  nil)
    if frame.iconButton then
      -- BEGIN FIX: Disable movable on iconButton when dragging is disallowed
      frame.iconButton:SetMovable(false)
      frame.iconButton:RegisterForDrag()
      frame.iconButton:SetScript("OnDragStart", nil)
      frame.iconButton:SetScript("OnDragStop", nil)
      -- END FIX
    end
  end
end

-- ─── Minimap Icon ────────────────────────────────────────────────────────────
function frame:CreateMinimapIcon()
  if self.minimapIcon then return end
  local f = self

  local icon = CreateFrame("Button", "NiceClockMinimapButton", Minimap)
  icon:SetSize(32,32)
  icon:ClearAllPoints()
  icon:SetPoint(NiceClockDB.minimapAnchorPoint, Minimap, NiceClockDB.minimapRelativePoint, NiceClockDB.minimapX, NiceClockDB.minimapY)
  local t = icon:CreateTexture(nil,"BACKGROUND")
  t:SetTexture("Interface\\AddOns\\NiceClock\\NiceClockiconMM.png")
  t:SetAllPoints(icon)
  icon.texture = t
  icon:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  icon:RegisterForClicks("AnyUp")
  icon:SetScript("OnClick", function(_,btn)
    if btn=="LeftButton" then f:ToggleSettings() else print(addonName..": Left-click to open settings.") end
  end)
  icon:SetMovable(true); icon:EnableMouse(true)
  icon:RegisterForDrag("LeftButton")
  icon:SetScript("OnDragStart", function(self)
    self:LockHighlight()
    self:SetScript("OnUpdate", function(self)
      local mx,my = Minimap:GetCenter()
      local scale = Minimap:GetEffectiveScale()
      local cx,cy = GetCursorPosition()
      local dx,dy = (cx/scale-mx),(cy/scale-my)
      local angle  = math.atan2(dy, dx)
      local radius = Minimap:GetWidth()/2 + 10
      self:ClearAllPoints()
      self:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle)*radius, math.sin(angle)*radius)
    end)
  end)
  icon:SetScript("OnDragStop", function(self)
    self:UnlockHighlight()
    self:SetScript("OnUpdate", nil)
    local p,_,rp,x,y = self:GetPoint()
    NiceClockDB.minimapAnchorPoint   = p
    NiceClockDB.minimapRelativePoint = rp
    NiceClockDB.minimapX             = x
    NiceClockDB.minimapY             = y
  end)

  -- BEGIN MINIMAP ICON HOVER TOOLTIP
  icon:SetScript("OnEnter", function(self)
    if NiceClockDB.trackTooltip then
      frame:ShowTrackingTooltip(self)
    else
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine("NiceClock")
      GameTooltip:Show()
    end
  end)
  icon:SetScript("OnLeave", GameTooltip_Hide)
  -- END MINIMAP ICON HOVER TOOLTIP

  self.minimapIcon = icon
end

-- ─── LibDataBroker Feed -------------------------------------------------------
function frame:CreateLDB()
  if self.dataObject then return end
  local ldb = LibStub and LibStub:GetLibrary("LibDataBroker-1.1", true)
  if not ldb then return end
  local obj = ldb:NewDataObject(addonName, {
    type = "data source",
    text = "",
    icon = "Interface\\AddOns\\NiceClock\\NiceClockicon.tga",
  })
  obj.OnClick = function(_, btn)
    if btn == "LeftButton" then frame:ToggleSettings() end
  end
  obj.OnTooltipShow = function(tt)
    tt:AddLine(addonName)
    if NiceClockDB.trackTooltip then
      local now = time()
      local sessionElapsed = now - (frame.sessionStart or now)
      if NiceClockDB.trackSession then tt:AddLine("Session: " .. frame:FormatSeconds(sessionElapsed)) end
      if NiceClockDB.trackDay then
        local total = (NiceClockDB.daySeconds or 0) + sessionElapsed
        tt:AddLine("Today: " .. frame:FormatSeconds(total))
      end
      if NiceClockDB.trackWeek then
        local total = (NiceClockDB.weekSeconds or 0) + sessionElapsed
        tt:AddLine("This Week: " .. frame:FormatSeconds(total))
      end
      if NiceClockDB.trackMonth then
        local total = (NiceClockDB.monthSeconds or 0) + sessionElapsed
        tt:AddLine("This Month: " .. frame:FormatSeconds(total))
      end
      if NiceClockDB.trackYear then
        local total = (NiceClockDB.yearSeconds or 0) + sessionElapsed
        tt:AddLine("This Year: " .. frame:FormatSeconds(total))
      end
    else
      tt:AddLine("Left-click to open settings")
    end
  end
  self.dataObject = obj
  self:UpdateTime()
end

-- ─── QoL Settings ───────────────────────────────────────────────────────────
function frame:ApplyQoLSettings()
  if ObjectiveTrackerFrame then
    if NiceClockPerCharDB.hideTracker then
      ObjectiveTrackerFrame:Hide()
    else
      ObjectiveTrackerFrame:Show()
    end
    ObjectiveTrackerFrame:SetScale(NiceClockPerCharDB.trackerScale or 1)
  end
  portraitManager:SetEnabled(NiceClockPerCharDB.enable3dPortraits)
end

function frame:SellJunkItems()
  local total = 0
  local maxBag = NUM_BAG_SLOTS or 4
  for bag = BACKPACK_CONTAINER, maxBag do
    local slots = C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerNumSlots(bag) or GetContainerNumSlots(bag)
    for slot = 1, (slots or 0) do
      local info = C_Container and C_Container.GetContainerItemInfo and C_Container.GetContainerItemInfo(bag, slot) or nil
      local quality = info and info.quality or select(4, GetContainerItemInfo(bag, slot))
      local locked = info and info.isLocked or select(3, GetContainerItemInfo(bag, slot))
      local hasNoValue = info and info.hasNoValue

      if quality == 0 and not locked and not hasNoValue then
        local link = (info and info.hyperlink) or GetContainerItemLink(bag, slot)
        local _, _, _, _, _, _, _, _, _, _, sellPrice = GetItemInfo(link or "")
        if sellPrice and sellPrice > 0 then
          local stackCount = info and info.stackCount or select(2, GetContainerItemInfo(bag, slot)) or 1
          UseContainerItem(bag, slot)
          total = total + (sellPrice * stackCount)
        end
      end
    end
  end

  if total > 0 then
    print(addonName .. ": Sold junk for " .. GetCoinTextureString(total))
  end
end

function frame:FastLoot(autoLoot)
  if self.fastLooting then return end
  local shouldAutoLoot = autoLoot
  if shouldAutoLoot == nil then
    shouldAutoLoot = GetCVarBool("autoLootDefault") ~= IsModifiedClick("AUTOLOOTTOGGLE")
  end
  if not shouldAutoLoot then return end

  local num = GetNumLootItems()
  if not num or num == 0 then return end

  self.fastLooting = true
  C_Timer.After(0, function()
    local count = GetNumLootItems()
    for slot = count, 1, -1 do
      LootSlot(slot)
    end
    self.fastLooting = false
  end)
end

function frame:MERCHANT_SHOW()
  if NiceClockPerCharDB.autoSellJunk then
    self:SellJunkItems()
  end
end

function frame:LOOT_READY(event, autoLoot)
  if NiceClockPerCharDB.fastAutoLoot then
    self:FastLoot(autoLoot)
  end
end

function frame:LOOT_CLOSED()
  self.fastLooting = false
end

function frame:UNIT_MODEL_CHANGED(event, unit)
  if not portraitManager.enabled then return end
  for texture, data in pairs(portraitManager.portraits) do
    if data.unit == unit then
      portraitManager:UpdateTexture(texture, unit, true)
    end
  end
end

-- ─── Combat Settings ─────────────────────────────────────────────────────────
function frame:ApplyCombatSettings()
  local opts = {
    {key="combatHealing",  cvar="floatingCombatTextCombatHealing"},
    {key="combatDamage",   cvar="floatingCombatTextCombatDamage"},
    {key="petDamage",      cvar="floatingCombatTextPetMeleeDamage"},
    {key="periodicDamage", cvar="floatingCombatTextPeriodicDamage"},
  }
  for _,o in ipairs(opts) do
    if NiceClockPerCharDB[o.key] ~= nil and SetCVar then
      SetCVar(o.cvar, NiceClockPerCharDB[o.key] and 1 or 0)
    end
  end
  if NiceClockPerCharDB.combatFont then
    local fontFile
    if NiceClockPerCharDB.combatFont:match("^Custom/") then
      local fname = NiceClockPerCharDB.combatFont:match("^Custom/(.+)$")
      for _, base in ipairs(COMBAT_FONT_GROUPS["Custom"].paths) do
        local candidate = base .. fname
        local f = CreateFont(addonName.."TempApplyFont")
        f:SetFont(candidate, 20, "")
        local loaded = f:GetFont()
        if loaded and loaded:lower():find(fname:lower(), 1, true) then
          fontFile = candidate
          break
        end
      end
    end
    if not fontFile then
      fontFile = "Interface\\AddOns\\NiceClock\\" .. NiceClockPerCharDB.combatFont
    end
    _G["DAMAGE_TEXT_FONT"] = fontFile
    _G["COMBAT_TEXT_FONT"]  = fontFile
  end
end

-- ─── Combat Font Persistence ─────────────────────────────────────────────────
function frame:ADDON_LOADED(event, addon)
  if addon == addonName then
    self:ApplyCombatSettings()
  end
end

-- ─── Alarm Handling ───────────────────────────────────────────────────────────
function frame:StartAlarm()
  if self.alarmPlaying then return end

  -- Silence music so alarm is clear
  local prevMusic = GetCVar("Sound_EnableMusic")
  if prevMusic == "1" then
    SetCVar("Sound_EnableMusic", "0")
    self.prevMusicEnabled = prevMusic
  else
    self.prevMusicEnabled = nil
  end

  -- Play alarm sound using the most compatible API
  local path = "Interface\\AddOns\\NiceClock\\Alarm\\1.ogg"
  local handle = SafePlaySound(path)

  self.alarmSound   = handle
  self.alarmPlaying = true
  -- Auto-stop timer
  if self.alarmTimer then
    self.alarmTimer:Cancel()
    self.alarmTimer = nil
  end
  local dur = NiceClockDB.alarmDuration or DEFAULTS.alarmDuration
  self.alarmTimer = C_Timer.NewTimer(dur, function() frame:StopAlarm() end)

  -- Create or show full-screen overlay
  if not self.alarmFrame then
    local overlay = CreateFrame("Frame", addonName.."AlarmOverlay", UIParent)
    overlay:SetAllPoints(UIParent)
    overlay:SetFrameStrata("DIALOG")
    overlay:EnableMouse(true)
    overlay:EnableKeyboard(true)
    overlay:SetPropagateKeyboardInput(false)
    overlay:SetScript("OnMouseDown", function() frame:StopAlarm() end)
    overlay:SetScript("OnKeyDown",   function() frame:StopAlarm() end)
    self.alarmFrame = overlay
  else
    self.alarmFrame:Show()
  end

  -- ── BEGIN FIX ─────────────────────────────────────────
  -- Ensure the clock ticker remains active and immediately update,
  -- so the time display never freezes while the alarm overlay is shown.
  self:RestartTicker()
  self:UpdateTime()
  -- ── END FIX ───────────────────────────────────────────

  -- Create or update the reminder text
  if not self.alarmText then
    local text = self.alarmFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    text:ClearAllPoints()
    text:SetPoint("CENTER", self.alarmFrame, "CENTER", 0, 0)
    text:SetJustifyH("CENTER")
    text:SetJustifyV("MIDDLE")
    text:SetWidth(1000)
    local reminderFontSize = (NiceClockDB.fontSize or DEFAULTS.fontSize) * 2
    text:SetFont(STANDARD_TEXT_FONT, reminderFontSize, "OUTLINE")
    self.alarmText = text
  else
    local reminderFontSize = (NiceClockDB.fontSize or DEFAULTS.fontSize) * 2
    self.alarmText:SetFont(STANDARD_TEXT_FONT, reminderFontSize, "OUTLINE")
  end

  self.alarmText:SetText(NiceClockDB.alarmReminder or "")
  self.alarmText:Show()

  -- Animate the reminder text color and position
  if self.alarmAnimTicker then self.alarmAnimTicker:Cancel() end
  local animAngle = 0
  self.alarmAnimTicker = C_Timer.NewTicker(0.05, function()
    animAngle = animAngle + math.pi * 0.1
    local r = (math.sin(animAngle) + 1) / 2
    local g = (math.sin(animAngle + 2 * math.pi / 3) + 1) / 2
    local b = (math.sin(animAngle + 4 * math.pi / 3) + 1) / 2
    self.alarmText:SetTextColor(r, g, b, 1)
    local yOffset = math.sin(animAngle * 2) * 20
    self.alarmText:ClearAllPoints()
    self.alarmText:SetPoint("CENTER", self.alarmFrame, "CENTER", 0, yOffset)
  end)
end

function frame:StopAlarm()
  -- Stop the sound
  if self.alarmSound then
    SafeStopSound(self.alarmSound)
    self.alarmSound = nil
  end

  if self.alarmTimer then
    self.alarmTimer:Cancel()
    self.alarmTimer = nil
  end

  -- Stop animation ticker
  if self.alarmAnimTicker then
    self.alarmAnimTicker:Cancel()
    self.alarmAnimTicker = nil
  end

  -- Restore music setting
  if self.prevMusicEnabled == "1" then
    SetCVar("Sound_EnableMusic", "1")
    self.prevMusicEnabled = nil
  end

  self.alarmPlaying = false
  if self.alarmText  then self.alarmText:Hide() end
  if self.alarmFrame then self.alarmFrame:Hide() end
  NiceClockDB.alarmTime = ""
  NiceClockDB.alarmTimestamp = 0
end

-- ─── Alarm Polling ────────────────────────────────────────────────────────────
function frame:CheckAlarm()
  -- BEGIN FEATURE: hourly chime support
  if NiceClockDB.hourlyChime then
    local h, m = nil, nil
    if NiceClockDB.useServerTime then
      h, m = GetServerClock()
    else
      h = tonumber(GetLocalTimeValue("%H"))
      m = tonumber(GetLocalTimeValue("%M"))
    end
    if m == 0 then
      if self.lastChimeHour ~= h then
        PlaySound(SOUNDKIT.ALARM_CLOCK_WARNING_3 or SOUNDKIT.RAID_WARNING, "Master")
        self.lastChimeHour = h
      end
    end
  end
  -- END FEATURE

  if not NiceClockDB.alarms then return end
  local now = GetServerTime and GetServerTime() or time()
  local h, m
  if NiceClockDB.useServerTime then
    h, m = GetServerClock()
  else
    h = tonumber(GetLocalTimeValue("%H"))
    m = tonumber(GetLocalTimeValue("%M"))
  end
  for i = #NiceClockDB.alarms, 1, -1 do
    local a = NiceClockDB.alarms[i]
    if a.timestamp then
      if now >= a.timestamp and not self.alarmPlaying then
        NiceClockDB.alarmReminder = a.text or ""
        table.remove(NiceClockDB.alarms, i)
        self:StartAlarm()
        if self.RefreshAlarmList then self:RefreshAlarmList() end
        break
      end
    else
      if h == a.hour and m == a.min and not self.alarmPlaying then
        NiceClockDB.alarmReminder = a.text or ""
        table.remove(NiceClockDB.alarms, i)
        self:StartAlarm()
        if self.RefreshAlarmList then self:RefreshAlarmList() end
        break
      end
    end
  end
end

-- ─── Chat Reminder Scheduling ────────────────────────────────────────────────
function frame:AddToastReminder(delay, text)
  self.reminders = self.reminders or {}
  local when = (GetServerTime and GetServerTime() or time()) + delay
  table.insert(self.reminders, {time = when, text = text})
end

function frame:ShowToast(text)
  if not self.toastFrame then
    local f = CreateFrame("Frame", addonName.."Toast", UIParent, "BackdropTemplate")
    f:SetSize(200, 40)
    f:SetBackdrop({bgFile = "Interface/Tooltips/UI-Tooltip-Background", edgeFile = "Interface/Tooltips/UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16, insets = {left=4,right=4,top=4,bottom=4}})
    f:SetBackdropColor(0,0,0,0.9)
    f:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -20, -20)
    local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("CENTER")
    f.text = fs
    self.toastFrame = f
  end
  local f = self.toastFrame
  f.text:SetText(text)
  f:Show()
  C_Timer.After(5, function() f:Hide() end)
end

function frame:CheckReminders()
  if not self.reminders then return end
  local now = GetServerTime and GetServerTime() or time()
  for i = #self.reminders, 1, -1 do
    local r = self.reminders[i]
    if now >= r.time then
      self:ShowToast(r.text)
      table.remove(self.reminders, i)
    end
  end
end

-- Add an absolute alarm (hour/minute) to the queue
function frame:AddAbsoluteAlarm(h, m, text)
  NiceClockDB.alarms = NiceClockDB.alarms or {}
  table.insert(NiceClockDB.alarms, {hour = h, min = m, text = text or ""})
  if self.RefreshAlarmList then self:RefreshAlarmList() end
end

-- Add a relative alarm in minutes to the queue
function frame:AddRelativeAlarm(minutes, text)
  NiceClockDB.alarms = NiceClockDB.alarms or {}
  local now = GetServerTime and GetServerTime() or time()
  table.insert(NiceClockDB.alarms, {timestamp = now + minutes * 60, text = text or ""})
  if self.RefreshAlarmList then self:RefreshAlarmList() end
end

-- Remove an alarm by index
function frame:RemoveAlarm(idx)
  if not NiceClockDB.alarms then return end
  table.remove(NiceClockDB.alarms, idx)
  if self.RefreshAlarmList then self:RefreshAlarmList() end
end

-- Refresh the upcoming alarm list in the settings UI
function frame:RefreshAlarmList()
  if not self.alarmListEntries then return end
  local now = GetServerTime and GetServerTime() or time()
  NiceClockDB.alarms = NiceClockDB.alarms or {}
  -- Sort alarms by next trigger time
  table.sort(NiceClockDB.alarms, function(a, b)
    local at = a.timestamp or (a.hour * 60 + a.min)
    local bt = b.timestamp or (b.hour * 60 + b.min)
    return at < bt
  end)
  for i, btn in ipairs(self.alarmListEntries) do
    local a = NiceClockDB.alarms[i]
    if a then
      btn.alarmIndex = i
      local display
      if a.timestamp then
        display = date("%H:%M", a.timestamp) .. " - " .. (a.text or "")
      else
        display = string.format("%02d:%02d - %s", a.hour, a.min, a.text or "")
      end
      btn.text:SetText(display)
      btn:Show()
    else
      btn:Hide()
      btn.alarmIndex = nil
    end
  end
end

function frame:HandleCalendarAlarm(...)
  local title
  if C_Calendar and C_Calendar.GetEventIndex then
    local idx = C_Calendar.GetEventIndex()
    if idx then
      local info = C_Calendar.GetEventInfo(idx)
      if info and info.title then title = info.title end
    end
  elseif CalendarGetEventIndex then
    local month, day, eventIndex = CalendarGetEventIndex()
    if month and day and eventIndex then
      CalendarGetDayEvent(month, day, eventIndex)
      if CalendarEventGetTitle then title = CalendarEventGetTitle() end
    end
  end
  NiceClockDB.alarmReminder = title or "Calendar Event"
  self:StartAlarm()
end

-- TIME_PLAYED_MSG fires after RequestTimePlayed().
-- We snapshot the total /played (seconds) and then let the UI tick upward
-- by adding elapsed real time while logged in.
function frame:TIME_PLAYED_MSG(event, totalTime, levelTime)
  totalTime = tonumber(totalTime) or 0

  self.playedBaseSeconds = totalTime
  -- Prefer GetTime() (time since login) to avoid issues if system time changes.
  self.playedReceivedAt  = (GetTime and GetTime()) or time()

  -- Self-heal for upgraded installs or partial saved variables.
  if type(NiceClockDB.playedByCharacter) ~= "table" then
    NiceClockDB.playedByCharacter = {}
  end

  local key = self:GetPlayerKey()
  if key and key ~= "" then
    NiceClockDB.playedByCharacter[key] = totalTime
  end

  -- Refresh tracking display immediately if the panel is open.
  self:UpdateTracking()
end

-- ─── Settings Panel & Tabs ──────────────────────────────────────────────────
function frame:ToggleSettings()
  if not self.settingsFrame then self:CreateSettingsFrame() end
  if self.settingsFrame:IsShown() then
    self.settingsFrame:Hide()
    self.settingsOverlay:Hide()
  else
    self.settingsOverlay:Show()
    self.settingsFrame:Show()
  end
end

function frame:CreateSettingsFrame()
  local f = CreateFrame("Frame","NiceClockSettingsFrame",UIParent,"BackdropTemplate")
  -- Enlarged to provide additional padding for the combat options panel
  f:SetSize(420,600)
  f:SetPoint("CENTER")
  f:SetMovable(true); f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart",f.StartMoving)
  f:SetScript("OnDragStop",f.StopMovingOrSizing)
  f:SetBackdrop({
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile     = true, tileSize=32, edgeSize=16,
    insets   = {8,8,8,8},
  })
  f:SetFrameStrata("DIALOG"); f:Hide()
  tinsert(UISpecialFrames, f:GetName())

  local overlay = CreateFrame("Frame","NiceClockSettingsOverlay",UIParent)
  overlay:SetAllPoints(UIParent)
  overlay:EnableMouse(true)
  overlay:SetFrameStrata("HIGH")
  overlay:SetScript("OnMouseDown", function(self) f:Hide(); self:Hide() end)
  overlay:Hide()

  local title = f:CreateFontString(nil,"OVERLAY","GameFontHighlightLarge")
  title:SetPoint("TOP",0,-12)
  title:SetText("Settings")

  -- Shared layout constants for all panels
  -- left/right margins keep widgets away from the frame edges
  local LAYOUT = {
    left  = 20,
    top   = -110,
  }
  -- compute second column starting X so content is centered
  LAYOUT.col2 = LAYOUT.left + (f:GetWidth() - LAYOUT.left * 2) / 2

  local panels = {}
  for i=1,5 do
    local p = CreateFrame("Frame",f:GetName().."Panel"..i,f)
    p:SetAllPoints(f)
    p:Hide()
    panels[i] = p
  end

  local tabInfo = {
    {text="Clock Settings", panel=panels[1]},
    {text="Alarm",          panel=panels[2]},
    {text="Quality of Life",panel=panels[3]},
    {text="Track",          panel=panels[4]},
    {text="Combat",         panel=panels[5]},
  }

  -- Create tabs and store references for layout
  local tabs = {}
  for i,info in ipairs(tabInfo) do
    local tab = CreateFrame("Button",f:GetName().."Tab"..i,f,"UIPanelButtonTemplate")
    tab:SetSize(110,25)
    tab:SetText(info.text)
    tab:SetScript("OnClick", function()
      for _,p in ipairs(panels) do p:Hide() end
      info.panel:Show()
      for j=1,#tabInfo do
        local other = _G[f:GetName().."Tab"..j]
        if j==i then other:LockHighlight() else other:UnlockHighlight() end
      end
    end)
    tabs[i] = tab
  end

  -- Helper to layout tabs centered in two rows
  local function LayoutTabs()
    local tabWidth, tabHeight = 110, 25
    local gap       = 10
    local rows      = { {1,2,3}, {4,5} }
    for r,row in ipairs(rows) do
      local count = #row
      local rowWidth = tabWidth * count + gap * (count-1)
      local startX = (f:GetWidth() - rowWidth) / 2
      for i,colIndex in ipairs(row) do
        local tab = tabs[colIndex]
        if tab then
          tab:ClearAllPoints()
          tab:SetPoint("TOPLEFT", f, "TOPLEFT",
                        startX + (i-1)*(tabWidth+gap), -40 - (r-1)*30)
        end
      end
    end
  end

  LayoutTabs()

  panels[1]:Show()
  _G[f:GetName().."Tab1"]:LockHighlight()

  -- Clock Settings Panel
  do
    local p = panels[1]
    -- Font Size Slider
    local fs = CreateFrame("Slider","NiceClockFontSizeSlider",p,"OptionsSliderTemplate")
    fs:SetPoint("TOPLEFT", LAYOUT.left, LAYOUT.top)
    fs:SetMinMaxValues(15,48); fs:SetValueStep(1); fs:SetWidth(300)
    fs:SetValue(NiceClockDB.fontSize)
    fs:SetScript("OnValueChanged", function(self, v)
      v = math.floor(v + 0.5)
      NiceClockDB.fontSize = v
      _G[self:GetName() .. "Text"]:SetText("Font Size: " .. v)
      frame:ApplySettings()
    end)
    _G["NiceClockFontSizeSliderLow"]:SetText("15")
    _G["NiceClockFontSizeSliderHigh"]:SetText("48")
    _G["NiceClockFontSizeSliderText"]:SetText("Font Size: "..NiceClockDB.fontSize)

    -- Show Date Checkbox
    local sd = CreateCheckbox(p, "NiceClockShowDateCB", "Show Date", LAYOUT.left, LAYOUT.top - 50, NiceClockDB.showDate, function(self)
      NiceClockDB.showDate = self:GetChecked()
      frame:ApplySettings()
    end)

    -- 24h Format Checkbox
    local h24 = CreateCheckbox(p, "NiceClock24hCB", "24h Format", LAYOUT.col2, LAYOUT.top - 50, NiceClockDB.is24h, function(self)
      NiceClockDB.is24h = self:GetChecked()
      frame:ApplySettings()
    end)

    -- Show Seconds Checkbox
    local ss = CreateCheckbox(p, "NiceClockShowSecCB", "Show Seconds", LAYOUT.left, LAYOUT.top - 80, NiceClockDB.showSeconds, function(self)
      NiceClockDB.showSeconds = self:GetChecked()
      frame:ApplySettings()
    end)

    -- BEGIN FEATURE: server time & hourly chime checkboxes
    local ust = CreateCheckbox(p, "NiceClockUseServerCB", "Use Server Time", LAYOUT.left, LAYOUT.top - 110, NiceClockDB.useServerTime)

    local chime = CreateCheckbox(p, "NiceClockChimeCB", "Hourly Chime", LAYOUT.col2, LAYOUT.top - 110, NiceClockDB.hourlyChime, function(self)
      NiceClockDB.hourlyChime = self:GetChecked()
    end)
    -- END FEATURE

    -- Time Zone Offset Slider
    local tz = CreateFrame("Slider", "NiceClockTZSlider", p, "OptionsSliderTemplate")
    tz:SetPoint("TOPLEFT", LAYOUT.left, LAYOUT.top - 160)
    tz:SetMinMaxValues(-12, 14)
    tz:SetValueStep(1)
    tz:SetObeyStepOnDrag(true)
    tz:SetWidth(300)
    tz:SetValue(NiceClockDB.timezoneOffset or 0)
    tz:SetScript("OnValueChanged", function(self, v)
      NiceClockDB.timezoneOffset = v
      _G[self:GetName() .. "Text"]:SetText("Time Zone Offset: " .. string.format("%+d", v))
      frame:UpdateTime()
    end)
    _G[tz:GetName() .. "Low"]:SetText("-12")
    _G[tz:GetName() .. "High"]:SetText("+14")
    _G[tz:GetName() .. "Text"]:SetText("Time Zone Offset: " .. string.format("%+d", NiceClockDB.timezoneOffset or 0))

    ust:SetScript("OnClick", function(self)
      NiceClockDB.useServerTime = self:GetChecked()
      if self:GetChecked() then
        NiceClockDB.timezoneOffset = 0
        tz:SetValue(0)
        tz:Disable()
        tz:SetAlpha(0.5)
      else
        tz:Enable()
        tz:SetAlpha(1)
      end
      _G[tz:GetName() .. "Text"]:SetText("Time Zone Offset: " .. string.format("%+d", NiceClockDB.timezoneOffset or 0))
      frame:UpdateTime()
    end)

    if NiceClockDB.useServerTime then
      tz:SetValue(0)
      tz:Disable()
      tz:SetAlpha(0.5)
    else
      tz:Enable()
      tz:SetAlpha(1)
    end

    -- Color Picker Button
    local cb = CreateFrame("Button","NiceClockColorButton",p,"UIPanelButtonTemplate")
    cb:SetSize(100,22)
    cb:SetPoint("TOPLEFT", LAYOUT.col2, LAYOUT.top - 80)
    cb:SetText("Font Color")
    cb:SetScript("OnClick",function()
      if LoadAddOn then LoadAddOn("Blizzard_ColorPicker") end
      local oR,oG,oB,oA = unpack(NiceClockDB.fontColor)
      local function live()
        local r,g,b = ColorPickerFrame:GetColorRGB()
        NiceClockDB.fontColor = {r,g,b,oA}
        frame.fs:SetTextColor(r,g,b,oA)
        if frame.icon then frame.icon:SetVertexColor(r,g,b,oA) end
        if frame.shadows then
          for _, s in ipairs(frame.shadows) do
            s:SetTextColor(r,g,b,0.3)
          end
        end
      end
      local function cancel()
        NiceClockDB.fontColor = {oR,oG,oB,oA}
        frame.fs:SetTextColor(oR,oG,oB,oA)
        if frame.icon then frame.icon:SetVertexColor(oR,oG,oB,oA) end
        if frame.shadows then
          for _, s in ipairs(frame.shadows) do
            s:SetTextColor(oR,oG,oB,0.3)
          end
        end
      end
      ColorPickerFrame.func        = live
      ColorPickerFrame.swatchFunc  = live
      ColorPickerFrame.cancelFunc  = cancel
      ColorPickerFrame.hasOpacity  = false
      local sw = _G[ColorPickerFrame:GetName().."ColorSwatch"]
      if sw then sw:SetVertexColor(oR,oG,oB) end
      ShowUIPanel(ColorPickerFrame)
    end)

    -- Clock Font Dropdown
    local fontDropdown = CreateFrame("Frame", "NiceClockFontDropdown", p, "UIDropDownMenuTemplate")
    fontDropdown:SetPoint("TOPLEFT", LAYOUT.left, LAYOUT.top - 220)
    UIDropDownMenu_SetWidth(fontDropdown, 150)
    UIDropDownMenu_Initialize(fontDropdown, function(self, level)
      for _, fname in ipairs(AVAILABLE_FONTS) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = fname
        info.value = fname
        info.func = function(self)
          NiceClockDB.fontName = self.value
          UIDropDownMenu_SetSelectedValue(fontDropdown, self.value)
          UIDropDownMenu_SetText(fontDropdown, self.value)
          -- BEGIN FIX: use unified ApplySettings for immediate redraw
          frame:ApplySettings()
          -- END FIX
        end
        info.checked = (NiceClockDB.fontName == fname)
        UIDropDownMenu_AddButton(info)
      end
    end)
    local ddLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ddLabel:SetPoint("BOTTOMLEFT", fontDropdown, "TOPLEFT", 0, 2)
    ddLabel:SetText("Clock Font")
    UIDropDownMenu_SetSelectedValue(fontDropdown, NiceClockDB.fontName)
    UIDropDownMenu_SetText(fontDropdown, NiceClockDB.fontName)

    hooksecurefunc("UIDropDownMenu_SetSelectedValue", function(self, value)
      if self == fontDropdown then
        NiceClockDB.fontName = value
        frame:ApplySettings()
      end
    end)

    local startY = LAYOUT.top - 250
    local spacing = 25

    -- Move Clock Checkbox
    local mv = CreateCheckbox(p, "NiceClockAllowMoveCB", "Tick to move clock", LAYOUT.left, startY, NiceClockDB.allowMove,
      function(self)
        NiceClockDB.allowMove = self:GetChecked()
        frame:ApplyMoveSettings()
      end,
      function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Tick to enable dragging; untick for click-through", 1,1,1)
        GameTooltip:Show()
      end,
      function() GameTooltip:Hide() end
    )

    -- Hide Clock Checkbox
    local hc = CreateCheckbox(p, "NiceClockHideClockCB", "Tick to hide clock", LAYOUT.left, startY - spacing, NiceClockDB.hideClock, function(self)
      NiceClockDB.hideClock = self:GetChecked()
      frame:ApplySettings()
    end)

    -- Hide Icon Checkbox
    local hi = CreateCheckbox(p, "NiceClockHideIconCB", "Tick to hide icon", LAYOUT.left, startY - 2*spacing, NiceClockDB.hideIcon, function(self)
      NiceClockDB.hideIcon = self:GetChecked()
      frame:ApplySettings()
    end)

    -- RGB Clock Checkbox
    local rgb = CreateCheckbox(p, "NiceClockRGBClockCB", "RGB Clock", LAYOUT.left, startY - 3*spacing, NiceClockDB.rgbClock, function(self)
      NiceClockDB.rgbClock = self:GetChecked()
      frame:ApplySettings()
    end)

    -- Wave Checkbox (renamed from "Bounce") aligned with other options
    -- Moved up to avoid overlapping the Default button
    local bc = CreateCheckbox(p, "NiceClockWaveCB", "Wave", LAYOUT.col2, startY - 3*spacing, NiceClockDB.waveClock, function(self)
      NiceClockDB.waveClock = self:GetChecked()
      frame:ApplySettings()
    end)

    -- Reset Defaults Button
    local rb = CreateFrame("Button","NiceClockResetButton",p,"UIPanelButtonTemplate")
    rb:SetSize(120,22)
    rb:SetPoint("BOTTOM",p,"BOTTOM",0,10)
    rb:SetText("Default")
    rb:SetScript("OnClick",function()
      -- BEGIN MOD: Preserve tracking values when resetting defaults
      for k, v in pairs(DEFAULTS) do
        -- skip all tracking-related keys to keep tracked data intact
        if not (
          k:match("^trackSession") or
          k:match("^trackDay") or
          k:match("^trackWeek") or
          k:match("^trackMonth") or
          k:match("^trackYear") or
          k == "trackTooltip" or
          k == "dayDate" or
          k == "daySeconds" or
          k == "weekID" or
          k == "weekSeconds" or
          k == "monthID" or
          k == "monthSeconds" or
          k == "yearID" or
          k == "yearSeconds"
        ) then
          NiceClockDB[k] = v
        end
      end
      -- END MOD

      NiceClockDB.positionPoint = nil; NiceClockDB.positionRelPoint = nil; NiceClockDB.positionX = nil; NiceClockDB.positionY = nil
      -- Restore minimap icon to default position
      NiceClockDB.minimapAnchorPoint  = DEFAULTS.minimapAnchorPoint
      NiceClockDB.minimapRelativePoint= DEFAULTS.minimapRelativePoint
      NiceClockDB.minimapX            = DEFAULTS.minimapX
      NiceClockDB.minimapY            = DEFAULTS.minimapY
      if frame.minimapIcon then
        frame.minimapIcon:ClearAllPoints()
        frame.minimapIcon:SetPoint(NiceClockDB.minimapAnchorPoint, Minimap,
                                   NiceClockDB.minimapRelativePoint,
                                   NiceClockDB.minimapX, NiceClockDB.minimapY)
      end

      fs:SetValue(NiceClockDB.fontSize)
      sd:SetChecked(NiceClockDB.showDate)
      h24:SetChecked(NiceClockDB.is24h)
      ss:SetChecked(NiceClockDB.showSeconds)
      ust:SetChecked(NiceClockDB.useServerTime)
      chime:SetChecked(NiceClockDB.hourlyChime)
      tz:SetValue(NiceClockDB.timezoneOffset or 0)
      _G[tz:GetName() .. "Text"]:SetText("Time Zone Offset: " .. string.format("%+d", NiceClockDB.timezoneOffset or 0))
      if NiceClockDB.useServerTime then
        tz:Disable()
        tz:SetAlpha(0.5)
      else
        tz:Enable()
        tz:SetAlpha(1)
      end
      UIDropDownMenu_SetSelectedValue(fontDropdown, NiceClockDB.fontName)
      UIDropDownMenu_SetText(fontDropdown, NiceClockDB.fontName)
      mv:SetChecked(NiceClockDB.allowMove)
      hc:SetChecked(NiceClockDB.hideClock)
      hi:SetChecked(NiceClockDB.hideIcon)
      rgb:SetChecked(NiceClockDB.rgbClock)
      bc:SetChecked(NiceClockDB.waveClock)
      local adSlider = _G[addonName.."AlarmDurSlider"]
      if adSlider then
        adSlider:SetValue(NiceClockDB.alarmDuration or DEFAULTS.alarmDuration)
        _G[adSlider:GetName() .. "Text"]:SetText("Alarm Duration: " .. (NiceClockDB.alarmDuration or DEFAULTS.alarmDuration) .. "s")
      end

      frame:ApplySettings()
      frame:ApplyMoveSettings()

      for k,v in pairs(PERCHAR_DEFAULTS) do NiceClockPerCharDB[k] = v end
      frame:ApplyQoLSettings()

      NiceClockPerCharDB.combatFont = nil
      _G["DAMAGE_TEXT_FONT"] = ORIGINAL_DAMAGE_TEXT_FONT
      _G["COMBAT_TEXT_FONT"] = ORIGINAL_COMBAT_TEXT_FONT
      frame:ApplyCombatSettings()

      SetCVar("WorldTextScale", "1.0")
      local csSlider = _G[addonName.."CombatScaleSlider"]
      if csSlider then csSlider:SetValue(1.0) end
      local csValue = _G[addonName.."CombatScaleValue"]
      if csValue then csValue:SetText("1.0") end

      local groups = {"Fun","Future","Movie/Game","Easy-to-Read","Custom"}
      for _,g in ipairs(groups) do
        local dd = _G[addonName .. g:gsub("[^%w]","") .. "Dropdown"]
        if dd then UIDropDownMenu_SetText(dd, "Select Font") end
      end
    end)
  end

  -- Alarm Panel
  do
    local p = panels[2]
    local timeLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    timeLabel:SetPoint("TOPLEFT", LAYOUT.left, LAYOUT.top)
    timeLabel:SetText("Alarm Time (HH:MM):")

    local timeEdit = CreateFrame("EditBox", addonName.."AlarmTimeBox", p, "InputBoxTemplate")
    timeEdit:SetSize(100, 24)
    timeEdit:SetPoint("TOPLEFT", timeLabel, "BOTTOMLEFT", 0, -4)
    timeEdit:SetAutoFocus(false)
    timeEdit:SetText("")

    local ampmDropdown = CreateFrame("Frame", addonName.."AlarmAMPMDropdown", p, "UIDropDownMenuTemplate")
    ampmDropdown:SetPoint("LEFT", timeEdit, "RIGHT", 10, 0)
    UIDropDownMenu_SetWidth(ampmDropdown, 60)
    UIDropDownMenu_Initialize(ampmDropdown, function(self, level)
      local info = UIDropDownMenu_CreateInfo()
      info.text = "AM"
      info.value = "AM"
      info.func = function(self) UIDropDownMenu_SetSelectedValue(ampmDropdown, self.value) end
      info.checked = UIDropDownMenu_GetSelectedValue(ampmDropdown) == "AM"
      UIDropDownMenu_AddButton(info)

      info = UIDropDownMenu_CreateInfo()
      info.text = "PM"
      info.value = "PM"
      info.func = function(self) UIDropDownMenu_SetSelectedValue(ampmDropdown, self.value) end
      info.checked = UIDropDownMenu_GetSelectedValue(ampmDropdown) == "PM"
      UIDropDownMenu_AddButton(info)
    end)
    UIDropDownMenu_SetSelectedValue(ampmDropdown, nil)
    UIDropDownMenu_SetText(ampmDropdown, "")

    local function parseAlarmInput()
      local val = strtrim(timeEdit:GetText() or "")
      local h, m = val:match("^(%d?%d):(%d%d)$")
      if not h then
        print(addonName..": Invalid time format. Use HH:MM.")
        return nil
      end
      h = tonumber(h); m = tonumber(m)
      if m < 0 or m > 59 then
        print(addonName..": Invalid minutes. Must be 00-59.")
        return nil
      end
      local sel = UIDropDownMenu_GetSelectedValue(ampmDropdown)
      if sel then
        if h < 1 or h > 12 then
          print(addonName..": Invalid hour for 12h format. Use 1-12.")
          return nil
        end
        if sel == "AM" then
          if h == 12 then h = 0 end
        else
          if h < 12 then h = h + 12 end
        end
      else
        if h < 0 or h > 23 then
          print(addonName..": Invalid hour for 24h format. Use 0-23.")
          return nil
        end
      end
      return h, m
    end

    timeEdit:SetScript("OnEnterPressed", function(self)
      self:ClearFocus()
    end)
    timeEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local remLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    remLabel:SetPoint("TOPLEFT", timeEdit, "BOTTOMLEFT", 0, -12)
    remLabel:SetText("Reminder Text:")
    local remEdit = CreateFrame("EditBox", addonName.."AlarmReminderBox", p, "InputBoxTemplate")
    remEdit:SetSize(300, 24)
    remEdit:SetPoint("TOPLEFT", remLabel, "BOTTOMLEFT", 0, -4)
    remEdit:SetAutoFocus(false)
    remEdit:SetText("")
    remEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    remEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local durLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    durLabel:SetPoint("TOPLEFT", remEdit, "BOTTOMLEFT", 0, -12)
    durLabel:SetText("Alarm Duration (sec):")

    local durSlider = CreateFrame("Slider", addonName.."AlarmDurSlider", p, "OptionsSliderTemplate")
    durSlider:SetPoint("TOPLEFT", durLabel, "BOTTOMLEFT", 0, -4)
    durSlider:SetMinMaxValues(5, 60)
    durSlider:SetValueStep(5)
    durSlider:SetObeyStepOnDrag(true)
    durSlider:SetWidth(300)
    durSlider:SetValue(NiceClockDB.alarmDuration or DEFAULTS.alarmDuration)
    -- Position the slider's value text below the slider so it doesn't
    -- extend past the settings frame border.
    local durText = _G[durSlider:GetName() .. "Text"]
    if durText then
      durText:ClearAllPoints()
      -- Place the text slightly below the slider and left aligned
      -- to avoid overlapping the Low/High labels.
      durText:SetPoint("TOPLEFT", durSlider, "BOTTOMLEFT", 0, -18)
      durText:SetJustifyH("LEFT")
    end
    durSlider:SetScript("OnValueChanged", function(self, v)
      v = math.floor(v + 0.5)
      NiceClockDB.alarmDuration = v
      _G[self:GetName() .. "Text"]:SetText("Alarm Duration: " .. v .. "s")
    end)
    _G[durSlider:GetName() .. "Low"]:SetText("5")
    _G[durSlider:GetName() .. "High"]:SetText("60")
    _G[durSlider:GetName() .. "Text"]:SetText("Alarm Duration: " .. (NiceClockDB.alarmDuration or DEFAULTS.alarmDuration) .. "s")

    local setBtn = CreateFrame("Button", addonName.."AlarmSetBtn", p, "UIPanelButtonTemplate")
    setBtn:SetSize(80, 22)
    -- Anchor the button below the duration text so everything shifts down
    -- when the value text moves.
    if durText then
      setBtn:SetPoint("TOPLEFT", durText, "BOTTOMLEFT", 0, -12)
    else
      setBtn:SetPoint("TOPLEFT", durSlider, "BOTTOMLEFT", 0, -12)
    end
    setBtn:SetText("Add Alarm")
    setBtn:SetScript("OnClick", function()
      local h, m = parseAlarmInput()
      if not h then return end
      local text = remEdit:GetText()
      frame:AddAbsoluteAlarm(h, m, text)
      print(addonName..": Alarm time set to "..string.format("%02d:%02d", h, m))
      if text and strtrim(text) ~= "" then
        print(addonName..": Reminder text set to '"..strtrim(text).."'.")
      end
      timeEdit:SetText("")
      remEdit:SetText("")
      UIDropDownMenu_SetSelectedValue(ampmDropdown, nil)
      UIDropDownMenu_SetText(ampmDropdown, "")
    end)

    local clearBtn = CreateFrame("Button", addonName.."AlarmClearBtn", p, "UIPanelButtonTemplate")
    clearBtn:SetSize(80, 22)
    clearBtn:SetPoint("LEFT", setBtn, "RIGHT", 10, 0)
    clearBtn:SetText("Clear All")
    clearBtn:SetScript("OnClick", function()
      NiceClockDB.alarms = {}
      frame:RefreshAlarmList()
      print(addonName..": all alarms cleared.")
    end)

    local upLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    upLabel:SetPoint("TOPLEFT", setBtn, "BOTTOMLEFT", 0, -16)
    upLabel:SetText("Upcoming Alarms:")

    p.alarmEntries = {}
    frame.alarmListEntries = p.alarmEntries
    for i = 1, 5 do
      local btn = CreateFrame("Button", addonName.."AlarmEntry"..i, p)
      btn:SetSize(300, 20)
      if i == 1 then
        btn:SetPoint("TOPLEFT", upLabel, "BOTTOMLEFT", 0, -2)
      else
        btn:SetPoint("TOPLEFT", p.alarmEntries[i-1], "BOTTOMLEFT", 0, 0)
      end
      btn:SetHighlightTexture("Interface/QuestFrame/UI-QuestTitleHighlight")
      local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      fs:SetAllPoints(btn)
      fs:SetJustifyH("LEFT")
      btn.text = fs
      btn:SetScript("OnClick", function(self)
        if self.alarmIndex then
          frame:RemoveAlarm(self.alarmIndex)
          print(addonName..": alarm cancelled.")
        end
      end)
      p.alarmEntries[i] = btn
    end
    p:HookScript("OnShow", function() frame:RefreshAlarmList() end)
  end

  -- Quality of Life Panel
  do
    local p = panels[3]
    local sliderWidth = 320
    local ts = CreateFrame("Slider","NiceClockTrackerSizeSlider",p,"OptionsSliderTemplate")
    ts:SetPoint("TOP", p, "TOP", 0, LAYOUT.top + 70)
    ts:SetMinMaxValues(0.5,2); ts:SetValueStep(0.05); ts:SetWidth(sliderWidth)
    ts:SetValue(NiceClockPerCharDB.trackerScale or 1)
    ts:SetScript("OnValueChanged",function(self,v)
      NiceClockPerCharDB.trackerScale = v
      _G[self:GetName().."Text"]:SetText("Objective Tracker Scale: "..string.format("%.2f", v))
      if ObjectiveTrackerFrame then
        ObjectiveTrackerFrame:SetScale(v)
      end
    end)
    _G["NiceClockTrackerSizeSliderLow"]:SetText("0.5")
    _G["NiceClockTrackerSizeSliderHigh"]:SetText("2")
    _G["NiceClockTrackerSizeSliderText"]:SetText("Objective Tracker Scale: "..string.format("%.2f", (NiceClockPerCharDB.trackerScale or 1)))

    local ht = CreateCheckbox(p, "NiceClockHideTrackerCB", "Hide Objective Tracker", LAYOUT.left, LAYOUT.top - 20, NiceClockPerCharDB.hideTracker, function(self)
      NiceClockPerCharDB.hideTracker = self:GetChecked()
      if ObjectiveTrackerFrame then
        if self:GetChecked() then ObjectiveTrackerFrame:Hide() else ObjectiveTrackerFrame:Show() end
      end
    end)

    local qolOptions = {
      {
        key = "enable3dPortraits",
        label = "3D portraits",
        handler = function(checked)
          NiceClockPerCharDB.enable3dPortraits = checked
          portraitManager:SetEnabled(checked)
        end,
      },
      {
        key = "autoSellJunk",
        label = "Auto-sell junk",
        handler = function(checked)
          NiceClockPerCharDB.autoSellJunk = checked
        end,
      },
      {
        key = "fastAutoLoot",
        label = "Fast autoloot",
        handler = function(checked)
          NiceClockPerCharDB.fastAutoLoot = checked
        end,
      },
    }

    local prev = ht
    local spacing = -30
    for _, opt in ipairs(qolOptions) do
      prev = CreateCheckbox(
        p,
        addonName .. "QoL" .. opt.key .. "CB",
        opt.label,
        0,
        spacing,
        NiceClockPerCharDB[opt.key],
        function(self) opt.handler(self:GetChecked()) end,
        nil,
        nil,
        prev,
        "BOTTOMLEFT",
        "TOPLEFT"
      )
    end
  end

  -- Track Panel
  do
    local p = panels[4]

    -- Total /played display (does not require the user to type /played)
    local totalCharLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    totalCharLabel:SetPoint("TOPLEFT", p, "TOPLEFT", LAYOUT.left, LAYOUT.top)
    totalCharLabel:SetText("Total time played (this character):")

    local totalCharVal = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    totalCharVal:SetPoint("TOPLEFT", totalCharLabel, "BOTTOMLEFT", 0, -4)
    totalCharVal:SetText("Loading…")
    frame.totalPlayedCharValText = totalCharVal

    local totalAllLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    totalAllLabel:SetPoint("TOPLEFT", totalCharVal, "BOTTOMLEFT", 0, -12)
    totalAllLabel:SetText("Total time played (all characters):")

    local totalAllVal = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    totalAllVal:SetPoint("TOPLEFT", totalAllLabel, "BOTTOMLEFT", 0, -4)
    totalAllVal:SetText("—")
    frame.totalPlayedAllValText = totalAllVal

    local totalNote = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    totalNote:SetPoint("TOPLEFT", totalAllVal, "BOTTOMLEFT", 0, -2)
    totalNote:SetJustifyH("LEFT")
    -- BEGIN FIX: wrap the explanatory note so it never spills beyond the settings frame
    totalNote:SetWordWrap(true)
    totalNote:SetJustifyV("TOP")
    local function UpdateTotalNoteWidth()
      -- Panel width matches the settings frame; subtract margins and a small safety pad for borders/insets.
      local w = (p and p.GetWidth and p:GetWidth()) or 0
      if w and w > 0 then
        totalNote:SetWidth(math.max(1, w - (LAYOUT.left * 2) - 20))
      else
        totalNote:SetWidth(360) -- fallback for very early layout
      end
    end
    UpdateTotalNoteWidth()
    p:HookScript("OnShow", UpdateTotalNoteWidth)
    p:HookScript("OnSizeChanged", UpdateTotalNoteWidth)
    -- END FIX
    totalNote:SetText("Only counts characters you've logged into with NiceClock enabled (log into each alt at least once to include it).")

    local totalCount = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    totalCount:SetPoint("TOPLEFT", totalNote, "BOTTOMLEFT", 0, -2)
    totalCount:SetJustifyH("LEFT")
    totalCount:SetText("Tracked characters: 0")
    frame.totalPlayedTrackedCountText = totalCount

    local trackingOptions = {
      { key = "trackSession", label = "Time played this session" },
      { key = "trackDay",     label = "Time played today" },
      { key = "trackWeek",    label = "Time played this week" },
      { key = "trackMonth",   label = "Time played this month" },
      { key = "trackYear",    label = "Time played this year" },
    }

    -- BEGIN FIX: anchor tracking checkboxes beneath the totals block (prevents overlap if the note wraps)
    local spacing = 30
    local prevAnchor = totalCount

    for i, opt in ipairs(trackingOptions) do
      local yOff = (i == 1) and -18 or -spacing
      local cb = CreateCheckbox(
        p,
        addonName.."Track"..opt.key.."CB",
        opt.label,
        0,
        yOff,
        NiceClockDB[opt.key] or false,
        function(self)
          NiceClockDB[opt.key] = self:GetChecked()
        end,
        nil,
        nil,
        prevAnchor,
        "BOTTOMLEFT",
        "TOPLEFT"
      )
      prevAnchor = cb

      -- create value text next to each checkbox
      if opt.key == "trackSession" then
        local val = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        val:SetPoint("LEFT", cb.text, "RIGHT", 10, 0)
        frame.sessionValText = val
      elseif opt.key == "trackDay" then
        local val = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        val:SetPoint("LEFT", cb.text, "RIGHT", 10, 0)
        frame.dayValText = val
      elseif opt.key == "trackWeek" then
        local val = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        val:SetPoint("LEFT", cb.text, "RIGHT", 10, 0)
        frame.weekValText = val
      elseif opt.key == "trackMonth" then
        local val = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        val:SetPoint("LEFT", cb.text, "RIGHT", 10, 0)
        frame.monthValText = val
      elseif opt.key == "trackYear" then
        local val = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        val:SetPoint("LEFT", cb.text, "RIGHT", 10, 0)
        frame.yearValText = val
      end
    end

    local tooltipCB = CreateCheckbox(
      p,
      addonName.."TrackTooltipCB",
      "Show tracking info as tooltip on icon hover",
      0,
      -20,
      NiceClockDB.trackTooltip or false,
      function(self)
        NiceClockDB.trackTooltip = self:GetChecked()
      end,
      nil,
      nil,
      prevAnchor,
      "BOTTOMLEFT",
      "TOPLEFT"
    )
    -- END FIX

    -- BEGIN FEATURE: reset tracking data
    local resetBtn = CreateFrame("Button", addonName.."TrackResetBtn", p, "UIPanelButtonTemplate")
    resetBtn:SetSize(120,22)
    resetBtn:SetPoint("TOPLEFT", tooltipCB, "BOTTOMLEFT", 0, -20)
    resetBtn:SetText("Reset Data")
    resetBtn:SetScript("OnClick", function()
      NiceClockDB.daySeconds   = 0
      NiceClockDB.weekSeconds  = 0
      NiceClockDB.monthSeconds = 0
      NiceClockDB.yearSeconds  = 0
      NiceClockDB.dayDate  = date("%Y-%m-%d")
      NiceClockDB.weekID   = date("%Y-%U")
      NiceClockDB.monthID  = date("%Y-%m")
      NiceClockDB.yearID   = date("%Y")
      frame.sessionStart = time()
      frame:UpdateTracking()
      print(addonName..": Tracking data reset.")
    end)
    -- END FEATURE
  end

  -- Combat Panel

  do
    local p = panels[5]
    -- Title for the font dropdown section
    local fontLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fontLabel:SetPoint("TOPLEFT", p, "TOPLEFT", LAYOUT.left, LAYOUT.top)
    fontLabel:SetText("Combat Text Font:")

    -- Create one dropdown per font group arranged in two columns
    local dropdowns = {}
    local lastDD
    -- forward declare helpers and preview/edit controls so callbacks
    -- defined below capture the proper local variables
    local SetCombatPreviewFont
    local preview
    local editBox
    local order = {"Fun","Future","Movie/Game","Easy-to-Read","Custom"}
    -- Provide wider dropdowns and spacing so text and arrows stay inside the
    -- settings frame even with longer font names.
    local colWidth  = 160
    local colOffset = 180
    for idx, grp in ipairs(order) do
      local dd = CreateFrame("Frame", addonName .. grp:gsub("[^%w]","") .. "Dropdown", p, "UIDropDownMenuTemplate")
      local row = math.floor((idx-1)/2)
      local col = (idx-1) % 2
      -- Start columns with a small left margin so they do not touch the frame edge
      local offsetX = col * colOffset + 10
      dd:SetPoint("TOPLEFT", fontLabel, "BOTTOMLEFT", offsetX, -20 - row*50)
      UIDropDownMenu_SetWidth(dd, colWidth)
      local lbl = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      -- Slight indent to line up with dropdown text area
      lbl:SetPoint("BOTTOMLEFT", dd, "TOPLEFT", 16, 3)
      lbl:SetText(grp)
      dropdowns[grp] = dd
      if idx == #order then
        lastDD = dd
      end

      UIDropDownMenu_Initialize(dd, function(self)
        local added = false
        for _,fname in ipairs(COMBAT_FONT_GROUPS[grp].fonts) do
          if combatFontExists[grp][fname] then
            added = true
            local fontData = combatFontCache[grp][fname]
            local info = UIDropDownMenu_CreateInfo()
            local display = fname:gsub("%.otf$",""):gsub("%.ttf$","")
            info.text = display
            info.value = fname
            -- Capture per-item values so the correct font is applied
            local fontObj   = fontData.font
            local relative  = fontData.relative
            local dispCopy  = display
            -- capture path separately so closures don't all reference the final
            -- loop iteration's value
            local pathCopy  = fontData.path
            info.func = function()
              -- clear other dropdown texts
              for g,d in pairs(dropdowns) do UIDropDownMenu_SetText(d, "Select Font") end
              NiceClockPerCharDB.combatFont = relative
              UIDropDownMenu_SetText(dd, dispCopy)
              SetCombatPreviewFont(fontObj, pathCopy)
              -- BEGIN FIX: force preview to redraw when font stays the same
              -- WoW's UI may skip layout if text hasn't changed; clearing then
              -- resetting ensures the new font actually renders.
              local txt = editBox:GetText()
              preview:SetText("")
              preview:SetText(txt)
              -- END FIX
            end
            info.checked = (NiceClockPerCharDB.combatFont == fontData.relative)
            UIDropDownMenu_AddButton(info)
          end
        end
        if not added then
          local info = UIDropDownMenu_CreateInfo()
          info.text = "No font detected"
          info.disabled = true
          UIDropDownMenu_AddButton(info)
        end
      end)
      local hasFonts = false
      for _,fname in ipairs(COMBAT_FONT_GROUPS[grp].fonts) do
        if combatFontExists[grp][fname] then hasFonts = true; break end
      end
      if not hasFonts then
        UIDropDownMenu_SetText(dd, "No font detected")
      end
    end

    -- Informational note
    local note = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    -- Anchor with a margin so the text does not hug the frame border
    note:SetPoint("TOPLEFT", lastDD, "BOTTOMLEFT", 0, -14)
    note:SetText("Requires full game restart once applied to change font")

    -- Font preview field
    preview = p:CreateFontString(addonName.."CombatPreviewFS","OVERLAY","GameFontNormalLarge")
    preview:SetJustifyH("LEFT"); preview:SetJustifyV("MIDDLE")
    preview:SetPoint("TOPLEFT", note, "BOTTOMLEFT", 0, -16)
    -- Wider preview box for readability
    preview:SetWidth(360)
    preview:SetText("12345")
    preview:SetTextColor(1,1,1,1)

    --[[
      Apply a combat font to the preview field.

      Some systems fail to load fonts unless provided an explicit file path.
      To make previewing reliable we try both the file path and the font object
      itself, falling back gracefully if either method fails.
    --]]
    --[[
      Robustly apply a combat font to the preview field. Some systems may fail
      to load fonts unless provided an explicit file path. We therefore attempt
      to load the font via its path using a protected call and fall back to the
      provided FontObject if that fails.
    --]]
    SetCombatPreviewFont = function(fontObj, path)
      if not fontObj then return end

      -- When called with a cached font table, extract its fields
      if type(fontObj) == "table" and fontObj.font then
        path    = fontObj.path
        fontObj = fontObj.font
      end

      -- Retrieve font attributes so we can scale them up for the preview
      local fPath, size, flags = fontObj:GetFont()
      path   = path   or fPath
      size   = size   or 20
      flags  = flags  or ""
      local scaled = size * 2

      -- Try loading the font file safely. SetFont does not return a status so
      -- we use pcall to detect any error when applying by path.
      local loadedOK = false
      if path then
        loadedOK = pcall(preview.SetFont, preview, path, scaled, flags)
      end

      -- If loading by path failed, fall back to using the FontObject directly
      if not loadedOK then
        preview:SetFontObject(fontObj)
      end

      -- Adjust height so tall glyphs are not clipped
      local _, appliedSize = preview:GetFont()
      appliedSize = appliedSize or scaled
      local pad = math.ceil(appliedSize * 0.4)
      preview:SetHeight(appliedSize + pad * 2)
    end

    -- Apply default font at double size on initialization
    SetCombatPreviewFont(preview:GetFontObject())

    -- Set initial dropdown text and preview based on saved font
    for _,dd in pairs(dropdowns) do UIDropDownMenu_SetText(dd, "Select Font") end
    if NiceClockPerCharDB.combatFont then
      local g,f = NiceClockPerCharDB.combatFont:match("^([^/]+)/(.+)$")
      if g and f and dropdowns[g] and combatFontExists[g][f] then
        UIDropDownMenu_SetText(dropdowns[g], f:gsub("%.otf$",""):gsub("%.ttf$","") )
        local fd = combatFontCache[g][f]
        if fd then SetCombatPreviewFont(fd.font, fd.path) end
      end
    end

    -- Edit box for preview text
    editBox = CreateFrame("EditBox", addonName.."CombatPreviewEdit", p, "InputBoxTemplate")
    editBox:SetSize(360, 24)
    editBox:SetPoint("TOPLEFT", preview, "BOTTOMLEFT", 0, -8)
    editBox:SetAutoFocus(false)
    editBox:SetText("12345")
    editBox:SetScript("OnTextChanged", function(self)
      preview:SetText(self:GetText())
    end)

    local applyBtn = CreateFrame("Button", addonName.."CombatApplyButton", p, "UIPanelButtonTemplate")
    applyBtn:SetSize(80,22)
    -- Keep apply button neatly below the edit box
    applyBtn:SetPoint("TOPLEFT", editBox, "BOTTOMLEFT", 0, -8)
    applyBtn:SetText("Apply")
    applyBtn:SetScript("OnClick", function()
      if NiceClockPerCharDB.combatFont then
        print(addonName..": Combat text font saved. Requires full game restart once applied.")
        UIErrorsFrame:AddMessage(addonName..": please EXIT & RESTART WoW to apply.",1,1,0)
      else
        print(addonName..": No combat font selected.")
      end
    end)


    -- Combat Text Size Slider
    -- --- Combat Text Size Slider -------------------------------------------------
    local sizeLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sizeLabel:SetPoint("TOPLEFT", applyBtn, "BOTTOMLEFT", 0, -24)
    sizeLabel:SetText("Combat Text Size:")

    local sizeSlider = CreateFrame("Slider", addonName.."CombatScaleSlider", p, "OptionsSliderTemplate")
    -- Slightly wider slider for readability
    sizeSlider:SetSize(300, 16)
    -- Drop the slider slightly lower for clarity
    sizeSlider:SetPoint("TOPLEFT", sizeLabel, "BOTTOMLEFT", 0, -12)
    sizeSlider:SetMinMaxValues(0.5, 5.0)
    sizeSlider:SetValueStep(0.1)
    sizeSlider:SetObeyStepOnDrag(true)
    _G[sizeSlider:GetName() .. "Low"]:SetText("0.5")
    _G[sizeSlider:GetName() .. "High"]:SetText("5.0")
    local sizeValue = p:CreateFontString(addonName.."CombatScaleValue", "OVERLAY", "GameFontHighlight")
    sizeValue:SetPoint("LEFT", sizeSlider, "RIGHT", 10, 0)

    local function UpdateCombatScale(val)
      val = math.floor(val * 10 + 0.5) / 10
      SetCVar("WorldTextScale", tostring(val))
      sizeValue:SetText(string.format("%.1f", val))
    end

    local currentScale = tonumber(GetCVar("WorldTextScale")) or 1.0
    sizeSlider:SetValue(currentScale)
    sizeValue:SetText(string.format("%.1f", currentScale))
    sizeSlider:SetScript("OnValueChanged", function(self,val) UpdateCombatScale(val) end)
    sizeSlider:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine("Drag to adjust combat text size",1,1,1)
      GameTooltip:Show()
    end)
    sizeSlider:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local combatOpts = {
      {k="combatHealing",  l="Show Combat Healing",  c="floatingCombatTextCombatHealing"},
      {k="combatDamage",   l="Show Combat Damage",   c="floatingCombatTextCombatDamage"},
      {k="petDamage",      l="Show Pet Damage",      c="floatingCombatTextPetMeleeDamage"},
      {k="periodicDamage", l="Show Periodic Damage", c="floatingCombatTextPeriodicDamage"},
    }
    -- Arrange checkboxes in two columns under the size slider
    for i, opt in ipairs(combatOpts) do
      local col = (i-1) % 2
      local row = math.floor((i-1) / 2)
      local x = col * 160
      -- tighter vertical spacing keeps checkboxes inside the panel
      local y = -30 * (row + 1)
      CreateCheckbox(p, "NiceClockCombat"..opt.k.."CB", opt.l, x, y, NiceClockPerCharDB[opt.k], function(self)
        NiceClockPerCharDB[opt.k] = self:GetChecked()
        SetCVar(opt.c, self:GetChecked() and 1 or 0)
      end, nil, nil, sizeSlider, "BOTTOMLEFT")
    end
  end

  self.settingsFrame   = f
  self.settingsOverlay = overlay
  if self.RefreshAlarmList then self:RefreshAlarmList() end
end

-- ─── Slash Command ───────────────────────────────────────────────────────────
SLASH_NICECLOCK1 = "/niceclock"
SlashCmdList["NICECLOCK"] = function(msg)
  local cmd = msg and strtrim(msg) or ""
  if cmd == "" then
    frame:ToggleSettings()
    return
  end

  local num, unit, text = cmd:lower():match("^remind%s+me%s+in%s+(%d+)([smhd])%s+(.+)$")
  if num then
    local secs = tonumber(num)
    if unit == "m" then secs = secs * 60
    elseif unit == "h" then secs = secs * 3600
    elseif unit == "d" then secs = secs * 86400
    end
    frame:AddToastReminder(secs, text)
    print(addonName..": reminder set in "..num..unit)
    return
  end

  -- Check for an alarm command in the format "alarm HH:MM [AM/PM] [reminder]"
  local h, m, ap, reminder = cmd:match("^alarm%s+(%d?%d):(%d%d)%s*(%a%a)?%s*(.*)$")
  if h then
    local hour = tonumber(h)
    local min  = tonumber(m)
    ap = ap and ap:upper() or nil
    -- validate minutes
    if min < 0 or min > 59 then
      print(addonName..": Invalid minutes. Must be 00-59.")
      return
    end
    -- handle 12h or 24h input
    if ap == "AM" or ap == "PM" then
      if hour < 1 or hour > 12 then
        print(addonName..": Invalid hour for 12h format. Use 1-12.")
        return
      end
      if ap == "PM" and hour < 12 then hour = hour + 12 end
      if ap == "AM" and hour == 12 then hour = 0 end
    else
      if hour < 0 or hour > 23 then
        print(addonName..": Invalid hour for 24h format. Use 0-23.")
        return
      end
    end

    frame:AddAbsoluteAlarm(hour, min, strtrim(reminder or ""))
    print(addonName..": Alarm time set to "..string.format("%02d:%02d", hour, min))
    if reminder and strtrim(reminder) ~= "" then
      print(addonName..": Reminder text set to '"..strtrim(reminder).."'.")
    end
    return
  end

  print(addonName..": unknown command")
end

-- ─── Relative Alarm Slash Command (/alarm) ───────────────────────────────────
SLASH_ALARM1 = "/alarm"
SlashCmdList["ALARM"] = function(msg)
  local input = msg and strtrim(msg) or ""
  if input == "" then
    print(addonName..": usage: /alarm <minutes> [message]")
    return
  end

  local mins, text = input:match("^(%d+)%s*(.*)$")
  mins = tonumber(mins)
  if not mins or mins <= 0 then
    print(addonName..": invalid minutes. Usage: /alarm <minutes> [message]")
    return
  end

  frame:AddRelativeAlarm(mins, strtrim(text or ""))
  print(string.format("%s: Alarm set for %d minute(s) from now.", addonName, mins))
  if text and strtrim(text) ~= "" then
    print(addonName..": Reminder text set to '"..strtrim(text).."'.")
  end
end

-- ─── Initialization & Events ─────────────────────────────────────────────────
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("CALENDAR_EVENT_ALARM")
frame:RegisterEvent("TIME_PLAYED_MSG")
frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterEvent("LOOT_READY")
frame:RegisterEvent("LOOT_CLOSED")
frame:RegisterEvent("UNIT_MODEL_CHANGED")

frame:SetScript("OnEvent", function(self, event, ...)
  if event == "PLAYER_LOGIN" then
    if not self.fs then
      -- Create clock text
      self.fs  = frame:CreateFontString(addonName.."Font","OVERLAY")
      self.fs:SetJustifyH("LEFT"); self.fs:SetJustifyV("BOTTOM")
      -- Create icon texture
      self.icon = frame:CreateTexture(addonName.."Icon","ARTWORK")
      self.icon:SetTexture("Interface\\AddOns\\NiceClock\\NiceClockicon.tga")

      -- ─── NEW: Icon Button for tracking tooltip on hover ──────────────────
      self.iconButton = CreateFrame("Button", addonName.."IconButton", frame)
      self.iconButton:SetAllPoints(self.icon)
      -- Show tracking tooltip when hovering icon next to clock text
      self.iconButton:SetScript("OnEnter", function(btn)
        frame:ShowTrackingTooltip(btn)
      end)
      self.iconButton:SetScript("OnLeave", GameTooltip_Hide)
      self.iconButton:EnableMouse(true)
      -- ────────────────────────────────────────────────────────────────

      -- Create halo shadow FontStrings for soft glow
      self.shadows = {}
      local offsets = {{1,0},{-1,0},{0,1},{0,-1}}
      for i, off in ipairs(offsets) do
        local fs = frame:CreateFontString(nil, "BACKGROUND", "GameFontNormal")
        fs:SetPoint("CENTER", self.fs, "CENTER", off[1], off[2])
        fs:SetTextColor(1,1,1,0.3)
        self.shadows[i] = fs
      end
    end

    self:ApplySettings()
    self:CreateMinimapIcon()
    self:CreateLDB()        -- new DataBroker feed
    self:ApplyQoLSettings()
    self:ApplyCombatSettings()
    self:ApplyMoveSettings()
    if not self.portraitHooked then
      hooksecurefunc("SetPortraitTexture", function(texture, unit)
        portraitManager:UpdateTexture(texture, unit)
      end)
      self.portraitHooked = true
    end
    -- BEGIN FIX: Ensure the clock is draggable on first login (no settings changes required)
    self:EnsureClockHitbox()
    -- END FIX
    -- BEGIN TRACKING ENHANCEMENT: initialize session & periods
    local now = time()
    self.sessionStart = now

    local today = date("%Y-%m-%d")
    if NiceClockDB.dayDate ~= today then
      NiceClockDB.dayDate    = today
      NiceClockDB.daySeconds = 0
    end

    local weekID = date("%Y-%U")
    if NiceClockDB.weekID ~= weekID then
      NiceClockDB.weekID      = weekID
      NiceClockDB.weekSeconds = 0
    end

    local monthID = date("%Y-%m")
    if NiceClockDB.monthID ~= monthID then
      NiceClockDB.monthID      = monthID
      NiceClockDB.monthSeconds = 0
    end

    local yearID = date("%Y")
    if NiceClockDB.yearID ~= yearID then
      NiceClockDB.yearID      = yearID
      NiceClockDB.yearSeconds = 0
    end

    if self.trackTicker then self.trackTicker:Cancel() end
    self:UpdateTracking()
    self.trackTicker = C_Timer.NewTicker(1, function() self:UpdateTracking() end)
    -- END TRACKING ENHANCEMENT

    -- Pull /played immediately so totals are available without the user typing /played.
    if RequestTimePlayed then
      RequestTimePlayed()
      -- Some client builds may delay TIME_PLAYED_MSG until after entering the world.
      -- Do a couple of light retries if we haven't received the snapshot yet.
      C_Timer.After(5, function()
        if not frame.playedBaseSeconds and RequestTimePlayed then RequestTimePlayed() end
      end)
      C_Timer.After(15, function()
        if not frame.playedBaseSeconds and RequestTimePlayed then RequestTimePlayed() end
      end)
    end

    self.alarmChecker = C_Timer.NewTicker(1, function()
      self:CheckAlarm()
      self:CheckReminders()
    end)
    self:UnregisterEvent("PLAYER_LOGIN")

  elseif event == "PLAYER_LOGOUT" then
    -- BEGIN TRACKING ENHANCEMENT: save session to accumulators
    local now = time()
    local elapsed = now - (self.sessionStart or now)
    NiceClockDB.daySeconds   = (NiceClockDB.daySeconds   or 0) + elapsed
    NiceClockDB.weekSeconds  = (NiceClockDB.weekSeconds  or 0) + elapsed
    NiceClockDB.monthSeconds = (NiceClockDB.monthSeconds or 0) + elapsed
    NiceClockDB.yearSeconds  = (NiceClockDB.yearSeconds  or 0) + elapsed
    if self.trackTicker then self.trackTicker:Cancel(); self.trackTicker = nil end
    if self.alarmChecker then self.alarmChecker:Cancel(); self.alarmChecker = nil end
    self:StopRGBTicker()
    self:StopWaveTicker()
    -- END TRACKING ENHANCEMENT

    -- Persist the current character's updated /played snapshot.
    do
      local key = self:GetPlayerKey()
      local cur = self:GetCurrentCharacterPlayedSeconds()
      if key and key ~= "" and cur then
        if type(NiceClockDB.playedByCharacter) ~= "table" then
          NiceClockDB.playedByCharacter = {}
        end
        NiceClockDB.playedByCharacter[key] = cur
      end
    end

  elseif event == "CALENDAR_EVENT_ALARM" then
    self:HandleCalendarAlarm(...)

  else
    return self[event] and self[event](self, event, ...)
  end
end)

-- ─── UpdateTracking: refresh the value texts ────────────────────────────────
function frame:UpdateTracking()
  local now = time()
  local sessionElapsed = now - (self.sessionStart or now)

  -- Total /played updates (character + all tracked characters)
  if self.totalPlayedCharValText then
    local cur = self:GetCurrentCharacterPlayedSeconds()
    self.totalPlayedCharValText:SetText(cur and self:FormatPlayedSeconds(cur) or "Loading…")
  end

  if self.totalPlayedAllValText then
    local all, count = self:GetAllTrackedCharactersPlayedSeconds()
    if all then
      self.totalPlayedAllValText:SetText(self:FormatPlayedSeconds(all))
    else
      self.totalPlayedAllValText:SetText("—")
    end
    if self.totalPlayedTrackedCountText then
      self.totalPlayedTrackedCountText:SetText(string.format("Tracked characters: %d", count or 0))
    end
  end

  if self.sessionValText then
    local txt = self:FormatSeconds(sessionElapsed)
    self.sessionValText:SetText(txt)
    self.sessionValText:SetShown(NiceClockDB.trackSession)
  end

  if self.dayValText then
    local dayTotal = (NiceClockDB.daySeconds or 0) + sessionElapsed
    self.dayValText:SetText(self:FormatSeconds(dayTotal))
    self.dayValText:SetShown(NiceClockDB.trackDay)
  end

  if self.weekValText then
    local weekTotal = (NiceClockDB.weekSeconds or 0) + sessionElapsed
    self.weekValText:SetText(self:FormatSeconds(weekTotal))
    self.weekValText:SetShown(NiceClockDB.trackWeek)
  end

  if self.monthValText then
    local monthTotal = (NiceClockDB.monthSeconds or 0) + sessionElapsed
    self.monthValText:SetText(self:FormatSeconds(monthTotal))
    self.monthValText:SetShown(NiceClockDB.trackMonth)
  end

  if self.yearValText then
    local yearTotal = (NiceClockDB.yearSeconds or 0) + sessionElapsed
    self.yearValText:SetText(self:FormatSeconds(yearTotal))
    self.yearValText:SetShown(NiceClockDB.trackYear)
  end
end
