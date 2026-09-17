----- Requires EPGP.

BINDING_HEADER_EPROLL = "EProll"
BINDING_NAME_EPROLL_AUCTION_MOUSEOVER = "Объявить предмет под курсором на аукцион"

local ADDON = "EProll"
local VERSION = "1.1.1"
local SYNC_PREFIX = "EProll"
local MIN_BID = 100
local MIN_STEP = 50
local AUCTION_VISIBLE_ROWS = 6
local AUCTION_ROW_HEIGHT = 19
local LOOT_VISIBLE_ROWS = 6
local LOOT_ROW_HEIGHT = 36

local state = {
    active = false,
    itemLink = nil,
    itemTexture = nil,
    bids = {},
    bidOrder = 0,
    bidSequence = {},
    loot = {},
    auctionWindowVisible = false,
    owner = nil,
}

local frame = CreateFrame("Frame", "EProllEventFrame", UIParent)
local lootFrame
local lootScroll
local auctionFrame
local auctionScroll
local auctionRows = {}
local optionsPanel
local debugCheckBox
local allLootCheckBox

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
end

local function IsDebugChat()
    EnsureDB()
    return EProllDB.debugChat and true or false
end

local function ShowAllLoot()
    EnsureDB()
    return EProllDB.showAllLoot and true or false
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

local function IsPlayerRaidLeader()
    local player = UnitName("player")
    if not player or GetNumRaidMembers() == 0 then return false end

    for i = 1, GetNumRaidMembers() do
        local name, rank = GetRaidRosterInfo(i)
        if name == player then
            return rank == 2
        end
    end
    return false
end

local function IsPlayerMasterLooter()
    local method, partyIndex, raidIndex = GetLootMethod()
    if method ~= "master" then return false end

    local player = UnitName("player")
    if not player then return false end

    if GetNumRaidMembers() > 0 and raidIndex then
        local name = GetRaidRosterInfo(raidIndex)
        return name == player
    end

    if GetNumPartyMembers() > 0 then
        if partyIndex == 0 then
            return true
        elseif partyIndex and partyIndex > 0 then
            return UnitName("party" .. partyIndex) == player
        end
    end

    return false
end

local function CanManageAuction()
    if GetNumRaidMembers() == 0 then
        return true
    end
    return IsPlayerRaidLeader() or IsPlayerMasterLooter()
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

local function GetSortedBids()
    local t = {}
    for name, amount in pairs(state.bids) do
        table.insert(t, {
            name = name,
            amount = amount,
            sequence = state.bidSequence[name] or 0,
        })
    end

    table.sort(t, function(a, b)
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

local function HighestOtherBid(name)
    local highest = nil
    for bidder, amount in pairs(state.bids) do
        if bidder ~= name and (not highest or amount > highest) then
            highest = amount
        end
    end
    return highest
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

    local sorted = GetSortedBids()
    local total = #sorted
    FauxScrollFrame_Update(auctionScroll, total, AUCTION_VISIBLE_ROWS, AUCTION_ROW_HEIGHT)
    local offset = FauxScrollFrame_GetOffset(auctionScroll)

    for i = 1, AUCTION_VISIBLE_ROWS do
        local row = auctionRows[i]
        local entry = sorted[i + offset]
        if entry then
            row.rank:SetText(tostring(i + offset) .. ".")
            row.name:SetText(entry.name)
            row.bid:SetText(tostring(entry.amount))
            row:Show()
        else
            row.rank:SetText("")
            row.name:SetText("")
            row.bid:SetText("")
            row:Hide()
        end
    end

    if total == 0 then
        auctionFrame.status:SetText("Ставок пока нет")
    else
        auctionFrame.status:SetText(string.format("Лидер: %s - %d EP", sorted[1].name, sorted[1].amount))
    end
end

local function EndAuctionLocal()
    state.active = false
    state.itemLink = nil
    state.itemTexture = nil
    state.owner = nil
    wipe(state.bids)
    wipe(state.bidSequence)
    state.bidOrder = 0
    RefreshAuctionFrame()
end

local function StartAuction(itemLink, texture)
    if not itemLink then
        Notify("Не удалось получить ссылку на предмет.")
        return
    end

    if not CanManageAuction() then
        Notify("Начать аукцион может только лидер рейда или мастер добычи.")
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
    state.auctionWindowVisible = true
    wipe(state.bids)
    wipe(state.bidSequence)
    state.bidOrder = 0

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

local function HandleBid(message, sender)
    if not state.active then return end
    if not IsAuctionOwner() then return end
    if not CanManageAuction() then return end
    if not message or not sender then return end

    local amount = tonumber(string.match(message, "^%s*(%d+)%s*$"))
    if not amount then return end

    amount = math.floor(amount)

    if amount < MIN_BID then
        RejectMinStep(sender)
        return
    end

    local oldBid = state.bids[sender]
    local highestOther = HighestOtherBid(sender)
    local required = MIN_BID
    if highestOther then
        required = math.max(required, highestOther + MIN_STEP)
    end

    if amount < required then
        RejectMinStep(sender)
        return
    end

    if oldBid then
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

    state.bids[sender] = amount
    state.bidOrder = state.bidOrder + 1
    state.bidSequence[sender] = state.bidOrder
    SendSync(string.format("B\t%s\t%d\t%d", sender, amount, state.bidOrder))
    RefreshAuctionFrame()
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

    local winner = sorted[1].name
    local amount = sorted[1].amount
    local currentEP = GetEP(winner)

    if not currentEP or currentEP < amount then
        RejectInsufficientEP(winner)
        state.bids[winner] = nil
        state.bidSequence[winner] = nil
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
    SendSync("E")

    EndAuctionLocal()
end

local function RaiseBidBy50()
    if not state.active then return end

    local sorted = GetSortedBids()
    local amount = MIN_BID
    if #sorted > 0 then
        amount = sorted[1].amount + MIN_STEP
    end

    if IsDebugChat() then
        RawSendChat(tostring(amount), "SAY")
        return
    end

    if GetNumRaidMembers() > 0 then
        RawSendChat(tostring(amount), "RAID")
    else
        Notify("Вне рейда включите Чат для отладки, чтобы сделать ставку.")
    end
end

local function AddBackgroundImage(parent, texturePath, alpha)
    local bg = parent:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, -12)
    bg:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -12, 12)
    bg:SetTexture(texturePath)
    bg:SetAlpha(alpha or 0.88)
    return bg
end

local function CreateAuctionFrame()
    local f = CreateFrame("Frame", "EProllAuctionFrame", UIParent)
    f:SetWidth(285)
    f:SetHeight(260)
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
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -13)
    title:SetText("EProll")

    local itemButton = CreateFrame("Button", nil, f)
    itemButton:SetWidth(30)
    itemButton:SetHeight(30)
    itemButton:SetPoint("TOPLEFT", f, "TOPLEFT", 17, -34)
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

    local itemText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    itemText:SetPoint("LEFT", itemButton, "RIGHT", 7, 0)
    itemText:SetWidth(210)
    itemText:SetHeight(30)
    itemText:SetJustifyH("LEFT")
    f.itemText = itemText

    local headerName = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    headerName:SetPoint("TOPLEFT", f, "TOPLEFT", 42, -72)
    headerName:SetText("Игрок")

    local headerBid = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    headerBid:SetPoint("TOPRIGHT", f, "TOPRIGHT", -31, -72)
    headerBid:SetText("EP")

    local listParent = CreateFrame("Frame", nil, f)
    listParent:SetPoint("TOPLEFT", f, "TOPLEFT", 17, -90)
    listParent:SetWidth(249)
    listParent:SetHeight(AUCTION_VISIBLE_ROWS * AUCTION_ROW_HEIGHT)

    for i = 1, AUCTION_VISIBLE_ROWS do
        local row = CreateFrame("Frame", nil, listParent)
        row:SetWidth(227)
        row:SetHeight(AUCTION_ROW_HEIGHT)
        if i == 1 then
            row:SetPoint("TOPLEFT", listParent, "TOPLEFT", 0, 0)
        else
            row:SetPoint("TOPLEFT", auctionRows[i - 1], "BOTTOMLEFT", 0, 0)
        end

        local rank = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        rank:SetPoint("LEFT", row, "LEFT", 0, 0)
        rank:SetWidth(24)
        rank:SetJustifyH("RIGHT")
        row.rank = rank

        local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        name:SetPoint("LEFT", rank, "RIGHT", 5, 0)
        name:SetWidth(140)
        name:SetJustifyH("LEFT")
        row.name = name

        local bid = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        bid:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        bid:SetWidth(55)
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
    status:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 17, 48)
    status:SetWidth(251)
    status:SetJustifyH("LEFT")
    f.status = status

    local raise = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    raise:SetWidth(112)
    raise:SetHeight(22)
    raise:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 15)
    raise:SetText("Повысить на 50")
    raise:SetScript("OnClick", RaiseBidBy50)
    f.raiseButton = raise

    local winner = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    winner:SetWidth(137)
    winner:SetHeight(22)
    winner:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 15)
    winner:SetText("Объявить победителя")
    winner:SetScript("OnClick", AnnounceWinner)
    f.winnerButton = winner

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -3, -3)
    close:SetScript("OnClick", function()
        state.auctionWindowVisible = false
        f:Hide()
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
    if not button or type(button.GetID) ~= "function" then return nil end

    local slot = button:GetID()
    local parent = type(button.GetParent) == "function" and button:GetParent() or nil
    local bag = parent and type(parent.GetID) == "function" and parent:GetID() or nil

    if type(slot) ~= "number" or type(bag) ~= "number" then
        return nil
    end

    return GetContainerItemLink(bag, slot)
end

local function GetMouseoverItemLink()
    local focus = GetMouseFocus and GetMouseFocus() or nil
    local current = focus
    for _ = 1, 8 do
        if not current then break end

        local link = LinkFromContainerButton(current)
        if link then
            return link
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
                    local link = LinkFromContainerButton(button)
                    if link then
                        return link
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
        state.itemTexture = GetItemTexture(link)
        state.owner = sender
        state.auctionWindowVisible = true
        wipe(state.bids)
        wipe(state.bidSequence)
        state.bidOrder = 0
        RefreshAuctionFrame()
        return
    end

    if not state.active or ShortName(state.owner) ~= sender then
        return
    end

    if command == "B" then
        local bidder, amount, sequence = string.match(rest, "^([^\t]+)\t(%d+)\t(%d+)$")
        amount = tonumber(amount)
        sequence = tonumber(sequence)
        if not bidder or not amount or not sequence then return end

        state.bids[bidder] = amount
        state.bidSequence[bidder] = sequence
        if sequence > state.bidOrder then
            state.bidOrder = sequence
        end
        RefreshAuctionFrame()
        return
    end

    if command == "R" then
        local bidder = rest
        if bidder and bidder ~= "" then
            state.bids[bidder] = nil
            state.bidSequence[bidder] = nil
            RefreshAuctionFrame()
        end
        return
    end

    if command == "E" then
        EndAuctionLocal()
        return
    end
end

function EProll_AuctionMouseover()
    local link = GetMouseoverItemLink()
    if not link then
        Notify("Наведите курсор на предмет в сумке и нажмите назначенную клавишу.")
        return
    end
    StartAuction(link, GetItemTexture(link))
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

    local allLootDesc = p:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    allLootDesc:SetPoint("TOPLEFT", allLoot, "BOTTOMLEFT", 4, -2)
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

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("CHAT_MSG_RAID")
frame:RegisterEvent("CHAT_MSG_RAID_LEADER")
frame:RegisterEvent("CHAT_MSG_SAY")
frame:RegisterEvent("CHAT_MSG_ADDON")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == ADDON then
            EnsureDB()
        end
        return
    end

    if event == "PLAYER_LOGIN" then
        EnsureDB()
        CreateAuctionFrame()
        CreateLootFrame()
        CreateOptionsPanel()
        if type(_G.RegisterAddonMessagePrefix) == "function" then
            _G.RegisterAddonMessagePrefix(SYNC_PREFIX)
        end
        if not EPGP then
            Notify("Не найден EPGP. Проверьте, что EPGP включён.")
        end
        return
    end

    if event == "LOOT_OPENED" then
        ScanLoot()
        return
    end

    if event == "CHAT_MSG_ADDON" then
        local prefix, message, channel, sender = ...
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
