local SORCERER_CLASS_UUID = "784001e2-c96d-4153-beb6-2adbef5abc92"
local MAX_CHAR_SLOTS = 8
local SLOTS_PER_LEVEL = 2

local syncChannel = Ext.Net.CreateChannel(ModuleUUID, "SorceryCasting_SyncCharPools")
local requestChannel = Ext.Net.CreateChannel(ModuleUUID, "SorceryCasting_RequestSync")

local SORCERY_POINT_COSTS = {
    1, -- Level 1
    2, -- Level 2
    3, -- Level 3
    4, -- Level 4
    5, -- Level 5
}

local SORCERER_BUNDLE_PASSIVES = {
    "KJ_SorceryCasting_Passive",
    "KJ_SorceryCasting_Points",
    "KJ_SorceryCasting_Level_1",
    "KJ_SorceryCasting_Level_2",
    "KJ_SorceryCasting_Level_3",
    "KJ_SorceryCasting_Level_4",
    "KJ_SorceryCasting_Level_5",
    "KJ_SorceryCasting_Level_6",
    "KJ_SorceryCasting_Level_7",
    "KJ_SorceryCasting_Level_8",
    "KJ_SorceryCasting_Level_9",
    "KJ_SorceryCasting_Level_10",
}

local function GetCharPassiveName(charIndex, level, slotIndex)
    return string.format("KJ_SorceryCasting_Char%d_Level%d_%d", charIndex, level, slotIndex)
end

if Ext.IsClient() then
    syncChannel:SetHandler(function(data)
        local updates = Ext.Json.Parse(data)
        for passiveName, boosts in pairs(updates) do
            local pStat = Ext.Stats.Get(passiveName)
            if pStat ~= nil then
                pStat.Boosts = boosts
                pStat:Sync()
            end
        end
    end)

    Ext.Events.GameStateChanged:Subscribe(function(e)
        if e.ToState == "Running" then
            Ext.Timer.WaitFor(500, function()
                requestChannel:SendToServer("")
            end)
        end
    end)
end

if Ext.IsServer() then
    local CachedChildrenMap = nil
    local CharacterSlotMap = {}
    local CharacterActivePassives = {}
	local CachedSorcSources = nil

    local function GetSorcererProgressionSources()
        if CachedSorcSources ~= nil then
            return CachedSorcSources
        end

        CachedSorcSources = {
            [SORCERER_CLASS_UUID] = true,
        }
        local sorcTables = {}

        local allClasses = Ext.StaticData.GetAll("ClassDescription") or {}
        for _, rawClassUuid in ipairs(allClasses) do
            local classUuid = tostring(rawClassUuid)
            local classDesc = Ext.StaticData.Get(rawClassUuid, "ClassDescription")
            if classDesc ~= nil then
                local parentGuid = classDesc.ParentGuid ~= nil and tostring(classDesc.ParentGuid) or ""
                if classUuid == SORCERER_CLASS_UUID or parentGuid == SORCERER_CLASS_UUID then
                    CachedSorcSources[classUuid] = true
                    if classDesc.ProgressionTableUUID ~= nil then
                        local tableUuid = tostring(classDesc.ProgressionTableUUID)
                        sorcTables[tableUuid] = true
                        CachedSorcSources[tableUuid] = true
                    end
                end
            end
        end

        local allProgressions = Ext.StaticData.GetAll("Progression") or {}
        for _, rawProgUuid in ipairs(allProgressions) do
            local progUuid = tostring(rawProgUuid)
            local prog = Ext.StaticData.Get(rawProgUuid, "Progression")
            if prog ~= nil and prog.TableUUID ~= nil then
                local tableUuid = tostring(prog.TableUUID)
                if sorcTables[tableUuid] or CachedSorcSources[tableUuid] then
                    CachedSorcSources[progUuid] = true
                end
            end
        end

        return CachedSorcSources
    end

    local function NormalizeUuid(guid)
        if guid ~= nil and math.floor(#guid / 36) ~= 0 then
            return string.sub(guid, -36)
        end
        return guid
    end

    local function IsNpcOrIgnoredSpell(spellName)
        if string.find(spellName, "CreateSorceryPoints") or string.find(spellName, "CreateSpellSlot") then
            return true
        end
        if string.find(spellName, "^AI_") or string.find(spellName, "^Quest_") or string.find(spellName, "^DEBUG_") then
            return true
        end
        if string.find(spellName, "_LOW_") or string.find(spellName, "_END_") or string.find(spellName, "_TUT_")
            or string.find(spellName, "_UND_") or string.find(spellName, "_SCL_") or string.find(spellName, "_HAG_")
            or string.find(spellName, "_GOB_") or string.find(spellName, "_CRE_") or string.find(spellName, "_SHA_") then
            return true
        end
        return false
    end

    local function HasIsSpellFlag(stat)
        if stat == nil or stat.SpellFlags == nil then
            return false
        end
        for _, flag in ipairs(stat.SpellFlags) do
            if flag == "IsSpell" then
                return true
            end
        end
        return false
    end

    local function GetSpellChildrenMap()
        if CachedChildrenMap ~= nil then
            return CachedChildrenMap
        end

        CachedChildrenMap = {}
        local allSpells = Ext.Stats.GetStats("SpellData") or {}

        for _, spellName in ipairs(allSpells) do
            if not IsNpcOrIgnoredSpell(spellName) then
                local stat = Ext.Stats.Get(spellName)
                if stat ~= nil and stat.Using ~= nil and stat.Using ~= "" then
                    CachedChildrenMap[stat.Using] = CachedChildrenMap[stat.Using] or {}
                    table.insert(CachedChildrenMap[stat.Using], spellName)
                end
            end
        end

        return CachedChildrenMap
    end

    local function CollectSpellFamily(rootSpell, childrenMap, collected)
        if collected[rootSpell] or IsNpcOrIgnoredSpell(rootSpell) then
            return
        end
        collected[rootSpell] = true

        local children = childrenMap[rootSpell]
        if children ~= nil then
            for _, childName in ipairs(children) do
                CollectSpellFamily(childName, childrenMap, collected)
            end
        end
    end

    local function HasSorcererLevels(entity)
        if entity == nil or entity.Classes == nil or entity.Classes.Classes == nil then
            return false
        end
        for _, classInfo in ipairs(entity.Classes.Classes) do
            if tostring(classInfo.ClassUUID) == SORCERER_CLASS_UUID and (classInfo.Level or 0) ~= 0 then
                return true
            end
        end
        return false
    end

    local function GrantSorcererBundle(uuid)
        for _, passiveName in ipairs(SORCERER_BUNDLE_PASSIVES) do
            if Osi.HasPassive(uuid, passiveName) == 0 then
                Osi.AddPassive(uuid, passiveName)
            end
        end
    end

    local function RemoveSorcererBundle(uuid)
        for _, passiveName in ipairs(SORCERER_BUNDLE_PASSIVES) do
            if Osi.HasPassive(uuid, passiveName) == 1 then
                Osi.RemovePassive(uuid, passiveName)
            end
        end
    end

    local function RemoveAllCharPassives(uuid)
        for charIdx = 1, MAX_CHAR_SLOTS do
            for level = 1, 5 do
                for slot = 1, SLOTS_PER_LEVEL do
                    local pName = GetCharPassiveName(charIdx, level, slot)
                    if Osi.HasPassive(uuid, pName) == 1 then
                        Osi.RemovePassive(uuid, pName)
                    end
                end
            end
        end
    end

    local function ApplyCharacterPassives(uuid)
        local cleanUuid = NormalizeUuid(uuid)
        local passives = CharacterActivePassives[cleanUuid] or {}
        for _, pName in ipairs(passives) do
            if Osi.HasPassive(cleanUuid, pName) == 0 then
                Osi.AddPassive(cleanUuid, pName)
            end
        end
    end

    local function GetOrAssignCharSlot(uuid)
        if CharacterSlotMap[uuid] ~= nil then
            return CharacterSlotMap[uuid]
        end

        local usedSlots = {}
        for _, slotIdx in pairs(CharacterSlotMap) do
            usedSlots[slotIdx] = true
        end

        for slotIdx = 1, MAX_CHAR_SLOTS do
            if not usedSlots[slotIdx] then
                CharacterSlotMap[uuid] = slotIdx
                return slotIdx
            end
        end

        return nil
    end

    local function ClearCharSlotPassives(charIdx, payload)
        for level = 1, 5 do
            for slot = 1, SLOTS_PER_LEVEL do
                local pName = GetCharPassiveName(charIdx, level, slot)
                local pStat = Ext.Stats.Get(pName)
                if pStat ~= nil then
                    pStat.Boosts = ""
                    payload[pName] = ""
                end
            end
        end
    end

    local function CompileCharacterPool(entity, uuid, childrenMap, sorcSources, payload)
        RemoveAllCharPassives(uuid)

        if not HasSorcererLevels(entity) then
            RemoveSorcererBundle(uuid)
            local oldSlot = CharacterSlotMap[uuid]
            if oldSlot ~= nil then
                ClearCharSlotPassives(oldSlot, payload)
                CharacterSlotMap[uuid] = nil
            end
            CharacterActivePassives[uuid] = nil
            return
        end

        local charIdx = GetOrAssignCharSlot(uuid)
        if charIdx == nil then
            return
        end

        ClearCharSlotPassives(charIdx, payload)
        CharacterActivePassives[uuid] = {}
        GrantSorcererBundle(uuid)

        local learnedSpells = {}
        if entity.SpellBook ~= nil and entity.SpellBook.Spells ~= nil then
            for _, spellEntry in ipairs(entity.SpellBook.Spells) do
                local id = spellEntry.Id
                if id ~= nil and id.Prototype ~= nil and sorcSources[tostring(id.ProgressionSource)] then
                    CollectSpellFamily(id.Prototype, childrenMap, learnedSpells)
                end
            end
        end

        local spellsByLevel = { {}, {}, {}, {}, {} }
        for spellName, _ in pairs(learnedSpells) do
            if not IsNpcOrIgnoredSpell(spellName) then
                local stat = Ext.Stats.Get(spellName)
                if stat ~= nil and HasIsSpellFlag(stat) then
                    local useCosts = stat.UseCosts or ""
                    local slotLevelStr = string.match(useCosts, "SpellSlotsGroup:%d+:%d+:(%d+)")
                    local slotLevel = tonumber(slotLevelStr) or stat.Level

                    if slotLevel ~= nil and SORCERY_POINT_COSTS[slotLevel] ~= nil and string.find(useCosts, "SpellSlotsGroup") then
                        table.insert(spellsByLevel[slotLevel], string.format("SpellId('%s')", spellName))
                    end
                end
            end
        end

        for level = 1, 5 do
            local spCost = SORCERY_POINT_COSTS[level]
            local predicates = spellsByLevel[level]
            local slotIndex = 1
            local currentExpr = ""

            local function FlushChunk(expr)
                if expr == "" or slotIndex == SLOTS_PER_LEVEL + 1 then
                    return
                end
                local pName = GetCharPassiveName(charIdx, level, slotIndex)
                local pStat = Ext.Stats.Get(pName)
                if pStat ~= nil then
                    local boostStr = string.format(
                        "UnlockSpellVariant((%s) & KJCanSorceryCast(),ModifyUseCosts(Add,SorceryPoint,%d,0),ModifyUseCosts(Replace,SpellSlotsGroup,0,-1,SpellSlotsGroup))",
                        expr,
                        spCost
                    )
                    pStat.Boosts = boostStr
                    pStat:Sync()
                    payload[pName] = boostStr
                    table.insert(CharacterActivePassives[uuid], pName)
                end
                slotIndex = slotIndex + 1
            end

            for _, pred in ipairs(predicates) do
                local candidate = currentExpr == "" and pred or (currentExpr .. "|" .. pred)
                if math.floor(#candidate / 1600) ~= 0 then
                    FlushChunk(currentExpr)
                    currentExpr = pred
                else
                    currentExpr = candidate
                end
            end

            FlushChunk(currentExpr)
        end

        if Osi.HasActiveStatus(uuid, "KJ_SORCERYCASTING_ACTIVE") == 1 then
            ApplyCharacterPassives(uuid)
        end
    end

    local function RebuildSingleSorcerer(characterGuid)
        local uuid = NormalizeUuid(characterGuid)
        if uuid == nil then
            return
        end

        local entity = Ext.Entity.Get(uuid)
        if entity == nil then
            return
        end

        local childrenMap = GetSpellChildrenMap()
        local sorcSources = GetSorcererProgressionSources()
        local payload = {}

        CompileCharacterPool(entity, uuid, childrenMap, sorcSources, payload)

        if next(payload) ~= nil then
            syncChannel:Broadcast(Ext.Json.Stringify(payload))
        end

        if Osi.HasActiveStatus(uuid, "KJ_SORCERYCASTING_ACTIVE") == 1 then
            RemoveAllCharPassives(uuid)
            Ext.Timer.WaitFor(100, function()
                ApplyCharacterPassives(uuid)
            end)
        end

        _P("[SorceryCasting] Updated Sorcerer spell pool for character: " .. tostring(uuid))
    end

    local function RebuildAllPartySorcerers()
        local childrenMap = GetSpellChildrenMap()
        local sorcSources = GetSorcererProgressionSources()
        local payload = {}

        CharacterSlotMap = {}
        CharacterActivePassives = {}

        for charIdx = 1, MAX_CHAR_SLOTS do
            ClearCharSlotPassives(charIdx, payload)
        end

        local seenUuids = {}
        local allCandidateRows = {}

        for _, row in ipairs(Osi.DB_PartOfTheTeam:Get(nil) or {}) do
            table.insert(allCandidateRows, row)
        end
        for _, row in ipairs(Osi.DB_InCamp:Get(nil) or {}) do
            table.insert(allCandidateRows, row)
        end

        local count = 0
        for _, row in ipairs(allCandidateRows) do
            local rawGuid = table.unpack(row)
            local uuid = NormalizeUuid(rawGuid)
            if uuid ~= nil and not seenUuids[uuid] then
                seenUuids[uuid] = true
                local entity = Ext.Entity.Get(uuid)
                if entity ~= nil then
                    CompileCharacterPool(entity, uuid, childrenMap, sorcSources, payload)
                    if CharacterSlotMap[uuid] ~= nil then
                        count = count + 1
                    end
                end
            end
        end

        syncChannel:Broadcast(Ext.Json.Stringify(payload))
        _P("[SorceryCasting] Initialized Sorcerer spell pools for " .. tostring(count) .. " recruited character(s).")
    end

    requestChannel:SetHandler(function()
        RebuildAllPartySorcerers()
    end)

    Ext.Events.GameStateChanged:Subscribe(function(e)
        if e.ToState == "Running" then
            RebuildAllPartySorcerers()
        end
    end)

    Ext.Events.SessionLoaded:Subscribe(function()
        local function DelayedSingleRebuild(character)
            local uuid = NormalizeUuid(character)
            if uuid == nil then
                return
            end
            Ext.Timer.WaitFor(500, function()
                RebuildSingleSorcerer(uuid)
            end)
        end

        Ext.Osiris.RegisterListener("StatusApplied", 4, "after", function(object, status, causee, storyActionID)
            if status == "KJ_SORCERYCASTING_ACTIVE" then
                ApplyCharacterPassives(object)
            end
        end)

        Ext.Osiris.RegisterListener("StatusRemoved", 4, "after", function(object, status, causee, applyStoryActionID)
            if status == "KJ_SORCERYCASTING_ACTIVE" then
                local uuid = NormalizeUuid(object)
                if uuid ~= nil then
                    RemoveAllCharPassives(uuid)
                end
            end
        end)

        Ext.Osiris.RegisterListener("LeveledUp", 1, "after", function(character)
            DelayedSingleRebuild(character)
        end)

        Ext.Osiris.RegisterListener("CharacterJoinedParty", 1, "after", function(character)
            DelayedSingleRebuild(character)
        end)

        Ext.Osiris.RegisterListener("UserConnected", 3, "after", function()
            Ext.Timer.WaitFor(500, function()
                RebuildAllPartySorcerers()
            end)
        end)
    end)
end
