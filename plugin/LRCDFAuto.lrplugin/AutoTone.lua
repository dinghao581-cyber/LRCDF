-- Menu command: ask for a style, then tone the selected photos (non-destructive).
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
local Tone = fresh 'Tone'

local function askOptions(count, referenceName)
    return LrFunctionContext.callWithContext('LRCDF options', function(context)
        local prefs = LrPrefs.prefsForPlugin()
        local props = LrBinding.makePropertyTable(context)
        props.style = prefs.style or config.styles[1].value
        props.strength = prefs.strength or 100
        props.group = prefs.group or 'time'
        props.follow = false
        local f = LrView.osFactory()
        local result = LrDialogs.presentModalDialog {
            title = LOC("$$$/LRCDF/Title/Tone=LRCDF 一键调色"),
            actionVerb = LOC("$$$/LRCDF/AutoTone/ApplyCount=应用到 ^1 张照片", count),
            contents = f:column {
                bind_to_object = props,
                spacing = f:control_spacing(),
                f:row {
                    f:static_text { title = LOC("$$$/LRCDF/Look=风格"), width = 60 },
                    f:popup_menu { items = config.styles, value = LrView.bind('style'), width = 320 },
                },
                f:row {
                    f:static_text { title = LOC("$$$/LRCDF/AutoTone/Strength=强度"), width = 60 },
                    f:slider { min = 0, max = 150, integral = true, value = LrView.bind('strength'), width = 200 },
                    f:static_text { title = LrView.bind('strength'), width = 40 },
                },
                f:row {
                    f:static_text { title = LOC("$$$/LRCDF/AutoTone/Group=整组一致"), width = 60 },
                    f:popup_menu { items = config.groups, value = LrView.bind('group'), width = 320 },
                },
                f:static_text { title = LOC("$$$/LRCDF/AutoTone/GroupHelp=整组一致：同一场的照片使用相同的风格参数，白平衡互相靠拢，曝光仍逐张判断。") },
                f:separator { fill_horizontal = 1 },
                f:checkbox { title = LOC("$$$/LRCDF/AutoTone/MatchReference=参考照片模式：其余照片跟随 ^1 现在的调色", referenceName), value = LrView.bind('follow'),
                    enabled = count > 1 },
                f:static_text { title = LOC("$$$/LRCDF/AutoTone/ReferenceHelp=先把一张调到满意并让它成为选中照片里最亮的那张（主选照片），再勾选此项。\n其余照片沿用它的风格参数和白平衡，曝光逐张判断；参考照片本身不变。此时上面的风格、强度、整组一致不起作用。") },
                f:static_text { title = LOC("$$$/LRCDF/AutoTone/ApplyHelp=只写入修改设置，可随时撤销或继续调整。") },
            },
        }
        if result ~= 'ok' then return nil end
        prefs.style, prefs.strength, prefs.group = props.style, props.strength, props.group
        return props.style, props.strength / 100, props.group, props.follow and count > 1
    end)
end

local function run()
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()
    if #photos == 0 then return end
    local active = catalog:getTargetPhoto()
    local style, strength, group, follow = askOptions(#photos, active and active:getFormattedMetadata('fileName') or LOC("$$$/LRCDF/AutoTone/ActivePhoto=主选照片"))
    if not style then return end
    local scope = LrProgressScope { title = LOC("$$$/LRCDF/Title/Tone=LRCDF 一键调色") }
    local applied, failed, log = Tone.apply(photos, style, strength, group, {
        localized = true,
        caption = function(text) scope:setCaption(text) end,
        portion = function(done, total) scope:setPortionComplete(done, total) end,
        canceled = function() return scope:isCanceled() end,
    }, follow and active or nil)
    scope:done()
    if not applied then
        if failed ~= LOC("$$$/LRCDF/Errors/Cancelled=已取消") then LrDialogs.message('LRCDF', failed, 'critical') end
    elseif failed > 0 then
        LrDialogs.message('LRCDF', LOC("$$$/LRCDF/AutoTone/Result=已应用 ^1 张，^2 张失败。日志：^3", applied, failed, log), 'warning')
    end
end

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext('LRCDF auto tone', function(context)
        LrDialogs.attachErrorDialogToFunctionContext(context)
        run()
    end)
end)
