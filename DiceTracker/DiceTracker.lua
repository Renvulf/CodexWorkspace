local ADDON_NAME = ...
local DiceTracker = {}
_G.DiceTracker = DiceTracker

-- ============================================================================
-- DiceTracker (Retail 12.0)
-- Tracks Worn Troll Dice (ItemID 36862) tosses and learns calibrated bucket
-- probabilities (Low / Seven / High) with conservative, anchored online learning.
-- GUI only. No slash commands. No chat output.
-- ============================================================================

-- -----------------------------
-- Constants
-- -----------------------------
local ITEM_ID = 36862 -- Worn Troll Dice
local EPS = 1e-6

local BUCKET_KEYS = { "low", "seven", "high" }
local BUCKET_LABEL = { low = "Low", seven = "Seven", high = "High" }

local FAIR_ANCHOR = {
  low = 15/36,
  seven = 6/36,
  high = 15/36,
}

local SCHEMA_VERSION = 7

local RT

-- Expert parameters
local KT_ALPHA_BUCKET = 0.5
local RHO_FAST = 0.03
local RHO_SLOW = 0.005

-- Loss EWMA smoothing for expert comparison (prequential)
local LOSS_RHO = 0.02

-- Softmax mixing vs anchor (bounded)
local ADV_CLAMP = 0.20
local ADV_BETA = 10.0

-- Conservative gates
local GATE_MASS0 = 25
local GATE_MASS1 = 125
local GATE_ADV0  = 0.010
local GATE_ADV1  = 0.060

-- Actor/global shrink gate
local ACTOR_MASS0 = 25
local ACTOR_MASS1 = 125
local ACTOR_ADV0  = 0.008
local ACTOR_ADV1  = 0.050

-- Runtime limits (bounded memory footprint)
local MAX_ACTORS = 50  -- LRU bounded
local AUTO_WINDOW = 15 -- seconds after a confirmed toss to auto-target that actor

-- Pending pairing window (conservative TTL)
local MAX_WAIT_SECONDS = 5

-- Dedupe
local LINEID_LRU_MAX = 256
local TTL_DEDUPE_MAX = 256
local TTL_DEDUPE_SECONDS = 4
local ITEMNAME_RETRY_MAX = 3
local ITEMNAME_RETRY_DELAY = 0.6
local UNKNOWN_TOSS_MAX = 64

-- -----------------------------
-- Utilities
-- -----------------------------
local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

local function shallowCopy(t)
  local o = {}
  for k, v in pairs(t) do o[k] = v end
  return o
end

local function deepCopy(obj, seen)
  if type(obj) ~= "table" then return obj end
  if not seen then seen = {} end
  if seen[obj] then return seen[obj] end
  local out = {}
  seen[obj] = out
  for k, v in pairs(obj) do
    out[deepCopy(k, seen)] = deepCopy(v, seen)
  end
  return out
end

local function stripColorAndTextures(s)
  if type(s) ~= "string" then return "" end
  s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  s = s:gsub("|T.-|t", "")
  return s
end

local function normalizeWhitespace(s)
  if type(s) ~= "string" then return "" end
  s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  return s
end

local function cleanMessage(s)
  s = stripColorAndTextures(s)
  s = normalizeWhitespace(s)
  return s
end

local function selfActorName()
  if RT.selfTesting and RT.selfTestSelfName then
    return RT.selfTestSelfName
  end
  if UnitFullName then
    local n, r = UnitFullName("player")
    if n and r and r ~= "" then return n .. "-" .. r end
    if n and n ~= "" then return n end
  end
  return UnitName and UnitName("player") or "?"
end

local function selfActorKey()
  if RT.selfTesting and RT.selfTestSelfGuid then
    return RT.selfTestSelfGuid
  end
  if UnitGUID then
    local guid = UnitGUID("player")
    if guid and guid ~= "" then return guid end
  end
  return selfActorName()
end

local function stableActorKeyFromNameGuid(name, guid)
  if type(guid) == "string" and guid ~= "" then
    return guid
  end
  local selfName = selfActorName()
  if name and selfName and name == selfName and UnitGUID then
    local selfGuid = UnitGUID("player")
    if selfGuid and selfGuid ~= "" then
      return selfGuid
    end
  end
  return name
end

local function isGuidKey(key)
  if type(key) ~= "string" then return false end
  return key:match("^Player%-%x+%-%x+") ~= nil
end

local function targetActorKey()
  if RT.selfTesting and RT.selfTestTargetKey then
    return RT.selfTestTargetKey
  end
  if not UnitExists or not UnitIsPlayer then return nil end
  if not UnitExists("target") or not UnitIsPlayer("target") then return nil end
  if UnitGUID then
    local guid = UnitGUID("target")
    if guid and guid ~= "" then
      return guid
    end
  end
  if UnitFullName then
    local n, r = UnitFullName("target")
    if n and n ~= "" then
      if r and r ~= "" then
        return n .. "-" .. r
      end
      return n
    end
  end
  return nil
end

local function isValidActorName(name)
  if type(name) ~= "string" then return false end
  name = normalizeWhitespace(name)
  if name == "" then return false end
  -- Player names do not contain spaces; if our parsing captured spaces, it's not deterministic.
  if name:find("%s") then return false end
  return true
end

local function baseName(actor)
  if type(actor) ~= "string" then return nil end
  return actor:match("^([^%-]+)") or actor
end

local function canonicalizeActorName(actorName)
  if type(actorName) ~= "string" then return nil end
  actorName = normalizeWhitespace(stripColorAndTextures(actorName))
  if actorName == "" then return nil end

  -- Map localized "You" to the local player name
  local youWord = (_G and type(_G.YOU) == "string") and _G.YOU or "You"
  if actorName:lower() == tostring(youWord):lower() or actorName:lower() == "you" then
    return selfActorName()
  end

  -- Map local player's unqualified name to full name-realm when available
  local selfBase = UnitName and UnitName("player") or nil
  local selfFull = selfActorName()
  if type(selfBase) == "string" and selfBase ~= "" and actorName == selfBase then
    return selfFull
  end
  local bn = baseName(selfFull)
  if bn and actorName == bn then
    return selfFull
  end

  return actorName
end

local function bucketFromSum(sum)
  if sum >= 2 and sum <= 6 then return "low" end
  if sum == 7 then return "seven" end
  if sum >= 8 and sum <= 12 then return "high" end
  return nil
end

local function clampAndRenorm(p)
  local sum = 0
  for _, k in ipairs(BUCKET_KEYS) do
    local v = tonumber(p[k]) or 0
    if v < EPS then v = EPS end
    p[k] = v
    sum = sum + v
  end
  if sum <= 0 then
    p.low, p.seven, p.high = FAIR_ANCHOR.low, FAIR_ANCHOR.seven, FAIR_ANCHOR.high
    return p
  end
  for _, k in ipairs(BUCKET_KEYS) do
    p[k] = p[k] / sum
  end
  return p
end

local function nllForBucket(probs, bucket)
  local p = tonumber(probs[bucket]) or 0
  if p < EPS then p = EPS end
  return -math.log(p)
end

local function ewmaUpdate(prev, x, rho)
  if prev == nil then return x end
  return (1 - rho) * prev + rho * x
end

local function safeNow()
  if GetTime then return GetTime() end
  return 0
end

-- Rounding to 1 decimal each with exact 100.0 total after rounding.
local function roundedPercentsTo100(p)
  local raw = {
    low   = (tonumber(p.low) or 0) * 1000,   -- tenths of a percent
    seven = (tonumber(p.seven) or 0) * 1000,
    high  = (tonumber(p.high) or 0) * 1000,
  }

  -- Base: floor, then distribute remainder.
  local base = {}
  local frac = {}
  local sumBase = 0
  for _, k in ipairs(BUCKET_KEYS) do
    local v = raw[k]
    local b = math.floor(v)
    base[k] = b
    frac[k] = v - b
    sumBase = sumBase + b
  end

  local target = 1000
  local diff = target - sumBase

  if diff ~= 0 then
    -- Sort buckets by fractional part (descending if we need to add, ascending if subtract)
    local order = { "low", "seven", "high" }
    table.sort(order, function(a, b)
      if diff > 0 then
        return frac[a] > frac[b]
      else
        return frac[a] < frac[b]
      end
    end)

    local i = 1
    local steps = math.abs(diff)
    local stepSign = (diff > 0) and 1 or -1
    while steps > 0 do
      local k = order[i]
      base[k] = base[k] + stepSign
      steps = steps - 1
      i = i + 1
      if i > #order then i = 1 end
    end
  end

  local out = {}
  for _, k in ipairs(BUCKET_KEYS) do
    out[k] = base[k] / 10.0 -- one decimal percent
  end
  return out
end

-- -----------------------------
-- Runtime state
-- -----------------------------
RT = {
  itemName = nil,

  pending = {}, -- [actorKeyPrimary] = { actorKeyPrimary, actorName, t0, rolls={...}, tossLineID, tossGuid, expireToken }
  lastConfirmedActor = nil,
  lastConfirmedTime = 0,

  lineIdSeen = {},   -- [lineID]=true
  lineIdQueue = {},  -- FIFO
  ttlSeen = {},      -- [key]=expireTime

  lastDebug = {
    lastSample = nil,
    selfTest = { ran = false, ok = true, details = "" },
  },

  pendingUnknownTosses = {}, -- [key]=entry (bounded)
}

local function dedupeLineID(lineID)
  if type(lineID) ~= "number" then return false end
  if RT.lineIdSeen[lineID] then return true end
  RT.lineIdSeen[lineID] = true
  RT.lineIdQueue[#RT.lineIdQueue + 1] = lineID
  if #RT.lineIdQueue > LINEID_LRU_MAX then
    local old = table.remove(RT.lineIdQueue, 1)
    if old then RT.lineIdSeen[old] = nil end
  end
  return false
end

local function dedupeTTL(key)
  local now = safeNow()
  -- prune occasionally (bounded)
  local count = 0
  for k, exp in pairs(RT.ttlSeen) do
    if exp <= now then
      RT.ttlSeen[k] = nil
    else
      count = count + 1
    end
  end
  if count > TTL_DEDUPE_MAX then
    -- hard trim: clear all (bounded, conservative: better to drop uncertain samples)
    RT.ttlSeen = {}
  end

  local exp = RT.ttlSeen[key]
  if exp and exp > now then
    return true
  end
  RT.ttlSeen[key] = now + TTL_DEDUPE_SECONDS
  return false
end

-- -----------------------------
-- SavedVariables: schema + bounded storage
-- -----------------------------
local function newEmptyModel()
  local m = {
    -- Long-run bucket counts (E1)
    bucket = { low = 0, seven = 0, high = 0, total = 0 },

    -- Exponentially decayed counts (E2/E3)
    fast = { low = 0, seven = 0, high = 0, total = 0 },
    slow = { low = 0, seven = 0, high = 0, total = 0 },

    -- Optional bounded experts (S1/F1/P1)
    sum = { total = 0 },
    face1 = { total = 0 },
    face2 = { total = 0 },
    pair = { total = 0 },

    -- Optional Markov (M1)
    markov = {
      last = nil,
      t = {
        low = { low = 0, seven = 0, high = 0 },
        seven = { low = 0, seven = 0, high = 0 },
        high = { low = 0, seven = 0, high = 0 },
      },
    },

    -- EWMA prequential log losses (anchor + experts + displayed)
    loss = {
      anchor = nil,
      displayed = nil,
      E1 = nil,
      E2 = nil,
      E3 = nil,
      S1 = nil,
      F1 = nil,
      P1 = nil,
      M1 = nil,

      -- For actor streams: comparison losses
      globalDisplayed = nil,
      actorDisplayed = nil,
      combinedDisplayed = nil,
    },

    -- Cached expert weights (diagnostics only; derived from losses)
    weights = {
      E1 = nil,
      E2 = nil,
      E3 = nil,
    },

    meta = {
      lastSeen = 0,
      displayName = nil,
    }
  }

  for s = 2, 12 do
    m.sum[s] = 0
  end
  for f = 1, 6 do
    m.face1[f] = 0
    m.face2[f] = 0
  end
  for i = 1, 36 do
    m.pair[i] = 0
  end

  return m
end

local function newDB()
  return {
    schemaVersion = SCHEMA_VERSION,
    settings = {
      debugOverlay = false,
      target = { mode = "auto", actor = nil }, -- mode: auto|me|global|actor
    },
    ui = {
      point = "CENTER",
      relPoint = "CENTER",
      x = 0,
      y = 0,
      scale = 1,
    },
    drop = { total = 0, reasons = {} },
    global = newEmptyModel(),
    actors = {
      map = {},      -- [actorKey]=model
    },
    lastSample = nil, -- lightweight summary for debug UI
  }
end

local function bumpDrop(reason)
  if not DiceTrackerDB or not DiceTrackerDB.drop then return end
  DiceTrackerDB.drop.total = (tonumber(DiceTrackerDB.drop.total) or 0) + 1
  local r = DiceTrackerDB.drop.reasons or {}
  DiceTrackerDB.drop.reasons = r
  r[reason] = (tonumber(r[reason]) or 0) + 1
end

local function isModelTable(t)
  return type(t) == "table"
    and type(t.bucket) == "table"
    and type(t.fast) == "table"
    and type(t.slow) == "table"
    and type(t.loss) == "table"
end

local function ensureModelTables(m)
  if not isModelTable(m) then return newEmptyModel() end

  m.bucket = m.bucket or { low = 0, seven = 0, high = 0, total = 0 }
  m.fast = m.fast or { low = 0, seven = 0, high = 0, total = 0 }
  m.slow = m.slow or { low = 0, seven = 0, high = 0, total = 0 }

  m.sum = m.sum or { total = 0 }
  for s = 2, 12 do m.sum[s] = tonumber(m.sum[s]) or 0 end
  m.sum.total = tonumber(m.sum.total) or 0

  m.face1 = m.face1 or { total = 0 }
  m.face2 = m.face2 or { total = 0 }
  for f = 1, 6 do
    m.face1[f] = tonumber(m.face1[f]) or 0
    m.face2[f] = tonumber(m.face2[f]) or 0
  end
  m.face1.total = tonumber(m.face1.total) or 0
  m.face2.total = tonumber(m.face2.total) or 0

  m.pair = m.pair or { total = 0 }
  for i = 1, 36 do m.pair[i] = tonumber(m.pair[i]) or 0 end
  m.pair.total = tonumber(m.pair.total) or 0

  m.markov = m.markov or { last = nil, t = {} }
  m.markov.t = m.markov.t or {}
  for _, from in ipairs(BUCKET_KEYS) do
    m.markov.t[from] = m.markov.t[from] or {}
    for _, to in ipairs(BUCKET_KEYS) do
      m.markov.t[from][to] = tonumber(m.markov.t[from][to]) or 0
    end
  end

  m.loss = m.loss or {}
  m.weights = m.weights or {}
  for _, k in ipairs({ "E1", "E2", "E3" }) do
    if m.weights[k] ~= nil and type(m.weights[k]) ~= "number" then
      m.weights[k] = nil
    end
  end
  m.meta = m.meta or {}
  m.meta.lastSeen = tonumber(m.meta.lastSeen) or 0
  if m.meta.displayName ~= nil and type(m.meta.displayName) ~= "string" then
    m.meta.displayName = nil
  end

  return m
end

local function migrateIfNeeded(existing)
  if type(existing) ~= "table" then return newDB() end

  local db = existing

  -- Migrate from older schema that used "version" (v2) and stored aggregate counts in db.data
  if db.schemaVersion == nil and tonumber(db.version) == 2 and type(db.data) == "table" then
    local fresh = newDB()

    -- Salvage long-run bucket counts if present
    local totals = db.data.totals
    if type(totals) == "table" then
      fresh.global.bucket.low   = tonumber(totals.low) or 0
      fresh.global.bucket.seven = tonumber(totals.seven) or 0
      fresh.global.bucket.high  = tonumber(totals.high) or 0
      fresh.global.bucket.total = tonumber(totals.total) or (fresh.global.bucket.low + fresh.global.bucket.seven + fresh.global.bucket.high)
    end

    -- Salvage sum counts
    if type(db.data.sums) == "table" then
      for s = 2, 12 do
        fresh.global.sum[s] = tonumber(db.data.sums[s]) or 0
      end
      local st = 0
      for s = 2, 12 do st = st + (fresh.global.sum[s] or 0) end
      fresh.global.sum.total = st
    end

    -- Salvage lastCat for Markov last state
    if type(db.data.lastCat) == "string" and BUCKET_LABEL[db.data.lastCat] then
      fresh.global.markov.last = db.data.lastCat
    end
    if type(db.data.transitions) == "table" then
      for _, from in ipairs(BUCKET_KEYS) do
        if type(db.data.transitions[from]) == "table" then
          for _, to in ipairs(BUCKET_KEYS) do
            fresh.global.markov.t[from][to] = tonumber(db.data.transitions[from][to]) or 0
          end
        end
      end
    end

    -- Settings migration: keep frame position if present
    if type(db.ui) == "table" then
      fresh.ui.point = db.ui.point or fresh.ui.point
      fresh.ui.relPoint = db.ui.relPoint or fresh.ui.relPoint
      fresh.ui.x = tonumber(db.ui.x) or fresh.ui.x
      fresh.ui.y = tonumber(db.ui.y) or fresh.ui.y
      fresh.ui.scale = tonumber(db.ui.scale) or fresh.ui.scale
    end

    -- If old had uiEnabled setting, preserve it by keeping the frame visible regardless
    if type(db.settings) == "table" then
      -- announceOnToss was removed (no chat output); ignore.
    end

    return fresh
  end

  -- Bump forward older schema versions (safe: we only add/ensure missing fields; never wipe learned stats).
  local sv = tonumber(db.schemaVersion)
  if sv and sv < SCHEMA_VERSION then
    db.schemaVersion = SCHEMA_VERSION
  end

  -- If schemaVersion matches, ensure integrity / fill missing tables
  if tonumber(db.schemaVersion) == SCHEMA_VERSION then
    db.settings = db.settings or {}
    db.settings.debugOverlay = (db.settings.debugOverlay == true)
    db.settings.target = db.settings.target or { mode = "auto", actor = nil }
    if type(db.settings.target) ~= "table" then
      db.settings.target = { mode = "auto", actor = nil }
    end
    local mode = db.settings.target.mode
    if mode ~= "auto" and mode ~= "me" and mode ~= "global" and mode ~= "actor" then
      db.settings.target.mode = "auto"
      db.settings.target.actor = nil
    end
    if db.settings.target.mode ~= "actor" then
      db.settings.target.actor = nil
    end

    db.ui = db.ui or {}
    db.ui.point = db.ui.point or "CENTER"
    db.ui.relPoint = db.ui.relPoint or "CENTER"
    db.ui.x = tonumber(db.ui.x) or 0
    db.ui.y = tonumber(db.ui.y) or 0
    db.ui.scale = tonumber(db.ui.scale) or 1

    db.drop = db.drop or { total = 0, reasons = {} }
    db.drop.total = tonumber(db.drop.total) or 0
    db.drop.reasons = db.drop.reasons or {}

    db.global = ensureModelTables(db.global)

    db.actors = db.actors or { map = {} }
    db.actors.map = db.actors.map or {}
    for actor, model in pairs(db.actors.map) do
      db.actors.map[actor] = ensureModelTables(model)
    end

    db.lastSample = (type(db.lastSample) == "table") and db.lastSample or nil

    return db
  end

  -- Unknown/corrupt schema: salvage what we can conservatively.
  local fresh = newDB()
  if type(db.global) == "table" then
    -- best-effort: copy aggregate bucket totals if present
    if type(db.global.bucket) == "table" then
      fresh.global.bucket.low = tonumber(db.global.bucket.low) or 0
      fresh.global.bucket.seven = tonumber(db.global.bucket.seven) or 0
      fresh.global.bucket.high = tonumber(db.global.bucket.high) or 0
      fresh.global.bucket.total = tonumber(db.global.bucket.total) or (fresh.global.bucket.low + fresh.global.bucket.seven + fresh.global.bucket.high)
    end
  end
  if type(db.ui) == "table" then
    fresh.ui.point = db.ui.point or fresh.ui.point
    fresh.ui.relPoint = db.ui.relPoint or fresh.ui.relPoint
    fresh.ui.x = tonumber(db.ui.x) or fresh.ui.x
    fresh.ui.y = tonumber(db.ui.y) or fresh.ui.y
    fresh.ui.scale = tonumber(db.ui.scale) or fresh.ui.scale
  end
  return fresh
end

-- Global SavedVariables reference
DiceTrackerDB = nil

-- -----------------------------
-- Item confirmation for toss
-- -----------------------------
local onTossEvent

local function getItemNameNow()
  if RT.selfTesting and RT.selfTestItemNameGate then
    local gate = RT.selfTestItemNameGate
    if type(gate.remaining) == "number" and gate.remaining > 0 then
      gate.remaining = gate.remaining - 1
      return nil
    end
    return gate.name
  end
  return GetItemInfo and GetItemInfo(ITEM_ID) or nil
end

local function refreshItemName(attempt)
  attempt = attempt or 0
  if attempt > 8 then return end
  local name = getItemNameNow()
  if name and name ~= "" then
    RT.itemName = name
    return
  end
  if (not RT.selfTesting) and C_Timer and C_Timer.After then
    C_Timer.After(1.5, function() refreshItemName(attempt + 1) end)
  end
end

local function processPendingUnknownTosses()
  local keys = {}
  for k in pairs(RT.pendingUnknownTosses) do
    keys[#keys + 1] = k
  end
  for _, k in ipairs(keys) do
    local entry = RT.pendingUnknownTosses[k]
    if entry then
      local name = getItemNameNow()
      if name and name ~= "" then
        RT.itemName = name
        RT.pendingUnknownTosses[k] = nil
        onTossEvent(entry.event, entry.msg, entry.sender, entry.lineID, entry.guid, false)
      else
        entry.attempts = (entry.attempts or 0) + 1
        if entry.attempts >= ITEMNAME_RETRY_MAX then
          RT.pendingUnknownTosses[k] = nil
          bumpDrop("toss_item_unknown")
        elseif (not RT.selfTesting) and C_Timer and C_Timer.After then
          C_Timer.After(ITEMNAME_RETRY_DELAY, function()
            processPendingUnknownTosses()
          end)
        end
      end
    end
  end
end

local function queueUnknownToss(event, msg, sender, lineID, guid)
  local cleanedMsg = cleanMessage(msg)
  local key
  if type(lineID) == "number" then
    key = "L|" .. lineID
  else
    key = tostring(event) .. "|" .. tostring(sender or "?") .. "|" .. tostring(cleanedMsg)
  end
  if RT.pendingUnknownTosses[key] then return end

  local count = 0
  for _ in pairs(RT.pendingUnknownTosses) do count = count + 1 end
  if count >= UNKNOWN_TOSS_MAX then
    bumpDrop("toss_unknown_overflow")
    return
  end

  RT.pendingUnknownTosses[key] = {
    event = event,
    msg = msg,
    sender = sender,
    lineID = lineID,
    guid = guid,
    attempts = 0,
  }

  processPendingUnknownTosses()
end

local function isConfirmedTossMessage(msg)
  if type(msg) ~= "string" then return false end
  if msg:find("|Hitem:" .. ITEM_ID .. ":", 1, true) then
    return true
  end
  local itemName = RT.itemName
  if itemName and itemName ~= "" then
    local cleaned = cleanMessage(msg)
    if cleaned:lower():find(itemName:lower(), 1, true) then
      return true
    end
  end
  return false
end

-- -----------------------------
-- Roll parsing (locale-safe)
-- -----------------------------
local rollPatternOther = nil
local rollPatternSelf = nil

local function formatToPattern(fmt)
  -- Convert Blizzard's localized format strings (e.g. RANDOM_ROLL_RESULT) into a strict Lua pattern.
  -- Supports both plain and positional specifiers (e.g. %1$s, %2$d).
  if type(fmt) ~= "string" or fmt == "" then return nil end

  local p = fmt

  -- Normalize positional specifiers to plain ones so we can replace them deterministically.
  -- (Lua's string patterns don't understand the positional syntax; the chat message is already formatted.)
  p = p:gsub("%%(%d+)%$s", "%%s")
  p = p:gsub("%%(%d+)%$d", "%%d")
  p = p:gsub("%%(%d+)%$u", "%%d")

  -- Escape pattern magic characters, including %.
  p = p:gsub("([%(%)%.%+%-%*%?%[%^%$%%])", "%%%1")

  -- Replace escaped placeholders with captures.
  -- After escaping, %s becomes %%s and %d becomes %%d.
  p = p:gsub("%%%%s", "(.+)")
  p = p:gsub("%%%%d", "(%%d+)")

  return "^" .. p .. "$"
end

local function buildRollPatterns()
  rollPatternOther = formatToPattern(_G.RANDOM_ROLL_RESULT)
  rollPatternSelf = formatToPattern(_G.RANDOM_ROLL_RESULT_SELF)
end

local function parseRollLine(msg)
  if type(msg) ~= "string" then return nil end
  msg = cleanMessage(msg)

  if not rollPatternOther or not rollPatternSelf then
    buildRollPatterns()
  end

  -- 1) Localized patterns
  if rollPatternOther then
    local who, roll, minV, maxV = msg:match(rollPatternOther)
    if who and roll and minV and maxV then
      who = normalizeWhitespace(stripColorAndTextures(who))
      if not isValidActorName(who) then
        return nil
      end
      roll, minV, maxV = tonumber(roll), tonumber(minV), tonumber(maxV)
      if roll and minV and maxV then
        return who, roll, minV, maxV
      end
      return nil
    end
  end

  if rollPatternSelf then
    local roll, minV, maxV = msg:match(rollPatternSelf)
    if roll and minV and maxV then
      roll, minV, maxV = tonumber(roll), tonumber(minV), tonumber(maxV)
      local who = selfActorName()
      return who, roll, minV, maxV
    end
  end

  -- 2) Numeric fallback: still require the line to end with "(1-6)" (dash variants ok).
  -- Must still deterministically capture actor (no spaces allowed).
  local who2, roll2, min2, max2 = msg:match("^(.+)%s+%S+%s+(%d+)%s*%(%s*(%d+)%s*[-–—]%s*(%d+)%s*%)$")
  if who2 and roll2 and min2 and max2 then
    who2 = normalizeWhitespace(stripColorAndTextures(who2))
    if not isValidActorName(who2) then
      return nil
    end
    roll2, min2, max2 = tonumber(roll2), tonumber(min2), tonumber(max2)
    if roll2 and min2 and max2 then
      return who2, roll2, min2, max2
    end
  end

  return nil
end

local function isPotentialRollMessage(msg)
  if type(msg) ~= "string" then return false end
  msg = cleanMessage(msg)
  if not rollPatternOther or not rollPatternSelf then
    buildRollPatterns()
  end
  if rollPatternOther and msg:match(rollPatternOther) then return true end
  if rollPatternSelf and msg:match(rollPatternSelf) then return true end
  if msg:match("%(%s*%d+%s*[-–—]%s*%d+%s*%)$") then return true end
  return false
end

-- -----------------------------
-- Expert probabilities
-- -----------------------------
local function probsKTBucketFromCounts(counts)
  local n = (tonumber(counts.total) or 0)
  local denom = n + 3 * KT_ALPHA_BUCKET
  local p = {
    low = ((tonumber(counts.low) or 0) + KT_ALPHA_BUCKET) / denom,
    seven = ((tonumber(counts.seven) or 0) + KT_ALPHA_BUCKET) / denom,
    high = ((tonumber(counts.high) or 0) + KT_ALPHA_BUCKET) / denom,
  }
  return clampAndRenorm(p)
end

local function probsKTBucketFromDecay(decayCounts)
  local n = (tonumber(decayCounts.total) or 0)
  local denom = n + 3 * KT_ALPHA_BUCKET
  local p = {
    low = ((tonumber(decayCounts.low) or 0) + KT_ALPHA_BUCKET) / denom,
    seven = ((tonumber(decayCounts.seven) or 0) + KT_ALPHA_BUCKET) / denom,
    high = ((tonumber(decayCounts.high) or 0) + KT_ALPHA_BUCKET) / denom,
  }
  return clampAndRenorm(p)
end

local function gatherExpertProbs(model)
  -- This iteration implements ONLY E1/E2/E3.
  local p = {}
  p.E1 = probsKTBucketFromCounts(model.bucket)
  p.E2 = probsKTBucketFromDecay(model.fast)
  p.E3 = probsKTBucketFromDecay(model.slow)
  return p
end

local function computeWeightsVsAnchor(model, expertProbs)
  -- Conservative softmax weights over expert advantage vs anchor (bounded).
  local weights = {}
  local sumW = 0.0

  local la = model.loss and model.loss.anchor or nil
  local bestAdv = 0.0

  for key, _ in pairs(expertProbs) do
    local le = model.loss and model.loss[key] or nil
    local adv = 0.0
    if la ~= nil and le ~= nil then
      adv = la - le
      bestAdv = math.max(bestAdv, adv)
    end
    adv = clamp(adv, -ADV_CLAMP, ADV_CLAMP)
    local w = math.exp(ADV_BETA * adv)
    weights[key] = w
    sumW = sumW + w
  end

  if sumW <= 0 then
    -- Fallback: uniform over present experts
    local n = 0
    for _ in pairs(expertProbs) do n = n + 1 end
    if n <= 0 then n = 1 end
    for k in pairs(expertProbs) do
      weights[k] = 1.0 / n
    end
  else
    for k, v in pairs(weights) do
      weights[k] = v / sumW
    end
  end

  return weights, bestAdv
end

local function mixExperts(weights, expertProbs)
  -- Mixture prediction: normalized weighted sum of expert bucket probabilities (no anchor here).
  local p = { low = 0, seven = 0, high = 0 }

  for key, w in pairs(weights) do
    local e = expertProbs[key]
    if e then
      p.low = p.low + w * (tonumber(e.low) or 0)
      p.seven = p.seven + w * (tonumber(e.seven) or 0)
      p.high = p.high + w * (tonumber(e.high) or 0)
    end
  end

  return clampAndRenorm(p)
end

local function anchorGate(model, pMixed, bestAdv)
  local n = tonumber(model.bucket.total) or 0
  local massFactor = clamp((n - GATE_MASS0) / (GATE_MASS1 - GATE_MASS0), 0, 1)
  local advFactor = clamp((bestAdv - GATE_ADV0) / (GATE_ADV1 - GATE_ADV0), 0, 1)
  local g = massFactor * advFactor

  local p = {
    low = (1 - g) * FAIR_ANCHOR.low + g * pMixed.low,
    seven = (1 - g) * FAIR_ANCHOR.seven + g * pMixed.seven,
    high = (1 - g) * FAIR_ANCHOR.high + g * pMixed.high,
  }
  p = clampAndRenorm(p)

  -- Anti-overconfidence early
  local capBase = 0.55
  local capMass = clamp((n - 50) / 250, 0, 1)
  local capAdv = clamp((bestAdv - 0.02) / 0.08, 0, 1)
  local cap = capBase + 0.30 * capMass + 0.10 * capAdv
  cap = clamp(cap, 0.55, 0.90)

  local maxK, maxV = "low", p.low
  if p.seven > maxV then maxK, maxV = "seven", p.seven end
  if p.high > maxV then maxK, maxV = "high", p.high end

  if maxV > cap then
    local excess = maxV - cap
    p[maxK] = cap
    local others = {}
    for _, k in ipairs(BUCKET_KEYS) do
      if k ~= maxK then others[#others+1] = k end
    end
    local sumOthers = p[others[1]] + p[others[2]]
    if sumOthers <= 0 then
      p[others[1]] = (1 - cap) * 0.5
      p[others[2]] = (1 - cap) * 0.5
    else
      p[others[1]] = p[others[1]] + excess * (p[others[1]] / sumOthers)
      p[others[2]] = p[others[2]] + excess * (p[others[2]] / sumOthers)
    end
    p = clampAndRenorm(p)
  end

  return p, g
end

-- -----------------------------
-- Model updates (learn)
-- -----------------------------
local function updateDecayCounts(counts, bucket, rho)
  local d = 1 - rho
  counts.low = (tonumber(counts.low) or 0) * d
  counts.seven = (tonumber(counts.seven) or 0) * d
  counts.high = (tonumber(counts.high) or 0) * d

  counts[bucket] = (tonumber(counts[bucket]) or 0) + 1
  counts.total = (tonumber(counts.low) or 0) + (tonumber(counts.seven) or 0) + (tonumber(counts.high) or 0)
end

local function updateModelWithSample(model, bucket, die1, die2)
  model.bucket[bucket] = (tonumber(model.bucket[bucket]) or 0) + 1
  model.bucket.total = (tonumber(model.bucket.total) or 0) + 1

  updateDecayCounts(model.fast, bucket, RHO_FAST)
  updateDecayCounts(model.slow, bucket, RHO_SLOW)

  model.meta.lastSeen = time and time() or 0
end

local function updateLossesPrequential(model, bucket, expertProbs, alsoDisplayProbs)
  -- anchor
  local nllA = nllForBucket(FAIR_ANCHOR, bucket)
  model.loss.anchor = ewmaUpdate(model.loss.anchor, nllA, LOSS_RHO)

  -- experts
  for key, probs in pairs(expertProbs) do
    local nll = nllForBucket(probs, bucket)
    model.loss[key] = ewmaUpdate(model.loss[key], nll, LOSS_RHO)
  end

  -- displayed (global/actor mixture with anchor gating)
  if alsoDisplayProbs then
    local nllD = nllForBucket(alsoDisplayProbs, bucket)
    model.loss.displayed = ewmaUpdate(model.loss.displayed, nllD, LOSS_RHO)
  end
end

-- -----------------------------
-- Actor store (bounded LRU)
-- -----------------------------
local function ensureActorModel(actorKey)
  if not DiceTrackerDB then return nil end
  local map = DiceTrackerDB.actors.map
  if not map then
    DiceTrackerDB.actors.map = {}
    map = DiceTrackerDB.actors.map
  end

  local m = map[actorKey]
  if not m then
    m = newEmptyModel()
    map[actorKey] = m
  else
    m = ensureModelTables(m)
    map[actorKey] = m
  end
  m.meta.lastSeen = time and time() or 0

  -- Evict LRU if needed (pin local player)
  local selfKey = selfActorKey()
  local count = 0
  for _ in pairs(map) do count = count + 1 end
  if count > MAX_ACTORS then
    local oldestKey, oldestSeen = nil, nil
    for k, v in pairs(map) do
      if k ~= selfKey then
        local seen = (type(v) == "table" and type(v.meta) == "table" and tonumber(v.meta.lastSeen)) or 0
        if not oldestSeen or seen < oldestSeen then
          oldestSeen = seen
          oldestKey = k
        end
      end
    end
    if oldestKey then
      map[oldestKey] = nil
    end
  end

  return m
end


local function mergeModels(dst, src)
  if type(dst) ~= "table" or type(src) ~= "table" then return end
  dst = ensureModelTables(dst)
  src = ensureModelTables(src)

  local function mergeCounts(dt, st)
    if type(dt) ~= "table" or type(st) ~= "table" then return end
    for _, k in ipairs(BUCKET_KEYS) do
      dt[k] = (tonumber(dt[k]) or 0) + (tonumber(st[k]) or 0)
    end
    dt.total = (tonumber(dt.total) or 0) + (tonumber(st.total) or 0)
  end

  mergeCounts(dst.bucket, src.bucket)
  mergeCounts(dst.fast, src.fast)
  mergeCounts(dst.slow, src.slow)

  local wDst = (type(dst.bucket) == "table" and tonumber(dst.bucket.total)) or 0
  local wSrc = (type(src.bucket) == "table" and tonumber(src.bucket.total)) or 0
  if type(dst.loss) == "table" and type(src.loss) == "table" then
    for k, v in pairs(src.loss) do
      if dst.loss[k] == nil then
        dst.loss[k] = v
      elseif type(dst.loss[k]) == "number" and type(v) == "number" and (wDst + wSrc) > 0 then
        dst.loss[k] = (wDst * dst.loss[k] + wSrc * v) / (wDst + wSrc)
      end
    end
  end

  if type(dst.meta) == "table" and type(src.meta) == "table" then
    dst.meta.lastSeen = math.max(tonumber(dst.meta.lastSeen) or 0, tonumber(src.meta.lastSeen) or 0)
  end
end

local function ensureActorModelWithDisplay(actorKey, displayName)
  if not actorKey or actorKey == "" then return nil end
  local map = DiceTrackerDB and DiceTrackerDB.actors and DiceTrackerDB.actors.map
  if type(map) ~= "table" then
    ensureActorModel(actorKey)
    map = DiceTrackerDB.actors.map
  end

  if displayName and displayName ~= "" and map[displayName] and not map[actorKey] then
    map[actorKey] = ensureModelTables(map[displayName])
    map[displayName] = nil
  elseif displayName and displayName ~= "" and map[displayName] and map[actorKey] then
    mergeModels(map[actorKey], map[displayName])
    map[displayName] = nil
  end

  local m = ensureActorModel(actorKey)
  if m and displayName and displayName ~= "" then
    m.meta.displayName = displayName
  end
  return m
end

local function fixLocalActorKey(attempt)
  attempt = attempt or 0
  if attempt > 8 then return end
  if not DiceTrackerDB or not DiceTrackerDB.actors or not DiceTrackerDB.actors.map then return end

  local selfName = selfActorName()
  local selfGuid = selfActorKey()
  local selfBase = UnitName and UnitName("player") or nil
  if type(selfName) ~= "string" or selfName == "" or type(selfBase) ~= "string" or selfBase == "" then
    if C_Timer and C_Timer.After then
      C_Timer.After(1.0, function() fixLocalActorKey(attempt + 1) end)
    end
    return
  end

  -- Wait until realm is available (name-realm); otherwise we might canonicalize too early.
  if not selfName:find("-", 1, true) then
    if C_Timer and C_Timer.After then
      C_Timer.After(1.0, function() fixLocalActorKey(attempt + 1) end)
    end
    return
  end

  local map = DiceTrackerDB.actors.map
  local mBase = map[selfBase]
  local mName = map[selfName]
  local mGuid = map[selfGuid]

  if mBase and not mName then
    map[selfName] = ensureModelTables(mBase)
    map[selfBase] = nil
  elseif mBase and mName then
    mName = ensureModelTables(mName)
    mergeModels(mName, mBase)
    map[selfName] = mName
    map[selfBase] = nil
  end

  if selfGuid and selfGuid ~= "" then
    if mName and not mGuid then
      map[selfGuid] = ensureModelTables(mName)
      map[selfName] = nil
    elseif mName and mGuid then
      mGuid = ensureModelTables(mGuid)
      mergeModels(mGuid, mName)
      map[selfGuid] = mGuid
      map[selfName] = nil
    end
    if map[selfGuid] and type(map[selfGuid].meta) == "table" then
      map[selfGuid].meta.displayName = selfName
    end
  elseif mName and type(mName.meta) == "table" then
    mName.meta.displayName = selfName
  end

  -- If the user had selected the base name explicitly, preserve intent by updating to full key.
  if DiceTrackerDB.settings and type(DiceTrackerDB.settings.target) == "table"
      and DiceTrackerDB.settings.target.mode == "actor"
      and DiceTrackerDB.settings.target.actor == selfBase then
    DiceTrackerDB.settings.target.actor = selfGuid or selfName
  end
end

-- -----------------------------
-- Prediction APIs
-- -----------------------------
local function computeModelDisplayedPrediction(model)
  model = ensureModelTables(model)
  local expertProbs = gatherExpertProbs(model)

  local weights, bestAdv = computeWeightsVsAnchor(model, expertProbs)
  model.weights = model.weights or {}
  for k, w in pairs(weights) do
    model.weights[k] = w
  end
  local mixed = mixExperts(weights, expertProbs)
  local displayed, gate = anchorGate(model, mixed, bestAdv)

  return displayed, {
    expertProbs = expertProbs,
    weights = weights,
    bestAdv = bestAdv,
    gate = gate,
    mass = tonumber(model.bucket.total) or 0,
  }
end

local function computeActorCombinedPrediction(actorKey)
  local globalP, globalMeta = computeModelDisplayedPrediction(DiceTrackerDB.global)

  if not actorKey or actorKey == "GLOBAL" then
    return globalP, {
      mode = "global",
      global = globalMeta,
      actor = nil,
      combinedGate = 0,
    }
  end

  local map = DiceTrackerDB and DiceTrackerDB.actors and DiceTrackerDB.actors.map
  local actorModel = (type(map) == "table") and map[actorKey] or nil
  if not actorModel then
    return globalP, {
      mode = "global-unseen",
      global = globalMeta,
      actor = nil,
      combinedGate = 0,
    }
  end

  actorModel = ensureModelTables(actorModel)
  local actorP, actorMeta = computeModelDisplayedPrediction(actorModel)

  -- Compare on actor stream using stored EWMA losses inside actorModel
  local lg = actorModel.loss.globalDisplayed
  local la = actorModel.loss.actorDisplayed
  local adv = 0
  if lg ~= nil and la ~= nil then
    adv = lg - la -- positive means actor beats global on actor stream
  end

  local nA = tonumber(actorModel.bucket.total) or 0
  local massFactor = clamp((nA - ACTOR_MASS0) / (ACTOR_MASS1 - ACTOR_MASS0), 0, 1)
  local advFactor = clamp((adv - ACTOR_ADV0) / (ACTOR_ADV1 - ACTOR_ADV0), 0, 1)
  local s = massFactor * advFactor

  local combined = {
    low = (1 - s) * globalP.low + s * actorP.low,
    seven = (1 - s) * globalP.seven + s * actorP.seven,
    high = (1 - s) * globalP.high + s * actorP.high,
  }
  combined = clampAndRenorm(combined)

  return combined, {
    mode = "actor",
    global = globalMeta,
    actor = actorMeta,
    combinedGate = s,
    actorAdv = adv,
  }
end

local function recommendationFromProbs(p)
  local vL = tonumber(p.low) or 0
  local vH = tonumber(p.high) or 0
  local v7 = tonumber(p.seven) or 0

  -- Deterministic tie-break: Low > High > Seven
  local bestK, bestV = "low", vL
  if vH > bestV or (vH == bestV and bestK ~= "low") then
    bestK, bestV = "high", vH
  end
  if v7 > bestV then
    bestK, bestV = "seven", v7
  end
  return bestK
end

-- -----------------------------
-- Pending pairing helpers
-- -----------------------------
local function resolvePendingKey(rollActor)
  local directMatch = nil
  local directCount = 0
  for k, entry in pairs(RT.pending) do
    if entry and entry.actorName == rollActor then
      directMatch = k
      directCount = directCount + 1
    end
  end
  if directCount == 1 then
    return directMatch, nil
  elseif directCount > 1 then
    return nil, "roll_actor_ambiguous"
  end
  return nil, nil
end

local function expirePending(actorKey, token)
  local entry = RT.pending[actorKey]
  if not entry then return end
  if entry.expireToken ~= token then return end
  RT.pending[actorKey] = nil
  bumpDrop("pending_timeout")
  DiceTracker.UpdateUI()
end

local function openPendingToss(actorKeyPrimary, actorName, lineID, guid)
  local now = safeNow()
  if not actorKeyPrimary or actorKeyPrimary == "" then return end
  if not actorName or actorName == "" then return end

  if RT.pending[actorKeyPrimary] then
    RT.pending[actorKeyPrimary] = nil
    bumpDrop("pending_overwritten")
  end
  -- If the same actor (by canonical name) already has a pending session under a different key,
  -- replace it conservatively to avoid multiple concurrent sessions for one actor.
  local removeKeys = nil
  for k, entry in pairs(RT.pending) do
    if entry and entry.actorName == actorName and k ~= actorKeyPrimary then
      removeKeys = removeKeys or {}
      removeKeys[#removeKeys + 1] = k
    end
  end
  if removeKeys then
    for _, k in ipairs(removeKeys) do
      RT.pending[k] = nil
      bumpDrop("pending_overwritten")
    end
  end

  local token = now + math.random() -- token to avoid stale timer clears
  RT.pending[actorKeyPrimary] = {
    actorKeyPrimary = actorKeyPrimary,
    actorName = actorName,
    t0 = now,
    expireAt = now + MAX_WAIT_SECONDS,
    rolls = {},
    tossLineID = lineID,
    tossGuid = guid,
    expireToken = token,
  }

  if C_Timer and C_Timer.After then
    C_Timer.After(MAX_WAIT_SECONDS + 0.1, function()
      expirePending(actorKeyPrimary, token)
    end)
  end
end

-- -----------------------------
-- Finalization (score-before-learn)
-- -----------------------------
local function finalizeSample(actorKey, actorName, die1, die2)
  local sum = die1 + die2
  local bucket = bucketFromSum(sum)
  if not bucket then
    bumpDrop("invalid_sum")
    return
  end

  local db = DiceTrackerDB
  if not db then return end

  local globalModel = db.global
  local actorModel = ensureActorModelWithDisplay(actorKey, actorName)

  -- Compute predictions pre-learn
  local globalP, globalMeta = computeModelDisplayedPrediction(globalModel)
  local actorP, actorMeta = computeModelDisplayedPrediction(actorModel)

  -- Combined (actor vs global shrink gate)
  local combinedP, combinedMeta = computeActorCombinedPrediction(actorKey)

  -- Score-before-learn: update losses on correct streams
  -- Global stream: anchor + each expert + displayed(global)
  local globalExperts = globalMeta.expertProbs
  updateLossesPrequential(globalModel, bucket, globalExperts, globalP)

  -- Actor stream: anchor + each expert + actorDisplayed; also store globalDisplayed and combinedDisplayed on actor stream
  local actorExperts = actorMeta.expertProbs
  updateLossesPrequential(actorModel, bucket, actorExperts, actorP)

  actorModel.loss.globalDisplayed = ewmaUpdate(actorModel.loss.globalDisplayed, nllForBucket(globalP, bucket), LOSS_RHO)
  actorModel.loss.actorDisplayed = ewmaUpdate(actorModel.loss.actorDisplayed, nllForBucket(actorP, bucket), LOSS_RHO)
  actorModel.loss.combinedDisplayed = ewmaUpdate(actorModel.loss.combinedDisplayed, nllForBucket(combinedP, bucket), LOSS_RHO)

  -- Learn (update sufficient statistics)
  updateModelWithSample(globalModel, bucket, die1, die2)
  updateModelWithSample(actorModel, bucket, die1, die2)

  -- Store last sample summary (bounded)
  db.lastSample = {
    when = time and time() or 0,
    actor = actorKey,
    actorName = actorName,
    die1 = die1,
    die2 = die2,
    sum = sum,
    bucket = bucket,
    gates = {
      mode = combinedMeta.mode,
      combinedGate = combinedMeta.combinedGate,
      actorAdv = combinedMeta.actorAdv,
      global = {
        gate = globalMeta.gate,
        bestAdv = globalMeta.bestAdv,
        mass = globalMeta.mass,
      },
      actor = {
        gate = actorMeta.gate,
        bestAdv = actorMeta.bestAdv,
        mass = actorMeta.mass,
      },
    },
  }

  RT.lastDebug.lastSample = shallowCopy(db.lastSample)

  DiceTracker.UpdateUI()
end

-- -----------------------------
-- Event handlers (capture / pairing)
-- -----------------------------
local function onTossEvent(event, msg, sender, lineID, guid, allowQueue)
  if allowQueue == nil then allowQueue = true end
  -- Prefilter: ignore unrelated emotes to keep drop counters meaningful.
  if type(msg) ~= "string" then return end
  local cleanedMsg = cleanMessage(msg)
  local hasAnyItemLink = msg:find("|Hitem:", 1, true) ~= nil

  -- Ensure itemName is populated if possible (helps when the toss line includes only the localized item name).
  if (not hasAnyItemLink) and (not RT.itemName or RT.itemName == "") then
    local name = getItemNameNow()
    if name and name ~= "" then
      RT.itemName = name
    else
      if allowQueue and cleanedMsg ~= "" then
        queueUnknownToss(event, msg, sender, lineID, guid)
      end
      if (not RT.selfTesting) and C_Timer and C_Timer.After then
        refreshItemName(0)
      end
      return
    end
  end

  local mentionsItemName = false
  if RT.itemName and RT.itemName ~= "" then
    mentionsItemName = cleanedMsg:lower():find(RT.itemName:lower(), 1, true) ~= nil
  end
  if not hasAnyItemLink and not mentionsItemName then
    return
  end

  if not isConfirmedTossMessage(msg) then
    bumpDrop("toss_not_confirmed")
    return
  end

  local actorName = sender and cleanMessage(sender) or nil
  actorName = normalizeWhitespace(stripColorAndTextures(actorName or ""))

  if not isValidActorName(actorName) then
    -- Only parse from the message if the sender is missing/empty (not provided by the event payload).
    if (not sender or sender == "") and type(msg) == "string" then
      local parsed = cleanMessage(msg):match("^([^%s]+)%s")
      if parsed and isValidActorName(parsed) then
        actorName = parsed
      end
    end
  end

  if not isValidActorName(actorName) then
    bumpDrop("toss_actor_ambiguous")
    return
  end

  actorName = canonicalizeActorName(actorName)
  if not isValidActorName(actorName) then
    bumpDrop("toss_actor_ambiguous")
    return
  end

  local actorKeyPrimary = stableActorKeyFromNameGuid(actorName, guid)

  -- Dedupe
  if lineID and dedupeLineID(lineID) then
    bumpDrop("dedupe_lineid")
    return
  end
  if not lineID then
    local key = tostring(event) .. "|" .. tostring(actorKeyPrimary or actorName) .. "|" .. tostring(cleanedMsg)
    if dedupeTTL(key) then
      bumpDrop("dedupe_ttl")
      return
    end
  end

  RT.lastConfirmedActor = actorName
  RT.lastConfirmedTime = safeNow()

  openPendingToss(actorKeyPrimary, actorName, lineID, guid)

  DiceTracker.UpdateUI()
end

local function onSystemEvent(msg, lineID)
  if type(msg) ~= "string" then return end
  local cleanedMsg = cleanMessage(msg)
  if not isPotentialRollMessage(cleanedMsg) then
    return
  end
  msg = cleanedMsg

  -- Dedupe
  if lineID and dedupeLineID(lineID) then
    bumpDrop("dedupe_lineid")
    return
  end

  local who, roll, minV, maxV = parseRollLine(msg)
  if not who or not roll or not minV or not maxV then
    bumpDrop("roll_parse_fail")
    return
  end

  if not lineID then
    local key = "SYS|" .. tostring(who) .. "|" .. tostring(msg)
    if dedupeTTL(key) then
      bumpDrop("dedupe_ttl")
      return
    end
  end

  who = normalizeWhitespace(stripColorAndTextures(who))
  who = canonicalizeActorName(who)
  if not isValidActorName(who) then
    bumpDrop("roll_actor_ambiguous")
    return
  end

  local key, pendingReason = resolvePendingKey(who)

  if minV ~= 1 or maxV ~= 6 or roll < 1 or roll > 6 or roll ~= math.floor(roll) then
    if key then
      RT.pending[key] = nil
      bumpDrop("pending_invalid_range")
    else
      bumpDrop("roll_not_d6")
    end
    return
  end
  if not key then
    bumpDrop(pendingReason or "roll_no_pending")
    return
  end

  local entry = RT.pending[key]
  if not entry then
    bumpDrop("roll_no_pending")
    return
  end

  if (safeNow() - (entry.t0 or 0)) > MAX_WAIT_SECONDS then
    RT.pending[key] = nil
    bumpDrop("pending_timeout")
    return
  end
  if entry.expireAt and safeNow() > entry.expireAt then
    RT.pending[key] = nil
    bumpDrop("pending_timeout")
    return
  end

  local rolls = entry.rolls
  rolls[#rolls + 1] = roll

  if #rolls == 2 then
    RT.pending[key] = nil
    finalizeSample(entry.actorKeyPrimary or entry.actorName or key, entry.actorName or entry.actorKeyPrimary or key, rolls[1], rolls[2])
  elseif #rolls > 2 then
    RT.pending[key] = nil
    bumpDrop("pending_overflow")
  end
end

-- -----------------------------
-- UI
-- -----------------------------
local ui = {}
DiceTracker.ui = ui

local function setFramePosition(frame)
  local u = DiceTrackerDB and DiceTrackerDB.ui
  if not u then return end
  frame:ClearAllPoints()
  frame:SetPoint(u.point or "CENTER", UIParent, u.relPoint or "CENTER", u.x or 0, u.y or 0)
  if frame.SetScale then frame:SetScale(u.scale or 1) end
end

local function persistFramePosition(frame)
  local u = DiceTrackerDB and DiceTrackerDB.ui
  if not u then return end
  local point, _, relPoint, x, y = frame:GetPoint(1)
  u.point = point
  u.relPoint = relPoint
  u.x = x
  u.y = y
end

local function computeEffectiveTarget()
  local db = DiceTrackerDB
  if not db then return selfActorKey(), "me" end

  local t = db.settings.target
  local mode = t and t.mode or "auto"
  if mode == "global" then
    return "GLOBAL", "global"
  end
  if mode == "me" then
    return selfActorKey(), "me"
  end
  if mode == "actor" and t.actor and t.actor ~= "" then
    return t.actor, "actor"
  end

  -- auto
  local targetKey = targetActorKey()
  if targetKey then
    return targetKey, "auto-target"
  end
  return "GLOBAL", "auto-global"
end

local function displayNameForActorKey(actorKey)
  if not actorKey or actorKey == "" then return "?" end
  if actorKey == "GLOBAL" then return "Global" end
  if actorKey == selfActorKey() then
    return selfActorName()
  end
  if UnitGUID and UnitFullName and UnitExists and UnitIsPlayer then
    if UnitExists("target") and UnitIsPlayer("target") and UnitGUID("target") == actorKey then
      local tn, tr = UnitFullName("target")
      if tn and tn ~= "" then
        if tr and tr ~= "" then
          return tn .. "-" .. tr
        end
        return tn
      end
    end
  end
  if not isGuidKey(actorKey) then return actorKey end
  local m = DiceTrackerDB and DiceTrackerDB.actors and DiceTrackerDB.actors.map and DiceTrackerDB.actors.map[actorKey]
  if m and m.meta and type(m.meta.displayName) == "string" and m.meta.displayName ~= "" then
    return m.meta.displayName
  end
  return actorKey
end

local function selectionText()
  local db = DiceTrackerDB
  if not db then return "Auto" end
  local t = db.settings.target
  local mode = t and t.mode or "auto"
  if mode == "auto" then return "Auto" end
  if mode == "me" then return "Me" end
  if mode == "global" then return "Global" end
  if mode == "actor" and t.actor then return displayNameForActorKey(t.actor) end
  return "Auto"
end

local function trackedActors()
  local out = {}
  local map = DiceTrackerDB and DiceTrackerDB.actors and DiceTrackerDB.actors.map
  if type(map) == "table" then
    for k, model in pairs(map) do
      if k and k ~= "" then
        local label = displayNameForActorKey(k)
        if model and model.meta and type(model.meta.displayName) == "string" and model.meta.displayName ~= "" then
          label = model.meta.displayName
        end
        out[#out + 1] = { key = k, label = label }
      end
    end
  end
  table.sort(out, function(a, b)
    return tostring(a.label) < tostring(b.label)
  end)
  return out
end

local function dropdownInit(self, level)
  local info = UIDropDownMenu_CreateInfo()
  info.func = function(btn)
    local v = btn.value
    if not DiceTrackerDB then return end
    if v == "auto" then
      DiceTrackerDB.settings.target.mode = "auto"
      DiceTrackerDB.settings.target.actor = nil
    elseif v == "me" then
      DiceTrackerDB.settings.target.mode = "me"
      DiceTrackerDB.settings.target.actor = nil
    elseif v == "global" then
      DiceTrackerDB.settings.target.mode = "global"
      DiceTrackerDB.settings.target.actor = nil
    else
      DiceTrackerDB.settings.target.mode = "actor"
      DiceTrackerDB.settings.target.actor = v
    end
    DiceTracker.UpdateUI()
  end

  info.text, info.value = "Auto", "auto"
  UIDropDownMenu_AddButton(info, level)

  info.text, info.value = "Me", "me"
  UIDropDownMenu_AddButton(info, level)

  info.text, info.value = "Global", "global"
  UIDropDownMenu_AddButton(info, level)

  local actors = trackedActors()
  if #actors > 0 then
    info.disabled = true
    info.notCheckable = true
    info.text = "— Tracked —"
    UIDropDownMenu_AddButton(info, level)
    info.disabled = false
    info.notCheckable = false
    for _, a in ipairs(actors) do
      info.text, info.value = a.label, a.key
      UIDropDownMenu_AddButton(info, level)
    end
  end
end

local function createUI()
  if ui.frame then return end

  local f = CreateFrame("Frame", "DiceTrackerFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  ui.frame = f

  f:SetSize(320, 140)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")

  f:SetScript("OnDragStart", function(self)
    self:StartMoving()
  end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    persistFramePosition(self)
  end)

  if f.SetBackdrop then
    f:SetBackdrop({
      bgFile = "Interface/Tooltips/UI-Tooltip-Background",
      edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    f:SetBackdropColor(0, 0, 0, 0.70)
  else
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(true)
    bg:SetColorTexture(0, 0, 0, 0.70)
    ui.bg = bg
  end

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 12, -10)
  title:SetText("DiceTracker")
  ui.title = title

  local dd = CreateFrame("Frame", nil, f, "UIDropDownMenuTemplate")
  dd:SetPoint("TOPLEFT", f, "TOPLEFT", -8, -28)
  UIDropDownMenu_SetWidth(dd, 160)
  UIDropDownMenu_Initialize(dd, dropdownInit)
  ui.dropdown = dd

  local target = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  target:SetPoint("TOPLEFT", 12, -62)
  target:SetText("Next: -")
  ui.target = target

  local rec = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  rec:SetPoint("TOPLEFT", 12, -82)
  rec:SetText("Recommend: -")
  ui.recommend = rec

  local probs = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  probs:SetPoint("TOPLEFT", 12, -110)
  probs:SetText("Low: -   Seven: -   High: -")
  ui.probs = probs

  local btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  btn:SetSize(90, 22)
  btn:SetPoint("BOTTOMLEFT", 10, 10)
  btn:SetText("Self-Test")
  btn:SetScript("OnClick", function()
    DiceTracker.RunSelfTest()
  end)
  ui.selfTestButton = btn

  local dbg = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  dbg:SetPoint("BOTTOMRIGHT", -12, 12)
  dbg:SetText("")
  ui.status = dbg

  local debugText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  debugText:SetPoint("TOPLEFT", 12, -140)
  debugText:SetWidth(300)
  debugText:SetJustifyH("LEFT")
  debugText:SetJustifyV("TOP")
  debugText:SetText("")
  debugText:Hide()
  ui.debugText = debugText

  setFramePosition(f)
  f:Show()
end

local function formatDebugOverlay(targetKey, combinedMeta, combinedProbs)
  local db = DiceTrackerDB
  if not db then return "" end

  local ls = db.lastSample
  local line = {}
  local function formatSampleTime(ts)
    ts = tonumber(ts) or 0
    if ts <= 0 then return "-" end
    if date then
      return date("%Y-%m-%d %H:%M:%S", ts)
    end
    return tostring(ts)
  end

  if ls then
    line[#line + 1] = string.format("Last: %s  %d+%d=%d  %s  %s",
      tostring(ls.actorName or displayNameForActorKey(ls.actor) or "?"),
      tonumber(ls.die1) or 0,
      tonumber(ls.die2) or 0,
      tonumber(ls.sum) or 0,
      BUCKET_LABEL[ls.bucket] or tostring(ls.bucket),
      formatSampleTime(ls.when)
    )
  else
    line[#line + 1] = "Last: -"
  end

  local drops = db.drop and db.drop.reasons or {}
  local dropParts = {}
  local dropTotal = db.drop and tonumber(db.drop.total) or 0
  dropParts[#dropParts + 1] = "Drops: " .. tostring(dropTotal)
  -- show a few top reasons
  local reasons = {}
  for k, v in pairs(drops) do
    reasons[#reasons + 1] = { k = k, v = tonumber(v) or 0 }
  end
  table.sort(reasons, function(a, b) return a.v > b.v end)
  for i = 1, math.min(6, #reasons) do
    dropParts[#dropParts + 1] = string.format("%s=%d", reasons[i].k, reasons[i].v)
  end
  line[#line + 1] = table.concat(dropParts, "  ")

  local g = db.global
  local a = (targetKey and targetKey ~= "GLOBAL") and db.actors.map[targetKey] or nil
  local gMass = g and g.bucket and tonumber(g.bucket.total) or 0
  local aMass = a and a.bucket and tonumber(a.bucket.total) or 0
  line[#line + 1] = string.format("Mass: global=%d  actor=%d", gMass, aMass)

  local gLossA = g and g.loss and g.loss.anchor
  local gLossD = g and g.loss and g.loss.displayed
  local aLossA = a and a.loss and a.loss.anchor
  local aLossC = a and a.loss and a.loss.combinedDisplayed

  line[#line + 1] = string.format("EWMA NLL: global anchor=%.3f disp=%.3f  actor anchor=%.3f comb=%.3f",
    tonumber(gLossA) or 0, tonumber(gLossD) or 0,
    tonumber(aLossA) or 0, tonumber(aLossC) or 0
  )

  -- Expert weights / losses (global + actor if present)
  local function fmtWeights(meta, model, label)
    if not meta or not meta.weights or not model or not model.loss then return nil end
    local parts = { label .. ":" }
    local keys = { "E1", "E2", "E3" }
    for _, k in ipairs(keys) do
      local w = meta.weights[k]
      local l = model.loss[k]
      if w then
        parts[#parts + 1] = string.format("%s w=%.2f l=%.3f", k, w, tonumber(l) or 0)
      end
    end
    return table.concat(parts, "  ")
  end

  local gw = fmtWeights(combinedMeta.global, db.global, "Weights(global)")
  if gw then line[#line + 1] = gw end
  if targetKey and targetKey ~= "GLOBAL" then
    local am = db.actors.map[targetKey]
    local aw = fmtWeights(combinedMeta.actor, am, "Weights(actor)")
    if aw then line[#line + 1] = aw end
    line[#line + 1] = string.format("Actor shrink gate: %.2f  actorAdv: %.3f",
      tonumber(combinedMeta.combinedGate) or 0,
      tonumber(combinedMeta.actorAdv) or 0
    )
  end

  local function gateSummary(prefix, info)
    if type(info) ~= "table" then return end
    local gGate = info.global and info.global.gate
    local gAdv = info.global and info.global.bestAdv
    local gMass = info.global and info.global.mass
    local aGate = info.actor and info.actor.gate
    local aAdv = info.actor and info.actor.bestAdv
    local aMass = info.actor and info.actor.mass
    local parts = {
      prefix .. string.format(" mode=%s", tostring(info.mode or "?")),
      string.format("globalGate=%.2f adv=%.3f mass=%d", tonumber(gGate) or 0, tonumber(gAdv) or 0, tonumber(gMass) or 0),
    }
    if info.mode == "actor" then
      parts[#parts + 1] = string.format("actorGate=%.2f adv=%.3f mass=%d", tonumber(aGate) or 0, tonumber(aAdv) or 0, tonumber(aMass) or 0)
      parts[#parts + 1] = string.format("shrink=%.2f actorAdv=%.3f", tonumber(info.combinedGate) or 0, tonumber(info.actorAdv) or 0)
    end
    line[#line + 1] = table.concat(parts, "  ")
  end

  gateSummary("Now:", combinedMeta)
  if ls and type(ls.gates) == "table" then
    gateSummary("Last sample:", ls.gates)
  end

  -- Self-test status
  if RT.lastDebug.selfTest and RT.lastDebug.selfTest.ran then
    local ok = RT.lastDebug.selfTest.ok and "PASS" or "FAIL"
    line[#line + 1] = "Self-Test: " .. ok
    if not RT.lastDebug.selfTest.ok and RT.lastDebug.selfTest.details and RT.lastDebug.selfTest.details ~= "" then
      line[#line + 1] = RT.lastDebug.selfTest.details
    end
  end

  return table.concat(line, "\n")
end

function DiceTracker.UpdateUI()
  if not DiceTrackerDB then return end
  createUI()

  local db = DiceTrackerDB
  local f = ui.frame
  if not f then return end

  local targetKey, mode = computeEffectiveTarget()
  local displayTarget = displayNameForActorKey(targetKey)

  local probs, meta = computeActorCombinedPrediction(targetKey)
  probs = clampAndRenorm(probs)

  local perc = roundedPercentsTo100(probs)
  local rec = recommendationFromProbs(probs)

  UIDropDownMenu_SetText(ui.dropdown, selectionText())

  ui.target:SetText("Next: " .. tostring(displayTarget))
  ui.recommend:SetText("Recommend: " .. (BUCKET_LABEL[rec] or tostring(rec)))

  ui.probs:SetText(string.format("Low: %.1f%%   Seven: %.1f%%   High: %.1f%%",
    perc.low, perc.seven, perc.high
  ))

  -- Expand/hide debug overlay
  if db.settings.debugOverlay then
    ui.debugText:Show()
    ui.debugText:SetText(formatDebugOverlay(targetKey, meta, probs))
    f:SetHeight(360)
  else
    ui.debugText:Hide()
    f:SetHeight(140)
  end

  -- lightweight status
  local last = db.lastSample
  if last and last.bucket then
    ui.status:SetText(string.format("Last: %s", BUCKET_LABEL[last.bucket] or tostring(last.bucket)))
  else
    ui.status:SetText("")
  end
end

-- -----------------------------
-- Self-Test (GUI only)
-- -----------------------------
local function assertEq(name, a, b, failures)
  if a ~= b then
    failures[#failures + 1] = string.format("%s: expected %s got %s", name, tostring(b), tostring(a))
    return false
  end
  return true
end

local function assertNear(name, a, b, tol, failures)
  tol = tol or 1e-6
  if math.abs((a or 0) - (b or 0)) > tol then
    failures[#failures + 1] = string.format("%s: expected %.6f got %.6f", name, b or 0, a or 0)
    return false
  end
  return true
end

function DiceTracker.RunSelfTest()
  if not DiceTrackerDB then return end

  local failures = {}
  local function safeFormatRoll(fmt, ...)
    if type(fmt) ~= "string" then
      failures[#failures + 1] = "RANDOM_ROLL_RESULT format missing"
      return nil
    end
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok or type(msg) ~= "string" then
      failures[#failures + 1] = "RANDOM_ROLL_RESULT format failed"
      return nil
    end
    return msg
  end
  local function pendingByActorName(name)
    for _, entry in pairs(RT.pending) do
      if entry and entry.actorName == name then
        return entry
      end
    end
    return nil
  end

  -- Snapshot state so the self-test never contaminates learned data.
  local backupDB = deepCopy(DiceTrackerDB)
  local backupRuntime = {
    pending = deepCopy(RT.pending),
    lastConfirmedActor = RT.lastConfirmedActor,
    lastConfirmedTime = RT.lastConfirmedTime,
    lineIdSeen = deepCopy(RT.lineIdSeen),
    lineIdQueue = deepCopy(RT.lineIdQueue),
    ttlSeen = deepCopy(RT.ttlSeen),
    itemName = RT.itemName,
    selfTesting = RT.selfTesting,
    selfTestTargetKey = RT.selfTestTargetKey,
    selfTestSelfName = RT.selfTestSelfName,
    selfTestSelfGuid = RT.selfTestSelfGuid,
    pendingUnknownTosses = deepCopy(RT.pendingUnknownTosses),
  }

  -- Isolate runtime + DB
  RT.selfTesting = true
  RT.selfTestSelfName = "SelfTest-Me"
  RT.selfTestSelfGuid = "Player-SELFTEST-0001"
  RT.pending = {}
  RT.lastConfirmedActor = nil
  RT.lastConfirmedTime = 0
  RT.lineIdSeen = {}
  RT.lineIdQueue = {}
  RT.ttlSeen = {}
  RT.pendingUnknownTosses = {}

  DiceTrackerDB = migrateIfNeeded({})
  _G.DiceTrackerDB = DiceTrackerDB
  ensureActorModelWithDisplay(selfActorKey(), selfActorName())

  -- 0b) Unseen actor should not allocate a model (UI should fall back to global)
  local unseenKey = "Player-UNSEEN-0003"
  local _, unseenMeta = computeActorCombinedPrediction(unseenKey)
  assertEq("unseen_actor_no_create", (DiceTrackerDB.actors.map and DiceTrackerDB.actors.map[unseenKey]) == nil, true, failures)
  assertEq("unseen_actor_mode", unseenMeta and unseenMeta.mode or "?", "global-unseen", failures)

  -- 0) Auto-target behavior (target player vs global)
  DiceTrackerDB.settings.target.mode = "auto"
  RT.selfTestTargetKey = "Player-SELFTESTTARGET-0002"
  local autoKey = computeEffectiveTarget()
  assertEq("auto_target_key", autoKey, "Player-SELFTESTTARGET-0002", failures)
  RT.selfTestTargetKey = nil
  local autoGlobalKey = computeEffectiveTarget()
  assertEq("auto_target_global", autoGlobalKey, "GLOBAL", failures)

  -- 1) Toss confirmation via hyperlink
  local actor = "SelfTest-A"
  local itemLink = "|cffffffff|Hitem:" .. ITEM_ID .. ":0:0:0:0:0:0:0:0|h[Worn Troll Dice]|h|r"
  local emoteMsg = actor .. " casually tosses " .. itemLink .. "."
  onTossEvent("CHAT_MSG_TEXT_EMOTE", emoteMsg, actor, 90001, "Player-TEST1")
  assertEq("pending_opened_hyperlink", pendingByActorName(actor) ~= nil, true, failures)
  assertEq("auto_target_recent", RT.lastConfirmedActor, actor, failures)
  local pendingA = pendingByActorName(actor)
  if pendingA then
    assertEq("pending_has_expire", pendingA.expireAt ~= nil, true, failures)
    assertEq("pending_expire_future", pendingA.expireAt >= (pendingA.t0 or 0), true, failures)
  end

  -- 1a) Empty sender should parse actor name from the message.
  local actorEmpty = "SelfTest-Empty"
  local emoteMsgEmpty = actorEmpty .. " casually tosses " .. itemLink .. "."
  onTossEvent("CHAT_MSG_TEXT_EMOTE", emoteMsgEmpty, "", 900010, "Player-TESTEMPTY")
  assertEq("pending_opened_empty_sender", pendingByActorName(actorEmpty) ~= nil, true, failures)

  -- 1b) Toss confirmation via item name fallback (deterministic GetItemInfo delay)
  local keepName = RT.itemName
  RT.itemName = nil
  RT.selfTestItemNameGate = { remaining = 1, name = "Worn Troll Dice" }

  local actorB = "SelfTest-B"
  local emoteMsgB = actorB .. " casually tosses [" .. "Worn Troll Dice" .. "]."
  onTossEvent("CHAT_MSG_TEXT_EMOTE", emoteMsgB, actorB, 90002, "Player-TEST2")
  assertEq("pending_not_opened_before_name", pendingByActorName(actorB) == nil, true, failures)

  processPendingUnknownTosses()
  assertEq("pending_still_nil_before_gate", pendingByActorName(actorB) == nil, true, failures)

  processPendingUnknownTosses()
  assertEq("item_name_set_after_gate", RT.itemName, "Worn Troll Dice", failures)
  assertEq("pending_opened_name_fallback", pendingByActorName(actorB) ~= nil, true, failures)

  -- 1b2) Toss confirmation via item name fallback without brackets (queued while name unavailable)
  RT.itemName = nil
  RT.selfTestItemNameGate = { remaining = 1, name = "Worn Troll Dice" }
  local actorC = "SelfTest-C"
  local emoteMsgC = actorC .. " casually tosses Worn Troll Dice."
  onTossEvent("CHAT_MSG_TEXT_EMOTE", emoteMsgC, actorC, 900025, "Player-TEST3")
  assertEq("pending_not_opened_before_name_unbracketed", pendingByActorName(actorC) == nil, true, failures)

  processPendingUnknownTosses()
  assertEq("pending_still_nil_before_gate_unbracketed", pendingByActorName(actorC) == nil, true, failures)

  processPendingUnknownTosses()
  assertEq("item_name_set_after_gate_unbracketed", RT.itemName, "Worn Troll Dice", failures)
  assertEq("pending_opened_name_fallback_unbracketed", pendingByActorName(actorC) ~= nil, true, failures)

  -- 1b3) Item name fallback should be case-insensitive in cleaned messages.
  local actorC2 = "SelfTest-C2"
  local emoteMsgC2 = actorC2 .. " casually tosses worn troll dice."
  onTossEvent("CHAT_MSG_TEXT_EMOTE", emoteMsgC2, actorC2, 9000261, "Player-TEST3B")
  assertEq("pending_opened_name_fallback_case_insensitive", pendingByActorName(actorC2) ~= nil, true, failures)
  -- 1c) Toss line that starts with localized "You" and has no sender must map deterministically to the local player
  local youWord = (_G and type(_G.YOU) == "string") and _G.YOU or "You"
  local selfKey = selfActorKey()
  local selfName = selfActorName()
  local emoteMsgYou = youWord .. " casually tosses " .. itemLink .. "."
  onTossEvent("CHAT_MSG_TEXT_EMOTE", emoteMsgYou, nil, 900021, "Player-SELFTESTYOU")
  assertEq("pending_opened_you_no_sender", pendingByActorName(selfName) ~= nil, true, failures)

  -- Feed one localized self roll line (if we can format it) and verify pairing sticks to selfKey without finalizing.
  if type(_G.RANDOM_ROLL_RESULT_SELF) == "string" then
    local okFmtY, selfMsgY = pcall(string.format, _G.RANDOM_ROLL_RESULT_SELF, 2, 1, 6)
    if okFmtY and type(selfMsgY) == "string" then
      onSystemEvent(selfMsgY, 900022)
      local pendingSelf = pendingByActorName(selfName)
      assertEq("pending_one_die_you", (pendingSelf and pendingSelf.rolls and #pendingSelf.rolls == 1), true, failures)
    end
  end

  -- 1d) Duplicate toss for same actor name under a different key should replace pending session.
  local actorD = "SelfTest-D"
  local emoteMsgD = actorD .. " casually tosses " .. itemLink .. "."
  local beforeOverwrite = DiceTrackerDB.drop.total
  onTossEvent("CHAT_MSG_TEXT_EMOTE", emoteMsgD, actorD, 900026, "Player-TESTD")
  assertEq("pending_opened_first_key", pendingByActorName(actorD) ~= nil, true, failures)
  onTossEvent("CHAT_MSG_TEXT_EMOTE", emoteMsgD, actorD, 900027, nil)
  assertEq("pending_replaced_same_actor", pendingByActorName(actorD) ~= nil, true, failures)
  assertEq("pending_replaced_drop_increment", DiceTrackerDB.drop.total, beforeOverwrite + 1, failures)

  for k, entry in pairs(RT.pending) do
    if entry and entry.actorName == selfName then
      RT.pending[k] = nil
    end
  end

  for k, entry in pairs(RT.pending) do
    if entry and entry.actorName == actorB then
      RT.pending[k] = nil
    end
  end
  for k, entry in pairs(RT.pending) do
    if entry and entry.actorName == actorC then
      RT.pending[k] = nil
    end
  end
  for k, entry in pairs(RT.pending) do
    if entry and entry.actorName == actorC2 then
      RT.pending[k] = nil
    end
  end
  for k, entry in pairs(RT.pending) do
    if entry and entry.actorName == actorD then
      RT.pending[k] = nil
    end
  end
  for k, entry in pairs(RT.pending) do
    if entry and entry.actorName == actorEmpty then
      RT.pending[k] = nil
    end
  end
  RT.selfTestItemNameGate = nil
  RT.itemName = keepName

  -- 2) Roll parsing + pairing: two d6 rolls should finalize exactly one sample
  local rollMsg1 = safeFormatRoll(_G.RANDOM_ROLL_RESULT, actor, 1, 1, 6)
  local rollMsg2 = safeFormatRoll(_G.RANDOM_ROLL_RESULT, actor, 1, 1, 6)
  if rollMsg1 and rollMsg2 then
    onSystemEvent(rollMsg1, 90003)
    onSystemEvent(rollMsg2, 90004)
  end

  assertEq("pending_cleared_after_two", pendingByActorName(actor) == nil, true, failures)
  assertEq("lastSample_bucket_low", DiceTrackerDB.lastSample and DiceTrackerDB.lastSample.bucket, "low", failures)

  -- 2b) Fallback roll parsing with dash glyph: must still require (1–6)
  local dashMsg = actor .. " rolls 4 (1–6)"
  local whoF, rollF, minF, maxF = parseRollLine(dashMsg)
  assertEq("fallback_dash_who", whoF, actor, failures)
  assertEq("fallback_dash_roll", rollF, 4, failures)
  assertEq("fallback_dash_range", (minF == 1 and maxF == 6), true, failures)

  -- 2c) Self roll localized parsing (if format supports numeric formatting)
  if type(_G.RANDOM_ROLL_RESULT_SELF) == "string" then
    local okFmt, selfMsg = pcall(string.format, _G.RANDOM_ROLL_RESULT_SELF, 3, 1, 6)
    if okFmt and type(selfMsg) == "string" then
      local whoS, rollS, minS, maxS = parseRollLine(selfMsg)
      assertEq("self_roll_actor", whoS, selfActorName(), failures)
      assertEq("self_roll_value", rollS, 3, failures)
      assertEq("self_roll_range", (minS == 1 and maxS == 6), true, failures)
    end
  end

  -- 2d) Fallback "You rolls" parsing should map to the local player
  local youWord = (_G and type(_G.YOU) == "string") and _G.YOU or "You"
  local selfKey2 = selfActorKey()
  local selfName2 = selfActorName()
  openPendingToss("Player-SELFROLL", selfName2, 900023, "Player-SELFROLL")
  local beforeYouFallback = pendingByActorName(selfName2)
  assertEq("pending_self_before_you_fallback", beforeYouFallback ~= nil, true, failures)
  onSystemEvent(youWord .. " rolls 4 (1-6)", 900024)
  local pendingSelfAfter = pendingByActorName(selfName2)
  assertEq("pending_self_one_die_fallback", (pendingSelfAfter and pendingSelfAfter.rolls and #pendingSelfAfter.rolls == 1), true, failures)
  for k, entry in pairs(RT.pending) do
    if entry and entry.actorName == selfName2 then
      RT.pending[k] = nil
    end
  end

  -- 3) Roll without pending must be dropped
  local beforeDrops = DiceTrackerDB.drop.total
  local strayMsg = safeFormatRoll(_G.RANDOM_ROLL_RESULT, "SomeoneElse", 2, 1, 6)
  if strayMsg then
    onSystemEvent(strayMsg, 90005)
  end
  assertEq("drop_increment_roll_no_pending", DiceTrackerDB.drop.total, beforeDrops + 1, failures)

  -- 3a) Non-roll system messages should be ignored (no drop)
  local beforeNonRoll = DiceTrackerDB.drop.total
  onSystemEvent("You have unlearned a spell.", 900050)
  assertEq("non_roll_no_drop", DiceTrackerDB.drop.total, beforeNonRoll, failures)

  -- 3b) Ambiguous baseName pairing must drop and not consume any pending sessions
  openPendingToss("Player-DUPA", "Dup-RealmA", 90006, "Player-DUPA")
  openPendingToss("Player-DUPB", "Dup-RealmB", 90007, "Player-DUPB")
  local beforeAmbig = DiceTrackerDB.drop.total
  local beforeAmbigReason = (DiceTrackerDB.drop.reasons and DiceTrackerDB.drop.reasons.roll_actor_ambiguous) or 0
  onSystemEvent("Dup rolls 3 (1-6)", 90008)
  assertEq("ambig_pending_keptA", pendingByActorName("Dup-RealmA") ~= nil, true, failures)
  assertEq("ambig_pending_keptB", pendingByActorName("Dup-RealmB") ~= nil, true, failures)
  assertEq("ambig_drop_increment", DiceTrackerDB.drop.total, beforeAmbig + 1, failures)
  assertEq("ambig_drop_reason", (DiceTrackerDB.drop.reasons and DiceTrackerDB.drop.reasons.roll_actor_ambiguous) or 0, beforeAmbigReason + 1, failures)
  for k, entry in pairs(RT.pending) do
    if entry and (entry.actorName == "Dup-RealmA" or entry.actorName == "Dup-RealmB") then
      RT.pending[k] = nil
    end
  end

  -- 3b2) Base-name roll must not match realm-qualified pending session
  openPendingToss("Player-REALM", "RealmActor-MyRealm", 900081, "Player-REALM")
  local beforeBaseName = DiceTrackerDB.drop.total
  onSystemEvent("RealmActor rolls 4 (1-6)", 900082)
  assertEq("basename_no_match_pending_kept", pendingByActorName("RealmActor-MyRealm") ~= nil, true, failures)
  assertEq("basename_no_match_drop_increment", DiceTrackerDB.drop.total, beforeBaseName + 1, failures)
  for k, entry in pairs(RT.pending) do
    if entry and entry.actorName == "RealmActor-MyRealm" then
      RT.pending[k] = nil
    end
  end

  -- 3c) Wrong actor roll does not consume pending
  openPendingToss("Player-WRONG", "RightActor", 90009, "Player-WRONG")
  local beforeWrong = DiceTrackerDB.drop.total
  local wrongMsg = safeFormatRoll(_G.RANDOM_ROLL_RESULT, "OtherActor", 3, 1, 6)
  if wrongMsg then
    onSystemEvent(wrongMsg, 90010)
  end
  assertEq("wrong_actor_drop", DiceTrackerDB.drop.total, beforeWrong + 1, failures)
  assertEq("wrong_actor_pending_kept", pendingByActorName("RightActor") ~= nil, true, failures)

  -- 3d) Only one roll then timeout should drop
  local pendingRight = pendingByActorName("RightActor")
  if pendingRight then
    local rightMsg1 = safeFormatRoll(_G.RANDOM_ROLL_RESULT, "RightActor", 4, 1, 6)
    if rightMsg1 then
      onSystemEvent(rightMsg1, 90011)
    end
    pendingRight.t0 = safeNow() - (MAX_WAIT_SECONDS + 1)
    local beforeTimeout = DiceTrackerDB.drop.total
    local rightMsg2 = safeFormatRoll(_G.RANDOM_ROLL_RESULT, "RightActor", 5, 1, 6)
    if rightMsg2 then
      onSystemEvent(rightMsg2, 90012)
    end
    assertEq("timeout_drop_increment", DiceTrackerDB.drop.total, beforeTimeout + 1, failures)
  end

  -- 3e) Three rolls should overflow and drop
  openPendingToss("Player-THREE", "TripleActor", 90013, "Player-THREE")
  local tripleMsg1 = safeFormatRoll(_G.RANDOM_ROLL_RESULT, "TripleActor", 1, 1, 6)
  local tripleMsg2 = safeFormatRoll(_G.RANDOM_ROLL_RESULT, "TripleActor", 2, 1, 6)
  if tripleMsg1 then
    onSystemEvent(tripleMsg1, 90014)
  end
  if tripleMsg2 then
    onSystemEvent(tripleMsg2, 90015)
  end
  local beforeOverflow = DiceTrackerDB.drop.total
  local tripleMsg3 = safeFormatRoll(_G.RANDOM_ROLL_RESULT, "TripleActor", 3, 1, 6)
  if tripleMsg3 then
    onSystemEvent(tripleMsg3, 90016)
  end
  assertEq("overflow_drop_increment", DiceTrackerDB.drop.total, beforeOverflow + 1, failures)
  assertEq("overflow_pending_cleared", pendingByActorName("TripleActor") == nil, true, failures)

  -- 3f) Wrong range should drop
  openPendingToss("Player-RANGE", "RangeActor", 90017, "Player-RANGE")
  local beforeRange = DiceTrackerDB.drop.total
  onSystemEvent("RangeActor rolls 6 (1-20)", 90018)
  assertEq("wrong_range_drop", DiceTrackerDB.drop.total, beforeRange + 1, failures)
  assertEq("wrong_range_pending_cleared", pendingByActorName("RangeActor") == nil, true, failures)

  -- 4) Probability normalization / rounding to 100.0
  local perc = roundedPercentsTo100({ low = 0.333333, seven = 0.333333, high = 0.333334 })
  local sum = perc.low + perc.seven + perc.high
  assertNear("rounded_sum_100", sum, 100.0, 0.0001, failures)

  -- 4b) Clamp + renormalize probabilities
  local clamped = clampAndRenorm({ low = 0, seven = 1, high = 0 })
  local clampSum = (clamped.low or 0) + (clamped.seven or 0) + (clamped.high or 0)
  assertNear("clamp_renorm_sum_1", clampSum, 1.0, 1e-6, failures)
  assertEq("clamp_low_min", (clamped.low or 0) >= EPS, true, failures)
  assertEq("clamp_high_min", (clamped.high or 0) >= EPS, true, failures)

  -- 5) Prequential score-before-learn sanity (anchor + E1 on the first sample)
  local expectedAnchorNLL = -math.log(FAIR_ANCHOR.low)
  assertNear("nll_anchor_low", DiceTrackerDB.global.loss.anchor, expectedAnchorNLL, 1e-6, failures)

  local expectedE1NLL = -math.log(1/3)
  assertNear("nll_E1_prelearn", DiceTrackerDB.global.loss.E1, expectedE1NLL, 1e-6, failures)

  -- 5b) Expert weights should be cached and normalized
  local w = DiceTrackerDB.global.weights or {}
  assertEq("weights_present", (type(w.E1) == "number" and type(w.E2) == "number" and type(w.E3) == "number"), true, failures)
  local wsum = (tonumber(w.E1) or 0) + (tonumber(w.E2) or 0) + (tonumber(w.E3) or 0)
  assertNear("weights_sum_1", wsum, 1.0, 1e-6, failures)

  -- Restore state
  DiceTrackerDB = backupDB
  _G.DiceTrackerDB = DiceTrackerDB

  RT.pending = backupRuntime.pending
  RT.lastConfirmedActor = backupRuntime.lastConfirmedActor
  RT.lastConfirmedTime = backupRuntime.lastConfirmedTime
  RT.lineIdSeen = backupRuntime.lineIdSeen
  RT.lineIdQueue = backupRuntime.lineIdQueue
  RT.ttlSeen = backupRuntime.ttlSeen
  RT.itemName = backupRuntime.itemName
  RT.selfTesting = backupRuntime.selfTesting
  RT.selfTestTargetKey = backupRuntime.selfTestTargetKey
  RT.selfTestSelfName = backupRuntime.selfTestSelfName
  RT.selfTestSelfGuid = backupRuntime.selfTestSelfGuid
  RT.pendingUnknownTosses = backupRuntime.pendingUnknownTosses

  RT.lastDebug.selfTest = RT.lastDebug.selfTest or {}
  RT.lastDebug.selfTest.ran = true
  RT.lastDebug.selfTest.ok = (#failures == 0)
  RT.lastDebug.selfTest.details = table.concat(failures, "\n")

  if (not RT.lastDebug.selfTest.ok) and DiceTrackerDB and DiceTrackerDB.settings then
    DiceTrackerDB.settings.debugOverlay = true
  end

  DiceTracker.UpdateUI()
end
-- -----------------------------
-- Settings UI (Retail Settings API)
-- -----------------------------
local function createSettingsPanel()
  if ui.settingsPanel then return end

  local panel = CreateFrame("Frame")
  ui.settingsPanel = panel

  local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText("DiceTracker")

  local debugCB = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  debugCB:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
  debugCB:SetChecked(DiceTrackerDB and DiceTrackerDB.settings and DiceTrackerDB.settings.debugOverlay == true)

  local debugLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  debugLbl:SetPoint("LEFT", debugCB, "RIGHT", 6, 0)
  debugLbl:SetText("Enable Debug Overlay")

  debugCB:SetScript("OnClick", function(self)
    if not DiceTrackerDB then return end
    DiceTrackerDB.settings.debugOverlay = (self:GetChecked() == true)
    DiceTracker.UpdateUI()
  end)
  ui.debugCB = debugCB

  local resetBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  resetBtn:SetSize(160, 24)
  resetBtn:SetPoint("TOPLEFT", debugCB, "BOTTOMLEFT", 0, -12)
  resetBtn:SetText("Reset Learned Data")
  resetBtn:SetScript("OnClick", function()
    if StaticPopup_Show then
      StaticPopup_Show("DICETRACKER_RESET_CONFIRM")
    end
  end)

  local selfTestBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  selfTestBtn:SetSize(160, 24)
  selfTestBtn:SetPoint("TOPLEFT", resetBtn, "BOTTOMLEFT", 0, -8)
  selfTestBtn:SetText("Run Self-Test")
  selfTestBtn:SetScript("OnClick", function()
    DiceTracker.RunSelfTest()
  end)

  local note = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  note:SetPoint("TOPLEFT", selfTestBtn, "BOTTOMLEFT", 0, -10)
  note:SetWidth(580)
  note:SetJustifyH("LEFT")
  note:SetText("Resets learned statistics (global + per-actor). UI settings and frame position are kept.")

  -- Register with Settings API when available
  if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
    local category = Settings.RegisterCanvasLayoutCategory(panel, "DiceTracker")
    Settings.RegisterAddOnCategory(category)
    ui.settingsCategory = category
  end
end

StaticPopupDialogs = StaticPopupDialogs or {}
StaticPopupDialogs["DICETRACKER_RESET_CONFIRM"] = {
  text = "Reset DiceTracker learned data?",
  button1 = YES,
  button2 = NO,
  OnAccept = function()
    if not DiceTrackerDB then return end
    -- Preserve settings + UI position; wipe only learned statistics.
    local keepSettings = deepCopy(DiceTrackerDB.settings or {})
    local keepUI = deepCopy(DiceTrackerDB.ui or {})
    local fresh = newDB()
    fresh.settings = keepSettings
    fresh.ui = keepUI
    -- Keep schema
    DiceTrackerDB = fresh
    _G.DiceTrackerDB = DiceTrackerDB

    ensureActorModelWithDisplay(selfActorKey(), selfActorName())
    DiceTracker.UpdateUI()
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

-- -----------------------------
-- Event wiring
-- -----------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGOUT")
f:RegisterEvent("CHAT_MSG_TEXT_EMOTE")
f:RegisterEvent("CHAT_MSG_EMOTE")
f:RegisterEvent("CHAT_MSG_SYSTEM")

f:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" then
    local name = ...
    if name ~= ADDON_NAME then return end

    DiceTrackerDB = migrateIfNeeded(_G.DiceTrackerDB)
    _G.DiceTrackerDB = DiceTrackerDB

    ensureActorModelWithDisplay(selfActorKey(), selfActorName())
    fixLocalActorKey(0)
    refreshItemName(0)

    createSettingsPanel()
    createUI()
    DiceTracker.UpdateUI()
    return
  end

  if not DiceTrackerDB then return end

  if event == "PLAYER_LOGOUT" then
    return
  end

  if event == "CHAT_MSG_TEXT_EMOTE" or event == "CHAT_MSG_EMOTE" then
    local msg, sender, _, _, _, _, _, _, _, _, lineID, guid = ...
    onTossEvent(event, msg, sender, lineID, guid)
    return
  end

  if event == "CHAT_MSG_SYSTEM" then
    local msg, _, _, _, _, _, _, _, _, _, lineID = ...
    onSystemEvent(msg, lineID)
    return
  end
end)
