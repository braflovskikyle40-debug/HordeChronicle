-- Команды и связка: победа → баннер, звук, скриншот, объявление, обновление книги.
local ADDON, ns = ...
local C, A = ns.Core, ns.Announce

function ns.onRecord(rec)
  local s = C.db().settings
  A.announce(rec, s)
  if s.toast and ns.Toast then ns.Toast.show(rec) end
  if s.sound then PlaySound((SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959, "Master") end
  if s.screenshot and not rec.test and Screenshot then C_Timer.After(0.4, Screenshot) end
  if not rec.test and rec.killer == "me" and ns.War then ns.War.changed() end
  if ns.Book then ns.Book.refresh() end
end

function ns.onReady()
  local mine = 0
  for _, k in ipairs(C.db().kills) do if not k.test and k.hero == C.heroKey() then mine = mine + 1 end end
  A.printSelf(("загружена: %d %s в летописи. Открыть — /летопись или /hc"):format(
    mine, ns.Narrative.plural(mine, "победа", "победы", "побед")))
end

local function sagaCount()
  local n = 0
  for _ in pairs(HordeChronicle_Sagas or {}) do n = n + 1 end
  return n
end

local function diag()
  local _, build, _, iface = GetBuildInfo()
  local d = C.diag
  A.printSelf(("клиент %s, Interface %s, issecretvalue: %s"):format(tostring(build), tostring(iface), issecretvalue and "есть" or "нет"))
  local ev = {}
  for name, ok in pairs(d.events) do ev[#ev + 1] = name .. (ok and "=ок" or "=НЕТ") end
  table.sort(ev)
  A.printSelf("события: " .. table.concat(ev, ", "))
  A.printSelf(("PARTY_KILL пришло %d: записано %d, скрыто(secret) %d, не игрок %d, своя фракция %d, фракция неизвестна %d; кэш помог %d раз"):format(
    d.partyKills, d.recorded, d.secret, d.notPlayer, d.friendly, d.unknownFaction, d.cacheHits))
  A.printSelf("последний разбор: " .. (d.lastReason ~= "" and d.lastReason or "—"))
  A.printSelf(("в летописи %d записей, сказаний ИИ %d"):format(#C.db().kills, sagaCount()))
  local w, dd = ns.War.diag, d.deaths
  A.printSelf(("индекс войны: префикс %s, гильдия %s, отправлено %d (не ушло %d), принято %d, отброшено %d%s"):format(
    w.prefix and "ок" or "НЕТ", ns.War.guildKey() and "есть" or "нет", w.sent, w.failed, w.received, w.rejected,
    w.lastReject ~= "" and (" (последнее: " .. w.lastReject .. ")") or ""))
  A.printSelf(("смерти: от игроков засчитано %d, врага рядом не было %d, скрыто(secret) %d"):format(dd.enemy, dd.none, dd.secret))
end

local TONE_WORDS = { ["эпичный"] = "epic", ["глумливый"] = "mock", ["18+"] = "hard", ["жёсткий"] = "hard", ["жесткий"] = "hard", epic = "epic", mock = "mock", hard = "hard" }
local CHANNEL_WORDS = { ["себе"] = "self", ["гильдия"] = "guild", ["группа"] = "group", self = "self", guild = "guild", group = "group" }

SLASH_HORDECHRONICLE1 = "/летопись"
SLASH_HORDECHRONICLE2 = "/hc"
SLASH_HORDECHRONICLE3 = "/chronicle"
SlashCmdList.HORDECHRONICLE = function(msg)
  msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local cmd, arg = msg:match("^(%S+)%s*(.*)$")
  if not cmd or cmd == "" then
    ns.Book.toggle()
  elseif cmd == "тест" or cmd == "test" then
    C.fakeKill()
  elseif cmd == "диаг" or cmd == "diag" then
    diag()
  elseif cmd == "стат" or cmd == "stats" then
    ns.Book.tab = "stats"; ns.Book.show()
  elseif cmd == "война" or cmd == "war" then
    A.printSelf(ns.War.summary(ns.War.report()))
    ns.Book.tab = "war"; ns.Book.show()
  elseif cmd == "канал" or cmd == "channel" then
    local ch = CHANNEL_WORDS[arg]
    if ch then
      C.db().settings.channel = ch
      A.printSelf("о победах сообщаю: " .. A.CHANNELS[ch])
    else
      A.printSelf("канал: /летопись канал себе | гильдия | группа")
    end
  elseif cmd == "тон" or cmd == "tone" then
    local t = TONE_WORDS[arg]
    if t then
      C.db().settings.tone = t
      A.printSelf("тон летописи: " .. ns.Narrative.TONE_NAMES[t])
      if ns.Book then ns.Book.refresh() end
    else
      A.printSelf("тон: /летопись тон эпичный | глумливый | 18+")
    end
  else
    A.printSelf("команды: /летопись — книга, тест — пробная победа, диаг — диагностика, стат — статистика, война — индекс войны, канал себе|гильдия|группа, тон эпичный|глумливый|18+")
  end
end

C.start()
