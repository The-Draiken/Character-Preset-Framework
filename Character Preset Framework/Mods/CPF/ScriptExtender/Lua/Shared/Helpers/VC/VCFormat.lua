VCFormat = {}

local GUID_LENGTH = 36

--- Returns the last 36 characters of a string, which is the length of a GUID
--- @param str string
--- @return string
function VCFormat:Guid(str)
    return str:sub(-GUID_LENGTH)
end

function VCFormat:IsUUID(uuid)
    if type(uuid) ~= "string" then
        return false
    end

    return uuid:match("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$") ~= nil
end

return VCFormat
