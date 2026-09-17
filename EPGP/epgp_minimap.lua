local LDB      = LibStub("LibDataBroker-1.1")
local LDBIcon  = LibStub("LibDBIcon-1.0")

local LDB_NAME    = "EPGP_MinimapLDB"
local ICON_LABEL  = "EPGP_Minimap"

local function GetMinimapSV()
  if _G.EPGP and EPGP.db and EPGP.db.profile then
    EPGP.db.profile.minimap = EPGP.db.profile.minimap or { hide = false }
    return EPGP.db.profile.minimap
  else
    EPGP_DB = EPGP_DB or {}
    EPGP_DB.minimap = EPGP_DB.minimap or { hide = false }
    return EPGP_DB.minimap
  end
end

local function CallEPGPSlash(msg)
  if _G.EPGP and type(EPGP.ChatCommand) == "function" then
    local ok = pcall(function() EPGP:ChatCommand(msg or "") end)
    if ok then return true end
  end
  local sl = _G.SlashCmdList
  if sl then
    for _, key in ipairs({ "EPGP", "ACECONSOLE_EPGP", "EPGP_CONSOLE" }) do
      if type(sl[key]) == "function" then
        local ok = pcall(sl[key], msg or "")
        if ok then return true end
      end
    end
  end
  return false
end

local function ToggleEPGPFrameDirect()
  local f = _G.EPGPFrame
  if f then
    if f:IsShown() then f:Hide() else f:Show() end
    return true
  end
  return false
end

local function OpenOptionsFallback()
  if InterfaceOptionsFrame_OpenToCategory then
    InterfaceOptionsFrame_OpenToCategory("EPGP")
    InterfaceOptionsFrame_OpenToCategory("EPGP")
  end
end

local dataobj = LDB:NewDataObject(LDB_NAME, {
  type  = "launcher",
  icon  = "Interface\\AddOns\\EPGP\\images\\doge_meme",
  label = "EPGP",
  OnClick = function(_, button)
    if button == "LeftButton" then
      if not CallEPGPSlash("") then
        ToggleEPGPFrameDirect()
      end
    elseif button == "RightButton" then
      if _G.EPGP and type(EPGP.OpenConfig) == "function" then
        pcall(function() EPGP:OpenConfig() end)
      elseif not CallEPGPSlash("config") then
        if InCombatLockdown() then
          UIErrorsFrame:AddMessage("EPGP: настройки откроются после боя.", 1, 0.2, 0.2)
          local w = CreateFrame("Frame")
          w:RegisterEvent("PLAYER_REGEN_ENABLED")
          w:SetScript("OnEvent", function(self)
            self:UnregisterEvent("PLAYER_REGEN_ENABLED")
            OpenOptionsFallback()
          end)
        else
          OpenOptionsFallback()
        end
      end
    end
  end,
  OnTooltipShow = function(tt)
    tt:AddLine("EPGP")
    tt:AddLine("|cffffff00ЛКМ|r — открыть/закрыть")
    tt:AddLine("|cffffff00ПКМ|r — настройки")
  end,
})

-- Регистрируем иконку после полной загрузки UI
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
  LDBIcon:Register(ICON_LABEL, dataobj, GetMinimapSV())
  -- Если вдруг она была скрыта в SavedVariables, покажем подсказку в чат:
  if GetMinimapSV().hide then
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99EPGP|r: иконка скрыта. /run LibStub('LibDBIcon-1.0'):Show('"..ICON_LABEL.."')")
  end
end)