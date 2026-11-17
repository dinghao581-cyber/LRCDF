-- What the background listener can do. Read from disk for every command (see Server.lua).
local LrApplication = import 'LrApplication'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

-- Read a plug-in file from disk every time, so edits take effect without reloading the plug-in.
local function fresh(name)
    local path = LrPathUtils.child(_PLUGIN.path, name .. '.lua')
    return assert(loadstring(LrFileUtils.readFile(path), name))()
end

local Tone = fresh 'Tone'

local function serialize(value, out)
    local kind = type(value)
    if kind == 'table' then
        out[#out + 1] = '{'
        for k, v in pairs(value) do
            local vk = type(v)
            if vk == 'table' or vk == 'number' or vk == 'string' or vk == 'boolean' then
                out[#out + 1] = type(k) == 'number' and ('[' .. k .. ']=') or ('[' .. string.format('%q', tostring(k)) .. ']=')
                serialize(v, out)
                out[#out + 1] = ','
            end
        end
        out[#out + 1] = '}'
    elseif kind == 'string' then
        out[#out + 1] = string.format('%q', value)
    else
        out[#out + 1] = tostring(value)
    end
end

local function targetPhotos(args)
    local catalog = LrApplication.activeCatalog()
    if not args.ids then return catalog:getTargetPhotos() end
    local photos = {}
    for id in args.ids:gmatch('%d+') do
        photos[#photos + 1] = catalog:getPhotoByLocalId(tonumber(id))
    end
    return photos
end

local function applyFile(photos, path, label, asBefore)
    local saved = assert(loadstring(LrFileUtils.readFile(path)))()
    local count = 0
    LrApplication.activeCatalog():withWriteAccessDo(label, function()
        for _, photo in ipairs(photos) do
            local settings = saved[tostring(photo.localIdentifier)]
            if settings then
                if settings.WhiteBalance == 'As Shot' then
                    -- only a preset really returns a photo to its as-shot white balance; applyDevelopSettings would
                    -- keep the current temperature under an "As Shot" label
                    local asShot = LrApplication.addDevelopPresetForPlugin(_PLUGIN, LOC("$$$/LRCDF/History/AsShotWhiteBalance=LRCDF 原始白平衡"), { WhiteBalance = 'As Shot' })
                    photo:applyDevelopSettings({ WhiteBalance = 'Custom', Temperature = 5000, Tint = 0 }, label)
                    photo:applyDevelopPreset(asShot, _PLUGIN)
                    settings.WhiteBalance, settings.Temperature, settings.Tint = nil, nil, nil
                end
                -- going back: a photo that had no masks when it was saved has none afterwards (the skin mask goes)
                if asBefore and not settings.MaskGroupBasedCorrections then settings.MaskGroupBasedCorrections = {} end
                photo:applyDevelopSettings(settings, label)
                count = count + 1
            end
        end
    end, { timeout = 30 })
    return count
end

local actions = {}

function actions.tone(args, photos)
    local reference
    if args.ref then  -- reference-photo mode: ref=<id> must be one of the photos
        for _, photo in ipairs(photos) do
            if photo.localIdentifier == tonumber(args.ref) then reference = photo end
        end
        if not reference then error('ref must be one of the photos', 0) end
    end
    local applied, failed, log = Tone.apply(photos, args.style or 'a', tonumber(args.strength) or 1.0, args.group or 'time', nil, reference)
    if not applied then error(failed, 0) end
    return 'applied=' .. applied .. ' failed=' .. failed .. ' log=' .. tostring(log)
end

-- Full-size 16-bit TIFFs as the retouching step gets them: dir=<folder> [wide=1 for ProPhoto RGB]
function actions.exportfull(args, photos)
    local rendered = Tone.render(photos, assert(args.dir, 'dir is required'), nil, nil, args.wide == '1')
    local lines = {}
    for id, path in pairs(rendered) do lines[#lines + 1] = id .. '\t' .. path end
    return table.concat(lines, '\n')
end

function actions.export(args, photos)
    local dir = assert(args.dir, 'dir is required')
    local staging = LrPathUtils.child(dir, '.staging')
    local rendered = Tone.render(photos, staging, tonumber(args.size) or 1024)
    local lines = {}
    for id, path in pairs(rendered) do
        local target = LrPathUtils.child(dir, id .. '_' .. (args.tag or 'out') .. '.jpg')
        if LrFileUtils.exists(target) then LrFileUtils.delete(target) end
        LrFileUtils.move(path, target)
        lines[#lines + 1] = target
    end
    LrFileUtils.delete(staging)
    return table.concat(lines, '\n')
end

function actions.save(args, photos)
    local all = {}
    for _, photo in ipairs(photos) do all[tostring(photo.localIdentifier)] = photo:getDevelopSettings() end
    local out = { 'return ' }
    serialize(all, out)
    local file = assert(io.open(assert(args.file, 'file is required'), 'w'))
    file:write(table.concat(out))
    file:close()
    return 'saved=' .. #photos
end

function actions.restore(args, photos)
    return 'restored=' .. applyFile(photos, assert(args.file, 'file is required'), LOC("$$$/LRCDF/History/Restore=LRCDF 还原"), true)
end

function actions.apply(args, photos)
    return 'applied=' .. applyFile(photos, assert(args.file, 'file is required'), LOC("$$$/LRCDF/History/ApplySettings=LRCDF 应用设置"))
end

function actions.info(args, photos)
    local lines = {}
    for _, photo in ipairs(photos) do
        local s = photo:getDevelopSettings()
        lines[#lines + 1] = table.concat({ tostring(photo.localIdentifier), tostring(photo:getFormattedMetadata('fileName')),
            tostring(s.WhiteBalance), tostring(s.Temperature), tostring(s.Tint), tostring(s.Exposure2012),
            tostring(photo:getRawMetadata('dateTimeOriginal')) }, '\t')
    end
    return table.concat(lines, '\n')
end

-- Where each photo sits in its folder stack: id, file, in stack, position (1 = top), then the stack members top first.
function actions.stack(args, photos)
    local lines = {}
    for _, photo in ipairs(photos) do
        local members = {}
        for _, other in ipairs(photo:getRawMetadata('stackInFolderMembers') or {}) do
            members[#members + 1] = other:getRawMetadata('stackPositionInFolder') .. ':' .. other:getFormattedMetadata('fileName')
                .. '#' .. other.localIdentifier
        end
        table.sort(members)
        lines[#lines + 1] = table.concat({ tostring(photo.localIdentifier), tostring(photo:getFormattedMetadata('fileName')),
            tostring(photo:getRawMetadata('isInStackInFolder')), tostring(photo:getRawMetadata('stackPositionInFolder')),
            table.concat(members, ' ') }, '\t')
    end
    return table.concat(lines, '\n')
end

-- Overview of the catalog for picking test photos: one line per folder (photo count, raw count, ISO range, capture hours),
-- or with folder=<path> one line per photo of that folder (id, file, ISO, shutter, aperture, capture time).
function actions.catalog(args)
    local catalog = LrApplication.activeCatalog()
    local lines = {}
    local function visit(folder)
        local photos = folder:getPhotos(false)
        if #photos > 0 and (not args.folder or folder:getPath() == args.folder) then
            local meta = catalog:batchGetRawMetadata(photos, { 'isoSpeedRating', 'dateTimeOriginal', 'fileFormat', 'shutterSpeed', 'aperture' })
            local raws, lo, hi, hours = 0, nil, nil, {}
            for _, photo in ipairs(photos) do
                local m = meta[photo]
                if m.fileFormat == 'RAW' or m.fileFormat == 'DNG' then raws = raws + 1 end
                local iso = m.isoSpeedRating
                if iso then lo = math.min(lo or iso, iso) hi = math.max(hi or iso, iso) end
                local hour = m.dateTimeOriginal and os.date('%H', m.dateTimeOriginal + 978307200)
                if hour then hours[hour] = (hours[hour] or 0) + 1 end
                if args.folder then
                    lines[#lines + 1] = table.concat({ tostring(photo.localIdentifier), tostring(photo:getFormattedMetadata('fileName')),
                        tostring(iso), tostring(m.shutterSpeed), tostring(m.aperture),
                        m.dateTimeOriginal and os.date('%Y-%m-%d %H:%M', m.dateTimeOriginal + 978307200) or '?' }, '\t')
                end
            end
            if not args.folder then
                local hs = {}
                for hour, n in pairs(hours) do hs[#hs + 1] = hour .. 'h:' .. n end
                table.sort(hs)
                lines[#lines + 1] = table.concat({ folder:getPath(), #photos .. ' photos', raws .. ' raw',
                    'iso ' .. tostring(lo) .. '-' .. tostring(hi), table.concat(hs, ' ') }, '\t')
            end
        end
        for _, child in ipairs(folder:getChildren()) do visit(child) end
    end
    for _, folder in ipairs(catalog:getFolders()) do visit(folder) end
    return table.concat(lines, '\n')
end

-- Add every file of a folder to the catalog in place (for test material). Prints id and file per photo.
function actions.add(args)
    local catalog = LrApplication.activeCatalog()
    local added = {}
    catalog:withWriteAccessDo(LOC("$$$/LRCDF/History/AddTestPhotos=LRCDF 添加测试照片"), function()
        for path in LrFileUtils.files(assert(args.dir, 'dir is required')) do
            if not LrPathUtils.leafName(path):match('^%.') then
                local photo = catalog:findPhotoByPath(path) or catalog:addPhoto(path)
                added[#added + 1] = photo
            end
        end
    end, { timeout = 60 })
    local lines = {}
    for _, photo in ipairs(added) do
        lines[#lines + 1] = photo.localIdentifier .. '\t' .. photo:getFormattedMetadata('fileName')
    end
    return table.concat(lines, '\n')
end

-- Put the photos back to the unedited look (as-shot white balance, all model-controlled settings neutral).
function actions.neutral(args, photos)
    LrApplication.activeCatalog():withWriteAccessDo(LOC("$$$/LRCDF/History/OriginalState=LRCDF 原片状态"), function()
        local preset = LrApplication.addDevelopPresetForPlugin(_PLUGIN, LOC("$$$/LRCDF/History/OriginalState=LRCDF 原片状态"), fresh 'Neutral')
        for _, photo in ipairs(photos) do
            photo:applyDevelopSettings({ WhiteBalance = 'Custom', Temperature = 5000, Tint = 0 }, 'LRCDF')
            photo:applyDevelopPreset(preset, _PLUGIN)
        end
    end, { timeout = 30 })
    return 'neutral=' .. #photos
end

-- The simple workflow, as the "LRCDF 一键修图" dialog runs it.
function actions.previews(args, photos)
    local t0 = os.time()
    local Simple = fresh 'Simple'
    fresh('Beauty').warm()      -- the beauty preview will be wanted next: load its models while Lightroom renders the looks
    local only
    if args.only and args.only ~= '' then       -- only=none,d: just these now; the lines list the looks that exist
        only = {}
        for value in args.only:gmatch('[^,]+') do only[value] = true end
    end
    local paths, dir = Simple.previews(photos[1], nil, tonumber(args.size), args.dir, only)
    if not paths then error(dir, 0) end
    local lines = { 'seconds=' .. (os.time() - t0) }
    -- a fifth column for the colour wheels: where the look itself puts shadows and highlights, in the wheels' own
    -- numbers ("wheels=<shadow hue>,<amount>,<highlight hue>,<amount>"; amount = saturation x 2, as shadow= / high=
    -- are halved when written). A wheel starts there: what it sends replaces the look's value, so a wheel starting
    -- at nothing would make the colour jump at the first touch. Empty for a look not rendered yet.
    local results = {}
    local analysis = LrPathUtils.child(dir, 'analysis.lua')
    if LrFileUtils.exists(analysis) then
        local chunk = loadstring(LrFileUtils.readFile(analysis))
        local ok, read = pcall(chunk or error)
        if ok and type(read) == 'table' then results = read end
    end
    local id = tostring(photos[1].localIdentifier)
    local function amount(saturation) return math.min(100, math.floor((tonumber(saturation) or 0) * 2 / 5 + 0.5) * 5) end
    local function hue(value) return (math.floor((tonumber(value) or 0) / 5 + 0.5) * 5) % 360 end
    for _, card in ipairs(Simple.cards(true)) do   -- value, picture, title, note, wheels: in the order they are shown
        local made = LrFileUtils.exists(paths[card.value])
        local settings = results[card.value] and results[card.value][id]
        local wheels = ''
        if card.value == 'none' then
            wheels = 'wheels=0,0,0,0'
        elseif made and type(settings) == 'table' and not settings.error then
            wheels = string.format('wheels=%d,%d,%d,%d', hue(settings.SplitToningShadowHue), amount(settings.SplitToningShadowSaturation),
                hue(settings.SplitToningHighlightHue), amount(settings.SplitToningHighlightSaturation))
        end
        lines[#lines + 1] = table.concat({ card.value, made and paths[card.value] or '', card.title, card.note, wheels }, '\t')
    end
    return table.concat(lines, '\n')
end

-- tweak=bright,warm,rich: 1.0 is one of the old five steps, -2..2, in steps of 0.05 ("0.35,-1.2,0"; the old whole
-- steps "1,0,-1" mean what they always did). The apps show value x 50 (-100..100).
-- The colour wheels add, each optional: tint=T (-2..2 in steps of 0.05; green to magenta), shadow=hue,amount and
-- high=hue,amount (hue 0..359 in steps of 5 degrees, amount 0..100 in steps of 5). Not given: the look's own colour
-- for that range stays. Given with amount 0: no colour there (the wheel dragged to its centre); the hue is then 0.
-- Returns { bright, warm, rich, tint = T, shadow = { hue, amount }, high = { hue, amount } } or nil when nothing is asked.
local function tweakOf(args)
    local t = {}
    for value in (args.tweak or ''):gmatch('-?%d+%.?%d*') do
        local v = math.max(-2, math.min(2, tonumber(value) or 0))
        t[#t + 1] = math.floor(v * 20 + 0.5) / 20
    end
    if #t ~= 3 then
        if args.tweak and args.tweak ~= '' then return nil end
        t = { 0, 0, 0 }
    end
    local tint = tonumber(args.tint)
    if tint then
        tint = math.floor(math.max(-2, math.min(2, tint)) * 20 + 0.5) / 20
        if tint ~= 0 then t.tint = tint end
    end
    local function wheel(text)
        local hue, amount = (text or ''):match('^(%d+%.?%d*),(%d+%.?%d*)$')
        hue, amount = tonumber(hue), tonumber(amount)
        if not hue or not amount then return nil end
        amount = math.floor(math.max(0, math.min(100, amount)) / 5 + 0.5) * 5
        if amount == 0 then return { 0, 0 } end     -- given with nothing: this range gets no colour, whatever the look has
        return { (math.floor(hue / 5 + 0.5) * 5) % 360, amount }
    end
    t.shadow, t.high = wheel(args.shadow), wheel(args.high)
    if t[1] == 0 and t[2] == 0 and t[3] == 0 and not t.tint and not t.shadow and not t.high then return nil end
    return t
end

-- One look with a tweak, for the app's comparison: dir=<previews folder of the photo> look=d tweak=0.35,-1.2,0 [tint=0.4 shadow=210,30 high=45,20]
function actions.tweakpreview(args, photos)
    local tweak = assert(tweakOf(args), 'tweak is required')
    local path, name = fresh('Simple').tweakPreview(photos[1], assert(args.dir), assert(args.look), tweak, tonumber(args.size))
    if not path then error(name, 0) end
    return name .. '\t' .. path
end

-- Store the current edit of the photo as one of the user's own looks: name=<title>
-- The first photo is the one on screen and must be edited. Every other photo given that has been edited too becomes
-- another example (at most 24 in all): the look is the average of what the user did, which is clearly closer to how
-- they edit than one photo (predict.learn). Answer: the key, then "examples=<how many photos it was learnt from>".
function actions.learnstyle(args, photos)
    local function edited(photo)
        local s = photo:getDevelopSettings()
        if s.WhiteBalance ~= 'As Shot' then return true end
        for _, key in ipairs { 'Exposure2012', 'Contrast2012', 'Highlights2012', 'Shadows2012', 'Whites2012', 'Blacks2012', 'Vibrance', 'Saturation' } do
            if (s[key] or 0) ~= 0 then return true end
        end
        return false
    end
    local photo = photos[1]
    if not edited(photo) then error('这张照片还没有调过。请先在 Lightroom 里把它调到满意，再存为我的风格。', 0) end
    local examples = { photo }
    for k = 2, #photos do
        if #examples < 24 and edited(photos[k]) then examples[#examples + 1] = photos[k] end
    end
    local key = 'u' .. os.time()
    local ok, message = Tone.apply(examples, 'a', 1.0, 'none', nil, photo, { learn = { key = key, name = args.name or '我的风格' } })
    if not ok then error(message, 0) end
    return key .. '\nexamples=' .. #examples
end

function actions.forgetstyle(args)
    local config = fresh 'Config'
    local q = Tone.shellQuote
    local out = LrPathUtils.child(config.appData, 'forget.lua')
    Tone.execute(Tone.python(config.predict) .. ' --ckpt x --job x --out ' .. q(out) ..
        ' --mystyles ' .. q(config.myStyles) .. ' --forget ' .. q(assert(args.key, 'key is required')))
    return 'forgotten=' .. args.key
end

-- Undo a run: file=<settings saved before it> [rejects=<ids of the pictures it made>] [denoised=<ids>]
-- The SDK cannot remove photos from the catalog, so the pictures the run made are marked as rejected instead.
function actions.undo(args, photos)
    local restored = applyFile(photos, assert(args.file, 'file is required'), LOC("$$$/LRCDF/History/Undo=LRCDF 撤销"), true)
    local catalog = LrApplication.activeCatalog()
    local rejected = 0
    if args.rejects then
        catalog:withWriteAccessDo(LOC("$$$/LRCDF/History/Undo=LRCDF 撤销"), function()
            for id in args.rejects:gmatch('%d+') do
                local photo = catalog:getPhotoByLocalId(tonumber(id))
                if photo then photo:setRawMetadata('pickStatus', -1) rejected = rejected + 1 end
            end
        end, { timeout = 30 })
    end
    if args.denoised then
        local list = {}
        for id in args.denoised:gmatch('%d+') do list[#list + 1] = catalog:getPhotoByLocalId(tonumber(id)) end
        if #list > 0 then fresh('Denoise').remove(list) end
    end
    return 'restored=' .. restored .. ' rejected=' .. rejected
end

-- Which photos have closed eyes or are out of focus: renders them into dir and lets scripts/cull.py judge.
-- Lines: id <TAB> flags (comma list, may be empty) <TAB> sharpness <TAB> blink <TAB> faces
function actions.cull(args, photos)
    local config = fresh 'Config'
    local dir = assert(args.dir, 'dir is required')
    local staging = LrPathUtils.child(dir, '.staging')
    local rendered = Tone.render(photos, staging, tonumber(args.size) or 1400)
    local job = LrPathUtils.child(dir, 'cull_job.tsv')
    local file = assert(io.open(job, 'w'))
    for _, photo in ipairs(photos) do
        local path = rendered[photo.localIdentifier]
        if path then
            local target = LrPathUtils.child(dir, photo.localIdentifier .. '.jpg')
            if LrFileUtils.exists(target) then LrFileUtils.delete(target) end
            LrFileUtils.move(path, target)
            file:write(photo.localIdentifier, '\t', target, '\n')
        end
    end
    file:close()
    LrFileUtils.delete(staging)
    local q = Tone.shellQuote
    local out = LrPathUtils.child(dir, 'cull_result.tsv')
    Tone.execute(Tone.python(config.cull) .. ' --job ' .. q(job) .. ' --out ' .. q(out) ..
        ' --people ' .. q(LrPathUtils.child(dir, 'people.json')) .. ' --fresh ' .. (args.fresh == '1' and 1 or 0) ..
        ' > ' .. q(LrPathUtils.child(dir, 'cull.log')) .. ' 2>&1')
    if not LrFileUtils.exists(out) then error('选片分析没有完成。', 0) end
    return LrFileUtils.readFile(out)
end

-- Small pictures of the photos as they look now, for the app's photo strip: dir/<id>.jpg.
function actions.thumbs(args, photos)
    local dir = assert(args.dir, 'dir is required')
    local staging = LrPathUtils.child(dir, '.staging')
    local rendered = Tone.render(photos, staging, tonumber(args.size) or 240)
    local lines = {}
    for _, photo in ipairs(photos) do
        local path = rendered[photo.localIdentifier]
        if path then
            local target = LrPathUtils.child(dir, photo.localIdentifier .. '.jpg')
            if LrFileUtils.exists(target) then LrFileUtils.delete(target) end
            LrFileUtils.move(path, target)
            lines[#lines + 1] = photo.localIdentifier .. '\t' .. target
        end
    end
    LrFileUtils.delete(staging)
    return table.concat(lines, '\n')
end

-- Beautified versions of one look's preview picture, for the app's before/after view.
-- dir=<folder of Simple.previews> look=d levels=natural,refined slim=0|1 -> lines "level <TAB> picture"
function actions.beautypreview(args)
    local config = fresh 'Config'
    local dir, look = assert(args.dir, 'dir is required'), assert(args.look, 'look is required')
    look = fresh('Simple').lookName(look)        -- an app from before the stepless tweaks names tweaked looks the old way
    local order = { 'slim', 'bigeyes', 'chest', 'waist', 'legs', 'light' }
    local suffix, amounts = '', {}
    for _, key in ipairs(order) do
        local on = args[key] == '1'
        if on then suffix = suffix .. '_' .. key end
        amounts[#amounts + 1] = on and config.shapes[key] / 100 or 0
    end
    local Beauty = fresh 'Beauty'
    if args.peoplefile and LrFileUtils.exists(args.peoplefile) and args.people and args.people ~= '' then suffix = suffix .. '_p' .. args.people:gsub('[:,]', '') end
    local job = LrPathUtils.child(dir, 'beauty_job.tsv')
    local file = assert(io.open(job, 'w'))
    local wanted = {}
    for level in (args.levels or 'natural'):gmatch('[%a]+') do
        local values = config.beautyLevels[level == 'auto' and 'refined' or level]
        local out = LrPathUtils.child(dir, look .. '_' .. level .. suffix .. '.jpg')
        if values then
            wanted[#wanted + 1] = { level = level, path = out }
            if not LrFileUtils.exists(out) then
                file:write(table.concat({ LrPathUtils.child(dir, look .. '.jpg'), out, values.blemish / 100, values.smooth / 100,
                    values.undereye / 100, values.eyes / 100, values.teeth / 100, table.concat(amounts, '\t') }, '\t'),
                    level == 'auto' and '\tauto' or '', '\n')
            end
        end
    end
    file:close()
    local q = Tone.shellQuote
    local function arguments(quote)
        return ' --job ' .. quote(job) .. ' --original ' .. quote(LrPathUtils.child(dir, 'none.jpg')) ..
            ' --faces ' .. quote(LrPathUtils.child(dir, 'faces.json')) .. Beauty.who(args.peoplefile, args.people, quote)
    end
    -- The .req file is parsed by Python's shlex on both platforms.
    if not Beauty.preview(arguments(Tone.posixQuote)) then
        Tone.execute(Tone.python(config.previewBeauty) .. arguments(q) ..
            ' > ' .. q(LrPathUtils.child(dir, 'beauty.log')) .. ' 2>&1')
    end
    local lines = {}
    for _, item in ipairs(wanted) do
        if LrFileUtils.exists(item.path) then lines[#lines + 1] = item.level .. '\t' .. item.path end
    end
    if #lines == 0 then error('美颜预览没有生成。', 0) end
    return table.concat(lines, '\n')
end

-- progress=<file>: while it runs, the file holds "fraction <TAB> what is happening" for whoever is waiting.
function actions.oneclick(args, photos)
    local progress
    if args.progress then
        local phase, phases, text = 1, 1, ''
        local function report(fraction)
            local file = io.open(args.progress .. '.tmp', 'w')
            if file then
                file:write(string.format('%.3f', math.min(1, (phase - 1 + fraction) / phases)), '\t', text, '\n')
                file:close()
                LrFileUtils.delete(args.progress)
                LrFileUtils.move(args.progress .. '.tmp', args.progress)
            end
        end
        progress = {
            phase = function(n, count) phase, phases = n, count report(0) end,
            caption = function(caption) text = caption report(0) end,
            portion = function(done, total) report(total > 0 and done / total or 0) end,
        }
    end
    local result, message = fresh('Simple').run(photos, args.style or 'd', args.beauty or 'natural', args.slim == '1', progress,
        { dest = args.dest, import = args.import ~= '0', bits = tonumber(args.bits), people = args.people, peoplefile = args.peoplefile, chest = args.chest == '1' or nil,
          waist = args.waist == '1' or nil, bigeyes = args.bigeyes == '1' or nil, legs = args.legs == '1' or nil, light = args.light == '1' or nil }, args.denoise == '1', tweakOf(args))
    if not result then error(message, 0) end
    local created, denoised = {}, {}
    for original, new in pairs(result.created or {}) do created[#created + 1] = original .. ':' .. new end
    for _, id in ipairs(result.denoisedIds or {}) do denoised[#denoised + 1] = tostring(id) end
    return 'toned=' .. result.toned .. ' beautified=' .. result.beautified .. ' denoised=' .. result.denoised .. ' failed=' .. result.failed ..
        '\ncreated=' .. table.concat(created, ',') .. '\ndenoisedids=' .. table.concat(denoised, ',')
end

-- For development: run a Lua file inside Lightroom. The chunk gets (import, photos, args) and returns the text to print.
function actions.lua(args, photos)
    local chunk = assert(loadstring(LrFileUtils.readFile(assert(args.file, 'file is required')), 'probe'))
    return tostring(chunk(import, photos, args))
end

-- Make the given photos the selection (first one active), e.g. before a manual step in Lightroom.
function actions.select(args, photos)
    local others = {}
    for k = 2, #photos do others[#others + 1] = photos[k] end
    local catalog = LrApplication.activeCatalog()
    -- a photo can only be selected in a source that shows it, so switch to its folder first
    local folder = catalog:getFolderByPath(LrPathUtils.parent(photos[1]:getRawMetadata('path')))
    if folder then catalog:setActiveSources { folder } LrTasks.sleep(1) end
    catalog:setSelectedPhotos(photos[1], others)
    return 'selected=' .. #photos .. ' path=' .. tostring(photos[1]:getRawMetadata('path'))
end

function actions.beauty(args, photos)
    local options = { dest = args.dest, import = args.import ~= '0', bits = tonumber(args.bits) }
    for _, key in ipairs { 'blemish', 'smooth', 'undereye', 'eyes', 'teeth', 'slim', 'bigeyes', 'chest', 'waist', 'legs' } do options[key] = tonumber(args[key]) end
    local done, failed, log = fresh('Beauty').apply(photos, options)
    if not done then error(failed, 0) end
    return 'done=' .. done .. ' failed=' .. failed .. ' log=' .. tostring(log)
end

-- args: the key=value pairs of one command file. Returns the text for the .done file.
return function(args)
    local action = actions[args.action or '']
    if not action then error('unknown action: ' .. tostring(args.action), 0) end
    if args.action == 'catalog' or args.action == 'add' or args.action == 'beautypreview' or args.action == 'forgetstyle' then return action(args) end
    if args.action == 'lua' and not args.ids then return action(args, LrApplication.activeCatalog():getTargetPhotos()) end
    local photos = targetPhotos(args)
    if #photos == 0 then error('no photos selected', 0) end
    return action(args, photos)
end
