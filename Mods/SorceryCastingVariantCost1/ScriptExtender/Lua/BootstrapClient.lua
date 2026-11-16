Ext.Require("Shared/SorceryCasting.lua")

local syncChannel = Ext.Net.CreateChannel(ModuleUUID, "SorceryCasting_SyncPool")
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
