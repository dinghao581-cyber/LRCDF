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

local messages = fresh 'Messages'
local config = fresh 'Config'
local Tone = fresh 'Tone'
local Simple = {}

-- What a photo's preview folder is called. The number Lightroom gives a photo is only unique inside one catalog:
-- with a second catalog the previews of another photo with the same number were shown (found during the Windows
-- port). The photo's own id is the same in every catalog and belongs to this photo alone.
local function previewName(photo)
    local uuid = photo:getRawMetadata('uuid')
    return (uuid and uuid ~= '') and tostring(uuid) or tostring(photo.localIdentifier)
end

local function previewDir(photo)
    return LrPathUtils.child(LrPathUtils.child(config.work, 'previews'), previewName(photo))
end

-- The looks on offer: the built-in ones, then the user's own (learned from their edits).
function Simple.cards(localized)
    local cards = {}
    for _, card in ipairs(config.cards) do
        if localized then
            local key = "$$$/LRCDF/Looks/" .. card.value
            cards[#cards + 1] = { value = card.value,
                title = LOC(key .. "/Title=" .. card.title), note = LOC(key .. "/Note=" .. card.note) }
        else
            cards[#cards + 1] = card
        end
    end
    local list = LrPathUtils.replaceExtension(config.myStyles, 'lua')
    if LrFileUtils.exists(list) then
        local ok, mine = pcall(function() return assert(loadstring(LrFileUtils.readFile(list)))() end)
        if ok and type(mine) == 'table' then
            for _, card in ipairs(mine) do
                if localized and card.note == '我的风格' then
                    cards[#cards + 1] = { value = card.value, title = card.title,
                        note = LOC("$$$/LRCDF/MyLook=我的风格") }
                elseif localized and type(card.note) == 'string' then
                    local count = card.note:match('^我的风格 · 学自 (%d+) 张照片$')
                    cards[#cards + 1] = { value = card.value, title = card.title,
                        note = count and LOC("$$$/LRCDF/Looks/Custom/Learned=我的风格 · 学自 ^1 张照片", count) or card.note }
                else
                    cards[#cards + 1] = card
                end
            end
        end
    end
    return cards
end

-- Show `settings` on the photo and render it into `target`.
local function shoot(photo, settings, target, size)
    if settings then
        local written
        LrApplication.activeCatalog():withWriteAccessDo(LOC("$$$/LRCDF/History/Preview=LRCDF 预览"), function()
            written = Tone.write(photo, settings, LOC("$$$/LRCDF/History/Preview=LRCDF 预览"))
        end, { timeout = 30 })
        Tone.arrived(photo, written or settings)      -- the write lands a moment later; render only once it is there
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

-- Dark skin (Tone.skinNotes): the preview `target` just made shows the look as the model gave it. It is measured and
-- the look corrected, twice at most, the preview made again each time; `settings` is changed in place. What was
-- changed is kept next to the previews (skin_<look>.lua) for the tweaked previews of this look.
local function keepSkin(photo, settings, look, dir, target, size)
    local id = tostring(photo.localIdentifier)
    local state = LrPathUtils.child(dir, 'skin_' .. look .. '.json')
    local kept = LrPathUtils.child(dir, 'skin_' .. look .. '.lua')
    for _, path in ipairs { state, kept } do
        if LrFileUtils.exists(path) then LrFileUtils.delete(path) end
    end
    local all, ok = {}, true
    for _ = 1, 2 do
        local change = Tone.skinChanges({ { id = id, path = target, settings = settings } }, LrPathUtils.child(dir, 'analysis'), state)[id]
        if not change then break end
        for name, value in pairs(change) do settings[name], all[name] = value, value end
        ok = shoot(photo, settings, target, size)
        if not ok then break end
    end
    local out = io.open(kept, 'w')
    if out then
        out:write('return {')
        for name, value in pairs(all) do out:write(name, '=', tostring(value), ',') end
        out:write('}\n')
        out:close()
    end
    return ok
end

-- The look's settings with what keepSkin changed for this photo (nothing for most photos).
local function withKeptSkin(settings, dir, look)
    local kept = LrPathUtils.child(dir, 'skin_' .. look .. '.lua')
    if LrFileUtils.exists(kept) then
        local ok, all = pcall(function() return assert(loadstring(LrFileUtils.readFile(kept)))() end)
        if ok and type(all) == 'table' then
            for name, value in pairs(all) do settings[name] = value end
        end
    end
    return settings
end

-- Pictures of one photo in every look of Simple.cards(): { [card value] = path }, or nil, message.
-- Made once per photo and kept (only the missing ones are made); the photo's own settings are put back afterwards.
-- size and base are optional: long edge in pixels and the folder to keep them in (the desktop app asks for large ones
-- in its own folder). The model's settings for every look are kept next to them (analysis.lua) for tweak previews.
-- only: optional set { [card value] = true } - make just these now (the desktop app asks for the look on screen first
-- and for the others one by one afterwards); the paths of all cards are returned, made or not.
function Simple.previews(photo, progress, size, base, only)
    progress = progress or {}
    local message = progress.localized and LOC or messages.source
    local caption = progress.caption or function() end
    size = size or config.previewSize
    local dir = base and LrPathUtils.child(base, previewName(photo) .. '_' .. size) or previewDir(photo)
    local cards = Simple.cards(progress.localized)
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
        caption(message("$$$/LRCDF/Progress/AnalyzePhoto=正在分析这张照片…"))
        results, before, file = Tone.apply({ photo }, 'all', 1.0, 'none', {
            localized = progress.localized,
        })
        if not results then return nil, before end
        if LrFileUtils.exists(analysis) then LrFileUtils.delete(analysis) end
        LrFileUtils.copy(file, analysis)
        for _, ending in ipairs { '.skin.lua', '.skin.npz' } do      -- the skin notes belong to the analysis
            local from, to = LrPathUtils.removeExtension(file) .. ending, LrPathUtils.removeExtension(analysis) .. ending
            if LrFileUtils.exists(to) then LrFileUtils.delete(to) end
            if LrFileUtils.exists(from) then LrFileUtils.copy(from, to) end
        end
    end
    local dark = Tone.skinNotes(LrPathUtils.removeExtension(analysis))[id]
    local ok = true
    for n, card in ipairs(missing) do
        if card.value == 'none' then
            ok = shoot(photo, nil, paths.none, size) and ok   -- Tone.apply left the photo in its neutral state
        else
            local settings = results[card.value] and results[card.value][id]
            if settings and not settings.error then
                caption(message("$$$/LRCDF/Progress/LookPreview=正在生成预览：^1（^2/^3）", card.title, n, #missing))
                if progress.portion then progress.portion(n, #missing + 1) end
                ok = shoot(photo, settings, paths[card.value], size) and ok
                if dark and ok then ok = keepSkin(photo, settings, card.value, dir, paths[card.value], size) end
            else
                ok = false
            end
        end
    end
    Tone.restore(before)
    if not ok then return nil, message("$$$/LRCDF/Errors/PreviewFailed=预览生成失败。") end
    return paths, dir
end

-- Several photos at once, for the desktop app's loading in the background. Lightroom renders the photos of one
-- export session side by side: 8 photos in about 1 s instead of 5 s one by one (16: 1.4 s instead of 9.7 s, measured
-- 2026-11-17 on the 3090 PC). Same pictures, same folders and same files as Simple.previews makes for each photo;
-- only the order differs: the analysis of all of them in one go, then each look on all of them together.
-- jobs: { { photo = photo, only = { [card value] = true } or nil } }. Returns { [photo] = { paths, dir } or { nil, message } }.
function Simple.previewsMany(jobs, size, base)
    size = size or config.previewSize
    local message = messages.source
    local cards = Simple.cards()
    local out, work = {}, {}
    for _, job in ipairs(jobs) do
        local photo = job.photo
        local dir = base and LrPathUtils.child(base, previewName(photo) .. '_' .. size) or previewDir(photo)
        local paths, missing, any = {}, {}, false
        for _, card in ipairs(cards) do
            paths[card.value] = LrPathUtils.child(dir, card.value .. '.jpg')
            if not LrFileUtils.exists(paths[card.value]) and (not job.only or job.only[card.value]) then
                missing[card.value], any = true, true
            end
        end
        out[photo] = { paths, dir }
        if any then
            LrFileUtils.createAllDirectories(dir)
            work[#work + 1] = { photo = photo, id = tostring(photo.localIdentifier), dir = dir, paths = paths,
                                missing = missing, analysis = LrPathUtils.child(dir, 'analysis.lua'), ok = true }
        end
    end
    if #work == 0 then return out end

    -- the model's settings: kept from an earlier call where they are complete (as in Simple.previews)
    local ask, before = {}, {}
    for _, w in ipairs(work) do
        local results
        if LrFileUtils.exists(w.analysis) and not w.missing.none then
            results = assert(loadstring(LrFileUtils.readFile(w.analysis)))()
            for value in pairs(w.missing) do
                if not (results[value] and results[value][w.id]) then results = nil; break end
            end
        end
        if results then
            w.results, w.skinBase = results, LrPathUtils.removeExtension(w.analysis)
            before[w.photo] = w.photo:getDevelopSettings()
        else
            ask[#ask + 1] = w
        end
    end
    if #ask > 0 then
        local photos = {}
        for i, w in ipairs(ask) do photos[i] = w.photo end
        local results, prior, file = Tone.apply(photos, 'all', 1.0, 'none', {})
        if not results then
            for _, w in ipairs(ask) do w.ok, w.failure = false, prior end
        else
            for photo, saved in pairs(prior) do before[photo] = saved end
            for _, w in ipairs(ask) do
                if LrFileUtils.exists(w.analysis) then LrFileUtils.delete(w.analysis) end
                LrFileUtils.copy(file, w.analysis)
                for _, ending in ipairs { '.skin.lua', '.skin.npz' } do
                    local from, to = LrPathUtils.removeExtension(file) .. ending, LrPathUtils.removeExtension(w.analysis) .. ending
                    if LrFileUtils.exists(to) then LrFileUtils.delete(to) end
                    if LrFileUtils.exists(from) then LrFileUtils.copy(from, to) end
                end
                w.results, w.skinBase = results, LrPathUtils.removeExtension(file)   -- one skin file for the whole group
            end
        end
    end

    -- show settings on several photos, wait for all of them once, render them together
    local function shootMany(list, look)
        local written = {}
        LrApplication.activeCatalog():withWriteAccessDo(LOC("$$$/LRCDF/History/Preview=LRCDF 预览"), function()
            for _, w in ipairs(list) do
                if w.settings then written[w] = Tone.write(w.photo, w.settings, LOC("$$$/LRCDF/History/Preview=LRCDF 预览")) end
            end
        end, { timeout = 30 })
        local names = { 'Temperature', 'Contrast2012', 'Exposure2012', 'LuminanceAdjustmentOrange', 'SaturationAdjustmentOrange' }
        for _ = 1, 20 do                                 -- Tone.arrived for all of them, the pause once
            local there = true
            for _, w in ipairs(list) do
                local want = written[w] or w.settings
                if want then
                    local now = w.photo:getDevelopSettings()
                    for _, name in ipairs(names) do
                        local v, have = want[name], now[name]
                        if type(v) == 'number' and not (type(have) == 'number' and math.abs(have - v) < 0.006) then there = false end
                    end
                end
            end
            if there then break end
            LrTasks.sleep(0.2)
        end
        if next(written) then LrTasks.sleep(config.previewSettle) end
        local photos = {}
        for i, w in ipairs(list) do photos[i] = w.photo end
        local staging = LrPathUtils.child(list[1].dir, look .. '.staging')
        local rendered = Tone.render(photos, staging, size) or {}
        for _, w in ipairs(list) do
            local path = rendered[w.photo.localIdentifier]
            if path then
                local target = w.paths[look]
                if LrFileUtils.exists(target) then LrFileUtils.delete(target) end
                LrFileUtils.move(path, target)
            else
                w.ok = false
            end
        end
        LrFileUtils.delete(staging)
    end

    local live = {}
    for _, w in ipairs(work) do if w.ok then live[#live + 1] = w end end
    local list = {}
    for _, w in ipairs(live) do
        if w.missing.none then w.settings = nil; list[#list + 1] = w end   -- Tone.apply left these in their neutral state
    end
    if #list > 0 then shootMany(list, 'none') end
    for _, card in ipairs(cards) do
        local look = card.value
        if look ~= 'none' then
            list = {}
            for _, w in ipairs(live) do
                if w.ok and w.missing[look] then
                    local settings = w.results[look] and w.results[look][w.id]
                    if settings and not settings.error then
                        w.settings = settings
                        list[#list + 1] = w
                    else
                        w.ok = false
                    end
                end
            end
            if #list > 0 then
                shootMany(list, look)
                -- dark skin, as keepSkin: measured and corrected twice at most, the corrected ones rendered together
                local groups = {}
                for _, w in ipairs(list) do
                    if w.ok then
                        for _, path in ipairs { LrPathUtils.child(w.dir, 'skin_' .. look .. '.json'), LrPathUtils.child(w.dir, 'skin_' .. look .. '.lua') } do
                            if LrFileUtils.exists(path) then LrFileUtils.delete(path) end
                        end
                        if Tone.skinNotes(LrPathUtils.removeExtension(w.analysis))[w.id] then
                            w.kept = {}
                            groups[w.skinBase] = groups[w.skinBase] or {}
                            table.insert(groups[w.skinBase], w)
                        end
                    end
                end
                for skinBase, pending in pairs(groups) do
                    local state = LrPathUtils.child(pending[1].dir, 'skin_' .. look .. '.json')
                    for _ = 1, 2 do
                        local items = {}
                        for _, w in ipairs(pending) do items[#items + 1] = { id = w.id, path = w.paths[look], settings = w.settings } end
                        local changes = Tone.skinChanges(items, skinBase, state)
                        local redo = {}
                        for _, w in ipairs(pending) do
                            local change = changes[w.id]
                            if change then
                                for name, value in pairs(change) do w.settings[name], w.kept[name] = value, value end
                                redo[#redo + 1] = w
                            end
                        end
                        if #redo == 0 then break end
                        shootMany(redo, look)
                        pending = {}
                        for _, w in ipairs(redo) do if w.ok then pending[#pending + 1] = w end end
                        if #pending == 0 then break end
                    end
                end
                for _, w in ipairs(list) do
                    if w.kept then
                        local file = io.open(LrPathUtils.child(w.dir, 'skin_' .. look .. '.lua'), 'w')
                        if file then
                            file:write('return {')
                            for name, value in pairs(w.kept) do file:write(name, '=', tostring(value), ',') end
                            file:write('}\n')
                            file:close()
                        end
                        w.kept = nil
                    end
                end
            end
        end
    end
    if next(before) then Tone.restore(before) end
    for _, w in ipairs(work) do
        if not w.ok then out[w.photo] = { nil, w.failure or message("$$$/LRCDF/Errors/PreviewFailed=预览生成失败。") } end
    end
    return out
end

-- One look with a tweak ({ bright, warm, rich }), rendered next to the other previews. Returns the picture's path.
-- The file name of a tweaked look: the three values in hundredths of a step, "d_t35_-120_0" (a whole step is 100),
-- then what the colour wheels ask for, in this order and only when there: _n<tint x 100>, _s<hue>-<amount> (shadows),
-- _h<hue>-<amount> (highlights): "d_t35_-120_0_n40_s210-30_h45-20".
function Simple.tweakName(look, tweak)
    local parts = {}
    for i = 1, 3 do parts[i] = string.format('%d', math.floor((tweak[i] or 0) * 100 + 0.5)) end
    local name = look .. '_t' .. table.concat(parts, '_')
    if tweak.tint and tweak.tint ~= 0 then name = name .. string.format('_n%d', math.floor(tweak.tint * 100 + 0.5)) end
    if tweak.shadow then name = name .. string.format('_s%d-%d', tweak.shadow[1], tweak.shadow[2]) end
    if tweak.high then name = name .. string.format('_h%d-%d', tweak.high[1], tweak.high[2]) end
    return name
end

-- A look's name as an app gives it. Apps from before the stepless tweaks say "d_t1_0_-1" (whole steps); a name in
-- hundredths never has all three values within -2..2 (the smallest one that is not zero is 5), so those are old ones.
function Simple.lookName(look)
    local base, b, w, r = look:match('^(.+)_t(-?%d+)_(-?%d+)_(-?%d+)$')
    if not base then return look end
    b, w, r = tonumber(b), tonumber(w), tonumber(r)
    if math.max(math.abs(b), math.abs(w), math.abs(r)) <= 2 then return Simple.tweakName(base, { b, w, r }) end
    return look
end

-- A stepless tweak can ask for many pictures: of one look's tweaked previews only the latest KEPT stay (by the time
-- they were made), with the retouched previews made from them.
local KEPT = 8

-- "d_t35_-120_0_n40_s210-30_natural_slim" -> "d", "d_t35_-120_0_n40_s210-30", "_natural_slim" (nil for other names)
local function tweaked(name)
    local look, values, rest = name:match('^(.-)(_t%-?%d+_%-?%d+_%-?%d+)(.*)$')
    if not look then return nil end
    for _, pattern in ipairs { '^_n%-?%d+', '^_s%d+%-%d+', '^_h%d+%-%d+' } do
        local segment = rest:match(pattern)
        if segment then values, rest = values .. segment, rest:sub(#segment + 1) end
    end
    return look, look .. values, rest
end

local function forgetOld(dir, look)
    local found = {}
    for path in LrFileUtils.files(dir) do
        local leaf = LrPathUtils.leafName(path)
        local of, name, rest = tweaked(leaf:match('^(.*)%.jpg$') or '')
        if of == look and rest == '' then
            local attributes = LrFileUtils.fileAttributes(path)
            found[#found + 1] = { name = name, made = attributes and attributes.fileModificationDate or 0 }
        end
    end
    if #found <= KEPT then return end
    table.sort(found, function(x, y) return x.made > y.made end)
    local gone = {}
    for i = KEPT + 1, #found do gone[found[i].name] = true end
    for path in LrFileUtils.files(dir) do
        local _, name = tweaked(LrPathUtils.leafName(path):match('^(.*)%.jpg$') or '')
        if name and gone[name] then LrFileUtils.delete(path) end
    end
end

function Simple.tweakPreview(photo, dir, look, tweak, size)
    local name = Simple.tweakName(look, tweak)
    local target = LrPathUtils.child(dir, name .. '.jpg')
    if LrFileUtils.exists(target) then return target, name end
    local analysis = LrPathUtils.child(dir, 'analysis.lua')
    if not LrFileUtils.exists(analysis) then return nil, '请先生成这张照片的预览。' end
    local results = assert(loadstring(LrFileUtils.readFile(analysis)))()
    local settings = results[look] and results[look][tostring(photo.localIdentifier)]
    if not settings or settings.error then return nil, '没有这个效果的数据。' end
    local before = { [photo] = photo:getDevelopSettings() }
    local ok = shoot(photo, Tone.tweak(withKeptSkin(settings, dir, look), tweak), target, size or config.previewSize)
    Tone.restore(before)
    if not ok then return nil, '预览生成失败。' end
    forgetOld(dir, look)
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
