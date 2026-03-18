-- MythicPlusTimer: Default style descriptor

local MPT = MythicPlusTimer

local colorSchema = {
    { key = "colorTitle",           label = "Цвет названия уровня и названия ключа" },
    { key = "colorAffixes",         label = "Цвет аффиксов текстом" },
    { key = "colorTimer",           label = "Цвет таймера" },
    { key = "colorTimerFailed",     label = "Цвет проваленного таймера" },
    { key = "colorPlus23",          label = "Цвет таймера на +2/+3" },
    { key = "colorPlus23Remaining", label = "Цвет времени до окончания +2/+3" },
    { key = "colorBossPending",     label = "Цвет списка непройденных боссов" },
    { key = "colorBossKilled",      label = "Цвет пройденного босса" },
    { key = "colorForcesPct",       label = "Цвет основного процента убитых врагов" },
    { key = "colorForcesPull",      label = "Цвет процентов за спуленный пак" },
    { key = "forcesColor",          label = "Цвет прогресс бара" },
    { key = "colorDeathsIcon",      label = "Цвет иконки количества смертей" },
    { key = "colorDeaths",          label = "Цвет количества смертей" },
    { key = "colorDeathsPenalty",   label = "Цвет штрафа за смерти" },
    { key = "colorBattleResIcon",   label = "Цвет иконки количества БР" },
    { key = "colorBattleRes",       label = "Цвет количества БР" },
    { key = "colorButtons",         label = "Цвет кнопок интерфейса" },
}

local defaultOptions = {
    font = "Friz Quadrata (default)",
    scale = 1.0,
    forcesTexture = "Blank",
    affixText = true,
    affixIcons = false,
}

local optionsSchema = {
    { key = "font",         label = "Шрифт",            type = "font" },
    { key = "forcesTexture",label = "Текстура",         type = "texture" },
    { key = "scale",        label = "Масштаб таймера",  type = "scale" },
    { key = "affixText",    label = "Показывать аффиксы текстом",  type = "toggle" },
    { key = "affixIcons",   label = "Показывать аффиксы иконками", type = "toggle" },
}

MPT:RegisterStyle({
    id = "default",
    label = "Minimal",
    defaultColors = MPT.COLOR_DEFAULTS,
    defaultOptions = defaultOptions,
    optionsSchema = optionsSchema,
    colorSchema = colorSchema,
    onApply = function(self)
        if self.RefreshAllColors then
            self:RefreshAllColors()
        end
        if self.RefreshConfigWindow then
            self:RefreshConfigWindow()
        end
    end,
})
