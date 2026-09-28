-- Книга летописи: вкладки «Летопись», «Статистика», «Настройки».
local _, ns = ...

local B = {}
ns.Book = B

local MAX_ENTRIES = 200
local ORANGE, RED, GOLD, GREY, END = "|cffffd100", "|cffff5a4a", "|cffc8a26e", "|cff9d9d9d", "|r"

B.filter = "all"     -- all | me | ally
B.search = ""
B.allHeroes = false
B.tab = "chronicle"

local function clean(s) return (tostring(s or ""):gsub("|", "/")) end

local function entryText(i, k)
  local D = ns.Data
  local cls = D.CLASSES[k.victim.class or ""] or D.UNKNOWN_CLASS
  local who = D.ucfirst(k.victim.sex == 3 and cls.f or cls.m) .. " " .. clean(k.victim.name)
  local place = clean(k.zone) .. ((k.subzone and k.subzone ~= "") and (", " .. clean(k.subzone)) or "")
  local head = ORANGE .. "№" .. i .. " · " .. (k.date or "") .. " · " .. place .. END
  local mark = k.test and (GREY .. " (тест)" .. END) or (k.killer == "ally" and (GREY .. " (добил соратник)" .. END) or "")
  local body = k.victim and ns.Narrative.build(k, ns.Core.db().settings.tone) or k.text
  local out = head .. "\n" .. RED .. who .. END .. mark .. "\n" .. clean(body)
  local saga = HordeChronicle_Sagas and HordeChronicle_Sagas[k.id]
  if saga then out = out .. "\n" .. GOLD .. "Сказание: " .. END .. clean(saga) end
  return out
end

local function visible(k, hero)
  if not B.allHeroes and k.hero ~= hero then return false end
  if B.filter == "me" and k.killer ~= "me" then return false end
  if B.filter == "ally" and k.killer ~= "ally" then return false end
  if B.search ~= "" and not (k.victim.name or ""):lower():find(B.search:lower(), 1, true) then return false end
  return true
end

local function chronicleText()
  local db, hero = ns.Core.db(), ns.Core.heroKey()
  local parts, shown = {}, 0
  for i = #db.kills, 1, -1 do
    local k = db.kills[i]
    if visible(k, hero) then
      parts[#parts + 1] = entryText(i, k)
      shown = shown + 1
      if shown >= MAX_ENTRIES then break end
    end
  end
  if shown == 0 then
    return GREY .. "Летопись пока пуста. Первая победа над Альянсом появится здесь.\nПроверить вид можно кнопкой «Тестовая победа» на вкладке «Настройки»." .. END
  end
  return table.concat(parts, "\n\n")
end

local function statsText()
  local D, db = ns.Data, ns.Core.db()
  local r = ns.Stats.compute(db.kills, B.allHeroes and nil or ns.Core.heroKey())
  local L = {}
  L[#L + 1] = ORANGE .. "Всего побед: " .. r.total .. END .. "   моих добиваний: " .. r.mine .. ", с соратниками: " .. r.ally
  L[#L + 1] = "Лучшая серия без смерти: " .. r.bestStreak
  L[#L + 1] = "\n" .. ORANGE .. "Заклятые враги" .. END
  for _, e in ipairs(r.topFoes) do L[#L + 1] = "  " .. clean(e.key) .. " — " .. e.count end
  L[#L + 1] = "\n" .. ORANGE .. "По классам" .. END
  for _, e in ipairs(r.topClasses) do
    local c = D.CLASSES[e.key]
    L[#L + 1] = "  " .. (c and D.ucfirst(c.m) or e.key) .. " — " .. e.count
  end
  L[#L + 1] = "\n" .. ORANGE .. "По расам" .. END
  for _, e in ipairs(r.topRaces) do L[#L + 1] = "  " .. (D.RACES[e.key] or e.key) .. " — " .. e.count end
  L[#L + 1] = "\n" .. ORANGE .. "Где чаще всего" .. END
  for _, e in ipairs(r.topZones) do L[#L + 1] = "  " .. clean(e.key) .. " — " .. e.count end
  if r.total == 0 then L[#L + 1] = "\n" .. GREY .. "Статистика появится после первых побед." .. END end
  return table.concat(L, "\n")
end

local function button(parent, label, w, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, 24)
  b:SetText(label)
  b:SetScript("OnClick", onClick)
  return b
end

local function checkbox(parent, label, get, set)
  local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  c:SetSize(26, 26)
  local fs = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  fs:SetPoint("LEFT", c, "RIGHT", 4, 0)
  fs:SetText(label)
  c:SetScript("OnShow", function() c:SetChecked(get()) end)
  c:SetScript("OnClick", function() set(c:GetChecked() and true or false) end)
  return c
end

local function buildSettings(parent)
  local p = CreateFrame("Frame", nil, parent)
  p:SetAllPoints()
  local s = function() return ns.Core.db().settings end
  local y = -8
  local head = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  head:SetPoint("TOPLEFT", 8, y)
  head:SetText("Куда сообщать о победе (себе — всегда):")
  y = y - 24
  local radios = {}
  for _, key in ipairs({ "self", "guild", "group" }) do
    local r = checkbox(p, ns.Announce.CHANNELS[key], function() return s().channel == key end, function()
      s().channel = key
      for _, other in ipairs(radios) do other:GetScript("OnShow")(other) end
    end)
    r:SetPoint("TOPLEFT", 12, y)
    radios[#radios + 1] = r
    y = y - 26
  end
  y = y - 8
  local toneHead = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  toneHead:SetPoint("TOPLEFT", 8, y)
  toneHead:SetText("Тон летописи (вся книга перечитывается сразу):")
  y = y - 24
  local toneRadios = {}
  for _, key in ipairs(ns.Narrative.TONES) do
    local r = checkbox(p, ns.Narrative.TONE_NAMES[key], function() return s().tone == key end, function()
      s().tone = key
      for _, other in ipairs(toneRadios) do other:GetScript("OnShow")(other) end
    end)
    r:SetPoint("TOPLEFT", 12, y)
    toneRadios[#toneRadios + 1] = r
    y = y - 26
  end
  y = y - 10
  local opts = {
    { "Мат в чат гильдии/группы (иначе туда идёт глумливый вариант)", "hardInChat" },
    { "Записывать победы, где добил соратник", "recordAlly" },
    { "Объявлять в канал и победы соратников", "announceAlly" },
    { "Показывать баннер победы", "toast" },
    { "Звук победы", "sound" },
    { "Скриншот в момент победы", "screenshot" },
  }
  for _, o in ipairs(opts) do
    local c = checkbox(p, o[1], function() return s()[o[2]] end, function(v) s()[o[2]] = v end)
    c:SetPoint("TOPLEFT", 12, y)
    y = y - 26
  end
  y = y - 14
  local t = button(p, "Тестовая победа", 170, function() ns.Core.fakeKill() end)
  t:SetPoint("TOPLEFT", 12, y)
  local clear = button(p, "Удалить тестовые записи", 200, function()
    local db, kept = ns.Core.db(), {}
    for _, k in ipairs(db.kills) do if not k.test then kept[#kept + 1] = k end end
    db.kills = kept
    ns.Announce.printSelf("Тестовые записи удалены.")
  end)
  clear:SetPoint("LEFT", t, "RIGHT", 10, 0)
  return p
end

local function build()
  local f = CreateFrame("Frame", "HordeChronicleBook", UIParent, "BasicFrameTemplateWithInset")
  f:SetSize(660, 580)
  f:SetPoint("CENTER")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetFrameStrata("DIALOG")
  tinsert(UISpecialFrames, "HordeChronicleBook")
  if f.TitleText then f.TitleText:SetText("Летопись Орды") end

  -- вкладки
  local tabs = {}
  local function setTab(name) B.tab = name; B.refresh() end
  local x = 14
  for _, t in ipairs({ { "chronicle", "Летопись" }, { "stats", "Статистика" }, { "settings", "Настройки" } }) do
    local b = button(f, t[2], 120, function() setTab(t[1]) end)
    b:SetPoint("TOPLEFT", x, -30)
    tabs[t[1]] = b
    x = x + 126
  end
  f.tabs = tabs

  -- фильтры летописи
  local bar = CreateFrame("Frame", nil, f)
  bar:SetPoint("TOPLEFT", 14, -60); bar:SetPoint("TOPRIGHT", -14, -60); bar:SetHeight(26)
  local fx = 0
  for _, fl in ipairs({ { "all", "Все" }, { "me", "Мои" }, { "ally", "Соратников" } }) do
    local b = button(bar, fl[2], 96, function() B.filter = fl[1]; B.refresh() end)
    b:SetPoint("LEFT", fx, 0)
    fx = fx + 100
  end
  local search = CreateFrame("EditBox", nil, bar, "InputBoxTemplate")
  search:SetSize(150, 22); search:SetPoint("LEFT", fx + 12, 0); search:SetAutoFocus(false)
  search:SetScript("OnTextChanged", function(self) B.search = self:GetText() or ""; B.refresh() end)
  local hint = bar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("LEFT", search, "RIGHT", 6, 0); hint:SetText("поиск по имени")
  local all = checkbox(bar, "все герои", function() return B.allHeroes end, function(v) B.allHeroes = v; B.refresh() end)
  all:SetPoint("RIGHT", -70, 0)
  f.bar = bar

  -- прокручиваемый текст
  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 16, -92)
  scroll:SetPoint("BOTTOMRIGHT", -34, 14)
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(600, 10)
  scroll:SetScrollChild(child)
  local text = child:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  text:SetPoint("TOPLEFT", 4, -4)
  text:SetWidth(592)
  text:SetJustifyH("LEFT")
  text:SetJustifyV("TOP")
  text:SetSpacing(3)
  f.scroll, f.child, f.text = scroll, child, text

  f.settings = buildSettings(f)
  f.settings:ClearAllPoints()
  f.settings:SetPoint("TOPLEFT", 14, -64)
  f.settings:SetPoint("BOTTOMRIGHT", -14, 14)
  f:Hide()
  return f
end

function B.refresh()
  local f = B.frame
  if not f or not f:IsShown() then return end
  local isSettings = B.tab == "settings"
  f.settings:SetShown(isSettings)
  f.scroll:SetShown(not isSettings)
  f.bar:SetShown(B.tab == "chronicle")
  f.scroll:ClearAllPoints()
  f.scroll:SetPoint("TOPLEFT", 16, B.tab == "chronicle" and -92 or -64)
  f.scroll:SetPoint("BOTTOMRIGHT", -34, 14)
  if isSettings then
    for _, c in ipairs({ f.settings:GetChildren() }) do local h = c:GetScript("OnShow"); if h then h(c) end end
    return
  end
  f.text:SetText(B.tab == "stats" and statsText() or chronicleText())
  f.child:SetHeight(f.text:GetStringHeight() + 16)
end

function B.show()
  B.frame = B.frame or build()
  B.frame:Show()
  B.refresh()
end

function B.toggle()
  if B.frame and B.frame:IsShown() then B.frame:Hide() else B.show() end
end

return B
