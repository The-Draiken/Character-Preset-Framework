--- Applies preset data while the player is in Character Creation.
--- In CC the appearance lives on character creation definition components, not on
--- CharacterCreationAppearance: CCCharacterDefinition for the player character and
--- CCCompanionDefinition for the Dream Guardian (Dream Visitor).
--- Field layouts of these components differ between Script Extender versions, so every
--- access is probed and wrapped in pcall.
CCApplier = {}

CCApplier.TARGET_CHARACTER = "Character"
CCApplier.TARGET_GUARDIAN = "DreamGuardian"

--- Messages from the last Apply call, included in the CC debug report
CCApplier.LastLog = {}

local function note(msg)
    table.insert(CCApplier.LastLog, msg)
    CPFPrint(2, "CCApplier: " .. msg)
end

local STAT_FIELDS = {
    { preset = "BodyShape", names = { "BodyShape" } },
    { preset = "BodyType",  names = { "BodyType" } },
    { preset = "Race",      names = { "Race", "RaceUuid" } },
    { preset = "SubRace",   names = { "Subrace", "SubRace", "SubRaceUuid" } },
}

local function safeGet(obj, key)
    local ok, value = pcall(function() return obj[key] end)
    if ok then return value end
    return nil
end

--- Whether a value looks like a CharacterCreationAppearance (has Visuals and Elements)
local function isAppearance(value)
    if value == nil or type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
        return false
    end
    return safeGet(value, "Visuals") ~= nil and safeGet(value, "Elements") ~= nil
end

--- Finds the appearance object and the object holding race/body fields inside a CC definition component
---@param component any
---@return any|nil appearance
---@return any|nil statsHolder
local function findAppearance(component)
    if not component then return nil, nil end

    -- Known layouts first
    local definition = safeGet(component, "Definition")
    if definition then
        local visual = safeGet(definition, "Visual")
        if isAppearance(visual) then return visual, definition end
    end
    for _, key in ipairs({ "Visual", "Appearance" }) do
        local visual = safeGet(component, key)
        if isAppearance(visual) then return visual, component end
    end

    -- Unknown layout: scan fields one level deep
    local found = nil
    pcall(function()
        for _, value in pairs(component) do
            if isAppearance(value) then
                found = value
                break
            end
        end
    end)
    if found then return found, component end

    return nil, nil
end

function CCApplier.BumpChange(component)
    local changed = {}
    if pcall(function() component.ChangeId = component.ChangeId + 1 end) then table.insert(changed, "ChangeId") end
    if pcall(function() component.NeedsSync = true end) then table.insert(changed, "NeedsSync") end
    if pcall(function() component.Dirty = true end) then table.insert(changed, "Dirty") end
    return changed
end

local function replicate(entity, componentName)
    if not Ext.IsServer() then return end
    local ok, err = pcall(function() entity:Replicate(componentName) end)
    if not ok then
        note(string.format("could not replicate %s: %s", componentName, tostring(err)))
    else
        note("replicated " .. componentName)
    end
end

--- Copies preset appearance fields onto an appearance object
---@return integer applied
function CCApplier.WriteAppearance(appearance, ccAppearance)
    local applied = 0
    local copy = Table.deepcopy(ccAppearance)
    for k, v in pairs(copy) do
        -- Presets saved in game leave AccessorySet (and field_98) empty. Character Creation requires a value,
        -- so writing "none" leaves a choice pending: keep whatever the creator already has instead.
        if v == "" then
            note("kept current " .. tostring(k) .. " (empty in preset)")
        else
            local ok, err = pcall(function() appearance[k] = v end)
            if ok then
                applied = applied + 1
            else
                note("failed to set " .. tostring(k) .. ": " .. tostring(err))
            end
        end
    end
    return applied
end

function CCApplier.WriteStats(holder, ccStats)
    if not holder or not ccStats then return end
    for _, field in ipairs(STAT_FIELDS) do
        local value = ccStats[field.preset]
        if value ~= nil then
            for _, name in ipairs(field.names) do
                if safeGet(holder, name) ~= nil then
                    pcall(function() holder[name] = value end)
                    break
                end
            end
        end
    end
end

---@param name string
---@return EntityHandle[]
local function entitiesWith(name)
    local ok, result = pcall(Ext.Entity.GetAllEntitiesWithComponent, name)
    if ok and result then return result end
    return {}
end

local function sameUser(a, b)
    local ua = a and a.UserReservedFor and a.UserReservedFor.UserID
    local ub = b and b.UserReservedFor and b.UserReservedFor.UserID
    return ua ~= nil and ua == ub
end

--- Finds the entity carrying the player's Dream Guardian definition during CC
---@param playerEntity EntityHandle
---@return EntityHandle|nil
function CCApplier.FindGuardianEntity(playerEntity)
    if playerEntity and safeGet(playerEntity, "CCCompanionDefinition") then
        return playerEntity
    end

    local candidates = entitiesWith("CCCompanionDefinition")
    if #candidates == 1 then
        return candidates[1]
    end
    for _, candidate in ipairs(candidates) do
        if sameUser(candidate, playerEntity) then
            return candidate
        end
    end
    return nil
end

--- Finds the entity holding the player's CC character definition.
--- The controlled character on the client is not always the entity that owns the definition.
---@param playerEntity EntityHandle|nil
---@return EntityHandle|nil
function CCApplier.FindCCEntity(playerEntity)
    if playerEntity and safeGet(playerEntity, "CCCharacterDefinition") then
        return playerEntity
    end

    local candidates = entitiesWith("CCCharacterDefinition")
    for _, candidate in ipairs(candidates) do
        if sameUser(candidate, playerEntity) then
            return candidate
        end
    end
    if #candidates == 1 then
        return candidates[1]
    end
    return nil
end

--- Whether the entity is currently in character creation (has a CC definition)
---@param entity EntityHandle
---@return boolean
function CCApplier.IsInCC(entity)
    return entity ~= nil and safeGet(entity, "CCCharacterDefinition") ~= nil
end

--- Extracts the Dream Guardian's CC appearance for saving as a preset
---@param guardianEntity EntityHandle
---@return PresetData|nil
function CCApplier.ExtractGuardianData(guardianEntity)
    local component = guardianEntity and safeGet(guardianEntity, "CCCompanionDefinition")
    local appearance, holder = findAppearance(component)
    if not appearance then return nil end

    local stats = {}
    for _, field in ipairs(STAT_FIELDS) do
        for _, name in ipairs(field.names) do
            local value = safeGet(holder, name)
            if value ~= nil then
                stats[field.preset] = value
                break
            end
        end
    end

    return {
        CCStats = next(stats) and stats or nil,
        CCAppearance = Table.deepcopy(appearance),
    }
end

--- Applies preset data to a CC definition
---@param entity EntityHandle
---@param target "Character"|"DreamGuardian"
---@param presetData PresetData
---@param applyStats boolean
---@return boolean success
---@return string? error
function CCApplier.Apply(entity, target, presetData, applyStats)
    CCApplier.LastLog = {}
    local componentName = target == CCApplier.TARGET_GUARDIAN and "CCCompanionDefinition" or "CCCharacterDefinition"
    local component = safeGet(entity, componentName)
    if not component then
        note("entity has no " .. componentName)
        return false, "Entity has no " .. componentName
    end

    local appearance, holder = findAppearance(component)
    if not appearance then
        note("no appearance found on " .. componentName)
        return false, "Could not find appearance data on " .. componentName
    end

    local applied = CCApplier.WriteAppearance(appearance, presetData.CCAppearance)
    if applyStats then
        CCApplier.WriteStats(holder, presetData.CCStats)
    end

    CCApplier.BumpChange(component)
    if componentName == "CCCharacterDefinition" then
        local common = safeGet(entity, "CCDefinitionCommon")
        if common then
            CCApplier.BumpChange(common)
            replicate(entity, "CCDefinitionCommon")
        end
    end
    replicate(entity, componentName)

    note(string.format("applied %d appearance fields to %s (%s) on %s", applied, componentName, target,
        Ext.IsServer() and "server" or "client"))
    return true
end

return CCApplier
