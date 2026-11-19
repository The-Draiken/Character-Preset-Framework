PresetApplication = {}

local function appendAll(target, values)
    if not values then
        return
    end

    for _, value in ipairs(values) do
        table.insert(target, value)
    end
end

local function collectAppliedAttributes(preset)
    local appliedAttributes = {}

    if preset and preset.Data and preset.Data.CCAppearance then
        for key, _ in pairs(preset.Data.CCAppearance) do
            table.insert(appliedAttributes, key)
        end
    end

    return appliedAttributes
end

local function getCharacterName(entity)
    if not entity or not entity.DisplayName or not entity.DisplayName.NameKey then
        return "Unknown"
    end

    return Ext.Loca.GetTranslatedString(entity.DisplayName.NameKey.Handle.Handle)
end

local function buildError(errorCode, errorMessage, extra)
    local result = {
        Success = false,
        ErrorCode = errorCode,
        Error = errorMessage,
        Warnings = {},
        AppliedAttributes = {},
        MissingMods = {},
    }

    if extra then
        for key, value in pairs(extra) do
            result[key] = value
        end
    end

    return result
end

---@param entityUuid string
---@param preset Preset|table
---@param options? {checkAvailability?: boolean, collectWarnings?: boolean, autoEnterMirror?: boolean, logSuccess?: boolean, applyStats?: boolean, target?: "Character"|"DreamGuardian", inCC?: boolean}
---@return table result
function PresetApplication.Apply(entityUuid, preset, options)
    options = options or {}

    if not Ext.IsServer() then
        return buildError("INVALID_CONTEXT", "ApplyPreset must be called from server context")
    end

    if type(entityUuid) ~= "string" then
        return buildError("INVALID_ENTITY_UUID", "Invalid parameter: entityUuid must be a string")
    end

    local valid, validationErr = Preset.Validate(preset)
    if not valid then
        return buildError("INVALID_PRESET", "Invalid preset: " .. tostring(validationErr), {
            ValidationError = validationErr,
        })
    end

    local warnings = {}
    if options.collectWarnings then
        appendAll(warnings, Preset.GetWarnings(preset))
    end

    local missingMods = {}
    if options.checkAvailability then
        missingMods = PresetCompatibility.CheckMods(preset)
        if #missingMods > 0 then
            return buildError(
                "MISSING_DEPENDENCIES",
                "Preset has missing dependencies: " .. table.concat(missingMods, ", "),
                {
                    Warnings = warnings,
                    MissingMods = missingMods,
                }
            )
        end
    end

    local entity = Ext.Entity.Get(entityUuid)
    if not entity then
        return buildError("ENTITY_NOT_FOUND", "Entity not found: " .. entityUuid, {
            Warnings = warnings,
        })
    end

    local target = options.target or "Character"
    local charName = getCharacterName(entity)
    local appliedAttributes = collectAppliedAttributes(preset)

    -- Character Creation: write to the CC definition (player or Dream Guardian) instead of the live components
    local ccPlayer = options.inCC and CCApplier.FindCCEntity(entity) or nil
    if options.inCC and not ccPlayer then
        -- Report instead of silently falling back to the in-game path
        if CCDebug then
            CCDebug.Dump(entity, "server CC apply: no CCCharacterDefinition found", { target = target })
        end
        return buildError("CC_APPLY_FAILED", "Character Creation data not found for this character", {
            Warnings = warnings,
        })
    end

    if ccPlayer then
        local ccEntity = ccPlayer
        if target == CCApplier.TARGET_GUARDIAN then
            ccEntity = CCApplier.FindGuardianEntity(ccPlayer)
            if not ccEntity then
                if CCDebug then CCDebug.Dump(entity, "server CC apply: guardian not found") end
                return buildError("ENTITY_NOT_FOUND", "Dream Guardian definition not found in Character Creation", {
                    Warnings = warnings,
                })
            end
        end

        local ok, err = CCApplier.Apply(ccEntity, target, preset.Data, options.applyStats)
        if CCDebug then
            CCDebug.Dump(ccEntity, "server CC apply (" .. target .. ")", {
                success = ok, error = err, log = CCApplier.LastLog,
            })
        end
        if not ok then
            return buildError("CC_APPLY_FAILED", tostring(err), { Warnings = warnings })
        end

        -- Let the client update its own copy of the definition and the CC dummy
        NetChannels.ApplyCCAToClientDummy:Broadcast({
            PresetData = preset.Data,
            ApplyStats = options.applyStats or false,
            Target = target,
            InCC = true,
            EntityUuid = ccEntity.Uuid and ccEntity.Uuid.EntityUuid or nil,
            OwnerUuid = entityUuid,
        })

        if options.logSuccess then
            CPFPrint(1, string.format("Applied preset '%s' by %s in Character Creation (%s)",
                preset.Name, preset.Author, target))
        end

        return {
            Success = true,
            Warnings = warnings,
            AppliedAttributes = appliedAttributes,
            MissingMods = missingMods,
        }
    end

    CCA.ApplyPresetData(entity, preset.Data, options.applyStats, target)

    if options.applyStats and entity.CharacterCreationStats then
        CCStatsApplier.ApplyToEntity(entity, preset.Data.CCStats)
    end

    entity:Replicate("CharacterCreationAppearance")
    if entity.CharacterCreationStats then
        entity:Replicate("CharacterCreationStats")
    end

    if options.logSuccess then
        CPFPrint(1, string.format("Applied preset '%s' by %s to character %s",
            preset.Name,
            preset.Author,
            charName))
    end

    -- The mirror only edits the player character, never the Dream Guardian
    if options.autoEnterMirror and target ~= "DreamGuardian" then
        CPFPrint(1, "Auto-entering mirror for " .. charName)
        Osi.StartChangeAppearance(entityUuid)
    end

    return {
        Success = true,
        Error = nil,
        ErrorCode = nil,
        Warnings = warnings,
        AppliedAttributes = appliedAttributes,
        MissingMods = missingMods,
    }
end

return PresetApplication
