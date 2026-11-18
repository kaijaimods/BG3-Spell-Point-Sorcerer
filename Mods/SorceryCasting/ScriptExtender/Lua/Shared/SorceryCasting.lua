local SORCERER_CLASS_UUID = "784001e2-c96d-4153-beb6-2adbef5abc92"
local MAX_CHAR_SLOTS = 8
local SLOTS_PER_LEVEL = 3
local REACTION_SLOTS_PER_CHAR = 6

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

local function ChunkBoostsList(items, separator, maxLen)
    local chunks = {}
    local current = ""
    for _, item in ipairs(items) do
        local candidate = current == "" and item or (current .. separator .. item)
        if #candidate > maxLen then
            if current ~= "" then
                table.insert(chunks, current)
            end
            current = item
        else
            current = candidate
        end
    end
    if current ~= "" then
        table.insert(chunks, current)
    end
    return chunks
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

local function ResolveInheritedDisplayName(statName)
    local current = Ext.Stats.Get(statName)
    local visited = {}
    while current ~= nil do
        if current.Name ~= nil then
            if visited[current.Name] then
                break
            end
            visited[current.Name] = true
        end

        local rawHandle = current.DisplayName or ""
        if rawHandle ~= "" then
            local cleanHandle = string.gsub(rawHandle, ";%d+$", "")
            local translated = Ext.Loca.GetTranslatedString(cleanHandle)
            if translated ~= nil and translated ~= "" then
                return translated
            end
            if not string.match(cleanHandle, "^h[%x]+g[%x]+g[%x]+g[%x]+g[%x]+$") then
                return cleanHandle
            end
        end

        local parentName = current.Using
        if parentName ~= nil and parentName ~= "" then
            current = Ext.Stats.Get(parentName)
        else
            break
        end
    end
    return statName
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
        if not string.find(intName, "^KJ_SP_")
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

local function StripWarCasterPrefix(interruptName)
    local base = string.gsub(interruptName, "^KJ_WC_%u%u%u_PM_Interrupt_", "")
    base = string.gsub(base, "^KJ_WC_%u%u%u_Interrupt_", "")
    base = string.gsub(base, "^KJ_WC_PM_Interrupt_", "")
    base = string.gsub(base, "^KJ_WC_Interrupt_", "")
    return base
end

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
    return childEffects ~= "" and childEffects == rootEffects
end

local function IsRedundantUpcastInterrupt(interruptName, intStat)
    if string.find(interruptName, "^KJ_WC_") then
        return IsNonScalingUpcastSpell(StripWarCasterPrefix(interruptName))
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

local function RegisterDynamicInterruptForSpell(spellName, newIntName, slotLevel, origInterrupt)
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
        origInterrupt = origInterrupt,
    })
end

local function GenerateDynamicSorcererReactions()
    SpellToDynamicInterrupts = {}
    local intToSpells = BuildInterruptToSpellsMap()

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

                        if spCost ~= nil and ((intSlotStr ~= nil) or (spellSlotStr ~= nil)) then
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
                                RegisterDynamicInterruptForSpell(linkedSpell, newIntName, slotLevel, interruptName)

                                local rootId = spellStat.RootSpellID
                                if rootId ~= nil and rootId ~= "" then
                                    RegisterDynamicInterruptForSpell(rootId, newIntName, slotLevel, interruptName)
                                end

                                if string.find(linkedSpell, "UAWC_") then
                                    local baseFromSpell = string.gsub(linkedSpell, "^UAWC_PM_", "")
                                    baseFromSpell = string.gsub(baseFromSpell, "^UAWC_", "")
                                    RegisterDynamicInterruptForSpell(baseFromSpell, newIntName, slotLevel, interruptName)
                                end

                                if string.find(interruptName, "^Interrupt_UAWC_") then
                                    local baseFromInt = string.gsub(interruptName, "^Interrupt_UAWC_PM_", "")
                                    baseFromInt = string.gsub(baseFromInt, "^Interrupt_UAWC_", "")
                                    RegisterDynamicInterruptForSpell(baseFromInt, newIntName, slotLevel, interruptName)
                                end

                                if string.find(interruptName, "^KJ_WC_") then
                                    RegisterDynamicInterruptForSpell(StripWarCasterPrefix(interruptName), newIntName, slotLevel, interruptName)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
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
            EnsureDynamicReactionsPrepared()
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

    local function GetMaxSorcererSpellLevel(uuid)
        local charLevel = uuid ~= nil and Osi.GetLevel(uuid) or 0
        if charLevel == 0 then
            return 1
        end
        local maxSpellLvl = math.ceil(charLevel / 2)
        return math.floor(maxSpellLvl / 6) ~= 0 and 5 or maxSpellLvl
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
            for rSlot = 1, REACTION_SLOTS_PER_CHAR do
                local rName = GetCharReactionPassiveName(charIdx, rSlot)
                if Osi.HasPassive(uuid, rName) == 1 then
                    Osi.RemovePassive(uuid, rName)
                end
            end
        end
    end

    local function CharacterHasInterrupt(uuid, targetInterrupt)
        if targetInterrupt == nil or targetInterrupt == "" then
            return true
        end
        local ent = Ext.Entity.Get(uuid)
        if ent == nil or ent.InterruptContainer == nil or ent.InterruptContainer.Interrupts == nil then
            return false
        end
        for _, ie in ipairs(ent.InterruptContainer.Interrupts) do
            if ie ~= nil and ie.InterruptData ~= nil and ie.InterruptData.Interrupt == targetInterrupt then
                return true
            end
        end
        return false
    end

    local function GetLastInterruptInPassive(passiveName)
        local pStat = Ext.Stats.Get(passiveName)
        if pStat == nil or pStat.Boosts == nil or pStat.Boosts == "" then
            return nil
        end
        local lastInt = nil
        for intId in string.gmatch(pStat.Boosts, "UnlockInterrupt%(([^%)]+)%)") do
            lastInt = intId
        end
        return lastInt
    end

    local function ApplyPassivesSequentially(uuid, passiveList, index)
        if index > #passiveList then
            return
        end

        local pName = passiveList[index]
        local expectedLastInt = GetLastInterruptInPassive(pName)

        if Osi.HasPassive(uuid, pName) == 0 then
            Osi.AddPassive(uuid, pName)
        end

        local attempts = 0
        local function WaitUntilApplied()
            attempts = attempts + 1
            if (Osi.HasPassive(uuid, pName) == 1 and CharacterHasInterrupt(uuid, expectedLastInt)) or attempts >= 120 then
                ApplyPassivesSequentially(uuid, passiveList, index + 1)
            else
                Ext.Timer.WaitFor(1, WaitUntilApplied)
            end
        end

        Ext.Timer.WaitFor(1, WaitUntilApplied)
    end

    local function ApplyCharacterPassives(uuid)
        local cleanUuid = NormalizeUuid(uuid)
        ApplyPassivesSequentially(cleanUuid, CharacterActivePassives[cleanUuid] or {}, 1)
    end

    local function ApplyCharacterReactionPassives(uuid)
        local cleanUuid = NormalizeUuid(uuid)
        ApplyPassivesSequentially(cleanUuid, CharacterReactionPassives[cleanUuid] or {}, 1)
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

        local containerChildren = {}
        for spellName, _ in pairs(learnedSpells) do
            local sStat = Ext.Stats.Get(spellName)
            if sStat ~= nil and sStat.ModifierList == "SpellData" and (sStat.ContainerSpells or "") ~= "" then
                for subSpell in string.gmatch(sStat.ContainerSpells, "[^;]+") do
                    CollectSpellFamily(subSpell, childrenMap, containerChildren)
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
            local chunks = ChunkBoostsList(spellsByLevel[level], "|", 1600)
            for slotIndex = 1, math.min(#chunks, SLOTS_PER_LEVEL) do
                local pName = GetCharPassiveName(charIdx, level, slotIndex)
                local pStat = Ext.Stats.Get(pName)
                if pStat ~= nil then
                    local boostStr = string.format(
                        "UnlockSpellVariant((%s) & KJCanSorceryCast(),ModifyUseCosts(Add,SorceryPoint,%d,0),ModifyUseCosts(Replace,SpellSlotsGroup,0,-1,SpellSlotsGroup))",
                        chunks[slotIndex],
                        spCost
                    )
                    pStat.Boosts = boostStr
                    pStat:Sync()
                    payload[pName] = boostStr
                    table.insert(CharacterActivePassives[uuid], pName)
                end
            end
        end

        local unlockedInterrupts = {}
        if entity.InterruptContainer ~= nil and entity.InterruptContainer.Interrupts ~= nil then
            for _, intEnt in ipairs(entity.InterruptContainer.Interrupts) do
                if intEnt ~= nil and intEnt.InterruptData ~= nil and intEnt.InterruptData.Interrupt ~= nil then
                    unlockedInterrupts[intEnt.InterruptData.Interrupt] = true
                end
            end
        end

        local maxSlotLevel = GetMaxSorcererSpellLevel(uuid)
        local candidateReactions = {}
        local seenInterrupts = {}

        for spellName, _ in pairs(learnedSpells) do
            local intList = SpellToDynamicInterrupts[spellName]
            if intList ~= nil then
                for _, info in ipairs(intList) do
                    local levelAllowed = maxSlotLevel ~= 0 and math.floor(maxSlotLevel / info.level) ~= 0
                    local hasBaseReaction = info.origInterrupt ~= nil and unlockedInterrupts[info.origInterrupt] == true
                    if not seenInterrupts[info.interrupt] and levelAllowed and hasBaseReaction then
                        seenInterrupts[info.interrupt] = true
                        local displayText = ResolveInheritedDisplayName(info.interrupt)
                        local cleanBase = string.gsub(displayText, "%s*%([Ll]evel%s*%d+%)", "")
                        local sortKey = string.format("%s_%02d_%s", string.lower(cleanBase), info.level or 0, info.interrupt)
                        table.insert(candidateReactions, {
                            interrupt = info.interrupt,
                            sortKey = sortKey,
                        })
                    end
                end
            end
        end

        table.sort(candidateReactions, function(a, b)
            return a.sortKey < b.sortKey
        end)

        local charReactionBoosts = {}
        for _, entry in ipairs(candidateReactions) do
            table.insert(charReactionBoosts, string.format("UnlockInterrupt(%s)", entry.interrupt))
        end

        local reactChunks = ChunkBoostsList(charReactionBoosts, ";", 1600)
        for reactSlot = 1, math.min(#reactChunks, REACTION_SLOTS_PER_CHAR) do
            local pName = GetCharReactionPassiveName(charIdx, reactSlot)
            local pStat = Ext.Stats.Get(pName)
            if pStat ~= nil then
                pStat.Boosts = reactChunks[reactSlot]
                pStat:Sync()
                payload[pName] = reactChunks[reactSlot]
                table.insert(CharacterReactionPassives[uuid], pName)
            end
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

        EnsureDynamicReactionsPrepared()
        local childrenMap = GetSpellChildrenMap()
        local sorcSources = GetSorcererProgressionSources()
        local payload = {}

        CompileCharacterPool(entity, uuid, childrenMap, sorcSources, payload)

        if next(payload) ~= nil then
            syncChannel:Broadcast(Ext.Json.Stringify(payload))
        end

        Ext.Timer.WaitFor(100, function()
            ApplyCharacterReactionPassives(uuid)
            if Osi.HasActiveStatus(uuid, "KJ_SORCERYCASTING_ACTIVE") == 1 then
                ApplyCharacterPassives(uuid)
            end
        end)
    end

    local function RebuildAllPartySorcerers()
        EnsureDynamicReactionsPrepared()
        local childrenMap = GetSpellChildrenMap()
        local sorcSources = GetSorcererProgressionSources()
        local payload = {}

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

        for _, row in ipairs(allCandidateRows) do
            local rawGuid = table.unpack(row)
            local uuid = NormalizeUuid(rawGuid)
            if uuid ~= nil and not seenUuids[uuid] then
                seenUuids[uuid] = true
                local entity = Ext.Entity.Get(uuid)
                if entity ~= nil then
                    CompileCharacterPool(entity, uuid, childrenMap, sorcSources, payload)
                end
            end
        end

        syncChannel:Broadcast(Ext.Json.Stringify(payload))

        Ext.Timer.WaitFor(100, function()
            for uuid, _ in pairs(CharacterSlotMap) do
                ApplyCharacterReactionPassives(uuid)
                if Osi.HasActiveStatus(uuid, "KJ_SORCERYCASTING_ACTIVE") == 1 then
                    ApplyCharacterPassives(uuid)
                end
            end
        end)
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

        local LastNonSPInterruptSignature = {}

        local function ComputeNonSPInterruptSignature(entity)
            if entity == nil or entity.InterruptContainer == nil or entity.InterruptContainer.Interrupts == nil then
                return ""
            end
            local list = {}
            for _, ie in ipairs(entity.InterruptContainer.Interrupts) do
                if ie ~= nil and ie.InterruptData ~= nil and ie.InterruptData.Interrupt ~= nil then
                    local id = ie.InterruptData.Interrupt
                    if not string.find(id, "^KJ_SP_") then
                        table.insert(list, id)
                    end
                end
            end
            table.sort(list)
            return table.concat(list, ";")
        end

        Ext.Entity.OnChange("InterruptContainer", function(entity)
            if entity ~= nil and entity.Uuid ~= nil and entity.Uuid.EntityUuid ~= nil then
                local uuid = NormalizeUuid(entity.Uuid.EntityUuid)
                if uuid ~= nil and CharacterSlotMap[uuid] ~= nil then
                    local sig = ComputeNonSPInterruptSignature(entity)
                    if sig ~= LastNonSPInterruptSignature[uuid] then
                        LastNonSPInterruptSignature[uuid] = sig
                        DelayedSingleRebuild(uuid)
                    end
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