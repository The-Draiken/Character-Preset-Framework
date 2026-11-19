--- Character Creation diagnostics.
--- Writes what the game actually exposes during CC (component names, CC definition contents, UI
--- view-model properties) to Script Extender/CPF/cc_debug_<side>.json so the CC apply/refresh
--- logic can be matched to the real data layout.
CCDebug = {}

local MAX_TEXT = 20000

local function side()
    return Ext.IsServer() and "server" or "client"
end

local function stringify(value)
    local ok, text = pcall(Ext.Json.Stringify, value, {
        Beautify = false,
        StringifyInternalTypes = true,
        IterateUserdata = true,
        AvoidRecursion = true,
        MaxDepth = 6,
    })
    if not ok then return "<stringify failed: " .. tostring(text) .. ">" end
    if #text > MAX_TEXT then text = text:sub(1, MAX_TEXT) .. "...<truncated>" end
    return text
end

local function isCCName(name)
    return name:find("CC") ~= nil or name:find("CharacterCreation") ~= nil
        or name:find("Companion") ~= nil or name:find("Dummy") ~= nil
end

--- Lists CC-related components on an entity and their contents
---@param entity EntityHandle
---@return table
function CCDebug.DescribeEntity(entity)
    local info = { components = {} }
    pcall(function() info.uuid = entity.Uuid and entity.Uuid.EntityUuid end)
    pcall(function() info.handle = tostring(entity) end)

    local ok, names = pcall(function() return entity:GetAllComponentNames(false) end)
    if not ok or type(names) ~= "table" then
        info.error = "GetAllComponentNames failed: " .. tostring(names)
        return info
    end

    info.allComponentNames = {}
    for _, name in pairs(names) do
        table.insert(info.allComponentNames, tostring(name))
    end

    -- Short names of the CC components (GetAllComponentNames only lists unmapped full type names)
    for _, name in ipairs({
        "CCCharacterDefinition", "CCCompanionDefinition", "CCDefinitionCommon", "CCSessionCommon",
        "ClientCCDummyDefinition", "ClientCCDefinitionState", "ClientCCBaseDefinitionState",
        "ClientCCCompanionDefinition",
    }) do
        local got, comp = pcall(function() return entity[name] end)
        if got and comp then
            info.components[name] = stringify(comp)
        end
    end

    for _, name in ipairs(info.allComponentNames) do
        if isCCName(name) then
            local got, comp = pcall(function() return entity[name] end)
            info.components[name] = got and stringify(comp) or ("<read failed: " .. tostring(comp) .. ">")
        end
    end
    return info
end

--- Entities carrying any of the listed component names
local CANDIDATE_COMPONENTS = {
    "CCCharacterDefinition", "CCCompanionDefinition", "CCDefinitionCommon", "CCState",
    "CCChangeAppearanceDefinition", "CCLevelUpDefinition", "CCFullRespecDefinition",
    "CCSessionCommon", "CCRespec", "CCCreation",
    "ClientCCDummyDefinition", "ClientCCDefinitionState", "ClientCCBaseDefinitionState",
    "ClientCCCompanionDefinition", "ClientCCChangeAppearanceDefinition", "ClientCCFullRespecDefinition",
    "ClientCCLevelUpDefinition", "ServerCCCustomIcon", "ServerCCAppearanceVisualTag",
}

---@return table
function CCDebug.DescribeWorld()
    local world = {}
    for _, name in ipairs(CANDIDATE_COMPONENTS) do
        local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, name)
        if ok and entities then
            local list = {}
            for _, e in ipairs(entities) do
                local uuid = nil
                pcall(function() uuid = e.Uuid and e.Uuid.EntityUuid end)
                table.insert(list, uuid or tostring(e))
            end
            world[name] = list
        else
            world[name] = "<unknown component>"
        end
    end
    return world
end

--- Walks the Noesis UI tree and records elements whose DataContext looks like character creation
---@return table
function CCDebug.DescribeUI()
    local found = {}
    if Ext.IsServer() then return found end

    local root = nil
    pcall(function() root = Ext.UI.GetRoot() end)
    if not root then return { error = "no UI root" } end

    local seenContexts = {}
    local function visit(node, path, depth)
        if depth > 12 or #found > 40 then return end

        local ctx = nil
        pcall(function() ctx = node.DataContext end)
        if ctx then
            local typeName = ""
            pcall(function() typeName = tostring(ctx.Type or ctx) end)
            if (typeName:find("Character") or typeName:find("CC")) and not seenContexts[typeName] then
                seenContexts[typeName] = true
                local props = nil
                pcall(function() props = ctx:GetAllProperties() end)
                table.insert(found, {
                    path = path,
                    type = typeName,
                    properties = props and stringify(props) or "<no GetAllProperties>",
                })
            end
        end

        local count = 0
        pcall(function() count = node.ChildrenCount end)
        if not count or count == 0 then
            -- Fallback: probe children until nil
            count = 0
            for i = 1, 64 do
                local ok, child = pcall(function() return node:Child(i) end)
                if not ok or not child then break end
                count = i
            end
        end
        for i = 1, count do
            local ok, child = pcall(function() return node:Child(i) end)
            if ok and child then
                visit(child, path .. "/" .. i, depth + 1)
            end
        end
    end

    visit(root, "", 0)
    return found
end

--- Writes a report to Script Extender/CPF/cc_debug_<side>.json
---@param label string
---@param report table
function CCDebug.Write(label, report)
    report.side = side()
    report.label = label
    local ok, err = pcall(function()
        Ext.IO.SaveFile("CPF/cc_debug_" .. side() .. ".json", Ext.Json.Stringify(report, { Beautify = true }))
    end)
    if ok then
        CPFPrint(0, "CC debug report written to Script Extender/CPF/cc_debug_" .. side() .. ".json")
    else
        CPFWarn(0, "Could not write CC debug report: " .. tostring(err))
    end
end

--- Full dump of an entity plus the world (and UI on the client)
---@param entity EntityHandle|nil
---@param label string
---@param extra table|nil
function CCDebug.Dump(entity, label, extra)
    local report = extra or {}
    report.entity = entity and CCDebug.DescribeEntity(entity) or "<none>"
    report.world = CCDebug.DescribeWorld()
    if Ext.IsClient() then
        report.ui = CCDebug.DescribeUI()
        local dummies = {}
        local ok, list = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientCCDummyDefinition")
        if ok and list then
            for i, d in ipairs(list) do
                dummies[i] = CCDebug.DescribeEntity(d)
            end
        end
        report.dummies = dummies
    end
    CCDebug.Write(label, report)
end

Ext.RegisterConsoleCommand("cpf_ccdump", function()
    local entity = nil
    if Ext.IsClient() then
        entity = _C()
    else
        local ok, hosts = pcall(function() return Osi.DB_Players:Get(nil) end)
        if ok and hosts and hosts[1] then entity = Ext.Entity.Get(hosts[1][1]) end
        if not entity then
            local list = Ext.Entity.GetAllEntitiesWithComponent("CCCharacterDefinition") or {}
            entity = list[1]
        end
    end
    CCDebug.Dump(entity, "console")
end)

return CCDebug
