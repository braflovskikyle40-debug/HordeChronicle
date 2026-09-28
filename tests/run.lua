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
function GetServerTime() return W.now or os.time() end
function UnitIsUnit(a) return (W.onMe or {})[a] end
local addonSent, timers = {}, {}
C_ChatInfo = {
  SendAddonMessage = function(p, t, ch) addonSent[#addonSent + 1] = { p = p, t = t, ch = ch }; return W.sendResult end,
  RegisterAddonMessagePrefix = function() return true end,
}
C_Timer = { After = function(d, fn) timers[#timers + 1] = { d = d, fn = fn } end, NewTicker = function() end }
local function runTimers() local list = timers; timers = {}; for _, t in ipairs(list) do t.fn() end end

local function load(name) assert(loadfile(ROOT .. name))(ADDON, ns) end
for _, f in ipairs({ "Data_Ru.lua", "Narrative.lua", "Stats.lua", "War.lua", "Announce.lua", "Core.lua" }) do load(f) end
local C, N, S, A, D, Wr = ns.Core, ns.Narrative, ns.Stats, ns.Announce, ns.Data, ns.War

-- ---------- мини-фреймворк ----------
local passed, failed = 0, 0
local function test(name, fn)
  HordeChronicleDB = nil
  C.cache, C.cacheSize, C.recentSpells, C.streak, C.seq = {}, 0, {}, { count = 0, last = 0 }, 0
  W = { guids = { player = "Player-1-ME" }, players = {} }
  sent, printed, addonSent, timers = {}, {}, {}, {}
  A.lastSent, A.pending = -1e9, nil
  C.lastEnemyTarget, C.lastEnemyName, C.diag.deaths = -1e9, nil, { enemy = 0, none = 0, secret = 0 }
  Wr.pendingSend, Wr.replyScheduled, Wr.lastReply, Wr.dirty, Wr.greeted = nil, nil, nil, nil, nil
  Wr.diag = { prefix = nil, sent = 0, failed = 0, received = 0, rejected = 0, lastReject = "" }
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

-- ---------- индекс войны ----------
local DAY = 86400
local TODAY = 20700                       -- номер суток по UTC
local function at(day, hour) return day * DAY + (hour or 12) * 3600 end
local function near(a, b, msg) if math.abs(a - b) > 1e-9 then error((msg or "") .. " ожидалось " .. b .. ", получено " .. a, 2) end end
local function inGuild() W.inGuild = true; W.guilds = { player = "Кровавый Топор" }; W.now = at(TODAY) end
local GUILD = "Кровавый Топор-Пламегор"
local function counts(list) local c = {}; for i = 1, 7 do c[i] = list[i] or { 0, 0 } end; return c end

test("курс: +1% за победу, -1% за смерть; перевес — доля побед", function()
  near(Wr.rate(0, 0), 100); near(Wr.rate(1, 0), 101); near(Wr.rate(0, 1), 99)
  near(Wr.rate(2, 1), 100 * 1.01 * 1.01 * 0.99)
  eq(Wr.balance(3, 1), 0.75); eq(Wr.balance(0, 0), nil)
  eq(Wr.balanceText(0.63), "Орда 63% — 37% Альянс"); eq(Wr.balanceText(nil), "стычек за неделю не было")
end)

test("сообщение со счётом: туда и обратно", function()
  local c = counts({ { 1, 0 }, [7] = { 12, 3 } })
  local text = Wr.encode(TODAY, c)
  eq(text, "S|" .. TODAY .. "|1,0;0,0;0,0;0,0;0,0;0,0;12,3")
  local m = assert(Wr.decode(text, TODAY))
  eq(m.kind, "S"); eq(m.day, TODAY); eq(m.counts[1][1], 1); eq(m.counts[7][1], 12); eq(m.counts[7][2], 3)
  eq(Wr.decode("Q", TODAY).kind, "Q")
end)

test("кривые и подозрительные сообщения отбрасываются", function()
  local good = Wr.encode(TODAY, counts({}))
  eq(select(2, Wr.decode("привет", TODAY)), "формат")
  eq(select(2, Wr.decode("S|" .. TODAY .. "|1,0;0,0", TODAY)), "формат")
  eq(select(2, Wr.decode("S|" .. TODAY .. "|1,0;;0,0;0,0;0,0;0,0;0,0", TODAY)), "формат")
  eq(select(2, Wr.decode("S|" .. (TODAY + 5) .. good:match("|[^|]+$"), TODAY)), "день из будущего")
  eq(select(2, Wr.decode(Wr.encode(TODAY, counts({ { 1000, 0 } })), TODAY)), "слишком много за сутки")
  local db = C.db()
  eq(Wr.receive(db, GUILD, "Друг-Пламегор", "мусор", TODAY, "Громмаш-Пламегор"), nil)
  eq(Wr.diag.rejected, 1)
end)

test("свои сообщения не считаются дважды", function()
  local db = C.db()
  local kind, why = Wr.receive(db, GUILD, "Громмаш-Пламегор", Wr.encode(TODAY, counts({ [7] = { 5, 0 } })), TODAY, "Громмаш-Пламегор")
  eq(kind, nil); eq(why, "своё"); eq(next(Wr.guild(db, GUILD).peers), nil)
end)

test("индекс гильдии = мой счёт + последние счета согильдейцев", function()
  inGuild()
  local db = C.db()
  db.kills = {
    { hero = "Громмаш-Пламегор", killer = "me", ts = at(TODAY) },
    { hero = "Громмаш-Пламегор", killer = "me", ts = at(TODAY - 1) },
    { hero = "Громмаш-Пламегор", killer = "ally", ts = at(TODAY) },               -- добил соратник — не наш счёт
    { hero = "Громмаш-Пламегор", killer = "me", ts = at(TODAY), test = true },    -- тестовая
    { hero = "Громмаш-Пламегор", killer = "me", ts = at(TODAY - 8) },             -- вне окна
  }
  db.deaths = { { hero = "Громмаш-Пламегор", ts = at(TODAY) } }
  Wr.receive(db, GUILD, "Друг-Пламегор", Wr.encode(TODAY, counts({ [7] = { 1, 1 } })), TODAY, "Громмаш-Пламегор")
  Wr.receive(db, GUILD, "Друг-Пламегор", Wr.encode(TODAY, counts({ [7] = { 3, 1 } })), TODAY, "Громмаш-Пламегор") -- обновил счёт
  Wr.receive(db, GUILD, "Лира-Пламегор", Wr.encode(TODAY - 3, counts({ { 50, 0 }, [7] = { 2, 0 } })), TODAY, "Громмаш-Пламегор")
  local r = Wr.totals(db, GUILD, TODAY, "Громмаш-Пламегор")
  eq(r.k, 2 + 3 + 2, "побед"); eq(r.d, 1 + 1, "потерь"); eq(r.members, 3)
  eq(r.mine.k, 2); eq(r.mine.d, 1)
  eq(r.days[7].k, 1 + 3); eq(r.days[4].k, 2, "счёт Лиры сдвинут на её день")
  near(r.rate, Wr.rate(7, 2)); near(r.change, r.days[7].rate - r.days[6].rate)
end)

test("вне гильдии — только свой счёт; альты в той же гильдии считаются", function()
  local db = C.db()
  db.kills = { { hero = "Громмаш-Пламегор", killer = "me", ts = at(TODAY) }, { hero = "Алт-Пламегор", killer = "me", ts = at(TODAY) } }
  local solo = Wr.totals(db, nil, TODAY, "Громмаш-Пламегор")
  eq(solo.k, 1); eq(solo.members, 1)
  Wr.state(db).heroGuild["Алт-Пламегор"] = GUILD
  local r = Wr.totals(db, GUILD, TODAY, "Громмаш-Пламегор")
  eq(r.k, 2); eq(r.members, 2)
end)

test("молчащие больше 14 дней согильдейцы забываются", function()
  local db = C.db()
  Wr.guild(db, GUILD).peers["Старый-Пламегор"] = { day = TODAY - 20, counts = counts({}), seen = TODAY - 20 }
  Wr.receive(db, GUILD, "Друг-Пламегор", Wr.encode(TODAY, counts({})), TODAY, "Громмаш-Пламегор")
  eq(Wr.guild(db, GUILD).peers["Старый-Пламегор"], nil); assert(Wr.guild(db, GUILD).peers["Друг-Пламегор"])
end)

test("смерть: враг держит меня в цели — засчитана, с именем", function()
  W.guids.nameplate3 = "Player-1-A"; W.factions = { nameplate3 = "Alliance" }; W.onMe = { nameplate3target = true }; W.names = { nameplate3 = "Ламберт" }
  eq(C.onPlayerDead(), "enemy")
  local d = C.db().deaths
  eq(#d, 1); eq(d[1].killer, "Ламберт"); eq(d[1].hero, "Громмаш-Пламегор"); eq(C.diag.deaths.enemy, 1)
  eq(#timers, 1, "счёт уйдёт гильдии")
end)

test("смерть без врага рядом и от своих не засчитывается", function()
  eq(C.onPlayerDead(), "none")
  W.guids.nameplate1 = "Player-1-H"; W.factions = { nameplate1 = "Horde" }; W.onMe = { nameplate1target = true }
  eq(C.onPlayerDead(), "none")
  W.guids.nameplate2 = "Player-1-A"; W.factions.nameplate2 = "Alliance"          -- враг есть, но бьёт не меня
  eq(C.onPlayerDead(), "none")
  eq(#C.db().deaths, 0); eq(C.diag.deaths.none, 3)
end)

test("смерть: secret — пропуск, не ошибка", function()
  W.guids.nameplate1 = "Player-1-A"; W.factions = { nameplate1 = SECRET }
  eq(C.onPlayerDead(), "secret"); eq(#C.db().deaths, 0)
  W.factions = { nameplate1 = "Alliance" }; W.onMe = { nameplate1target = SECRET }
  eq(C.onPlayerDead(), "secret")
end)

test("смерть: враг был моей целью в последние 15 с", function()
  W.guids.target = "Player-1-A"; W.factions = { target = "Alliance" }; W.names = { target = "Гизмо" }
  C.noteTarget()
  W.guids.target = nil
  clock = clock + 10
  eq(C.onPlayerDead(), "enemy"); eq(C.db().deaths[1].killer, "Гизмо")
  clock = clock + 20
  eq(C.onPlayerDead(), "none")
end)

test("отправка счёта откладывается и склеивается", function()
  inGuild()
  local db = C.db()
  db.kills = { { hero = "Громмаш-Пламегор", killer = "me", ts = at(TODAY) } }
  Wr.changed(); Wr.changed(); Wr.changed()
  eq(#timers, 1); eq(timers[1].d, 5); eq(#addonSent, 0)
  runTimers()
  eq(#addonSent, 1); eq(addonSent[1].p, "HChron1"); eq(addonSent[1].ch, "GUILD")
  eq(addonSent[1].t, "S|" .. TODAY .. "|0,0;0,0;0,0;0,0;0,0;0,0;1,0")
  eq(Wr.state(db).heroGuild["Громмаш-Пламегор"], GUILD)
end)

test("без гильдии или с выключенной галочкой счёт не уходит", function()
  Wr.changed(); runTimers(); eq(#addonSent, 0)
  inGuild(); C.db().settings.shareWar = false
  Wr.changed(); runTimers(); eq(#addonSent, 0)
  eq(C.db().settings.shareWar, false)
end)

test("не ушло — повторим позже", function()
  inGuild(); W.sendResult = 7
  eq(Wr.sendState(), false); eq(Wr.dirty, true); eq(Wr.diag.failed, 1)
  W.sendResult = 0
  eq(Wr.sendState(), true); eq(Wr.dirty, false)
end)

test("ответ на запрос: со случайной задержкой и не чаще раза в 30 с", function()
  inGuild()
  Wr.onAddonMessage("HChron1", "Q", "GUILD", "Друг-Пламегор")
  Wr.onAddonMessage("HChron1", "Q", "GUILD", "Лира-Пламегор")
  eq(#timers, 1); assert(timers[1].d >= 1 and timers[1].d <= 8)
  runTimers(); eq(#addonSent, 1)
  Wr.onAddonMessage("HChron1", "Q", "GUILD", "Друг-Пламегор"); eq(#timers, 0, "перерыв 30 с")
  clock = clock + 31
  Wr.onAddonMessage("HChron1", "Q", "GUILD", "Друг-Пламегор"); eq(#timers, 1)
end)

test("чужой префикс и не гильдейский канал игнорируются", function()
  inGuild()
  local text = Wr.encode(TODAY, counts({ [7] = { 4, 0 } }))
  Wr.onAddonMessage("DBM", text, "GUILD", "Друг-Пламегор")
  Wr.onAddonMessage("HChron1", text, "WHISPER", "Друг-Пламегор")
  eq(next(Wr.guild(C.db(), GUILD).peers), nil)
  Wr.onAddonMessage("HChron1", text, "GUILD", "Друг-Пламегор")
  eq(Wr.guild(C.db(), GUILD).peers["Друг-Пламегор"].counts[7][1], 4)
end)

test("имя отправителя: мир без пробелов и дефисов", function()
  eq(Wr.norm("Громмаш-Серебряная Длань"), "Громмаш-СеребрянаяДлань"); eq(Wr.norm("Гром-Азжол-Неруб"), "Гром-АзжолНеруб")
end)

print(("Тесты: %d прошло, %d упало"):format(passed, failed))
if failed > 0 then os.exit(1) end
