-- MythicPlusTimer: Core
-- Инициализация аддона и SavedVariables

MythicPlusTimer = {}
local MPT = MythicPlusTimer

local function CopyValue(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, vv in pairs(v) do
        out[k] = CopyValue(vv)
    end
    return out
end

local LEGACY_COLOR_KEYS = {
    "colorTitle",
    "colorAffixes",
    "colorTimer",
    "colorTimerFailed",
    "colorPlus23",
    "colorPlus23Expired",
    "colorPlus23Remaining",
    "colorBossPending",
    "colorBossKilled",
    "colorForcesPct",
    "colorForcesPull",
    "forcesColor",
    "colorDeaths",
    "colorDeathsPenalty",
    "colorDeathsIcon",
    "colorBattleRes",
    "colorBattleResIcon",
    "colorButtons",
}

local LEGACY_STYLE_OPTION_DEFAULTS = {
    font = "Friz Quadrata (default)",
    scale = 1.0,
    forcesTexture = "Blank",
    affixText = true,
    affixIcons = false,
}

local LEGACY_STYLE_DEFAULT_COLORS = {
    colorTitle         = { r = 1,      g = 0.82,  b = 0 },
    colorAffixes       = { r = 0.67,   g = 0.67,  b = 0.67 },
    colorTimer         = { r = 1,      g = 1,     b = 1 },
    colorTimerFailed   = { r = 1,      g = 0.2,   b = 0.2 },
    colorPlus23        = { r = 1,      g = 1,     b = 1 },
    colorPlus23Expired = { r = 0.53,   g = 0.53,  b = 0.53 },
    colorPlus23Remaining = { r = 0,    g = 1,     b = 0 },
    colorBossPending   = { r = 1,      g = 1,     b = 1 },
    colorBossKilled    = { r = 0.53,   g = 0.53,  b = 0.53 },
    colorForcesPct     = { r = 1,      g = 1,     b = 1 },
    colorForcesPull    = { r = 0,      g = 1,     b = 0 },
    forcesColor        = { r = 0.25,   g = 0.55,  b = 1.0 },
    colorDeaths        = { r = 1,      g = 1,     b = 1 },
    colorDeathsPenalty = { r = 1,      g = 0.27,  b = 0.27 },
    colorDeathsIcon    = { r = 1,      g = 1,     b = 1 },
    colorBattleRes     = { r = 1,      g = 1,     b = 1 },
    colorBattleResIcon = { r = 1,      g = 1,     b = 1 },
    colorButtons       = { r = 1,      g = 1,     b = 1 },
}

-- Дефолтные значения SavedVariables
local DB_DEFAULTS = {
    debug        = false,
    runs         = {},
    affixIcons   = false,
    affixText    = true,
    scale        = 1.0,
    forcesBar    = false,
    forcesColor  = { r = 0.25, g = 0.55, b = 1.0 },
    showForcesInTooltip = true,
    showForcesPullPct   = true,
    showBossRecord = true,
    autoKeystone = false,
    reverseTimer = false,
    forcesTexture = "Blank",
    font = "Friz Quadrata (default)",
    hideDefaultTracker = false,
    activeStyle = "default",
    minimap = {
        hide = false,
        angle = 220,
    },
    styles = {
        default = {
            colors = LEGACY_STYLE_DEFAULT_COLORS,
            options = LEGACY_STYLE_OPTION_DEFAULTS,
        },
    },
    -- Цвета (кастомизация)
    colorTitle         = LEGACY_STYLE_DEFAULT_COLORS.colorTitle,
    colorAffixes       = LEGACY_STYLE_DEFAULT_COLORS.colorAffixes,
    colorTimer         = LEGACY_STYLE_DEFAULT_COLORS.colorTimer,
    colorTimerFailed   = LEGACY_STYLE_DEFAULT_COLORS.colorTimerFailed,
    colorPlus23        = LEGACY_STYLE_DEFAULT_COLORS.colorPlus23,
    colorPlus23Expired = LEGACY_STYLE_DEFAULT_COLORS.colorPlus23Expired,
    colorPlus23Remaining = LEGACY_STYLE_DEFAULT_COLORS.colorPlus23Remaining,
    colorBossPending   = LEGACY_STYLE_DEFAULT_COLORS.colorBossPending,
    colorBossKilled    = LEGACY_STYLE_DEFAULT_COLORS.colorBossKilled,
    colorForcesPct     = LEGACY_STYLE_DEFAULT_COLORS.colorForcesPct,
    colorForcesPull    = LEGACY_STYLE_DEFAULT_COLORS.colorForcesPull,
    colorDeaths        = LEGACY_STYLE_DEFAULT_COLORS.colorDeaths,
    colorDeathsPenalty = LEGACY_STYLE_DEFAULT_COLORS.colorDeathsPenalty,
    colorDeathsIcon    = LEGACY_STYLE_DEFAULT_COLORS.colorDeathsIcon,
    colorBattleRes     = LEGACY_STYLE_DEFAULT_COLORS.colorBattleRes,
    colorBattleResIcon = LEGACY_STYLE_DEFAULT_COLORS.colorBattleResIcon,
    colorButtons       = LEGACY_STYLE_DEFAULT_COLORS.colorButtons,
}

local CHAR_DB_DEFAULTS = {}

-- Инициализация
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:SetScript("OnEvent", function(self, _, addonName)
    if addonName ~= "MythicPlusTimer" then return end

    if not MythicPlusTimerDB then
        MythicPlusTimerDB = {}
    end
    for k, v in pairs(DB_DEFAULTS) do
        if MythicPlusTimerDB[k] == nil then
            MythicPlusTimerDB[k] = CopyValue(v)
        end
    end

    if not MythicPlusTimerCharDB then
        MythicPlusTimerCharDB = {}
    end
    for k, v in pairs(CHAR_DB_DEFAULTS) do
        if MythicPlusTimerCharDB[k] == nil then
            MythicPlusTimerCharDB[k] = v
        end
    end

    MPT.db = MythicPlusTimerDB
    MPT.charDb = MythicPlusTimerCharDB

    MPT:Init()
    self:UnregisterEvent("ADDON_LOADED")
end)

-- Дефолты цветов для сброса в настройках (копия ключей из DB_DEFAULTS)
MPT.COLOR_DEFAULTS = {
    colorTitle         = CopyValue(LEGACY_STYLE_DEFAULT_COLORS.colorTitle),
    colorAffixes       = CopyValue(LEGACY_STYLE_DEFAULT_COLORS.colorAffixes),
    colorTimer         = CopyValue(LEGACY_STYLE_DEFAULT_COLORS.colorTimer),
    colorTimerFailed   = CopyValue(LEGACY_STYLE_DEFAULT_COLORS.colorTimerFailed),
    colorPlus23        = CopyValue(LEGACY_STYLE_DEFAULT_COLORS.colorPlus23),
    colorPlus23Expired = CopyValue(LEGACY_STYLE_DEFAULT_COLORS.colorPlus23Expired),
    colorPlus23Remaining = CopyValue(LEGACY_STYLE_DEFAULT_COLORS.colorPlus23Remaining),
    colorBossPending   = CopyValue(LEGACY_STYLE_DEFAULT_COLORS.colorBossPending),
    colorBossKilled    = CopyValue(LEGACY_STYLE_DEFAULT_COLORS.colorBossKilled),
    colorForcesPct     = CopyValue(LEGACY_STYLE_DEFAULT_COLORS.colorForcesPct),
    colorForcesPull    = CopyValue(LEGACY_STYLE_DEFAULT_COLORS.colorForcesPull),
    forcesColor        = CopyValue(LEGACY_STYLE_DEFAULT_COLORS.forcesColor),
    colorDeaths        = CopyValue(LEGACY_STYLE_DEFAULT_COLORS.colorDeaths),
    colorDeathsPenalty = CopyValue(LEGACY_STYLE_DEFAULT_COLORS.colorDeathsPenalty),
    colorDeathsIcon    = CopyValue(LEGACY_STYLE_DEFAULT_COLORS.colorDeathsIcon),
    colorBattleRes     = CopyValue(LEGACY_STYLE_DEFAULT_COLORS.colorBattleRes),
    colorBattleResIcon = CopyValue(LEGACY_STYLE_DEFAULT_COLORS.colorBattleResIcon),
    colorButtons       = CopyValue(LEGACY_STYLE_DEFAULT_COLORS.colorButtons),
}

function MPT:EnsureStyleState()
    if not self.db then return end
    if type(self.db.activeStyle) ~= "string" or self.db.activeStyle == "" then
        self.db.activeStyle = "default"
    end
    if type(self.db.styles) ~= "table" then
        self.db.styles = {}
    end
    if type(self.db.styles.default) ~= "table" then
        self.db.styles.default = {}
    end
    if type(self.db.styles.default.colors) ~= "table" then
        self.db.styles.default.colors = {}
    end
    if type(self.db.styles.default.options) ~= "table" then
        self.db.styles.default.options = {}
    end

    local colors = self.db.styles.default.colors
    for _, key in ipairs(LEGACY_COLOR_KEYS) do
        local c = colors[key]
        if type(c) ~= "table" or type(c.r) ~= "number" or type(c.g) ~= "number" or type(c.b) ~= "number" then
            local legacy = self.db[key]
            if type(legacy) == "table" and type(legacy.r) == "number" and type(legacy.g) == "number" and type(legacy.b) == "number" then
                colors[key] = { r = legacy.r, g = legacy.g, b = legacy.b }
            else
                local def = self.COLOR_DEFAULTS[key]
                if def then
                    colors[key] = { r = def.r, g = def.g, b = def.b }
                end
            end
        end
    end

    local opts = self.db.styles.default.options
    for key, defVal in pairs(LEGACY_STYLE_OPTION_DEFAULTS) do
        if opts[key] == nil then
            local legacyVal = self.db[key]
            if legacyVal ~= nil then
                opts[key] = legacyVal
            else
                opts[key] = CopyValue(defVal)
            end
        end
    end
end

function MPT:GetStyleOption(key, fallback, styleId)
    if self.GetStyleOptionFor and self.GetStyleOptionFor ~= MPT.GetStyleOption then
        return self:GetStyleOptionFor(styleId or (self.GetActiveStyleId and self:GetActiveStyleId()) or "default", key, fallback)
    end
    if self.GetStyleOptionFor then
        return self:GetStyleOptionFor(styleId or "default", key, fallback)
    end
    if self.db and self.db.styles and self.db.styles.default and self.db.styles.default.options then
        local v = self.db.styles.default.options[key]
        if v ~= nil then return v end
    end
    return fallback
end

function MPT:SetStyleOption(key, value, styleId)
    if self.SetStyleOptionFor then
        return self:SetStyleOptionFor(styleId or (self.GetActiveStyleId and self:GetActiveStyleId()) or "default", key, value)
    end
    if not self.db then return end
    if type(self.db.styles) ~= "table" then self.db.styles = {} end
    local sid = styleId or "default"
    if type(self.db.styles[sid]) ~= "table" then self.db.styles[sid] = {} end
    if type(self.db.styles[sid].options) ~= "table" then self.db.styles[sid].options = {} end
    self.db.styles[sid].options[key] = value
end

function MPT:GetActiveStyleOptions()
    local sid = (self.GetActiveStyleId and self:GetActiveStyleId()) or (self.db and self.db.activeStyle) or "default"
    if self.GetStyleOptionsFor then
        return self:GetStyleOptionsFor(sid)
    end
    if self.db and self.db.styles and self.db.styles[sid] then
        return self.db.styles[sid].options or {}
    end
    return {}
end

function MPT:Init()
    self:EnsureStyleState()
    if self.InitStyleRegistry then
        self:InitStyleRegistry()
    end
    if self.ApplyStyle then
        self:ApplyStyle(self.db and self.db.activeStyle or "default")
    end
    if self.LoadTimerPosition then
        self:LoadTimerPosition()
    end
    if self.RefreshForcesTexture then self:RefreshForcesTexture() end
    if self.RefreshFont           then self:RefreshFont()          end
    if self.ApplyButtonColors     then self:ApplyButtonColors()     end
    if self.ApplyDeathsBrIconColors then self:ApplyDeathsBrIconColors() end
    if self.InitMinimapButton then self:InitMinimapButton() end
end

function MPT:Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[MPT]|r " .. tostring(msg))
end

-- GetAffixInfo(id) → name [, description [, icon]] (на Sirus может не работать)
function MPT:GetAffixInfo(affixId)
    if not C_ChallengeMode or not C_ChallengeMode.GetAffixInfo then return nil, nil, nil end
    local ok, name, description, icon = pcall(function()
        local n, d, i = C_ChallengeMode.GetAffixInfo(affixId)
        if n ~= nil or d ~= nil or i ~= nil then return n, d, i end
        return C_ChallengeMode.GetAffixInfo(C_ChallengeMode, affixId)
    end)
    if not ok then return nil, nil, nil end
    return name, description, icon
end

-- Слэш-команды
SLASH_MPT1 = "/mpt"
SlashCmdList["MPT"] = function(msg)
    local cmd = msg:lower():match("^(%S+)")

    if not cmd or cmd == "" then
        if MPT.ToggleConfigWindow then
            MPT:ToggleConfigWindow()
        else
            MPT:Print("Окно настроек пока недоступно.")
        end

    elseif cmd == "debug" then
        MPT.db.debug = not MPT.db.debug
        MPT:Print("Debug: " .. (MPT.db.debug and "ON" or "OFF"))

    elseif cmd == "reset" then
        MPT.db.killLog       = {}
        MPT.db.learnedForces = {}
        MPT:Print("killLog и learnedForces очищены.")

    elseif cmd == "timer" then
        MPT:ToggleTimer()

    elseif cmd == "preview" then
        MPT:ShowPreview()

    elseif cmd == "kills" then
        local kl = MPT.db and MPT.db.killLog
        if not kl or #kl == 0 then
            MPT:Print("killLog пуст. Убей мобов в ключе.")
            return
        end
        MPT:Print(string.format("=== killLog: %d записей ===", #kl))
        for i, e in ipairs(kl) do
            MPT:Print(string.format("[%d] npcID=%d bar=%.2f%% name=%s",
                i, e.npcID or 0, e.bar or 0, tostring(e.name)))
        end

    elseif cmd == "findframes" then
        -- Печатает видимые глобальные фреймы с "Scenario", "Tracker", "Challenge", "Objective" в имени
        local found = 0
        for k, v in pairs(_G) do
            if type(k) == "string" and type(v) == "table" and type(v.IsShown) == "function" then
                local lower = k:lower()
                if lower:find("scenario") or lower:find("tracker") or lower:find("challenge") or lower:find("objective") then
                    local ok, shown = pcall(function() return v:IsShown() end)
                    if ok then
                        MPT:Print(string.format("[%s] shown=%s", k, tostring(shown)))
                        found = found + 1
                    end
                end
            end
        end
        if found == 0 then MPT:Print("Ничего не найдено. Попробуй во время активного ключа.") end

    elseif cmd == "options" or cmd == "config" then
        if MPT.ToggleConfigWindow then
            MPT:ToggleConfigWindow()
        else
            MPT:Print("Окно настроек пока недоступно.")
        end

    else
        MPT:Print("Команды: /mpt | config | debug | reset | timer | preview | kills | findframes")
    end
end
