-- One-click beautification: export full-size TIFFs, retouch them with the local model, and add the
-- results to the catalog stacked on top of the originals. The originals are never changed.
local LrApplication = import 'LrApplication'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'
local LrDate = import 'LrDate'

-- Read a plug-in file from disk every time, so edits take effect without reloading the plug-in.
local function fresh(name)
    local path = LrPathUtils.child(_PLUGIN.path, name .. '.lua')
    return assert(loadstring(LrFileUtils.readFile(path), name))()
end

local messages = fresh 'Messages'
local config = fresh 'Config'
local Tone = fresh 'Tone'
local Beauty = {}

-- Per-person retouching for the command line: file = people.json of the shoot (scripts/cull.py), choices = "3:off,5:refined".
function Beauty.who(file, choices, quote)
    local levels = {}       -- always told: the automatic level needs them too
    for name, v in pairs(config.beautyLevels) do
        levels[#levels + 1] = name .. '=' .. table.concat({ v.blemish / 100, v.smooth / 100, v.undereye / 100, v.eyes / 100, v.teeth / 100 }, ',')
    end
    local told = ' --levels ' .. table.concat(levels, '/')
    if not file or not LrFileUtils.exists(file) then return told end       -- without choices it still tells who is a man
    if choices and not choices:match('^[%d%a:,]+$') then choices = nil end
    return ' --people ' .. (quote or Tone.shellQuote)(file) .. (choices and choices ~= '' and ' --choices ' .. choices or '') .. told
end

-- The preview process that stays loaded (scripts/preview_beauty.py --serve): starting Python and loading the models
-- takes longer than a preview. Beauty.warm() starts it unless it is there; Beauty.preview(arguments) hands it one
-- request and waits. Returns true when the pictures were made; false = make them the slow way.
-- The process writes its file `alive` every second, also while it loads and while it works. A file older than GONE
-- seconds means the process is not there any more (it was ended, or it crashed): a request is then not left waiting.
local GONE = 15        -- a starting Python needs a moment before its first sign of life; Beauty.warm writes one for it

local function sinceAlive()
    local attributes = LrFileUtils.fileAttributes(LrPathUtils.child(config.previewServer, 'alive'))
    return attributes and attributes.fileModificationDate and LrDate.currentTime() - attributes.fileModificationDate
end

local function serverAlive()
    local age = sinceAlive()
    return age ~= nil and age < GONE
end

function Beauty.warm()
    if serverAlive() then return end
    LrFileUtils.createAllDirectories(config.previewServer)
    local mark = io.open(LrPathUtils.child(config.previewServer, 'alive'), 'w')     -- at once: loading takes seconds, and a second call must not start another
    if mark then mark:close() end
    local q = Tone.shellQuote
    local command = Tone.python(config.previewBeauty) .. ' --serve ' .. q(config.previewServer) ..
        ' > ' .. q(LrPathUtils.child(config.previewServer, 'server.log')) .. ' 2>&1'
    if WIN_ENV then
        Tone.execute('start "" /b ' .. command)
    else
        LrTasks.execute('nohup ' .. command .. ' &')
    end
end

function Beauty.preview(arguments)
    local function ask()            -- true: made; false: no answer in two minutes; nil: the process is gone
        Beauty.warm()
        local name = LrPathUtils.child(config.previewServer, 'r' .. os.time() .. math.random(100000, 999999))
        local file = io.open(name .. '.tmp', 'w')
        if not file then return false end
        file:write(arguments); file:close()
        LrFileUtils.move(name .. '.tmp', name .. '.req')
        local answer = false
        for step = 1, 1200 do                               -- two minutes: the first request also waits for the models
            if LrFileUtils.exists(name .. '.done') then
                LrFileUtils.delete(name .. '.done')
                return true
            end
            if step % 10 == 0 and not serverAlive() then answer = nil break end
            LrTasks.sleep(0.1)
        end
        if LrFileUtils.exists(name .. '.req') then LrFileUtils.delete(name .. '.req') end
        return answer
    end
    local made = ask()
    if made == nil then made = ask() end        -- gone: a new process is started and asked once more
    return made == true
end

-- The full-size run loads the models itself: the preview process makes room first.
function Beauty.rest()
    if not LrFileUtils.exists(LrPathUtils.child(config.previewServer, 'alive')) then return end
    local file = io.open(LrPathUtils.child(config.previewServer, 'quit'), 'w')
    if file then file:close() end
end

-- options: auto = true (every face gets the strongest level that is not overdone on it; the strengths are the fallback);
-- people + peoplefile (see Beauty.who); blemish, smooth, undereye, eyes, teeth, slim (0..1.5; slim is off at 0); bits (8 or 16, default config.beautyBits);
-- import (default true); dest (folder, default: next to the original)
-- Returns done, failed, logPath, { [original id] = id of the new photo }; or nil, message.
function Beauty.apply(photos, options, progress)
    options = options or {}
    progress = progress or {}
    local message = progress.localized and LOC or messages.source
    local caption = progress.caption or function() end
    local catalog = LrApplication.activeCatalog()
    local session = LrPathUtils.child(config.work, 'beauty-' .. os.date('%Y%m%d-%H%M%S'))
    caption(message("$$$/LRCDF/Progress/ExportFullSize=正在导出全尺寸图像…"))
    -- 16-bit results are made in ProPhoto RGB (nothing of the photo's colour is cut off); 8-bit ones in sRGB
    local wide = (options.bits or config.beautyBits) == 16
    local rendered = Tone.render(photos, session, nil, function(done)
        if progress.portion then progress.portion(done * 0.5, #photos) end
        if progress.canceled and progress.canceled() then return false end
    end, wide)
    if not rendered then return nil, message("$$$/LRCDF/Errors/Cancelled=已取消") end

    local job = LrPathUtils.child(session, 'job.tsv')
    local file = assert(io.open(job, 'w'))
    local outputs = {}
    for _, photo in ipairs(photos) do
        local input = rendered[photo.localIdentifier]
        if input then
            local original = photo:getRawMetadata('path')
            local folder = options.dest or LrPathUtils.parent(original)
            LrFileUtils.createAllDirectories(folder)
            local name = LrPathUtils.removeExtension(LrPathUtils.leafName(original)) .. '-LRCDF.tif'
            local output = LrFileUtils.chooseUniqueFileName(LrPathUtils.child(folder, name))
            file:write(input, '\t', output, '\n')
            outputs[#outputs + 1] = { photo = photo, input = input, output = output }
        end
    end
    file:close()

    caption(message("$$$/LRCDF/Progress/Beauty=正在美颜…"))
    Beauty.rest()
    local q = Tone.shellQuote
    local log = LrPathUtils.child(session, 'beautify.log')
    local command = Tone.python(config.beautify) .. ' --job ' .. q(job)
    for _, key in ipairs { 'blemish', 'smooth', 'undereye', 'eyes', 'teeth', 'slim', 'bigeyes', 'chest', 'waist', 'legs', 'light' } do
        command = command .. ' --' .. key .. ' ' .. tostring(options[key] or config.beauty[key] / 100)
    end
    command = command .. Beauty.who(options.peoplefile, options.people)
    if options.auto then command = command .. ' --auto 1' end
    command = command .. ' --bits ' .. ((options.bits or config.beautyBits) == 16 and 16 or 8)
    local status = Tone.execute(command .. ' > ' .. q(log) .. ' 2>&1')

    caption(message("$$$/LRCDF/Progress/ImportResults=正在导入成片…"))
    local done, failed, created = 0, 0, {}
    catalog:withWriteAccessDo(LOC("$$$/LRCDF/Title/Beauty=LRCDF 一键美颜"), function()
        for _, item in ipairs(outputs) do
            if LrFileUtils.exists(item.output) then
                if options.import ~= false then item.added = catalog:addPhoto(item.output, item.photo, 'above') end
                done = done + 1
            else
                failed = failed + 1
            end
        end
    end, { timeout = 60 })
    for _, item in ipairs(outputs) do
        LrFileUtils.delete(item.input)
        if item.added then created[item.photo.localIdentifier] = item.added.localIdentifier end
    end
    if done == 0 and status ~= 0 then return nil, message("$$$/LRCDF/Errors/BeautyFailed=美颜运行失败。日志：^1", log) end
    return done, failed, log, created
end

return Beauty
