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

local messages = fresh 'Messages'
local config = fresh 'Config'
local neutral = fresh 'Neutral'
local Tone = {}

function Tone.posixQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function Tone.shellQuote(value)
    if WIN_ENV then
        local argument = tostring(value):gsub('(\\*)"', '%1%1\\"'):gsub('(\\+)$', '%1%1')
        return '"' .. argument .. '"'
    end
    return Tone.posixQuote(value)
end

function Tone.python(script)
    local q = Tone.shellQuote
    return q(config.python) .. (WIN_ENV and ' -s -X utf8 ' or ' ') .. q(script)
end

function Tone.execute(command)
    if WIN_ENV and command:sub(1, 1) == '"' then
        command = '"' .. command .. '"'
    end
    return LrTasks.execute(command)
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

-- Small nudges on top of a look, each anywhere from -2 to 2 (fractions allowed): { bright, warm, rich }. Changes `settings` and returns it.
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
    -- the colour wheels: tint = green to magenta; shadow / high = { hue, amount } replace the look's split toning for
    -- that range (amount 0 takes the look's colour away), at half the amount shown (the SplitToning keys are the ones Lightroom takes and gives back; it has
    -- no ColorGradeShadow keys - written and read back in Lightroom 16)
    if tweak.tint and settings.Tint then add('Tint', 10 * tweak.tint, -150, 150) end
    if tweak.shadow then
        settings.SplitToningShadowHue, settings.SplitToningShadowSaturation = tweak.shadow[1], math.floor(tweak.shadow[2] / 2 + 0.5)
    end
    if tweak.high then
        settings.SplitToningHighlightHue, settings.SplitToningHighlightSaturation = tweak.high[1], math.floor(tweak.high[2] / 2 + 0.5)
    end
    return settings
end

-- Skin corrections for the skin only. The model sets orange and yellow saturation and luminance for every photo, for
-- the sake of the skin - but those sliders go by colour, so wood, warm clothes and warm light were thinned and lifted
-- with it (docs/colorchart/REPORT.md). predict.py now says where the skin is (settings._skin: brush strokes from
-- lrcdf/skinmask.py, in the frame of the preview). Tone.forPhoto turns the four sliders into one local correction on a
-- brush mask over the skin; a brush mask needs no computing by Lightroom (an AI mask would, and a plug-in cannot
-- start that). A photo without `_skin` (no skin found, reference mode) keeps the sliders as they are.
-- The correction's name carries the four slider values, so that Tone.global can give them back when the photo's
-- edit is read (reference photo, own looks).
local SKIN = 'LRCDF skin'
local skinSliders = { 'SaturationAdjustmentOrange', 'LuminanceAdjustmentOrange', 'SaturationAdjustmentYellow', 'LuminanceAdjustmentYellow' }
-- local saturation / local exposure per slider unit, measured on the skin of 8 portraits in Lightroom
-- (docs/colorchart/tools/calibrate.py): orange saturation -15 = -12.3 % chroma (11.0-14.0), local saturation -0.15 = -15.2 %;
-- orange luminance +32 = +3.6 L (2.4-4.9: more on light, saturated skin), local exposure +0.05 = +3.5 L (3.3-3.8);
-- yellow hardly reaches skin (-10 saturation = -0.5 %, +8 luminance = +0.06 L)
local SKIN_K = { sat = { 0.0095, 0.0005 }, exposure = { 0.0019, 0.0001 } }

local function ours(group)
    return type(group) == 'table' and type(group.CorrectionName) == 'string' and group.CorrectionName:sub(1, #SKIN) == SKIN
end

-- The strokes (0..1 of the cropped preview) as brush masks in the frame Lightroom keeps them in: the uncropped
-- photo as the camera stored it, before it is turned upright. The crop is a rectangle in that same frame, from
-- (CropLeft, CropTop) to (CropRight, CropBottom), turned by CropAngle. width, height: the photo as shown.
-- Checked in Lightroom 16 with and without crop and angle for 'AB' and 'BC'; a mirrored photo gets no mask.
local turned = {
    AB = function(u, v) return u, v end,
    BC = function(u, v) return v, 1 - u end,        -- shown turned a quarter clockwise
    DA = function(u, v) return 1 - v, u end,        -- a quarter anticlockwise
    CD = function(u, v) return 1 - u, 1 - v end,    -- upside down
}

local function brushes(skin, now, width, height)
    local frame = turned[now.orientation or 'AB']
    if not frame then return nil end
    if now.orientation == 'BC' or now.orientation == 'DA' then width, height = height, width end
    local left, top = (now.CropLeft or 0) * width, (now.CropTop or 0) * height
    local dx, dy = (now.CropRight or 1) * width - left, (now.CropBottom or 1) * height - top
    local angle = math.rad(now.CropAngle or 0)
    local c, s = math.cos(angle), math.sin(angle)
    local w, h = dx * c + dy * s, -dx * s + dy * c          -- the crop's own width and height
    if w <= 0 or h <= 0 then return nil end
    local masks = {}
    for _, brush in ipairs(skin.brushes or {}) do
        local dabs = {}
        for i = 1, #brush.dabs - 1, 2 do
            local u, v = frame(brush.dabs[i], brush.dabs[i + 1])
            u, v = u * w, v * h
            dabs[#dabs + 1] = string.format('d %.6f %.6f', (left + u * c - v * s) / width, (top + u * s + v * c) / height)
        end
        masks[#masks + 1] = { What = 'Mask/Paint', MaskActive = true, MaskName = SKIN, MaskBlendMode = 0, MaskInverted = false,
            MaskValue = 1, Radius = brush.r * math.max(w, h) / math.max(width, height), Flow = 1, CenterWeight = 0.5, Dabs = dabs }
    end
    return #masks > 0 and masks or nil
end

-- What is really written to the photo for `settings` (which stay as they are): without `_skin`, with the skin
-- sliders moved into the mask, and with the photo's other masks kept (an earlier mask of ours is replaced).
function Tone.forPhoto(photo, settings)
    local out = {}
    for name, value in pairs(settings) do if name ~= '_skin' then out[name] = value end end
    local now = photo:getDevelopSettings()
    local groups, had = {}, false
    for _, group in ipairs(now.MaskGroupBasedCorrections or {}) do
        if ours(group) then had = true else groups[#groups + 1] = group end
    end
    local size = photo:getRawMetadata('dimensions')
    local masks = settings._skin and config.skinOnly ~= false and size and size.width and size.height
        and brushes(settings._skin, now, size.width, size.height)
    if masks then
        local values, sat, exposure = {}, 0, 0
        for i, name in ipairs(skinSliders) do
            values[i] = out[name] or 0
            out[name] = 0
        end
        sat = SKIN_K.sat[1] * values[1] + SKIN_K.sat[2] * values[3]
        exposure = SKIN_K.exposure[1] * values[2] + SKIN_K.exposure[2] * values[4]
        groups[#groups + 1] = { What = 'Correction', CorrectionAmount = 1, CorrectionActive = true,
            CorrectionName = string.format('%s %g %g %g %g', SKIN, values[1], values[2], values[3], values[4]),
            LocalSaturation = math.max(-1, math.min(1, sat)), LocalExposure2012 = math.max(-1, math.min(1, exposure)),
            LocalCurveRefineSaturation = 100, CorrectionMasks = masks }
    end
    if masks or had then
        out.MaskGroupBasedCorrections = groups
        if #groups > 0 then out.EnableMaskGroupBasedCorrections = true end
    end
    return out
end

-- Settings read from a photo, with the skin sliders as the look meant them (a copy; the mask of ours is left out).
function Tone.global(saved)
    local out = {}
    for name, value in pairs(saved) do out[name] = value end
    local groups, found = {}, nil
    for _, group in ipairs(saved.MaskGroupBasedCorrections or {}) do
        if ours(group) and group.CorrectionActive ~= false then found = group else groups[#groups + 1] = group end
    end
    if found then
        local values = {}
        for number in found.CorrectionName:sub(#SKIN + 1):gmatch('%S+') do values[#values + 1] = tonumber(number) end
        for i, name in ipairs(skinSliders) do out[name] = (out[name] or 0) + (values[i] or 0) end
        out.MaskGroupBasedCorrections = groups
    end
    return out
end

-- Write `settings` to the photo (inside withWriteAccessDo). Returns what was written, for Tone.arrived.
function Tone.write(photo, settings, label)
    local out = Tone.forPhoto(photo, settings)
    photo:applyDevelopSettings(out, label)
    return out
end

-- Settings read earlier, ready to be written back: a photo that had no masks then has none afterwards.
local function asBefore(saved)
    local out = {}
    for name, value in pairs(saved) do out[name] = value end
    out.MaskGroupBasedCorrections = saved.MaskGroupBasedCorrections or {}
    return out
end
Tone.asBefore = asBefore

-- Wait until Lightroom reports `settings` on the photo (a write lands a moment later), then the pause a render needs.
function Tone.arrived(photo, settings)
    local names = { 'Temperature', 'Contrast2012', 'Exposure2012', 'LuminanceAdjustmentOrange', 'SaturationAdjustmentOrange' }
    for _ = 1, 20 do
        local now, there = photo:getDevelopSettings(), true
        for _, name in ipairs(names) do
            local want, have = settings[name], now[name]
            if type(want) == 'number' and not (type(have) == 'number' and math.abs(have - want) < 0.006) then there = false end
        end
        if there then break end
        LrTasks.sleep(0.2)
    end
    LrTasks.sleep(config.previewSettle)
end

-- Dark skin keeps its own depth (lrcdf/skinkeep.py). predict.py notes the photos concerned next to its result:
-- <base>.skin.lua = { [id] = depth 0..1 } and <base>.skin.npz (where their skin is). Returns that table ({} if none).
function Tone.skinNotes(base)
    local path = base .. '.skin.lua'
    if not LrFileUtils.exists(path) or not LrFileUtils.exists(base .. '.skin.npz') then return {} end
    local ok, notes = pcall(function() return assert(loadstring(LrFileUtils.readFile(path)))() end)
    return ok and type(notes) == 'table' and notes or {}
end

local skinKeys = { 'Exposure2012', 'LuminanceAdjustmentOrange', 'SaturationAdjustmentOrange' }

-- What to change so that the look does not lighten dark skin, measured on a render of the look (scripts/skin_keep.py).
-- items: { { id = string, path = render of the photo as it is now, settings = what that render shows } }.
-- state: a file the script keeps between its two calls for a photo (first the look itself, then the look with the
-- changes of the first call; a third call changes nothing). Returns { [id] = { name = value } }, {} when nothing
-- is to change or the script failed (the look then stays as the model gave it).
function Tone.skinChanges(items, base, state)
    if #items == 0 then return {} end
    local q = Tone.shellQuote
    local job, out = state .. '.job.tsv', state .. '.changes.lua'
    local file = io.open(job, 'w')
    if not file then return {} end
    for _, item in ipairs(items) do
        file:write(item.id, '\t', item.path)
        for _, name in ipairs(skinKeys) do file:write('\t', tostring(item.settings[name] or 0)) end
        file:write('\n')
    end
    file:close()
    if LrFileUtils.exists(out) then LrFileUtils.delete(out) end
    local script = LrPathUtils.child(LrPathUtils.parent(config.predict), 'skin_keep.py')
    local status = Tone.execute(Tone.python(script) .. ' --skin ' .. q(base) .. ' --state ' .. q(state) ..
        ' --job ' .. q(job) .. ' --out ' .. q(out) .. ' >> ' .. q(state .. '.log') .. ' 2>&1')
    if status ~= 0 or not LrFileUtils.exists(out) then return {} end
    local ok, changes = pcall(function() return assert(loadstring(LrFileUtils.readFile(out)))() end)
    return ok and type(changes) == 'table' and changes or {}
end

-- Put photos back to settings read earlier with getDevelopSettings ({ [photo] = settings }).
-- "As Shot" needs care: applyDevelopSettings would keep the current temperature under an "As Shot" label.
function Tone.restore(before, label)
    label = label or LOC("$$$/LRCDF/History/Restore=LRCDF 还原")
    LrApplication.activeCatalog():withWriteAccessDo(label, function()
        local asShot = LrApplication.addDevelopPresetForPlugin(_PLUGIN, LOC("$$$/LRCDF/History/AsShotWhiteBalance=LRCDF 原始白平衡"), { WhiteBalance = 'As Shot' })
        for photo, saved in pairs(before) do
            local settings = asBefore(saved)
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
    LrApplication.activeCatalog():withWriteAccessDo(LOC("$$$/LRCDF/Title/Tone=LRCDF 一键调色"), function()
        -- "As Shot" only really resets white balance when it comes from a preset; applyDevelopSettings
        -- changes the label but keeps the old temperature and the old rendering.
        local preset = LrApplication.addDevelopPresetForPlugin(_PLUGIN, LOC("$$$/LRCDF/History/OriginalState=LRCDF 原片状态"), neutral)
        for _, photo in ipairs(photos) do
            -- a photo that only carries the "As Shot" label over an old custom temperature would not be reset by the
            -- preset either, so make the white balance custom first
            photo:applyDevelopSettings({ WhiteBalance = 'Custom', Temperature = 5000, Tint = 0 }, LOC("$$$/LRCDF/Title/Tone=LRCDF 一键调色"))
            photo:applyDevelopPreset(preset, _PLUGIN)
            -- the neutral state has no skin mask of ours (the photo's other masks stay, as before)
            local groups, had = {}, false
            for _, group in ipairs(photo:getDevelopSettings().MaskGroupBasedCorrections or {}) do
                if ours(group) then had = true else groups[#groups + 1] = group end
            end
            if had then photo:applyDevelopSettings({ MaskGroupBasedCorrections = groups }, LOC("$$$/LRCDF/Title/Tone=LRCDF 一键调色")) end
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
-- options is optional: tweak = { bright, warm, rich, tint =, shadow =, high = } (see Tone.tweak);
--   learn = { key, name }: nothing is written to the photos; the edits of ALL the photos given (the reference first) are
--   stored, averaged, as the user's style `key`.
function Tone.apply(photos, style, strength, group, progress, reference, options)
    options = options or {}
    progress = progress or {}
    local message = progress.localized and LOC or messages.source
    local caption = progress.caption or function() end
    if not LrFileUtils.exists(config.checkpoint) then
        if WIN_ENV then
            return nil, message("$$$/LRCDF/Errors/ModelMissingWindows=找不到调色模型：^1\n请先检查 LRCDF 安装目录，确认模型文件已安装。", config.checkpoint)
        end
        return nil, message("$$$/LRCDF/Errors/ModelMissing=找不到模型文件：^1\n请确认外置 SSD 已连接。", config.checkpoint)
    end
    local catalog = LrApplication.activeCatalog()
    local session = LrPathUtils.child(config.work, os.date('%Y%m%d-%H%M%S'))
    -- remember the current look and put it back if anything fails
    local before = {}
    for _, photo in ipairs(photos) do before[photo] = photo:getDevelopSettings() end
    local function restore() Tone.restore(before) end
    Tone.neutralise(photos)
    caption(message("$$$/LRCDF/Progress/TonePreviews=正在生成预览…"))
    local rendered = Tone.render(photos, session, 512, function(done)
        if progress.portion then progress.portion(done * 0.6, #photos) end
        if progress.canceled and progress.canceled() then return false end
    end)
    if not rendered then restore() return nil, message("$$$/LRCDF/Errors/Cancelled=已取消") end

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
        for name, value in pairs(Tone.global(before[reference])) do
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
                for name, value in pairs(Tone.global(before[photo])) do
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

    caption(message("$$$/LRCDF/Progress/ModelAnalysis=模型正在分析…"))
    local q = Tone.shellQuote
    local out = LrPathUtils.child(session, 'result.lua')
    local log = LrPathUtils.child(session, 'predict.log')
    local status = Tone.execute(Tone.python(config.predict) ..
        ' --ckpt ' .. q(config.checkpoint) .. ' --job ' .. q(job) .. ' --out ' .. q(out) ..
        ' --style ' .. q(style) .. ' --strength ' .. tostring(strength) .. ' --group ' .. q(group) ..
        ' --gap ' .. tostring(config.gapMinutes) .. extra .. ' > ' .. q(log) .. ' 2>&1')
    if status ~= 0 or not LrFileUtils.exists(out) then
        restore()
        return nil, message("$$$/LRCDF/Errors/ModelFailed=模型运行失败。日志：^1", log)
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

    -- dark skin: the look is shown, measured and corrected (twice at most) before the settings are written for good
    local dark = {}
    if not reference then
        for id in pairs(Tone.skinNotes(LrPathUtils.removeExtension(out))) do
            if byId[id] and results[id] and not results[id].error then dark[#dark + 1] = byId[id] end
        end
    end
    for pass = 1, #dark > 0 and 2 or 0 do
        local label = LOC("$$$/LRCDF/Title/Tone=LRCDF 一键调色")
        local written = {}
        catalog:withWriteAccessDo(label, function()
            for _, photo in ipairs(dark) do written[photo] = Tone.write(photo, results[tostring(photo.localIdentifier)], label) end
        end, { timeout = 30 })
        for _, photo in ipairs(dark) do Tone.arrived(photo, written[photo] or results[tostring(photo.localIdentifier)]) end
        local shots = Tone.render(dark, LrPathUtils.child(session, 'skin' .. pass), 512)
        local items = {}
        for _, photo in ipairs(dark) do
            local id = tostring(photo.localIdentifier)
            if shots and shots[photo.localIdentifier] then
                items[#items + 1] = { id = id, path = shots[photo.localIdentifier], settings = results[id] }
            end
        end
        local changes = Tone.skinChanges(items, LrPathUtils.removeExtension(out), LrPathUtils.child(session, 'skin_state.json'))
        for _, item in ipairs(items) do LrFileUtils.delete(item.path) end
        if next(changes) == nil then break end
        for id, change in pairs(changes) do
            if results[id] then for name, value in pairs(change) do results[id][name] = value end end
        end
    end

    caption(message("$$$/LRCDF/Progress/DevelopSettings=正在写入修改设置…"))
    local applied, failed = 0, 0
    catalog:withWriteAccessDo(LOC("$$$/LRCDF/Title/Tone=LRCDF 一键调色"), function()
        for id, settings in pairs(results) do
            local photo = byId[id]
            if photo == reference then photo = nil end
            if photo and not settings.error then
                Tone.write(photo, Tone.tweak(settings, options.tweak), LOC("$$$/LRCDF/Title/Tone=LRCDF 一键调色"))
                applied = applied + 1
            else
                if photo then photo:applyDevelopSettings(asBefore(before[photo]), LOC("$$$/LRCDF/History/Restore=LRCDF 还原")) end
                failed = failed + 1
            end
        end
    end, { timeout = 30 })
    if reference then Tone.restore({ [reference] = before[reference] }) end
    for _, path in pairs(rendered) do LrFileUtils.delete(path) end
    return applied, failed, log
end

return Tone
