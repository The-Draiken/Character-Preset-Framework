---Server-side handler for RequestDreamGuardians

---@class DreamGuardianData
---@field AvatarName string
---@field Data PresetData

---@param templateId Guid
---@return ResourceCompanionPreset|nil
local function findCompanionPreset(templateId)
    for _, guid in ipairs(Ext.StaticData.GetAll("CompanionPreset")) do
        local companionPreset = Ext.StaticData.Get(guid, "CompanionPreset")
        if companionPreset.RootTemplate == templateId then
            return companionPreset
        end
    end
end

---The guardian has no CharacterCreationStats, so race and body come from its CompanionPreset
---@param guardianUuid Guid
---@return PresetData|nil
local function extractGuardianData(guardianUuid)
    local guardian = Ext.Entity.Get(guardianUuid)
    local data = CCA.ExtractFromEntity(guardian)
    if not data or not data.CCAppearance then
        CPFWarn(1, "Dream Guardian " .. guardianUuid .. " has no CharacterCreationAppearance")
        return nil
    end

    local companionPreset = findCompanionPreset(guardian.ServerCharacter.Template.Id)
    if not companionPreset then
        CPFWarn(1, "Dream Guardian " .. guardianUuid .. " has no matching CompanionPreset")
        return nil
    end

    data.CCStats = {
        BodyShape = companionPreset.BodyShape,
        BodyType = companionPreset.BodyType,
        Race = companionPreset.RaceUuid,
        SubRace = companionPreset.SubRaceUuid
    }
    return data
end

---One user can reserve several avatars, for example a host who took over a guest's avatar
---@param request { CharacterUuid?: string, InCC?: boolean } Request from the client
---@param userId integer Packed network user id: (peerId << 16) | userIndex
---@return { Guardians: DreamGuardianData[] } response
local function handleDreamGuardians(request, userId)
    -- Osiris user id of this peer
    local osirisUserId = (userId & 0xffff0000) | 1

    local guardians = {}
    for _, row in ipairs(Osi.DB_GLO_DaisyDreams_Relationships:Get(nil, nil)) do
        local avatar, guardian = row[1], row[2]
        if Osi.GetReservedUserID(avatar) == osirisUserId then
            -- Database values have a template prefix
            local avatarEntity = Ext.Entity.Get(VCFormat:Guid(avatar))
            local data = avatarEntity and extractGuardianData(VCFormat:Guid(guardian))
            if data then
                local displayName = avatarEntity.DisplayName
                table.insert(guardians, {
                    AvatarName = Ext.Loca.GetTranslatedString(displayName.NameKey.Handle.Handle),
                    GuardianUuid = VCFormat:Guid(guardian),
                    Data = data
                })
            end
        end
    end

    -- Character Creation: the guardian is only a definition until the game starts
    if #guardians == 0 and request and request.InCC and request.CharacterUuid then
        local player = Ext.Entity.Get(request.CharacterUuid)
        if player and CCApplier.IsInCC(player) then
            local guardianEntity = CCApplier.FindGuardianEntity(player)
            if guardianEntity then
                local avatarName = ""
                pcall(function()
                    avatarName = Ext.Loca.GetTranslatedString(player.DisplayName.NameKey.Handle.Handle)
                end)
                table.insert(guardians, {
                    AvatarName = avatarName,
                    InCC = true,
                    Data = CCApplier.ExtractGuardianData(guardianEntity),
                })
            end
        end
    end

    return { Guardians = guardians }
end

NetChannels.RequestDreamGuardians:SetRequestHandler(handleDreamGuardians)
