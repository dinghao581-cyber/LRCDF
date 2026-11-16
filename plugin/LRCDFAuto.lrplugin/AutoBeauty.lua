-- Menu command: ask for strengths, then beautify the selected photos into new stacked TIFFs.
local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
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
local Beauty = fresh 'Beauty'

local sliders = {
    { key = 'blemish', title = LOC("$$$/LRCDF/AutoBeauty/Blemishes=祛痘祛斑") },
    { key = 'smooth', title = LOC("$$$/LRCDF/AutoBeauty/EvenSkin=匀肤") },
    { key = 'undereye', title = LOC("$$$/LRCDF/AutoBeauty/UnderEye=淡化黑眼圈") },
    { key = 'eyes', title = LOC("$$$/LRCDF/AutoBeauty/BrightenEyes=提亮眼神") },
    { key = 'teeth', title = LOC("$$$/LRCDF/AutoBeauty/WhitenTeeth=牙齿美白") },
    { key = 'slim', title = LOC("$$$/LRCDF/AutoBeauty/SlimFace=瘦脸") },
    { key = 'bigeyes', title = LOC("$$$/LRCDF/AutoBeauty/EnlargeEyes=大眼") },
    { key = 'chest', title = LOC("$$$/LRCDF/AutoBeauty/FullerChest=丰胸") },
    { key = 'waist', title = LOC("$$$/LRCDF/AutoBeauty/SlimWaist=收腰") },
    { key = 'legs', title = LOC("$$$/LRCDF/AutoBeauty/LengthenLegs=长腿") },
}

local function askOptions(count)
    return LrFunctionContext.callWithContext('LRCDF beauty options', function(context)
        local prefs = LrPrefs.prefsForPlugin()
        local props = LrBinding.makePropertyTable(context)
        local f = LrView.osFactory()
        local rows = { bind_to_object = props, spacing = f:control_spacing() }
        for _, s in ipairs(sliders) do
            props[s.key] = prefs['beauty_' .. s.key] or config.beauty[s.key]
            rows[#rows + 1] = f:row {
                f:static_text { title = s.title, width = 90 },
                f:slider { min = 0, max = 150, integral = true, value = LrView.bind(s.key), width = 220 },
                f:static_text { title = LrView.bind(s.key), width = 40 },
            }
        end
        props.deep = prefs.beauty_deep == true
        rows[#rows + 1] = f:checkbox { title = LOC("$$$/LRCDF/AutoBeauty/MaxQuality=保留最大画质：16 位广色域 TIFF（文件大约是三倍）"), value = LrView.bind 'deep' }
        rows[#rows + 1] = f:static_text { title = LOC("$$$/LRCDF/AutoBeauty/StackHelp=会为每张照片生成一张新的 TIFF 并叠在原片上方，原片不会被改动。") }
        local result = LrDialogs.presentModalDialog {
            title = LOC("$$$/LRCDF/Title/Beauty=LRCDF 一键美颜"),
            actionVerb = LOC("$$$/LRCDF/AutoBeauty/RetouchCount=美颜 ^1 张照片", count),
            contents = f:column(rows),
        }
        if result ~= 'ok' then return nil end
        local options = {}
        for _, s in ipairs(sliders) do
            prefs['beauty_' .. s.key] = props[s.key]
            options[s.key] = props[s.key] / 100
        end
        prefs.beauty_deep = props.deep
        options.bits = props.deep and 16 or 8
        return options
    end)
end

local function run()
    local photos = LrApplication.activeCatalog():getTargetPhotos()
    if #photos == 0 then return end
    local options = askOptions(#photos)
    if not options then return end
    local scope = LrProgressScope { title = LOC("$$$/LRCDF/Title/Beauty=LRCDF 一键美颜") }
    local done, failed, log = Beauty.apply(photos, options, {
        localized = true,
        caption = function(text) scope:setCaption(text) end,
        portion = function(n, total) scope:setPortionComplete(n, total) end,
        canceled = function() return scope:isCanceled() end,
    })
    scope:done()
    if not done then
        if failed ~= LOC("$$$/LRCDF/Errors/Cancelled=已取消") then LrDialogs.message('LRCDF', failed, 'critical') end
    elseif failed > 0 then
        LrDialogs.message('LRCDF', LOC("$$$/LRCDF/AutoBeauty/Result=已完成 ^1 张，^2 张失败。日志：^3", done, failed, log), 'warning')
    end
end

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext('LRCDF auto beauty', function(context)
        LrDialogs.attachErrorDialogToFunctionContext(context)
        run()
    end)
end)
