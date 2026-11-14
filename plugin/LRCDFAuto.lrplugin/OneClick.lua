-- Menu command "LRCDF 一键修图": pick a look from pictures of your own photo, pick how much retouching, done.
local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrColor = import 'LrColor'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils = import 'LrPathUtils'
local LrProgressScope = import 'LrProgressScope'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

-- Read a plug-in file from disk every time, so edits take effect without reloading the plug-in.
local function fresh(name)
    local path = LrPathUtils.child(_PLUGIN.path, name .. '.lua')
    return assert(loadstring(LrFileUtils.readFile(path), name))()
end

local config = fresh 'Config'
local Simple = fresh 'Simple'
local grey = LrColor(0.55, 0.55, 0.55)

local function ask(count, photo, previews)
    return LrFunctionContext.callWithContext('LRCDF one click', function(context)
        local prefs = LrPrefs.prefsForPlugin()
        local props = LrBinding.makePropertyTable(context)
        props.style = prefs.simple_style or 'd'
        props.level = prefs.simple_level or 'natural'
        props.slim = prefs.simple_slim == true
        props.denoise = prefs.simple_denoise == true
        local f = LrView.osFactory()

        local size = photo:getRawMetadata('croppedDimensions') or { width = 3, height = 2 }
        local long = 250
        local scale = long / math.max(size.width, size.height)
        local w, h = math.floor(size.width * scale), math.floor(size.height * scale)
        local function card(c)
            return f:column {
                spacing = 4,
                f:picture { value = previews[c.value], width = w, height = h, frame_width = 0 },
                f:radio_button { title = c.title, value = LrView.bind 'style', checked_value = c.value, font = '<system/bold>' },
                f:static_text { title = c.note, font = '<system/small>', text_color = grey, width = w },
            }
        end
        local perRow = w > h and 4 or 7
        local rows = { spacing = 14 }
        local row
        for n, c in ipairs(Simple.cards()) do
            if (n - 1) % perRow == 0 then
                row = { spacing = 14 }
                rows[#rows + 1] = row
            end
            row[#row + 1] = card(c)
        end
        for n = 1, #rows do rows[n] = f:row(rows[n]) end

        local result = LrDialogs.presentModalDialog {
            title = 'LRCDF 一键修图',
            actionVerb = count > 1 and ('修好这 ' .. count .. ' 张') or '修好这张',
            contents = f:column {
                bind_to_object = props,
                spacing = 14,
                f:static_text { title = '① 选一个喜欢的效果', font = '<system/bold>' },
                f:static_text { title = '下面是这张照片在每种风格下的样子，点图片下面的圆点选择。', font = '<system/small>', text_color = grey },
                f:column(rows),
                f:separator { fill_horizontal = 1 },
                f:static_text { title = '② 美颜', font = '<system/bold>' },
                f:row {
                    spacing = 18,
                    f:radio_button { title = '关闭', value = LrView.bind 'level', checked_value = 'off' },
                    f:radio_button { title = '自然（推荐）', value = LrView.bind 'level', checked_value = 'natural' },
                    f:radio_button { title = '精致', value = LrView.bind 'level', checked_value = 'refined' },
                    f:spacer { width = 24 },
                    f:checkbox { title = '轻微瘦脸', value = LrView.bind 'slim',
                        enabled = LrView.bind { key = 'level', transform = function(v) return v ~= 'off' end } },
                },
                f:static_text { title = '祛痘、匀肤、淡化黑眼圈、提亮眼神和牙齿，保留真实皮肤纹理。会生成一张新照片叠在原片上方。',
                    font = '<system/small>', text_color = grey },
                f:checkbox { title = 'AI 降噪（高感光、夜景照片建议勾选，每张多花约 10 秒）', value = LrView.bind 'denoise' },
                f:separator { fill_horizontal = 1 },
                f:static_text { title = '原片不会被改动，调色可随时撤销。想逐项微调：图库 → 增效工具额外信息 → 高级。',
                    font = '<system/small>', text_color = grey },
            },
        }
        if result ~= 'ok' then return nil end
        prefs.simple_style, prefs.simple_level, prefs.simple_slim = props.style, props.level, props.slim
        prefs.simple_denoise = props.denoise
        return props.style, props.level, props.slim and props.level ~= 'off', props.denoise
    end)
end

local function run()
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()
    if #photos == 0 then return end
    local active = catalog:getTargetPhoto() or photos[1]

    -- The desktop app does the talking when it is installed; the dialog below is the fallback.
    if LrFileUtils.exists(config.app) then
        LrFileUtils.createAllDirectories(config.appData)
        local ids = {}
        for _, photo in ipairs(photos) do ids[#ids + 1] = tostring(photo.localIdentifier) end
        local name = tostring(active:getFormattedMetadata('fileName')):gsub('[\\"]', '')
        local iso = 0   -- the highest ISO among the photos: the app suggests denoising from it
        for _, values in pairs(catalog:batchGetRawMetadata(photos, { 'isoSpeedRating' })) do
            iso = math.max(iso, tonumber(values.isoSpeedRating) or 0)
        end
        local path = LrPathUtils.child(config.appData, 'session.json')
        local file = assert(io.open(path .. '.tmp', 'w'))
        file:write('{"time":', os.time(), ',"active":', active.localIdentifier, ',"ids":[', table.concat(ids, ','),
            '],"name":"', name, '","iso":', iso, '}\n')
        file:close()
        LrFileUtils.delete(path)
        LrFileUtils.move(path .. '.tmp', path)
        LrTasks.execute('open -a "' .. config.app .. '"')
        return
    end

    local scope = LrProgressScope { title = 'LRCDF：正在用这张照片生成各风格预览（只需一次）' }
    local previews, message = Simple.previews(active, {
        caption = function(text) scope:setCaption(text) end,
        portion = function(n, total) scope:setPortionComplete(n, total) end,
    })
    scope:done()
    if not previews then
        LrDialogs.message('LRCDF', message or '预览生成失败。', 'critical')
        return
    end

    local style, level, slim, denoise = ask(#photos, active, previews)
    if not style then return end
    if style == 'none' and level == 'off' and not denoise then return end

    scope = LrProgressScope { title = 'LRCDF 一键修图' }
    local result, failure = Simple.run(photos, style, level, slim, {
        caption = function(text) scope:setCaption(text) end,
        portion = function(n, total) scope:setPortionComplete(n, total) end,
        canceled = function() return scope:isCanceled() end,
    }, nil, denoise)
    scope:done()
    if not result then
        if failure ~= '已取消' then LrDialogs.message('LRCDF', failure, 'critical') end
    elseif result.failed > 0 then
        LrDialogs.message('LRCDF', '有 ' .. result.failed .. ' 张没有处理成功。日志：' .. tostring(result.log), 'warning')
    else
        LrDialogs.showBezel('LRCDF：' .. #photos .. ' 张已修好')
    end
end

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext('LRCDF one click run', function(context)
        LrDialogs.attachErrorDialogToFunctionContext(context)
        run()
    end)
end)
