-- Background commands: drop a text file "<name>.cmd" (key=value lines) into ~/LRCDF/plugin_work/cmd
-- and the plugin runs it on the selected photos, then writes "<name>.done" (first line ok / error).
--   action=tone     style=a strength=1.0 group=time
--   action=export   dir=/path size=1024 tag=before      -> <dir>/<photo id>_<tag>.jpg
--   action=save     file=/path/saved.lua                 -> current develop settings of the photos
--   action=restore  file=/path/saved.lua
--   action=apply    file=/path/settings.lua              -> { ["photo id"] = { develop settings } }
--   action=info                                          -> lists the photos in the .done file
--   action=beauty   [smooth=0.6 …] [import=0] [dest=/path] -> retouched TIFFs, stacked on the originals
-- ids=12,34 picks photos by id instead of the current selection.
local LrApplication = import 'LrApplication'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'

-- Read a plug-in file from disk every time, so edits take effect without reloading the plug-in.
local function fresh(name)
    local path = LrPathUtils.child(_PLUGIN.path, name .. '.lua')
    return assert(loadstring(LrFileUtils.readFile(path), name))()
end

local config = fresh 'Config'

-- commands come from scripts (work folder) and from the desktop app (its own folder)
local directories = { LrPathUtils.child(config.work, 'cmd'), LrPathUtils.child(config.appData, 'cmd') }

local function handle(path)
    local text = LrFileUtils.readFile(path)
    LrFileUtils.delete(path)
    local args = {}
    for key, value in text:gmatch('([%w_]+)=([^\r\n]*)') do args[key] = value end
    local ok, result = LrTasks.pcall(function() return fresh('Actions')(args) end)
    local done = assert(io.open(LrPathUtils.replaceExtension(path, 'done'), 'w'))
    done:write(ok and 'ok' or 'error', '\n', tostring(result), '\n')
    done:close()
end

-- Reloading the plug-in starts a new listener; the old one sees the changed number and stops.
local prefs = LrPrefs.prefsForPlugin()
local generation = (prefs.serverGeneration or 0) + 1
prefs.serverGeneration = generation

LrTasks.startAsyncTask(function()
    for _, directory in ipairs(directories) do LrFileUtils.createAllDirectories(directory) end
    local quiet = 0      -- polls since the last request: look often while the app is sending one after another
    while prefs.serverGeneration == generation do
        quiet = quiet + 1
        for _, directory in ipairs(directories) do
            for path in LrFileUtils.files(directory) do
                if LrPathUtils.extension(path) == 'cmd' then handle(path) quiet = 0 end
            end
            local file = io.open(LrPathUtils.child(directory, 'alive'), 'w')
            if file then file:write(os.time(), '\n') file:close() end
        end
        LrTasks.sleep(quiet < 60 and 0.05 or 0.3)
    end
end)
