import Foundation

/// Every text the app shows, in one place. Views never carry a text of their own: they say `L.something`.
///
/// Simplified Chinese is the source language and is written here; the other languages are in
/// `app/Localizable.xcstrings`, under the same keys. `app/strings.py` brings that catalog in line with this file
/// (new keys in, comments updated, translations kept, vanished keys marked stale); `build.sh` runs it and compiles
/// the catalog into the app. The comment of each entry is all a translator sees of the screen: say where the text
/// appears and how much room it has. Keys are stable: change the wording, keep the key.
///
/// Not here: the names and notes of the looks and the progress lines during a run come from the Lightroom plug-in;
/// the installer's progress lines come from first_run.sh.
enum L {
    // MARK: Common
    static var close: String { String(localized: "common.close", defaultValue: "关闭", comment: "Button: closes a panel or dialog.") }
    static var cancel: String { String(localized: "common.cancel", defaultValue: "取消", comment: "Button: cancels a dialog.") }
    static var save: String { String(localized: "common.save", defaultValue: "保存", comment: "Button: saves (in the save-my-style dialog).") }
    static var goOn: String { String(localized: "common.continue", defaultValue: "继续", comment: "Button: carries on with a run that was paused or interrupted.") }
    static var back: String { String(localized: "common.back", defaultValue: "返回", comment: "Button on the failure screen: back to choosing a look.") }
    static var backToLightroom: String { String(localized: "common.backToLightroom", defaultValue: "回到 Lightroom", comment: "Button: brings Lightroom Classic to the front.") }
    static var explain: String { String(localized: "common.explain", defaultValue: "说明", comment: "Accessibility label of the small ? button that opens an explanation.") }

    // MARK: First screen
    static var appTitle: String { String(localized: "waiting.title", defaultValue: "LRCDF 一键修图", comment: "Large title of the first screen, shown before any photo has been handed over. LRCDF is the product name.") }
    static var waitingStep1: String { String(localized: "waiting.step1", defaultValue: "在 Lightroom 里选中要修的照片", comment: "First of three numbered steps on the first screen.") }
    static var waitingStep2: String { String(localized: "waiting.step2", defaultValue: "菜单 图库 → 增效工具额外信息 → 开始一键修图…", comment: "Second step on the first screen: the menu path inside Lightroom Classic. Use the menu names of Lightroom in the target language.") }
    static var waitingStep3: String { String(localized: "waiting.step3", defaultValue: "回到这里挑一个喜欢的效果", comment: "Third step on the first screen.") }
    static var notConnected: String { String(localized: "waiting.notConnected", defaultValue: "还没有连上 Lightroom Classic，请先打开它", comment: "Warning on the first screen when Lightroom Classic is not running.") }
    static var openLightroom: String { String(localized: "waiting.openLightroom", defaultValue: "打开 Lightroom", comment: "Button next to the not-connected warning.") }
    static var lastContinue: String { String(localized: "lastRun.continue", defaultValue: "继续修完", comment: "Button on the first screen: finish the photos left over from the last run.") }
    static var lastStop: String { String(localized: "lastRun.stop", defaultValue: "不修了", comment: "Button on the first screen: give up the photos left over from the last run.") }
    static var viewResults: String { String(localized: "run.viewResults", defaultValue: "查看成片", comment: "Button: look at the finished pictures next to the originals.") }
    static var lastUndo: String { String(localized: "lastRun.undo", defaultValue: "撤销上次修图", comment: "Button on the first screen: undo the previous retouching run.") }
    static var progressFirst: String { String(localized: "progress.first", defaultValue: "正在准备这张照片", comment: "Small progress line on the main screen, right after photos were sent from Lightroom: the photo on screen is being rendered. Keep it short.") }
    static func lastUnfinished(_ remaining: Int, _ done: Int) -> String {
        String(localized: "lastRun.unfinished", defaultValue: "上次有 \(remaining) 张还没修完（已完成 \(done) 张）", comment: "First screen: photos left over from the last run. %1 = photos still to do, %2 = photos done.")
    }
    static func lastDone(_ count: Int) -> String {
        String(localized: "lastRun.done", defaultValue: "上次修了 \(count) 张", comment: "First screen: how many photos the last run retouched.")
    }
    static func progressReading(_ done: Int, _ total: Int) -> String {
        String(localized: "progress.reading", defaultValue: "正在读取照片 \(done) / \(total)", comment: "Small progress line on the main screen: small pictures of the photos are being read. %1 = photos read so far, %2 = photos in all. Keep it short.")
    }
    static func progressLoading(_ done: Int, _ total: Int) -> String {
        String(localized: "progress.loading", defaultValue: "正在加载照片 \(done) / \(total)", comment: "Small progress line on the main screen: every photo is being prepared in the background (its original and the chosen look), so that clicking any photo shows it at once. %1 = photos ready, %2 = photos in all. Keep it short.")
    }
    static func progressLooks(_ done: Int, _ total: Int) -> String {
        String(localized: "progress.looks", defaultValue: "正在生成效果 \(done) / \(total)", comment: "Small progress line on the main screen: the remaining looks (styles) of all the photos are being rendered one by one in the background. %1 = looks ready, %2 = looks in all. Keep it short.")
    }
    static func progressChecking(_ done: Int, _ total: Int) -> String {
        String(localized: "progress.checking", defaultValue: "正在检查闭眼和虚焦 \(done) / \(total)", comment: "Small progress line on the main screen: the photos are being checked for closed eyes and missed focus. %1 = photos checked, %2 = photos in all. Keep it short.")
    }

    // MARK: Failure
    static var failedTitle: String { String(localized: "failed.title", defaultValue: "没有完成", comment: "Title of the screen shown when something went wrong.") }
    static var lightroomAway: String { String(localized: "error.lightroomAway", defaultValue: "没有连上 Lightroom。请先打开 Lightroom Classic。", comment: "Error: Lightroom Classic is not running.") }
    static var noAnswer: String { String(localized: "error.noAnswer", defaultValue: "Lightroom 没有回应，请回到 Lightroom 看看是否有对话框挡住了。", comment: "Error: Lightroom did not answer in time.") }
    static var noPreview: String { String(localized: "error.noPreview", defaultValue: "没有拿到这张照片的预览。", comment: "Error: the preview pictures of a photo could not be made.") }
    static func failedKeep(_ reason: String) -> String {
        String(localized: "failed.keep", defaultValue: "\(reason)\n已经做完的部分都在，可以点“继续”接着做。", comment: "Failure screen when a run broke off. %@ = the error message; the second paragraph refers to the button common.continue.")
    }

    // MARK: Main screen: photos
    static var railHint: String { String(localized: "photos.railHint", defaultValue: "点一张看它的效果\n所选设置用于全部", comment: "Small hint under the strip of photos on the left of the main screen. Two short lines.") }
    static var reviewRailHint: String { String(localized: "review.railHint", defaultValue: "点一张看它\n修图前后的样子", comment: "Small hint under the strip of photos on the review screen. Two short lines.") }
    static var flagEyes: String { String(localized: "flag.eyes", defaultValue: "闭眼", comment: "Tiny badge on a photo thumbnail: someone's eyes are closed. Keep it very short.") }
    static var flagBlur: String { String(localized: "flag.blur", defaultValue: "虚焦", comment: "Tiny badge on a photo thumbnail: out of focus. Keep it very short.") }
    static var flagOver: String { String(localized: "flag.over", defaultValue: "过曝", comment: "Tiny badge on a photo thumbnail: face overexposed. Keep it very short.") }
    static var flagDup: String { String(localized: "flag.dup", defaultValue: "重复", comment: "Tiny badge on a photo thumbnail: near-duplicate of its neighbour. Keep it very short.") }
    static var loadingTitle: String { String(localized: "loading.title", defaultValue: "正在用这张照片试每一种效果", comment: "Title over the photo while the looks of another photo are being rendered.") }
    static var loadingNote: String { String(localized: "loading.note", defaultValue: "大约 20 秒，看过的照片下次直接打开", comment: "Line under the loading title.") }
    static var previous: String { String(localized: "photos.previous", defaultValue: "上一张", comment: "Accessibility label of the ‹ button: previous photo.") }
    static var next: String { String(localized: "photos.next", defaultValue: "下一张", comment: "Accessibility label of the › button: next photo.") }
    static func appliesToAll(_ count: Int) -> String {
        String(localized: "photos.appliesToAll", defaultValue: "设置会用于全部 \(count) 张", comment: "Top row, next to the photo counter, when several photos were handed over: the settings apply to all of them.")
    }
    static func position(_ index: Int, _ count: Int) -> String {
        String(localized: "photos.position", defaultValue: "\(index) / \(count)", comment: "Photo counter in the top row: photo %1 of %2.")
    }

    // MARK: Main screen: the picture
    static var original: String { String(localized: "compare.original", defaultValue: "原片", comment: "Small label on the left half of the before/after picture: the photo as shot.") }
    static var divider: String { String(localized: "compare.divider", defaultValue: "对比分隔线", comment: "Accessibility label of the draggable before/after divider.") }
    static var zoomOut: String { String(localized: "zoom.out", defaultValue: "缩小", comment: "Accessibility label of the − button.") }
    static var zoomIn: String { String(localized: "zoom.in", defaultValue: "放大", comment: "Accessibility label of the + button.") }
    static var fit: String { String(localized: "zoom.fit", defaultValue: "适合窗口", comment: "Button between − and +: shows the whole picture. Shown while the picture is not zoomed.") }
    static var toFace: String { String(localized: "zoom.toFace", defaultValue: "放大看脸", comment: "Button: zooms in on the first face.") }
    static var nextFace: String { String(localized: "zoom.nextFace", defaultValue: "下一张脸", comment: "Same button once zoomed on a face: go to the next face.") }
    static var wholePicture: String { String(localized: "zoom.whole", defaultValue: "看整张", comment: "Same button on the last face: back to the whole picture.") }
    static var zoomHelp: String { String(localized: "zoom.help", defaultValue: "双指捏合或滚轮缩放，放大后拖动照片移动，双击放大或还原", comment: "Hover help of the zoom control: the gestures.") }
    static func pendingLabel(_ look: String) -> String {
        String(localized: "compare.pending", defaultValue: "\(look)，美颜预览生成中", comment: "Small label on the right half of the picture while the retouching preview is being made. %@ = name of the look.")
    }
    static func retouchedLabel(_ look: String) -> String {
        String(localized: "compare.retouched", defaultValue: "\(look) + 美颜", comment: "Small label on the right half of the picture: look plus retouching. %@ = name of the look.")
    }

    // MARK: Main screen: looks
    static var pageLook: String { String(localized: "page.look", defaultValue: "效果", comment: "Tab of the bottom bar in a narrow window: the colour looks. One short word.") }
    static var beauty: String { String(localized: "beauty.title", defaultValue: "美颜", comment: "Section heading in the inspector and tab of the bottom bar: skin retouching. One short word.") }
    static var pageMore: String { String(localized: "page.more", defaultValue: "更多", comment: "Tab of the bottom bar in a narrow window: remaining switches. One short word.") }
    static var deleteStyle: String { String(localized: "look.delete", defaultValue: "删除这个风格", comment: "Button / context menu on one of the user's own looks.") }
    static var saveStyle: String { String(localized: "look.saveMine", defaultValue: "存为我的风格", comment: "Last card in the row of looks, and the title of the dialog it opens: store the current Lightroom edit as an own look.") }
    static var saveStyleNote: String { String(localized: "look.saveMine.note", defaultValue: "照你调好的来", comment: "Second line of that card.") }
    static var saveStyleText: String { String(localized: "look.saveMine.text", defaultValue: "先在 Lightroom 里把左边选中的这张照片调到你满意的样子，再回到这里点“保存”。\n之后它会成为一张新的效果卡片，对别的照片也会按你的调法来，并且照样根据每张照片自动调整曝光和白平衡。\n这次带过来的照片里，其他已经调过的也会一起用来学习：调过的越多，学得越准（6 张以上最好）。", comment: "Explanation in the save-my-style dialog. Three paragraphs.") }
    static var saveStyleField: String { String(localized: "look.saveMine.placeholder", defaultValue: "给它起个名字，例如：我的日系", comment: "Placeholder of the name field in the save-my-style dialog.") }
    static var saveStyleBusy: String { String(localized: "look.saveMine.busy", defaultValue: "正在学习你的调法…", comment: "Shown in the dialog while the look is being learnt.") }
    static var defaultStyleName: String { String(localized: "look.saveMine.defaultName", defaultValue: "我的风格", comment: "Name given to an own look when the user typed none.") }
    static var keepOriginal: String { String(localized: "look.none.note", defaultValue: "保持原片的颜色", comment: "Line under the look's name when the look is the unedited original.") }
    static var darker: String { String(localized: "tweak.darker", defaultValue: "暗", comment: "Left end of the brightness slider. As short as possible, ideally one word.") }
    static var brighter: String { String(localized: "tweak.brighter", defaultValue: "亮", comment: "Right end of the brightness row. As short as possible.") }
    static var cooler: String { String(localized: "tweak.cooler", defaultValue: "冷", comment: "Left end of the colour-temperature row. As short as possible.") }
    static var warmer: String { String(localized: "tweak.warmer", defaultValue: "暖", comment: "Right end of the colour-temperature row. As short as possible.") }
    static var pinker: String { String(localized: "tweak.pinker", defaultValue: "粉", comment: "Top of the white-balance colour wheel: towards pink / magenta. As short as possible.") }
    static var greener: String { String(localized: "tweak.greener", defaultValue: "绿", comment: "Bottom of the white-balance colour wheel: towards green. As short as possible.") }
    static var pageTone: String { String(localized: "page.tone", defaultValue: "色盘", comment: "Tab of the bottom bar in a narrow window: the colour wheels. One short word.") }
    static var wheelBalance: String { String(localized: "wheel.balance", defaultValue: "白平衡", comment: "First of three segments above the colour wheel: white balance. Short.") }
    static var wheelShadows: String { String(localized: "wheel.shadows", defaultValue: "阴影", comment: "Second segment above the colour wheel: a colour for the dark parts of the picture. Short.") }
    static var wheelHighlights: String { String(localized: "wheel.highlights", defaultValue: "高光", comment: "Third segment above the colour wheel: a colour for the bright parts of the picture. Short.") }
    static var wheelWarmth: String { String(localized: "wheel.warmth", defaultValue: "冷暖", comment: "Label of a number under the white-balance wheel: cool to warm, -100 to +100. Short.") }
    static var wheelTint: String { String(localized: "wheel.tint", defaultValue: "绿粉", comment: "Label of a number under the white-balance wheel: green to pink, -100 to +100. Short.") }
    static var wheelHue: String { String(localized: "wheel.hue", defaultValue: "色相", comment: "Label of a number under the shadows / highlights wheel: hue in degrees. Short.") }
    static var wheelAmount: String { String(localized: "wheel.amount", defaultValue: "浓度", comment: "Label of a number under the shadows / highlights wheel: how strong the colour is, 0 to 100. Short.") }
    static var paler: String { String(localized: "tweak.paler", defaultValue: "淡", comment: "Left end of the colour-strength row (less saturated). As short as possible.") }
    static var richer: String { String(localized: "tweak.richer", defaultValue: "浓", comment: "Right end of the colour-strength row (more saturated). As short as possible.") }

    // MARK: Main screen: retouching
    static var levelOff: String { String(localized: "level.off", defaultValue: "不美颜", comment: "Retouching level, one of four segments in a row: no skin retouching. Short.") }
    static var levelAuto: String { String(localized: "level.auto", defaultValue: "自动", comment: "Retouching level: chosen automatically per face. Short.") }
    static var levelNatural: String { String(localized: "level.natural", defaultValue: "自然", comment: "Retouching level, also a per-person choice: natural. Short.") }
    static var levelRefined: String { String(localized: "level.refined", defaultValue: "精致", comment: "Retouching level, also a per-person choice: the strongest. Short.") }
    static var levelOffNote: String { String(localized: "level.off.note", defaultValue: "只调色，不动皮肤", comment: "Line under the level row when 'no retouching' is chosen.") }
    static var levelAutoNote: String { String(localized: "level.auto.note", defaultValue: "每张脸各选一档：修不过头的前提下尽量干净（推荐）", comment: "Line under the level row when 'automatic' is chosen.") }
    static var levelNaturalNote: String { String(localized: "level.natural.note", defaultValue: "看不出修过", comment: "Line under the level row when 'natural' is chosen.") }
    static var levelRefinedNote: String { String(localized: "level.refined.note", defaultValue: "更干净，适合特写", comment: "Line under the level row when 'refined' is chosen.") }
    static var personFollow: String { String(localized: "person.follow", defaultValue: "跟随", comment: "Under a person's face: they get the general level. One short word.") }
    static var personLight: String { String(localized: "person.light", defaultValue: "轻", comment: "Under a person's face: light retouching. One short word.") }
    static var personOff: String { String(localized: "person.off", defaultValue: "不修", comment: "Under a person's face: not retouched. One short word.") }
    static var peopleHelp: String { String(localized: "person.help", defaultValue: "每个人可以单独设置：点头像，在 跟随、轻、自然、精致、不修 之间切换。跟随 = 用上面的整体档位。男士和小孩默认是 轻；你改过的人，下次会记住。", comment: "Explanation of the per-person faces (opens from the ? button). Mentions the five choices by name: keep them the same as person.follow, person.light, level.natural, level.refined, person.off.") }
    static var shapeSlim: String { String(localized: "shape.slim", defaultValue: "瘦脸", comment: "Shaping chip: slimmer face. Short.") }
    static var shapeEyes: String { String(localized: "shape.eyes", defaultValue: "大眼", comment: "Shaping chip: larger eyes. Short.") }
    static var shapeWaist: String { String(localized: "shape.waist", defaultValue: "收腰", comment: "Shaping chip: narrower waist. Short.") }
    static var shapeChest: String { String(localized: "shape.chest", defaultValue: "丰胸", comment: "Shaping chip: fuller chest. Short.") }
    static var shapeLegs: String { String(localized: "shape.legs", defaultValue: "长腿", comment: "Shaping chip: longer legs. Short.") }
    static var shapeLight: String { String(localized: "shape.light", defaultValue: "匀光", comment: "Chip: evens out side light on the face. Short.") }
    static var shapingHelp: String { String(localized: "shape.help", defaultValue: "塑形：点亮的才会做。身体侧着、被手挡住、或腿没拍全时，对应的那一项会自动跳过。\n匀光：把侧光造成的一边亮一边暗匀开一些，只动明暗，不动皮肤纹理；鼻影、帽檐这类有边缘的影子不会去掉。", comment: "Explanation of the six chips (opens from the ? button). Two paragraphs.") }
    static var best: String { String(localized: "quality.best", defaultValue: "保留最大画质", comment: "Switch: keep the most picture quality (16-bit wide-gamut output).") }
    static var bestHelp: String { String(localized: "quality.best.help", defaultValue: "保留最大画质：成片存成 16 位广色域（ProPhoto RGB），适合还要继续精修或大幅输出；每张约 300MB，是平时的三倍多。关闭时是 8 位 sRGB，适合直接交付。", comment: "Explanation of the quality switch (opens from the ? button).") }
    static var denoise: String { String(localized: "denoise.title", defaultValue: "AI 降噪", comment: "Switch: run Lightroom's AI Denoise first.") }
    static var denoiseNote: String { String(localized: "denoise.note", defaultValue: "夜景、高感光的照片建议打开。每张多花约 10 秒。", comment: "Note under the denoise switch.") }
    static var retouchOne: String { String(localized: "retouch.one", defaultValue: "修好这张", comment: "The main button when one photo will be retouched.") }
    static var safeNote: String { String(localized: "retouch.safeNote", defaultValue: "原片不会被改动，修完可以一键撤销。", comment: "Reassurance under the main button.") }
    static func noisyNote(_ iso: Int) -> String {
        String(localized: "denoise.noisyNote", defaultValue: "这组照片感光度较高（ISO \(iso)），建议打开。每张多花约 10 秒。", comment: "Note under the denoise switch when the photos were shot at high ISO. %lld = the ISO value.")
    }
    static func skipFlagged(_ count: Int) -> String {
        String(localized: "retouch.skipFlagged", defaultValue: "跳过 \(count) 张有问题的（闭眼、虚焦、过曝、重复）", comment: "Switch above the main button: leave out the photos the selection help marked. Names the four marks (flag.eyes, flag.blur, flag.over, flag.dup).")
    }
    static func retouchMany(_ count: Int) -> String {
        String(localized: "retouch.many", defaultValue: "修好这 \(count) 张", comment: "The main button when several photos will be retouched (count is 2 or more).")
    }

    // MARK: While Lightroom works, and afterwards
    static var workingOne: String { String(localized: "working.one", defaultValue: "正在修这张照片", comment: "Title of the progress card for one photo.") }
    static var handingOver: String { String(localized: "working.handingOver", defaultValue: "正在交给 Lightroom…", comment: "Progress line at the very start of a run.") }
    static var rememberingBefore: String { String(localized: "working.rememberingBefore", defaultValue: "正在记下修图前的样子…", comment: "Progress line: saving how the photos looked before.") }
    static var retrying: String { String(localized: "working.retrying", defaultValue: "有照片没成功，再试一次…", comment: "Progress line: some photos failed and are tried once more.") }
    static var pause: String { String(localized: "working.pause", defaultValue: "暂停", comment: "Button on the progress card.") }
    static var pauseAsked: String { String(localized: "working.pauseAsked", defaultValue: "做完手上这几张就暂停…", comment: "The pause button after it was pressed: the photos in hand are finished first.") }
    static var pausedTitle: String { String(localized: "paused.title", defaultValue: "已暂停", comment: "Title of the card while a run is paused.") }
    static var stopHere: String { String(localized: "paused.stop", defaultValue: "到此为止", comment: "Button while paused: keep what is done, give up the rest.") }
    static var undoneTitle: String { String(localized: "finished.undone", defaultValue: "已撤销", comment: "Title after a run was undone.") }
    static var finishedOne: String { String(localized: "finished.one", defaultValue: "修好了", comment: "Title after one photo was retouched.") }
    static var tonedNote: String { String(localized: "finished.toned", defaultValue: "调色已经写进 Lightroom。", comment: "Line after a run that only changed colour.") }
    static var stackedNote: String { String(localized: "finished.stacked", defaultValue: "成片已经在 Lightroom 里，叠在原片上方。", comment: "Line after a run that made retouched pictures.") }
    static var again: String { String(localized: "finished.again", defaultValue: "换个效果再来", comment: "Button: back to choosing, to try another look.") }
    static var undoRun: String { String(localized: "run.undo", defaultValue: "撤销这次修图", comment: "Button: undo this retouching run.") }
    static var undoing: String { String(localized: "undo.busy", defaultValue: "正在撤销…", comment: "Notice while a run is being undone.") }
    static var undoneNote: String { String(localized: "undo.done", defaultValue: "已撤销，照片回到修图前的样子。", comment: "Notice after undoing a run that only changed colour.") }
    static var resultLabel: String { String(localized: "review.result", defaultValue: "成片", comment: "Small label on the right half of the before/after picture on the review screen: the finished picture.") }
    static var fetchingResult: String { String(localized: "review.fetching", defaultValue: "正在取这张成片…", comment: "Shown while a finished picture is being fetched from Lightroom.") }
    static var reviewDone: String { String(localized: "review.done", defaultValue: "看完了", comment: "Main button of the review screen: finished looking.") }
    static func workingMany(_ count: Int) -> String {
        String(localized: "working.many", defaultValue: "正在修 \(count) 张照片", comment: "Title of the progress card for several photos.")
    }
    static func doneOf(_ done: Int, _ total: Int, _ step: String) -> String {
        String(localized: "working.doneOf", defaultValue: "已完成 \(done) / \(total)，\(step)", comment: "Progress line: %1 of %2 photos done, then %3 = what Lightroom is doing right now (text from the plug-in).")
    }
    static func pausedNote(_ done: Int, _ remaining: Int) -> String {
        String(localized: "paused.note", defaultValue: "已完成 \(done) 张，还剩 \(remaining) 张。关掉程序也没关系，下次打开可以接着修。", comment: "Text of the paused card. %1 = photos done, %2 = photos left.")
    }
    static func finishedMany(_ count: Int) -> String {
        String(localized: "finished.many", defaultValue: "\(count) 张已修好", comment: "Title after several photos were retouched.")
    }
    static func failedCount(_ count: Int) -> String {
        String(localized: "finished.failedCount", defaultValue: "有 \(count) 张没有成功", comment: "On the finished card: some photos did not work.")
    }
    static func retryCount(_ count: Int) -> String {
        String(localized: "finished.retry", defaultValue: "再试这 \(count) 张", comment: "Button next to it: try those photos again.")
    }
    static func undoneRejects(_ count: Int) -> String {
        String(localized: "undo.doneWithRejects", defaultValue: "已撤销。调色已还原，\(count) 张美颜成片被标记为“排除”，在 Lightroom 里用 照片 → 删除排除的照片 可以一次清掉。", comment: "Notice after undoing a run that made retouched pictures. %lld = number of pictures. Names a Lightroom menu path (Photo → Delete Rejected Photos): use Lightroom's menu names in the target language.")
    }
    static func undoFailed(_ reason: String) -> String {
        String(localized: "undo.failed", defaultValue: "撤销没有完成：\(reason)", comment: "Notice when undoing did not work. %@ = the error message.")
    }

    // MARK: First-run installer (all-in-one app)
    static var setupPreparing: String { String(localized: "setup.preparing", defaultValue: "正在准备…", comment: "First progress line of the installer.") }
    static var setupTitle: String { String(localized: "setup.title", defaultValue: "第一次打开，正在安装", comment: "Title of the installer panel on first launch.") }
    static var setupOffline: String { String(localized: "setup.offline", defaultValue: "全部在这台电脑上完成，不需要联网。", comment: "Line in the installer panel.") }
    static var setupDone: String { String(localized: "setup.done", defaultValue: "安装好了", comment: "Title when the installer has finished.") }
    static var setupStep1: String { String(localized: "setup.step1", defaultValue: "打开 Lightroom Classic（已经开着的话，请退出再打开一次）。", comment: "First of three numbered steps after installing.") }
    static var setupStep2: String { String(localized: "setup.step2", defaultValue: "在图库里选中要修的照片。", comment: "Second step after installing.") }
    static var understood: String { String(localized: "setup.understood", defaultValue: "知道了", comment: "Button that closes the installer panel.") }
    static var setupFailed: String { String(localized: "setup.failed", defaultValue: "安装没有完成", comment: "Title when the installer failed (a log excerpt follows).") }

    // MARK: Updates (line at the bottom of the window, Settings, app menu)
    static var updateChecking: String { String(localized: "update.checking", defaultValue: "正在检查更新…", comment: "Line at the bottom of the window while looking for a new version.") }
    static var updateNone: String { String(localized: "update.none", defaultValue: "已经是最新版本", comment: "Line after a manual check that found nothing new.") }
    static func updateAvailable(_ version: String, _ size: String) -> String {
        String(localized: "update.available", defaultValue: "有新版本 \(version)，需要下载 \(size)", comment: "Line when a new version exists and is large enough to ask first. First %@ = version number, second %@ = download size such as 210 MB.")
    }
    static var updateDownload: String { String(localized: "update.download", defaultValue: "下载", comment: "Button on the update line: start downloading. One short word.") }
    static func updateDownloading(_ version: String, _ percent: Int) -> String {
        String(localized: "update.downloading", defaultValue: "正在下载新版本 \(version)　\(percent)%", comment: "Line while an update downloads. %@ = version number, %lld = per cent done.")
    }
    static func updateReady(_ version: String) -> String {
        String(localized: "update.ready", defaultValue: "新版本 \(version) 已准备好，重新打开后生效", comment: "Line when an update is downloaded and waits to be installed. %@ = version number.")
    }
    static var updateInstall: String { String(localized: "update.install", defaultValue: "现在重开", comment: "Button on the update line: quit, install and open the app again. Short.") }
    static var updateLater: String { String(localized: "update.later", defaultValue: "以后", comment: "Button on the update line: hide it for now. One short word.") }
    static var updateInstalling: String { String(localized: "update.installing", defaultValue: "正在安装，马上回来…", comment: "Line shown for a moment before the app quits to install an update.") }
    static var updateUnreachable: String { String(localized: "update.unreachable", defaultValue: "没能连上更新服务器，稍后再试", comment: "Line after a manual check when the server could not be reached or its answer could not be trusted.") }
    static var updateBroken: String { String(localized: "update.broken", defaultValue: "下载的更新不完整，已放弃。下次会重新下载", comment: "Line when a downloaded update failed its integrity check.") }
    static var updateNotInstalled: String { String(localized: "update.notInstalled", defaultValue: "这份 LRCDF 不是用一体版安装的，不能自动更新", comment: "Line after a manual check on a copy that was not installed by the all-in-one app.") }
    static var updateTooNew: String { String(localized: "update.tooNew", defaultValue: "有新版本，但这一版 LRCDF 太旧，不能自动更新，请到下载页获取", comment: "Line when the update feed is of a newer kind than this app understands.") }
    static var updateOpenPage: String { String(localized: "update.openPage", defaultValue: "打开下载页", comment: "Button on the update line: opens the download page in the browser.") }
    static var updateAuto: String { String(localized: "update.auto", defaultValue: "自动检查并安装更新", comment: "Switch in Settings.") }
    static var updateAutoNote: String { String(localized: "update.autoNote", defaultValue: "打开 LRCDF 时检查一次，之后大约每天一次。只下载一个写着版本号的公开小文件，不发送任何关于你、照片或目录的内容。关掉后，LRCDF 自己不再联网；随附的 Google MediaPipe 库在做人脸/人体检测时仍可能向 Google 发送使用统计（不含照片），详见隐私政策。", comment: "Explanation under the switch in Settings. Must stay true to the privacy policy: translate faithfully.") }
    static var updateCheckNow: String { String(localized: "update.checkNow", defaultValue: "现在检查更新", comment: "Button in Settings and item in the app menu.") }
    static var updateGoBack: String { String(localized: "update.goBack", defaultValue: "退回上一个版本", comment: "Button in Settings: undo the last update.") }

    static var licences: String { String(localized: "licences.title", defaultValue: "许可与致谢", comment: "Button in Settings and title of the window that shows the licence texts.") }

    // MARK: Rights: launch prompt, card, break reminder. Wording reviewed elsewhere: translate faithfully, do not adapt the legal content.
    static var rightsMenu: String { String(localized: "rights.menu", defaultValue: "了解您拥有的权利…", comment: "Help menu item that opens the rights card.") }
    static var rightsQuestion: String { String(localized: "rights.question", defaultValue: "您是否正在剥削性工作中？", comment: "Question of the prompt shown at launch.") }
    static var rightsInvite: String { String(localized: "rights.invite", defaultValue: "了解您拥有的权利。", comment: "Line under the launch question.") }
    static var rightsOpen: String { String(localized: "rights.open", defaultValue: "了解我的权利", comment: "Main button of the launch prompt: opens the rights card.") }
    static var rightsDismiss: String { String(localized: "rights.dismiss", defaultValue: "没有，继续", comment: "Other button of the launch prompt.") }
    static var rightsDontAsk: String { String(localized: "rights.dontAsk", defaultValue: "不再提示", comment: "Checkbox in the launch prompt.") }
    static var rightsTitle: String { String(localized: "rights.title", defaultValue: "您拥有的权利", comment: "Title of the rights card.") }
    static var rightsDisclaimer: String { String(localized: "rights.disclaimer", defaultValue: "以下为一般性信息，不是法律意见，依据澳大利亚联邦法律和首都领地（堪培拉，ACT）的规定。如果你在其他地方工作，当地法律可能不同。", comment: "First paragraph of the rights card.") }
    static var rightsPayTitle: String { String(localized: "rights.pay.title", defaultValue: "报酬", comment: "Rights card, heading 1.") }
    static var rightsPayBody: String { String(localized: "rights.pay.body", defaultValue: "雇员有权获得至少法定最低工资，以及按所适用的行业裁定（award）或协议应得的加班、周末和公共假日待遇。如果“无薪”做的是真正的工作，而不是很短的、合理的评估，通常是违法的。", comment: "Rights card, text 1.") }
    static var rightsHoursTitle: String { String(localized: "rights.hours.title", defaultValue: "工时与休息", comment: "Rights card, heading 2.") }
    static var rightsHoursBody: String { String(localized: "rights.hours.body", defaultValue: "全职每周标准工时是 38 小时；超出的部分必须合理，你有权拒绝不合理的加班。你也有权享有休息和假期（年假、病假等，按雇用类型而定）。", comment: "Rights card, text 2.") }
    static var rightsShamTitle: String { String(localized: "rights.sham.title", defaultValue: "“假承包”", comment: "Rights card, heading 3: sham contracting.") }
    static var rightsShamBody: String { String(localized: "rights.sham.body", defaultValue: "把雇员硬说成“自由职业者/承包人”来逃避工资和福利，可能构成假承包（sham contracting），是违法的。拿不准自己的身份，可以免费咨询公平工作监察专员。", comment: "Rights card, text 3.") }
    static var rightsCreditTitle: String { String(localized: "rights.credit.title", defaultValue: "署名与作品", comment: "Rights card, heading 4: attribution and moral rights.") }
    static var rightsCreditBody: String { String(localized: "rights.credit.body", defaultValue: "作者对自己的作品享有精神权利：被署名，作品不被歪曲。雇用关系里版权通常归雇主，但精神权利仍在你手上，除非你书面同意放弃。", comment: "Rights card, text 4.") }
    static var rightsSafetyTitle: String { String(localized: "rights.safety.title", defaultValue: "安全与健康", comment: "Rights card, heading 5.") }
    static var rightsSafetyBody: String { String(localized: "rights.safety.body", defaultValue: "雇主有责任在合理可行的范围内提供安全、健康的工作环境，包括合理的工作量和休息。长时间连续工作造成的伤害，也是工作安全问题。", comment: "Rights card, text 5.") }
    static var rightsReprisalTitle: String { String(localized: "rights.reprisal.title", defaultValue: "不被报复", comment: "Rights card, heading 6: protection from adverse action.") }
    static var rightsReprisalBody: String { String(localized: "rights.reprisal.body", defaultValue: "你行使自己的工作权利（提问、投诉、请假）时，雇主不能因此解雇你、削减工时或区别对待。", comment: "Rights card, text 6.") }
    static var rightsForcedTitle: String { String(localized: "rights.forced.title", defaultValue: "强迫劳动", comment: "Rights card, heading 7.") }
    static var rightsForcedBody: String { String(localized: "rights.forced.body", defaultValue: "以债务、威胁或暴力逼人工作是刑事犯罪，与你是什么身份或签证无关；扣押护照或证件可能构成犯罪，也是强迫劳动的警示信号。遇到危险请立刻拨打 000。", comment: "Rights card, text 7. 000 is the Australian emergency number.") }
    static var rightsVisaTitle: String { String(localized: "rights.visa.title", defaultValue: "签证持有人", comment: "Rights card, heading 8.") }
    static var rightsVisaBody: String { String(localized: "rights.visa.body", defaultValue: "持工作、学生或其他签证的人，同样享有基本的工作权利，向监察专员求助本身不会取消你的签证（只有内政部能取消签证），符合条件的人还有举报保护。具体情况请向官方或法律援助确认。", comment: "Rights card, text 8.") }
    static var rightsWhere: String { String(localized: "rights.help.title", defaultValue: "在哪里求助", comment: "Rights card: heading of the list of places to get help.") }
    static var helpFWO: String { String(localized: "rights.help.fwo", defaultValue: "公平工作监察专员（Fair Work Ombudsman）", comment: "Name of an Australian body; keep the English name in brackets.") }
    static var helpFWOHow: String { String(localized: "rights.help.fwo.how", defaultValue: "免费咨询，可使用翻译服务。电话 13 13 94", comment: "What that body offers and its phone number.") }
    static var helpFWC: String { String(localized: "rights.help.fwc", defaultValue: "公平工作委员会（Fair Work Commission）", comment: "Name of an Australian body; keep the English name in brackets.") }
    static var helpFWCHow: String { String(localized: "rights.help.fwc.how", defaultValue: "不公平解雇、欺凌等申请", comment: "What that body handles.") }
    static var helpWorkSafeHow: String { String(localized: "rights.help.worksafe.how", defaultValue: "堪培拉的工作安全与健康", comment: "What WorkSafe ACT covers (Canberra).") }
    static var helpLegalAid: String { String(localized: "rights.help.legalaid", defaultValue: "ACT 法律援助（Legal Aid ACT）", comment: "Name of an Australian body; keep the English name in brackets.") }
    static var helpLegalAidHow: String { String(localized: "rights.help.legalaid.how", defaultValue: "免费或低价法律帮助。求助热线 1300 654 314", comment: "What that body offers and its phone number.") }
    static var helpHRC: String { String(localized: "rights.help.hrc", defaultValue: "ACT 人权委员会", comment: "Name of the ACT Human Rights Commission.") }
    static var helpHRCHow: String { String(localized: "rights.help.hrc.how", defaultValue: "歧视和骚扰投诉", comment: "What that body handles.") }
    static var helpAFP: String { String(localized: "rights.help.afp", defaultValue: "澳大利亚联邦警察（AFP）", comment: "Name of an Australian body; keep the abbreviation in brackets.") }
    static var helpAFPHow: String { String(localized: "rights.help.afp.how", defaultValue: "强迫劳动、人口贩运举报。电话 131 237；紧急情况拨 000", comment: "What to report there, and phone numbers.") }
    static var helpTIS: String { String(localized: "rights.help.tis", defaultValue: "笔译和口译服务（TIS National）", comment: "Name of the national translating and interpreting service; keep the English name in brackets.") }
    static var helpTISHow: String { String(localized: "rights.help.tis.how", defaultValue: "打电话时需要翻译，拨 131 450", comment: "How to use it, with its phone number.") }
    static var helpLifelineHow: String { String(localized: "rights.help.lifeline.how", defaultValue: "情绪支持，24 小时。电话 13 11 14", comment: "What Lifeline offers and its phone number.") }
    static var rightsRemind: String { String(localized: "rights.remindAtLaunch", defaultValue: "每次打开时提醒我这些权利", comment: "Checkbox at the end of the rights card.") }
    static var breakRemind: String { String(localized: "rights.breakReminder", defaultValue: "连续工作 1.5 小时后提醒休息", comment: "Checkbox at the end of the rights card.") }
    static var breakText: String { String(localized: "break.text", defaultValue: "已经连续工作约 1.5 小时了，起来活动一下、喝口水吧。", comment: "Banner shown after about 1.5 hours of continuous work.") }
    static var breakRest: String { String(localized: "break.rest", defaultValue: "去休息", comment: "Button on the break banner: take the break.") }
    static var breakLater: String { String(localized: "break.later", defaultValue: "30 分钟后再说", comment: "Button on the break banner: ask again in 30 minutes.") }
}
