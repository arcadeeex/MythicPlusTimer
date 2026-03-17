-- MythicPlusTimer: Second style descriptor

local MPT = MythicPlusTimer

local secondColors = {
    colorBackground    = { r = 0.00, g = 0.00, b = 0.00 },
    colorTitle         = { r = 1.00, g = 1.00, b = 1.00 },
    colorAffixes       = { r = 0.75, g = 0.85, b = 0.95 },
    colorTimer         = { r = 0.95, g = 0.95, b = 0.95 },
    colorTimerBar      = { r = 1.00, g = 0.93, b = 0.10 },
    colorTimerFailed   = { r = 1.00, g = 0.25, b = 0.25 },
    colorPlus23        = { r = 0.95, g = 0.95, b = 0.95 },
    colorPlus23Expired = { r = 0.55, g = 0.55, b = 0.55 },
    colorPlus23Remaining = { r = 0.20, g = 1.00, b = 0.20 },
    colorBossPending   = { r = 0.95, g = 0.95, b = 0.95 },
    colorBossKilled    = { r = 0.35, g = 0.95, b = 0.35 },
    colorForcesPct     = { r = 0.95, g = 0.95, b = 0.95 },
    colorForcesPull    = { r = 0.20, g = 1.00, b = 0.20 },
    forcesColor        = { r = 0.25, g = 0.55, b = 1.00 },
    colorDeaths        = { r = 0.95, g = 0.95, b = 0.95 },
    colorDeathsPenalty = { r = 1.00, g = 0.35, b = 0.35 },
    colorDeathsIcon    = { r = 0.95, g = 0.95, b = 0.95 },
    colorBattleRes     = { r = 0.95, g = 0.95, b = 0.95 },
    colorBattleResIcon = { r = 1.00, g = 0.20, b = 0.20 },
    colorButtons       = { r = 0.95, g = 0.95, b = 0.95 },
}

MPT:RegisterStyle({
    id = "second",
    label = "Reloe",
    defaultColors = secondColors,
    defaultOptions = {
        font = "Friz Quadrata (default)",
        scale = 1.0,
    },
    optionsSchema = {
        { key = "font",  type = "font",  label = "Шрифт" },
        { key = "scale", type = "scale", label = "Масштаб таймера" },
    },
    colorSchema = {
        { key = "colorBackground",    label = "Цвет фона" },
        { key = "colorTitle",         label = "Цвет заголовка" },
        { key = "colorTimer",         label = "Цвет таймера" },
        { key = "colorTimerBar",      label = "Цвет полосы таймера" },
        { key = "colorBossPending",   label = "Цвет незакрытого босса" },
        { key = "colorBossKilled",    label = "Цвет закрытого босса" },
        { key = "forcesColor",        label = "Цвет прогресс бара" },
        { key = "colorForcesPct",     label = "Цвет текущих процентов" },
        { key = "colorForcesPull",    label = "Цвет процента за пак" },
        { key = "colorButtons",       label = "Цвет кнопок" },
        { key = "colorDeathsIcon",    label = "Цвет иконки смертей" },
        { key = "colorDeaths",        label = "Цвет текста смертей" },
        { key = "colorBattleResIcon", label = "Цвет иконки БР" },
        { key = "colorBattleRes",     label = "Цвет текста БР" },
    },
    onApply = function(self)
        if self.RefreshAllColors then self:RefreshAllColors() end
        if self.RefreshConfigWindow then self:RefreshConfigWindow() end
        if self.RefreshCurrentAffixes then self:RefreshCurrentAffixes() end
        if self.RefreshForcesMode then self:RefreshForcesMode() end
    end,
})
