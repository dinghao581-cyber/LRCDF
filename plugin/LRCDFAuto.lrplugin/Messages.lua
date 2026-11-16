-- The bridge keeps its original Chinese payload. Only Lightroom's own dialogs call LOC.
local Messages = {}

function Messages.source(key, ...)
    local text = key:match('=(.*)$')
    local values = { ... }
    return (text:gsub('%^(%d+)', function(index) return tostring(values[tonumber(index)]) end))
end

return Messages
