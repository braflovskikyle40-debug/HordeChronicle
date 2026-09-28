-- Куда сообщать о победе: себе / гильдии / группе. С защитой от спама.
-- /say и /yell не предлагаем: вне подземелий их нельзя отправить без нажатия клавиши игроком.
local _, ns = ...
ns = ns or {}

local A = {}
ns.Announce = A

A.THROTTLE = 10          -- сек между сообщениями в общий канал
A.PREFIX = "|cffb30000[Летопись Орды]|r "
A.lastSent = -1e9
A.pending = nil          -- записи, накопившиеся за время тишины

A.CHANNELS = {
  self = "только себе",
  guild = "гильдия",
  group = "группа / рейд",
}

local function sendChat(text, channel)
  local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
  send(text, channel)
end

function A.printSelf(text)
  DEFAULT_CHAT_FRAME:AddMessage(A.PREFIX .. text)
end

-- Какой игровой канал соответствует настройке; nil — отправлять некуда (напишем себе)
function A.resolve(setting)
  if setting == "guild" then
    return (IsInGuild and IsInGuild()) and "GUILD" or nil
  elseif setting == "group" then
    if IsInRaid and IsInRaid() then return "RAID" end
    if IsInGroup and LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    if IsInGroup and IsInGroup() then return "PARTY" end
  end
  return nil
end

-- Тон для общего канала: 18+ уходит туда только с отдельной галочкой — мат в общих чатах
-- легко приводит к жалобам и блокировке по правилам Blizzard; вместо него — глумливый вариант.
function A.chatTone(settings)
  if settings.tone == "hard" and not settings.hardInChat then return "mock" end
  return settings.tone
end

-- Главная функция: всегда пишет себе; в общий канал — по настройке и не чаще THROTTLE
function A.announce(rec, settings, now)
  A.printSelf(rec.short)
  if rec.test then return "self" end
  if rec.killer == "ally" and not settings.announceAlly then return "self" end
  local channel = A.resolve(settings.channel)
  if not channel then return "self" end
  now = now or GetTime()
  if now - A.lastSent < A.THROTTLE then
    A.pending = (A.pending or 0) + 1
    return "throttled"
  end
  local text = (ns.Narrative and rec.victim) and ns.Narrative.short(rec, A.chatTone(settings)) or rec.short
  if A.pending and A.pending > 0 then
    text = text .. " (и ещё " .. A.pending .. " — летопись полнится)"
    A.pending = nil
  end
  sendChat(text, channel)
  A.lastSent = now
  return channel
end

return A
