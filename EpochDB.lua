-- ============================================================
--  EpochDB — Data Collection Addon for Project Epoch (3.3.5)
--  Version: 1.2.0
-- ============================================================

local ADDON_NAME = "EpochDB"
EpochDB = EpochDB or {}
EpochDB.version = "1.2.0"
EpochDB._bagScanPending = false
EpochDB._debug = false

-- ── HELPERS ──────────────────────────────────────────────────

local function getCoords()
    local x, y = GetPlayerMapPosition("player")
    return string.format("%.2f, %.2f", x * 100, y * 100)
end

local function ts()
    return date("%Y-%m-%d %H:%M:%S")
end

local function eprint(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cFFc8a84b[EpochDB]|r " .. tostring(msg))
end

local function log(msg)
    if EpochDB._debug then eprint("|cff888888" .. tostring(msg) .. "|r") end
end

local function getZone()
    local zone = GetRealZoneText()
    if not zone or zone == "" or zone == "Unknown" then return nil end
    return zone
end

local function getSubZone()
    return GetSubZoneText() or ""
end

local function makeSessionId()
    local p = UnitName("player") or "Player"
    local r = GetRealmName() or "Realm"
    return (p .. "-" .. r .. "-" .. tostring(time())):gsub("%s+", "")
end

-- ── GUID UTILITIES ───────────────────────────────────────────

local function GetEntryIdFromGUID(guid)
    if not guid then return nil end
    local s = tostring(guid)
    if s:find("-", 1, true) then
        local parts = { strsplit("-", s) }
        local id = tonumber(parts[6] or parts[5])
        if id and id > 0 then return id end
        return nil
    end
    local up = s:gsub("^0x", ""):upper()
    if #up < 10 then return nil end
    if up:sub(1, 2) == "F1" then
        local id = tonumber(up:sub(5, 10), 16)
        if id and id > 0 then return id end
    end
    local nB = tonumber(up:sub(5, 10), 16)
    if nB and nB > 0 then return nB end
    return nil
end

-- ── MOB SNAPSHOTS ────────────────────────────────────────────

local mobSnap = {}

local function snapshotUnit(unit)
    if not UnitExists(unit) then return end
    local guid = UnitGUID(unit)
    if not guid then return end
    mobSnap[guid] = {
        guid           = guid,
        id             = GetEntryIdFromGUID(guid),
        name           = UnitName(unit),
        level          = UnitLevel and UnitLevel(unit) or nil,
        classification = UnitClassification and UnitClassification(unit) or nil,
        creatureType   = UnitCreatureType and UnitCreatureType(unit) or nil,
        creatureFamily = UnitCreatureFamily and UnitCreatureFamily(unit) or nil,
        reaction       = UnitReaction and UnitReaction("player", unit) or nil,
        maxHp          = UnitHealthMax and UnitHealthMax(unit) or nil,
        maxMana        = UnitManaMax and UnitManaMax(unit) or nil,
    }
end

-- ── KILL TRACKING ────────────────────────────────────────────

local KILL_DEDUP_WINDOW = 300
local seenKillByGUID = {}

local function resetKillDedup()
    wipe(seenKillByGUID)
end

local function killSeenRecently(guid)
    local t = seenKillByGUID[guid]
    return t and (time() - t) < KILL_DEDUP_WINDOW
end

local function markKill(guid)
    if guid then seenKillByGUID[guid] = time() end
end

local function handleCombatLog(...)
    if not EpochDBData or not EpochDBData.kills then return end

    local timestamp, event, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags = ...

    if event ~= "UNIT_DIED" and event ~= "PARTY_KILL" then return end
    if not destGUID or not destName or destName == "" then return end
    if bit.band(destFlags, COMBATLOG_OBJECT_TYPE_PLAYER) ~= 0 then return end

    local affMine  = bit.band(sourceFlags, COMBATLOG_OBJECT_AFFILIATION_MINE)
    local affParty = bit.band(sourceFlags, COMBATLOG_OBJECT_AFFILIATION_PARTY)
    local affRaid  = bit.band(sourceFlags, COMBATLOG_OBJECT_AFFILIATION_RAID)
    if affMine == 0 and affParty == 0 and affRaid == 0 then return end

    if killSeenRecently(destGUID) then return end
    markKill(destGUID)

    local zone = getZone()
    if not zone then return end

    local npcId = GetEntryIdFromGUID(destGUID)
    local snap = mobSnap[destGUID]
    local x, y = GetPlayerMapPosition("player")
    local coords = string.format("%.2f, %.2f", x * 100, y * 100)
    local key = destName .. "|" .. zone

    if not EpochDBData.kills[key] then
        EpochDBData.kills[key] = {
            name           = destName,
            npcId          = npcId,
            zone           = zone,
            subZone        = getSubZone(),
            coords         = coords,
            level          = snap and snap.level or nil,
            classification = snap and snap.classification or nil,
            creatureType   = snap and snap.creatureType or nil,
            maxHp          = snap and snap.maxHp or nil,
            count          = 0,
        }
    end

    local entry = EpochDBData.kills[key]
    entry.count  = entry.count + 1
    entry.coords = coords
    if snap then
        entry.level          = snap.level
        entry.classification = snap.classification
    end
    log("kill " .. destName .. " npcId=" .. tostring(npcId))
end

-- ── LOOT TRACKING ────────────────────────────────────────────

local function DetectLootSource()
    if not GetLootSourceInfo then return nil, nil end
    local num = GetNumLootItems() or 0
    local mobGuid, mobId
    for slot = 1, num do
        local src = { GetLootSourceInfo(slot) }
        for i = 1, #src, 2 do
            local guid = src[i]
            if guid and not mobGuid then
                mobGuid = guid
                mobId   = GetEntryIdFromGUID(guid)
            end
        end
    end
    if mobGuid then return mobGuid, mobId end
    if UnitExists("target") then
        local tg = UnitGUID("target")
        return tg, GetEntryIdFromGUID(tg)
    end
    return nil, nil
end

local function handleLootOpened()
    if not EpochDBData or not EpochDBData.loot then return end

    local sourceGUID, sourceNpcId = DetectLootSource()
    local sourceName = nil
    if sourceGUID and mobSnap[sourceGUID] then
        sourceName = mobSnap[sourceGUID].name
    elseif UnitExists("target") then
        sourceName = UnitName("target")
    end
    if not sourceName or sourceName == "" then sourceName = nil end

    local currentCoords = getCoords()
    local numItems = GetNumLootItems()
    for slot = 1, numItems do
        local _, itemName, _, _, quality = GetLootSlotInfo(slot)
        local link = GetLootSlotLink(slot)

        if link then
            local itemID = link:match("item:(%d+)")
            if itemID and itemName and itemName ~= "" then
                if not EpochDBData.loot[itemID] then
                    EpochDBData.loot[itemID] = {
                        id      = itemID,
                        name    = itemName,
                        quality = quality or 1,
                        count   = 0,
                        sources = {},
                    }
                end

                EpochDBData.loot[itemID].count = EpochDBData.loot[itemID].count + 1

                if sourceName then
                    local sourceKey = sourceName .. " (" .. currentCoords .. ")"
                    EpochDBData.loot[itemID].sources[sourceKey] =
                        (EpochDBData.loot[itemID].sources[sourceKey] or 0) + 1
                end
            end
        end
    end
    log("loot opened, source=" .. tostring(sourceName) .. " npcId=" .. tostring(sourceNpcId))
end

-- ── TOOLTIP SCANNING ─────────────────────────────────────────

local ScannerTip = nil
local function initScannerTip()
    if ScannerTip then return end
    local success, result = pcall(function()
        local tip = CreateFrame("GameTooltip", "EpochDBScannerTip", nil, "GameTooltipTemplate")
        tip:SetOwner(WorldFrame, "ANCHOR_NONE")
        return tip
    end)
    if success then
        ScannerTip = result
    end
end

local function safeSetTooltip(tip, link)
    if not tip or not link then return false end
    local itemId = link:match("item:(%d+)")
    if itemId and tip.SetItemByID then
        local ok = pcall(tip.SetItemByID, tip, tonumber(itemId))
        if ok then return true end
    end
    local sanitized = itemId and ("item:" .. itemId) or link
    if tip.SetHyperlink then
        local ok = pcall(tip.SetHyperlink, tip, sanitized)
        if ok then return true end
        if sanitized ~= link then
            ok = pcall(tip.SetHyperlink, tip, link)
            if ok then return true end
        end
    end
    return false
end

local function getItemExtras(link)
    if not ScannerTip then initScannerTip() end
    if not ScannerTip then return nil end
    if not ScannerTip:GetOwner() then
        ScannerTip:SetOwner(WorldFrame or UIParent, "ANCHOR_NONE")
    end
    ScannerTip:ClearLines()
    if not safeSetTooltip(ScannerTip, link) then return nil end

    local extras = {
        bindType   = nil,
        requires   = {},
        effects    = {},
        setBonuses = {},
        slotName   = nil,
        armorType  = nil,
        armor      = nil,
        attrs      = {},
        weapon     = {},
    }
    local function num(s) return tonumber((tostring(s or ""):gsub(",", ""))) end

    for i = 2, ScannerTip:NumLines() do
        local fs = _G["EpochDBScannerTipTextLeft"..i]
        if not fs then break end
        local text = fs:GetText()
        if not text or text == "" then break end
        text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        local tl = text:lower()

        -- Bind type
        if tl:find("binds when picked up", 1, true) then extras.bindType = extras.bindType or "BOP"
        elseif tl:find("binds when equipped", 1, true) then extras.bindType = extras.bindType or "BOE"
        elseif tl:find("binds when used", 1, true) then extras.bindType = extras.bindType or "BOU"
        elseif tl:find("quest item", 1, true) then extras.bindType = extras.bindType or "QUEST" end

        -- Slot name
        if text == "Head" or text == "Neck" or text == "Shoulder" or text == "Back"
            or text == "Chest" or text == "Wrist" or text == "Hands" or text == "Waist"
            or text == "Legs" or text == "Feet" or text == "Finger" or text == "Trinket"
            or text == "One-Hand" or text == "Two-Hand" or text == "Off Hand"
            or text == "Main Hand" or text == "Held In Off-hand" or text == "Shield"
            or text == "Ranged" or text == "Thrown" then
            extras.slotName = extras.slotName or text
        end

        -- Armor type
        if text == "Cloth" or text == "Leather" or text == "Mail" or text == "Plate" then
            extras.armorType = extras.armorType or text
        end

        -- Armor value
        local a = text:match("(%d+)%s+[Aa]rmor")
        if a then extras.armor = extras.armor or num(a) end

        -- Primary attributes
        local v, stat = text:match("^([%+%-]%d+)%s+(%a+)")
        if v and stat then
            stat = stat:lower(); local val = num(v)
            if stat == "strength"  or stat == "str" then extras.attrs.str = (extras.attrs.str or 0) + val end
            if stat == "agility"   or stat == "agi" then extras.attrs.agi = (extras.attrs.agi or 0) + val end
            if stat == "stamina"   or stat == "sta" then extras.attrs.sta = (extras.attrs.sta or 0) + val end
            if stat == "intellect" or stat == "int" then extras.attrs.int = (extras.attrs.int or 0) + val end
            if stat == "spirit"    or stat == "spi" then extras.attrs.spi = (extras.attrs.spi or 0) + val end
        end

        -- Secondary stats
        local crit  = text:match("^([%+%-]%d+).-[Cc]ritical [Ss]trike")
        if crit then extras.attrs.crit = (extras.attrs.crit or 0) + num(crit) end
        local hitv  = text:match("^([%+%-]%d+).-[Hh]it [Rr]ating")
        if hitv then extras.attrs.hit = (extras.attrs.hit or 0) + num(hitv) end
        local haste = text:match("^([%+%-]%d+).-[Hh]aste")
        if haste then extras.attrs.haste = (extras.attrs.haste or 0) + num(haste) end
        local ap    = text:match("^([%+%-]%d+).-[Aa]ttack [Pp]ower")
        if ap then extras.attrs.ap = (extras.attrs.ap or 0) + num(ap) end
        local sp    = text:match("^([%+%-]%d+).-[Ss]pell [Pp]ower")
        if sp then extras.attrs.sp = (extras.attrs.sp or 0) + num(sp) end
        local mp5   = text:match("^([%+%-]%d+).-[Mm][Pp]5")
        if mp5 then extras.attrs.mp5 = (extras.attrs.mp5 or 0) + num(mp5) end
        local def   = text:match("^([%+%-]%d+).-[Dd]efense")
        if def then extras.attrs.def = (extras.attrs.def or 0) + num(def) end

        -- Weapon stats
        local dmin, dmax = text:match("(%d+)%s*%-%s*(%d+)%s+[Dd]amage")
        if dmin and dmax then extras.weapon.min = num(dmin); extras.weapon.max = num(dmax) end
        local dps = text:match("([%d%.]+)%s+[Dd]amage per second")
        if dps then extras.weapon.dps = tonumber(dps) end
        local spd = text:match("[Ss]peed%s*([%d%.]+)")
        if spd then extras.weapon.speed = tonumber(spd) end

        -- Requirements
        if tl:find("^requires") then table.insert(extras.requires, text) end

        -- Effects
        if text:find("^Use:") then table.insert(extras.effects, { type = "use", text = text:gsub("^Use:%s*", "") }) end
        if text:find("^Equip:") then table.insert(extras.effects, { type = "equip", text = text:gsub("^Equip:%s*", "") }) end
        if text:find("^Chance on hit:") then table.insert(extras.effects, { type = "chance", text = text:gsub("^Chance on hit:%s*", "") }) end

        -- Set bonuses
        if text:find("^Set:") or text:find("^%(") then table.insert(extras.setBonuses, text) end
    end

    if not next(extras.attrs) then extras.attrs = nil end
    if not next(extras.weapon) then extras.weapon = nil end
    if #extras.requires == 0 then extras.requires = nil end
    if #extras.effects == 0 then extras.effects = nil end
    if #extras.setBonuses == 0 then extras.setBonuses = nil end
    return extras
end

-- ── ITEM TRACKING (bag & bank scan) ──────────────────────────

local function scanContainer(bag)
    for slot = 1, GetContainerNumSlots(bag) do
        local link = GetContainerItemLink(bag, slot)
        if link then
            local itemID = link:match("item:(%d+)")
            if itemID and not EpochDBData.items[itemID] then
                local name, _, quality, ilvl, _, iType, iSubType, _, iSlot =
                    GetItemInfo(link)
                if name then
                    EpochDBData.items[itemID] = {
                        id      = itemID,
                        name    = name,
                        quality = quality or 1,
                        ilvl    = ilvl or 0,
                        type    = iType or "",
                        subType = iSubType or "",
                        slot    = iSlot or "",
                        extras  = getItemExtras(link),
                    }
                end
            end
        end
    end
end

local function scanBags()
    if not EpochDBData or not EpochDBData.items then return end
    for bag = 0, NUM_BAG_SLOTS do
        scanContainer(bag)
    end
    EpochDB._bagScanPending = false
end

local function scanBank()
    if not EpochDBData or not EpochDBData.items then return end
    -- Main bank container (id -1)
    scanContainer(-1)
    -- Bank bag slots
    for bag = NUM_BAG_SLOTS + 1, NUM_BAG_SLOTS + NUM_BANKBAGSLOTS do
        scanContainer(bag)
    end
end

local function scanEquipped()
    if not EpochDBData or not EpochDBData.items then return end
    for slot = 1, 19 do
        local link = GetInventoryItemLink("player", slot)
        if link then
            local itemID = link:match("item:(%d+)")
            if itemID and not EpochDBData.items[itemID] then
                local name, _, quality, ilvl, _, iType, iSubType, _, iSlot =
                    GetItemInfo(link)
                if name then
                    EpochDBData.items[itemID] = {
                        id      = itemID,
                        name    = name,
                        quality = quality or 1,
                        ilvl    = ilvl or 0,
                        type    = iType or "",
                        subType = iSubType or "",
                        slot    = iSlot or "",
                        extras  = getItemExtras(link),
                    }
                end
            end
        end
    end
end

local function scanGuildBank()
    if not EpochDBData or not EpochDBData.items then return end
    if not GetNumGuildBankTabs then return end
    local numTabs = GetNumGuildBankTabs()
    local slotsPerTab = MAX_GUILDBANK_SLOTS_PER_TAB or 98
    for tab = 1, numTabs do
        for slot = 1, slotsPerTab do
            local link = GetGuildBankItemLink(tab, slot)
            if link then
                local itemID = link:match("item:(%d+)")
                if itemID and not EpochDBData.items[itemID] then
                    local name, _, quality, ilvl, _, iType, iSubType, _, iSlot =
                        GetItemInfo(link)
                    if name then
                        EpochDBData.items[itemID] = {
                            id      = itemID,
                            name    = name,
                            quality = quality or 1,
                            ilvl    = ilvl or 0,
                            type    = iType or "",
                            subType = iSubType or "",
                            slot    = iSlot or "",
                            extras  = getItemExtras(link),
                        }
                    end
                end
            end
        end
    end
end

local function scheduleBagScan()
    if EpochDB._bagScanPending then return end
    EpochDB._bagScanPending = true
    local elapsed = 0
    local f = CreateFrame("Frame")
    f:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed >= 2 then
            scanBags()
            self:SetScript("OnUpdate", nil)
            self:Hide()
            f = nil
        end
    end)
    f:Show()
end

-- ── QUEST TRACKING ───────────────────────────────────────────

local function getOrCreateQuest(title)
    if not title or title == "" then return nil end
    local zone = getZone()
    if not zone then return nil end

    if not EpochDBData.quests[title] then
        EpochDBData.quests[title] = {
            name        = title,
            zone        = zone,
            coords      = getCoords(),
            completions = 0,
            rewards     = {},
        }
    end
    return EpochDBData.quests[title]
end

local function handleQuestDetail()
    if not EpochDBData or not EpochDBData.quests then return end

    local title = GetTitleText()
    local q = getOrCreateQuest(title)
    if not q then return end

    q.coords = getCoords()

    -- Quest body & objective text (only available during QUEST_DETAIL)
    local body = GetQuestText and GetQuestText() or nil
    if body and body ~= "" then q.questText = body end

    local obj = GetObjectiveText and GetObjectiveText() or nil
    if obj and obj ~= "" then q.objectiveText = obj end

    local group = GetSuggestedGroupNum and GetSuggestedGroupNum() or 0
    if group and group > 0 then q.suggestedGroup = group end

    -- Required items to complete the quest
    local numRequired = GetNumQuestItems and GetNumQuestItems() or 0
    if numRequired > 0 then
        q.requiredItems = q.requiredItems or {}
        for i = 1, numRequired do
            local name, _, count = GetQuestItemInfo("required", i)
            local link = GetQuestItemLink and GetQuestItemLink("required", i) or nil
            local id = link and link:match("item:(%d+)") or nil
            if id then
                q.requiredItems[id] = { id = id, name = name, count = count }
            end
        end
    end

    log("quest detail: " .. tostring(title))
end

local function handleQuestProgress()
    if not EpochDBData or not EpochDBData.quests then return end

    local title = GetTitleText()
    local q = getOrCreateQuest(title)
    if not q then return end

    local progress = GetProgressText and GetProgressText() or nil
    if progress and progress ~= "" then q.progressText = progress end
end

local function handleQuestComplete()
    if not EpochDBData or not EpochDBData.quests then return end

    local title = GetTitleText()
    local q = getOrCreateQuest(title)
    if not q then return end

    q.completions = q.completions + 1
    q.coords = getCoords()

    -- Reward / completion text
    local rewardText = GetRewardText and GetRewardText() or nil
    if rewardText and rewardText ~= "" then q.rewardText = rewardText end

    -- Money reward
    local money = GetRewardMoney and GetRewardMoney() or 0
    if money > 0 then q.rewardMoney = money end

    -- Choice rewards (pick one)
    local numChoices = GetNumQuestChoices()
    for i = 1, numChoices do
        local rLink = GetQuestItemLink("choice", i)
        if rLink then
            local rID = rLink:match("item:(%d+)")
            if rID then
                q.rewards[rID] = (q.rewards[rID] or 0) + 1
            end
        end
    end

    -- Fixed rewards (always given)
    local numRewards = GetNumQuestRewards and GetNumQuestRewards() or 0
    if numRewards > 0 then
        q.rewardItems = q.rewardItems or {}
        for i = 1, numRewards do
            local name, _, count = GetQuestItemInfo("reward", i)
            local link = GetQuestItemLink and GetQuestItemLink("reward", i) or nil
            local id = link and link:match("item:(%d+)") or nil
            if id then
                q.rewardItems[id] = { id = id, name = name, count = count }
            end
        end
    end

    log("quest complete: " .. tostring(title))
end

-- ── VENDOR CAPTURE ────────────────────────────────────────────

local lastVendorSnapshot = nil

local function buildItemEntry(link, nameFromLoot, qtyFromLoot, qualityFromLoot)
    local name, _, quality, itemLevel, reqLevel, className, subClassName,
          maxStack, equipLoc, icon, sellPrice = GetItemInfo(link or "")
    local itemID = link and tonumber(tostring(link):match("item:(%d+)")) or nil
    return {
        id       = itemID,
        name     = name or nameFromLoot,
        qty      = qtyFromLoot or 1,
        quality  = quality or qualityFromLoot,
        info     = {
            itemLevel = itemLevel,
            reqLevel  = reqLevel,
            class     = className,
            subclass  = subClassName,
            equipLoc  = equipLoc,
            maxStack  = maxStack,
            sellPrice = sellPrice,
            extras    = getItemExtras(link),
        },
    }
end

local function captureVendor()
    if not EpochDBData or not EpochDBData.vendors then return end
    if not MerchantFrame or not MerchantFrame:IsShown() then return end
    if not GetMerchantNumItems then return end

    local count = GetMerchantNumItems()
    if not count or count <= 0 then return end

    -- Identify the vendor
    local vendorGUID = UnitGUID and UnitGUID("target") or nil
    local vendorName = UnitName and UnitName("target") or nil
    local vendorId   = vendorGUID and GetEntryIdFromGUID(vendorGUID) or nil

    -- Collect items
    local items, itemIds = {}, {}
    for index = 1, count do
        local link = GetMerchantItemLink and GetMerchantItemLink(index) or nil
        local name, _, price, quantity, numAvailable, _, extendedCost = GetMerchantItemInfo(index)
        local entry = buildItemEntry(link, name, quantity, nil)
        local iid = entry and entry.id or nil
        if iid then
            entry.priceCopper    = price
            entry.qtyPerPurchase = quantity
            entry.numAvailable   = numAvailable
            entry.extendedCost   = extendedCost
            items[#items + 1]    = entry
            itemIds[#itemIds + 1] = iid
        end
    end
    if #items == 0 then return end

    -- Simple dedup: same vendor + same item set = skip
    table.sort(itemIds)
    local sig = tostring(vendorId or vendorGUID or "") .. ":" .. table.concat(itemIds, ":")
    if lastVendorSnapshot and lastVendorSnapshot.sig == sig and (time() - (lastVendorSnapshot.ts or 0) < 2) then
        return
    end

    local x, y = GetPlayerMapPosition("player")
    local key = tostring(vendorId or vendorName or "unknown")

    EpochDBData.vendors[key] = {
        name     = vendorName,
        npcId    = vendorId,
        guid     = vendorGUID,
        zone     = getZone(),
        subZone  = getSubZone(),
        x        = x,
        y        = y,
        canRepair = CanMerchantRepair and CanMerchantRepair() or nil,
        items    = items,
        lastSeen = ts(),
    }

    lastVendorSnapshot = { sig = sig, ts = time() }
    log("vendor captured: " .. tostring(vendorName) .. " (" .. tostring(vendorId or vendorGUID or "?") .. ") items=" .. #items)
end

-- ── FRAME & EVENT HANDLING ───────────────────────────────────

EpochDB._lastError = nil
local function oops(where, err)
    EpochDB._lastError = (where or "?") .. ": " .. tostring(err)
    eprint("|cffff6666ERROR|r " .. EpochDB._lastError)
end

local frame = CreateFrame("Frame", "EpochDBFrame", UIParent)
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("QUEST_DETAIL")
frame:RegisterEvent("QUEST_PROGRESS")
frame:RegisterEvent("QUEST_COMPLETE")
frame:RegisterEvent("BAG_UPDATE_DELAYED")
frame:RegisterEvent("BANKFRAME_OPENED")
frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
frame:RegisterEvent("GUILDBANKFRAME_OPENED")
frame:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")
frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterEvent("MERCHANT_UPDATE")
frame:RegisterEvent("MERCHANT_CLOSED")

frame:SetScript("OnEvent", function(self, event, ...)
    local n = select("#", ...)
    local args = { ... }
    local ok, err = pcall(function()
        if event == "ADDON_LOADED" then
            if args[1] == ADDON_NAME then
                EpochDB:OnLoad()
            end
        elseif event == "PLAYER_ENTERING_WORLD" then
            EpochDB:OnEnterWorld()
        elseif event == "PLAYER_LOGOUT" then
            EpochDB:OnLogout()
        elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
            handleCombatLog(unpack(args, 1, n))
        elseif event == "LOOT_OPENED" then
            handleLootOpened()
        elseif event == "QUEST_DETAIL" then
            handleQuestDetail()
        elseif event == "QUEST_PROGRESS" then
            handleQuestProgress()
        elseif event == "QUEST_COMPLETE" then
            handleQuestComplete()
        elseif event == "BAG_UPDATE_DELAYED" then
            scheduleBagScan()
        elseif event == "BANKFRAME_OPENED" then
            scanBank()
        elseif event == "PLAYER_EQUIPMENT_CHANGED" then
            scanEquipped()
        elseif event == "GUILDBANKFRAME_OPENED" or event == "GUILDBANKBAGSLOTS_CHANGED" then
            scanGuildBank()
        elseif event == "UPDATE_MOUSEOVER_UNIT" then
            if UnitExists("mouseover") then snapshotUnit("mouseover") end
        elseif event == "PLAYER_TARGET_CHANGED" then
            if UnitExists("target") then snapshotUnit("target") end
        elseif event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
            captureVendor()
        elseif event == "MERCHANT_CLOSED" then
            lastVendorSnapshot = nil
        end
    end)
    if not ok and err then oops(event, err) end
end)

-- ── INIT ─────────────────────────────────────────────────────

function EpochDB:OnLoad()
    if not EpochDBData then
        EpochDBData = {}
    end
    EpochDBData.kills   = EpochDBData.kills   or {}
    EpochDBData.items   = EpochDBData.items   or {}
    EpochDBData.quests  = EpochDBData.quests  or {}
    EpochDBData.loot    = EpochDBData.loot    or {}
    EpochDBData.vendors = EpochDBData.vendors or {}
    EpochDBData.meta    = EpochDBData.meta    or {}

    self.session = makeSessionId()
    eprint("v" .. self.version .. " loaded. Use /edb help for commands.")
end

function EpochDB:OnEnterWorld()
    if not EpochDBData then return end
    resetKillDedup()
    local meta = EpochDBData.meta
    meta.player    = UnitName("player")
    meta.realm     = GetRealmName()
    meta.class     = select(2, UnitClass("player"))
    meta.race      = select(2, UnitRace("player"))
    meta.faction   = UnitFactionGroup("player")
    meta.level     = UnitLevel("player")
    meta.session   = self.session
    meta.sessions  = (meta.sessions or 0) + 1
    meta.lastSeen  = ts()
    meta.firstSeen = meta.firstSeen or ts()

    local v, build, _, iface = GetBuildInfo()
    meta.clientVersion = v
    meta.clientBuild   = tostring(build)
    meta.interface     = iface

    initScannerTip()
    scanBags()
    scanEquipped()
end

function EpochDB:OnLogout()
    if EpochDBData and EpochDBData.meta then
        EpochDBData.meta.lastSeen = ts()
    end
end

-- ── SLASH COMMANDS ───────────────────────────────────────────

SLASH_EPOCHDB1 = "/edb"
SLASH_EPOCHDB2 = "/epochdb"

SlashCmdList["EPOCHDB"] = function(msg)
    msg = strtrim(msg or ""):lower()
    if msg == "" or msg == "stats" then
        EpochDB:PrintStats()
    elseif msg == "reset" then
        EpochDB:Reset()
    elseif msg == "debug" or msg == "debug toggle" then
        EpochDB._debug = not EpochDB._debug
        eprint("Debug " .. (EpochDB._debug and "ON" or "OFF"))
    elseif msg == "debug on" then
        EpochDB._debug = true; eprint("Debug ON")
    elseif msg == "debug off" then
        EpochDB._debug = false; eprint("Debug OFF")
    elseif msg == "vendor" then
        captureVendor()
    elseif msg == "status" then
        local e = EpochDB._lastError or "none"
        eprint("v" .. EpochDB.version .. " | session=" .. tostring(EpochDB.session) .. " | lastError=" .. e)
    elseif msg == "help" then
        EpochDB:PrintHelp()
    else
        eprint("Unknown command. Type /edb help")
    end
end

function EpochDB:Count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

function EpochDB:PrintStats()
    if not EpochDBData then
        eprint("Data not initialized yet.")
        return
    end
    local totalKills = 0
    for _, v in pairs(EpochDBData.kills) do totalKills = totalKills + (v.count or 0) end

    eprint("----- EpochDB Stats -----")
    eprint(string.format("Kills Captured : %d", totalKills))
    eprint(string.format("Items Tracked  : %d", self:Count(EpochDBData.items)))
    eprint(string.format("Loot Records   : %d", self:Count(EpochDBData.loot)))
    eprint(string.format("Vendors Tracked: %d", self:Count(EpochDBData.vendors or {})))
    eprint(string.format("Quests Tracked : %d", self:Count(EpochDBData.quests or {})))
end

function EpochDB:Reset()
    if not EpochDBData then return end
    EpochDBData.kills   = {}
    EpochDBData.items   = {}
    EpochDBData.quests  = {}
    EpochDBData.loot    = {}
    EpochDBData.vendors = {}
    resetKillDedup()
    eprint("All data cleared.")
end

function EpochDB:PrintHelp()
    eprint("Commands:")
    eprint("  /edb stats    — Show collection stats")
    eprint("  /edb status   — Show addon status & errors")
    eprint("  /edb debug    — Toggle debug logging")
    eprint("  /edb vendor   — Manually capture open vendor")
    eprint("  /edb reset    — Clear all data")
end