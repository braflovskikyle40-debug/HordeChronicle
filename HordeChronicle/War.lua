-- Индекс войны: счёт гильдии в стычках с другой фракцией и «курс очков войны».
--
-- K — свои добивания игроков другой фракции, D — свои смерти от них. Каждый аддон считает только
-- себя, а согильдейцам шлёт свой счёт по дням скрытым сообщением аддона (канал GUILD).
-- Храним последний присланный счёт каждого согильдейца: повторная доставка ничего не ломает,
-- пропущенное восполняется, когда он снова войдёт в игру. Сутки — по UTC, одинаковые для всех.
-- Это игровые очки, не деньги.
local _, ns = ...
ns = ns or {}

local W = {}
ns.War = W

W.PREFIX = "HChron1"
W.WINDOW = 7              -- дней в окне индекса
W.DAY = 86400
W.MAX_PER_DAY = 999       -- больше за сутки — считаем сообщение подделкой
W.PEER_TTL = 14           -- дней: молчащих дольше согильдейцев забываем
W.SEND_DELAY = 5          -- сек: откладываем отправку, чтобы серия побед ушла одним сообщением
W.REPLY_MIN, W.REPLY_MAX = 1, 8
W.REPLY_COOLDOWN = 30
W.RETRY_EVERY = 60
W.GAIN, W.LOSS = 1.01, 0.99

W.diag = { prefix = nil, sent = 0, failed = 0, received = 0, rejected = 0, lastReject = "" }

local isSecret = issecretvalue or function() return false end
local FACTION_NAMES = { Horde = "Орда", Alliance = "Альянс" }
W.FACTION_NAMES = FACTION_NAMES

local function now() return (GetServerTime and GetServerTime()) or time() end

function W.dayIndex(ts) return math.floor((ts or now()) / W.DAY) end

-- «Имя-Мир» в том виде, в каком игра подписывает сообщения аддонов: в мире без пробелов и дефисов
function W.norm(key)
  local name, realm = tostring(key or ""):match("^([^%-]+)%-?(.*)$")
  if not name then return "" end
  return name .. "-" .. (realm or ""):gsub("[%s%-]", "")
end

function W.state(db)
  db.war = db.war or {}
  db.war.guilds = db.war.guilds or {}
  db.war.heroGuild = db.war.heroGuild or {}
  return db.war
end

function W.guild(db, key)
  local g = W.state(db).guilds
  g[key] = g[key] or { peers = {} }
  return g[key]
end

local function emptyCounts()
  local c = {}
  for i = 1, W.WINDOW do c[i] = { 0, 0 } end
  return c
end

-- Мой счёт за окно: {k, d} по дням, от старого к сегодняшнему
function W.myCounts(db, hero, today)
  local counts, first = emptyCounts(), today - W.WINDOW + 1
  local function add(ts, slot)
    local d = W.dayIndex(ts)
    if d >= first and d <= today then
      local c = counts[d - first + 1]
      c[slot] = c[slot] + 1
    end
  end
  for _, k in ipairs(db.kills or {}) do
    if not k.test and k.killer == "me" and k.hero == hero and k.ts then add(k.ts, 1) end
  end
  for _, e in ipairs(db.deaths or {}) do
    if e.hero == hero and e.ts then add(e.ts, 2) end
  end
  return counts
end

function W.rate(k, d) return 100 * W.GAIN ^ k * W.LOSS ^ d end

-- Доля побед в стычках, nil — стычек не было
function W.balance(k, d)
  if k + d == 0 then return nil end
  return k / (k + d)
end

-- Моя фракция и противник (аддон работает и у игрока Альянса)
function W.sides()
  local mine = UnitFactionGroup("player")
  return mine, mine == "Alliance" and "Horde" or "Alliance"
end

function W.balanceText(balance)
  if not balance then return "стычек за неделю не было" end
  local mine, enemy = W.sides()
  local p = math.floor(balance * 100 + 0.5)
  return ("%s %d%% — %d%% %s"):format(FACTION_NAMES[mine] or "Мы", p, 100 - p, FACTION_NAMES[enemy])
end

function W.summary(r)
  local who = W.guildKey() and ("гильдия, участников с аддоном: " .. r.members) or "только вы (вне гильдии)"
  return ("Индекс войны: курс %.2f (%+.2f за сутки), %s; за 7 дней побед %d, потерь %d; %s"):format(
    r.rate, r.change, W.balanceText(r.balance), r.k, r.d, who)
end

function W.encode(today, counts)
  local parts = {}
  for i, c in ipairs(counts) do parts[i] = c[1] .. "," .. c[2] end
  return "S|" .. today .. "|" .. table.concat(parts, ";")
end

-- Разбор сообщения. Возвращает {kind="Q"} | {kind="S", day, counts} или nil и причину.
function W.decode(text, today)
  if type(text) ~= "string" or #text > 255 then return nil, "не строка" end
  if text == "Q" then return { kind = "Q" } end
  local day, body = text:match("^S|(%d+)|([%d,;]+)$")
  day = tonumber(day)
  if not day then return nil, "формат" end
  if today and day > today + 1 then return nil, "день из будущего" end
  local counts = {}
  for part in (body .. ";"):gmatch("([^;]*);") do
    local k, d = part:match("^(%d+),(%d+)$")
    k, d = tonumber(k), tonumber(d)
    if not k then return nil, "формат" end
    if k > W.MAX_PER_DAY or d > W.MAX_PER_DAY then return nil, "слишком много за сутки" end
    counts[#counts + 1] = { k, d }
  end
  if #counts ~= W.WINDOW then return nil, "формат" end
  return { kind = "S", day = day, counts = counts }
end

function W.prune(db, today)
  for _, g in pairs(W.state(db).guilds) do
    for who, p in pairs(g.peers) do
      if (p.seen or 0) < today - W.PEER_TTL then g.peers[who] = nil end
    end
  end
end

-- Приём сообщения согильдейца. me — моё имя в формате отправителя.
function W.receive(db, guildKey, sender, text, today, me)
  if not sender or sender == me then return nil, "своё" end
  local m, why = W.decode(text, today)
  if not m then
    W.diag.rejected = W.diag.rejected + 1
    W.diag.lastReject = why
    return nil, why
  end
  if m.kind == "Q" then return "Q" end
  if not guildKey then return nil, "не в гильдии" end
  W.guild(db, guildKey).peers[sender] = { day = m.day, counts = m.counts, seen = today }
  W.diag.received = W.diag.received + 1
  W.prune(db, today)
  return "S"
end

-- Итог по гильдии (или только по мне, если guildKey = nil)
function W.totals(db, guildKey, today, hero)
  local first = today - W.WINDOW + 1
  local days = {}
  for i = 1, W.WINDOW do days[i] = { day = first + i - 1, k = 0, d = 0 } end
  local function add(lastDay, counts)
    for i, c in ipairs(counts) do
      local day = lastDay - #counts + i
      if day >= first and day <= today then
        local t = days[day - first + 1]
        t.k, t.d = t.k + c[1], t.d + c[2]
      end
    end
  end

  -- мои герои в этой гильдии: текущий всегда, остальные — если были в ней замечены
  local mine, own, members = { k = 0, d = 0 }, {}, 0
  local heroGuild = W.state(db).heroGuild
  for _, h in ipairs(W.heroes(db, hero)) do
    if h == hero or (guildKey and heroGuild[h] == guildKey) then
      local counts = W.myCounts(db, h, today)
      add(today, counts)
      own[W.norm(h)] = true
      members = members + 1
      if h == hero then
        for _, c in ipairs(counts) do mine.k, mine.d = mine.k + c[1], mine.d + c[2] end
      end
    end
  end
  if guildKey then
    for who, p in pairs(W.guild(db, guildKey).peers) do
      if not own[who] and (p.seen or 0) >= today - W.PEER_TTL then
        add(p.day, p.counts)
        members = members + 1
      end
    end
  end

  local K, D = 0, 0
  for _, t in ipairs(days) do
    K, D = K + t.k, D + t.d
    t.rate = W.rate(K, D)
  end
  return {
    days = days, k = K, d = D, rate = days[#days].rate,
    change = days[#days].rate - (days[#days - 1] and days[#days - 1].rate or 100),
    balance = W.balance(K, D), members = members, mine = mine,
  }
end

-- Все герои аккаунта, у которых есть записи (плюс текущий)
function W.heroes(db, hero)
  local seen, list = { [hero] = true }, { hero }
  local function note(h) if h and not seen[h] then seen[h] = true; list[#list + 1] = h end end
  for _, k in ipairs(db.kills or {}) do note(k.hero) end
  for _, e in ipairs(db.deaths or {}) do note(e.hero) end
  return list
end

-- ---------- связь с игрой ----------

function W.guildKey()
  if not (IsInGuild and IsInGuild()) then return nil end
  local g = GetGuildInfo("player")
  if not g or isSecret(g) then return nil end
  return g .. "-" .. ((GetRealmName and GetRealmName()) or ""):gsub("[%s%-]", "")
end

function W.me() return W.norm(ns.Core.heroKey()) end

function W.report()
  local C = ns.Core
  return W.totals(C.db(), W.guildKey(), W.dayIndex(), C.heroKey())
end

function W.send(text)
  local send = C_ChatInfo and C_ChatInfo.SendAddonMessage
  local ok, res = false, nil
  if send then ok, res = pcall(send, W.PREFIX, text, "GUILD") end
  local success = Enum and Enum.SendAddonMessageResult and Enum.SendAddonMessageResult.Success
  local good = ok and (res == nil or res == true or res == 0 or (success ~= nil and res == success))
  if good then W.diag.sent = W.diag.sent + 1 else W.diag.failed = W.diag.failed + 1 end
  return good
end

-- Отправить свой счёт гильдии. Не ушло — повторим по таймеру.
function W.sendState()
  local C = ns.Core
  local db = C.db()
  local key = W.guildKey()
  if not key or not db.settings.shareWar then W.dirty = false; return false end
  local hero, today = C.heroKey(), W.dayIndex()
  W.state(db).heroGuild[hero] = key
  local ok = W.send(W.encode(today, W.myCounts(db, hero, today)))
  W.dirty = not ok
  return ok
end

-- Мой счёт изменился: отправка через SEND_DELAY, серия склеивается в одно сообщение
function W.changed()
  W.dirty = true
  if W.pendingSend then return end
  W.pendingSend = true
  C_Timer.After(W.SEND_DELAY, function()
    W.pendingSend = false
    W.sendState()
  end)
end

-- Кто-то попросил счёт: отвечаем со случайной задержкой и не чаще раза в REPLY_COOLDOWN
function W.onQuery()
  if W.replyScheduled or not ns.Core.db().settings.shareWar then return end
  if GetTime() - (W.lastReply or -1e9) < W.REPLY_COOLDOWN then return end
  W.replyScheduled = true
  C_Timer.After(W.REPLY_MIN + math.random() * (W.REPLY_MAX - W.REPLY_MIN), function()
    W.replyScheduled = false
    W.lastReply = GetTime()
    W.sendState()
  end)
end

function W.onAddonMessage(prefix, text, channel, sender)
  if prefix ~= W.PREFIX or channel ~= "GUILD" then return end
  if isSecret(text) or isSecret(sender) then return end
  local kind = W.receive(ns.Core.db(), W.guildKey(), sender, text, W.dayIndex(), W.me())
  if kind == "Q" then
    W.onQuery()
  elseif kind == "S" and ns.Book and ns.Book.tab == "war" then
    ns.Book.refresh()
  end
end

-- Поздороваться с гильдией: отправить свой счёт и попросить чужие
function W.hello()
  if not W.guildKey() then return end
  W.greeted = true
  W.prune(ns.Core.db(), W.dayIndex())
  W.sendState()
  W.send("Q")
end

function W.start()
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    W.diag.prefix = pcall(C_ChatInfo.RegisterAddonMessagePrefix, W.PREFIX)
  else
    W.diag.prefix = false
  end
  C_Timer.After(8, W.hello)   -- сразу после входа сведения о гильдии ещё не пришли
  C_Timer.NewTicker(W.RETRY_EVERY, function()
    if not W.greeted then W.hello() elseif W.dirty then W.sendState() end
  end)
end

return W
