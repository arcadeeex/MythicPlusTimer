-- MythicPlusTimer: Arcade style descriptor

local MPT = MythicPlusTimer

local arcadeColors = {
    colorBackground    = { r = 0.12, g = 0.18, b = 0.30 },
    colorTitle         = { r = 0.96, g = 0.79, b = 0.32 },
    colorAffixes       = { r = 0.70, g = 0.80, b = 0.95 },
    colorTimer         = { r = 0.97, g = 0.82, b = 0.26 },
    colorTimerBar      = { r = 0.95, g = 0.74, b = 0.21 },
    colorTimerFailed   = { r = 0.95, g = 0.36, b = 0.36 },
    colorPlus23        = { r = 0.92, g = 0.92, b = 0.98 },
    colorPlus23Expired = { r = 0.55, g = 0.58, b = 0.65 },
    colorPlus23Remaining = { r = 0.30, g = 0.80, b = 1.00 },
    colorBossPending   = { r = 0.80, g = 0.88, b = 1.00 },
    colorBossKilled    = { r = 0.35, g = 0.92, b = 0.62 },
    colorForcesPct     = { r = 0.82, g = 0.92, b = 1.00 },
    colorForcesPull    = { r = 0.40, g = 0.87, b = 0.95 },
    forcesColor        = { r = 0.33, g = 0.63, b = 1.00 },
    colorDeaths        = { r = 0.90, g = 0.92, b = 0.98 },
    colorDeathsPenalty = { r = 0.95, g = 0.45, b = 0.45 },
    colorDeathsIcon    = { r = 0.82, g = 0.86, b = 0.95 },
    colorBattleRes     = { r = 1.00, g = 0.60, b = 0.78 },
    colorBattleResIcon = { r = 1.00, g = 0.45, b = 0.66 },
    colorButtons       = { r = 0.88, g = 0.92, b = 1.00 },
}

MPT:RegisterStyle({
    id = "arcade",
    label = "Dashboard",
    defaultColors = arcadeColors,
    defaultOptions = {
        scale = 1.0,
    },
    optionsSchema = {
        { key = "scale", type = "scale", label = "Масштаб таймера" },
    },
    colorSchema = {},
    onApply = function(self)
        if self.RefreshAllColors then self:RefreshAllColors() end
        if self.RefreshConfigWindow then self:RefreshConfigWindow() end
        if self.RefreshCurrentAffixes then self:RefreshCurrentAffixes() end
        if self.RefreshForcesMode then self:RefreshForcesMode() end
    end,
})
