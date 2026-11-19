---Client-side handler for applying preset data to client dummies

-- Thanks rakor and Skiz for this!
local function refreshMirrorDummy()
    -- Doesn't seem to work in CC!
    VCTimer:OnTicks(10, function()
        CPFPrint(2, "Refreshing CC dummy")
        Ext.UI.Defer(function()
            local root = Ext.UI.GetRoot()
            if not root then return end
            local panel = root
            for _, index in ipairs({ 1, 1, 24, 1 }) do
                panel = panel:Child(index)
                if not panel then return end
            end
            local command = panel:GetProperty("StartCharacterCreation")
            if command then command:Execute() end
        end)
    end)
end

--- Get all relevant dummy entities (from CCChangeAppearanceDefinition and ClientCCDummyDefinition)
---@return EntityHandle[] dummyEntities
local function GetDummyEntities()
    local dummies = {}

    -- Get all CCChangeAppearanceDefinition entities
    local ccChangeAppearanceEntities = Ext.Entity.GetAllEntitiesWithComponent('CCChangeAppearanceDefinition')
    if ccChangeAppearanceEntities then
        for _, entity in ipairs(ccChangeAppearanceEntities) do
            table.insert(dummies, entity)
        end
    end

    -- Get ClientCCDummyDefinition entity (specifically index 2?)
    local ccDummyEntities = Ext.Entity.GetAllEntitiesWithComponent('ClientCCDummyDefinition')
    if ccDummyEntities and ccDummyEntities[2] then
        table.insert(dummies, ccDummyEntities[2])
    end

    return dummies
end

--- Extract CCStats-compatible stats from a dummy entity
---@param entity EntityHandle
---@return CCStats|nil
local function ExtractDummyStats(entity)
    -- Try ClientCCDummyDefinition first
    if entity.ClientCCDummyDefinition then
        local def = entity.ClientCCDummyDefinition
        if def.BodyShape ~= nil and def.BodyType ~= nil and def.Race and def.Subrace then
            return {
                BodyShape = def.BodyShape,
                BodyType = def.BodyType,
                Race = def.Race,
                SubRace = def.Subrace
            }
        end
    end

    -- Try ClientCCChangeAppearanceDefinition
    if entity.ClientCCChangeAppearanceDefinition and entity.ClientCCChangeAppearanceDefinition.Definition then
        local def = entity.ClientCCChangeAppearanceDefinition.Definition
        if def.BodyShape ~= nil and def.BodyType ~= nil and def.Race and def.Subrace then
            return {
                BodyShape = def.BodyShape,
                BodyType = def.BodyType,
                Race = def.Race,
                SubRace = def.Subrace
            }
        end
    end

    -- Try CCChangeAppearanceDefinition
    if entity.CCChangeAppearanceDefinition and entity.CCChangeAppearanceDefinition.Definition then
        local def = entity.CCChangeAppearanceDefinition.Definition
        if def.BodyShape ~= nil and def.BodyType ~= nil and def.Race and def.Subrace then
            return {
                BodyShape = def.BodyShape,
                BodyType = def.BodyType,
                Race = def.Race,
                SubRace = def.Subrace
            }
        end
    end

    return nil
end

--- Apply visuals to a dummy entity, trying all known paths
---@param entity EntityHandle
---@param ccaTable CharacterCreationAppearance
---@return integer successCount
---@return integer failCount
local function ApplyVisualsToDummy(entity, ccaTable)
    -- Define all possible paths to try for accessing the Visual component
    local pathsToTry = {
        {
            name = "CCChangeAppearanceDefinition.Appearance.Visual",
            getter = function(e)
                return e.CCChangeAppearanceDefinition and
                    e.CCChangeAppearanceDefinition.Appearance and
                    e.CCChangeAppearanceDefinition.Appearance.Visual
            end
        },
        {
            name = "CCChangeAppearanceDefinition.Definition.Visual",
            getter = function(e)
                return e.CCChangeAppearanceDefinition and
                    e.CCChangeAppearanceDefinition.Definition and
                    e.CCChangeAppearanceDefinition.Definition.Visual
            end
        },
        {
            name = "ClientCCChangeAppearanceDefinition.Definition.Visual",
            getter = function(e)
                return e.ClientCCChangeAppearanceDefinition and
                    e.ClientCCChangeAppearanceDefinition.Definition and
                    e.ClientCCChangeAppearanceDefinition.Definition.Visual
            end
        },
        {
            name = "ClientCCDummyDefinition.Visual",
            getter = function(e)
                return e.ClientCCDummyDefinition and
                    e.ClientCCDummyDefinition.Visual
            end
        },
    }

    local totalSuccessCount = 0
    local totalFailCount = 0
    local pathsAttempted = 0

    -- Try each path
    for _, path in ipairs(pathsToTry) do
        local visual = path.getter(entity)

        if visual then
            CPFPrint(2, "Found Visual at path: " .. path.name)
            pathsAttempted = pathsAttempted + 1

            -- Apply CCA table to this visual
            local copy = Table.deepcopy(ccaTable)
            local successCount = 0
            local failCount = 0

            for k, v in pairs(copy) do
                -- Empty values in a preset mean "not set": keep the dummy's current value
                local success, err = true, nil
                if v ~= "" then
                    success, err = pcall(function() visual[k] = v end)
                end
                if success then
                    successCount = successCount + 1
                else
                    failCount = failCount + 1
                    CPFPrint(2, string.format("Failed to set property %s on %s: %s", k, path.name, tostring(err)))
                end
            end

            totalSuccessCount = totalSuccessCount + successCount
            totalFailCount = totalFailCount + failCount

            CPFPrint(2, string.format("Path %s: %d succeeded, %d failed", path.name, successCount, failCount))
        end
    end

    if pathsAttempted == 0 then
        CPFPrint(2, "No valid Visual paths found on dummy entity")
    end

    return totalSuccessCount, totalFailCount
end

--- Finds this client's CC definition entity for the target.
--- In CC the definitions live on unnamed entities (no Uuid): one holds CCCharacterDefinition plus the
--- player's preview dummy, another holds CCCompanionDefinition plus the Dream Guardian's preview dummy.
---@param isGuardian boolean
---@return EntityHandle|nil
local function findClientCCEntity(isGuardian)
    local name = isGuardian and "CCCompanionDefinition" or "CCCharacterDefinition"
    local ok, list = pcall(Ext.Entity.GetAllEntitiesWithComponent, name)
    if not ok or not list then return nil end
    -- Prefer the entity that also carries a preview dummy (the local player's)
    for _, e in ipairs(list) do
        if e.ClientCCDummyDefinition then return e end
    end
    return list[1]
end

--- Character Creation: update the client copy of the CC definition and its preview dummy
---@param data table
---@param presetData PresetData
---@param isGuardian boolean
local function handleCharacterCreation(data, presetData, isGuardian)
    -- Broadcasts reach every client; only the requesting player's client edits its CC
    local me = _C()
    if not me or not me.Uuid or me.Uuid.EntityUuid ~= data.OwnerUuid then
        return
    end

    local target = isGuardian and CCApplier.TARGET_GUARDIAN or CCApplier.TARGET_CHARACTER
    local ccEntity = findClientCCEntity(isGuardian)
    local attempts = {}

    if not ccEntity then
        attempts.error = "no client CC definition entity"
    else
        local ok, err = CCApplier.Apply(ccEntity, target, presetData, data.ApplyStats)
        attempts.clientDefinition = { ok = ok, error = err, log = CCApplier.LastLog }

        -- Client-side copies of the appearance (field names from Script Extender's type definitions)
        attempts.copies = {}
        local function writeCopy(label, getter)
            local holder = nil
            pcall(function() holder = getter() end)
            if holder and holder.Visual then
                local count = CCApplier.WriteAppearance(holder.Visual, presetData.CCAppearance)
                if data.ApplyStats then CCApplier.WriteStats(holder, presetData.CCStats) end
                attempts.copies[label] = count
            end
        end
        if isGuardian then
            writeCopy("ClientCCCompanionDefinition", function() return ccEntity.ClientCCCompanionDefinition end)
        else
            writeCopy("ClientCCBaseDefinitionState.Definition",
                function() return ccEntity.ClientCCBaseDefinitionState.Definition end)
        end

        -- Preview model: write the appearance, then bump its change counters so the creator rebuilds it
        local dummyDef = ccEntity.ClientCCDummyDefinition
        if dummyDef then
            if data.ApplyStats and presetData.CCStats then
                CCStatsApplier.ApplyToDummies({ ccEntity }, presetData.CCStats)
            end
            local okCount, failCount = ApplyVisualsToDummy(ccEntity, presetData.CCAppearance)
            attempts.dummy = string.format("wrote %d fields to dummy (%d failed)", okCount, failCount)
            attempts.dummyCounters = {}
            for _, field in ipairs({ "ChangeId", "ChangeId2" }) do
                if pcall(function() dummyDef[field] = dummyDef[field] + 1 end) then
                    table.insert(attempts.dummyCounters, field)
                end
            end
        else
            attempts.dummy = "definition entity has no preview dummy"
        end

        -- Definition state: bump change ids and ask the client to sync the definition back to the server
        attempts.bumped = {}
        for _, name in ipairs({ "ClientCCDefinitionState", "ClientCCDefinitionStateEx", "CCDefinitionCommon" }) do
            local comp = nil
            pcall(function() comp = ccEntity[name] end)
            if comp then
                attempts.bumped[name] = CCApplier.BumpChange(comp)
            end
        end
    end

    Ext.System.ClientVisual.ReloadAllVisuals = true

    -- Diagnostics: give the game a moment to react, then record what the CC looks like
    if CCDebug then
        VCTimer:OnTicks(30, function()
            CCDebug.Dump(ccEntity, "client CC apply (" .. target .. ")", { attempts = attempts })
        end)
    end
end

---Handles ApplyCCAToClientDummy messages from server
---@param data table - Contains PresetData to apply
---@param userId integer
local function handleApplyCCAToClientDummy(data, userId)
    CPFPrint(2, "Received request to apply preset data to client dummy")

    local photoModeDummies = Ext.Entity.GetAllEntitiesWithComponent("PhotoModeDummy")
    if data.ApplyStats or (photoModeDummies and #photoModeDummies > 0) then
        -- Reload visuals (photography race/body swap or photo mode). Thanks Focus for the tip!
        Ext.System.ClientVisual.ReloadAllVisuals = true
    end
    if not data.PresetData then
        CPFPrint(2, "No PresetData provided in request")
        return
    end

    local presetData = data.PresetData
    if not presetData.CCAppearance then
        CPFPrint(2, "PresetData is missing CCAppearance")
        return
    end

    local isGuardian = data.Target == "DreamGuardian"

    if data.InCC then
        handleCharacterCreation(data, presetData, isGuardian)
        return
    end

    -- In game the Dream Guardian is a separate entity: never touch the player's mirror dummies
    if isGuardian then
        Ext.System.ClientVisual.ReloadAllVisuals = true
        CPFPrint(2, "Reloading visuals for Dream Guardian")
        return
    end

    -- Get all dummy entities
    local dummyEntities = GetDummyEntities()
    if #dummyEntities == 0 then
        CPFPrint(2, "No dummy entities found")
        return
    end

    -- Apply preset stats to dummies (photography race/body swap)
    if data.ApplyStats then
        CCStatsApplier.ApplyToDummies(dummyEntities, presetData.CCStats)
    end

    local totalSuccessCount = 0
    local totalFailCount = 0
    local entitiesProcessed = 0

    -- Process each dummy entity
    for _, entity in ipairs(dummyEntities) do
        -- Extract stats from dummy for compatibility check
        local dummyStats = ExtractDummyStats(entity)

        -- Check compatibility if we have both preset and dummy stats
        if presetData.CCStats and dummyStats and PresetCompatibility then
            local warnings = PresetCompatibility.CheckStats(presetData.CCStats, dummyStats)

            if #warnings > 0 then
                CPFPrint(2, "Compatibility warnings for dummy entity:")
                for _, warning in ipairs(warnings) do
                    CPFPrint(2, "  - " .. warning)
                end
                -- CPFPrint(2, "Skipping visual application for this dummy due to incompatibility")
                -- goto continue
            end
        end

        -- Apply visuals to this dummy
        local successCount, failCount = ApplyVisualsToDummy(entity, presetData.CCAppearance)
        totalSuccessCount = totalSuccessCount + successCount
        totalFailCount = totalFailCount + failCount

        if successCount > 0 or failCount > 0 then
            entitiesProcessed = entitiesProcessed + 1
        end

        ::continue::
    end

    if entitiesProcessed == 0 then
        CPFPrint(2, "No compatible dummy entities found to apply visuals")
        return
    end

    CPFPrint(2, string.format("Applied preset data to %d dummy entities: %d total succeeded, %d total failed",
        entitiesProcessed, totalSuccessCount, totalFailCount))
    refreshMirrorDummy()
end

local function initClientHandlers()
    NetChannels.ApplyCCAToClientDummy:SetHandler(handleApplyCCAToClientDummy)
end

initClientHandlers()
