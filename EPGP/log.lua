--
-- GetNumRecords(): Returns the number of log records.
--
-- GetLogRecord(i): Returns the ith log record starting 0.
--
-- ExportLog(): Returns a string with the data of the exported log for
-- import into the web application.
--
-- UndoLastAction(): Removes the last entry from the log and undoes
-- its action. The undone action is not logged.
--
-- This module also fires the following messages.
--
-- LogChanged(n): Fired when the log is changed. n is the new size of
-- the log.
--

local mod = EPGP:NewModule("log", "AceComm-3.0", "AceEvent-3.0", "AceTimer-3.0")

local L = LibStub:GetLibrary("AceLocale-3.0"):GetLocale("EPGP")
local GS = LibStub("LibGuildStorage-1.0")
local JSON = LibStub("LibJSON-1.0")
local deformat = AceLibrary("Deformat-2.0")

local CallbackHandler = LibStub("CallbackHandler-1.0")
if not mod.callbacks then
    mod.callbacks = CallbackHandler:New(mod)
end
local callbacks = mod.callbacks

local timestamp_t = {}
local function GetTimestamp(diff)
    return time()
end

local function CheckFilter(log, str)
    return string.find(string.lower(log[3]), string.lower(str))
end

local LOG_FORMAT = "LOG:%d\31%s\31%s\31%s\31%d"
local LOG_FORMAT_NEW = "LOG:%d\31%s\31%s\31%s\31%d\31%s"
local exists_logs = {}

local function LogKey(entry)
    if type(entry) ~= "table" or type(entry[1]) ~= "number" or
        type(entry[2]) ~= "string" or type(entry[3]) ~= "string" or
        type(entry[4]) ~= "string" or type(entry[5]) ~= "number" then
        return nil
    end
    return string.format(LOG_FORMAT_NEW, entry[1], entry[2], entry[3], entry[4], entry[5], entry[6] or "Unknown")
end

local function ParseSyncEntry(msg, sender)
    if type(msg) ~= "string" then return nil end
    local timestamp, kind, name, reason, amount, officer = deformat(msg, LOG_FORMAT_NEW)
    if not timestamp then
        timestamp, kind, name, reason, amount = deformat(msg, LOG_FORMAT)
        officer = "Unknown"
    end
    timestamp = tonumber(timestamp)
    amount = tonumber(amount)
    if not timestamp or not amount or not name or name == "" or
        type(reason) ~= "string" or (kind ~= "EP" and kind ~= "GP" and kind ~= "BI") then
        return nil
    end
    if timestamp < 0 or timestamp > time() + 3600 then return nil end
    local entry = {timestamp, kind, name, reason, amount, officer or "Unknown"}
    return entry, LogKey(entry)
end

local function RefreshLogViews()
    table.sort(mod.db.profile.log, function(a, b) return a[1] < b[1] end)
    local filtered = mod.db.profile.filtred_logs
    table.wipe(filtered)
    local filter = mod.db.profile.filter or ""
    for _, entry in ipairs(mod.db.profile.log) do
        if CheckFilter(entry, filter) then
            table.insert(filtered, entry)
        end
    end
    mod.callbacks:Fire("LogChanged", #mod.db.profile.log)
end

local function log(...)
    -- print("EPGP_SYNC", ...)
end

local function AppendToLog(kind, event_type, name, reason, amount, mass, undo)
    -- Clear the redo table
    if not undo then
        for k, _ in ipairs(mod.db.profile.redo) do
            mod.db.profile.redo[k] = nil
        end
    end

    local entry = { GetTimestamp(), kind, name, reason, amount, UnitName("player")}
    table.insert(mod.db.profile.log, entry)
    exists_logs[string.format(LOG_FORMAT_NEW, unpack(entry))] = true

    if CheckFilter(entry, mod.db.profile.filter) then
        table.insert(mod.db.profile.filtred_logs, entry)
    end

    mod:SendCommMessage("EPGP", string.format(LOG_FORMAT_NEW, unpack(entry)), "GUILD", nil, "BULK")
    callbacks:Fire("LogChanged", #mod.db.profile.log)
end

function mod:LogSync(prefix, msg, distribution, sender)
    if prefix ~= "EPGP" or sender == UnitName("player") or distribution ~= "GUILD" then
        return
    end
    local entry, key = ParseSyncEntry(msg, sender)
    if entry and key and not exists_logs[key] then
        table.insert(self.db.profile.log, entry)
        exists_logs[key] = true
        RefreshLogViews()
    end
end

local function LogRecordToString(record)
    local timestamp, kind, name, reason, amount, officer = unpack(record)

    if kind == "EP" then
        return string.format(L["%s: %+d EP (%s) to %s from $s"],
            date("%Y-%m-%d %H:%M", timestamp), amount, reason, name, officer)
    elseif kind == "GP" then
        return string.format(L["%s: %+d GP (%s) to %s from $s"],
            date("%Y-%m-%d %H:%M", timestamp), amount, reason, name, officer)
    elseif kind == "BI" then
        return string.format(L["%s: %s to %s from $s"],
            date("%Y-%m-%d %H:%M", timestamp), reason, name, officer)
    else
        assert(false, "Unknown record in the log")
    end
end

function mod:SetFilter(search)
    self.db.profile.filter = search
    table.wipe(self.db.profile.filtred_logs)
    for _, log in ipairs(self.db.profile.log) do
        if CheckFilter(log, search) then
            table.insert(self.db.profile.filtred_logs, log)
        end
    end

    callbacks:Fire("LogChanged", #self.db.profile.filtred_logs)
end

function mod:GetPersonalLogRecords(name)
    local records = {}
    if type(name) ~= "string" or name == "" then
        return records
    end
    for i = #self.db.profile.log, 1, -1 do
        local entry = self.db.profile.log[i]
        if entry[3] == name then
            table.insert(records, LogRecordToString(entry))
        end
    end
    return records
end

function mod:GetEPGraphData(name, rangeDays)
    local now = time()
    local today = date("*t", now)
    local todayNoon = time({year = today.year, month = today.month, day = today.day, hour = 12})
    local firstTimestamp
    for _, entry in ipairs(self.db.profile.log) do
        if entry[2] == "EP" and entry[3] == name and type(entry[1]) == "number" and type(entry[5]) == "number" then
            if not firstTimestamp or entry[1] < firstTimestamp then
                firstTimestamp = entry[1]
            end
        end
    end

    local days = tonumber(rangeDays)
    local cdStart
    if rangeDays == "cd" then
        local utc = date("!*t", now)
        local elapsed = ((utc.wday - 5 + 7) % 7) * 86400 + utc.hour * 3600 + utc.min * 60 + utc.sec
        cdStart = now - elapsed
        local first = date("*t", cdStart)
        local firstNoon = time({year = first.year, month = first.month, day = first.day, hour = 12})
        days = math.floor((todayNoon - firstNoon) / 86400 + 0.5) + 1
    end
    if not days or days <= 0 then
        local oldest = date("*t", firstTimestamp or now)
        local oldestNoon = time({year = oldest.year, month = oldest.month, day = oldest.day, hour = 12})
        days = math.floor((todayNoon - oldestNoon) / 86400 + 0.5) + 1
    end
    days = math.max(1, math.floor(days))
    local span = math.max(1, math.ceil(days / 48))
    local buckets = {}
    local dayBuckets = {}
    for i = 1, days do
        local day = date("*t", todayNoon - (days - i) * 86400)
        local index = math.floor((i - 1) / span) + 1
        local dayStart = time({year = day.year, month = day.month, day = day.day, hour = 0, min = 0, sec = 0})
        if not buckets[index] then
            buckets[index] = {start = dayStart, finish = dayStart, earned = 0, spent = 0}
        end
        local endDay = time({year = day.year, month = day.month, day = day.day, hour = 23, min = 59, sec = 59})
        buckets[index].finish = math.min(endDay, now)
        dayBuckets[date("%Y-%m-%d", dayStart)] = index
    end

    local earned, spent = 0, 0
    for _, entry in ipairs(self.db.profile.log) do
        if entry[2] == "EP" and entry[3] == name and type(entry[1]) == "number" and type(entry[5]) == "number" then
            if entry[1] <= now and (not cdStart or entry[1] >= cdStart) then
                local bucket = buckets[dayBuckets[date("%Y-%m-%d", entry[1])]]
                if bucket then
                    if entry[5] > 0 then
                        bucket.earned = bucket.earned + entry[5]
                        earned = earned + entry[5]
                    elseif entry[5] < 0 then
                        bucket.spent = bucket.spent - entry[5]
                        spent = spent - entry[5]
                    end
                end
            end
        end
    end
    local currentEP = EPGP:GetEPGP(name)
    local runningBalance = currentEP
    for i = #buckets, 1, -1 do
        local bucket = buckets[i]
        bucket.change = bucket.earned - bucket.spent
        if type(runningBalance) == "number" then
            bucket.balance = runningBalance
            runningBalance = runningBalance - bucket.change
        end
    end
    return buckets, earned, spent, currentEP
end

function mod:GetNumRecords()
    if self.db.profile.filter == "" then
        return #self.db.profile.log
    end
    return #self.db.profile.filtred_logs
end

function mod:GetLogRecord(i)
    local logs = self.db.profile.filtred_logs
    if self.db.profile.filter == "" then
        logs = self.db.profile.log
    end

    local logsize = #logs
    assert(i >= 0 and i < logsize, "Index " .. i .. " is out of bounds")

    return LogRecordToString(logs[logsize - i])
end

function mod:CanUndo()
    if not CanEditOfficerNote() or not GS:IsCurrentState() then
        return false
    end
    return self:GetLastActionForUndo() ~= nil
end

function mod:GetLastActionForUndo()
    local skip_count = 0

    for i = #self.db.profile.log, 1, -1 do
        local log = self.db.profile.log[i]

        local is_undo = string.starts(log[4], L["Undo"])
        if not is_undo and skip_count == 0 then
            return log
        end

        if is_undo then
            skip_count = skip_count + 1
        else
            skip_count = skip_count - 1
        end
    end

    return nil
end

function mod:UndoLastAction()
    assert(#self.db.profile.log ~= 0)

    local record = mod:GetLastActionForUndo()
    if not record then
        return false
    end
    table.insert(self.db.profile.redo, record)

    local timestamp, kind, name, reason, amount, officer = unpack(record)

    local ep, gp, main = EPGP:GetEPGP(name)

    if kind == "EP" then
        EPGP:IncEPBy(name, L["Undo"] .. " " .. reason, -amount, false, true)
    elseif kind == "GP" then
        EPGP:IncGPBy(name, L["Undo"] .. " " .. reason, -amount, false, true)
    elseif kind == "BI" then
        EPGP:BankItem(L["Undo"] .. " " .. reason, true)
    else
        assert(false, "Unknown record in the log")
    end

    callbacks:Fire("LogChanged", #self.db.profile.log)
    return true
end

function mod:CanRedo()
    if not CanEditOfficerNote() or not GS:IsCurrentState() then
        return false
    end

    return #self.db.profile.redo ~= 0
end

function mod:RedoLastUndo()
    if #self.db.profile.redo == 0 then
        return false
    end

    local record = self.db.profile.redo[#self.db.profile.redo]
    if type(record) ~= "table" then
        return false
    end
    local timestamp, kind, name, reason, amount, officer = unpack(record)

    if kind == "EP" then
        EPGP:IncEPBy(name, L["Redo"] .. " " .. reason, amount, false, true)
    elseif kind == "GP" then
        EPGP:IncGPBy(name, L["Redo"] .. " " .. reason, amount, false, true)
    elseif kind == "BI" then
        EPGP:BankItem(L["Redo"] .. " " .. reason, true)
    else
        return false
    end

    table.remove(self.db.profile.redo)
    callbacks:Fire("LogChanged", #self.db.profile.log)
    return true
end

-- This is kept for historical reasons: see
-- http://code.google.com/p/epgp/issues/detail?id=350.
function mod:Snapshot()
    local t = self.db.profile.snapshot
    if not t then
        t = {}
        self.db.profile.snapshot = t
    end
    t.time = GetTimestamp()
    GS:Snapshot(t)
end

local function swap(t, i, j)
    t[i], t[j] = t[j], t[i]
end

local function reverse(t)
    for i = 1, math.floor(#t / 2) do
        swap(t, i, #t - i + 1)
    end
end

string.starts = string.starts or function(str, start)
    return string.sub(str, 1, string.len(start)) == start
end
local timeReuse = 60 * 60 * 24 * 30
function mod:TrimToOneMonth()
    -- The log is sorted in reverse timestamp. We do not want to remove
    -- one item at a time since this will result in O(n^2) time. So we
    -- build it anew.
    local new_log = {}
    local last_timestamp = GetTimestamp() - timeReuse

    -- Go through the log in reverse order and stop when we reach an
    -- entry older than one month.
    for i = #self.db.profile.log, 1, -1 do
        local record = self.db.profile.log[i]
        if record[1] < last_timestamp then
            break
        end
        table.insert(new_log, record)
    end

    -- The new log is in reverse order now so reverse it.
    reverse(new_log)

    self.db.profile.log = new_log

    table.wipe(exists_logs)
    for _, entry in ipairs(new_log) do
        local key = LogKey(entry)
        if key then exists_logs[key] = true end
    end
    RefreshLogViews()
end

function mod:Export()
    local d = {}
    d.region = GetCVar("portal")
    d.guild = select(1, GetGuildInfo("player"))
    d.realm = GetRealmName()
    d.base_gp = EPGP:GetBaseGP()
    d.min_ep = EPGP:GetMinEP()
    d.decay_p = EPGP:GetDecayPercent()
    d.extras_p = EPGP:GetExtrasPercent()
    d.timestamp = GetTimestamp()

    d.roster = EPGP:ExportRoster()

    d.loot = {}
    for i, record in ipairs(self.db.profile.log) do
        local timestamp, kind, name, reason, amount, officer = unpack(record)
        if kind == "GP" or kind == "BI" then
            local id = tonumber(reason:match("item:(%d+)"))
            if id then
                table.insert(d.loot, { timestamp, name, id, amount })
            end
        end
    end

    return JSON.Serialize(d):gsub("\124", "\124\124")
end

function mod:Import(jsonStr)
    local success, d = pcall(JSON.Deserialize, jsonStr)
    if not success then
        EPGP:Print(L["The imported data is invalid"])
        return
    end

    if d.region and d.region ~= GetCVar("portal") then
        EPGP:Print(L["The imported data is invalid"])
        return
    end

    if d.guild ~= select(1, GetGuildInfo("player")) or
        d.realm ~= GetRealmName() then
        EPGP:Print(L["The imported data is invalid"])
        return
    end

    local types = {
        timestamp = "number",
        roster = "table",
        decay_p = "number",
        extras_p = "number",
        min_ep = "number",
        base_gp = "number",
    }
    for k, t in pairs(types) do
        if type(d[k]) ~= t then
            EPGP:Print(L["The imported data is invalid"])
            return
        end
    end

    for _, entry in pairs(d.roster) do
        if type(entry) ~= "table" then
            EPGP:Print(L["The imported data is invalid"])
            return
        else
            local types = {
                [1] = "string",
                [2] = "number",
                [3] = "number",
            }
            for k, t in pairs(types) do
                if type(entry[k]) ~= t then
                    EPGP:Print(L["The imported data is invalid"])
                    return
                end
            end
        end
    end

    EPGP:Print(L["Importing data snapshot taken at: %s"]:format(
        date("%Y-%m-%d %H:%M", d.timestamp)))
    EPGP:SetGlobalConfiguration(d.decay_p, d.extras_p, d.base_gp, d.min_ep)
    EPGP:ImportRoster(d.roster, d.base_gp)

    -- Trim the log if necessary.
    local timestamp = d.timestamp
    while true do
        local records = #self.db.profile.log
        if records == 0 then
            break
        end

        if self.db.profile.log[records][1] > timestamp then
            table.remove(self.db.profile.log)
        else
            break
        end
    end
    -- Add the redos back to the log if necessary.
    while #self.db.profile.redo ~= 0 do
        local record = table.remove(self.db.profile.redo)
        if record[1] < timestamp then
            table.insert(self.db.profile.log, record)
            exists_logs[string.format(LOG_FORMAT_NEW, unpack(record))] = true
        end
    end

    table.wipe(exists_logs)
    for _, entry in ipairs(self.db.profile.log) do
        local key = LogKey(entry)
        if key then exists_logs[key] = true end
    end
    RefreshLogViews()
end

mod.dbDefaults = {
    profile = {
        enabled = true,
        log = {},
        redo = {},
    }
}

local syncDirty = false
local lastSyncRequest
local lastFullRequest
local hasCompletedSync = false
local knownOnline = {}
local onlineReady = false
local syncWindow = 90 * 24 * 60 * 60

local function IsGuildSender(sender)
    if type(sender) ~= "string" or sender == "" then return false end
    if GS:GetRank(sender) then return true end
    local total = GetNumGuildMembers(true) or 0
    for i = 1, total do
        if GetGuildRosterInfo(i) == sender then
            return true
        end
    end
    return false
end

function mod:FinalizeSync()
    if not syncDirty then return end
    syncDirty = false
    RefreshLogViews()
end

function mod:RequestLogSync(days)
    if not IsInGuild() then return end
    local now = GetTime()
    if lastSyncRequest and now - lastSyncRequest < 60 then return end
    lastSyncRequest = now
    if days == nil or days >= 90 then
        lastFullRequest = now
    end
    local window = (type(days) == "number" and days > 0 and days or 90) * 24 * 60 * 60
    self:SendCommMessage("EPGP_SYNC_REQUEST", tostring(math.floor(time() - window)), "GUILD", nil, "BULK")
end

function mod:PeriodicLogSync()
    if not hasCompletedSync or not lastFullRequest or GetTime() - lastFullRequest >= 14400 then
        self:RequestLogSync(90)
    else
        self:RequestLogSync(1)
    end
end

function mod:GUILD_ROSTER_UPDATE()
    if not IsInGuild() then return end
    local total = GetNumGuildMembers(true)
    if not total or total < 1 then return end
    local online = {}
    local newOnline = false
    for i = 1, total do
        local name, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
        if name and isOnline then
            online[name] = true
            if onlineReady and not knownOnline[name] and name ~= UnitName("player") then
                newOnline = true
            end
        end
    end
    knownOnline = online
    onlineReady = true
    if newOnline then
        self:RequestLogSync(90)
    end
end

function mod:EPGP_SYNC_REQUEST(tag, msg, channel, sender)
    if channel ~= "GUILD" or sender == UnitName("player") or not IsGuildSender(sender) then
        return
    end
    local from_timestamp = tonumber(msg)
    if not from_timestamp then return end
    from_timestamp = math.max(from_timestamp, time() - syncWindow)
    local logs = self.db.profile.log
    local sent = 0
    for _, entry in ipairs(logs) do
        if entry[1] > from_timestamp then
            local key = LogKey(entry)
            if key then
                self:SendCommMessage("EPGP_SYNC_LOG", key, "WHISPER", sender, "BULK")
                sent = sent + 1
            end
        end
    end
    self:SendCommMessage("EPGP_SYNC_LOG", "END:" .. tostring(sent), "WHISPER", sender, "BULK")
end

function mod:EPGP_SYNC_LOG(tag, msg, channel, sender)
    if channel ~= "WHISPER" or sender == UnitName("player") or not IsGuildSender(sender) then
        return
    end
    if string.sub(msg, 1, 4) == "END:" then
        return self:EPGP_SYNC_RESPONSE(tag, msg, channel, sender)
    end
    local entry, key = ParseSyncEntry(msg, sender)
    if not entry or not key or entry[1] < time() - syncWindow or exists_logs[key] then
        return
    end
    table.insert(self.db.profile.log, entry)
    exists_logs[key] = true
    if not syncDirty then
        syncDirty = true
        self:ScheduleTimer("FinalizeSync", 15)
    end
end

function mod:EPGP_SYNC_RESPONSE(tag, msg, channel, sender)
    if channel ~= "WHISPER" or sender == UnitName("player") or not IsGuildSender(sender) then
        return
    end
    if not string.match(msg, "^END:%d+$") then return end
    hasCompletedSync = true
    self:FinalizeSync()
end

function mod:OnEnable()
    EPGP.RegisterCallback(mod, "EPAward", AppendToLog, "EP")
    EPGP.RegisterCallback(mod, "GPAward", AppendToLog, "GP")
    EPGP.RegisterCallback(mod, "BankedItem", AppendToLog, "BI")
    mod:RegisterComm("EPGP", "LogSync")
    mod:RegisterComm("EPGP_SYNC_REQUEST", "EPGP_SYNC_REQUEST")
    mod:RegisterComm("EPGP_SYNC_LOG", "EPGP_SYNC_LOG")

    -- Upgrade the logs from older dbs
    if EPGP.db.profile.log then
        self.db.profile.log = EPGP.db.profile.log
        EPGP.db.profile.log = nil
    end
    if EPGP.db.profile.redo then
        self.db.profile.redo = EPGP.db.profile.redo
        EPGP.db.profile.redo = nil
    end

    self.db.profile.filter = ""
    self.db.profile.filtred_logs = {}

    table.sort(self.db.profile.log, function (a, b)
        return a[1] < b[1]
    end)

    table.wipe(exists_logs)
    for _, entry in ipairs(self.db.profile.log) do
        entry[6] = entry[6] or "Unknown"
        local key = LogKey(entry)
        if key then exists_logs[key] = true end
    end

    syncDirty = false
    hasCompletedSync = false
    lastSyncRequest = nil
    lastFullRequest = nil
    knownOnline = {}
    onlineReady = false
    self:RegisterEvent("GUILD_ROSTER_UPDATE")
    self:GUILD_ROSTER_UPDATE()
    self:RequestLogSync(90)
    self:ScheduleRepeatingTimer("PeriodicLogSync", 900)

    -- This is kept for historical reasons. See:
    -- http://code.google.com/p/epgp/issues/detail?id=350.
    EPGP.db.RegisterCallback(self, "OnDatabaseShutdown", "Snapshot")
end

function mod:OnDisable()
    self:UnregisterEvent("GUILD_ROSTER_UPDATE")
    self:CancelAllTimers()
    self:UnregisterAllComm()
end
