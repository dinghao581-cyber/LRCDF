-- Lightroom's own AI Denoise, switched on for the given photos. It lives in the Develop module and works on the photo
-- shown there, so each photo is shown in turn; selection and module are put back afterwards.
local LrApplication = import 'LrApplication'
local LrApplicationView = import 'LrApplicationView'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local Denoise = {}

local function state()
    local ok, s = LrTasks.pcall(LrDevelopController.getEnhancePanelState)
    return ok and s or {}
end

-- Returns done, skipped (already denoised, or not a raw file), failed, ids of the photos it was switched on for.
-- progress is optional: { caption = function(text), portion = function(done, total), canceled = function() }
function Denoise.apply(photos, progress)
    progress = progress or {}
    local catalog = LrApplication.activeCatalog()
    local selected, active = catalog:getTargetPhotos(), catalog:getTargetPhoto()
    local module = LrApplicationView.getCurrentModuleName()
    if module ~= 'develop' then
        LrApplicationView.switchToModule('develop')
        LrTasks.sleep(2)
    end
    local done, skipped, failed, switched = 0, 0, 0, {}
    for n, photo in ipairs(photos) do
        if progress.canceled and progress.canceled() then break end
        if progress.caption then progress.caption('正在降噪（' .. n .. '/' .. #photos .. '）…') end
        catalog:setSelectedPhotos(photo, {})
        for _ = 1, 20 do   -- until Develop shows this photo
            if catalog:getTargetPhoto() == photo then break end
            LrTasks.sleep(0.25)
        end
        LrTasks.sleep(1.5)
        local s = state()
        if s.denoiseState or s.denoiseEnabled == false then
            skipped = skipped + 1
        else
            -- toggleEnhance, not setEnhance: setEnhance('denoise', true) leaves the photo in "AI processing" for ever
            local ok = LrTasks.pcall(LrDevelopController.toggleEnhance, 'denoise')
            local on = false
            for _ = 1, 240 do   -- up to two minutes; about 8 s on an M5 Pro
                if ok and state().denoiseState then on = true break end
                LrTasks.sleep(0.5)
            end
            if on then done = done + 1 switched[#switched + 1] = photo.localIdentifier else failed = failed + 1 end
        end
        if progress.portion then progress.portion(n, #photos) end
    end
    if active then
        local others = {}
        for _, photo in ipairs(selected) do
            if photo ~= active then others[#others + 1] = photo end
        end
        catalog:setSelectedPhotos(active, others)
    end
    if module and module ~= 'develop' then LrApplicationView.switchToModule(module) end
    LrTasks.sleep(1)
    return done, skipped, failed, switched
end

-- Switch AI Denoise off again on the given photos (undo).
function Denoise.remove(photos)
    local catalog = LrApplication.activeCatalog()
    local selected, active = catalog:getTargetPhotos(), catalog:getTargetPhoto()
    local module = LrApplicationView.getCurrentModuleName()
    if module ~= 'develop' then LrApplicationView.switchToModule('develop') LrTasks.sleep(2) end
    for _, photo in ipairs(photos) do
        catalog:setSelectedPhotos(photo, {})
        LrTasks.sleep(2)
        if state().denoiseState then
            LrTasks.pcall(LrDevelopController.toggleEnhance, 'denoise')
            LrTasks.sleep(1.5)
        end
    end
    if active then
        local others = {}
        for _, photo in ipairs(selected) do
            if photo ~= active then others[#others + 1] = photo end
        end
        catalog:setSelectedPhotos(active, others)
    end
    if module and module ~= 'develop' then LrApplicationView.switchToModule(module) end
end

return Denoise
