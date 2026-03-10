-- MythicPlusTimer: Core
-- Инициализация аддона и SavedVariables

MythicPlusTimer = {}
local MPT = MythicPlusTimer

-- Дефолтные значения SavedVariables
local DB_DEFAULTS = {
    debug        = false,
    runs         = {},
    affixIcons   = false,
    affixText    = true,
    scale        = 1.0,
    forcesBar    = false,
    forcesColor  = { r = 0.25, g = 0.55, b = 1.0 },
    showBossRecord = true,
    autoKeystone = false,
    reverseTimer = false,
    forcesTexture = "Blank",
    font = "Friz Quadrata (default)",
    hideDefaultTracker = false,
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
            MythicPlusTimerDB[k] = v
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

function MPT:Init()
    if self.LoadTimerPosition then
        self:LoadTimerPosition()
    end
    if self.RefreshForcesTexture then self:RefreshForcesTexture() end
    if self.RefreshFont           then self:RefreshFont()          end
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

    if cmd == "debug" then
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

    elseif cmd == "resdebug" then
        -- Дебаг воскрешений в бою: C_ChallengeMode и фреймы с текстом (сердечко/цифра)
        if MPT.DumpResurrectionSources then
            MPT:DumpResurrectionSources()
        else
            MPT:Print("DataCollector не загружен — DumpResurrectionSources недоступен.")
        end

    else
        MPT:Print("Команды: /mpt debug | reset | timer | preview | kills | findframes | resdebug")
    end
end
