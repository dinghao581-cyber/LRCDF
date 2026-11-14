-- Shared work: render previews, ask the model for develop settings, write them to the photos.
local LrApplication = import 'LrApplication'
local LrExportSession = import 'LrExportSession'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

-- Read a plug-in file from disk every time, so edits take effect without reloading the plug-in.
local function fresh(name)
    local path = LrPathUtils.child(_PLUGIN.path, name .. '.lua')
    return assert(loadstring(LrFileUtils.readFile(path), name))()
end

local config = fresh 'Config'
local neutral = fresh 'Neutral'
local Tone = {}

function Tone.shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- Export JPEGs of the photos as they currently look. Returns { [localIdentifier] = path }.
-- size = nil exports full-size 16-bit TIFFs (for pixel work) instead of small JPEG previews.
-- wide = true: those TIFFs are in ProPhoto RGB instead of sRGB (nothing of the photo's colour is cut off).
function Tone.render(photos, directory, size, onRendered, wide)
    LrFileUtils.createAllDirectories(directory)
    local full = size == nil
    local session = LrExportSession {
        photosToExport = photos,
        exportSettings = {
            LR_format = full and 'TIFF' or 'JPEG',
            LR_export_bitDepth = 16,
            LR_tiff_compressionMethod = 'compressionMethod_None',
            LR_jpeg_quality = 0.9,
            LR_export_colorSpace = (full and wide) and 'ProPhotoRGB' or 'sRGB',
            LR_size_doConstrain = not full,
            LR_size_resizeType = 'longEdge',
            LR_size_maxHeight = size,
            LR_size_maxWidth = size,
            LR_size_units = 'pixels',
            LR_size_doNotEnlarge = true,
            LR_export_destinationType = 'specificFolder',
            LR_export_destinationPathPrefix = directory,
            LR_export_useSubfolder = false,
            LR_collisionHandling = 'rename',
            -- previews keep their metadata: the develop settings embedded in them are the only reliable place to read
            -- the as-shot white balance (getDevelopSettings gives nil or -999999 for photos never opened in Develop)
            LR_minimizeEmbeddedMetadata = full,
            LR_embeddedMetadataOption = 'all',
            LR_removeLocationMetadata = true,
            LR_outputSharpeningOn = false,
            LR_reimportExportedPhoto = false,
            LR_includeVideoFiles = false,
        },
    }
    local rendered = {}
    local done = 0
    for _, rendition in session:renditions() do
        local ok, path = rendition:waitForRender()
        done = done + 1
        if ok then rendered[rendition.photo.localIdentifier] = path end
        if onRendered and onRendered(done) == false then return nil end
    end
    return rendered
end

-- Small nudges on top of a look, in steps of -2..2: { bright, warm, rich }. Changes `settings` and returns it.
function Tone.tweak(settings, tweak)
    if not tweak or not settings.Temperature then return settings end
    local function add(name, amount, lo, hi)
        settings[name] = math.max(lo, math.min(hi, (settings[name] or 0) + amount))
    end
    local b, w, r = tweak[1] or 0, tweak[2] or 0, tweak[3] or 0
    add('Exposure2012', 0.14 * b, -5, 5)
    add('LuminanceAdjustmentOrange', 4 * b, -100, 100)
    settings.Temperature = math.floor(math.max(2000, math.min(50000, settings.Temperature * (1 + 0.04 * w))) + 0.5)
    add('Vibrance', 8 * r, -100, 100)
    add('Saturation', 3 * r, -100, 100)
    add('Contrast2012', 5 * r, -100, 100)
    return settings
end

-- Put photos back to settings read earlier with getDevelopSettings ({ [photo] = settings }).
-- "As Shot" needs care: applyDevelopSettings would keep the current temperature under an "As Shot" label.
function Tone.restore(before, label)
    label = label or 'LRCDF 还原'
    LrApplication.activeCatalog():withWriteAccessDo(label, function()
        local asShot = LrApplication.addDevelopPresetForPlugin(_PLUGIN, 'LRCDF 原始白平衡', { WhiteBalance = 'As Shot' })
        for photo, saved in pairs(before) do
            local settings = {}
            for k, v in pairs(saved) do settings[k] = v end
            if settings.WhiteBalance == 'As Shot' then
                photo:applyDevelopSettings({ WhiteBalance = 'Custom', Temperature = 5000, Tint = 0 }, label)
                photo:applyDevelopPreset(asShot, _PLUGIN)
                settings.WhiteBalance, settings.Temperature, settings.Tint = nil, nil, nil
            end
            photo:applyDevelopSettings(settings, label)
        end
    end, { timeout = 30 })
end

-- The model was trained on unedited photos, so every photo is judged from its neutral rendering.
function Tone.neutralise(photos)
    LrApplication.activeCatalog():withWriteAccessDo('LRCDF 一键调色', function()
        -- "As Shot" only really resets white balance when it comes from a preset; applyDevelopSettings
        -- changes the label but keeps the old temperature and the old rendering.
        local preset = LrApplication.addDevelopPresetForPlugin(_PLUGIN, 'LRCDF 原片状态', neutral)
        for _, photo in ipairs(photos) do
            -- a photo that only carries the "As Shot" label over an old custom temperature would not be reset by the
            -- preset either, so make the white balance custom first
            photo:applyDevelopSettings({ WhiteBalance = 'Custom', Temperature = 5000, Tint = 0 }, 'LRCDF 一键调色')
            photo:applyDevelopPreset(preset, _PLUGIN)
        end
    end, { timeout = 30 })
    for _ = 1, 40 do  -- the write lands a moment later
        local ready = true
        for _, photo in ipairs(photos) do
            local s = photo:getDevelopSettings()
            if s.WhiteBalance ~= 'As Shot' or not s.Temperature or s.Exposure2012 ~= 0 then ready = false end
        end
        if ready then break end
        LrTasks.sleep(0.25)
    end
    LrTasks.sleep(config.settleSeconds)  -- let Lightroom re-render before the previews are exported
end

-- Returns applied, failed, logPath; or nil, message.
-- progress is optional: { caption = function(text), portion = function(done, total), canceled = function() }
-- reference is optional: one of the photos, already edited to taste. The others then take its style sliders and
-- white balance, with exposure judged per photo; the reference keeps its settings.
-- style 'all' writes nothing: it returns the model's settings for every style, { style = { id = settings } }, with the
-- photos left in their neutral state, the earlier settings as second result and the result file as third (style previews).
-- options is optional: tweak = { bright, warm, rich } (-2..2 each, see Tone.tweak);
--   learn = { key, name }: nothing is written to the photos; the edits of ALL the photos given (the reference first) are
--   stored, averaged, as the user's style `key`.
function Tone.apply(photos, style, strength, group, progress, reference, options)
    options = options or {}
    progress = progress or {}
    local caption = progress.caption or function() end
    if not LrFileUtils.exists(config.checkpoint) then
        return nil, '找不到模型文件：' .. config.checkpoint .. '\n请确认外置 SSD 已连接。'
    end
    local catalog = LrApplication.activeCatalog()
    local session = LrPathUtils.child(config.work, os.date('%Y%m%d-%H%M%S'))
    -- remember the current look and put it back if anything fails
    local before = {}
    for _, photo in ipairs(photos) do before[photo] = photo:getDevelopSettings() end
    local function restore() Tone.restore(before) end
    Tone.neutralise(photos)
    caption('正在生成预览…')
    local rendered = Tone.render(photos, session, 512, function(done)
        if progress.portion then progress.portion(done * 0.6, #photos) end
        if progress.canceled and progress.canceled() then return false end
    end)
    if not rendered then restore() return nil, '已取消' end

    local job = LrPathUtils.child(session, 'job.tsv')
    local file = assert(io.open(job, 'w'))
    local byId = {}
    for _, photo in ipairs(photos) do
        local id = tostring(photo.localIdentifier)
        local path = rendered[photo.localIdentifier]
        if path then
            local settings = photo:getDevelopSettings()
            local asShot = settings.WhiteBalance == 'As Shot' and settings.Temperature
            local when = photo:getRawMetadata('dateTimeOriginal') or photo:getRawMetadata('dateTime') or 0
            file:write(id, '\t', path, '\t', settings.Temperature or 0, '\t', settings.Tint or 0,
                       '\t', asShot and '1' or '0', '\t', string.format('%.0f', when), '\n')
            byId[id] = photo
        end
    end
    file:close()

    local extra = ''
    if reference then
        local path = LrPathUtils.child(session, 'reference.tsv')
        local out = assert(io.open(path, 'w'))
        for name, value in pairs(before[reference]) do
            if type(value) == 'number' then
                out:write(name, '\t', tostring(value), '\n')
            elseif type(value) == 'table' and type(value[1]) == 'number' then
                out:write(name, '\t', table.concat(value, ','), '\n')
            end
        end
        out:close()
        extra = ' --reference ' .. tostring(reference.localIdentifier) .. ' --refsettings ' .. Tone.shellQuote(path)
    end
    extra = extra .. ' --mystyles ' .. Tone.shellQuote(config.myStyles)
    if options.learn then
        extra = extra .. ' --learn ' .. Tone.shellQuote(options.learn.key) .. ' --name ' .. Tone.shellQuote(options.learn.name)
        local more = {}         -- the other photos are examples too: their edits, as they were before this call
        for _, photo in ipairs(photos) do
            if photo ~= reference then
                local out = assert(io.open(LrPathUtils.child(session, 'reference_' .. photo.localIdentifier .. '.tsv'), 'w'))
                for name, value in pairs(before[photo]) do
                    if type(value) == 'number' then
                        out:write(name, '\t', tostring(value), '\n')
                    elseif type(value) == 'table' and type(value[1]) == 'number' then
                        out:write(name, '\t', table.concat(value, ','), '\n')
                    end
                end
                out:close()
                more[#more + 1] = tostring(photo.localIdentifier)
            end
        end
        if #more > 0 then extra = extra .. ' --examples ' .. table.concat(more, ',') end
    end

    caption('模型正在分析…')
    local q = Tone.shellQuote
    local out = LrPathUtils.child(session, 'result.lua')
    local log = LrPathUtils.child(session, 'predict.log')
    local status = LrTasks.execute(q(config.python) .. ' ' .. q(config.predict) ..
        ' --ckpt ' .. q(config.checkpoint) .. ' --job ' .. q(job) .. ' --out ' .. q(out) ..
        ' --style ' .. q(style) .. ' --strength ' .. tostring(strength) .. ' --group ' .. q(group) ..
        ' --gap ' .. tostring(config.gapMinutes) .. extra .. ' > ' .. q(log) .. ' 2>&1')
    if status ~= 0 or not LrFileUtils.exists(out) then
        restore()
        return nil, '模型运行失败。日志：' .. log
    end
    local results = assert(loadstring(LrFileUtils.readFile(out)))()
    if style == 'all' then
        for _, path in pairs(rendered) do LrFileUtils.delete(path) end
        return results, before, out
    end
    if options.learn then
        for _, path in pairs(rendered) do LrFileUtils.delete(path) end
        restore()
        return 0, 0, log
    end

    caption('正在写入修改设置…')
    local applied, failed = 0, 0
    catalog:withWriteAccessDo('LRCDF 一键调色', function()
        for id, settings in pairs(results) do
            local photo = byId[id]
            if photo == reference then photo = nil end
            if photo and not settings.error then
                photo:applyDevelopSettings(Tone.tweak(settings, options.tweak), 'LRCDF 一键调色')
                applied = applied + 1
            else
                if photo then photo:applyDevelopSettings(before[photo], 'LRCDF 还原') end
                failed = failed + 1
            end
        end
    end, { timeout = 30 })
    if reference then Tone.restore({ [reference] = before[reference] }) end
    for _, path in pairs(rendered) do LrFileUtils.delete(path) end
    return applied, failed, log
end

return Tone
