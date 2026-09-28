-- Тесты логики аддона в LuaJIT с заглушками WoW API.
-- Запуск из папки games/wow_chronicle: luajit tests/run.lua
local ADDON = "HordeChronicle"
local ns = {}
local ROOT = "HordeChronicle/"

-- ---------- заглушки WoW API ----------
local clock = 1000
local W = {}      -- состояние мира для тестов
function GetTime() return clock end
function UnitName(u) if u == "player" then return "Громмаш", nil end return W.names and W.names[u] end
function GetRealmName() return "Пламегор" end
function UnitGUID(u) return (W.guids or {})[u] end
function UnitExists(u) return (W.guids or {})[u] ~= nil end
function UnitIsPlayer(u) return true end
function UnitLevel(u) if u == "player" then return 60 end return (W.levels or {})[u] end
function UnitSex(u) return W.mySex or 2 end
function UnitFactionGroup(u) if u == "player" then return "Horde" end return (W.factions or {})[u] end
function GetGuildInfo(u) return (W.guilds or {})[u] end
function GetPlayerInfoByGUID(guid) local p = (W.players or {})[guid]; if not p then return nil end return p.lclass, p.class, p.lrace, p.race, p.sex, p.name, p.realm end
function GetRealZoneText() return W.zone or "Предгорья Хилсбрада" end
function GetZoneText() return GetRealZoneText() end
function GetSubZoneText() return "Южнобережье" end
function IsInRaid() return false end
function IsInGroup(cat) if cat == LE_PARTY_CATEGORY_INSTANCE then return false end return W.inGroup or false end
time, date = os.time, os.date   -- в WoW это глобальные функции
function IsInGuild() return W.inGuild or false end
LE_PARTY_CATEGORY_INSTANCE = 2
C_Spell = { GetSpellName = function(id) return ({ [133] = "Огненный шар", [5308] = "Казнь" })[id] end }
SECRET = {}
function issecretvalue(v) return v == SECRET end
local sent, printed = {}, {}
function SendChatMessage(text, ch) sent[#sent + 1] = { text = text, ch = ch } end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, t) printed[#printed + 1] = t end }

local function load(name) assert(loadfile(ROOT .. name))(ADDON, ns) end
for _, f in ipairs({ "Data_Ru.lua", "Narrative.lua", "Stats.lua", "Announce.lua", "Core.lua" }) do load(f) end
local C, N, S, A, D = ns.Core, ns.Narrative, ns.Stats, ns.Announce, ns.Data

-- ---------- мини-фреймворк ----------
local passed, failed = 0, 0
local function test(name, fn)
  HordeChronicleDB = nil
  C.cache, C.cacheSize, C.recentSpells, C.streak, C.seq = {}, 0, {}, { count = 0, last = 0 }, 0
  W = { guids = { player = "Player-1-ME" }, players = {} }
  sent, printed = {}, {}
  A.lastSent, A.pending = -1e9, nil
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. " ожидалось " .. tostring(b) .. ", получено " .. tostring(a), 2) end end
local function has(s, sub, msg) if not tostring(s):find(sub, 1, true) then error((msg or "") .. " нет «" .. sub .. "» в: " .. tostring(s), 2) end end

local function enemy(guid, name, class, race, sex, extra)
  W.players[guid] = { name = name, class = class, race = race, sex = sex or 2, realm = "", lclass = class, lrace = race }
  for k, v in pairs(extra or {}) do W.players[guid][k] = v end
end

-- ---------- ядро ----------
test("своё добивание игрока Альянса записывается", function()
  enemy("Player-1-A", "Ламберт", "PALADIN", "Dwarf")
  local rec = assert(C.onPartyKill("Player-1-ME", "Player-1-A"))
  eq(rec.killer, "me"); eq(rec.victim.name, "Ламберт"); eq(rec.streak, 1); eq(rec.meet, 1)
  eq(#HordeChronicleDB.kills, 1)
  has(rec.text, "Ламберт")
end)

test("союзник по группе — отдельная пометка и его имя", function()
  enemy("Player-1-B", "Селестия", "PRIEST", "NightElf", 3)
  W.guids.party1 = "Player-1-ALLY"; W.names = { party1 = "Траллка" }
  local rec = assert(C.onPartyKill("Player-1-ALLY", "Player-1-B"))
  eq(rec.killer, "ally"); eq(rec.allyName, "Траллка"); eq(rec.streak, 0)
  has(rec.text, "Селестия")
end)

test("союзнические победы можно не записывать", function()
  C.db().settings.recordAlly = false
  enemy("Player-1-B", "Селестия", "PRIEST", "NightElf", 3)
  local rec = C.onPartyKill("Player-1-ALLY", "Player-1-B")
  eq(rec, nil); eq(#HordeChronicleDB.kills, 0)
end)

test("secret-значения пропускаются без ошибки", function()
  local rec, why = C.onPartyKill(SECRET, "Player-1-A")
  eq(rec, nil); has(why, "secret"); eq(C.diag.secret >= 1, true)
end)

test("НПС не записываются", function()
  local rec, why = C.onPartyKill("Player-1-ME", "Creature-0-1-2-3-4")
  eq(rec, nil); eq(why, "не игрок")
end)

test("игроки Орды не записываются", function()
  enemy("Player-1-H", "Горк", "WARRIOR", "Orc")
  local rec, why = C.onPartyKill("Player-1-ME", "Player-1-H")
  eq(rec, nil); eq(why, "своя фракция")
end)

test("нейтральная раса: фракция из кэша юнита", function()
  enemy("Player-1-P", "По", "MONK", "Pandaren")
  local rec, why = C.onPartyKill("Player-1-ME", "Player-1-P")
  eq(rec, nil); eq(why, "фракция неизвестна")
  W.guids.target = "Player-1-P"; W.factions = { target = "Alliance" }; W.levels = { target = 62 }; W.guilds = { target = "Щит Лордерона" }
  C.remember("target")
  rec = assert(C.onPartyKill("Player-1-ME", "Player-1-P"))
  eq(rec.victim.level, 62); eq(rec.victim.guild, "Щит Лордерона")
  has(rec.text, "Щит Лордерона"); has(rec.text, "2 уровня выше")
  has(N.build(rec, "epic"), "на 2 уровня выше")
end)

test("серия растёт, смерть её сбрасывает", function()
  enemy("Player-1-A", "Ламберт", "PALADIN", "Dwarf")
  enemy("Player-1-C", "Гизмо", "MAGE", "Gnome")
  C.onPartyKill("Player-1-ME", "Player-1-A")
  local r2 = C.onPartyKill("Player-1-ME", "Player-1-C")
  eq(r2.streak, 2)
  C.onPlayerDead()
  local r3 = C.onPartyKill("Player-1-ME", "Player-1-A")
  eq(r3.streak, 1)
end)

test("повторная встреча считается по имени и миру", function()
  enemy("Player-1-A", "Ламберт", "PALADIN", "Dwarf")
  C.onPartyKill("Player-1-ME", "Player-1-A")
  local r2 = C.onPartyKill("Player-1-ME", "Player-1-A")
  eq(r2.meet, 2); has(N.build(r2, "epic"), "снова Ламберт"); has(N.build(r2, "mock"), "за добавкой")
end)

test("последние мои заклинания попадают в запись", function()
  C.noteSpell(133); clock = clock + 2; C.noteSpell(5308)
  enemy("Player-1-A", "Ламберт", "PALADIN", "Dwarf")
  local rec = C.onPartyKill("Player-1-ME", "Player-1-A")
  eq(rec.spells[1], "Казнь"); eq(rec.spells[2], "Огненный шар")
  clock = clock + 60
  local rec2 = C.onPartyKill("Player-1-ME", "Player-1-A")
  eq(#rec2.spells, 0, "старые заклинания не считаются")
end)

-- ---------- текст ----------
local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID", "DEATHKNIGHT", "MONK", "DEMONHUNTER", "EVOKER", "UNKNOWN" }
local RACES = { "Human", "Dwarf", "NightElf", "Gnome", "Draenei", "Worgen", "VoidElf", "Pandaren", "Mystery" }

test("все тоны × классы × расы × пол × режимы дают текст без пропусков", function()
  local n = 0
  for _, tone in ipairs(N.TONES) do
  for _, cl in ipairs(CLASSES) do for _, rc in ipairs(RACES) do for _, sx in ipairs({ 2, 3 }) do
    for _, killer in ipairs({ "me", "ally" }) do for _, streak in ipairs({ 1, 2, 3, 7 }) do
      n = n + 1
      local rec = { id = "t" .. n, hero = "Громмаш-Пламегор", killer = killer, allyName = "Друг", mySex = (n % 2 == 0) and 3 or 2,
        victim = { name = "Имя", class = cl, race = rc, sex = sx, level = (n % 4 == 0) and 70 or 40, guild = (n % 5 == 0) and "Щит" or nil },
        myLevel = 60, zone = (n % 3 == 0) and "Неизвестная земля" or "Ясеневый лес", spells = (n % 2 == 0) and { "Казнь" } or {},
        streak = streak, meet = (n % 11) + 1, hour = n % 24 }
      local text, short = N.build(rec, tone), N.short(rec, tone)
      assert(#text > 30, "короткий текст"); assert(not text:find("{", 1, true), "осталась подстановка: " .. text)
      assert(not short:find("{", 1, true))
      assert(not text:find("(а)", 1, true) and not text:find("(ла)", 1, true), "скобочный род: " .. text)
    end end
  end end end
  end
  assert(n > 6000)
end)

test("род глагола по полу жертвы (эпичный тон)", function()
  local base = { id = "g1", killer = "ally", allyName = "Друг", victim = { name = "Селестия", class = "PRIEST", race = "NightElf", sex = 3 }, streak = 0, meet = 1 }
  has(N.short(base, "epic"), "Жрица Селестия из ночных эльфов пала")
  base.victim = { name = "Ламберт", class = "PALADIN", race = "Dwarf", sex = 2 }
  has(N.short(base, "epic"), "Паладин Ламберт из дворфов Стальгорна пал")
end)

test("18+: фраза пользователя и женский род", function()
  local rec = { id = "h1", hero = "Громмаш-Пламегор", killer = "me", victim = { name = "Ламберт", class = "PALADIN", race = "Dwarf", sex = 2 }, streak = 1, meet = 1 }
  has(N.short(rec, "hard"), "Игрок Альянса Ламберт (паладин из дворфов Стальгорна) был жёстко оттрахан в рот моим могуществом")
  rec.victim = { name = "Селестия", class = "PRIEST", race = "NightElf", sex = 3 }
  has(N.short(rec, "hard"), "Селестия (жрица из ночных эльфов) была жёстко оттрахана в рот")
end)

test("глумливый: «был уничтожен» и имя героя", function()
  local rec = { id = "m1", hero = "Громмаш-Пламегор", killer = "me", victim = { name = "Гизмо", class = "MAGE", race = "Gnome", sex = 2 }, streak = 1, meet = 1 }
  has(N.short(rec, "mock"), "Игрок Альянса Гизмо (маг из гномов) был уничтожен моим величием. Великий Громмаш снова в деле")
  rec.mySex = 3
  has(N.short(rec, "mock"), "Великая Громмаш снова в деле")
end)

test("тон по умолчанию — 18+", function()
  eq(N.DEFAULT_TONE, "hard"); eq(C.db().settings.tone, "hard"); eq(C.db().settings.hardInChat, false)
end)

test("текст детерминирован по id", function()
  local rec = { id = "same", killer = "me", victim = { name = "А", class = "MAGE", race = "Gnome", sex = 2 }, streak = 1, meet = 1 }
  eq(N.build(rec), N.build(rec))
end)

test("заглавная кириллица", function()
  eq(D.ucfirst("ёж"), "Ёж"); eq(D.ucfirst("под кронами"), "Под кронами"); eq(D.ucfirst("abc"), "Abc")
end)

test("склонение слова «уровень»", function()
  eq(N.plural(1, "уровень", "уровня", "уровней"), "уровень")
  eq(N.plural(3, "уровень", "уровня", "уровней"), "уровня")
  eq(N.plural(11, "уровень", "уровня", "уровней"), "уровней")
  eq(N.plural(22, "уровень", "уровня", "уровней"), "уровня")
end)

-- ---------- статистика ----------
test("статистика: итоги, заклятые враги, тестовые записи не считаются", function()
  local kills = {
    { hero = "H", killer = "me", streak = 3, zone = "Z1", victim = { name = "А", class = "MAGE", race = "Gnome" } },
    { hero = "H", killer = "me", streak = 1, zone = "Z1", victim = { name = "А", class = "MAGE", race = "Gnome" } },
    { hero = "H", killer = "ally", streak = 0, zone = "Z2", victim = { name = "Б", class = "PRIEST", race = "Human" } },
    { hero = "H", test = true, killer = "me", victim = { name = "Т" } },
    { hero = "X", killer = "me", victim = { name = "В" } },
  }
  local r = S.compute(kills, "H")
  eq(r.total, 3); eq(r.mine, 2); eq(r.ally, 1); eq(r.bestStreak, 3)
  eq(r.topFoes[1].key, "А"); eq(r.topFoes[1].count, 2); eq(r.byClass.MAGE, 2)
end)

-- ---------- каналы ----------
test("по умолчанию только себе", function()
  local rec = { short = "Победа.", killer = "me" }
  eq(A.announce(rec, { channel = "self" }, 0), "self"); eq(#sent, 0); eq(#printed, 1)
end)

test("гильдия: отправка и защита от спама со склейкой", function()
  W.inGuild = true
  local s = { channel = "guild", announceAlly = false }
  eq(A.announce({ short = "Раз.", killer = "me" }, s, 100), "GUILD")
  eq(A.announce({ short = "Два.", killer = "me" }, s, 105), "throttled")
  eq(A.announce({ short = "Три.", killer = "me" }, s, 111), "GUILD")
  eq(#sent, 2); has(sent[2].text, "и ещё 1")
end)

test("гильдия выбрана, но игрок без гильдии — пишем себе", function()
  W.inGuild = false
  eq(A.announce({ short = "Раз.", killer = "me" }, { channel = "guild" }, 100), "self"); eq(#sent, 0)
end)

test("союзнические победы в канал — только если включено", function()
  W.inGroup = true
  eq(A.announce({ short = "С.", killer = "ally" }, { channel = "group", announceAlly = false }, 100), "self")
  eq(A.announce({ short = "С.", killer = "ally" }, { channel = "group", announceAlly = true }, 200), "PARTY")
end)

test("18+ в гильдию — только с галочкой, иначе глумливый вариант", function()
  W.inGuild = true
  local rec = { id = "c1", hero = "Громмаш-Пламегор", short = "себе", killer = "me", victim = { name = "Ламберт", class = "PALADIN", race = "Dwarf", sex = 2 }, streak = 1 }
  A.announce(rec, { channel = "guild", tone = "hard", hardInChat = false }, 100)
  has(sent[1].text, "был уничтожен"); eq(sent[1].text:find("оттрахан", 1, true), nil)
  A.announce(rec, { channel = "guild", tone = "hard", hardInChat = true }, 200)
  has(sent[2].text, "оттрахан в рот")
  A.announce(rec, { channel = "guild", tone = "epic" }, 300)
  has(sent[3].text, "пал от моей руки")
end)

test("тестовые победы не уходят в канал", function()
  W.inGuild = true
  eq(A.announce({ short = "Т.", killer = "me", test = true }, { channel = "guild" }, 100), "self"); eq(#sent, 0)
end)

print(("Тесты: %d прошло, %d упало"):format(passed, failed))
if failed > 0 then os.exit(1) end
