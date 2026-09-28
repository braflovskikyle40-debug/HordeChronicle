-- Баннер победы вверху экрана: свиток с кроваво-красной каймой, 6 секунд.
local _, ns = ...

local T = {}
ns.Toast = T

local SHOW_SECONDS = 6

local function build()
  local f = CreateFrame("Frame", "HordeChronicleToast", UIParent, "BackdropTemplate")
  f:SetSize(560, 96)
  f:SetPoint("TOP", UIParent, "TOP", 0, -140)
  f:SetFrameStrata("HIGH")
  f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
    tile = true, tileSize = 32, edgeSize = 24,
    insets = { left = 6, right = 6, top = 6, bottom = 6 },
  })
  f:SetBackdropColor(0.25, 0.02, 0.02, 0.92)
  f:SetBackdropBorderColor(0.8, 0.1, 0.05, 1)

  local icon = f:CreateTexture(nil, "ARTWORK")
  icon:SetSize(52, 52)
  icon:SetPoint("LEFT", 18, 0)
  icon:SetTexture("Interface\\Icons\\Achievement_PVP_H_16")
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 14, 0)
  title:SetText("Летопись Орды")
  title:SetTextColor(1, 0.3, 0.2)

  local text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
  text:SetPoint("RIGHT", f, "RIGHT", -18, 0)
  text:SetJustifyH("LEFT")
  text:SetWordWrap(true)
  f.text = text

  f:EnableMouse(true)
  f:SetScript("OnMouseUp", function() f:Hide(); if ns.Book then ns.Book.show() end end)
  f:Hide()
  return f
end

function T.show(rec)
  T.frame = T.frame or build()
  local f = T.frame
  f.text:SetText(rec.short or "")
  f:SetAlpha(1)
  f:Show()
  f.token = (f.token or 0) + 1
  local token = f.token
  C_Timer.After(SHOW_SECONDS, function()
    if f.token ~= token then return end
    if UIFrameFadeOut then
      UIFrameFadeOut(f, 0.8, 1, 0)
      C_Timer.After(0.85, function() if f.token == token then f:Hide() end end)
    else
      f:Hide()
    end
  end)
end

return T
