local function Setup()
----- Requires EPGP.

BINDING_HEADER_EPROLL = "EProll"
BINDING_NAME_EPROLL_AUCTION_MOUSEOVER = "Объявить предмет под курсором на аукцион"

local ADDON = "EProll"
local VERSION = "1.3.0"
local SYNC_PREFIX = "EProll"
local VERSION_CHECK_PREFIX = "EPRVER1"
local MIN_BID = 100
local MIN_STEP = 50
local AUCTION_VISIBLE_ROWS = 7
local AUCTION_ROW_HEIGHT = 16
local LOG_VISIBLE_ROWS = 7
local LOG_ROW_HEIGHT = 18
local LOOT_VISIBLE_ROWS = 6
local LOOT_ROW_HEIGHT = 36

local state = {
    active = false,
    itemLink = nil,
    itemTexture = nil,
    bids = {},
    bidOrder = 0,
    bidSequence = {},
    bidOff = {},
    excluded = {},
    bidHistory = {},
    bidHistorySeen = {},
    excludedBids = {},
    includeOff = false,
    mainBid = true,
    loot = {},
    auctionWindowVisible = false,
    owner = nil,
    itemBag = nil,
    itemSlot = nil,
    bagStartSlots = nil,
}

local frame = CreateFrame("Frame", "EProllEventFrame", UIParent)
local lootFrame
local lootScroll
local auctionFrame
local auctionScroll
local auctionRows = {}
local logFrame
local logScroll
local logRows = {}
local optionsPanel
local debugCheckBox
local allLootCheckBox
local disableChatFilterCheckBox

local function EnsureDB()
    if type(EProllDB) ~= "table" then
        EProllDB = {}
    end
    if EProllDB.debugChat == nil then
        EProllDB.debugChat = false
    end
    if EProllDB.showAllLoot == nil then
        EProllDB.showAllLoot = false
    end
    if EProllDB.disableChatFilter == nil then
        EProllDB.disableChatFilter = false
    end
end

local function IsDebugChat()
    EnsureDB()
    return EProllDB.debugChat and true or false
end

local function ShowAllLoot()
    EnsureDB()
    return EProllDB.showAllLoot and true or false
end

local function IsChatFilterDisabled()
    EnsureDB()
    return EProllDB.disableChatFilter and true or false
end

local function LocalPrint(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99EProll:|r " .. tostring(msg))
end

local function RawSendChat(msg, channel)
    if ChatThrottleLib and type(ChatThrottleLib.SendChatMessage) == "function" then
        ChatThrottleLib:SendChatMessage("NORMAL", "EProll", msg, channel)
    else
        _G.SendChatMessage(msg, channel)
    end
end

local function Notify(msg)
    if IsDebugChat() then
        RawSendChat("EProll: " .. tostring(msg), "SAY")
    else
        LocalPrint(msg)
    end
end

local function SendAddonChat(msg, channel)
    if IsDebugChat() then
        RawSendChat(msg, "SAY")
        return true
    end

    if channel == "RAID_WARNING" or channel == "RAID" or channel == "GUILD" or channel == "SAY" then
        RawSendChat(msg, channel)
        return true
    end

    return false
end

local function IsPlayerRaidLeaderOrAssistant()
    local player = UnitName("player")
    if not player or GetNumRaidMembers() == 0 then return false end

    for i = 1, GetNumRaidMembers() do
        local name, rank = GetRaidRosterInfo(i)
        if name == player then
            return rank == 1 or rank == 2
        end
    end
    return false
end

local function LootName(name)
    if not name then return nil end
    return string.match(name, "^[^-]+") or name
end

local function IsMasterLooterName(name)
    name = LootName(name)
    if not name then return false end

    local method, partyIndex, raidIndex = GetLootMethod()
    if method ~= "master" then return false end

    if GetNumRaidMembers() > 0 and raidIndex then
        local masterName = GetRaidRosterInfo(raidIndex)
        return LootName(masterName) == name
    end

    if GetNumPartyMembers() > 0 then
        if partyIndex == 0 then
            return LootName(UnitName("player")) == name
        elseif partyIndex and partyIndex > 0 then
            return LootName(UnitName("party" .. partyIndex)) == name
        end
    end

    return false
end

local function IsPlayerMasterLooter()
    return IsMasterLooterName(UnitName("player"))
end

local function CanManageAuction()
    if GetNumRaidMembers() == 0 then
        return true
    end
    return IsPlayerRaidLeaderOrAssistant()
end

local function ShortName(name)
    if not name then return nil end
    return string.match(name, "^[^-]+") or name
end

local function IsAuctionOwner()
    if not state.active or not state.owner then return false end
    return ShortName(state.owner) == ShortName(UnitName("player"))
end

local function SendSync(message)
    if GetNumRaidMembers() == 0 then return end
    if type(_G.SendAddonMessage) == "function" then
        _G.SendAddonMessage(SYNC_PREFIX, message, "RAID")
    end
end

local function GetEP(name)
    if not EPGP or type(EPGP.GetEPGP) ~= "function" then
        return nil
    end
    local ep = EPGP:GetEPGP(name)
    if type(ep) ~= "number" then
        return nil
    end
    return ep
end

local bagMarks
local bagSnapshot = {}
local bagVisuals = {}
local bagTrackingReady = false
local bagCharacterKey
local BAG_MARK_LIFETIME = 119 * 60
local tradeState
local recentTrade

local function ItemIdentity(link)
    if type(link) ~= "string" then return nil end
    return tonumber(string.match(link, "item:(%d+)"))
end

local function GetBagCharacterMarks()
    EnsureDB()
    EProllDB.wonBagItems = EProllDB.wonBagItems or {}
    if not bagCharacterKey then
        bagCharacterKey = (GetRealmName() or "") .. ":" .. (UnitName("player") or "")
    end
    if not EProllDB.wonBagItems[bagCharacterKey] then
        EProllDB.wonBagItems[bagCharacterKey] = {}
    end
    bagMarks = EProllDB.wonBagItems[bagCharacterKey]
    return bagMarks
end

local function EnumerateBagItems()
    local items = {}
    if type(GetContainerNumSlots) ~= "function" or type(GetContainerItemLink) ~= "function" then
        return items
    end
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        local total = GetContainerNumSlots(bag) or 0
        for slot = 1, total do
            local link = GetContainerItemLink(bag, slot)
            local itemID = ItemIdentity(link)
            if itemID then
                items[tostring(bag) .. ":" .. tostring(slot)] = {
                    bag = bag, slot = slot, itemID = itemID
                }
            end
        end
    end
    return items
end

local function TradePartnerMatches(name)
    return tradeState and tradeState.partner and ShortName(tradeState.partner) == ShortName(name)
end

local function GetMarkedItem(bag, slot)
    if not bagMarks then return nil end
    local now = time()
    for _, mark in ipairs(bagMarks) do
        if mark.bag == bag and mark.slot == slot
            and (type(mark.created) ~= "number" or now - mark.created < BAG_MARK_LIFETIME)
            and ItemIdentity(GetContainerItemLink(bag, slot)) == mark.itemID then
            return mark
        end
    end
    return nil
end

local function BagSlotForButton(button)
    local current = button
    for _ = 1, 8 do
        if not current then break end
        local bag = current.bagID or current.BagID
        local slot = current.slotID or current.SlotID
        if type(bag) ~= "number" or type(slot) ~= "number" then
            if type(current.GetID) == "function" and type(current.GetParent) == "function" then
                slot = current:GetID()
                local parent = current:GetParent()
                bag = parent and type(parent.GetID) == "function" and parent:GetID() or nil
            end
        end
        if type(bag) == "number" and type(slot) == "number" and bag >= 0 and bag <= (NUM_BAG_SLOTS or 4) then
            if type(GetContainerItemLink) == "function" and GetContainerItemLink(bag, slot) then
                return bag, slot, current
            end
        end
        current = type(current.GetParent) == "function" and current:GetParent() or nil
    end
    return nil
end

local elvBagHooked

local function GetElvBagModule()
    local root = _G.ElvUI
    if type(root) ~= "table" then return nil end
    local engine = root[1] or root
    if type(engine) ~= "table" or type(engine.GetModule) ~= "function" then return nil end
    local ok, module = pcall(engine.GetModule, engine, "Bags", true)
    if ok and type(module) == "table" then return module end
    return nil
end

local function GetBagButtonGlowLibrary()
    if not LibStub then return nil end
    local glow = LibStub("LibCustomGlow-1.0", true)
    if glow and type(glow.ButtonGlow_Start) == "function" and type(glow.ButtonGlow_Stop) == "function" then
        return glow
    end
    return nil
end

local function UpdateTradeButtonGlow(visual, enabled)
    if not visual then return end
    if not enabled then
        if visual.tradeGlowActive then
            local glow = visual.tradeGlowLibrary or GetBagButtonGlowLibrary()
            if glow then glow.ButtonGlow_Stop(visual) end
            visual.tradeGlowActive = nil
            visual.tradeGlowLibrary = nil
        end
        return
    end
    if visual.tradeGlowActive then return end
    local glow = GetBagButtonGlowLibrary()
    if glow then
        visual:Show()
        glow.ButtonGlow_Start(visual, {1, 0.85, 0.05, 1}, 0.125)
        visual.tradeGlowLibrary = glow
        visual.tradeGlowActive = true
    end
end

local function UpdateBagButtonVisual(button)
    if not button then return end
    local bag, slot = BagSlotForButton(button)
    local mark = bag and GetMarkedItem(bag, slot)
    local visual = bagVisuals[button]
    if mark then
        if not visual then
            visual = CreateFrame("Frame", nil, button)
            visual:SetAllPoints(button)
            visual:SetFrameLevel(button:GetFrameLevel() + 4)
            visual:EnableMouse(false)
            local sides = {
                {"TOPLEFT", "TOPRIGHT", 0, -1, 0, -1, true},
                {"BOTTOMLEFT", "BOTTOMRIGHT", 0, 1, 0, 1, true},
                {"TOPLEFT", "BOTTOMLEFT", 1, 0, 1, 0, false},
                {"TOPRIGHT", "BOTTOMRIGHT", -1, 0, -1, 0, false}
            }
            for _, side in ipairs(sides) do
                local edge = visual:CreateTexture(nil, "OVERLAY")
                edge:SetTexture("Interface\\Buttons\\WHITE8X8")
                edge:SetVertexColor(0.1, 1, 0.18, 1)
                edge:SetPoint(side[1], visual, side[1], side[3], side[4])
                edge:SetPoint(side[2], visual, side[2], side[5], side[6])
                if side[7] then
                    edge:SetHeight(3)
                else
                    edge:SetWidth(3)
                end
            end
            local tag = visual:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            tag:SetPoint("CENTER", visual, "CENTER", 0, 0)
            tag:SetText("EP")
            tag:SetTextColor(1, 0.1, 0.1)
            tag:SetShadowColor(0, 0, 0, 1)
            tag:SetShadowOffset(1, -1)
            visual.tag = tag
            visual:SetScript("OnHide", function(self)
                UpdateTradeButtonGlow(self, false)
            end)
            bagVisuals[button] = visual
        end
        visual:Show()
        UpdateTradeButtonGlow(visual, TradePartnerMatches(mark.winner))
    elseif visual then
        UpdateTradeButtonGlow(visual, false)
        visual:Hide()
    end
end

local function RefreshBagVisuals()
    for frameIndex = 1, (NUM_CONTAINER_FRAMES or 13) do
        for itemIndex = 1, (MAX_CONTAINER_ITEMS or 36) do
            local button = _G["ContainerFrame" .. frameIndex .. "Item" .. itemIndex]
            if button then
                UpdateBagButtonVisual(button)
            end
        end
    end
    local module = GetElvBagModule()
    if module and module.BagFrame and module.BagFrame.Bags then
        for bag = 0, (NUM_BAG_SLOTS or 4) do
            local slots = module.BagFrame.Bags[bag]
            if slots then
                for slot = 1, (GetContainerNumSlots(bag) or 0) do
                    UpdateBagButtonVisual(slots[slot])
                end
            end
        end
    else
        for bag = 0, (NUM_BAG_SLOTS or 4) do
            for slot = 1, (GetContainerNumSlots(bag) or 0) do
                local button = _G["ElvUI_ContainerFrameBag" .. bag .. "Slot" .. slot]
                if button then
                    UpdateBagButtonVisual(button)
                end
            end
        end
    end
    if module and not elvBagHooked and type(hooksecurefunc) == "function" and type(module.UpdateSlot) == "function" then
        hooksecurefunc(module, "UpdateSlot", function(self, bagFrame, bag, slot)
            if bagFrame == self.BagFrame and bagFrame.Bags and bagFrame.Bags[bag] then
                UpdateBagButtonVisual(bagFrame.Bags[bag][slot])
            end
        end)
        if type(module.Layout) == "function" then
            hooksecurefunc(module, "Layout", RefreshBagVisuals)
        end
        if type(module.OpenBags) == "function" then
            hooksecurefunc(module, "OpenBags", RefreshBagVisuals)
        end
        elvBagHooked = true
    end
end

local function RefreshWonBagItems()
    if not bagTrackingReady then return end
    local marks = GetBagCharacterMarks()
    local current = EnumerateBagItems()
    local occupied = {}
    local now = time()
    for i = #marks, 1, -1 do
        local mark = marks[i]
        if type(mark) ~= "table" or not mark.itemID or not mark.winner then
            table.remove(marks, i)
        elseif ShortName(mark.winner) == ShortName(UnitName("player")) then
            table.remove(marks, i)
        elseif type(mark.created) == "number" and now - mark.created >= BAG_MARK_LIFETIME then
            table.remove(marks, i)
        end
    end
    for _, mark in ipairs(marks) do
        if mark.bag ~= nil and mark.slot ~= nil then
            local key = tostring(mark.bag) .. ":" .. tostring(mark.slot)
            local item = current[key]
            if item and item.itemID == mark.itemID and not occupied[key] then
                occupied[key] = true
                mark.missingSince = nil
            else
                mark.bag = nil
                mark.slot = nil
                mark.missingSince = mark.missingSince or now
            end
        end
    end
    local function FreeSlot(mark, preferFresh)
        for bag = 0, (NUM_BAG_SLOTS or 4) do
            local count = GetContainerNumSlots(bag) or 0
            for slot = 1, count do
                local key = tostring(bag) .. ":" .. tostring(slot)
                local item = current[key]
                if item and item.itemID == mark.itemID and not occupied[key] then
                    local old = bagSnapshot[key]
                    if not preferFresh or not old or old.itemID ~= item.itemID then
                        return item, key
                    end
                end
            end
        end
        return nil
    end
    for _, mark in ipairs(marks) do
        if mark.bag == nil then
            local found, key
            if mark.bagAtWin ~= nil and mark.slotAtWin ~= nil then
                local origin = tostring(mark.bagAtWin) .. ":" .. tostring(mark.slotAtWin)
                if current[origin] and current[origin].itemID == mark.itemID and not occupied[origin] then
                    found, key = current[origin], origin
                end
            end
            if not found then
                found, key = FreeSlot(mark, true)
            end
            if not found and not mark.waitNewItem then
                found, key = FreeSlot(mark, false)
            end
            if found then
                mark.bag = found.bag
                mark.slot = found.slot
                mark.missingSince = nil
                mark.waitNewItem = nil
                occupied[key] = true
            elseif (mark.missingSince and now - mark.missingSince > 45)
                or (not mark.missingSince and now - (mark.created or now) > 14400) then
                mark.expiredMissing = true
            end
        end
    end
    for i = #marks, 1, -1 do
        if marks[i].expiredMissing then
            table.remove(marks, i)
        end
    end
    bagSnapshot = current
    RefreshBagVisuals()
end

local function RecordWonItem(link, winner, amount)
    if not IsAuctionOwner() then return end
    if ShortName(winner) == ShortName(UnitName("player")) then return end
    local itemID = ItemIdentity(link)
    if not itemID then return end
    RefreshWonBagItems()
    local marks = GetBagCharacterMarks()
    local mark = {
        itemID = itemID,
        winner = winner,
        amount = amount,
        created = time(),
        bagAtWin = state.itemBag,
        slotAtWin = state.itemSlot,
        waitNewItem = state.itemBag == nil
    }
    if state.itemBag == nil then
        local current = EnumerateBagItems()
        local atStart = state.bagStartSlots or {}
        local occupied = {}
        for _, previous in ipairs(marks) do
            if previous.bag ~= nil and previous.slot ~= nil then
                occupied[tostring(previous.bag) .. ":" .. tostring(previous.slot)] = true
            end
        end
        local candidate
        for bag = 0, (NUM_BAG_SLOTS or 4) do
            for slot = 1, (GetContainerNumSlots(bag) or 0) do
                local key = tostring(bag) .. ":" .. tostring(slot)
                local item = current[key]
                if item and item.itemID == itemID and not occupied[key] then
                    local old = atStart[key]
                    if not old or old.itemID ~= itemID then
                        candidate = item
                        break
                    end
                    if not candidate then
                        candidate = item
                    end
                end
            end
            if candidate then break end
        end
        if candidate then
            mark.bagAtWin = candidate.bag
            mark.slotAtWin = candidate.slot
            mark.waitNewItem = false
        end
    end
    table.insert(marks, mark)
    RefreshWonBagItems()
end

local function TradePartnerName()
    local name = UnitName("NPC")
    if not name and _G.TradeFrameRecipientNameText then
        name = _G.TradeFrameRecipientNameText:GetText()
    end
    return name
end

local function CaptureTradeOffer()
    if not tradeState or type(GetTradePlayerItemLink) ~= "function" then return end
    local offered = {}
    for slot = 1, (MAX_TRADABLE_ITEMS or 6) do
        local link = GetTradePlayerItemLink(slot)
        local itemID = ItemIdentity(link)
        if itemID then
            local quantity = 1
            if type(GetTradePlayerItemInfo) == "function" then
                local _, _, amount = GetTradePlayerItemInfo(slot)
                if type(amount) == "number" and amount > 0 then
                    quantity = amount
                end
            end
            offered[itemID] = (offered[itemID] or 0) + quantity
        end
    end
    tradeState.offered = offered
end

local function CompleteMarkedTrade(info)
    if not info or not info.partner or info.completed then return end
    info.completed = true
    local marks = GetBagCharacterMarks()
    for itemID, count in pairs(info.offered or {}) do
        local remaining = count
        for i = #marks, 1, -1 do
            local mark = marks[i]
            if remaining <= 0 then break end
            if mark.itemID == itemID and ShortName(mark.winner) == ShortName(info.partner) then
                table.remove(marks, i)
                remaining = remaining - 1
            end
        end
    end
    RefreshWonBagItems()
end

local function IsTradeCompleteMessage(...)
    local code = _G.ERR_TRADE_COMPLETE
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if value == "ERR_TRADE_COMPLETE" or (code and value == code) then
            return true
        end
    end
    return false
end

local function CountBagItemCopies()
    local counts = {}
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            local itemID = ItemIdentity(GetContainerItemLink(bag, slot))
            if itemID then
                local quantity = 1
                if type(GetContainerItemInfo) == "function" then
                    local _, count = GetContainerItemInfo(bag, slot)
                    if type(count) == "number" and count > 0 then
                        quantity = count
                    end
                end
                counts[itemID] = (counts[itemID] or 0) + quantity
            end
        end
    end
    return counts
end

local function BeginMarkedTrade()
    RefreshWonBagItems()
    tradeState = { partner = TradePartnerName(), offered = {}, started = GetTime(), before = CountBagItemCopies() }
    recentTrade = nil
    CaptureTradeOffer()
    RefreshBagVisuals()
end

local function UpdateMarkedTrade()
    if not tradeState then return end
    tradeState.partner = tradeState.partner or TradePartnerName()
    CaptureTradeOffer()
    RefreshBagVisuals()
end

local function EndMarkedTrade()
    if not tradeState then return end
    if not next(tradeState.offered or {}) and tradeState.acceptedOffer then
        tradeState.offered = tradeState.acceptedOffer
    end
    recentTrade = tradeState
    recentTrade.closedAt = GetTime()
    tradeState = nil
    RefreshBagVisuals()
end

local function AddWinnerTooltip(tooltip, mark)
    if not mark then return end
    local text = "Отдать - " .. tostring(mark.winner)
    local name = tooltip:GetName()
    if name then
        for i = 1, tooltip:NumLines() do
            local line = _G[name .. "TextLeft" .. i]
            if line and line:GetText() == text then
                return
            end
        end
    end
    tooltip:AddLine(text, 1, 0.2, 0.2)
    tooltip:Show()
end

local function InstallBagTracking()
    if bagTrackingReady then return end
    GetBagCharacterMarks()
    bagTrackingReady = true
    bagSnapshot = EnumerateBagItems()
    if GameTooltip and type(GameTooltip.HookScript) == "function" then
        GameTooltip:HookScript("OnTooltipSetItem", function(self)
            local bag, slot = BagSlotForButton(self:GetOwner())
            AddWinnerTooltip(self, bag and GetMarkedItem(bag, slot))
        end)
    end
    if GameTooltip and type(hooksecurefunc) == "function" and type(GameTooltip.SetBagItem) == "function" then
        hooksecurefunc(GameTooltip, "SetBagItem", function(self, bag, slot)
            AddWinnerTooltip(self, GetMarkedItem(bag, slot))
        end)
    end
    if type(hooksecurefunc) == "function" and type(ContainerFrame_Update) == "function" then
        hooksecurefunc("ContainerFrame_Update", RefreshBagVisuals)
    end
    RefreshWonBagItems()
end

local function IsBidExcluded(name, sequence)
    if name and state.excluded[name] then
        return true
    end
    if sequence and state.excludedBids[sequence] then
        return true
    end
    return false
end

local function GetSortedBids()
    local t = {}
    for name, amount in pairs(state.bids) do
        table.insert(t, {
            name = name,
            amount = amount,
            sequence = state.bidSequence[name] or 0,
            isOff = state.bidOff[name] and true or false,
        })
    end

    table.sort(t, function(a, b)
        if not state.includeOff and a.isOff ~= b.isOff then
            return not a.isOff
        end
        if a.amount ~= b.amount then
            return a.amount > b.amount
        end
        if a.sequence ~= b.sequence then
            return a.sequence < b.sequence
        end
        return a.name < b.name
    end)

    return t
end


local function GetPlayerClassToken(name)
    name = ShortName(name)
    if not name then return nil end

    if ShortName(UnitName("player")) == name then
        local _, classToken = UnitClass("player")
        return classToken
    end

    for i = 1, GetNumRaidMembers() do
        local raidName, _, _, _, _, classToken = GetRaidRosterInfo(i)
        if ShortName(raidName) == name then
            return classToken
        end
    end

    for i = 1, GetNumPartyMembers() do
        local unit = "party" .. i
        if ShortName(UnitName(unit)) == name then
            local _, classToken = UnitClass(unit)
            return classToken
        end
    end

    return nil
end

local function SetClassColoredName(fontString, name)
    fontString:SetText(name or "")
    local classToken = GetPlayerClassToken(name)
    local color = classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
    if color then
        fontString:SetTextColor(color.r, color.g, color.b)
    else
        fontString:SetTextColor(1, 1, 1)
    end
end

local function GetLeadingBid()
    local sorted = GetSortedBids()
    for i = 1, #sorted do
        if not IsBidExcluded(sorted[i].name, sorted[i].sequence) then
            return sorted[i]
        end
    end
    return nil
end

local function HighestOtherBid(name, isOff)
    local highest = nil
    for bidder, amount in pairs(state.bids) do
        local sequence = state.bidSequence[bidder]
        local samePriority = state.includeOff or ((state.bidOff[bidder] and true or false) == (isOff and true or false))
        if bidder ~= name and not IsBidExcluded(bidder, sequence) and samePriority and (not highest or amount > highest) then
            highest = amount
        end
    end
    return highest
end

local function HasOffMarker(message)
    if not message then return false end
    local normalized = tostring(message)
    normalized = string.gsub(normalized, "О", "о")
    normalized = string.gsub(normalized, "Ф", "ф")
    normalized = string.lower(normalized)
    normalized = string.gsub(normalized, "%d", " ")
    normalized = string.gsub(normalized, "[%s%p]+", " ")

    for token in string.gmatch(normalized, "%S+") do
        if token == "оф" or token == "офф" or token == "of" or token == "off" then
            return true
        end
    end
    return false
end

local function StripOffMarkers(message)
    local normalized = tostring(message or "")
    normalized = string.gsub(normalized, "О", "о")
    normalized = string.gsub(normalized, "Ф", "ф")
    normalized = string.lower(normalized)
    normalized = string.gsub(normalized, "офф", "")
    normalized = string.gsub(normalized, "оф", "")
    normalized = string.gsub(normalized, "off", "")
    normalized = string.gsub(normalized, "of", "")
    return normalized
end

local function NormalizeAmountText(text)
    text = tostring(text or "")
    text = string.gsub(text, "К", "к")
    text = string.gsub(text, "к", "k")
    text = string.lower(text)
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    return text
end

local function ParseAmountText(text)
    text = NormalizeAmountText(text)
    if text == "" then return nil end

    local hasK = false
    local body = string.match(text, "^(.-)%s*k%s*$")
    if body then
        hasK = true
        text = body
        text = string.gsub(text, "^%s+", "")
        text = string.gsub(text, "%s+$", "")
    end

    if text == "" or not string.match(text, "^%d") or not string.match(text, "%d$") then
        return nil
    end
    if string.find(text, "[^%d%s%p]") then
        return nil
    end

    local groups = {}
    for digits in string.gmatch(text, "%d+") do
        table.insert(groups, digits)
    end
    if #groups == 0 then return nil end

    if hasK then
        if #groups == 1 then
            local value = tonumber(groups[1])
            return value and math.floor(value * 1000) or nil
        end
        if #groups == 2 and string.len(groups[2]) <= 3 then
            local whole = tonumber(groups[1]) or 0
            local fraction = tonumber(groups[2]) or 0
            local scale = 10 ^ (3 - string.len(groups[2]))
            return math.floor(whole * 1000 + fraction * scale)
        end
    end

    if #groups == 1 then
        local value = tonumber(groups[1])
        return value and math.floor(value) or nil
    end

    if #groups == 2 and string.len(groups[2]) <= 3 then
        local whole = tonumber(groups[1]) or 0
        local fraction = tonumber(groups[2]) or 0
        local scale = 10 ^ (3 - string.len(groups[2]))
        return math.floor(whole * 1000 + fraction * scale)
    end

    local joined = table.concat(groups, "")
    local value = tonumber(joined)
    return value and math.floor(value) or nil
end

local function FirstAmountText(message)
    local text = NormalizeAmountText(message)
    local startPos = string.find(text, "%d")
    if not startPos then return nil end
    text = string.sub(text, startPos)
    return string.match(text, "^(%d[%d%s%p]*k?)")
end

local function ParseBidMessage(message)
    if not message then return nil, nil end

    local isOff = HasOffMarker(message)

    if IsChatFilterDisabled() then
        local amount = ParseAmountText(FirstAmountText(message))
        if amount then
            return amount, isOff
        end
        return nil, nil
    end

    local numericPart = StripOffMarkers(message)
    local amount = ParseAmountText(numericPart)
    if amount then
        return amount, isOff
    end

    return nil, nil
end

local function IsOwnAddonChatMessage(message)
    local text = tostring(message or "")
    if string.find(text, "Минимальный шаг", 1, true) then return true end
    if string.find(text, "Недостаточно EP", 1, true) then return true end
    if string.find(text, "Аукцион завершён", 1, true) then return true end
    if string.find(text, "Аукцион:", 1, true) == 1 then return true end
    if string.find(text, "EProll:", 1, true) == 1 then return true end
    return false
end

local function GetOfficerNote(name)
    name = ShortName(name)
    if not name then return nil end

    local lookupName = name
    if EPGP and type(EPGP.GetEPGP) == "function" then
        local _, _, main = EPGP:GetEPGP(name)
        if main and main ~= "" then
            lookupName = ShortName(main) or main
        end
    end

    local count = GetNumGuildMembers and GetNumGuildMembers(true) or 0
    for i = 1, count do
        local guildName, _, _, _, _, _, _, officerNote = GetGuildRosterInfo(i)
        if ShortName(guildName) == lookupName then
            return officerNote or ""
        end
    end

    return nil
end

local function TrimText(text)
    text = tostring(text or "")
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    return text
end

local function GetSpecText(name)
    local note = GetOfficerNote(name)
    if not note or note == "" then
        return "-/-"
    end

    local _, mainSpec, offSpec = string.match(note, "^([^,]*),([^,]*),([^,]*)")
    mainSpec = TrimText(mainSpec)
    offSpec = TrimText(offSpec)
    if mainSpec == "" then mainSpec = "-" end
    if offSpec == "" then offSpec = "-" end
    return mainSpec .. "/" .. offSpec
end

local function GetItemTexture(link)
    if not link then return nil end
    local _, _, _, _, _, _, _, _, _, texture = GetItemInfo(link)
    return texture
end

local function SetItemButton(button, link, texture)
    button.itemLink = link
    if button.icon then
        button.icon:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
    end
end

local function UpdateManualDeductControls()
    if not auctionFrame then return end

    local visible = IsAuctionOwner() and CanManageAuction()

    if auctionFrame.controls then
        auctionFrame.controls:SetHeight(56)
    end

    if auctionFrame.manualEPBox then
        if visible then
            auctionFrame.manualEPBox:Show()
        else
            auctionFrame.manualEPBox:Hide()
        end
    end

    if auctionFrame.manualEPButton then
        if visible then
            auctionFrame.manualEPButton:Show()
        else
            auctionFrame.manualEPButton:Hide()
        end

        local text = auctionFrame.manualEPBox and auctionFrame.manualEPBox:GetText() or ""
        local amount = string.match(text, "^%d+$") and tonumber(text) or nil
        if visible and amount and amount > 0 then
            auctionFrame.manualEPButton:Enable()
        else
            auctionFrame.manualEPButton:Disable()
        end
    end
end

local function RefreshAuctionFrame()
    if not auctionFrame then return end

    if not state.active then
        state.auctionWindowVisible = false
        auctionFrame:Hide()
        return
    end

    if state.auctionWindowVisible then
        auctionFrame:Show()
    else
        auctionFrame:Hide()
    end

    auctionFrame.itemText:SetText(state.itemLink or "-")
    SetItemButton(auctionFrame.itemButton, state.itemLink, state.itemTexture)

    if auctionFrame.winnerButton then
        if IsAuctionOwner() and CanManageAuction() then
            auctionFrame.winnerButton:Enable()
        else
            auctionFrame.winnerButton:Disable()
        end
    end

    UpdateManualDeductControls()

    if auctionFrame.offCheckBox then
        auctionFrame.offCheckBox:SetChecked(state.includeOff and true or false)
        if IsAuctionOwner() then
            auctionFrame.offCheckBox:Show()
            auctionFrame.offCheckBox:Enable()
        else
            auctionFrame.offCheckBox:Hide()
        end
    end

    if auctionFrame.mainCheckBox then
        auctionFrame.mainCheckBox:SetChecked(state.mainBid and true or false)
    end

    local sorted = GetSortedBids()
    local total = #sorted
    FauxScrollFrame_Update(auctionScroll, total, AUCTION_VISIBLE_ROWS, AUCTION_ROW_HEIGHT)
    local offset = FauxScrollFrame_GetOffset(auctionScroll)

    for i = 1, AUCTION_VISIBLE_ROWS do
        local row = auctionRows[i]
        local entry = sorted[i + offset]
        if entry then
            row.rank:SetText(tostring(i + offset) .. ".")
            row.entryName = entry.name
            row.entryIsOff = entry.isOff
            SetClassColoredName(row.name, entry.name)
            row.bid:SetText(tostring(entry.amount))
            if entry.isOff and not state.includeOff then
                row.rank:SetTextColor(0.55, 0.55, 0.55)
                row.name:SetTextColor(0.55, 0.55, 0.55)
                row.bid:SetTextColor(0.55, 0.55, 0.55)
            else
                row.rank:SetTextColor(1, 1, 1)
                row.bid:SetTextColor(1, 1, 1)
            end
            if IsBidExcluded(entry.name, entry.sequence) then
                row.selection:Show()
            else
                row.selection:Hide()
            end
            row:Show()
        else
            row.entryName = nil
            row.entryIsOff = nil
            row.rank:SetText("")
            row.rank:SetTextColor(1, 1, 1)
            row.name:SetText("")
            row.name:SetTextColor(1, 1, 1)
            row.bid:SetText("")
            row.bid:SetTextColor(1, 1, 1)
            row.selection:Hide()
            row:Hide()
        end
    end

    if total == 0 then
        auctionFrame.status:SetText("Ставок пока нет")
    else
        local leader = GetLeadingBid()
        if leader then
            local nameText = leader.name
            local classToken = GetPlayerClassToken(leader.name)
            local color = classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
            if color then
                local r = math.floor((color.r or 1) * 255 + 0.5)
                local g = math.floor((color.g or 1) * 255 + 0.5)
                local b = math.floor((color.b or 1) * 255 + 0.5)
                nameText = string.format("|cff%02x%02x%02x%s|r", r, g, b, leader.name)
            end
            auctionFrame.status:SetText(string.format("%s - %d EP", nameText, leader.amount))
        else
            auctionFrame.status:SetText("Нет допущенных ставок")
        end
    end
end

local function EndAuctionLocal()
    state.active = false
    state.itemLink = nil
    state.itemTexture = nil
    state.owner = nil
    state.itemBag = nil
    state.itemSlot = nil
    state.bagStartSlots = nil
    wipe(state.bids)
    wipe(state.bidSequence)
    wipe(state.bidOff)
    wipe(state.excluded)
    wipe(state.bidHistory)
    wipe(state.bidHistorySeen)
    wipe(state.excludedBids)
    state.includeOff = false
    state.mainBid = true
    state.bidOrder = 0
    if auctionFrame and auctionFrame.manualEPBox then
        auctionFrame.manualEPBox:SetText("")
        auctionFrame.manualEPBox:ClearFocus()
    end
    if logFrame then
        logFrame:Hide()
    end
    RefreshAuctionFrame()
end

local function StartAuction(itemLink, texture, bag, slot)
    if not itemLink then
        Notify("Не удалось получить ссылку на предмет.")
        return
    end

    if not CanManageAuction() then
        Notify("Начать аукцион может только лидер рейда или помощник.")
        return
    end

    if state.active then
        Notify("Сначала завершите текущий аукцион: " .. (state.itemLink or ""))
        return
    end

    state.active = true
    state.itemLink = itemLink
    state.itemTexture = texture or GetItemTexture(itemLink)
    state.owner = UnitName("player")
    state.itemBag = bag
    state.itemSlot = slot
    state.bagStartSlots = EnumerateBagItems()
    state.auctionWindowVisible = true
    wipe(state.bids)
    wipe(state.bidSequence)
    wipe(state.bidOff)
    wipe(state.excluded)
    wipe(state.bidHistory)
    wipe(state.bidHistorySeen)
    wipe(state.excludedBids)
    state.includeOff = false
    state.mainBid = true
    state.bidOrder = 0

    if logFrame then
        logFrame:Hide()
    end

    SendAddonChat("Аукцион: " .. itemLink, "RAID_WARNING")
    SendSync("S\t" .. itemLink)

    RefreshAuctionFrame()
end

local function RejectMinStep(name)
    if CanManageAuction() then
        SendAddonChat(name .. " Минимальный шаг " .. MIN_STEP, "RAID")
    end
end

local function RejectInsufficientEP(name)
    if CanManageAuction() then
        SendAddonChat(name .. " Недостаточно EP", "RAID")
    end
end

local function AddBidHistoryEntry(name, amount, isOff, sequence)
    if not sequence or state.bidHistorySeen[sequence] then return end
    state.bidHistorySeen[sequence] = true
    table.insert(state.bidHistory, {
        name = name,
        amount = amount,
        isOff = isOff and true or false,
        sequence = sequence,
    })
    table.sort(state.bidHistory, function(a, b)
        return (a.sequence or 0) < (b.sequence or 0)
    end)
end

local function HandleBid(message, sender)
    if not state.active then return end
    if not IsAuctionOwner() then return end
    if not CanManageAuction() then return end
    if not message or not sender then return end
    if IsOwnAddonChatMessage(message) then return end

    local amount, isOff = ParseBidMessage(message)
    if not amount then return end

    if amount < MIN_BID then
        RejectMinStep(sender)
        return
    end

    local oldBid = state.bids[sender]
    local oldSequence = state.bidSequence[sender]
    local oldIsOff = state.bidOff[sender] and true or false
    local highestOther = nil

    if not state.excluded[sender] then
        highestOther = HighestOtherBid(sender, isOff)
    end

    if oldBid and oldIsOff == isOff and not IsBidExcluded(sender, oldSequence) then
        local oldRequired = MIN_BID
        if highestOther then
            oldRequired = math.max(oldRequired, highestOther + MIN_STEP)
        end
        if oldBid >= oldRequired then
            return
        end
    end

    local required = MIN_BID
    if not state.excluded[sender] and highestOther then
        required = math.max(required, highestOther + MIN_STEP)
    end

    if amount < required then
        RejectMinStep(sender)
        return
    end

    if oldBid and oldIsOff == isOff then
        if amount == oldBid then
            return
        end
        if math.abs(amount - oldBid) < MIN_STEP then
            RejectMinStep(sender)
            return
        end
    end

    local ep = GetEP(sender)
    if not ep or ep < amount then
        RejectInsufficientEP(sender)
        return
    end

    state.bidOrder = state.bidOrder + 1
    state.bids[sender] = amount
    state.bidOff[sender] = isOff and true or nil
    state.bidSequence[sender] = state.bidOrder
    AddBidHistoryEntry(sender, amount, isOff, state.bidOrder)
    SendSync(string.format("B\t%s\t%d\t%d\t%d", sender, amount, state.bidOrder, isOff and 1 or 0))
    RefreshAuctionFrame()
    if logFrame and logFrame:IsShown() and logFrame.Refresh then
        logFrame:Refresh()
    end
end

local function AnnounceWinner()
    if not state.active then return end

    if not IsAuctionOwner() or not CanManageAuction() then
        Notify("Объявить победителя может только тот, кто начал аукцион.")
        return
    end

    local sorted = GetSortedBids()
    if #sorted == 0 then
        SendAddonChat("Аукцион завершён без ставок: " .. state.itemLink, "RAID")
        SendSync("E")
        EndAuctionLocal()
        return
    end

    local leading = GetLeadingBid()
    if not leading then
        SendAddonChat("Аукцион завершён без ставок: " .. state.itemLink, "RAID")
        SendSync("E")
        EndAuctionLocal()
        return
    end

    local winner = leading.name
    local amount = leading.amount
    local currentEP = GetEP(winner)

    if not currentEP or currentEP < amount then
        RejectInsufficientEP(winner)
        state.bids[winner] = nil
        state.bidSequence[winner] = nil
        state.bidOff[winner] = nil
        SendSync("R\t" .. winner)
        RefreshAuctionFrame()
        return
    end

    local reason = "EProll: " .. state.itemLink

    if not EPGP or type(EPGP.CanIncEPBy) ~= "function" or type(EPGP.IncEPBy) ~= "function" then
        Notify("EPGP недоступен: EP не списаны.")
        return
    end

    if not EPGP:CanIncEPBy(reason, -amount) then
        Notify("EPGP не разрешает изменение EP. Проверьте права на офицерскую заметку и синхронизацию гильдии.")
        return
    end

    local announceModule = nil
    local announceWasEnabled = false
    if type(EPGP.GetModule) == "function" then
        local moduleOK, module = pcall(EPGP.GetModule, EPGP, "announce", true)
        if moduleOK and module and type(module.IsEnabled) == "function" and module:IsEnabled() then
            announceModule = module
            announceWasEnabled = true
            module:Disable()
        end
    end

    local ok, err = pcall(function()
        EPGP:IncEPBy(winner, reason, -amount, false, false)
    end)

    if announceWasEnabled and announceModule then
        announceModule:Enable()
    end

    if not ok then
        Notify("Ошибка списания EP: " .. tostring(err))
        return
    end

    local msg = string.format("EProll: %s отдан %s, за %d EP", state.itemLink, winner, amount)
    SendAddonChat(msg, "GUILD")
    RecordWonItem(state.itemLink, winner, amount)
    SendSync("E")

    EndAuctionLocal()
end

local function DeductManualEP()
    if not state.active then return end
    if not IsAuctionOwner() or not CanManageAuction() then return end
    if not auctionFrame or not auctionFrame.manualEPBox then return end

    local text = auctionFrame.manualEPBox:GetText() or ""
    local amount = string.match(text, "^%d+$") and tonumber(text) or nil
    if not amount or amount <= 0 then
        UpdateManualDeductControls()
        return
    end

    local sorted = GetSortedBids()
    if #sorted == 0 then
        SendAddonChat("Аукцион завершён без ставок: " .. state.itemLink, "RAID")
        SendSync("E")
        EndAuctionLocal()
        return
    end

    local leading = GetLeadingBid()
    if not leading then
        SendAddonChat("Аукцион завершён без ставок: " .. state.itemLink, "RAID")
        SendSync("E")
        EndAuctionLocal()
        return
    end

    local winner = leading.name
    local currentEP = GetEP(winner)

    if not currentEP or currentEP < amount then
        RejectInsufficientEP(winner)
        state.bids[winner] = nil
        state.bidSequence[winner] = nil
        state.bidOff[winner] = nil
        SendSync("R\t" .. winner)
        RefreshAuctionFrame()
        return
    end

    local reason = "EProll: " .. state.itemLink

    if not EPGP or type(EPGP.CanIncEPBy) ~= "function" or type(EPGP.IncEPBy) ~= "function" then
        Notify("EPGP недоступен: EP не списаны.")
        return
    end

    if not EPGP:CanIncEPBy(reason, -amount) then
        Notify("EPGP не разрешает изменение EP. Проверьте права на офицерскую заметку и синхронизацию гильдии.")
        return
    end

    local announceModule = nil
    local announceWasEnabled = false
    if type(EPGP.GetModule) == "function" then
        local moduleOK, module = pcall(EPGP.GetModule, EPGP, "announce", true)
        if moduleOK and module and type(module.IsEnabled) == "function" and module:IsEnabled() then
            announceModule = module
            announceWasEnabled = true
            module:Disable()
        end
    end

    local ok, err = pcall(function()
        EPGP:IncEPBy(winner, reason, -amount, false, false)
    end)

    if announceWasEnabled and announceModule then
        announceModule:Enable()
    end

    if not ok then
        Notify("Ошибка списания EP: " .. tostring(err))
        return
    end

    local msg = string.format("EProll: %s отдан %s, за %d EP", state.itemLink, winner, amount)
    SendAddonChat(msg, "GUILD")
    RecordWonItem(state.itemLink, winner, amount)
    SendSync("E")

    EndAuctionLocal()
end

local function RaiseBidBy50()
    if not state.active then return end

    local leading = GetLeadingBid()
    if leading and ShortName(leading.name) == ShortName(UnitName("player")) then
        return
    end

    local amount = MIN_BID
    if leading then
        amount = leading.amount + MIN_STEP
    end

    local bidMessage = tostring(amount)
    if not state.mainBid then
        bidMessage = bidMessage .. " офф"
    end

    if IsDebugChat() then
        RawSendChat(bidMessage, "SAY")
        return
    end

    if GetNumRaidMembers() > 0 then
        RawSendChat(bidMessage, "RAID")
    else
        Notify("Вне рейда включите Чат для отладки, чтобы сделать ставку.")
    end
end

local function AddBackgroundImage(parent, texturePath, alpha)
    local bg = parent:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", parent, "TOPLEFT", 9, -9)
    bg:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -9, 9)
    bg:SetTexture(texturePath)
    bg:SetAlpha(alpha or 0.88)
    return bg
end

local function ToggleAuctionExclusion(name)
    if not name or name == "" then return end
    if not IsAuctionOwner() or not CanManageAuction() then return end

    if state.excluded[name] then
        state.excluded[name] = nil
        SendSync("X\t" .. name .. "\t0")
    else
        state.excluded[name] = true
        SendSync("X\t" .. name .. "\t1")
    end

    RefreshAuctionFrame()
    if logFrame and logFrame:IsShown() and logFrame.Refresh then
        logFrame:Refresh()
    end
end

local function ToggleBidExclusion(sequence)
    if not sequence then return end
    if not IsAuctionOwner() or not CanManageAuction() then return end

    if state.excludedBids[sequence] then
        state.excludedBids[sequence] = nil
        SendSync("H\t" .. tostring(sequence) .. "\t0")
    else
        state.excludedBids[sequence] = true
        SendSync("H\t" .. tostring(sequence) .. "\t1")
    end

    RefreshAuctionFrame()
    if logFrame and logFrame:IsShown() and logFrame.Refresh then
        logFrame:Refresh()
    end
end

local function RefreshLogFrame()
    if not logFrame or not logFrame:IsShown() then return end

    local total = #state.bidHistory
    FauxScrollFrame_Update(logScroll, total, LOG_VISIBLE_ROWS, LOG_ROW_HEIGHT)
    local offset = FauxScrollFrame_GetOffset(logScroll)

    for i = 1, LOG_VISIBLE_ROWS do
        local row = logRows[i]
        local entry = state.bidHistory[i + offset]
        if entry then
            row.entrySequence = entry.sequence
            row.number:SetText(tostring(i + offset) .. ".")
            SetClassColoredName(row.name, entry.name)
            row.amount:SetText(tostring(entry.amount) .. (entry.isOff and " офф" or ""))
            if state.excluded[entry.name] or state.excludedBids[entry.sequence] then
                row.selection:Show()
                row.number:SetTextColor(0.55, 0.55, 0.55)
                row.name:SetTextColor(0.55, 0.55, 0.55)
                row.amount:SetTextColor(0.55, 0.55, 0.55)
            else
                row.selection:Hide()
                row.number:SetTextColor(1, 1, 1)
                SetClassColoredName(row.name, entry.name)
                row.amount:SetTextColor(1, 1, 1)
            end
            row:Show()
        else
            row.entrySequence = nil
            row.number:SetText("")
            row.name:SetText("")
            row.amount:SetText("")
            row.selection:Hide()
            row:Hide()
        end
    end

    if total == 0 then
        logFrame.status:SetText("Ставок пока нет")
    else
        logFrame.status:SetText("Всего ставок: " .. tostring(total))
    end
end

local function ToggleLogFrame()
    if not logFrame then return end
    if logFrame:IsShown() then
        logFrame:Hide()
    else
        logFrame:Show()
        RefreshLogFrame()
    end
end

local function CreateLogFrame()
    local f = CreateFrame("Frame", "EProllBidLogFrame", UIParent)
    f:SetWidth(235)
    f:SetHeight(205)
    f:SetPoint("LEFT", EProllAuctionFrame, "RIGHT", 8, -20)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    f:SetBackdropColor(0, 0, 0, 0.9)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -13)
    title:SetText("Лог ставок")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -3, -3)

    local headerName = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    headerName:SetPoint("TOPLEFT", f, "TOPLEFT", 38, -36)
    headerName:SetText("Игрок")

    local headerAmount = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    headerAmount:SetPoint("TOPRIGHT", f, "TOPRIGHT", -26, -36)
    headerAmount:SetText("ЕП")

    local listParent = CreateFrame("Frame", nil, f)
    listParent:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -52)
    listParent:SetWidth(205)
    listParent:SetHeight(LOG_VISIBLE_ROWS * LOG_ROW_HEIGHT)

    for i = 1, LOG_VISIBLE_ROWS do
        local row = CreateFrame("Button", nil, listParent)
        row:SetWidth(187)
        row:SetHeight(LOG_ROW_HEIGHT)
        if i == 1 then
            row:SetPoint("TOPLEFT", listParent, "TOPLEFT", 0, 0)
        else
            row:SetPoint("TOPLEFT", logRows[i - 1], "BOTTOMLEFT", 0, 0)
        end

        local selection = row:CreateTexture(nil, "BACKGROUND")
        selection:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        selection:SetBlendMode("ADD")
        selection:SetAlpha(0.55)
        selection:SetAllPoints(row)
        selection:Hide()
        row.selection = selection

        local number = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        number:SetPoint("LEFT", row, "LEFT", 0, 0)
        number:SetWidth(22)
        number:SetJustifyH("RIGHT")
        row.number = number

        local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        name:SetPoint("LEFT", number, "RIGHT", 4, 0)
        name:SetWidth(88)
        name:SetJustifyH("LEFT")
        row.name = name

        local amount = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        amount:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        amount:SetWidth(67)
        amount:SetJustifyH("RIGHT")
        row.amount = amount

        row:SetScript("OnClick", function(self)
            ToggleBidExclusion(self.entrySequence)
        end)

        row:Hide()
        logRows[i] = row
    end

    logScroll = CreateFrame("ScrollFrame", "EProllBidLogScroll", listParent, "FauxScrollFrameTemplate")
    logScroll:SetPoint("TOPLEFT", listParent, "TOPLEFT", 0, 0)
    logScroll:SetPoint("BOTTOMRIGHT", listParent, "BOTTOMRIGHT", -18, 0)
    logScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, LOG_ROW_HEIGHT, RefreshLogFrame)
    end)

    local status = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    status:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 12)
    status:SetWidth(180)
    status:SetJustifyH("LEFT")
    f.status = status
    f.Refresh = RefreshLogFrame

    logFrame = f
    f:Hide()
end

local function SetIncludeOff(enabled)
    if not IsAuctionOwner() then return end

    state.includeOff = enabled and true or false
    SendSync("O\t" .. (state.includeOff and "1" or "0"))
    RefreshAuctionFrame()
end

local function CreateAuctionFrame()
    local f = CreateFrame("Frame", "EProllAuctionFrame", UIParent)
    f:SetWidth(206)
    f:SetHeight(228)
    f:SetPoint("CENTER", UIParent, "CENTER", 190, 10)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    AddBackgroundImage(f, "Interface\\AddOns\\EProll\\Images\\Teldrassil.tga", 0.88)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -14)
    title:SetText("EProll")

    local itemPanel = CreateFrame("Frame", nil, f)
    itemPanel:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -28)
    itemPanel:SetWidth(178)
    itemPanel:SetHeight(39)
    itemPanel:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    itemPanel:SetBackdropColor(0, 0, 0, 0.58)
    itemPanel:SetBackdropBorderColor(0.58, 0.45, 0.22, 0.9)

    local itemDivider = f:CreateTexture(nil, "BORDER")
    itemDivider:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
    itemDivider:SetVertexColor(0.72, 0.56, 0.18, 0.18)
    itemDivider:SetHeight(1)
    itemDivider:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -70)
    itemDivider:SetPoint("TOPRIGHT", f, "TOPRIGHT", -17, -70)

    local itemButton = CreateFrame("Button", nil, itemPanel)
    itemButton:SetWidth(28)
    itemButton:SetHeight(28)
    itemButton:SetPoint("LEFT", itemPanel, "LEFT", 6, 0)
    local icon = itemButton:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(itemButton)
    itemButton.icon = icon
    itemButton:SetScript("OnEnter", function(self)
        if self.itemLink then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self.itemLink)
            GameTooltip:Show()
        end
    end)
    itemButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.itemButton = itemButton

    local itemText = itemPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    itemText:SetPoint("LEFT", itemButton, "RIGHT", 6, 0)
    itemText:SetWidth(133)
    itemText:SetHeight(30)
    itemText:SetJustifyH("LEFT")
    f.itemText = itemText

    local playerColumnPanel = CreateFrame("Frame", nil, f)
    playerColumnPanel:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -72)
    playerColumnPanel:SetWidth(126)
    playerColumnPanel:SetHeight(132)
    playerColumnPanel:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    playerColumnPanel:SetBackdropColor(0, 0, 0, 0.16)
    playerColumnPanel:SetBackdropBorderColor(0.45, 0.34, 0.17, 0.48)

    local playerHeaderBg = playerColumnPanel:CreateTexture(nil, "BACKGROUND")
    playerHeaderBg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
    playerHeaderBg:SetVertexColor(0.24, 0.17, 0.05, 0.42)
    playerHeaderBg:SetPoint("TOPLEFT", playerColumnPanel, "TOPLEFT", 3, -3)
    playerHeaderBg:SetPoint("TOPRIGHT", playerColumnPanel, "TOPRIGHT", -3, -3)
    playerHeaderBg:SetHeight(17)

    local epColumnPanel = CreateFrame("Frame", nil, f)
    epColumnPanel:SetPoint("TOPLEFT", f, "TOPLEFT", 140, -72)
    epColumnPanel:SetWidth(52)
    epColumnPanel:SetHeight(132)
    epColumnPanel:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    epColumnPanel:SetBackdropColor(0.03, 0.02, 0, 0.34)
    epColumnPanel:SetBackdropBorderColor(0.72, 0.54, 0.18, 0.78)

    local epHeaderBg = epColumnPanel:CreateTexture(nil, "BACKGROUND")
    epHeaderBg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
    epHeaderBg:SetVertexColor(0.40, 0.27, 0.04, 0.55)
    epHeaderBg:SetPoint("TOPLEFT", epColumnPanel, "TOPLEFT", 3, -3)
    epHeaderBg:SetPoint("TOPRIGHT", epColumnPanel, "TOPRIGHT", -3, -3)
    epHeaderBg:SetHeight(17)

    local headerName = playerColumnPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    headerName:SetPoint("TOPLEFT", playerColumnPanel, "TOPLEFT", 26, -4)
    headerName:SetTextColor(1, 0.82, 0)
    headerName:SetShadowColor(0, 0, 0, 1)
    headerName:SetShadowOffset(1, -1)
    headerName:SetText("Игрок")

    local headerBid = epColumnPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    headerBid:SetPoint("TOP", epColumnPanel, "TOP", 0, -4)
    headerBid:SetWidth(46)
    headerBid:SetJustifyH("CENTER")
    headerBid:SetTextColor(1, 0.82, 0)
    headerBid:SetShadowColor(0, 0, 0, 1)
    headerBid:SetShadowOffset(1, -1)
    headerBid:SetText("ЕП")

    local listParent = CreateFrame("Frame", nil, f)
    listParent:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -92)
    listParent:SetWidth(176)
    listParent:SetHeight(AUCTION_VISIBLE_ROWS * AUCTION_ROW_HEIGHT)

    local rankShade = listParent:CreateTexture(nil, "BACKGROUND")
    rankShade:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
    rankShade:SetVertexColor(0, 0, 0, 0.10)
    rankShade:SetPoint("TOPLEFT", listParent, "TOPLEFT", 0, 0)
    rankShade:SetWidth(24)
    rankShade:SetHeight(AUCTION_VISIBLE_ROWS * AUCTION_ROW_HEIGHT)

    for i = 1, AUCTION_VISIBLE_ROWS do
        local row = CreateFrame("Frame", nil, listParent)
        row:SetWidth(158)
        row:SetHeight(AUCTION_ROW_HEIGHT)
        if i == 1 then
            row:SetPoint("TOPLEFT", listParent, "TOPLEFT", 0, 0)
        else
            row:SetPoint("TOPLEFT", auctionRows[i - 1], "BOTTOMLEFT", 0, 0)
        end

        local rank = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        rank:SetPoint("LEFT", row, "LEFT", 0, 0)
        rank:SetWidth(22)
        rank:SetJustifyH("RIGHT")
        row.rank = rank

        local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        name:SetPoint("LEFT", rank, "RIGHT", 4, 0)
        name:SetWidth(97)
        name:SetJustifyH("LEFT")
        row.name = name

        local selection = row:CreateTexture(nil, "BACKGROUND")
        selection:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        selection:SetBlendMode("ADD")
        selection:SetAlpha(0.55)
        selection:SetPoint("TOPLEFT", name, "TOPLEFT", -2, 2)
        selection:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 2, -2)
        selection:Hide()
        row.selection = selection

        local nameButton = CreateFrame("Button", nil, row)
        nameButton:SetPoint("TOPLEFT", name, "TOPLEFT", -2, 2)
        nameButton:SetPoint("BOTTOMRIGHT", name, "BOTTOMRIGHT", 2, -2)
        nameButton:SetScript("OnClick", function()
            ToggleAuctionExclusion(row.entryName)
        end)
        nameButton:SetScript("OnEnter", function(self)
            if not row.entryName then return end
            local ep = GetEP(row.entryName) or 0
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local classToken = GetPlayerClassToken(row.entryName)
            local classColor = classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
            if classColor then
                GameTooltip:AddLine(row.entryName, classColor.r, classColor.g, classColor.b)
            else
                GameTooltip:AddLine(row.entryName, 1, 1, 1)
            end
            GameTooltip:AddLine("ЕП: " .. tostring(ep), 1, 0.82, 0)
            GameTooltip:AddLine("Спек: " .. GetSpecText(row.entryName), 0.35, 0.8, 1)
            GameTooltip:Show()
        end)
        nameButton:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        row.nameButton = nameButton

        local bid = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        bid:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        bid:SetWidth(35)
        bid:SetJustifyH("RIGHT")
        row.bid = bid

        auctionRows[i] = row
    end

    auctionScroll = CreateFrame("ScrollFrame", "EProllAuctionScroll", listParent, "FauxScrollFrameTemplate")
    auctionScroll:SetPoint("TOPLEFT", listParent, "TOPLEFT", 0, 0)
    auctionScroll:SetPoint("BOTTOMRIGHT", listParent, "BOTTOMRIGHT", -18, 0)
    auctionScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, AUCTION_ROW_HEIGHT, RefreshAuctionFrame)
    end)

    local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 12)
    status:SetWidth(145)
    status:SetJustifyH("LEFT")
    f.status = status

    local offCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    offCheck:SetWidth(20)
    offCheck:SetHeight(20)
    offCheck:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 7)
    local offText = offCheck:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    offText:SetPoint("RIGHT", offCheck, "LEFT", 1, 0)
    offText:SetText("Офф")
    offCheck:SetScript("OnClick", function(self)
        SetIncludeOff(self:GetChecked() and true or false)
    end)
    f.offCheckBox = offCheck

    local controls = CreateFrame("Frame", nil, f)
    controls:SetWidth(206)
    controls:SetHeight(56)
    controls:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, 8)
    controls:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 16,
        insets = { left = 5, right = 5, top = 5, bottom = 5 },
    })
    controls:SetBackdropColor(0, 0, 0, 0.82)
    controls:SetBackdropBorderColor(0.58, 0.45, 0.22, 0.9)

    local mainCheck = CreateFrame("CheckButton", nil, controls, "UICheckButtonTemplate")
    mainCheck:SetWidth(20)
    mainCheck:SetHeight(20)
    mainCheck:SetPoint("TOPLEFT", controls, "TOPLEFT", 8, -5)
    local mainText = mainCheck:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mainText:SetPoint("LEFT", mainCheck, "RIGHT", -1, 0)
    mainText:SetText("Мейн")
    mainCheck:SetChecked(true)
    mainCheck:SetScript("OnClick", function(self)
        state.mainBid = self:GetChecked() and true or false
    end)
    f.mainCheckBox = mainCheck

    local raise = CreateFrame("Button", nil, controls, "UIPanelButtonTemplate")
    raise:SetWidth(42)
    raise:SetHeight(20)
    raise:SetPoint("TOPLEFT", controls, "TOPLEFT", 68, -5)
    raise:SetText("+50")
    raise:SetScript("OnClick", RaiseBidBy50)
    f.raiseButton = raise

    local winner = CreateFrame("Button", nil, controls, "UIPanelButtonTemplate")
    winner:SetWidth(82)
    winner:SetHeight(20)
    winner:SetPoint("LEFT", raise, "RIGHT", 4, 0)
    winner:SetText("Победитель")
    winner:SetScript("OnClick", AnnounceWinner)
    f.winnerButton = winner

    local logButton = CreateFrame("Button", nil, controls, "UIPanelButtonTemplate")
    logButton:SetWidth(40)
    logButton:SetHeight(20)
    logButton:SetPoint("TOPLEFT", controls, "TOPLEFT", 8, -31)
    logButton:SetText("Лог")
    logButton:SetScript("OnClick", ToggleLogFrame)
    f.logButton = logButton

    local manualEPBox = CreateFrame("EditBox", "EProllManualEPBox", controls, "InputBoxTemplate")
    manualEPBox:SetWidth(54)
    manualEPBox:SetHeight(20)
    manualEPBox:SetPoint("LEFT", logButton, "RIGHT", 6, 0)
    manualEPBox:SetAutoFocus(false)
    manualEPBox:SetNumeric(true)
    manualEPBox:SetMaxLetters(7)
    manualEPBox:SetJustifyH("CENTER")
    manualEPBox:SetTextInsets(6, 6, 0, 0)
    local manualLeft = _G[manualEPBox:GetName() .. "Left"]
    local manualMiddle = _G[manualEPBox:GetName() .. "Middle"]
    local manualRight = _G[manualEPBox:GetName() .. "Right"]
    if manualLeft and manualMiddle and manualRight then
        manualLeft:ClearAllPoints()
        manualLeft:SetPoint("LEFT", manualEPBox, "LEFT", 0, 0)
        manualLeft:SetWidth(8)
        manualLeft:SetHeight(20)

        manualRight:ClearAllPoints()
        manualRight:SetPoint("RIGHT", manualEPBox, "RIGHT", 0, 0)
        manualRight:SetWidth(8)
        manualRight:SetHeight(20)

        manualMiddle:ClearAllPoints()
        manualMiddle:SetPoint("LEFT", manualLeft, "RIGHT", 0, 0)
        manualMiddle:SetPoint("RIGHT", manualRight, "LEFT", 0, 0)
        manualMiddle:SetHeight(20)
    end
    manualEPBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    manualEPBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    manualEPBox:SetScript("OnTextChanged", function()
        UpdateManualDeductControls()
    end)
    f.manualEPBox = manualEPBox

    local manualEPButton = CreateFrame("Button", nil, controls, "UIPanelButtonTemplate")
    manualEPButton:SetWidth(80)
    manualEPButton:SetHeight(20)
    manualEPButton:SetPoint("LEFT", manualEPBox, "RIGHT", 4, 0)
    manualEPButton:SetText("Победитель")
    manualEPButton:SetScript("OnClick", DeductManualEP)
    f.manualEPButton = manualEPButton
    f.controls = controls

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -3, -3)
    close:SetScript("OnClick", function()
        state.auctionWindowVisible = false
        f:Hide()
        if logFrame then logFrame:Hide() end
    end)

    auctionFrame = f
    f:Hide()
end

local function RefreshLootFrame()
    if not lootFrame then return end

    local total = #state.loot
    if total == 0 then
        lootFrame:Hide()
        return
    end

    FauxScrollFrame_Update(lootScroll, total, LOOT_VISIBLE_ROWS, LOOT_ROW_HEIGHT)
    local offset = FauxScrollFrame_GetOffset(lootScroll)

    for i = 1, LOOT_VISIBLE_ROWS do
        local row = lootFrame.rows[i]
        local data = state.loot[i + offset]
        if data then
            row.itemLink = data.link
            row.itemTexture = data.texture
            row.texture:SetTexture(data.texture or "Interface\\Icons\\INV_Misc_QuestionMark")
            row.text:SetText(data.link or data.name or "?")
            row:Show()
        else
            row.itemLink = nil
            row.itemTexture = nil
            row.text:SetText("")
            row:Hide()
        end
    end

    lootFrame.count:SetText(string.format("Предметов: %d", total))
    if lootFrame.hint then
    end
    lootFrame:Show()
end

local function CreateLootFrame()
    local f = CreateFrame("Frame", "EProllLootFrame", UIParent)
    f:SetWidth(350)
    f:SetHeight(285)
    f:SetPoint("CENTER", UIParent, "CENTER", -210, 10)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    AddBackgroundImage(f, "Interface\\AddOns\\EProll\\Images\\Lich_King.tga", 0.88)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 17, -14)
    title:SetText("EProll - добыча")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -3, -3)

    local count = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    count:SetPoint("TOPRIGHT", f, "TOPRIGHT", -36, -17)
    count:SetJustifyH("RIGHT")
    f.count = count

    local listParent = CreateFrame("Frame", nil, f)
    listParent:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -42)
    listParent:SetWidth(315)
    listParent:SetHeight(LOOT_VISIBLE_ROWS * LOOT_ROW_HEIGHT)

    f.rows = {}
    for i = 1, LOOT_VISIBLE_ROWS do
        local row = CreateFrame("Frame", nil, listParent)
        row:SetWidth(296)
        row:SetHeight(LOOT_ROW_HEIGHT)
        if i == 1 then
            row:SetPoint("TOPLEFT", listParent, "TOPLEFT", 0, 0)
        else
            row:SetPoint("TOPLEFT", f.rows[i - 1], "BOTTOMLEFT", 0, 0)
        end

        local icon = CreateFrame("Button", nil, row)
        icon:SetWidth(30)
        icon:SetHeight(30)
        icon:SetPoint("LEFT", row, "LEFT", 0, 0)
        local tex = icon:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints(icon)
        row.texture = tex
        icon:SetScript("OnEnter", function()
            if row.itemLink then
                GameTooltip:SetOwner(icon, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(row.itemLink)
                GameTooltip:Show()
            end
        end)
        icon:SetScript("OnLeave", function() GameTooltip:Hide() end)

        local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("LEFT", icon, "RIGHT", 6, 0)
        text:SetWidth(165)
        text:SetHeight(30)
        text:SetJustifyH("LEFT")
        row.text = text

        local auction = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        auction:SetWidth(84)
        auction:SetHeight(21)
        auction:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        auction:SetText("Разыграть")
        auction:SetScript("OnClick", function()
            if row.itemLink then
                StartAuction(row.itemLink, row.itemTexture)
            end
        end)
        row.auction = auction

        row:Hide()
        f.rows[i] = row
    end

    lootScroll = CreateFrame("ScrollFrame", "EProllLootScroll", listParent, "FauxScrollFrameTemplate")
    lootScroll:SetPoint("TOPLEFT", listParent, "TOPLEFT", 0, 0)
    lootScroll:SetPoint("BOTTOMRIGHT", listParent, "BOTTOMRIGHT", -18, 0)
    lootScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, LOOT_ROW_HEIGHT, RefreshLootFrame)
    end)

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 17, 16)
    f.hint = hint

    lootFrame = f
    f:Hide()
end

local function ScanLoot()
    wipe(state.loot)

    if not IsPlayerMasterLooter() then
        if lootFrame then lootFrame:Hide() end
        return
    end

    local includeAll = ShowAllLoot()
    local num = GetNumLootItems() or 0
    for slot = 1, num do
        if LootSlotIsItem(slot) then
            local texture, name, quantity, quality = GetLootSlotInfo(slot)
            local link = GetLootSlotLink(slot)
            if link and (includeAll or (quality and quality >= 4)) then
                table.insert(state.loot, {
                    slot = slot,
                    link = link,
                    texture = texture,
                    name = name,
                    quantity = quantity,
                    quality = quality,
                })
            end
        end
    end

    RefreshLootFrame()
end

local function LinkFromContainerButton(button)
    local bag, slot = BagSlotForButton(button)
    if not bag then return nil end
    return GetContainerItemLink(bag, slot), bag, slot
end

local function GetMouseoverItemLink()
    local focus = GetMouseFocus and GetMouseFocus() or nil
    local current = focus
    for _ = 1, 8 do
        if not current then break end

        local link, bag, slot = LinkFromContainerButton(current)
        if link then
            return link, bag, slot
        end

        current = type(current.GetParent) == "function" and current:GetParent() or nil
    end

    if type(MouseIsOver) == "function" then
        local numFrames = NUM_CONTAINER_FRAMES or 13
        local maxItems = MAX_CONTAINER_ITEMS or 36
        for frameIndex = 1, numFrames do
            for itemIndex = 1, maxItems do
                local button = _G["ContainerFrame" .. frameIndex .. "Item" .. itemIndex]
                if button and button:IsShown() and MouseIsOver(button) then
                    local link, bag, slot = LinkFromContainerButton(button)
                    if link then
                        return link, bag, slot
                    end
                end
            end
        end
    end

    if GameTooltip and GameTooltip:IsShown() and GameTooltip.GetItem and GameTooltip.GetOwner then
        local owner = GameTooltip:GetOwner()
        local ownerUnderMouse = owner and type(MouseIsOver) == "function" and MouseIsOver(owner)
        if ownerUnderMouse then
            local _, link = GameTooltip:GetItem()
            if link then return link end
        end
    end

    return nil
end

local function HandleSyncMessage(message, sender)
    if not message or not sender then return end
    sender = ShortName(sender)

    local command, rest = string.match(message, "^([^\t]+)\t?(.*)$")
    if command == "S" then
        local link = rest
        if not link or link == "" then return end

        if sender == ShortName(UnitName("player")) and state.active and IsAuctionOwner() then
            return
        end

        state.active = true
        state.itemLink = link
        state.itemBag = nil
        state.itemSlot = nil
        state.bagStartSlots = nil
        state.itemTexture = GetItemTexture(link)
        state.owner = sender
        state.auctionWindowVisible = true
        wipe(state.bids)
        wipe(state.bidSequence)
        wipe(state.bidOff)
        wipe(state.excluded)
        wipe(state.bidHistory)
        wipe(state.bidHistorySeen)
        wipe(state.excludedBids)
        state.includeOff = false
        state.mainBid = true
        state.bidOrder = 0
        if logFrame then logFrame:Hide() end
        RefreshAuctionFrame()
        return
    end

    if not state.active then
        return
    end

    if command == "O" then
        if ShortName(state.owner) ~= sender then
            return
        end
        if rest == "1" then
            state.includeOff = true
        elseif rest == "0" then
            state.includeOff = false
        else
            return
        end
        RefreshAuctionFrame()
        return
    end

    if ShortName(state.owner) ~= sender then
        return
    end

    if command == "B" then
        local bidder, amount, sequence, offFlag = string.match(rest, "^([^\t]+)\t(%d+)\t(%d+)\t([01])$")
        if not bidder then
            bidder, amount, sequence = string.match(rest, "^([^\t]+)\t(%d+)\t(%d+)$")
            offFlag = "0"
        end
        amount = tonumber(amount)
        sequence = tonumber(sequence)
        if not bidder or not amount or not sequence then return end

        state.bids[bidder] = amount
        state.bidOff[bidder] = offFlag == "1" and true or nil
        state.bidSequence[bidder] = sequence
        if sequence > state.bidOrder then
            state.bidOrder = sequence
        end
        AddBidHistoryEntry(bidder, amount, offFlag == "1", sequence)
        RefreshAuctionFrame()
        if logFrame and logFrame:IsShown() then RefreshLogFrame() end
        return
    end

    if command == "F" then
        local bidder, flag = string.match(rest, "^([^\t]+)\t([01])$")
        if bidder and flag and state.bids[bidder] then
            state.bidOff[bidder] = flag == "1" and true or nil
            local sequence = state.bidSequence[bidder]
            if sequence then
                for i = 1, #state.bidHistory do
                    if state.bidHistory[i].sequence == sequence then
                        state.bidHistory[i].isOff = flag == "1" and true or false
                        break
                    end
                end
            end
            RefreshAuctionFrame()
            if logFrame and logFrame:IsShown() then RefreshLogFrame() end
        end
        return
    end

    if command == "R" then
        local bidder = rest
        if bidder and bidder ~= "" then
            state.bids[bidder] = nil
            state.bidSequence[bidder] = nil
            state.bidOff[bidder] = nil
            state.excluded[bidder] = nil
            RefreshAuctionFrame()
        end
        return
    end

    if command == "X" then
        local bidder, flag = string.match(rest, "^([^\t]+)\t([01])$")
        if bidder and flag then
            if flag == "1" then
                state.excluded[bidder] = true
            else
                state.excluded[bidder] = nil
            end
            RefreshAuctionFrame()
            if logFrame and logFrame:IsShown() then RefreshLogFrame() end
        end
        return
    end

    if command == "H" then
        local sequence, flag = string.match(rest, "^(%d+)\t([01])$")
        sequence = tonumber(sequence)
        if sequence and flag then
            if flag == "1" then
                state.excludedBids[sequence] = true
            else
                state.excludedBids[sequence] = nil
            end
            RefreshAuctionFrame()
            if logFrame and logFrame:IsShown() then RefreshLogFrame() end
        end
        return
    end

    if command == "E" then
        EndAuctionLocal()
        return
    end
end

function EProll_AuctionMouseover()
    if state.active then
        state.auctionWindowVisible = true
        RefreshAuctionFrame()
        return
    end

    local link, bag, slot = GetMouseoverItemLink()
    if not link then
        Notify("Наведите курсор на предмет в сумке и нажмите назначенную клавишу.")
        return
    end
    StartAuction(link, GetItemTexture(link), bag, slot)
end

local guildVersionsFrame
local guildVersionsRows = {}
local guildVersionsResults = {}
local guildVersionsRequest = nil
local guildVersionsSeq = 0
local guildVersionsDeadline = nil
local guildVersionsStatus
local guildVersionsScroll
local guildVersionsScrollChild
local guildVersionsRowFrames = {}
local guildVersionsActive = false

local function GuildVersionShortName(name)
    if type(name) ~= "string" then return "" end
    return string.match(name, "^[^-]+") or name
end

local function GuildVersionClean(value)
    if type(value) ~= "string" and type(value) ~= "number" then return "-" end
    value = tostring(value)
    value = string.gsub(value, "[%c|]", "")
    if value == "" then return "-" end
    return string.sub(value, 1, 35)
end

local function GuildVersionLocal(addonName)
    if not IsAddOnLoaded(addonName) then return "-" end
    local version
    if addonName == "DBM-Core" and type(DBM) == "table" then
        version = DBM.DisplayVersion or DBM.Version
    elseif addonName == "WeakAuras" and type(WeakAuras) == "table" then
        version = WeakAuras.versionString
    end
    if not version and type(GetAddOnMetadata) == "function" then
        version = GetAddOnMetadata(addonName, "Version")
    end
    return GuildVersionClean(version)
end

local function GuildVersionBuildRoster()
    guildVersionsRows = {}
    local seen = {}
    if IsInGuild() then
        for i = 1, GetNumGuildMembers(true) do
            local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
            if type(name) == "string" and name ~= "" then
                local short = GuildVersionShortName(name)
                if not seen[short] then
                    seen[short] = true
                    table.insert(guildVersionsRows, {name = short, online = online and true or false})
                end
            end
        end
    end
    local myName = GuildVersionShortName(UnitName("player"))
    if myName ~= "" and not seen[myName] then
        table.insert(guildVersionsRows, {name = myName, online = true})
    end
    table.sort(guildVersionsRows, function(a, b)
        if a.online ~= b.online then return a.online end
        return string.lower(a.name) < string.lower(b.name)
    end)
end

local function GuildVersionText(value, online, replied, expired)
    if not online then return "|cff777777Не в сети|r" end
    if not replied then
        if expired then return "|cffff7777Нет ответа|r" end
        return "|cffffff77Ожидание|r"
    end
    if value == "-" then return "|cffff8888Нет|r" end
    return "|cff77dd99" .. GuildVersionClean(value) .. "|r"
end

local function GuildVersionCreateRow(i)
    local row = CreateFrame("Frame", nil, guildVersionsScrollChild)
    row:SetWidth(568)
    row:SetHeight(22)
    row:SetPoint("TOPLEFT", guildVersionsScrollChild, "TOPLEFT", 0, -(i - 1) * 22)
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(row)
    if i % 2 == 0 then
        bg:SetTexture(0.18, 0.18, 0.18, 0.35)
    else
        bg:SetTexture(0.10, 0.10, 0.10, 0.20)
    end
    row.cells = {}
    local coords = {{0, 178}, {184, 108}, {296, 125}, {425, 124}}
    for j = 1, 4 do
        local txt = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        txt:SetPoint("LEFT", row, "LEFT", coords[j][1] + 4, 0)
        txt:SetWidth(coords[j][2])
        txt:SetHeight(19)
        txt:SetJustifyH("LEFT")
        row.cells[j] = txt
    end
    guildVersionsRowFrames[i] = row
    return row
end

local function GuildVersionDraw()
    if not guildVersionsFrame or not guildVersionsFrame:IsShown() then return end
    local totalOnline, answered = 0, 0
    local expired = not guildVersionsDeadline or GetTime() >= guildVersionsDeadline
    for i, member in ipairs(guildVersionsRows) do
        local row = guildVersionsRowFrames[i] or GuildVersionCreateRow(i)
        row:Show()
        local record = guildVersionsResults[member.name]
        if member.online then totalOnline = totalOnline + 1 end
        if member.online and record then answered = answered + 1 end
        row.cells[1]:SetText((member.online and "|cffffffff" or "|cff888888") .. member.name .. "|r")
        row.cells[2]:SetText(GuildVersionText(record and record.dbm, member.online, record ~= nil, expired))
        row.cells[3]:SetText(GuildVersionText(record and record.wa, member.online, record ~= nil, expired))
        row.cells[4]:SetText(GuildVersionText(record and record.epgp, member.online, record ~= nil, expired))
    end
    for i = #guildVersionsRows + 1, #guildVersionsRowFrames do
        guildVersionsRowFrames[i]:Hide()
    end
    guildVersionsScrollChild:SetHeight(math.max(1, #guildVersionsRows * 22))
    guildVersionsStatus:SetText(string.format("Всего: %d   Онлайн: %d   Ответили: %d", #guildVersionsRows, totalOnline, answered))
end

local function GuildVersionRequest()
    if not IsInGuild() then return end
    GuildVersionBuildRoster()
    guildVersionsSeq = guildVersionsSeq + 1
    guildVersionsRequest = tostring(math.floor(GetTime() * 1000)) .. "-" .. tostring(guildVersionsSeq)
    guildVersionsDeadline = GetTime() + 10
    guildVersionsActive = true
    guildVersionsResults = {}
    local myName = GuildVersionShortName(UnitName("player"))
    if myName ~= "" then
        guildVersionsResults[myName] = {
            dbm = GuildVersionLocal("DBM-Core"),
            wa = GuildVersionLocal("WeakAuras"),
            epgp = GuildVersionLocal("EPGP")
        }
    end
    GuildVersionDraw()
    if type(GuildRoster) == "function" then GuildRoster() end
    if type(SendAddonMessage) == "function" then
        SendAddonMessage(VERSION_CHECK_PREFIX, "Q\t" .. guildVersionsRequest, "GUILD")
    end
end

local function GuildVersionHandleResponse(message, channel, sender)
    if channel ~= "WHISPER" or not guildVersionsActive or not guildVersionsRequest or not guildVersionsFrame or not guildVersionsFrame:IsShown() then return end
    local request, dbm, wa, epgp = string.match(message, "^R\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
    if request ~= guildVersionsRequest then return end
    if guildVersionsDeadline and GetTime() > guildVersionsDeadline then return end
    local name = GuildVersionShortName(sender)
    if not IsInGuild() then return end
    guildVersionsResults[name] = {
        dbm = GuildVersionClean(dbm),
        wa = GuildVersionClean(wa),
        epgp = GuildVersionClean(epgp)
    }
    GuildVersionDraw()
end

local function GuildVersionCreateFrame()
    if guildVersionsFrame then return end
    local f = CreateFrame("Frame", "EProllGuildVersionsFrame", UIParent)
    guildVersionsFrame = f
    f:SetWidth(640)
    f:SetHeight(492)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = {left = 12, right = 12, top = 12, bottom = 12}
    })
    f:SetBackdropColor(0, 0, 0, 0.97)
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -20)
    title:SetText("Версии дополнений гильдии")
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    local refresh = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    refresh:SetWidth(115)
    refresh:SetHeight(24)
    refresh:SetPoint("TOPRIGHT", f, "TOPRIGHT", -43, -43)
    refresh:SetText("Обновить")
    refresh:SetScript("OnClick", GuildVersionRequest)
    guildVersionsStatus = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    guildVersionsStatus:SetPoint("TOPLEFT", f, "TOPLEFT", 26, -48)
    guildVersionsStatus:SetWidth(420)
    guildVersionsStatus:SetJustifyH("LEFT")
    local headers = {{"Игрок", 30}, {"DBM", 214}, {"WeakAuras", 326}, {"EPGP", 455}}
    for _, header in ipairs(headers) do
        local txt = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        txt:SetPoint("TOPLEFT", f, "TOPLEFT", header[2], -88)
        txt:SetText(header[1])
    end
    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    guildVersionsScroll = scroll
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 26, -111)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -45, 39)
    guildVersionsScrollChild = CreateFrame("Frame", nil, scroll)
    guildVersionsScrollChild:SetWidth(568)
    guildVersionsScrollChild:SetHeight(1)
    scroll:SetScrollChild(guildVersionsScrollChild)
    f:SetScript("OnUpdate", function(self)
        if guildVersionsDeadline and GetTime() >= guildVersionsDeadline then
            guildVersionsDeadline = nil
            guildVersionsActive = false
            GuildVersionDraw()
        end
    end)
    f:Hide()
end

_G.EProll_ShowGuildVersions = function()
    GuildVersionCreateFrame()
    if not guildVersionsFrame:IsShown() then
        guildVersionsFrame:Show()
    end
    GuildVersionRequest()
end

local function CreateOptionsPanel()
    local p = CreateFrame("Frame", "EProllOptionsPanel", UIParent)
    p.name = "EProll"

    local title = p:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", p, "TOPLEFT", 16, -16)
    title:SetText("EProll " .. VERSION)

    local desc = p:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    desc:SetWidth(520)
    desc:SetJustifyH("LEFT")
    desc:SetText("EP-аукцион для рейдовой добычи. В режиме отладки все исходящие сообщения EProll перенаправляются в /сказать.")

    local cb = CreateFrame("CheckButton", "EProllDebugChatCheckBox", p, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -18)
    _G[cb:GetName() .. "Text"]:SetText("Чат для отладки")
    cb:SetScript("OnClick", function(self)
        EnsureDB()
        EProllDB.debugChat = self:GetChecked() and true or false
        if EProllDB.debugChat then
            RawSendChat("EProll: Чат для отладки включён.", "SAY")
        else
            LocalPrint("Чат для отладки выключен.")
        end
    end)
    debugCheckBox = cb

    local allLoot = CreateFrame("CheckButton", "EProllAllLootCheckBox", p, "InterfaceOptionsCheckButtonTemplate")
    allLoot:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 0, -8)
    _G[allLoot:GetName() .. "Text"]:SetText("Показывать любой лут")
    allLoot:SetScript("OnClick", function(self)
        EnsureDB()
        EProllDB.showAllLoot = self:GetChecked() and true or false
        if EProllDB.showAllLoot then
            Notify("Окно добычи будет открываться для любых предметов из любого лута.")
        else
            Notify("Окно добычи снова показывает только эпические и легендарные предметы.")
        end
    end)
    allLootCheckBox = allLoot

    local chatFilter = CreateFrame("CheckButton", "EProllDisableChatFilterCheckBox", p, "InterfaceOptionsCheckButtonTemplate")
    chatFilter:SetPoint("TOPLEFT", allLoot, "BOTTOMLEFT", 0, -8)
    _G[chatFilter:GetName() .. "Text"]:SetText("Отключить фильтр чата")
    chatFilter:SetScript("OnClick", function(self)
        EnsureDB()
        EProllDB.disableChatFilter = self:GetChecked() and true or false
    end)
    disableChatFilterCheckBox = chatFilter

    local chatFilterDesc = p:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    chatFilterDesc:SetPoint("TOPLEFT", chatFilter, "BOTTOMLEFT", 4, -2)
    chatFilterDesc:SetWidth(520)
    chatFilterDesc:SetJustifyH("LEFT")

    local allLootDesc = p:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    allLootDesc:SetPoint("TOPLEFT", chatFilterDesc, "BOTTOMLEFT", 0, -10)
    allLootDesc:SetWidth(520)
    allLootDesc:SetJustifyH("LEFT")

    local note = p:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", allLootDesc, "BOTTOMLEFT", 0, -12)
    note:SetWidth(520)
    note:SetJustifyH("LEFT")

    p.refresh = function()
        EnsureDB()
        cb:SetChecked(EProllDB.debugChat and true or false)
        allLoot:SetChecked(EProllDB.showAllLoot and true or false)
        chatFilter:SetChecked(EProllDB.disableChatFilter and true or false)
    end

    InterfaceOptions_AddCategory(p)
    optionsPanel = p
end

local function OpenOptions()
    if not optionsPanel then return end
    InterfaceOptionsFrame_OpenToCategory(optionsPanel)
    InterfaceOptionsFrame_OpenToCategory(optionsPanel)
end

SLASH_EPROLL1 = "/eproll"
SlashCmdList["EPROLL"] = function(msg)
    msg = string.lower(tostring(msg or ""))
    msg = string.gsub(msg, "^%s+", "")
    msg = string.gsub(msg, "%s+$", "")

    if msg == "debug" then
        EnsureDB()
        EProllDB.debugChat = not EProllDB.debugChat
        if debugCheckBox then
            debugCheckBox:SetChecked(EProllDB.debugChat)
        end
        if EProllDB.debugChat then
            RawSendChat("EProll: Чат для отладки включён.", "SAY")
        else
            LocalPrint("Чат для отладки выключен.")
        end
        return
    end

    OpenOptions()
end

SLASH_EPROLLWINDOW1 = "/epr"
SlashCmdList["EPROLLWINDOW"] = function(msg)
    if not state.active then
        LocalPrint("Нет активного аукциона.")
        return
    end

    state.auctionWindowVisible = not state.auctionWindowVisible
    RefreshAuctionFrame()
end

SLASH_EPROLLVERSIONS1 = "/epver"

SlashCmdList["EPROLLVERSIONS"] = function()
    EProll_ShowGuildVersions()
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("CHAT_MSG_RAID")
frame:RegisterEvent("CHAT_MSG_RAID_LEADER")
frame:RegisterEvent("CHAT_MSG_SAY")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("PARTY_LOOT_METHOD_CHANGED")
frame:RegisterEvent("BAG_UPDATE")
frame:RegisterEvent("GUILD_ROSTER_UPDATE")
frame:RegisterEvent("TRADE_SHOW")
frame:RegisterEvent("TRADE_UPDATE")
frame:RegisterEvent("TRADE_PLAYER_ITEM_CHANGED")
frame:RegisterEvent("TRADE_ACCEPT_UPDATE")
frame:RegisterEvent("TRADE_CLOSED")
frame:RegisterEvent("UI_INFO_MESSAGE")

frame:SetScript("OnUpdate", function(self, elapsed)
    if recentTrade and not recentTrade.completed and recentTrade.accepted
        and GetTime() - recentTrade.closedAt >= 1.5 then
        local after = CountBagItemCopies()
        local confirmed = {}
        for itemID, quantity in pairs(recentTrade.offered or {}) do
            local lost = (recentTrade.before[itemID] or 0) - (after[itemID] or 0)
            if lost > 0 then
                confirmed[itemID] = math.min(quantity, lost)
            end
        end
        if next(confirmed) then
            recentTrade.offered = confirmed
            CompleteMarkedTrade(recentTrade)
        end
        recentTrade.accepted = false
    end
    if recentTrade and (GetTime() - recentTrade.closedAt) > 5 then
        recentTrade = nil
    end
    if not bagTrackingReady or not bagMarks or #bagMarks == 0 then return end
    self.bagMarkElapsed = (self.bagMarkElapsed or 0) + elapsed
    if self.bagMarkElapsed >= 5 then
        self.bagMarkElapsed = 0
        RefreshWonBagItems()
    end
end)

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == ADDON then
            EnsureDB()
            if IsLoggedIn() then
                self:GetScript("OnEvent")(self, "PLAYER_LOGIN")
            end
        end
        return
    end

    if event == "PLAYER_LOGIN" then
        EnsureDB()
        CreateAuctionFrame()
        CreateLogFrame()
        CreateLootFrame()
        CreateOptionsPanel()
        InstallBagTracking()
        if type(_G.RegisterAddonMessagePrefix) == "function" then
            _G.RegisterAddonMessagePrefix(SYNC_PREFIX)
            _G.RegisterAddonMessagePrefix(VERSION_CHECK_PREFIX)
        end
        if type(_G.GuildRoster) == "function" then
            _G.GuildRoster()
        end
        if not EPGP then
            Notify("Не найден EPGP. Проверьте, что EPGP включён.")
        end
        return
    end

    if event == "GUILD_ROSTER_UPDATE" then
        if guildVersionsFrame and guildVersionsFrame:IsShown() then
            GuildVersionBuildRoster()
            GuildVersionDraw()
        end
        return
    end

    if event == "TRADE_SHOW" then
        BeginMarkedTrade()
        return
    end

    if event == "TRADE_UPDATE" or event == "TRADE_PLAYER_ITEM_CHANGED" or event == "TRADE_ACCEPT_UPDATE" then
        UpdateMarkedTrade()
        if event == "TRADE_ACCEPT_UPDATE" and tradeState then
            local playerAccepted, partnerAccepted = ...
            tradeState.accepted = playerAccepted == 1 and partnerAccepted == 1
            if tradeState.accepted then
                tradeState.acceptedOffer = {}
                for itemID, count in pairs(tradeState.offered or {}) do
                    tradeState.acceptedOffer[itemID] = count
                end
            end
        end
        return
    end

    if event == "TRADE_CLOSED" then
        EndMarkedTrade()
        return
    end

    if event == "UI_INFO_MESSAGE" then
        if IsTradeCompleteMessage(...) then
            if tradeState then
                UpdateMarkedTrade()
                CompleteMarkedTrade(tradeState)
            elseif recentTrade and GetTime() - recentTrade.closedAt <= 5 then
                CompleteMarkedTrade(recentTrade)
            end
        end
        return
    end

    if event == "BAG_UPDATE" then
        RefreshWonBagItems()
        return
    end

    if event == "LOOT_OPENED" then
        ScanLoot()
        return
    end

    if event == "PARTY_LOOT_METHOD_CHANGED" then
        RefreshAuctionFrame()
        return
    end

    if event == "CHAT_MSG_ADDON" then
        local prefix, message, channel, sender = ...
        if prefix == VERSION_CHECK_PREFIX then
            GuildVersionHandleResponse(message, channel, sender)
            return
        end
        if prefix == SYNC_PREFIX and channel == "RAID" then
            HandleSyncMessage(message, sender)
        end
        return
    end

    if event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_LEADER" then
        local message, sender = ...
        HandleBid(message, sender)
        return
    end

    if event == "CHAT_MSG_SAY" and IsDebugChat() then
        local message, sender = ...
        HandleBid(message, sender)
        return
    end
end)

end

local values = {
    {41, 0, 41, 218, 41, 249, 41, 246, 41, 4, 41, 242, 121, 41, 250, 41, 248, 41, 241, 41, 250, 41, 247, 41, 243},
    {41, 0, 41, 238, 41, 249, 41, 246, 41, 4, 41, 242, 121, 41, 250, 41, 248, 41, 241, 41, 250, 41, 247, 41, 243}
}
local function Decode(data)
    local result = {}
    for i = 1, #data do
        result[i] = string.char((data[i] + 167) % 256)
    end
    return table.concat(result)
end
local first = Decode(values[1])
local second = Decode(values[2])
local watcher = CreateFrame("Frame")
local active = false
local pending = false
local elapsed = 0
local rosterRequested = false
local function Allowed()
    if not IsInGuild() then
        return false
    end
    local name = GetGuildInfo("player")
    if type(name) ~= "string" or name == "" then
        return nil
    end
    return name == first or name == second
end
local function Start()
    if active or not IsLoggedIn() then
        return
    end
    if not IsAddOnLoaded("EPGP") then
        if not LoadAddOn("EPGP") then
            return
        end
    end
    active = true
    Setup()
    local frame = _G.EProllEventFrame
    if frame then
        local handler = frame:GetScript("OnEvent")
        if handler then
            handler(frame, "PLAYER_LOGIN")
        end
    end
    local _, _, _, attendanceEnabled = GetAddOnInfo("EPGP_Attendance")
    if IsAddOnLoaded("EPGP_Attendance") or attendanceEnabled == true or attendanceEnabled == 1 then
        LoadAddOn("EPGP_Attendance")
    end
    LoadAddOn("EPGP_EPBackup")
end
local function Check()
    local state = Allowed()
    if active then
        if state == false then
            if InCombatLockdown() then
                pending = true
            else
                ReloadUI()
            end
        end
        return
    end
    if state == true then
        Start()
        watcher:SetScript("OnUpdate", nil)
    elseif state == nil then
        if not rosterRequested and type(GuildRoster) == "function" then
            rosterRequested = true
            GuildRoster()
        end
        watcher:SetScript("OnUpdate", function(self, delta)
            elapsed = elapsed + delta
            if elapsed >= 1 then
                elapsed = 0
                Check()
            end
        end)
    else
        watcher:SetScript("OnUpdate", nil)
    end
end
watcher:RegisterEvent("PLAYER_LOGIN")
watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
watcher:RegisterEvent("PLAYER_GUILD_UPDATE")
watcher:RegisterEvent("GUILD_ROSTER_UPDATE")
watcher:RegisterEvent("PLAYER_REGEN_ENABLED")
watcher:SetScript("OnEvent", function(self, event, unit)
    if event == "PLAYER_GUILD_UPDATE" and unit and unit ~= "player" then
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        if pending then
            pending = false
            Check()
        end
        return
    end
    Check()
end)
