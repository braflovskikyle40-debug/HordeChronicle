-- Статистика по записям летописи. Чистые функции — тестируется в LuaJIT.
local _, ns = ...
ns = ns or {}

local S = {}
ns.Stats = S

local function inc(t, k) if k and k ~= "" then t[k] = (t[k] or 0) + 1 end end

local function top(counts, n)
  local list = {}
  for k, v in pairs(counts) do list[#list + 1] = { key = k, count = v } end
  table.sort(list, function(a, b) if a.count ~= b.count then return a.count > b.count end return a.key < b.key end)
  while #list > n do table.remove(list) end
  return list
end
S.top = top

-- kills — список записей; hero — «Имя-Мир» (nil = все герои); тестовые записи не считаются
function S.compute(kills, hero)
  local r = { total = 0, mine = 0, ally = 0, bestStreak = 0, byClass = {}, byRace = {}, byZone = {}, foes = {} }
  for _, k in ipairs(kills or {}) do
    if not k.test and (not hero or k.hero == hero) then
      r.total = r.total + 1
      if k.killer == "ally" then r.ally = r.ally + 1 else r.mine = r.mine + 1 end
      if (k.streak or 0) > r.bestStreak then r.bestStreak = k.streak end
      inc(r.byClass, k.victim and k.victim.class)
      inc(r.byRace, k.victim and k.victim.race)
      inc(r.byZone, k.zone)
      if k.victim and k.victim.name then
        local realm = k.victim.realm
        inc(r.foes, (realm and realm ~= "") and (k.victim.name .. "-" .. realm) or k.victim.name)
      end
    end
  end
  r.topFoes, r.topClasses, r.topRaces, r.topZones = top(r.foes, 5), top(r.byClass, 13), top(r.byRace, 14), top(r.byZone, 8)
  return r
end

-- Сколько раз уже побеждён этот враг (для «повторной встречи»)
function S.timesMet(kills, hero, name, realm)
  local n = 0
  for _, k in ipairs(kills or {}) do
    if not k.test and k.hero == hero and k.victim and k.victim.name == name and (k.victim.realm or "") == (realm or "") then
      n = n + 1
    end
  end
  return n
end

return S
