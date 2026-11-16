local SORCERER_CLASS_UUID = "784001e2-c96d-4153-beb6-2adbef5abc92"
local MAX_SLOTS_PER_LEVEL = 10

local SORCERER_SPELL_LISTS = {
    ["92c4751f-6255-4f67-822c-a75d53830b27"] = true, -- Sorcerer Level 1
    ["f80396e2-cb76-4694-b0db-5c34da61a478"] = true, -- Sorcerer Level 2
    ["dcbaf2ae-1f45-453e-ab83-cd154f8277a4"] = true, -- Sorcerer Level 3
    ["5fe40622-1d3e-4cc1-8d89-e66fe51d8c5c"] = true, -- Sorcerer Level 4
    ["3276fcfe-e143-4559-b6e0-7d7aa0ffcb53"] = true, -- Sorcerer Level 5
}

local SORCERY_POINT_COSTS = {
    2, -- Level 1
    3, -- Level 2
    5, -- Level 3
    6, -- Level 4
    7, -- Level 5
}

local function GetSlotPassiveName(level, slotIndex)
    return string.format("KJ_SorceryCasting_SpellCosts_Level%d_%d", level, slotIndex)
end

local function BuildSpellChildrenMap()
    local map = {}
    local allSpells = Ext.Stats.GetStats("SpellData") or {}

    for _, spellName in ipairs(allSpells) do
        local stat = Ext.Stats.Get(spellName)
        if stat ~= nil and stat.Using ~= nil and stat.Using ~= "" then
            map[stat.Using] = map[stat.Using] or {}
            table.insert(map[stat.Using], spellName)
        end
    end

    return map
end

local function CollectSpellFamily(rootSpell, childrenMap, collected)
    if collected[rootSpell] then
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

local function GetAllSorcererProgressionSpells(childrenMap)
    local expandedSpells = {}
    local sorcClassGuids = { [SORCERER_CLASS_UUID] = true }
    local sorcTableGuids = {}

    local allClasses = Ext.StaticData.GetAll("ClassDescription") or {}
    for _, classUuid in ipairs(allClasses) do
        local classDesc = Ext.StaticData.Get(classUuid, "ClassDescription")
        if classDesc ~= nil then
            if classUuid == SORCERER_CLASS_UUID or classDesc.ParentGuid == SORCERER_CLASS_UUID then
                sorcClassGuids[classUuid] = true
                if classDesc.ProgressionTableUUID ~= nil then
                    sorcTableGuids[classDesc.ProgressionTableUUID] = true
                end
            end
        end
    end

    local validSpellLists = {}
    for uuid, _ in pairs(SORCERER_SPELL_LISTS) do
        validSpellLists[uuid] = true
    end

    local allProgressions = Ext.StaticData.GetAll("Progression") or {}
    for _, progUuid in ipairs(allProgressions) do
        local prog = Ext.StaticData.Get(progUuid, "Progression")
        if prog ~= nil and prog.TableUUID ~= nil then
            local isSorcProg = sorcTableGuids[prog.TableUUID] or sorcClassGuids[prog.TableUUID]
            if not isSorcProg and prog.Name ~= nil then
                isSorcProg = string.find(string.lower(prog.Name), "sorcerer") ~= nil
            end

            if isSorcProg then
                if prog.SelectSpells ~= nil then
                    for _, entry in ipairs(prog.SelectSpells) do
                        if entry.SpellUUID ~= nil then
                            validSpellLists[entry.SpellUUID] = true
                        end
                    end
                end
                if prog.AddSpells ~= nil then
                    for _, entry in ipairs(prog.AddSpells) do
                        if entry.SpellUUID ~= nil then
                            validSpellLists[entry.SpellUUID] = true
                        end
                    end
                end
            end
        end
    end

    local allLists = Ext.StaticData.GetAll("SpellList") or {}
    for _, listUuid in ipairs(allLists) do
        local spellList = Ext.StaticData.Get(listUuid, "SpellList")
        if spellList ~= nil then
            local isSorcList = validSpellLists[listUuid]
                or (spellList.Name ~= nil and string.find(string.lower(spellList.Name), "sorcerer") ~= nil)

            if isSorcList and spellList.Spells ~= nil then
                for k, v in pairs(spellList.Spells) do
                    local spellName = type(k) == "string" and k or v
                    if type(spellName) == "string" then
                        CollectSpellFamily(spellName, childrenMap, expandedSpells)

                        for _, suffix in ipairs({ "_Sorcerer", "_Class" }) do
                            local variant = spellName .. suffix
                            if Ext.Stats.Get(variant) ~= nil then
                                CollectSpellFamily(variant, childrenMap, expandedSpells)
                            end
                        end
                    end
                end
            end
        end
    end

    return expandedSpells
end

local function PopulatePoolAtStartup()
    local childrenMap = BuildSpellChildrenMap()
    local expandedSpells = GetAllSorcererProgressionSpells(childrenMap)
    local spellsByLevel = { {}, {}, {}, {}, {} }

    for spellName, _ in pairs(expandedSpells) do
        local stat = Ext.Stats.Get(spellName)
        if stat ~= nil then
            local useCosts = stat.UseCosts or ""
            local slotLevelStr = string.match(useCosts, "SpellSlotsGroup:%d+:%d+:(%d+)")
            local slotLevel = tonumber(slotLevelStr) or stat.Level

            if slotLevel ~= nil and slotLevel >= 1 and slotLevel <= 5 and string.find(useCosts, "SpellSlotsGroup") then
                table.insert(spellsByLevel[slotLevel], string.format("SpellId('%s')", spellName))
            end
        end
    end

    local activeCount = 0
    local totalSpells = 0

    for level = 1, 5 do
        for slot = 1, MAX_SLOTS_PER_LEVEL do
            local pStat = Ext.Stats.Get(GetSlotPassiveName(level, slot))
            if pStat ~= nil then
                pStat.Boosts = ""
            end
        end

        local spCost = SORCERY_POINT_COSTS[level]
        local spellPredicates = spellsByLevel[level]
        local slotIndex = 1
        local currentExpr = ""

        local function FlushChunk(expr)
            if expr == "" then return end
            local pName = GetSlotPassiveName(level, slotIndex)
            local pStat = Ext.Stats.Get(pName)
            if pStat ~= nil then
                pStat.Boosts = string.format(
                    "UnlockSpellVariant((%s) & KJCanSorceryCast(),ModifyUseCosts(Add,SorceryPoint,%d,0),ModifyUseCosts(Replace,SpellSlotsGroup,0,-1,SpellSlotsGroup))",
                    expr,
                    spCost
                )
                pStat:Sync()
                activeCount = activeCount + 1
            else
                _P("[SorceryCasting] WARNING: Pool exhausted at " .. pName)
            end
            slotIndex = slotIndex + 1
        end

        for _, pred in ipairs(spellPredicates) do
            local candidate = currentExpr == "" and pred or (currentExpr .. "|" .. pred)
            if #candidate > 1600 then
                FlushChunk(currentExpr)
                currentExpr = pred
            else
                currentExpr = candidate
            end
        end

        FlushChunk(currentExpr)
        totalSpells = totalSpells + #spellPredicates
    end

    _P("[SorceryCasting] Startup compiled " .. tostring(totalSpells) .. " Sorcerer/subclass spells (Levels 1-5) into " .. tostring(activeCount) .. " grouped passives.")
end

PopulatePoolAtStartup()
Ext.Events.StatsLoaded:Subscribe(PopulatePoolAtStartup)

if Ext.IsServer() then
    local function HasSorcererLevels(entity)
        if entity == nil or entity.Classes == nil or entity.Classes.Classes == nil then
            return false
        end
        for _, classInfo in ipairs(entity.Classes.Classes) do
            if classInfo.ClassUUID == SORCERER_CLASS_UUID and (classInfo.Level or 0) ~= 0 then
                return true
            end
        end
        return false
    end

    local function SyncAllPartySorcerers()
        local partyEntities = Ext.Entity.GetAllEntitiesWithComponent("PartyMember")
        for _, entity in ipairs(partyEntities) do
            local uuid = entity.Uuid and entity.Uuid.EntityUuid
            if uuid ~= nil and HasSorcererLevels(entity) then
                if Osi.HasPassive(uuid, "KJ_SorceryCasting_Passive") == 0 then
                    Osi.AddPassive(uuid, "KJ_SorceryCasting_Passive")
                end
            end
        end
    end

    Ext.Events.GameStateChanged:Subscribe(function(e)
        if e.ToState == "Running" then
            SyncAllPartySorcerers()
        end
    end)

    Ext.Events.SessionLoaded:Subscribe(function()
        Ext.Osiris.RegisterListener("LeveledUp", 1, "after", function(character)
            SyncAllPartySorcerers()
        end)

        Ext.Osiris.RegisterListener("CharacterJoinedParty", 1, "after", function(character)
            SyncAllPartySorcerers()
        end)
    end)
end
