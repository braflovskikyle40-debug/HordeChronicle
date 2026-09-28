-- Генератор текста летописи. Чистые функции без WoW API — тестируется в LuaJIT.
-- Вход — запись о победе (rec) и тон, выход — строка. Выбор вариантов детерминирован по rec.id,
-- поэтому одна и та же запись в одном тоне всегда описана одинаково.
--
-- Тоны: epic — эпичный, mock — глумливый (без мата), hard — 18+ (мат).
local _, ns = ...
ns = ns or {}
local D = assert(ns.Data, "Data_Ru.lua должен грузиться раньше Narrative.lua")

local N = {}
ns.Narrative = N

N.TONES = { "epic", "mock", "hard" }
N.TONE_NAMES = { epic = "эпичный", mock = "глумливый", hard = "18+ (мат)" }
N.DEFAULT_TONE = "hard"

-- Детерминированный генератор: сид из строки id
local function makeRng(seedText)
  local h = 5381
  for i = 1, #seedText do h = (h * 33 + seedText:byte(i)) % 2147483647 end
  if h == 0 then h = 1 end
  return function(n)
    h = (h * 48271) % 2147483647
    return (h % n) + 1
  end
end

local function pick(rng, list) return list[rng(#list)] end

local function plural(n, one, few, many)
  local n10, n100 = n % 10, n % 100
  if n10 == 1 and n100 ~= 11 then return one end
  if n10 >= 2 and n10 <= 4 and (n100 < 12 or n100 > 14) then return few end
  return many
end
N.plural = plural

-- sex: 2 — мужской, 3 — женский (как в GetPlayerInfoByGUID / UnitSex); иное — мужской
local function g(sex) return sex == 3 and 2 or 1 end

-- {key} — подстановка; {Key} с заглавной — та же подстановка с заглавной буквы
local function fill(template, vars)
  return (template:gsub("{(%w+)}", function(k)
    local v = vars[k]
    if v == nil then
      local lower = k:sub(1, 1):lower() .. k:sub(2)
      if k:sub(1, 1):match("%u") and vars[lower] ~= nil then return D.ucfirst(vars[lower]) end
      error("нет подстановки {" .. k .. "} в шаблоне: " .. template)
    end
    return v
  end))
end

-- ============================ ТЕКСТЫ ============================
local T = {}

T.epic = {
  kill = {
    "{Cls} {name} {from}, {epi}, {dared} встать на пути Орды — и {fell}.",
    "Я {slew} {clsAcc} по имени {name} {from}. Альянс стал на одного бойца беднее.",
    "{Name}, {cls} {from}, {died} {place}. Кровь врага напоила землю.",
    "Лок'тар огар! {Cls} {name} {epi} {fell} от моей руки {place}.",
    "Сталь Орды нашла сердце врага: {cls} {name} {from} больше не поднимется.",
    "{Cls} {name} {dared} бросить мне вызов {place} — и {paid} за дерзость жизнью.",
    "Недолго длился бой. {Cls} {name} {from} {fell}, так и не поняв, откуда пришла смерть.",
    "{Place} {cls} {name} {epi} {fell} к моим ногам. За Орду!",
  },
  spell = {
    "Всё решил удар «{spell}»: {cls} {name} {from} {fell}.",
    "Последним, что {saw} {name}, был мой удар «{spell}». {Cls} {from} {fell} {place}.",
    "Одним ударом «{spell}» я {slew} {clsAcc} по имени {name} {epi}.",
  },
  ally = {
    "{Cls} {name} {from} {fell} от руки моего соратника {ally}. Я {was} рядом.",
    "Мой соратник {ally} добил {clsAcc} по имени {name} {from}, а я {covered} спину.",
    "Вместе мы взяли верх: {cls} {name} {epi} {fell}, последний удар — за {ally}.",
  },
  streak = {
    [2] = { "Двойная победа!", "Второй враг — не успел остыть клинок." },
    [3] = { "Третий подряд! Альянс редеет на глазах.", "Тройная победа — Орда будет петь об этом." },
    big = { "Бойня! {streak} врагов подряд без единой моей смерти.", "Серия в {streak} побед. Альянс трепещет." },
  },
  meet = {
    [2]  = { "Мы уже встречались — и снова {name} {lost}." },
    [5]  = { "Пятая встреча. {Name} — мой заклятый враг." },
    [10] = { "Десятый раз! Имя {name} вписано в летопись кровавыми рунами." },
    many = "Это наша {meet}-я встреча.",
  },
  higher = { "Враг был сильнее — на {diff} выше. Тем слаще победа." },
  lower = { "Лёгкая добыча, но Альянс есть Альянс.", "Не ровня мне — но пощады враг не заслужил." },
  guild = { "Гильдия «{guild}» недосчитается бойца." },
  night = { "Ночь скрыла мой удар.", "Луна была единственной свидетельницей." },
  dawn = { "Рассвет встретил победителя." },
  short = "{Cls} {name} {from} {fell} от моей руки",
  shortAlly = "{Cls} {name} {from} {fell} от руки соратника {ally}",
}

T.mock = {
  kill = {
    "Игрок Альянса {name} {destroyed}. {Great} {me} даже бровью не {moved}, а {cls} {from} так и не {understood}, что произошло.",
    "{Cls} {name} {from} {crushed} моим величием. Альянс, присылайте следующего — этот кончился.",
    "{Another} {cls} {epi}… {Name} {lay} мордой в грязь {place}, как и положено Альянсу.",
    "{Name} {dared} подойти ко мне. Смелость похвальна, результат предсказуем: {destroyed}.",
    "{Cls} {name} {epi}? Звучало грозно, выглядело жалко. {Humiliated} за пару секунд.",
    "Альянс снова прислал мне корм: {cls} {name} {from} {destroyed} и {sent} на кладбище думать над своим поведением.",
    "{Name} {squealed} совсем по-гномьи и {lay}. {Great} {me} не прощает слабости.",
    "{Place} {cls} {name} {humiliated} при свидетелях. Альянс, это было позорно даже для вас.",
  },
  spell = {
    "Хватило одного удара «{spell}» — {cls} {name} {from} {destroyed} и {sent} на кладбище.",
    "«{spell}» — и {name} {lay}. Даже вспотеть не пришлось, а ведь это {cls} {from}.",
    "Удар «{spell}» по самолюбию Альянса: {cls} {name} {crushed} моим величием.",
  },
  ally = {
    "{Cls} {name} {from} {destroyed} моим соратником {ally}. Я {stood} рядом и наслаждался зрелищем.",
    "Последний удар — за {ally}, {cls} {name} {humiliated}, а я {held} попкорн. Альянс, вы вообще стараетесь?",
    "Даже на подхвате у {ally} Альянс ложится штабелями: {cls} {name} {humiliated}.",
  },
  streak = {
    [2] = { "Двое за раз. Альянс, вы там вообще тренируетесь?", "Второй подряд. Скучно, но приятно." },
    [3] = { "Третий. Я уже {bored}.", "Трое подряд — Альянс, это уже неприлично." },
    big = { "{streak} подряд. Кто-нибудь, остановите меня. А, точно — вы не можете.", "Серия {streak}. Альянс кончается быстрее, чем мана у жреца." },
  },
  meet = {
    [2]  = { "{Name} {returned} за добавкой — и снова {got}." },
    [5]  = { "Пятый раз, {name}. Я уже узнаю тебя по визгу." },
    [10] = { "Десятый раз! {Name}, может, сменишь фракцию? Или игру?" },
    many = "Встреча номер {meet}. {Name} явно ко мне {keen}.",
  },
  higher = { "Выше меня на {diff} — и всё равно {lay}. Уровни не спасают от величия." },
  lower = { "Лёгкая добыча. Альянс, пришлите кого-нибудь посерьёзнее.", "Мелочь, но и мелочь надо давить." },
  guild = { "Гильдия «{guild}», заберите своего бойца с кладбища." },
  night = { "Ночью Альянс тоже сосёт — проверено.", "Даже ночью от меня не спрятаться." },
  dawn = { "Рассвет. Отличное время, чтобы унижать Альянс." },
  short = "Игрок Альянса {name} ({cls} {from}) {destroyed} моим величием. {Great} {me} снова в деле",
  shortAlly = "Игрок Альянса {name} ({cls} {from}) {destroyed} моим соратником {ally}",
}

T.hard = {
  kill = {
    "Игрок Альянса {name} {fucked} в рот моим могуществом.",
    "{Cls} {name} {from} {fucked}. {Valiant} {me} {pleased}: без смазки и без шансов.",
    "{Name} {came} ко мне {place} — и {fuckedFull}. Хули ты вообще сюда {climbed}?",
    "Я {bent} {clsAcc} по имени {name} раком и {owned}. Даже пикнуть не {managed}.",
    "{Cls} {name} {epi} {sucked} у моего клинка {place}. Альянс, это ваш лучший?",
    "Альянсовская шваль {name} ({cls} {from}) {fuckedFull}. Орда ебёт — Альянс плачет.",
    "{Name} {thought}, что {cls} {from} — это сила. {Me} {explained} иначе: {fucked}.",
    "{Place} {cls} {name} {humiliated} и {fucked}. Мама, забери меня отсюда.",
  },
  spell = {
    "{Rammed} «{spell}» по самые гланды — {cls} {name} {fucked}.",
    "Одним «{spell}» я {owned} {clsAcc} по имени {name}. Альянс, сосите.",
    "«{spell}» прямо в очко Альянсу: {cls} {name} {from} {fuckedFull}.",
  },
  ally = {
    "{Cls} {name} {fucked} моим соратником {ally}, а я {held} свечку.",
    "Мы с {ally} разложили {clsAcc} по имени {name} на двоих. Я {stood} рядом и ржал.",
    "Групповуха по-ордынски: {cls} {name} {from} {fuckedFull} вместе с {ally}.",
  },
  streak = {
    [2] = { "Двое за раз. Альянс, вы там все такие ебланы?", "Второй. Конвейер по ебле Альянса запущен." },
    [3] = { "Третий подряд! Конвейер ебли Альянса работает без перерыва.", "Трое. Альянс, у вас там очередь, что ли?" },
    big = { "{streak} подряд. Альянс, сука, кончайтесь уже.", "Серия {streak}. Столько раз Альянс не ебали даже в Катаклизм." },
  },
  meet = {
    [2]  = { "{Name} снова здесь. Понравилось, видимо." },
    [5]  = { "Пятый раз, {name}. Ты уже моя личная подстилка." },
    [10] = { "Десятый раз! {Name}, я на тебя уже абонемент {signed}." },
    many = "Встреча номер {meet}. {Name} явно {hooked} на мой клинок.",
  },
  higher = { "На {diff} выше — и всё равно {fucked} как нуб." },
  lower = { "Мелочь пузатая, но и такую ебём.", "Лоулвл, но Альянс есть Альянс — ебём всех." },
  guild = { "Гильдия «{guild}», забирайте своё обосранное тело с кладбища." },
  night = { "Ночью Альянс ебётся особенно жалко." },
  dawn = { "Утренний секс с Альянсом — лучшее начало дня." },
  short = "Игрок Альянса {name} ({cls} {from}) {fucked} в рот моим могуществом",
  shortAlly = "Игрок Альянса {name} ({cls} {from}) {fucked} моим соратником {ally}",
}

N.TEXTS = T

local function tone(t) return T[t or ""] and t or N.DEFAULT_TONE end

-- ============================ СБОРКА ============================
local VICTIM_VERBS = { "fell", "died", "dared", "saw", "lost", "paid", "destroyed", "crushed", "humiliated", "lay",
  "understood", "sent", "returned", "got", "another", "managed", "squealed", "fucked", "fuckedFull", "came", "sucked",
  "climbed", "thought", "hooked", "keen" }
local MY_VERBS = { "slew", "was", "covered", "stood", "held", "owned", "bent", "signed", "bored", "explained", "rammed",
  "great", "valiant", "moved", "pleased" }

function N.buildVars(rec, rng)
  local v = rec.victim
  local cls = D.CLASSES[v.class or ""] or D.UNKNOWN_CLASS
  local gv, gm = g(v.sex), g(rec.mySex)
  local fem = gv == 2
  local vars = {
    name = v.name or "безымянный",
    cls = fem and cls.f or cls.m,
    clsAcc = fem and cls.af or cls.am,
    from = D.RACES[v.race or ""] or "из рядов Альянса",
    epi = pick(rng, D.EPITHETS[v.class or ""] or D.GENERIC_EPITHETS),
    place = rec.zone and D.ZONES[rec.zone] or pick(rng, D.GENERIC_PLACES),
    me = (rec.hero or ""):match("^([^%-]+)") or "герой Орды",
    ally = rec.allyName or "из моей группы",
    spell = rec.spells and rec.spells[1] or "",
    streak = tostring(rec.streak or 0),
    meet = tostring(rec.meet or 1),
    guild = v.guild or "",
  }
  for _, k in ipairs(VICTIM_VERBS) do vars[k] = D.VERBS[k][gv] end
  for _, k in ipairs(MY_VERBS) do vars[k] = D.VERBS[k][gm] end
  local d = (v.level and rec.myLevel) and (v.level - rec.myLevel) or 0
  vars.diff = d .. " " .. plural(d, "уровень", "уровня", "уровней")
  return vars
end

-- Полный текст для книги
function N.build(rec, toneName)
  local t = T[tone(toneName)]
  local rng = makeRng(rec.id or "?")
  local vars = N.buildVars(rec, rng)
  local parts = {}
  local function add(list) if list then parts[#parts + 1] = fill(pick(rng, list), vars) end end

  if rec.killer == "ally" then
    add(t.ally)
  elseif rec.spells and rec.spells[1] and rng(2) == 1 then
    add(t.spell)
  else
    add(t.kill)
  end
  local s = rec.streak or 0
  if rec.killer ~= "ally" and s >= 2 then add(t.streak[s] or (s >= 4 and t.streak.big) or nil) end
  local m = rec.meet or 1
  if t.meet[m] then add(t.meet[m]) elseif m >= 3 then parts[#parts + 1] = fill(t.meet.many, vars) end
  local vl, ml = rec.victim.level, rec.myLevel
  if vl and ml and vl > 0 and ml > 0 then
    if vl - ml >= 1 then add(t.higher) elseif vl - ml <= -10 then add(t.lower) end
  end
  if rec.victim.guild and rec.victim.guild ~= "" then add(t.guild) end
  local h = rec.hour
  if h then
    if h >= 23 or h < 5 then add(t.night) elseif h < 8 then add(t.dawn) end
  end
  return table.concat(parts, " ")
end

-- Одна фраза для чата (себе, гильдии или группе)
function N.short(rec, toneName)
  local t = T[tone(toneName)]
  local vars = N.buildVars(rec, makeRng((rec.id or "?") .. ":short"))
  local zone = rec.zone and rec.zone ~= "" and (" (" .. rec.zone .. ")") or ""
  local line = fill(rec.killer == "ally" and t.shortAlly or t.short, vars) .. zone .. "."
  local s = rec.streak or 0
  if rec.killer ~= "ally" and s >= 2 then line = line .. " Серия: " .. s .. "!" end
  return line
end

return N
