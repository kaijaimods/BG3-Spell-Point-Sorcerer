local SORCERER_CLASS_UUID = "784001e2-c96d-4153-beb6-2adbef5abc92"
local MAX_CHAR_SLOTS = 8
local SLOTS_PER_LEVEL = 2
local REACTION_SLOTS_PER_CHAR = 2

local syncChannel = Ext.Net.CreateChannel(ModuleUUID, "SorceryCasting_SyncCharPools")
local requestChannel = Ext.Net.CreateChannel(ModuleUUID, "SorceryCasting_RequestSync")

local SORCERY_POINT_COSTS = {
    2, -- Level 1
    3, -- Level 2
    5, -- Level 3
    6, -- Level 4
    7, -- Level 5
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

local CachedChildrenMap = nil
local CachedSorcSources = nil
local SpellToDynamicInterrupts = {}

local function GetCharPassiveName(charIndex, level, slotIndex)
    return string.format("KJ_SorceryCasting_Char%d_Level%d_%d", charIndex, level, slotIndex)
end

local function GetCharReactionPassiveName(charIndex, slotIndex)
    return string.format("KJ_SorceryCasting_Char%d_Reactions_%d", charIndex, slotIndex)
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

local function SafeGetUseCosts(stat)
    if stat == nil or stat.ModifierList ~= "SpellData" then
        return nil
    end
    local ok, costs = pcall(function()
        return stat.UseCosts
    end)
    return ok and costs or nil
end

local function GetSpellSlotLevel(spellName)
    local sStat = Ext.Stats.Get(spellName)
    local costStr = SafeGetUseCosts(sStat)
    if costStr == nil then
        return nil
    end
    local slotStr = string.match(costStr, "[%w_]*SpellSlots?G?r?o?u?p?:%d+:%d+:(%d+)")
    return tonumber(slotStr) or sStat.Level
end

local function BuildInterruptToSpellsMap()
    local map = {}
    local lowestSpellByInt = {}
    local allSpells = Ext.Stats.GetStats("SpellData") or {}

    for _, spellName in ipairs(allSpells) do
        if not IsNpcOrIgnoredSpell(spellName) then
            local sStat = Ext.Stats.Get(spellName)
            if sStat ~= nil and sStat.ModifierList == "SpellData" then
                local intProto = sStat.InterruptPrototype
                if intProto ~= nil and intProto ~= "" then
                    local lvl = GetSpellSlotLevel(spellName) or 99
                    local existing = lowestSpellByInt[intProto]
                    if existing == nil or math.floor(lvl / existing.level) == 0 then
                        lowestSpellByInt[intProto] = { spell = spellName, level = lvl }
                    end
                end
            end
        end
    end

    for intProto, info in pairs(lowestSpellByInt) do
        map[intProto] = map[intProto] or {}
        table.insert(map[intProto], info.spell)
    end

    local allInterrupts = Ext.Stats.GetStats("InterruptData") or {}
    for _, intName in ipairs(allInterrupts) do
        if not string.find(intName, "^KJ_SP_Interrupt_")
            and not string.find(intName, "^Interrupt_UAWC_PM_")
            and not IsNpcOrIgnoredSpell(intName) then
            local iStat = Ext.Stats.Get(intName)
            if iStat ~= nil then
                for _, functorList in ipairs({ iStat.Properties, iStat.Success }) do
                    if functorList ~= nil then
                        for _, group in ipairs(functorList) do
                            if group.Functors ~= nil then
                                for _, functor in ipairs(group.Functors) do
                                    if functor.TypeId == "UseSpell" and functor.SpellId ~= nil and functor.SpellId ~= "" then
                                        map[intName] = map[intName] or {}
                                        table.insert(map[intName], functor.SpellId)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return map
end

local EXTRA_TARGETS_UPCAST_GUID = "04cc3403-f67f-470b-b49e-a1802cc7a6ad"

local function SerializeFunctorGroups(groups)
    if groups == nil then
        return ""
    end
    local ok, dumped = pcall(function()
        return Ext.Json.Stringify(Ext.DumpExport(groups))
    end)
    return ok and dumped or ""
end

local function SerializeSpellSingleTargetEffects(stat)
    if stat == nil or stat.ModifierList ~= "SpellData" then
        return ""
    end
    local ok, dumped = pcall(function()
        return Ext.Json.Stringify({
            succ = Ext.DumpExport(stat.SpellSuccess),
            fail = Ext.DumpExport(stat.SpellFail),
            proj = stat.ProjectileCount,
            dmg = stat.TooltipDamageList,
        })
    end)
    return ok and dumped or ""
end

local function IsNonScalingUpcastSpell(spellName)
    if spellName == nil or spellName == "" then
        return false
    end
    local stat = Ext.Stats.Get(spellName)
    if stat == nil or stat.ModifierList ~= "SpellData" then
        return false
    end

    local rootName = stat.RootSpellID or ""
    if rootName == "" or rootName == spellName then
        if string.match(spellName, "_%d+$") and (stat.Using or "") ~= "" then
            rootName = stat.Using
        else
            return false
        end
    end

    local rootStat = Ext.Stats.Get(rootName)
    if rootStat == nil or rootStat.ModifierList ~= "SpellData" then
        return false
    end

    local upcastDesc = stat.TooltipUpcastDescription or rootStat.TooltipUpcastDescription or ""
    if upcastDesc == EXTRA_TARGETS_UPCAST_GUID then
        return true
    end

    local childEffects = SerializeSpellSingleTargetEffects(stat)
    local rootEffects = SerializeSpellSingleTargetEffects(rootStat)
    if childEffects ~= "" and childEffects == rootEffects then
        return true
    end

    return false
end

local function IsRedundantUpcastInterrupt(interruptName, intStat)
    if string.find(interruptName, "^KJ_WC_") then
        local rawSpell = string.gsub(interruptName, "^KJ_WC_Char%d+_Interrupt_", "")
        rawSpell = string.gsub(rawSpell, "^KJ_WC_PM_Interrupt_", "")
        rawSpell = string.gsub(rawSpell, "^KJ_WC_Interrupt_", "")
        return IsNonScalingUpcastSpell(rawSpell)
    end

    if not string.match(interruptName, "_%d+$") then
        return false
    end

    local parentName = intStat.Using
    if parentName == nil or parentName == "" then
        parentName = string.gsub(interruptName, "_%d+$", "")
    end

    local parentStat = Ext.Stats.Get(parentName)
    if parentStat == nil then
        return false
    end

    local childProps = SerializeFunctorGroups(intStat.Properties)
    local parentProps = SerializeFunctorGroups(parentStat.Properties)
    local childSucc = SerializeFunctorGroups(intStat.Success)
    local parentSucc = SerializeFunctorGroups(parentStat.Success)

    if childProps == "" and childSucc == "" then
        return false
    end

    return childProps == parentProps and childSucc == parentSucc
end

local function RegisterDynamicInterruptForSpell(spellName, newIntName, slotLevel, isPolearmMaster, origInterrupt)
    if spellName == nil or spellName == "" then
        return
    end
    SpellToDynamicInterrupts[spellName] = SpellToDynamicInterrupts[spellName] or {}
    for _, existing in ipairs(SpellToDynamicInterrupts[spellName]) do
        if existing.interrupt == newIntName then
            return
        end
    end
    table.insert(SpellToDynamicInterrupts[spellName], {
        interrupt = newIntName,
        level = slotLevel,
        isPolearmMaster = isPolearmMaster or false,
        origInterrupt = origInterrupt,
    })
end

local function CreateSingleDynamicSorcererReaction(interruptName)
    if string.find(interruptName, "^KJ_SP_") then
        return nil
    end

    local intStat = Ext.Stats.Get(interruptName)
    if intStat == nil or intStat.ModifierList ~= "InterruptData" then
        return nil
    end

    local costStr = intStat.Cost or ""
    if not string.find(costStr, "ReactionActionPoint") then
        return nil
    end

    local slotPattern = "[%w_]*SpellSlots?G?r?o?u?p?:%d+:%d+:(%d+)"
    local replacePattern = "[%w_]*SpellSlots?G?r?o?u?p?:%d+:%d+:%d+"
    local slotStr = string.match(costStr, slotPattern)
    local slotLevel = tonumber(slotStr)
    if slotLevel == nil or slotLevel == 0 then
        return nil
    end

    if IsRedundantUpcastInterrupt(interruptName, intStat) then
        return nil
    end

    local spCost = SORCERY_POINT_COSTS[slotLevel]
    if spCost == nil then
        return nil
    end

    local newIntName = string.format("KJ_SP_Interrupt_%s_L%d", interruptName, slotLevel)
    local newInt = Ext.Stats.Get(newIntName) or Ext.Stats.Create(newIntName, "InterruptData", interruptName)
    if newInt == nil then
        return nil
    end

    newInt.DisplayName = intStat.DisplayName
    newInt.Description = intStat.Description
    newInt.Icon = intStat.Icon
    newInt.Cost = string.gsub(costStr, replacePattern, "SorceryPoint:" .. tostring(spCost))

    local origCond = intStat.Conditions or ""
    if origCond ~= "" then
        newInt.Conditions = string.format("(%s) and HasActionResource('SorceryPoint', %d, 0, false, false, context.Source)", origCond, spCost)
    else
        newInt.Conditions = string.format("HasActionResource('SorceryPoint', %d, 0, false, false, context.Source)", spCost)
    end

    newInt:Sync()

    local isPM = string.find(interruptName, "^Interrupt_UAWC_PM_") ~= nil or string.find(interruptName, "^KJ_WC_PM_") ~= nil

    if string.find(interruptName, "^KJ_WC_") then
        local baseFromKJ = string.gsub(interruptName, "^KJ_WC_Char%d+_Interrupt_", "")
        baseFromKJ = string.gsub(baseFromKJ, "^KJ_WC_PM_Interrupt_", "")
        baseFromKJ = string.gsub(baseFromKJ, "^KJ_WC_Interrupt_", "")
        RegisterDynamicInterruptForSpell(baseFromKJ, newIntName, slotLevel, isPM, interruptName)
    end

    return newIntName
end

local function GenerateDynamicSorcererReactions()
    SpellToDynamicInterrupts = {}
    local intToSpells = BuildInterruptToSpellsMap()
    local createdCount = 0

    local slotPattern = "[%w_]*SpellSlots?G?r?o?u?p?:%d+:%d+:(%d+)"
    local replacePattern = "[%w_]*SpellSlots?G?r?o?u?p?:%d+:%d+:%d+"

    for interruptName, spellList in pairs(intToSpells) do
        if not string.find(interruptName, "^KJ_SP_Interrupt_")
            and not string.find(interruptName, "^Interrupt_UAWC_PM_")
            and not IsNpcOrIgnoredSpell(interruptName) then
            local intStat = Ext.Stats.Get(interruptName)
            if intStat ~= nil and not IsRedundantUpcastInterrupt(interruptName, intStat) then
                local intCostStr = intStat.Cost or ""
                local intSlotStr = string.match(intCostStr, slotPattern)

                for _, linkedSpell in ipairs(spellList) do
                    local spellStat = Ext.Stats.Get(linkedSpell)
                    local spellCostStr = SafeGetUseCosts(spellStat)
                    if spellCostStr ~= nil and not IsNpcOrIgnoredSpell(linkedSpell) then
                        local spellSlotStr = string.match(spellCostStr, slotPattern)
                        local slotLevel = tonumber(intSlotStr) or tonumber(spellSlotStr)
                        local spCost = slotLevel ~= nil and SORCERY_POINT_COSTS[slotLevel] or nil

                        local usesSlot = (intSlotStr ~= nil) or (spellSlotStr ~= nil)

                        if spCost ~= nil and usesSlot then
                            local newIntName = string.format("KJ_SP_Interrupt_%s_L%d", interruptName, slotLevel)
                            local newInt = Ext.Stats.Get(newIntName) or Ext.Stats.Create(newIntName, "InterruptData", interruptName)

                            if newInt ~= nil then
                                if intSlotStr ~= nil then
                                    newInt.Cost = string.gsub(intCostStr, replacePattern, "SorceryPoint:" .. tostring(spCost))
                                else
                                    local baseCost = intCostStr ~= "" and intCostStr or "ReactionActionPoint:1"
                                    newInt.Cost = string.format("%s;SorceryPoint:%d", baseCost, spCost)
                                end

                                for _, functorList in ipairs({ newInt.Properties, newInt.Success }) do
                                    if functorList ~= nil then
                                        for _, group in ipairs(functorList) do
                                            if group.Functors ~= nil then
                                                for _, functor in ipairs(group.Functors) do
                                                    if functor.TypeId == "UseSpell" and functor.SpellId == linkedSpell then
                                                        local newSpellName = "KJ_SP_Spell_" .. linkedSpell
                                                        local newSpell = Ext.Stats.Get(newSpellName) or Ext.Stats.Create(newSpellName, "SpellData", linkedSpell)
                                                        if newSpell ~= nil then
                                                            newSpell.UseCosts = string.gsub(spellCostStr, replacePattern, "SorceryPoint:" .. tostring(spCost))
                                                            newSpell:Sync()
                                                            functor.SpellId = newSpellName
                                                        end
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end

                                newInt:Sync()
                                local isPM = string.find(interruptName, "^Interrupt_UAWC_PM_") ~= nil
                                    or string.find(linkedSpell, "^UAWC_PM_") ~= nil
                                    or string.find(interruptName, "^KJ_WC_PM_") ~= nil

                                RegisterDynamicInterruptForSpell(linkedSpell, newIntName, slotLevel, isPM, interruptName)

                                local rootId = spellStat.RootSpellID
                                if rootId ~= nil and rootId ~= "" then
                                    RegisterDynamicInterruptForSpell(rootId, newIntName, slotLevel, isPM, interruptName)
                                end

                                if string.find(linkedSpell, "UAWC_") then
                                    local baseFromSpell = string.gsub(linkedSpell, "^UAWC_PM_", "")
                                    baseFromSpell = string.gsub(baseFromSpell, "^UAWC_", "")
                                    RegisterDynamicInterruptForSpell(baseFromSpell, newIntName, slotLevel, isPM, interruptName)
                                end

                                if string.find(interruptName, "^Interrupt_UAWC_") then
                                    local baseFromInt = string.gsub(interruptName, "^Interrupt_UAWC_PM_", "")
                                    baseFromInt = string.gsub(baseFromInt, "^Interrupt_UAWC_", "")
                                    RegisterDynamicInterruptForSpell(baseFromInt, newIntName, slotLevel, isPM, interruptName)
                                end

                                if string.find(interruptName, "^KJ_WC_") then
                                    local baseFromKJ = string.gsub(interruptName, "^KJ_WC_Char%d+_Interrupt_", "")
                                    baseFromKJ = string.gsub(baseFromKJ, "^KJ_WC_PM_Interrupt_", "")
                                    baseFromKJ = string.gsub(baseFromKJ, "^KJ_WC_Interrupt_", "")
                                    RegisterDynamicInterruptForSpell(baseFromKJ, newIntName, slotLevel, isPM, interruptName)
                                end

                                createdCount = createdCount + 1
                            end
                        end
                    end
                end
            end
        end
    end

    _P("[SorceryCasting] Prepared " .. tostring(createdCount) .. " Sorcery Point reaction template(s).")
end

local function EnsureDynamicReactionsPrepared()
    if next(SpellToDynamicInterrupts) == nil then
        GenerateDynamicSorcererReactions()
    end
end

Ext.Events.StatsLoaded:Subscribe(function()
    GenerateDynamicSorcererReactions()
end)

if Ext.IsClient() then
    syncChannel:SetHandler(function(data)
        local packet = Ext.Json.Parse(data)
        local passiveUpdates = packet.passives or packet
        for _, origIntName in ipairs(packet.dynamicInterrupts or {}) do
            CreateSingleDynamicSorcererReaction(origIntName)
        end
        for passiveName, boosts in pairs(passiveUpdates) do
            local pStat = Ext.Stats.Get(passiveName)
            if pStat ~= nil then
                pStat.Boosts = boosts
                pStat:Sync()
            end
        end
    end)

    Ext.Events.GameStateChanged:Subscribe(function(e)
        if e.ToState == "Running" then
            GenerateDynamicSorcererReactions()
            Ext.Timer.WaitFor(500, function()
                requestChannel:SendToServer("")
            end)
        end
    end)
end

if Ext.IsServer() then
    local CharacterSlotMap = {}
    local CharacterActivePassives = {}
    local CharacterReactionPassives = {}
    local PendingRebuilds = {}

    local function NormalizeUuid(guid)
        if guid ~= nil and math.floor(#guid / 36) ~= 0 then
            return string.sub(guid, -36)
        end
        return guid
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

    local function GetMaxSorcererSpellLevel(entity, uuid)
        local charLevel = uuid ~= nil and Osi.GetLevel(uuid) or 0
        if charLevel == 0 then
            return 1
        end
        local maxSpellLvl = math.ceil(charLevel / 2)
        if math.floor(maxSpellLvl / 6) ~= 0 then
            return 5
        end
        return maxSpellLvl
    end

    local function ApplyCharacterReactionPassives(uuid)
        local cleanUuid = NormalizeUuid(uuid)
        local passives = CharacterReactionPassives[cleanUuid] or {}
        for _, pName in ipairs(passives) do
            if Osi.HasPassive(cleanUuid, pName) == 0 then
                Osi.AddPassive(cleanUuid, pName)
            end
        end
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

    local function RemoveAllCharReactionPassives(uuid)
        for charIdx = 1, MAX_CHAR_SLOTS do
            for rSlot = 1, REACTION_SLOTS_PER_CHAR do
                local pName = GetCharReactionPassiveName(charIdx, rSlot)
                if Osi.HasPassive(uuid, pName) == 1 then
                    Osi.RemovePassive(uuid, pName)
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
        for rSlot = 1, REACTION_SLOTS_PER_CHAR do
            local rName = GetCharReactionPassiveName(charIdx, rSlot)
            local rStat = Ext.Stats.Get(rName)
            if rStat ~= nil then
                rStat.Boosts = ""
                payload[rName] = ""
            end
        end
    end

    local function CompileCharacterPool(entity, uuid, childrenMap, sorcSources, payload, dynamicInterrupts)
        RemoveAllCharPassives(uuid)
        RemoveAllCharReactionPassives(uuid)

        if not HasSorcererLevels(entity) then
            RemoveSorcererBundle(uuid)
            local oldSlot = CharacterSlotMap[uuid]
            if oldSlot ~= nil then
                ClearCharSlotPassives(oldSlot, payload)
                CharacterSlotMap[uuid] = nil
            end
            CharacterActivePassives[uuid] = nil
            CharacterReactionPassives[uuid] = nil
            return
        end

        local charIdx = GetOrAssignCharSlot(uuid)
        if charIdx == nil then
            return
        end

        ClearCharSlotPassives(charIdx, payload)
        CharacterActivePassives[uuid] = {}
        CharacterReactionPassives[uuid] = {}
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

        -- Expand linked spell containers (e.g. Chromatic Orb -> elemental variants)
        local containerChildren = {}
        for spellName, _ in pairs(learnedSpells) do
            local sStat = Ext.Stats.Get(spellName)
            if sStat ~= nil and sStat.ModifierList == "SpellData" then
                local cSpells = sStat.ContainerSpells or ""
                if cSpells ~= "" then
                    for subSpell in string.gmatch(cSpells, "[^;]+") do
                        CollectSpellFamily(subSpell, childrenMap, containerChildren)
                    end
                end
            end
        end
        for subSpell, _ in pairs(containerChildren) do
            learnedSpells[subSpell] = true
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

        local unlockedInterrupts = {}
        if entity.InterruptContainer ~= nil and entity.InterruptContainer.Interrupts ~= nil then
            for _, intEnt in ipairs(entity.InterruptContainer.Interrupts) do
                if intEnt ~= nil and intEnt.InterruptData ~= nil and intEnt.InterruptData.Interrupt ~= nil then
                    local intId = intEnt.InterruptData.Interrupt
                    unlockedInterrupts[intId] = true
                    if string.find(intId, "^KJ_WC_Char%d+_Interrupt_") then
                        local spIntName = CreateSingleDynamicSorcererReaction(intId)
                        if spIntName ~= nil then
                            table.insert(dynamicInterrupts, intId)
                        end
                    end
                end
            end
        end

        local maxSlotLevel = GetMaxSorcererSpellLevel(entity, uuid)
        local charReactionBoosts = {}
        local seenInterrupts = {}

        for spellName, _ in pairs(learnedSpells) do
            local intList = SpellToDynamicInterrupts[spellName]
            if intList ~= nil then
                for _, info in ipairs(intList) do
                    local levelAllowed = maxSlotLevel ~= 0 and math.floor(maxSlotLevel / info.level) ~= 0
                    local hasBaseReaction = info.origInterrupt ~= nil and unlockedInterrupts[info.origInterrupt] == true
                    if not seenInterrupts[info.interrupt] and levelAllowed and hasBaseReaction then
                        seenInterrupts[info.interrupt] = true
                        table.insert(charReactionBoosts, string.format("UnlockInterrupt(%s)", info.interrupt))
                    end
                end
            end
        end

        local reactSlot = 1
        local currentReactExpr = ""

        local function FlushReactionChunk(expr)
            if expr == "" or reactSlot == REACTION_SLOTS_PER_CHAR + 1 then
                return
            end
            local pName = GetCharReactionPassiveName(charIdx, reactSlot)
            local pStat = Ext.Stats.Get(pName)
            if pStat ~= nil then
                pStat.Boosts = expr
                pStat:Sync()
                payload[pName] = expr
                table.insert(CharacterReactionPassives[uuid], pName)
            end
            reactSlot = reactSlot + 1
        end

        for _, boost in ipairs(charReactionBoosts) do
            local candidate = currentReactExpr == "" and boost or (currentReactExpr .. ";" .. boost)
            if math.floor(#candidate / 1600) ~= 0 then
                FlushReactionChunk(currentReactExpr)
                currentReactExpr = boost
            else
                currentReactExpr = candidate
            end
        end

        FlushReactionChunk(currentReactExpr)
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

        EnsureDynamicReactionsPrepared()
        local childrenMap = GetSpellChildrenMap()
        local sorcSources = GetSorcererProgressionSources()
        local payload = {}
        local dynamicInterrupts = {}

        CompileCharacterPool(entity, uuid, childrenMap, sorcSources, payload, dynamicInterrupts)

        if next(payload) ~= nil or #dynamicInterrupts > 0 then
            syncChannel:Broadcast(Ext.Json.Stringify({
                passives = payload,
                dynamicInterrupts = dynamicInterrupts,
            }))
        end

        Ext.Timer.WaitFor(100, function()
            ApplyCharacterReactionPassives(uuid)
            if Osi.HasActiveStatus(uuid, "KJ_SORCERYCASTING_ACTIVE") == 1 then
                ApplyCharacterPassives(uuid)
            end
        end)

        _P("[SorceryCasting] Updated Sorcerer spell and reaction pool for character: " .. tostring(uuid))
    end

    local function RebuildAllPartySorcerers()
        SpellToDynamicInterrupts = {}
        EnsureDynamicReactionsPrepared()
        local childrenMap = GetSpellChildrenMap()
        local sorcSources = GetSorcererProgressionSources()
        local payload = {}
        local dynamicInterrupts = {}

        CharacterSlotMap = {}
        CharacterActivePassives = {}
        CharacterReactionPassives = {}

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
                    CompileCharacterPool(entity, uuid, childrenMap, sorcSources, payload, dynamicInterrupts)
                    if CharacterSlotMap[uuid] ~= nil then
                        count = count + 1
                    end
                end
            end
        end

        syncChannel:Broadcast(Ext.Json.Stringify({
            passives = payload,
            dynamicInterrupts = dynamicInterrupts,
        }))

        Ext.Timer.WaitFor(100, function()
            for uuid, _ in pairs(CharacterSlotMap) do
                ApplyCharacterReactionPassives(uuid)
                if Osi.HasActiveStatus(uuid, "KJ_SORCERYCASTING_ACTIVE") == 1 then
                    ApplyCharacterPassives(uuid)
                end
            end
        end)

        _P("[SorceryCasting] Initialized Sorcerer spell and reaction pools for " .. tostring(count) .. " recruited character(s).")
    end

    function KJ_RebuildSorcerers()
        RebuildAllPartySorcerers()
    end

    requestChannel:SetHandler(function()
        RebuildAllPartySorcerers()
    end)

    Ext.Events.GameStateChanged:Subscribe(function(e)
        if e.ToState == "Running" then
            Ext.Timer.WaitFor(600, function()
                RebuildAllPartySorcerers()
            end)
        end
    end)

    Ext.Events.SessionLoaded:Subscribe(function()
        local function DelayedSingleRebuild(character)
            local uuid = NormalizeUuid(character)
            if uuid == nil then
                return
            end

            local token = (PendingRebuilds[uuid] or 0) + 1
            PendingRebuilds[uuid] = token

            Ext.Timer.WaitFor(650, function()
                if PendingRebuilds[uuid] == token then
                    PendingRebuilds[uuid] = nil
                    RebuildSingleSorcerer(uuid)
                end
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
            Ext.Timer.WaitFor(750, function()
                RebuildAllPartySorcerers()
            end)
        end)
    end)
end
