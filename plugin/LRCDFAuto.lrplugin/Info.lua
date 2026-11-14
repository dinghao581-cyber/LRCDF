return {
    LrSdkVersion = 13.0,
    LrSdkMinimumVersion = 10.0,
    LrToolkitIdentifier = 'com.ding.lrcdf.auto',
    LrPluginName = 'LRCDF 一键修图',
    LrInitPlugin = 'Server.lua',
    LrForceInitPlugin = true,
    LrLibraryMenuItems = {
        { title = '开始一键修图…', file = 'OneClick.lua', enabledWhen = 'photosSelected' },
        { title = '高级：调色参数…', file = 'AutoTone.lua', enabledWhen = 'photosSelected' },
        { title = '高级：美颜参数…', file = 'AutoBeauty.lua', enabledWhen = 'photosSelected' },
    },
    LrExportMenuItems = {
        { title = '开始一键修图…', file = 'OneClick.lua', enabledWhen = 'photosSelected' },
    },
    VERSION = { major = 1, minor = 0, revision = 0 },
}
