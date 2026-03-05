-- MythicPlusTimer: Timer
-- WotLK 3.3.5a
--
-- Подтверждено из снапшотов (2025-03):
--   GetEnemyForcesProgress() → ОДИН % (0-100), не (current, total)
--   GetDeathCount()          → (n, timeLost_в_секундах), 5с за каждую смерть
--   GetActiveKeystoneInfo()  → (level, affixes_table)
--   CHALLENGE_MODE_START не стреляет на Sirus → polling IsChallengeModeActive()

local MPT = MythicPlusTimer

-- ============================================================
-- Состояние таймера
-- ============================================================
local state = {
    running               = false,
    startTime             = 0,
    elapsed               = 0,
    completed             = false,
    level                 = nil,
    affixes               = nil,
    dungeonName           = nil,
    mapID                 = nil,  -- C_ChallengeMode.GetActiveChallengeMapID()
    bosses                = nil,  -- list of {name, killed, fightDuration, isNewFdPB}
    encounterStartElapsed = nil,  -- elapsed при ENCOUNTER_START текущего боя
}

-- Локальный счётчик смертей из ASMSG (fallback если GetDeathCount() не работает)
local localDeathCount = 0
local localDeathLost  = 0

-- Таблица engaged мобов по GUID: [guid] = npcID
-- Каждый уникальный моб учитывается один раз. При смерти убирается по GUID.
local engagedGuids = {}

-- Суммарный % прогресса engaged мобов (инкрементальный кэш)
local engagedForcesTotal = 0

local function EngageGuid(guid, npcID)
    if not guid or not npcID or npcID == 0 then return end
    if engagedGuids[guid] then return end  -- уже в бою
    local pct = MPT:GetNpcForces(npcID)
    if not pct or pct <= 0 then return end  -- не даёт прогресса или неизвестен
    -- Храним сам pct (а не npcID) чтобы disengage снял ровно то что добавили
    engagedGuids[guid] = pct
    engagedForcesTotal = engagedForcesTotal + pct
end

local function DisengageGuid(guid)
    local pct = engagedGuids[guid]
    if not pct then return end
    engagedForcesTotal = engagedForcesTotal - pct
    if engagedForcesTotal < 0 then engagedForcesTotal = 0 end
    engagedGuids[guid] = nil
end

local function ClearEngaged()
    engagedGuids = {}
    engagedForcesTotal = 0
end

-- ============================================================
-- Вспомогательные функции
-- ============================================================

local function FormatTime(sec)
    if not sec or sec < 0 then sec = 0 end
    return string.format("%d:%02d", math.floor(sec / 60), math.floor(sec % 60))
end

-- Подтверждено: возвращает ОДНО значение = % (0-100)
local function GetForces()
    local ok, a = pcall(function()
        return C_ChallengeMode.GetEnemyForcesProgress()
    end)
    if ok and type(a) == "number" then
        return a
    end
    local bar = _G["ScenarioObjectiveTrackerPoolFrameScenarioProgressBarTemplate1_77Bar"]
    if bar and bar.GetValue then return bar:GetValue() end
    return nil
end

-- GetActiveKeystoneInfo() → (level, affixes_table)
local function GetKeystoneData()
    local ok, level, affixes = pcall(function()
        return C_ChallengeMode.GetActiveKeystoneInfo()
    end)
    if not ok then return nil, nil end
    local lvl = (type(level) == "number" and level >= 1 and level <= 99) and level or nil
    local aff = type(affixes) == "table" and affixes or nil
    return lvl, aff
end

-- Лимиты времени (сек) для порогов +2 и +3.
-- Подтверждено из GetMapUIInfo(mapID) (снапшоты 2025-03):
--   r1=название, r2=mapID, r3=базовое время, r4=время +2 (~80%), r5=время +3 (~64%)
local timeLimits = {
    [4]  = { plus2 = 1680, plus3 = 1344 },  -- Крепость Утгард          (base 2100)
    [5]  = { plus2 = 1680, plus3 = 1344 },  -- Бастионы Адского Пламени (base 2100)
    [6]  = { plus2 = 2160, plus3 = 1728 },  -- Узилище                  (base 2700)
    [8]  = { plus2 = 1680, plus3 = 1344 },  -- Крепость Драк'Тарон      (base 2100)
    [9]  = { plus2 = 1680, plus3 = 1344 },  -- Чертоги Молний           (base 2100)
    [10] = { plus2 = 2160, plus3 = 1728 },  -- Кузня Крови              (base 2700)
    [11] = { plus2 = 2160, plus3 = 1728 },  -- Гробницы Маны            (base 2700)
    [12] = { plus2 = 2160, plus3 = 1728 },  -- Ан'кахет: Старое Королевство (base 2700)
}

local function GetPlus2Plus3Limits()
    if not C_ChallengeMode then return nil, nil end
    local ok, mapID = pcall(function() return C_ChallengeMode.GetActiveChallengeMapID() end)
    if ok and type(mapID) == "number" then
        local t = timeLimits[mapID]
        if t then return t.plus2, t.plus3 end
    end
    return nil, nil
end

-- GetAffixInfo(id) → name [, description [, iconFileDataID]] (на Sirus может не работать)
local function GetAffixInfoSafe(id)
    local ok, name, description, icon = pcall(function()
        local n, d, i = C_ChallengeMode.GetAffixInfo(id)
        if n ~= nil or d ~= nil or i ~= nil then return n, d, i end
        return C_ChallengeMode.GetAffixInfo(C_ChallengeMode, id)
    end)
    if not ok then return nil, nil, nil end
    return name, description, icon
end

local SEP = " · "
-- Разрез по байтам: после второго " · " берём с позиции idx+#SEP (не +1), иначе режем первый байт "М" (UTF-8)
local function WrapAffixLine(str)
    if not str or #str <= 24 then return str, nil end
    local idx = str:find(SEP, 1, true)
    if idx then idx = str:find(SEP, idx + 1, true) end
    if idx then
        local line2 = str:sub(idx + #SEP)
        return str:sub(1, idx - 1), (line2 ~= "" and line2 or nil)
    end
    return str, nil
end

local function GetAffixStrings(affixIDs)
    if not affixIDs or #affixIDs == 0 then return nil, nil end
    local names = {}
    for _, id in ipairs(affixIDs) do
        local name = GetAffixInfoSafe(id)
        if type(name) == "string" and #name > 0 then
            table.insert(names, name)
        else
            table.insert(names, "#" .. id)
        end
    end
    if #names == 0 then return nil, nil end
    return WrapAffixLine(table.concat(names, SEP))
end

-- ============================================================
-- Создание фрейма (CreateFrame на верхнем уровне — OK)
-- ============================================================

-- Forward declarations (определены позже, нужны кнопке сворачивания)
local UpdateDisplay
local titleTooltipFrame
local affixTooltipFrame
local ShowAffixTooltip
local SetForcesMode

local frame = CreateFrame("Frame", "MPTTimerFrame", UIParent)
frame:SetWidth(280)
-- Высота задаётся в SetBossCount; начальная — компактная (0 боссов)
local COMPACT_HEIGHT = 172  -- пересчитано при BOSS_LINE_HEIGHT=30
frame:SetHeight(COMPACT_HEIGHT)
frame:SetFrameStrata("HIGH")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)

-- Лёгкий тёмный фон для читаемости текста
local bg = frame:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints(frame)
bg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
bg:SetVertexColor(0, 0, 0, 0)

-- Заголовок: "+15 — Кузня Крови"
frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
frame.title:SetPoint("TOPLEFT",  frame, "TOPLEFT",  8, -6)
frame.title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -6)
frame.title:SetJustifyH("LEFT")
frame.title:SetWordWrap(true)
frame.title:SetFont("Fonts\\FRIZQT__.TTF", 13, "")
frame.title:SetTextColor(1, 1, 1)
frame.title:SetText("ожидание...")

-- Аффиксы: две строки без \n, чтобы кириллица не портилась (напр. Мучительный)
frame.affixes = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
frame.affixes:SetPoint("TOPLEFT",  frame, "TOPLEFT",  8, -24)
frame.affixes:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -24)
frame.affixes:SetJustifyH("LEFT")
frame.affixes:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
frame.affixes:SetTextColor(1, 1, 1)
frame.affixes:SetText("")
frame.affixes:Hide()
frame.affixesLine2 = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
frame.affixesLine2:SetPoint("TOPLEFT",  frame.affixes, "BOTTOMLEFT",  0, -4)
frame.affixesLine2:SetPoint("TOPRIGHT", frame.affixes, "BOTTOMRIGHT", 0, -4)
frame.affixesLine2:SetJustifyH("LEFT")
frame.affixesLine2:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
frame.affixesLine2:SetTextColor(1, 1, 1)
frame.affixesLine2:SetText("")
frame.affixesLine2:Hide()

-- Контейнер иконок аффиксов (якорится динамически в RefreshAffixes)
-- Содержит пул frame.affixIconFrames[i] — по одному на аффикс
local AFFIX_ICON_SIZE = 22
local AFFIX_ICON_GAP  = 8  -- расстояние между иконками
local MAX_AFFIX_ICONS = 8
frame.affixesIcons = CreateFrame("Frame", nil, frame)
frame.affixesIcons:SetHeight(AFFIX_ICON_SIZE)
frame.affixesIcons:SetPoint("TOPLEFT",  frame, "TOPLEFT",  8, -24)
frame.affixesIcons:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -24)
frame.affixesIcons:Hide()
-- Пул иконок-фреймов
frame.affixIconFrames = {}
for i = 1, MAX_AFFIX_ICONS do
    local iconFrame = CreateFrame("Frame", nil, frame.affixesIcons)
    iconFrame:SetWidth(AFFIX_ICON_SIZE)
    iconFrame:SetHeight(AFFIX_ICON_SIZE)
    -- Иконка
    local tex = iconFrame:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(iconFrame)
    tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    iconFrame.tex = tex
    -- Скругление: непрозрачный чёрный оверлей с прозрачным кругом в центре
    local corner = iconFrame:CreateTexture(nil, "OVERLAY")
    corner:SetAllPoints(iconFrame)
    corner:SetTexture("Interface\\AddOns\\MythicPlusTimer\\Media\\icon_corner")
    -- Тултип аффиксов при наведении на иконку
    iconFrame:EnableMouse(true)
    iconFrame:SetScript("OnEnter", function(self) ShowAffixTooltip(self) end)
    iconFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)
    iconFrame:Hide()
    frame.affixIconFrames[i] = iconFrame
end

-- Таймер (крупный): позиция по Y пересчитывается в UpdateTimerLayout
frame.timer = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
frame.timer:SetFont("Fonts\\FRIZQT__.TTF", 20, "")
frame.timer:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -56)
frame.timer:SetText("--:--")
frame.timer:SetTextColor(0.5, 0.5, 0.5)

-- Строки порогов +2/+3: позиции пересчитываются в UpdateTimerLayout
frame.plus2 = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
frame.plus2:SetJustifyH("LEFT")
frame.plus2:SetFont("Fonts\\FRIZQT__.TTF", 12, "")
frame.plus2:SetTextColor(1, 1, 1)
frame.plus2:SetText("")
frame.plus2:Hide()

frame.plus3 = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
frame.plus3:SetJustifyH("LEFT")
frame.plus3:SetFont("Fonts\\FRIZQT__.TTF", 12, "")
frame.plus3:SetTextColor(1, 1, 1)
frame.plus3:SetText("")
frame.plus3:Hide()


-- Строки боссов: динамическая высота (16px = 1 строка, 28px = 2 строки с переносом)
-- Позиции пересчитываются в UpdateBossLayout после каждого SetText на строке
local MAX_BOSSES = 4
local BOSS_LINE_H1    = 16  -- одна строка (~14px + 2px зазор)
local BOSS_LINE_H2    = 28  -- две строки
local BOSS_FIRST_OFFSET = 8  -- отступ от top блока боссов до первой строки
local FRAME_INNER_W   = 264   -- 280 - 2*8 (горизонтальные отступы)
frame.bossLines = {}
frame.bossLineH = {}  -- текущая высота каждой строки (16 или 28)
for i = 1, MAX_BOSSES do
    local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetWidth(FRAME_INNER_W)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    fs:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
    fs:SetTextColor(1, 1, 1)
    fs:SetText("")
    fs:Hide()
    frame.bossLines[i] = fs
    frame.bossLineH[i] = BOSS_LINE_H1
end


-- Прогресс сил врагов (GameFontNormal — чуть крупнее Small)
frame.forces = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
frame.forces:SetPoint("TOPLEFT",  frame, "TOPLEFT",  8, -109 - BOSS_LINE_H1)
frame.forces:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -109 - BOSS_LINE_H1)
frame.forces:SetJustifyH("LEFT")
frame.forces:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
frame.forces:SetTextColor(1, 1, 1)
frame.forces:SetText("|cff888888Убито врагов: —|r")

-- Контейнер для bar-режима (скрыт по умолчанию)
frame.forcesBarContainer = CreateFrame("Frame", nil, frame)
frame.forcesBarContainer:SetHeight(16)

-- Тёмный фон
local fbBg = frame.forcesBarContainer:CreateTexture(nil, "BACKGROUND")
fbBg:SetAllPoints(frame.forcesBarContainer)
fbBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
fbBg:SetVertexColor(0.05, 0.05, 0.05, 0.9)

-- Заполнение бара: отдельный Frame с текстурой, ширина меняется SetWidth()
frame.forcesBarFill = CreateFrame("Frame", nil, frame.forcesBarContainer)
frame.forcesBarFill:SetPoint("TOPLEFT", frame.forcesBarContainer, "TOPLEFT", 1, -1)
frame.forcesBarFill:SetWidth(1)   -- начальная ширина; обновляется через SetValue
frame.forcesBarFill:SetHeight(14) -- 16px контейнер - 2px (1px top + 1px bottom)
local fbFill = frame.forcesBarFill:CreateTexture(nil, "ARTWORK")
fbFill:SetAllPoints(frame.forcesBarFill)
fbFill:SetTexture("Interface\\BUTTONS\\WHITE8X8")
fbFill:SetVertexColor(0.25, 0.55, 1.0, 0.9)

-- Текст поверх, родитель — контейнер, OVERLAY
frame.forcesBar = {}  -- таблица для совместимости с остальным кодом
frame.forcesBar.text = frame.forcesBarContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
frame.forcesBar.text:SetPoint("LEFT",  frame.forcesBarContainer, "LEFT",  4, 0)
frame.forcesBar.text:SetPoint("RIGHT", frame.forcesBarContainer, "RIGHT", -4, 0)
frame.forcesBar.text:SetJustifyH("CENTER")
frame.forcesBar.text:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
frame.forcesBar.text:SetTextColor(1, 1, 1)

-- SetValue: обновляет ширину заполнения (0-100%)
-- Ширина контейнера = ширина фрейма (280) - 2 * 8px отступа = 264px
local FORCES_BAR_INNER_W = FRAME_INNER_W - 2  -- 262px (264 - 1px каждая сторона)
frame.forcesBar.SetValue = function(_, pct)
    local fillW = math.max(1, math.floor(FORCES_BAR_INNER_W * math.min(pct, 100) / 100 + 0.5))
    frame.forcesBarFill:SetWidth(fillW)
end

frame.forcesBarContainer:Hide()

-- Смерти
frame.deaths = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
frame.deaths:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -124 - BOSS_LINE_H1)
frame.deaths:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
frame.deaths:SetTextColor(1, 1, 1)
frame.deaths:SetText("|cff888888Смертей: —|r")

-- ============================================================
-- Кнопки управления (развёрнутый режим: 14×14, у нижнего правого угла)
-- ============================================================

-- Кнопка "Сдаться" (развёрнутый режим)
local forfeitBtn = CreateFrame("Button", nil, frame)
forfeitBtn:SetWidth(12)
forfeitBtn:SetHeight(12)
forfeitBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -5, 6)
local forfeitTex = forfeitBtn:CreateTexture(nil, "ARTWORK")
forfeitTex:SetAllPoints(forfeitBtn)
forfeitTex:SetTexture("Interface\\AddOns\\MythicPlusTimer\\Media\\forfeit.blp")
forfeitBtn:SetScript("OnClick", function()
    pcall(function() C_ChallengeMode.Forfeit() end)
end)
forfeitBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("Сдаться", 1, 0.2, 0.2, 1)
    GameTooltip:Show()
end)
forfeitBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Кнопка "Пауза" (развёрнутый режим)
local pauseBtn = CreateFrame("Button", nil, frame)
pauseBtn:SetWidth(12)
pauseBtn:SetHeight(12)
pauseBtn:SetPoint("BOTTOMRIGHT", forfeitBtn, "BOTTOMLEFT", -4, 0)
local pauseTex = pauseBtn:CreateTexture(nil, "ARTWORK")
pauseTex:SetAllPoints(pauseBtn)
pauseTex:SetTexture("Interface\\AddOns\\MythicPlusTimer\\Media\\pause.blp")
pauseBtn:SetScript("OnClick", function()
    pcall(function() C_ChallengeMode.Pause() end)
end)
pauseBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("Поставить паузу", 1, 1, 0.4, 1)
    GameTooltip:Show()
end)
pauseBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- ============================================================
-- Кнопка сворачивания (TOPRIGHT, 10×10)
-- ============================================================
local collapseBtn = CreateFrame("Button", nil, frame)
collapseBtn:SetWidth(10)
collapseBtn:SetHeight(10)
collapseBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
local collapseTex = collapseBtn:CreateTexture(nil, "ARTWORK")
collapseTex:SetAllPoints(collapseBtn)
collapseTex:SetTexture("Interface\\AddOns\\MythicPlusTimer\\Media\\minus.blp")

-- ============================================================
-- Маленькие кнопки для свёрнутого режима (10×10, справа)
-- Показываются только когда collapsed=true
-- ============================================================
local forfeitSmall = CreateFrame("Button", nil, frame)
forfeitSmall:SetWidth(10)
forfeitSmall:SetHeight(10)
forfeitSmall:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -18, -6)
forfeitSmall:Hide()
local forfeitSmallTex = forfeitSmall:CreateTexture(nil, "ARTWORK")
forfeitSmallTex:SetAllPoints(forfeitSmall)
forfeitSmallTex:SetTexture("Interface\\AddOns\\MythicPlusTimer\\Media\\forfeit.blp")
forfeitSmall:SetScript("OnClick", function()
    pcall(function() C_ChallengeMode.Forfeit() end)
end)
forfeitSmall:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("Сдаться", 1, 0.2, 0.2, 1)
    GameTooltip:Show()
end)
forfeitSmall:SetScript("OnLeave", function() GameTooltip:Hide() end)

local pauseSmall = CreateFrame("Button", nil, frame)
pauseSmall:SetWidth(10)
pauseSmall:SetHeight(10)
pauseSmall:SetPoint("TOPRIGHT", forfeitSmall, "TOPLEFT", -3, 0)
pauseSmall:Hide()
local pauseSmallTex = pauseSmall:CreateTexture(nil, "ARTWORK")
pauseSmallTex:SetAllPoints(pauseSmall)
pauseSmallTex:SetTexture("Interface\\AddOns\\MythicPlusTimer\\Media\\pause.blp")
pauseSmall:SetScript("OnClick", function()
    pcall(function() C_ChallengeMode.Pause() end)
end)
pauseSmall:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("Поставить паузу", 1, 1, 0.4, 1)
    GameTooltip:Show()
end)
pauseSmall:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- ============================================================
-- Collapse state
-- ============================================================
local collapsed = false
local collapsedHeight = 22
-- Сохранённая высота развёрнутого фрейма (для восстановления при разворачивании)
local expandedHeight = COMPACT_HEIGHT
-- Последний полный текст заголовка; восстанавливается при разворачивании
local lastTitleText = "ожидание..."
-- Сохранённые данные для восстановления при разворачивании
local savedBossShown = {}   -- [i] = true/false
local savedPlus2Shown = false
local savedPlus3Shown = false

local function SetCollapsed(isCollapsed)
    collapsed = isCollapsed
    if isCollapsed then
        collapseTex:SetTexture("Interface\\AddOns\\MythicPlusTimer\\Media\\plus.blp")
        -- Запоминаем что было видимо, чтобы восстановить при разворачивании
        savedPlus2Shown = frame.plus2:IsShown() and true or false
        savedPlus3Shown = frame.plus3:IsShown() and true or false
        for i = 1, MAX_BOSSES do
            savedBossShown[i] = frame.bossLines[i]:IsShown() and true or false
        end
        expandedHeight = frame:GetHeight()

        -- Фиксируем верхний левый угол чтобы сворачивание шло вниз
        local top  = frame:GetTop()  or 0
        local left = frame:GetLeft() or 0
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        frame:SetHeight(collapsedHeight)

        -- Скрываем всё кроме заголовка и кнопок
        frame.affixes:Hide()
        frame.affixesLine2:Hide()
        frame.affixesIcons:Hide()
        frame.timer:Hide()
        frame.plus2:Hide()
        frame.plus3:Hide()
        for i = 1, MAX_BOSSES do frame.bossLines[i]:Hide() end
        frame.forces:Hide()
        frame.forcesBarContainer:Hide()
        frame.deaths:Hide()
        forfeitBtn:Hide()
        pauseBtn:Hide()
        forfeitSmall:Show()
        pauseSmall:Show()
        titleTooltipFrame:EnableMouse(false)
        affixTooltipFrame:EnableMouse(false)

        -- Заголовок: "12:10  +15  Бастионы..." — без переноса, обрезается
        frame.title:SetWordWrap(false)
        frame.title:ClearAllPoints()
        -- Оставляем место для 3 кнопок справа: collapse@-4(10px)+forfeit@-18(10px)+pause@-31(10px) → конец ~-41
        frame.title:SetPoint("TOPLEFT",  frame, "TOPLEFT",  8, -6)
        frame.title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -44, -6)

        local active = state.running or state.completed
        local timerStr
        if active and state.elapsed then
            local lvlStr  = state.level and ("+" .. state.level) or "?"
            local dungeon = state.dungeonName or ""
            timerStr = string.format("%s  %s  %s", FormatTime(state.elapsed), lvlStr, dungeon)
        else
            -- Статический режим (превью или ожидание): берём текущий текст таймера + заголовок
            local timerText = frame.timer:GetText()
            if timerText and timerText ~= "" and timerText ~= "--:--" then
                -- Берём только часть до "/" (без лимита: "12:44/35:00" → "12:44")
                local elapsed = timerText:match("^([^/]+)") or timerText
                timerStr = elapsed .. "  " .. lastTitleText
            else
                timerStr = lastTitleText
            end
        end
        frame.title:SetText(timerStr)
    else
        collapseTex:SetTexture("Interface\\AddOns\\MythicPlusTimer\\Media\\minus.blp")

        -- Восстанавливаем якорь по верхней границе (TOPLEFT) и высоту
        local top  = frame:GetTop()  or 0
        local left = frame:GetLeft() or 0
        -- После сворачивания top = верх свёрнутого фрейма, восстанавливаем развёрнутый вниз от него
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        frame:SetHeight(expandedHeight)

        -- Восстанавливаем заголовок
        frame.title:SetWordWrap(true)
        frame.title:ClearAllPoints()
        frame.title:SetPoint("TOPLEFT",  frame, "TOPLEFT",  8, -6)
        frame.title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -6)
        frame.title:SetText(lastTitleText)

        -- Показываем обязательные элементы
        frame.timer:Show()
        SetForcesMode(MPT.db and MPT.db.forcesBar or false)
        frame.deaths:Show()
        forfeitBtn:Show()
        pauseBtn:Show()
        forfeitSmall:Hide()
        pauseSmall:Hide()
        titleTooltipFrame:EnableMouse(true)
        affixTooltipFrame:EnableMouse(true)

        -- Сначала восстанавливаем видимость plus2/plus3 и боссов,
        -- чтобы UpdateTimerLayout/UpdateBossLayout внутри RefreshCurrentAffixes
        -- видели правильное состояние и корректно пересчитали позиции
        if savedPlus2Shown then frame.plus2:Show() else frame.plus2:Hide() end
        if savedPlus3Shown then frame.plus3:Show() else frame.plus3:Hide() end
        for i = 1, MAX_BOSSES do
            if savedBossShown[i] then
                frame.bossLines[i]:Show()
            else
                frame.bossLines[i]:Hide()
            end
        end

        -- Восстанавливаем аффиксы и пересчитываем layout
        MPT:RefreshCurrentAffixes()

    end
end

collapseBtn:SetScript("OnClick", function()
    SetCollapsed(not collapsed)
end)
collapseBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(collapsed and "Развернуть" or "Свернуть" --[[@as string]], 1, 1, 1, 1)
    GameTooltip:Show()
end)
collapseBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Зона перетаскивания: весь фрейм (без тултипа аффиксов)
titleTooltipFrame = CreateFrame("Frame", nil, frame)
titleTooltipFrame:SetPoint("TOPLEFT",  frame, "TOPLEFT",  0, 0)
titleTooltipFrame:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, -64)
titleTooltipFrame:EnableMouse(true)
titleTooltipFrame:SetScript("OnMouseDown", function(_, button)
    if button == "LeftButton" then frame:StartMoving() end
end)
titleTooltipFrame:SetScript("OnMouseUp", function()
    frame:StopMovingOrSizing()
    if MPT.charDb then
        MPT.charDb.timerPos = { x = frame:GetLeft() or 0, y = frame:GetTop() or 0 }
    end
end)

-- Вспомогательная функция тултипа аффиксов (используется в affixTooltipFrame и иконках)
ShowAffixTooltip = function(anchor)
    local lvl, name, affs
    if (state.running or state.completed) and (state.level or state.dungeonName or (state.affixes and #state.affixes > 0)) then
        lvl  = state.level
        name = state.dungeonName or ""
        affs = state.affixes
    else
        lvl  = 15
        name = "Кузня Крови"
        affs = { 10, 2, 12, 3 }
    end
    local lvlStr = (lvl and ("+" .. lvl) or "?")
    GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(string.format("%s — %s", lvlStr, name), 1, 0.82, 0, 1)
    if affs and #affs > 0 then
        GameTooltip:AddLine(" ")
        for i, id in ipairs(affs) do
            if i > 1 then GameTooltip:AddLine(" ") end
            local aname, desc, icon = MPT:GetAffixInfo(id)
            local dispName = (type(aname) == "string" and #aname > 0) and aname or ("#" .. id)
            local lineText = dispName
            if type(icon) == "string" and #icon > 0 then
                local filename = icon:match("[^\\/]+$") or icon:gsub("^.*[\\/]", "")
                filename = filename:gsub("%.blp$", "")
                if filename ~= "" then
                    lineText = "|T" .. "Interface\\Icons\\" .. filename .. ":14:14|t " .. dispName
                end
            end
            GameTooltip:AddLine(lineText, 1, 0.82, 0, 1)
            if type(desc) == "string" and #desc > 0 then
                local cleanDesc = desc:gsub("\\n", "\n"):gsub("\\r", "")
                GameTooltip:AddLine(cleanDesc, 1, 1, 1, 1)
            end
        end
    end
    local limit2, limit3 = GetPlus2Plus3Limits()
    if (state.running or state.completed) and state.elapsed and (limit2 or limit3) then
        GameTooltip:AddLine(" ")
        if limit2 then
            local rem = math.max(0, limit2 - state.elapsed)
            GameTooltip:AddLine(string.format("До +2: %s", FormatTime(rem)), 0.6, 1, 0.6, 1)
        end
        if limit3 then
            local rem = math.max(0, limit3 - state.elapsed)
            GameTooltip:AddLine(string.format("До +3: %s", FormatTime(rem)), 0.6, 1, 0.6, 1)
        end
    end
    GameTooltip:Show()
end

-- Невидимый фрейм поверх аффиксов — показывает тултип при наведении
affixTooltipFrame = CreateFrame("Frame", nil, frame)
affixTooltipFrame:SetPoint("TOPLEFT",  frame, "TOPLEFT",  0, -22)
affixTooltipFrame:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, -64)
affixTooltipFrame:EnableMouse(true)
affixTooltipFrame:SetScript("OnMouseDown", function(_, button)
    if button == "LeftButton" then frame:StartMoving() end
end)
affixTooltipFrame:SetScript("OnMouseUp", function()
    frame:StopMovingOrSizing()
    if MPT.charDb then
        MPT.charDb.timerPos = { x = frame:GetLeft() or 0, y = frame:GetTop() or 0 }
    end
end)
affixTooltipFrame:SetScript("OnEnter", function(self)
    ShowAffixTooltip(self)
end)
affixTooltipFrame:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

-- Последний bossTopY от UpdateTimerLayout (используется в SetBossCount/UpdateBossDisplay)
local lastBossTopY = -80
local lastBossCount = 0

-- ============================================================
-- Управление строками боссов
-- UpdateBossLayout: пересчитывает позиции строк по их актуальной высоте,
-- затем двигает forces/deaths и меняет высоту фрейма.
-- Вызывается после любого изменения текста или видимости строк.
-- ============================================================
local function UpdateBossLayout(count, bossTopY)
    if collapsed then return end  -- в свёрнутом режиме геометрию не трогаем
    count    = math.max(0, math.min(count or lastBossCount, MAX_BOSSES))
    bossTopY = bossTopY or lastBossTopY
    lastBossTopY = bossTopY
    lastBossCount = count
    local forcesY, deathsY
    local FORCES_BAR_H = 16  -- высота бара (должна совпадать с SetHeight выше)
    if count == 0 then
        forcesY = bossTopY - 2
    else
        local y = bossTopY - BOSS_FIRST_OFFSET
        for i = 1, count do
            local fs = frame.bossLines[i]
            local h  = math.max(frame.bossLineH[i], fs:GetStringHeight() or 0)
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, y)
            y = y - h - 2
        end
        forcesY = y - 2
    end
    -- deathsY: под баром + 10px зазор
    deathsY = forcesY - FORCES_BAR_H - 10

    frame.forces:ClearAllPoints()
    frame.forces:SetPoint("TOPLEFT",  frame, "TOPLEFT",  8, forcesY)
    frame.forces:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, forcesY)

    frame.forcesBarContainer:ClearAllPoints()
    frame.forcesBarContainer:SetPoint("TOPLEFT",  frame, "TOPLEFT",  8, forcesY)
    frame.forcesBarContainer:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, forcesY)

    frame.deaths:ClearAllPoints()
    frame.deaths:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, deathsY)

    frame:SetHeight(-deathsY + 24)
end

local function SetBossCount(count)
    count = math.max(0, math.min(count, MAX_BOSSES))
    for i = 1, MAX_BOSSES do
        if i <= count then
            frame.bossLines[i]:Show()
        else
            frame.bossLines[i]:Hide()
        end
    end
    UpdateBossLayout(count)
end

-- ============================================================
-- Перетаскивание (паттерн из Omen: OnMouseDown/OnMouseUp)
-- Разрешено только в режиме превью (не во время активного ключа)
-- ============================================================
frame:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" and not state.running and not state.completed then
        self:StartMoving()
    end
end)

frame:SetScript("OnMouseUp", function(self)
    self:StopMovingOrSizing()
    if MPT.charDb then
        MPT.charDb.timerPos = {
            x = self:GetLeft() or 0,
            y = self:GetTop()  or 0,
        }
    end
end)

-- ============================================================
-- UpdateTimerLayout: позиционирует timer, plus2, plus3.
-- Возвращает Y нижней границы блока — от неё начинаются строки боссов.
-- ============================================================
local function UpdateTimerLayout(showPlus2, showPlus3)
    -- Если аргументы не переданы — читаем текущее состояние
    if showPlus2 == nil then showPlus2 = frame.plus2:IsShown() and true or false end
    if showPlus3 == nil then showPlus3 = frame.plus3:IsShown() and true or false end

    -- affixes на -24; высота зависит от контента
    local affixBottom = -24
    if frame.affixes:IsShown() then
        local h = math.max(14, frame.affixes:GetStringHeight() or 14)
        affixBottom = affixBottom - h
    end
    if frame.affixesLine2:IsShown() then
        local line2H = math.max(14, frame.affixesLine2:GetStringHeight() or 14)
        affixBottom = affixBottom - 4 - line2H
    end
    if frame.affixesIcons:IsShown() then
        affixBottom = affixBottom - 8 - AFFIX_ICON_SIZE
    end
    local timerY = affixBottom

    frame.timer:ClearAllPoints()
    frame.timer:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, timerY)

    -- Под таймером: 20pt ≈ 24px высота
    local timerBottom = timerY - 24
    local bossTopY

    if showPlus2 or showPlus3 then
        local lineY = timerBottom - 2
        if showPlus2 then
            frame.plus2:ClearAllPoints()
            frame.plus2:SetPoint("TOPLEFT",  frame, "TOPLEFT",  8, lineY)
            frame.plus2:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, lineY)
            frame.plus2:Show()
            lineY = lineY - 18
        else
            frame.plus2:Hide()
        end
        if showPlus3 then
            frame.plus3:ClearAllPoints()
            frame.plus3:SetPoint("TOPLEFT",  frame, "TOPLEFT",  8, lineY)
            frame.plus3:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, lineY)
            frame.plus3:Show()
            lineY = lineY - 18
        else
            frame.plus3:Hide()
        end
        bossTopY = lineY - 4
    else
        frame.plus2:Hide()
        frame.plus3:Hide()
        bossTopY = timerBottom - 4
    end

    return bossTopY
end

SetForcesMode = function(useBar)
    if useBar then
        frame.forces:Hide()
        frame.forcesBarContainer:Show()
    else
        frame.forcesBarContainer:Hide()
        frame.forces:Show()
    end
end

-- ============================================================
-- Обновление UI
-- ============================================================
UpdateDisplay = function()
    if state.running then
        state.elapsed = GetTime() - state.startTime
    end

    -- Смерти: сначала пробуем API, fallback — локальный счётчик из ASMSG
    local deathCount, deathLost = 0, 0
    local dOk, d, t = pcall(function() return C_ChallengeMode.GetDeathCount() end)
    if dOk and type(d) == "number" then
        deathCount = d
        deathLost  = type(t) == "number" and t or (d * 5)
    else
        deathCount = localDeathCount
        deathLost  = localDeathLost
    end

    -- Лимиты и эффективное время (elapsed + штраф смертей)
    local limit2, limit3 = GetPlus2Plus3Limits()
    local baseLimit       -- базовый лимит (для общего таймера)
    if limit2 and limit3 then
        -- base = limit2 / 0.80 (limit2 = 80% от base)
        baseLimit = math.floor(limit2 / 0.80 + 0.5)
    end
    local effElapsed = (state.elapsed or 0) + deathLost

    -- Таймер: elapsed+deaths / baseLimit
    local active = state.running or state.completed
    if active and state.elapsed then
        local elapsedStr = FormatTime(effElapsed)
        local limitStr   = baseLimit and FormatTime(baseLimit) or nil
        local timerText  = limitStr and (elapsedStr .. "/" .. limitStr) or elapsedStr

        local overBase = baseLimit and (effElapsed > baseLimit)
        if state.completed then
            if overBase then
                frame.timer:SetTextColor(1, 0.2, 0.2)
            else
                frame.timer:SetTextColor(0.2, 1, 0.2)
            end
            frame.timer:SetText(timerText .. " [done]")
        else
            if overBase then
                frame.timer:SetTextColor(1, 0.2, 0.2)
            else
                frame.timer:SetTextColor(1, 1, 1)
            end
            frame.timer:SetText(timerText)
        end
    else
        frame.timer:SetTextColor(0.5, 0.5, 0.5)
        frame.timer:SetText("--:--")
    end

    -- В свёрнутом режиме показываем "12:10  +15  Данж" в заголовке
    if collapsed then
        if active and state.elapsed then
            local lvlStr  = state.level and ("+" .. state.level) or "?"
            local dungeon = state.dungeonName or ""
            frame.title:SetText(string.format("%s  %s  %s", FormatTime(effElapsed), lvlStr, dungeon))
        else
            frame.title:SetText(lastTitleText)
        end
        return
    end

    -- Строки +2 / +3
    local showPlus2, showPlus3 = false, false
    if active and state.elapsed and (limit2 or limit3) then
        if limit2 then
            showPlus2 = true
            local rem = limit2 - effElapsed
            if rem < 0 then
                frame.plus2:SetText(string.format("|cff888888+2 (%s)|r", FormatTime(limit2)))
            else
                frame.plus2:SetText(string.format("+2 (%s)", FormatTime(limit2)))
            end
        end
        if limit3 then
            showPlus3 = true
            local rem = limit3 - effElapsed
            if rem < 0 then
                frame.plus3:SetText(string.format("|cff888888+3 (%s)|r", FormatTime(limit3)))
            else
                frame.plus3:SetText(string.format("+3 (%s)", FormatTime(limit3)))
            end
        end
    end

    local bossTopY = UpdateTimerLayout(showPlus2, showPlus3)
    if state.bosses and #state.bosses > 0 then
        UpdateBossLayout(math.min(#state.bosses, MAX_BOSSES), bossTopY)
    else
        UpdateBossLayout(0, bossTopY)
    end

    -- Прогресс (одно значение = %, 0-100)
    local forces = GetForces()
    local useBar = MPT.db and MPT.db.forcesBar
    if forces then
        local pctColor = forces >= 100 and "|cff00ff00" or ""
        local pctEnd   = forces >= 100 and "|r" or ""
        local baseText = string.format("%.1f%%", forces)
        if engagedForcesTotal >= 0.05 then
            local engagedCount = 0
            for _ in pairs(engagedGuids) do engagedCount = engagedCount + 1 end
            baseText = baseText .. string.format(" +%.2f%% (%d)", engagedForcesTotal, engagedCount)
        end
        if useBar then
            frame.forcesBar:SetValue(math.min(forces, 100))
            frame.forcesBar.text:SetText(pctColor .. baseText .. pctEnd)
        else
            frame.forces:SetText(string.format("Убито врагов: %s%s%s", pctColor, baseText, pctEnd))
        end
    else
        if useBar then
            frame.forcesBar:SetValue(0)
            frame.forcesBar.text:SetText("|cff888888—|r")
        else
            frame.forces:SetText("|cff888888Убито врагов: —|r")
        end
    end

    -- Смерти
    if deathCount > 0 then
        frame.deaths:SetText(string.format(
            "|cffff4444Смертей: %d (+%dс)|r", deathCount, deathLost))
    else
        frame.deaths:SetText("|cff888888Смертей: 0|r")
    end
end

-- Forward declaration: UpdateBossDisplay определена ниже, после ShowPreview.
-- Нужна здесь чтобы StartTimer мог её вызвать.
local UpdateBossDisplay

-- ============================================================
-- OnUpdate — тик 0.1с (только пока фрейм видим)
-- ============================================================
local throttle = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    throttle = throttle + elapsed
    if throttle < 0.1 then return end
    throttle = 0
    if state.running or state.completed then
        UpdateDisplay()
    end
end)

frame:Hide()

-- ============================================================
-- Polling фрейм — детекция старта/стопа ключа
-- CHALLENGE_MODE_START не стреляет на Sirus!
-- Опрашиваем IsChallengeModeActive() раз в секунду.
-- Фрейм НЕ скрывается — OnUpdate всегда работает.
-- ============================================================
local pollFrame = CreateFrame("Frame")
local pollThrottle = 0

pollFrame:SetScript("OnUpdate", function(_, elapsed)
    pollThrottle = pollThrottle + elapsed
    if pollThrottle < 1 then return end
    pollThrottle = 0

    local inInstance, instanceType = IsInInstance()
    if not inInstance or instanceType ~= "party" then return end
    local _, _, diffID = GetInstanceInfo()
    if diffID ~= 3 then return end

    local ok, isActive = pcall(function() return C_ChallengeMode.IsChallengeModeActive() end)
    if not ok then return end

    if isActive and not state.running and not state.completed then
        MPT:StartTimer()
    elseif not isActive and state.running then
        MPT:StopTimer(false)
        frame:Hide()
    end
end)

-- ============================================================
-- Публичный API
-- ============================================================

-- ============================================================
-- Скрытие дефолтного M+ трекера Sirus
-- Имена фреймов определены экспериментально (/mpt findframes)
-- ============================================================
local sirusTrackerFrames = {
    "ScenarioObjectiveTrackerPoolFrame",
    "ScenarioObjectiveTrackerFrame",
    "ObjectiveTrackerFrame",
}
local sirusTrackerWasShown = {}

local function HideSirusTracker()
    for _, name in ipairs(sirusTrackerFrames) do
        local f = _G[name]
        if f and type(f.IsShown) == "function" then
            local ok, shown = pcall(function() return f:IsShown() end)
            sirusTrackerWasShown[name] = ok and shown or false
            if ok and shown then
                pcall(function() f:Hide() end)
            end
        end
    end
end

local function RestoreSirusTracker()
    for _, name in ipairs(sirusTrackerFrames) do
        if sirusTrackerWasShown[name] then
            local f = _G[name]
            if f and type(f.Show) == "function" then
                pcall(function() f:Show() end)
            end
            sirusTrackerWasShown[name] = false
        end
    end
end

function MPT:LoadTimerPosition()
    frame:ClearAllPoints()
    local scale = (self.db and self.db.scale) or 1.0
    frame:SetScale(scale)
    local pos = self.charDb and self.charDb.timerPos
    if pos and pos.x then
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos.x, pos.y)
    else
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", 250, 300)
    end
end

-- Последний набор affix ID, переданных в RefreshAffixes.
-- Нужен чтобы RefreshCurrentAffixes работал и в превью, и в активном ключе.
local lastDisplayedAffixIDs = nil

-- Обновляет строки аффиксов в зависимости от настроек affixText / affixIcons.
-- Опции независимы: можно показывать обе, одну, или ни одной.
-- Если обе — сначала текст, под ним иконки.
-- affixIDs: таблица id аффиксов или nil.
function MPT:RefreshAffixes(affixIDs)
    lastDisplayedAffixIDs = affixIDs
    local useText  = self.db and self.db.affixText
    local useIcons = self.db and self.db.affixIcons

    -- Сброс
    frame.affixes:SetText("")
    frame.affixes:Hide()
    frame.affixesLine2:SetText("")
    frame.affixesLine2:Hide()
    frame.affixesIcons:Hide()
    for i = 1, MAX_AFFIX_ICONS do frame.affixIconFrames[i]:Hide() end

    if not affixIDs or #affixIDs == 0 then
        local bossTopY = UpdateTimerLayout()
        UpdateBossLayout(lastBossCount, bossTopY)
        return
    end

    -- Текстовый блок
    if useText then
        local line1, line2 = GetAffixStrings(affixIDs)
        local prefix, suffix = "|cffaaaaaa", "|r"
        frame.affixes:SetText(line1 and (prefix .. line1 .. suffix) or "")
        frame.affixes:Show()
        if line2 and #line2 > 0 then
            frame.affixesLine2:SetText(prefix .. line2 .. suffix)
            frame.affixesLine2:Show()
        end
    end

    -- Блок иконок (скруглённые Frame+Texture)
    if useIcons then
        -- Скрываем все иконки из пула
        for i = 1, MAX_AFFIX_ICONS do
            frame.affixIconFrames[i]:Hide()
        end
        -- Якорь контейнера: под последней видимой текстовой строкой
        frame.affixesIcons:ClearAllPoints()
        if frame.affixesLine2:IsShown() then
            frame.affixesIcons:SetPoint("TOPLEFT", frame.affixesLine2, "BOTTOMLEFT",  0, -8)
        elseif frame.affixes:IsShown() then
            frame.affixesIcons:SetPoint("TOPLEFT", frame.affixes,      "BOTTOMLEFT",  0, -8)
        else
            frame.affixesIcons:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -24)
        end
        -- Расставляем иконки горизонтально
        local count = math.min(#affixIDs, MAX_AFFIX_ICONS)
        local totalW = count * AFFIX_ICON_SIZE + math.max(0, count - 1) * AFFIX_ICON_GAP
        frame.affixesIcons:SetWidth(math.max(totalW, 1))
        frame.affixesIcons:SetHeight(AFFIX_ICON_SIZE)
        for i = 1, count do
            local id = affixIDs[i]
            local _, _, icon = GetAffixInfoSafe(id)
            local iconFrame = frame.affixIconFrames[i]
            iconFrame:ClearAllPoints()
            if i == 1 then
                iconFrame:SetPoint("TOPLEFT", frame.affixesIcons, "TOPLEFT", 0, 0)
            else
                iconFrame:SetPoint("TOPLEFT", frame.affixIconFrames[i-1], "TOPRIGHT", AFFIX_ICON_GAP, 0)
            end
            if type(icon) == "number" and icon > 0 then
                -- Sirus может возвращать числовой fileDataID
                iconFrame.tex:SetTexture(icon)
            elseif type(icon) == "string" and #icon > 0 then
                local filename = icon:match("[^\\/]+$") or icon
                filename = filename:gsub("%.blp$", "")
                if filename ~= "" then
                    iconFrame.tex:SetTexture("Interface\\Icons\\" .. filename)
                else
                    iconFrame.tex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                end
            else
                iconFrame.tex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
            end
            iconFrame:Show()
        end
        frame.affixesIcons:Show()
    end

    local bossTopY = UpdateTimerLayout()
    UpdateBossLayout(lastBossCount, bossTopY)
end

function MPT:RefreshCurrentAffixes()
    self:RefreshAffixes(lastDisplayedAffixIDs)
end

function MPT:RefreshForcesMode()
    SetForcesMode(self.db and self.db.forcesBar or false)
end

function MPT:StartTimer()
    state.running   = true
    state.completed = false
    ClearEngaged()
    HideSirusTracker()
    localDeathCount = 0
    localDeathLost  = 0

    -- Восстановление после /reload: charDb.keyStartUnix сохраняет unix-время старта.
    -- time() — секунды с эпохи, переживает reload. GetTime() — нет.
    local savedUnix = self.charDb and self.charDb.keyStartUnix
    if savedUnix then
        -- Ключ уже шёл до reload — восстанавливаем elapsed и боссов
        local elapsed   = math.max(0, time() - savedUnix)
        state.startTime = GetTime() - elapsed
        state.elapsed   = elapsed
        -- Восстанавливаем боссов из charDb (сохраняются туда при получении ASMSG)
        if self.charDb and self.charDb.bosses then
            state.bosses = self.charDb.bosses
            UpdateBossDisplay()
        end
        if self.db and self.db.debug then
            self:Print("Таймер восстановлен после reload. Прошло: " .. FormatTime(elapsed))
        end
    else
        -- Новый ключ
        state.startTime = GetTime()
        state.elapsed   = 0
        if self.charDb then
            self.charDb.keyStartUnix = time()
        end
    end

    local lvl, affixes = GetKeystoneData()
    state.level       = lvl
    state.affixes     = affixes
    state.dungeonName = GetInstanceInfo()  -- первый возврат = имя инстанса (может быть на английском)
    -- mapID надёжнее имени — используем для поиска боссов
    local mapOk, mapID = pcall(function() return C_ChallengeMode.GetActiveChallengeMapID() end)
    state.mapID = (mapOk and type(mapID) == "number") and mapID or nil

    -- Заголовок: "+15 — Кузня Крови"
    local lvlStr = state.level and ("+" .. state.level) or "?"
    local name   = state.dungeonName or ""
    lastTitleText = string.format("|cffffff00%s|r \226\128\148 %s", lvlStr, name)
    frame.title:SetText(lastTitleText)

    -- Аффиксы
    self:RefreshAffixes(state.affixes)

    -- Сбрасываем боссов только при новом ключе (при restore придут из ASMSG снова)
    if not savedUnix then
        -- Пробуем загрузить список из статической базы (по mapID — надёжнее имени)
        local staticBosses = self:GetDungeonBosses(state.dungeonName, state.mapID)
        if staticBosses and #staticBosses > 0 then
            state.bosses = {}
            for _, bossName in ipairs(staticBosses) do
                table.insert(state.bosses, { name = bossName, killed = false })
            end
        else
            state.bosses = nil
            for i = 1, MAX_BOSSES do
                frame.bossLines[i]:SetText("")
                frame.bossLines[i]:Hide()
            end
        end
    end

    -- Отображаем боссов; после ASMSG UpdateBossDisplay обновит список
    if state.bosses and #state.bosses > 0 then
        UpdateBossDisplay()
    else
        SetBossCount(0)
    end

    SetForcesMode(self.db and self.db.forcesBar or false)
    frame:Show()
    UpdateDisplay()

    if self.db and self.db.debug and not savedUnix then
        self:Print("Таймер запущен. Ключ " .. lvlStr .. " " .. name)
    end
end

function MPT:StopTimer(completed)
    state.running   = false
    state.completed = completed == true
    ClearEngaged()
    RestoreSirusTracker()
    -- Очищаем сохранённое время и боссов — ключ завершён или покинут
    if self.charDb then
        self.charDb.keyStartUnix = nil
        self.charDb.bosses       = nil
    end
    UpdateDisplay()
    if self.db and self.db.debug then
        self:Print(string.format("Таймер остановлен. time=%s completed=%s",
            FormatTime(state.elapsed), tostring(completed)))
    end
end

function MPT:ShowTimer()
    self:LoadTimerPosition()
    SetBossCount(state.bosses and #state.bosses or 0)
    UpdateDisplay()
    frame:Show()
end

function MPT:HideTimer()
    frame:Hide()
end

function MPT:ToggleTimer()
    if frame:IsShown() then
        frame:Hide()
    else
        self:ShowTimer()
    end
end

function MPT:ShowPreview()
    if collapsed then SetCollapsed(false) end
    self:LoadTimerPosition()

    lastTitleText = "|cffffff00+15|r \226\128\148 Кузня Крови"
    frame.title:SetText(lastTitleText)
    -- Аффиксы превью
    local previewAffixIDs = { 10, 2, 12, 3 }
    self:RefreshAffixes(previewAffixIDs)

    frame.timer:SetTextColor(1, 1, 1)
    frame.timer:SetText("12:44/35:00")
    frame.plus2:SetText("+2 (28:00)")
    frame.plus3:SetText("+3 (22:24)")

    -- Боссы: берём из статической базы для Кузни Крови
    local previewDungeon = "Кузня Крови"
    local previewBossList = self:GetDungeonBosses(previewDungeon) or {}
    local previewTexts = {}
    for j, bossName in ipairs(previewBossList) do
        if j == 1 then
            previewTexts[j] = string.format("|cff888888[+] %s  2:03 (Рекорд 1:59, +0:04)|r", bossName)
        elseif j == 2 then
            previewTexts[j] = string.format("|cff888888[+] %s  4:51 (Рекорд 4:20, +0:31)|r", bossName)
        else
            previewTexts[j] = string.format("[ ] %s  \226\128\148", bossName)
        end
    end
    local previewCount = math.min(#previewTexts, MAX_BOSSES)
    for i = 1, previewCount do
        local fs = frame.bossLines[i]
        fs:SetText(previewTexts[i])
        local h = fs:GetStringHeight() or 0
        frame.bossLineH[i] = (h > BOSS_LINE_H1 + 2) and BOSS_LINE_H2 or BOSS_LINE_H1
        fs:Show()
    end
    for i = previewCount + 1, MAX_BOSSES do
        frame.bossLines[i]:Hide()
    end
    local previewBossTopY = UpdateTimerLayout(true, true)
    UpdateBossLayout(previewCount, previewBossTopY)

    local useForcesBar = MPT.db and MPT.db.forcesBar
    SetForcesMode(useForcesBar)
    -- Превью прогресса: 34.1% уже убито и показан пример спуленного пака
    -- с +5.40% и 7 мобами, как в реальном режиме ("+X.XX% (N)").
    if useForcesBar then
        frame.forcesBar:SetValue(34.1)
        frame.forcesBar.text:SetText("34.1% +5.40% (7)")
    else
        frame.forces:SetText("Убито врагов: 34.1% +5.40% (7)")
    end
    frame.deaths:SetText("|cffff4444Смертей: 2 (+10с)|r")

    frame:Show()
end

-- ============================================================
-- Боссы: парсинг ASMSG_INSTANCE_ENCOUNTERS_STATE и обновление UI
-- Формат: "Имя1;0;Имя2;0;..." — 0=жив, 1=убит
-- ============================================================
local function ParseEncounterState(msg)
    local bosses = {}
    for name, status in msg:gmatch("([^;]+);(%d+)") do
        table.insert(bosses, { name = name, killed = (status ~= "0") })
    end
    return bosses
end

-- ============================================================
-- Рекорды боссов: лучшее время боя (fd).
-- Хранятся в MPT.db.bossRecords[dungeonName][bossName]
-- ============================================================
local function GetBossRecord(bossName)
    if not MPT.db or not MPT.db.bossRecords then return nil end
    local dn = state.dungeonName
    if not dn then return nil end
    local dr = MPT.db.bossRecords[dn]
    return dr and dr[bossName] or nil
end

local function UpdateBossRecord(bossName, fightDuration)
    if not MPT.db or not state.dungeonName then return end
    if not MPT.db.bossRecords then MPT.db.bossRecords = {} end
    local records = MPT.db.bossRecords
    local dn = state.dungeonName
    if not records[dn] then records[dn] = {} end
    local dnRec = records[dn]
    local rec = dnRec[bossName]
    if not rec then
        dnRec[bossName] = { fd = fightDuration }
    elseif fightDuration and (not rec.fd or fightDuration < rec.fd) then
        rec.fd = fightDuration
    end
end

-- Форматирует отклонение от рекорда: +0:04 или -0:03
local function FormatDelta(current, record)
    local delta = current - record
    local sign  = delta >= 0 and "+" or "-"
    local abs   = math.abs(delta)
    return sign .. string.format("%d:%02d", math.floor(abs / 60), math.floor(abs % 60))
end

UpdateBossDisplay = function()
    if not state.bosses or #state.bosses == 0 then return end
    local count = math.min(#state.bosses, MAX_BOSSES)
    for i = 1, count do
        frame.bossLines[i]:Show()
    end
    for i = count + 1, MAX_BOSSES do
        frame.bossLines[i]:Hide()
    end
    for i = 1, count do
        local boss = state.bosses[i]
        local line
        if boss.killed then
            local fd = boss.fightDuration
            if fd then
                local fdStr = FormatTime(fd)
                local rec   = GetBossRecord(boss.name)
                if rec and rec.fd then
                    local delta = FormatDelta(fd, rec.fd)
                    line = string.format("|cff888888[+] %s  %s (Рекорд %s, %s)|r",
                        boss.name, fdStr, FormatTime(rec.fd), delta)
                else
                    line = string.format("|cff888888[+] %s  %s|r", boss.name, fdStr)
                end
            else
                -- Убит, но нет времени боя (ENCOUNTER_START не сработал)
                line = string.format("|cff888888[+] %s|r", boss.name)
            end
        else
            line = string.format("[ ] %s  \226\128\148", boss.name)
        end
        local fs = frame.bossLines[i]
        fs:SetText(line)
        local h = fs:GetStringHeight() or 0
        frame.bossLineH[i] = (h > BOSS_LINE_H1 + 2) and BOSS_LINE_H2 or BOSS_LINE_H1
    end
    UpdateBossLayout(count)
end

-- ============================================================
-- События
-- ============================================================
-- WotLK GUID → NPC ID (hex позиции 9-12)
local function GetNpcIdFromGUID(guid)
    if not guid or string.sub(guid, 1, 3) ~= "0xF" then return nil end
    return tonumber(string.sub(guid, 9, 12), 16) or nil
end

local evFrame = CreateFrame("Frame")
evFrame:RegisterEvent("CHALLENGE_MODE_START")       -- fallback (на Sirus скорее всего не стреляет)
evFrame:RegisterEvent("CHALLENGE_MODE_COMPLETED")   -- завершение ключа
evFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
evFrame:RegisterEvent("CHAT_MSG_ADDON")             -- ASMSG_INSTANCE_ENCOUNTERS_STATE — список боссов
evFrame:RegisterEvent("BOSS_KILL")                  -- убийство босса
evFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED") -- агро и смерти мобов
-- ENCOUNTER_START/END: добавлены в WotLK, но неизвестно стреляют ли на Sirus
pcall(function() evFrame:RegisterEvent("ENCOUNTER_START") end)
pcall(function() evFrame:RegisterEvent("ENCOUNTER_END")   end)

evFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "CHALLENGE_MODE_START" then
        if not state.running then
            MPT:StartTimer()
        end

    elseif event == "CHALLENGE_MODE_COMPLETED" then
        MPT:StopTimer(true)
        frame:Show()

    elseif event == "PLAYER_ENTERING_WORLD" then
        MPT:LoadTimerPosition()
        local inInstance, instanceType = IsInInstance()
        local _, _, diffID = GetInstanceInfo()
        local inMythicDungeon = inInstance and instanceType == "party" and diffID == 3
        local cmOk, isActive = pcall(function() return C_ChallengeMode.IsChallengeModeActive() end)
        -- Консервативная проверка: при /reload внутри ключа IsInInstance может ещё
        -- не вернуть правильный результат — дополнительно проверяем IsChallengeModeActive.
        -- Очищаем только если ОБА источника говорят что ключа нет.
        local keyActive = (cmOk and isActive == true) or inMythicDungeon
        if not keyActive and MPT.charDb then
            MPT.charDb.keyStartUnix = nil
            MPT.charDb.bosses       = nil
        end
        if not keyActive and not state.running then
            state.completed = false
            state.bosses    = nil
            frame:Hide()
        end
        -- При любом PLAYER_ENTERING_WORLD во время активного ключа (respawn после вайпа)
        -- сбрасываем engaged таблицу — все мобы на паке уже мертвы или сброшены
        if state.running then
            ClearEngaged()
        end

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, msg = ...
        -- ASMSG_CHALLENGE_MODE_UPDATE_DEATH_COUNT: "deaths;timeLost_sec"
        if prefix == "ASMSG_CHALLENGE_MODE_UPDATE_DEATH_COUNT" and msg then
            local d, t = msg:match("^(%d+);(%d+)$")
            if d then
                localDeathCount = tonumber(d) or 0
                localDeathLost  = tonumber(t) or (localDeathCount * 5)
            end
        end
        -- ASMSG_INSTANCE_ENCOUNTERS_STATE: список боссов при старте ключа
        if prefix == "ASMSG_INSTANCE_ENCOUNTERS_STATE" and msg and #msg > 0 then
            local newBosses = ParseEncounterState(msg)
            -- Сливаем с текущим состоянием: сохраняем killTime/fightDuration для уже убитых
            local oldBosses = state.bosses
            if oldBosses then
                for _, newBoss in ipairs(newBosses) do
                    for _, oldBoss in ipairs(oldBosses) do
                        if oldBoss.name == newBoss.name and oldBoss.killed then
                            -- Сохраняем локальное состояние (ASMSG может прислать status=0 для убитого босса)
                            newBoss.killed        = true
                            newBoss.fightDuration = oldBoss.fightDuration
                            newBoss.isNewFdPB     = oldBoss.isNewFdPB
                            break
                        end
                    end
                end
            end
            state.bosses = newBosses
            -- Сохраняем в charDb — переживёт /reload
            if MPT.charDb then MPT.charDb.bosses = state.bosses end
            UpdateBossDisplay()
            if MPT.db and MPT.db.debug then
                MPT:Print("Боссы: " .. #state.bosses .. " / " .. msg)
            end
        end

    elseif event == "ENCOUNTER_START" then
        -- args: encounterID, encounterName, difficultyID, groupSize
        if state.running then
            state.encounterStartElapsed = state.elapsed
            if MPT.db and MPT.db.debug then
                local _, encName = ...
                MPT:Print("ENCOUNTER_START: " .. tostring(encName)
                    .. "  elapsed=" .. FormatTime(state.elapsed))
            end
        end

    elseif event == "ENCOUNTER_END" then
        -- args: encounterID, encounterName, difficultyID, groupSize, success (1=kill, 0=wipe)
        local _, _, _, _, success = ...
        -- При любом исходе (убийство или вайп) зачищаем engaged мобов:
        -- при убийстве — мобы комнаты мертвы; при вайпе — начинаем заново
        ClearEngaged()
        if success ~= 1 then
            state.encounterStartElapsed = nil
        end

    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        if not state.running then return end
        local _, eventType, a3, _, _, a6, a7, a8, a9 = ...
        -- Определяем WotLK vs Cata+ формат по третьему аргументу
        local destGUID, destFlags
        if type(a3) == "boolean" then
            destGUID, destFlags = a7, a9   -- Cata+: hideCaster=a3
        else
            destGUID, destFlags = a6, a8   -- WotLK
        end

        -- Фильтр: только враждебные/нейтральные NPC (не питомцы, не стражи)
        local function isHostileNpc(flags)
            if not flags then return false end
            local HOSTILE  = 0x00000040
            local NEUTRAL  = 0x00000020
            local IS_NPC   = 0x00000800
            local IS_PET   = 0x00001000
            local IS_GUARD = 0x00002000
            local CTRL_PLR = 0x00000100
            return (bit.band(flags, HOSTILE) ~= 0 or bit.band(flags, NEUTRAL) ~= 0)
               and bit.band(flags, IS_NPC)   ~= 0
               and bit.band(flags, IS_PET)   == 0
               and bit.band(flags, IS_GUARD) == 0
               and bit.band(flags, CTRL_PLR) == 0
        end

        if eventType == "UNIT_DIED" or eventType == "PARTY_KILL" then
            -- Моб убит — убираем из engaged
            if isHostileNpc(destFlags) then
                DisengageGuid(destGUID)
            end
        elseif eventType == "SWING_DAMAGE" or eventType == "SPELL_DAMAGE"
            or eventType == "RANGE_DAMAGE" or eventType == "SPELL_PERIODIC_DAMAGE" then
            -- Первый хит по мобу — считаем его вступившим в бой
            if isHostileNpc(destFlags) then
                local npcID = GetNpcIdFromGUID(destGUID)
                EngageGuid(destGUID, npcID)
            end
        end

    elseif event == "BOSS_KILL" then
        local _, bossName = ...
        if state.bosses and bossName then
            for _, boss in ipairs(state.bosses) do
                if boss.name == bossName then
                    boss.killed = true

                    -- Длительность боя (только если ENCOUNTER_START сработал)
                    if state.encounterStartElapsed and state.running then
                        boss.fightDuration = state.elapsed - state.encounterStartElapsed
                        state.encounterStartElapsed = nil
                    end

                    -- Обновляем рекорд и PB-статус
                    if boss.fightDuration then
                        local oldRec = GetBossRecord(boss.name)
                        boss.isNewFdPB = oldRec and oldRec.fd
                                         and boss.fightDuration < oldRec.fd or false
                        UpdateBossRecord(boss.name, boss.fightDuration)
                    end
                    break
                end
            end
            UpdateBossDisplay()
        end
    end
end)
