-- Ядро: ловит победы над игроками Альянса и пишет их в летопись.
--
-- В WoW Forever (интерфейс Midnight) журнал боя COMBAT_LOG_EVENT_UNFILTERED аддонам закрыт,
-- а боевые числа — «secret values». Победу засекаем событием PARTY_KILL(attackerGUID, targetGUID),
-- сведения о жертве берём из GetPlayerInfoByGUID и из кэша юнитов (цель/наведение/неймплейты).
-- Всё, что может оказаться secret, проверяется через issecretvalue и тихо пропускается.
local ADDON, ns = ...
ns = ns or {}
local D, N, S = ns.Data, ns.Narrative, ns.Stats

local C = {}
ns.Core = C

local isSecret = issecretvalue or function() return false end
local SPELL_WINDOW = 10        -- сек: какие мои заклинания считать «последними перед победой»
local SPELL_KEEP = 3
local CACHE_MAX = 400

C.diag = { partyKills = 0, secret = 0, notPlayer = 0, friendly = 0, unknownFaction = 0, recorded = 0, cacheHits = 0, lastReason = "", events = {} }
C.cache = {}          -- guid → {level, faction, guild, seen}
C.cacheSize = 0
C.recentSpells = {}   -- {name, t}
C.streak = { count = 0, last = 0 }
C.seq = 0

local function safe(v) if v == nil or isSecret(v) then return nil end return v end

function C.heroKey()
  local name, realm = UnitName("player")
  realm = realm or (GetRealmName and GetRealmName()) or ""
  return (name or "?") .. "-" .. (realm or "")
end

function C.db()
  HordeChronicleDB = HordeChronicleDB or {}
  local db = HordeChronicleDB
  db.kills = db.kills or {}
  db.settings = db.settings or {}
  local s = db.settings
  if s.channel == nil then s.channel = "self" end          -- self | guild | group
  if s.announceAlly == nil then s.announceAlly = false end
  if s.toast == nil then s.toast = true end
  if s.sound == nil then s.sound = true end
  if s.screenshot == nil then s.screenshot = false end
  if s.recordAlly == nil then s.recordAlly = true end
  if s.tone == nil then s.tone = N.DEFAULT_TONE end     -- epic | mock | hard
  if s.hardInChat == nil then s.hardInChat = false end  -- 18+ в чат гильдии/группы
  return db
end

-- Кэш сведений о врагах, пока они видны как юниты
function C.remember(unit)
  if not UnitExists(unit) or not UnitIsPlayer(unit) then return end
  local guid = safe(UnitGUID(unit))
  if not guid then return end
  local e = C.cache[guid]
  if not e then
    if C.cacheSize >= CACHE_MAX then C.cache, C.cacheSize = {}, 0 end
    e = {}
    C.cache[guid] = e
    C.cacheSize = C.cacheSize + 1
  end
  e.level = safe(UnitLevel(unit)) or e.level
  e.faction = safe(UnitFactionGroup(unit)) or e.faction
  if GetGuildInfo then e.guild = safe((GetGuildInfo(unit))) or e.guild end
  e.seen = GetTime()
end

function C.noteSpell(spellID)
  spellID = safe(spellID)
  if not spellID then return end
  local name = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)) or (GetSpellInfo and GetSpellInfo(spellID))
  name = safe(name)
  if not name then return end
  table.insert(C.recentSpells, 1, { name = name, t = GetTime() })
  while #C.recentSpells > SPELL_KEEP do table.remove(C.recentSpells) end
end

local function lastSpells()
  local out, now, seen = {}, GetTime(), {}
  for _, s in ipairs(C.recentSpells) do
    if now - s.t <= SPELL_WINDOW and not seen[s.name] then out[#out + 1] = s.name; seen[s.name] = true end
  end
  return out
end

-- Имя союзника по GUID среди группы/рейда
function C.allyName(guid)
  local units = {}
  if IsInRaid and IsInRaid() then
    for i = 1, 40 do units[#units + 1] = "raid" .. i end
  else
    for i = 1, 4 do units[#units + 1] = "party" .. i end
  end
  for _, u in ipairs(units) do
    if UnitExists(u) and safe(UnitGUID(u)) == guid then return (UnitName(u)) end
  end
  return nil
end

function C.onPlayerDead() C.streak.count = 0 end

local function reject(reason, field)
  C.diag.lastReason = reason
  if field then C.diag[field] = C.diag[field] + 1 end
  return nil, reason
end

-- Главная точка: PARTY_KILL. Возвращает запись или nil и причину.
function C.onPartyKill(attackerGUID, targetGUID)
  C.diag.partyKills = C.diag.partyKills + 1
  if isSecret(attackerGUID) or isSecret(targetGUID) then return reject("скрыто (secret)", "secret") end
  if type(targetGUID) ~= "string" or not targetGUID:find("^Player%-") then return reject("не игрок", "notPlayer") end

  local myGUID = UnitGUID("player")
  local killer
  if attackerGUID == myGUID then
    killer = "me"
  else
    killer = "ally"
    if not C.db().settings.recordAlly then return reject("союзник: запись выключена") end
  end

  local _, classToken, _, raceToken, sex, name, realm = GetPlayerInfoByGUID(targetGUID)
  classToken, raceToken, sex, name, realm = safe(classToken), safe(raceToken), safe(sex), safe(name), safe(realm)
  if not name then return reject("нет сведений о жертве", "secret") end

  local cached = C.cache[targetGUID]
  if cached then C.diag.cacheHits = C.diag.cacheHits + 1 end
  local myFaction = UnitFactionGroup("player")
  local faction = cached and cached.faction
  if not faction and raceToken then
    if D.ALLIANCE_RACES[raceToken] then faction = "Alliance" elseif D.HORDE_RACES[raceToken] then faction = "Horde" end
  end
  if not faction then return reject("фракция неизвестна", "unknownFaction") end
  if faction == myFaction then return reject("своя фракция", "friendly") end

  local db = C.db()
  local hero = C.heroKey()
  local now = GetTime()
  if killer == "me" then
    -- серия — мои победы подряд без смерти (PLAYER_DEAD сбрасывает)
    C.streak.count = C.streak.count + 1
    C.streak.last = now
  end

  C.seq = C.seq + 1
  local ts = time()
  local rec = {
    id = hero .. ":" .. ts .. ":" .. C.seq,
    hero = hero,
    ts = ts,
    date = date("%d.%m.%Y %H:%M", ts),
    hour = tonumber(date("%H", ts)),
    killer = killer,
    allyName = killer == "ally" and C.allyName(attackerGUID) or nil,
    victim = {
      name = name, realm = realm or "", class = classToken, race = raceToken, sex = sex,
      level = cached and cached.level or nil, guild = cached and cached.guild or nil,
    },
    myLevel = safe(UnitLevel("player")),
    mySex = safe(UnitSex("player")),
    zone = safe(GetRealZoneText and GetRealZoneText() or GetZoneText()) or "",
    subzone = safe(GetSubZoneText()) or "",
    spells = killer == "me" and lastSpells() or {},
    streak = killer == "me" and C.streak.count or 0,
  }
  rec.meet = S.timesMet(db.kills, hero, name, realm or "") + 1
  rec.text = N.build(rec, db.settings.tone)
  rec.short = N.short(rec, db.settings.tone)
  db.kills[#db.kills + 1] = rec
  C.diag.recorded = C.diag.recorded + 1
  C.diag.lastReason = "записано"
  if ns.onRecord then ns.onRecord(rec) end
  return rec
end

-- Фейковая победа для проверки баннера и книги (/летопись тест)
function C.fakeKill()
  local samples = {
    { "Ламберт", "PALADIN", "Dwarf", 2 }, { "Селестия", "PRIEST", "NightElf", 3 },
    { "Гизмо", "MAGE", "Gnome", 2 }, { "Эйвинд", "WARRIOR", "Human", 2 }, { "Нарель", "HUNTER", "Draenei", 3 },
  }
  local s = samples[math.random(#samples)]
  C.seq = C.seq + 1
  local ts = time()
  local rec = {
    id = C.heroKey() .. ":test:" .. ts .. ":" .. C.seq, hero = C.heroKey(), ts = ts, test = true,
    date = date("%d.%m.%Y %H:%M", ts), hour = tonumber(date("%H", ts)), killer = "me",
    victim = { name = s[1], realm = "", class = s[2], race = s[3], sex = s[4], level = safe(UnitLevel("player")) },
    myLevel = safe(UnitLevel("player")), mySex = safe(UnitSex("player")),
    zone = GetRealZoneText and GetRealZoneText() or "", subzone = GetSubZoneText() or "",
    spells = lastSpells(), streak = 1, meet = 1,
  }
  local db = C.db()
  rec.text = N.build(rec, db.settings.tone)
  rec.short = N.short(rec, db.settings.tone)
  db.kills[#db.kills + 1] = rec
  if ns.onRecord then ns.onRecord(rec) end
  return rec
end

-- Подключение к игре (в тестах не вызывается)
function C.start()
  local f = CreateFrame("Frame")
  C.frame = f
  local function reg(ev)
    local ok = pcall(f.RegisterEvent, f, ev)
    C.diag.events[ev] = ok
  end
  reg("ADDON_LOADED")
  reg("PARTY_KILL")
  reg("PLAYER_DEAD")
  reg("PLAYER_TARGET_CHANGED")
  reg("UPDATE_MOUSEOVER_UNIT")
  reg("NAME_PLATE_UNIT_ADDED")
  local okSpell = pcall(f.RegisterUnitEvent, f, "UNIT_SPELLCAST_SUCCEEDED", "player")
  C.diag.events["UNIT_SPELLCAST_SUCCEEDED"] = okSpell
  f:SetScript("OnEvent", function(_, ev, a1, a2, a3)
    if ev == "ADDON_LOADED" and a1 == ADDON then
      C.db()
      if ns.onReady then ns.onReady() end
    elseif ev == "PARTY_KILL" then
      local ok, err = pcall(C.onPartyKill, a1, a2)
      if not ok then C.diag.lastReason = "ошибка: " .. tostring(err) end
    elseif ev == "PLAYER_DEAD" then
      C.onPlayerDead()
    elseif ev == "PLAYER_TARGET_CHANGED" then
      C.remember("target")
    elseif ev == "UPDATE_MOUSEOVER_UNIT" then
      C.remember("mouseover")
    elseif ev == "NAME_PLATE_UNIT_ADDED" then
      C.remember(a1)
    elseif ev == "UNIT_SPELLCAST_SUCCEEDED" then
      C.noteSpell(a3)
    end
  end)
end

return C
