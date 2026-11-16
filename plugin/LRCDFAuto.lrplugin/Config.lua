-- Where the model lives. ~/LRCDF is a link to the project folder on the external SSD.
-- Lightroom's Lua has no os.getenv
local LrPathUtils = import 'LrPathUtils'
local home = LrPathUtils.getStandardFilePath('home')
local LrFileUtils = import 'LrFileUtils'
local function under(path, ...)
    for _, part in ipairs { ... } do
        path = LrPathUtils.child(path, part)
    end
    return path
end

local project, python, work, app, appData
if WIN_ENV then
    local root = under(home, 'LRCDF')
    project = under(root, 'project')
    app = under(project, 'app', 'windows', 'LRCDF.exe')
    work = under(root, 'plugin_work')
    -- On Windows the SDK's appData is the Lightroom folder under Roaming/Adobe.
    local lightroomData = LrPathUtils.getStandardFilePath('appData')
    local roaming = LrPathUtils.parent(LrPathUtils.parent(lightroomData))
    appData = under(roaming, 'LRCDF')
    python = under(root, 'python', 'python.exe')
    if not LrFileUtils.exists(python) then python = under(project, '.venv', 'Scripts', 'python.exe') end
else
    project = home .. '/LRCDF/project'
    -- The all-in-one app brings its own Python (~/LRCDF/python, see packaging/); a developer's checkout has .venv
    python = home .. '/LRCDF/python/bin/python3'
    if not LrFileUtils.exists(python) then python = project .. '/.venv/bin/python' end
    -- Where the desktop app is: it writes its own path when it installs itself; otherwise the usual place
    app = home .. '/Applications/LRCDF.app'
    local told = home .. '/Library/Application Support/LRCDF/app_path.txt'
    if LrFileUtils.exists(told) then
        local path = (LrFileUtils.readFile(told) or ''):gsub('%s+$', '')
        if path ~= '' and LrFileUtils.exists(path) then app = path end
    end
    work = home .. '/LRCDF/plugin_work'
    appData = home .. '/Library/Application Support/LRCDF'
end

local function projectFile(...)
    local parts = { ... }
    return WIN_ENV and under(project, ...) or project .. '/' .. table.concat(parts, '/')
end

local function dataFile(name)
    return WIN_ENV and under(appData, name) or appData .. '/' .. name
end

return {
    python = python,
    predict = projectFile('scripts', 'predict.py'),
    beautify = projectFile('scripts', 'beautify.py'),
    beauty = { blemish = 100, smooth = 60, undereye = 50, eyes = 40, teeth = 40, slim = 0, bigeyes = 0, chest = 0, waist = 0, legs = 0, light = 0 },  -- default strengths, percent
    -- the simple dialog offers these instead of sliders (percent, like `beauty` above)
    beautyLevels = {
        light = { blemish = 100, smooth = 35, undereye = 30, eyes = 25, teeth = 30 },   -- per person only: men and children by default
        natural = { blemish = 100, smooth = 60, undereye = 50, eyes = 40, teeth = 40 },
        refined = { blemish = 120, smooth = 85, undereye = 70, eyes = 55, teeth = 55 },
    },
    slimLight = 60,  -- "轻微瘦脸" in the simple dialog
    -- how strong the app's shaping switches are (percent)
    shapes = { slim = 60, bigeyes = 70, chest = 70, waist = 70, legs = 80, light = 70 },   -- light: 匀光 (lrcdf/relight.py), a switch like the others
    previewSize = 300,  -- long edge of the style previews in the simple dialog
    cards = {  -- the simple dialog: one picture per look, in this order
        { value = 'none', title = '原片', note = '不调色' },
        { value = 'd', title = '自然清透', note = '白里透粉，明亮柔和' },
        { value = 'a', title = '明亮通透', note = '干净偏冷，肤色白皙' },
        { value = 'e', title = '韩系', note = '奶白低饱和，柔和' },
        { value = 'b', title = '柔和暖调', note = '温暖，低对比' },
        { value = 'c', title = '鲜艳浓郁', note = '色彩饱满' },
        { value = 'f', title = '港风', note = '浓郁暖调，胶片颗粒' },
    },
    beautyBits = 8,  -- bit depth of the beautified TIFF; 16 gives ~300MB files for a 60MP photo
    checkpoint = projectFile('runs', 'tone', 'tone.pt'),
    work = work,
    -- the desktop app (LRCDF.app) and the folder it shares with the plug-in. The folder is on the internal disk on
    -- purpose: an app needs the user's permission to read an external disk, and this way it never has to.
    app = app,
    appData = appData,
    previewBeauty = projectFile('scripts', 'preview_beauty.py'),
    previewServer = dataFile('beauty_server'),  -- requests to the preview process that stays loaded
    cull = projectFile('scripts', 'cull.py'),
    myStyles = dataFile('my_styles.json'),  -- the user's own looks (+ .lua list of cards)
    previewSettle = 0.2,  -- pause between settings arriving on the photo and rendering a look preview (the render reads the catalog, not the screen)
    settleSeconds = 1.5,  -- wait after clearing a photo so the preview shows the neutral look
    skinOnly = true,  -- the look's orange / yellow skin corrections go into a brush mask over the skin (Tone.forPhoto); false = whole picture, as before 2026-11-16
    gapMinutes = 20,  -- shots further apart than this start a new shoot
    groups = {
        { title = LOC("$$$/LRCDF/Groups/Time=按拍摄时间自动分组（间隔超过 20 分钟算新的一场）"), value = 'time' },
        { title = LOC("$$$/LRCDF/Groups/All=所有选中照片视为同一场"), value = 'all' },
        { title = LOC("$$$/LRCDF/Groups/None=关闭（每张独立判断）"), value = 'none' },
    },
    styles = {
        { title = LOC("$$$/LRCDF/AdvancedLook/A=A · 明亮通透（偏冷、肤色白皙、对比较强）"), value = 'a' },
        { title = LOC("$$$/LRCDF/AdvancedLook/B=B · 柔和暖调（略暖、低对比、肤色提亮）"), value = 'b' },
        { title = LOC("$$$/LRCDF/AdvancedLook/C=C · 鲜艳浓郁（色彩饱满、暗部提亮、冷暖中性）"), value = 'c' },
        { title = LOC("$$$/LRCDF/AdvancedLook/D=D · 自然清透（白里透粉、明亮柔和、偏东方审美）"), value = 'd' },
        { title = LOC("$$$/LRCDF/AdvancedLook/E=E · 韩系（明亮低饱和、肤色奶白、柔和对比）"), value = 'e' },
        { title = LOC("$$$/LRCDF/AdvancedLook/F=F · 港风（浓郁暖调、红唇肤色饱满、青色暗部、胶片颗粒）"), value = 'f' },
    },
}
