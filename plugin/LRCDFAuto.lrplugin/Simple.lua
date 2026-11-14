-- The simple, slider-free workflow behind "LRCDF 一键修图": previews of every look made from the user's own photo,
-- then tone + beautify in one go.
local LrApplication = import 'LrApplication'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

-- Read a plug-in file from disk every time, so edits take effect without reloading the plug-in.
local function fresh(name)
    local path = LrPathUtils.child(_PLUGIN.path, name .. '.lua')
    return assert(loadstring(LrFileUtils.readFile(path), name))()
end

local config = fresh 'Config'
local Tone = fresh 'Tone'
local Simple = {}

local function previewDir(photo)
    return LrPathUtils.child(LrPathUtils.child(config.work, 'previews'), tostring(photo.localIdentifier))
end

-- The looks on offer: the built-in ones, then the user's own (learned from their edits).
function Simple.cards()
    local cards = {}
    for _, card in ipairs(config.cards) do cards[#cards + 1] = card end
    local list = LrPathUtils.replaceExtension(config.myStyles, 'lua')
    if LrFileUtils.exists(list) then
        local ok, mine = pcall(function() return assert(loadstring(LrFileUtils.readFile(list)))() end)
        if ok and type(mine) == 'table' then
            for _, card in ipairs(mine) do cards[#cards + 1] = card end
        end
    end
    return cards
end

-- Show `settings` on the photo and render it into `target`.
local function shoot(photo, settings, target, size)
    if settings then
        LrApplication.activeCatalog():withWriteAccessDo('LRCDF 预览', function()
            photo:applyDevelopSettings(settings, 'LRCDF 预览')
        end, { timeout = 30 })
        for _ = 1, 20 do   -- the write lands a moment later; render only once it is there
            local now = photo:getDevelopSettings()
            if now.Temperature == settings.Temperature and now.Contrast2012 == settings.Contrast2012
                and now.Exposure2012 == settings.Exposure2012 then break end
            LrTasks.sleep(0.2)
        end
        LrTasks.sleep(config.previewSettle)
    end
    local staging = target .. '.staging'
    local path = Tone.render({ photo }, staging, size)[photo.localIdentifier]
    if path then
        if LrFileUtils.exists(target) then LrFileUtils.delete(target) end
        LrFileUtils.move(path, target)
    end
    LrFileUtils.delete(staging)
    return path ~= nil
end

-- Pictures of one photo in every look of Simple.cards(): { [card value] = path }, or nil, message.
-- Made once per photo and kept (only the missing ones are made); the photo's own settings are put back afterwards.
-- size and base are optional: long edge in pixels and the folder to keep them in (the desktop app asks for large ones
-- in its own folder). The model's settings for every look are kept next to them (analysis.lua) for tweak previews.
-- only: optional set { [card value] = true } - make just these now (the desktop app asks for the look on screen first
-- and for the others one by one afterwards); the paths of all cards are returned, made or not.
function Simple.previews(photo, progress, size, base, only)
    progress = progress or {}
    local caption = progress.caption or function() end
    size = size or config.previewSize
    local dir = base and LrPathUtils.child(base, photo.localIdentifier .. '_' .. size) or previewDir(photo)
    local cards = Simple.cards()
    local paths, missing = {}, {}
    for _, card in ipairs(cards) do
        paths[card.value] = LrPathUtils.child(dir, card.value .. '.jpg')
        if not LrFileUtils.exists(paths[card.value]) and (not only or only[card.value]) then missing[#missing + 1] = card end
    end
    if #missing == 0 then return paths, dir end
    LrFileUtils.createAllDirectories(dir)

    local id = tostring(photo.localIdentifier)
    local analysis = LrPathUtils.child(dir, 'analysis.lua')
    local results, before, file
    -- The model's settings for every look are kept from the first call: asking it again costs several seconds.
    if LrFileUtils.exists(analysis) then
        results = assert(loadstring(LrFileUtils.readFile(analysis)))()
        for _, card in ipairs(missing) do
            if card.value == 'none' or not (results[card.value] and results[card.value][id]) then results = nil; break end
        end
    end
    if results then
        before = { [photo] = photo:getDevelopSettings() }
    else
        caption('正在分析这张照片…')
        results, before, file = Tone.apply({ photo }, 'all', 1.0, 'none')
        if not results then return nil, before end
        if LrFileUtils.exists(analysis) then LrFileUtils.delete(analysis) end
        LrFileUtils.copy(file, analysis)
    end
    local ok = true
    for n, card in ipairs(missing) do
        if card.value == 'none' then
            ok = shoot(photo, nil, paths.none, size) and ok   -- Tone.apply left the photo in its neutral state
        else
            local settings = results[card.value] and results[card.value][id]
            if settings and not settings.error then
                caption('正在生成预览：' .. card.title .. '（' .. n .. '/' .. #missing .. '）')
                if progress.portion then progress.portion(n, #missing + 1) end
                ok = shoot(photo, settings, paths[card.value], size) and ok
            else
                ok = false
            end
        end
    end
    Tone.restore(before)
    if not ok then return nil, '预览生成失败。' end
    return paths, dir
end

-- One look with a tweak ({ bright, warm, rich }), rendered next to the other previews. Returns the picture's path.
function Simple.tweakPreview(photo, dir, look, tweak, size)
    local name = look .. '_t' .. table.concat(tweak, '_')
    local target = LrPathUtils.child(dir, name .. '.jpg')
    if LrFileUtils.exists(target) then return target, name end
    local analysis = LrPathUtils.child(dir, 'analysis.lua')
    if not LrFileUtils.exists(analysis) then return nil, '请先生成这张照片的预览。' end
    local results = assert(loadstring(LrFileUtils.readFile(analysis)))()
    local settings = results[look] and results[look][tostring(photo.localIdentifier)]
    if not settings or settings.error then return nil, '没有这个效果的数据。' end
    local before = { [photo] = photo:getDevelopSettings() }
    local ok = shoot(photo, Tone.tweak(settings, tweak), target, size or config.previewSize)
    Tone.restore(before)
    if not ok then return nil, '预览生成失败。' end
    return target, name
end

-- Tone (unless style is 'none') and beautify (unless level is 'off') the photos.
-- level: 'off' | 'auto' | 'natural' | 'refined' (config.beautyLevels; auto = per face, see beautify.choose); slim: true for light face slimming.
-- extra: more options for Beauty.apply (import, dest). denoise: true switches on Lightroom's AI Denoise first.
-- Returns a table { toned, beautified, denoised, failed, log } or nil, message.
-- tweak: { bright, warm, rich } on top of the look. The result also lists created = { [original id] = new photo id }
-- and denoisedIds (photos whose AI Denoise was switched on here), for undo and for looking at the results.
function Simple.run(photos, style, level, slim, progress, extra, denoise, tweak)
    local out = { toned = 0, beautified = 0, denoised = 0, failed = 0 }
    progress = progress or {}
    local phases = (denoise and 1 or 0) + (style ~= 'none' and 1 or 0) + (level ~= 'off' and 1 or 0)
    local phase = 0
    local function nextPhase()
        phase = phase + 1
        if progress.phase then progress.phase(phase, phases) end
    end
    if denoise then
        nextPhase()
        local done, skipped, failed, ids = fresh('Denoise').apply(photos, progress)
        out.denoised, out.failed, out.denoisedIds = done + skipped, failed, ids
    end
    if style ~= 'none' then
        nextPhase()
        local applied, failed, log = Tone.apply(photos, style, 1.0, 'time', progress, nil, { tweak = tweak })
        if not applied then return nil, failed end
        out.toned, out.failed, out.log = applied, out.failed + failed, log
    end
    if level ~= 'off' then
        if style ~= 'none' or denoise then LrTasks.sleep(config.settleSeconds + 0.5) end   -- the new look must be rendered first
        nextPhase()
        local options = {}
        -- 'auto': the script chooses a level per face; the values of 精致 stand in where it cannot
        for key, value in pairs(config.beautyLevels[level == 'auto' and 'refined' or level] or config.beautyLevels.natural) do options[key] = value / 100 end
        if level == 'auto' then options.auto = true end
        for key, value in pairs(extra or {}) do options[key] = value end
        if slim then options.slim = true end
        for key, percent in pairs(config.shapes) do      -- extra.slim, .bigeyes, .chest, .waist, .legs are switches
            options[key] = options[key] and percent / 100 or 0
        end
        local done, failed, log, created = fresh('Beauty').apply(photos, options, progress)
        if not done then return nil, failed end
        out.beautified, out.failed, out.log, out.created = done, out.failed + failed, log, created
    end
    return out
end

return Simple
