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
    bosses                = nil,  -- list of {name, killed, killTime}  killTime = elapsed от старта ключа при убийстве
    encounterStartElapsed = nil,  -- elapsed при ENCOUNTER_START текущего боя
    wasPaused             = false,  -- для коррекции startTime при снятии паузы
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
-- Цвета из настроек (кастомизация)
-- ============================================================
local COLOR_DEFAULTS = {
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

local function GetColor(key)
    local def = COLOR_DEFAULTS[key]
    if MPT.GetStyleColor then
        local r, g, b = MPT:GetStyleColor(key, def)
        if type(r) == "number" and type(g) == "number" and type(b) == "number" then
            return r, g, b
        end
    end
    if MPT.db and MPT.db[key] and type(MPT.db[key].r) == "number" and type(MPT.db[key].g) == "number" and type(MPT.db[key].b) == "number" then
        return MPT.db[key].r, MPT.db[key].g, MPT.db[key].b
    end
    if def then return def.r, def.g, def.b end
    return 1, 1, 1
end

local function GetStyleOption(key, fallback)
    if MPT.GetStyleOption then
        return MPT:GetStyleOption(key, fallback)
    end
    if MPT.db and MPT.db[key] ~= nil then
        return MPT.db[key]
    end
    return fallback
end

local function RoundToPixel(v, scale)
    local s = (type(scale) == "number" and scale > 0) and scale or 1
    if type(v) ~= "number" then return 0 end
    return math.floor(v * s + 0.5) / s
end

local function IsSecondStyle()
    return MPT.GetActiveStyleId and MPT:GetActiveStyleId() == "second"
end

local function IsArcadeStyle()
    return MPT.GetActiveStyleId and MPT:GetActiveStyleId() == "arcade"
end

local function IsCustomStyle()
    return IsSecondStyle() or IsArcadeStyle()
end

local function RGBToHex(r, g, b)
    return string.format("|cff%02x%02x%02x", math.floor(r * 255), math.floor(g * 255), math.floor(b * 255))
end

-- ============================================================
-- Вспомогательные функции
-- ============================================================

local function FormatTime(sec)
    if not sec or sec < 0 then sec = 0 end
    return string.format("%d:%02d", math.floor(sec / 60), math.floor(sec % 60))
end

-- Форматирует убывающее время: может быть отрицательным → "-M:SS"
local function FormatCountdown(sec)
    if not sec then return "0:00" end
    if sec < 0 then
        local abs = -sec
        return string.format("-%d:%02d", math.floor(abs / 60), math.floor(abs % 60))
    end
    return string.format("%d:%02d", math.floor(sec / 60), math.floor(sec % 60))
end

local function GetCurrentStyleId()
    if MPT.GetActiveStyleId then
        return MPT:GetActiveStyleId() or "default"
    end
    return (MPT.db and MPT.db.activeStyle) or "default"
end

local SaveTimerPosition

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
local NotifyDisplayChanged
local lastDisplayedAffixIDs

local frame = CreateFrame("Frame", "MPTTimerFrame", UIParent)
frame:SetWidth(280)
local ARCADE_WIDTH = 300
-- Высота задаётся в SetBossCount; начальная — компактная (0 боссов)
local COMPACT_HEIGHT = 172  -- пересчитано при BOSS_LINE_HEIGHT=30
frame:SetHeight(COMPACT_HEIGHT)
frame:SetFrameStrata("HIGH")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)

local function SnapFrameToPixelGrid()
    if not frame then return end
    local left = frame:GetLeft()
    local top = frame:GetTop()
    local scale = frame:GetEffectiveScale() or 1
    if not left or not top then return end
    local snappedLeft = RoundToPixel(left, scale)
    local snappedTop = RoundToPixel(top, scale)
    if math.abs(snappedLeft - left) < 1e-6 and math.abs(snappedTop - top) < 1e-6 then return end
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", snappedLeft, snappedTop)
end

SaveTimerPosition = function()
    if not MPT.charDb then return end
    local x = frame:GetLeft() or 0
    local y = frame:GetTop() or 0
    local sid = GetCurrentStyleId()
    if type(MPT.charDb.timerPosByStyle) ~= "table" then
        MPT.charDb.timerPosByStyle = {}
    end
    MPT.charDb.timerPosByStyle[sid] = { x = x, y = y }
    -- Backward compatibility: keep legacy slot updated
    MPT.charDb.timerPos = { x = x, y = y }
end

local isDraggingFrame = false
local function StartFrameDrag()
    if state.running or state.completed or (MPT.db and MPT.db.locked) then return end
    isDraggingFrame = true
    frame:StartMoving()
end

local function StopFrameDrag()
    if isDraggingFrame then
        frame:StopMovingOrSizing()
        isDraggingFrame = false
    else
        frame:StopMovingOrSizing()
    end
    SnapFrameToPixelGrid()
    SaveTimerPosition()
end

-- Лёгкий тёмный фон для читаемости текста (прозрачный)
local bg = frame:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints(frame)
bg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
bg:SetVertexColor(0, 0, 0, 0)

local arcadeFrame = CreateFrame("Frame", nil, frame)
arcadeFrame:SetAllPoints(frame)
arcadeFrame:SetFrameLevel(frame:GetFrameLevel() - 1)
local arcadeUnifiedBg = arcadeFrame:CreateTexture(nil, "BACKGROUND")
arcadeUnifiedBg:SetAllPoints(arcadeFrame)
arcadeUnifiedBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
arcadeUnifiedBg:Hide()
local arcadeMiddleBg = arcadeFrame:CreateTexture(nil, "BACKGROUND")
arcadeMiddleBg:SetPoint("TOPLEFT", arcadeFrame, "TOPLEFT", 0, -32)
arcadeMiddleBg:SetPoint("TOPRIGHT", arcadeFrame, "TOPRIGHT", 0, -32)
arcadeMiddleBg:SetPoint("BOTTOMLEFT", arcadeFrame, "BOTTOMLEFT", 0, 34)
arcadeMiddleBg:SetPoint("BOTTOMRIGHT", arcadeFrame, "BOTTOMRIGHT", 0, 34)
arcadeMiddleBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
local arcadeMiddleBorder = arcadeFrame:CreateTexture(nil, "BORDER")
arcadeMiddleBorder:SetPoint("TOPLEFT", arcadeFrame, "TOPLEFT", 0, -32)
arcadeMiddleBorder:SetPoint("TOPRIGHT", arcadeFrame, "TOPRIGHT", 0, -32)
arcadeMiddleBorder:SetPoint("BOTTOMLEFT", arcadeFrame, "BOTTOMLEFT", 0, 34)
arcadeMiddleBorder:SetPoint("BOTTOMRIGHT", arcadeFrame, "BOTTOMRIGHT", 0, 34)
arcadeMiddleBorder:SetTexture("Interface\\BUTTONS\\WHITE8X8")
arcadeMiddleBorder:Hide()
local arcadeHeaderBg = arcadeFrame:CreateTexture(nil, "BORDER")
arcadeHeaderBg:SetPoint("TOPLEFT", arcadeFrame, "TOPLEFT", 0, 0)
arcadeHeaderBg:SetPoint("TOPRIGHT", arcadeFrame, "TOPRIGHT", 0, 0)
arcadeHeaderBg:SetHeight(32)
arcadeHeaderBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
local arcadeHeaderBorder = arcadeFrame:CreateTexture(nil, "BORDER")
arcadeHeaderBorder:SetPoint("TOPLEFT", arcadeFrame, "TOPLEFT", 0, 0)
arcadeHeaderBorder:SetPoint("TOPRIGHT", arcadeFrame, "TOPRIGHT", 0, 0)
arcadeHeaderBorder:SetHeight(32)
arcadeHeaderBorder:SetTexture("Interface\\BUTTONS\\WHITE8X8")
local arcadeBottomBg = arcadeFrame:CreateTexture(nil, "BORDER")
arcadeBottomBg:SetPoint("BOTTOMLEFT", arcadeFrame, "BOTTOMLEFT", 0, 0)
arcadeBottomBg:SetPoint("BOTTOMRIGHT", arcadeFrame, "BOTTOMRIGHT", 0, 0)
arcadeBottomBg:SetHeight(34)
arcadeBottomBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
local arcadeBottomBorder = arcadeFrame:CreateTexture(nil, "BORDER")
arcadeBottomBorder:SetPoint("BOTTOMLEFT", arcadeFrame, "BOTTOMLEFT", 8, 34)
arcadeBottomBorder:SetPoint("BOTTOMRIGHT", arcadeFrame, "BOTTOMRIGHT", -8, 34)
arcadeBottomBorder:SetHeight(1)
arcadeBottomBorder:SetTexture("Interface\\BUTTONS\\WHITE8X8")
local arcadeMidBorderLeft = arcadeFrame:CreateTexture(nil, "BORDER")
arcadeMidBorderLeft:SetTexture("Interface\\BUTTONS\\WHITE8X8")
arcadeMidBorderLeft:SetPoint("TOPLEFT", arcadeFrame, "TOPLEFT", 0, -32)
arcadeMidBorderLeft:SetPoint("BOTTOMLEFT", arcadeFrame, "BOTTOMLEFT", 0, 34)
arcadeMidBorderLeft:SetWidth(1)
local arcadeMidBorderRight = arcadeFrame:CreateTexture(nil, "BORDER")
arcadeMidBorderRight:SetTexture("Interface\\BUTTONS\\WHITE8X8")
arcadeMidBorderRight:SetPoint("TOPRIGHT", arcadeFrame, "TOPRIGHT", 0, -32)
arcadeMidBorderRight:SetPoint("BOTTOMRIGHT", arcadeFrame, "BOTTOMRIGHT", 0, 34)
arcadeMidBorderRight:SetWidth(1)
local arcadeCornerSize = 16
local arcadeCornerOverlap = 2
local arcadeUseTopSegmentMask = false
local arcadeOuterTop = frame:CreateTexture(nil, "OVERLAY")
arcadeOuterTop:SetTexture("Interface\\BUTTONS\\WHITE8X8")
arcadeOuterTop:SetPoint("TOPLEFT", frame, "TOPLEFT", arcadeCornerSize - arcadeCornerOverlap, 0)
arcadeOuterTop:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(arcadeCornerSize - arcadeCornerOverlap), 0)
arcadeOuterTop:SetHeight(1)
arcadeOuterTop:Hide()

local arcadeOuterBottom = frame:CreateTexture(nil, "OVERLAY")
arcadeOuterBottom:SetTexture("Interface\\BUTTONS\\WHITE8X8")
arcadeOuterBottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", arcadeCornerSize - arcadeCornerOverlap, 0)
arcadeOuterBottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -(arcadeCornerSize - arcadeCornerOverlap), 0)
arcadeOuterBottom:SetHeight(1)
arcadeOuterBottom:Hide()

local arcadeOuterLeft = frame:CreateTexture(nil, "OVERLAY")
arcadeOuterLeft:SetTexture("Interface\\BUTTONS\\WHITE8X8")
arcadeOuterLeft:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -(arcadeCornerSize - arcadeCornerOverlap))
arcadeOuterLeft:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, arcadeCornerSize - arcadeCornerOverlap)
arcadeOuterLeft:SetWidth(1)
arcadeOuterLeft:Hide()

local arcadeOuterRight = frame:CreateTexture(nil, "OVERLAY")
arcadeOuterRight:SetTexture("Interface\\BUTTONS\\WHITE8X8")
arcadeOuterRight:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -(arcadeCornerSize - arcadeCornerOverlap))
arcadeOuterRight:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, arcadeCornerSize - arcadeCornerOverlap)
arcadeOuterRight:SetWidth(1)
arcadeOuterRight:Hide()

local arcadeOuterCornerTL = frame:CreateTexture(nil, "OVERLAY")
arcadeOuterCornerTL:SetSize(arcadeCornerSize, arcadeCornerSize)
arcadeOuterCornerTL:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
arcadeOuterCornerTL:SetTexture("Interface\\AddOns\\MythicPlusTimer\\Media\\arcade_corner_mask.blp")
arcadeOuterCornerTL:SetTexCoord(0, 1, 0, 1)
arcadeOuterCornerTL:Hide()

local arcadeOuterCornerTR = frame:CreateTexture(nil, "OVERLAY")
arcadeOuterCornerTR:SetSize(arcadeCornerSize, arcadeCornerSize)
arcadeOuterCornerTR:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
arcadeOuterCornerTR:SetTexture("Interface\\AddOns\\MythicPlusTimer\\Media\\arcade_corner_mask.blp")
arcadeOuterCornerTR:SetTexCoord(1, 0, 0, 1)
arcadeOuterCornerTR:Hide()

local arcadeOuterCornerBL = frame:CreateTexture(nil, "OVERLAY")
arcadeOuterCornerBL:SetSize(arcadeCornerSize, arcadeCornerSize)
arcadeOuterCornerBL:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
arcadeOuterCornerBL:SetTexture("Interface\\AddOns\\MythicPlusTimer\\Media\\arcade_corner_mask.blp")
arcadeOuterCornerBL:SetTexCoord(0, 1, 1, 0)
arcadeOuterCornerBL:Hide()

local arcadeOuterCornerBR = frame:CreateTexture(nil, "OVERLAY")
arcadeOuterCornerBR:SetSize(arcadeCornerSize, arcadeCornerSize)
arcadeOuterCornerBR:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
arcadeOuterCornerBR:SetTexture("Interface\\AddOns\\MythicPlusTimer\\Media\\arcade_corner_mask.blp")
arcadeOuterCornerBR:SetTexCoord(1, 0, 1, 0)
arcadeOuterCornerBR:Hide()

local arcadeOuterTopMask = frame:CreateTexture(nil, "OVERLAY")
arcadeOuterTopMask:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
arcadeOuterTopMask:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
arcadeOuterTopMask:SetHeight(32)
arcadeOuterTopMask:SetTexture("Interface\\BUTTONS\\WHITE8X8")
arcadeOuterTopMask:Hide()

local function SetArcadeOuterBorderVisible(show, r, g, b, a)
    local alpha = a or 1
    local lineLogical = 1
    local borderOut = 0

    arcadeOuterTop:ClearAllPoints()
    arcadeOuterTop:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    arcadeOuterTop:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    arcadeOuterTop:SetHeight(lineLogical)
    arcadeOuterBottom:ClearAllPoints()
    arcadeOuterBottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    arcadeOuterBottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    arcadeOuterBottom:SetHeight(lineLogical)
    arcadeOuterLeft:ClearAllPoints()
    arcadeOuterLeft:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    arcadeOuterLeft:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    arcadeOuterLeft:SetWidth(lineLogical)
    arcadeOuterRight:ClearAllPoints()
    arcadeOuterRight:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    arcadeOuterRight:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    arcadeOuterRight:SetWidth(lineLogical)

    local useTopMask = arcadeUseTopSegmentMask and true or false
    local useSectionBorders = false
    arcadeOuterTopMask:SetShown(show and useTopMask)
    arcadeOuterTop:SetShown(show and (not useTopMask))
    arcadeOuterBottom:SetShown(show)
    arcadeOuterLeft:SetShown(show)
    arcadeOuterRight:SetShown(show)
    arcadeOuterCornerTL:Hide()
    arcadeOuterCornerTR:Hide()
    arcadeOuterCornerBL:Hide()
    arcadeOuterCornerBR:Hide()
    if show then
        arcadeOuterTopMask:SetVertexColor(r, g, b, alpha)
        arcadeOuterTop:SetVertexColor(r, g, b, alpha)
        arcadeOuterBottom:SetVertexColor(r, g, b, alpha)
        arcadeOuterLeft:SetVertexColor(r, g, b, alpha)
        arcadeOuterRight:SetVertexColor(r, g, b, alpha)
        arcadeOuterCornerTL:SetVertexColor(r, g, b, alpha)
        arcadeOuterCornerTR:SetVertexColor(r, g, b, alpha)
        arcadeOuterCornerBL:SetVertexColor(r, g, b, alpha)
        arcadeOuterCornerBR:SetVertexColor(r, g, b, alpha)
    end
end
arcadeFrame:Hide()

local arcadeHeaderDivider = frame:CreateTexture(nil, "BORDER")
arcadeHeaderDivider:SetTexture("Interface\\BUTTONS\\WHITE8X8")
arcadeHeaderDivider:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -32)
arcadeHeaderDivider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -32)
arcadeHeaderDivider:SetHeight(1)
arcadeHeaderDivider:Hide()

-- Заголовок: "+15 — Кузня Крови"
frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
frame.title:SetPoint("TOPLEFT",  frame, "TOPLEFT",  8, -6)
frame.title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -6)
frame.title:SetJustifyH("LEFT")
frame.title:SetWordWrap(true)
frame.title:SetFont("Fonts\\FRIZQT__.TTF", 13, "")
frame.title:SetTextColor(1, 1, 1)
frame.title:SetText("ожидание...")

frame.arcadeLevel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
frame.arcadeLevel:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -8)
frame.arcadeLevel:SetJustifyH("LEFT")
frame.arcadeLevel:SetFont("Fonts\\FRIZQT__.TTF", 14, "")
frame.arcadeLevel:SetTextColor(1, 0.82, 0)
frame.arcadeLevel:SetShadowOffset(0, 0)
frame.arcadeLevel:SetShadowColor(0, 0, 0, 0)
frame.arcadeLevel:SetText("")
frame.arcadeLevel:Hide()

frame.arcadeDungeon = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
frame.arcadeDungeon:SetPoint("LEFT", frame.arcadeLevel, "RIGHT", 8, 0)
frame.arcadeDungeon:SetJustifyH("LEFT")
frame.arcadeDungeon:SetFont("Fonts\\FRIZQT__.TTF", 14, "")
frame.arcadeDungeon:SetTextColor(0.86, 0.90, 0.96)
frame.arcadeDungeon:SetShadowOffset(0, 0)
frame.arcadeDungeon:SetShadowColor(0, 0, 0, 0)
frame.arcadeDungeon:SetText("")
frame.arcadeDungeon:Hide()

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

-- Краткие названия подземелий по mapID (для заголовка и свёрнутого режима)
local shortDungeonName = {
    [4]  = "Крепость Утгард",
    [5]  = "Бастионы",
    [6]  = "Узилище",
    [8]  = "Крепость Драк'Тарон",
    [9]  = "Чертоги Молний",
    [10] = "Кузня Крови",
    [11] = "Гробницы Маны",
    [12] = "Ан'кахет",
}

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
    -- Иконка: квадратная, но с лёгким кропом встроенной wow-рамки.
    local tex = iconFrame:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(iconFrame)
    tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    iconFrame.tex = tex
    -- Кольцо-рамка поверх иконки: перекрывает квадратные углы тёмным кольцом
    local border = iconFrame:CreateTexture(nil, "OVERLAY")
    border:SetAllPoints(iconFrame)
    border:SetTexture("Interface\\AddOns\\MythicPlusTimer\\Media\\icon_border")
    iconFrame.border = border
    local arcadeCornerMask = iconFrame:CreateTexture(nil, "OVERLAY")
    arcadeCornerMask:SetAllPoints(iconFrame)
    arcadeCornerMask:SetTexture("Interface\\AddOns\\MythicPlusTimer\\Media\\arcade_affix_corner_mask.blp")
    arcadeCornerMask:Hide()
    iconFrame.arcadeCornerMask = arcadeCornerMask
    local arcadeRoundBorder = iconFrame:CreateTexture(nil, "OVERLAY")
    arcadeRoundBorder:SetAllPoints(iconFrame)
    arcadeRoundBorder:SetTexture("Interface\\AddOns\\MythicPlusTimer\\Media\\arcade_affix_border_mask.blp")
    arcadeRoundBorder:Hide()
    iconFrame.arcadeRoundBorder = arcadeRoundBorder
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

-- Метка "Пауза" справа от таймера (одна строка, красный цвет)
frame.pauseLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
frame.pauseLabel:SetFont("Fonts\\FRIZQT__.TTF", 20, "")
frame.pauseLabel:SetPoint("LEFT", frame.timer, "RIGHT", 10, 0)
frame.pauseLabel:SetText("Пауза")
frame.pauseLabel:SetTextColor(1, 0, 0)
frame.pauseLabel:Hide()

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

-- Arcade: timer block widgets (left main timer, right +3/+2 rows)
frame.arcadeBaseTimer = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
frame.arcadeBaseTimer:SetFont("Fonts\\FRIZQT__.TTF", 12, "")
frame.arcadeBaseTimer:SetTextColor(0.62, 0.68, 0.82)
frame.arcadeBaseTimer:Hide()

frame.arcadePlus3Label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
frame.arcadePlus3Label:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
frame.arcadePlus3Label:SetText("+3")
frame.arcadePlus3Label:SetTextColor(1.0, 0.90, 0.32)
frame.arcadePlus3Label:Hide()

frame.arcadePlus2Label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
frame.arcadePlus2Label:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
frame.arcadePlus2Label:SetText("+2")
frame.arcadePlus2Label:SetTextColor(0.55, 0.68, 1.0)
frame.arcadePlus2Label:Hide()

frame.arcadePlus3Remain = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
frame.arcadePlus3Remain:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
frame.arcadePlus3Remain:SetJustifyH("RIGHT")
frame.arcadePlus3Remain:SetTextColor(1.0, 0.90, 0.32)
frame.arcadePlus3Remain:Hide()

frame.arcadePlus2Remain = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
frame.arcadePlus2Remain:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
frame.arcadePlus2Remain:SetJustifyH("RIGHT")
frame.arcadePlus2Remain:SetTextColor(0.55, 0.68, 1.0)
frame.arcadePlus2Remain:Hide()

frame.arcadePlus3BarContainer = CreateFrame("Frame", nil, frame)
frame.arcadePlus3BarContainer:SetHeight(4)
frame.arcadePlus3BarContainer:Hide()
frame.arcadePlus3BarBg = frame.arcadePlus3BarContainer:CreateTexture(nil, "BACKGROUND")
frame.arcadePlus3BarBg:SetAllPoints(frame.arcadePlus3BarContainer)
frame.arcadePlus3BarBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
frame.arcadePlus3BarBg:SetVertexColor(0.20, 0.27, 0.40, 0.95)
frame.arcadePlus3BarFillFrame = CreateFrame("Frame", nil, frame.arcadePlus3BarContainer)
frame.arcadePlus3BarFillFrame:SetPoint("TOPLEFT", frame.arcadePlus3BarContainer, "TOPLEFT", 0, 0)
frame.arcadePlus3BarFillFrame:SetWidth(1)
frame.arcadePlus3BarFillFrame:SetHeight(4)
frame.arcadePlus3BarFill = frame.arcadePlus3BarFillFrame:CreateTexture(nil, "ARTWORK")
frame.arcadePlus3BarFill:SetAllPoints(frame.arcadePlus3BarFillFrame)
frame.arcadePlus3BarFill:SetTexture("Interface\\BUTTONS\\WHITE8X8")

frame.arcadePlus2BarContainer = CreateFrame("Frame", nil, frame)
frame.arcadePlus2BarContainer:SetHeight(4)
frame.arcadePlus2BarContainer:Hide()
frame.arcadePlus2BarBg = frame.arcadePlus2BarContainer:CreateTexture(nil, "BACKGROUND")
frame.arcadePlus2BarBg:SetAllPoints(frame.arcadePlus2BarContainer)
frame.arcadePlus2BarBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
frame.arcadePlus2BarBg:SetVertexColor(0.20, 0.27, 0.40, 0.95)
frame.arcadePlus2BarFillFrame = CreateFrame("Frame", nil, frame.arcadePlus2BarContainer)
frame.arcadePlus2BarFillFrame:SetPoint("TOPLEFT", frame.arcadePlus2BarContainer, "TOPLEFT", 0, 0)
frame.arcadePlus2BarFillFrame:SetWidth(1)
frame.arcadePlus2BarFillFrame:SetHeight(4)
frame.arcadePlus2BarFill = frame.arcadePlus2BarFillFrame:CreateTexture(nil, "ARTWORK")
frame.arcadePlus2BarFill:SetAllPoints(frame.arcadePlus2BarFillFrame)
frame.arcadePlus2BarFill:SetTexture("Interface\\BUTTONS\\WHITE8X8")

frame.arcadeTimerDivider = frame:CreateTexture(nil, "BORDER")
frame.arcadeTimerDivider:SetTexture("Interface\\BUTTONS\\WHITE8X8")
frame.arcadeTimerDivider:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -84)
frame.arcadeTimerDivider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -84)
frame.arcadeTimerDivider:SetHeight(1)
frame.arcadeTimerDivider:Hide()

frame.arcadeForcesTopDivider = frame:CreateTexture(nil, "BORDER")
frame.arcadeForcesTopDivider:SetTexture("Interface\\BUTTONS\\WHITE8X8")
frame.arcadeForcesTopDivider:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -170)
frame.arcadeForcesTopDivider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -170)
frame.arcadeForcesTopDivider:SetHeight(1)
frame.arcadeForcesTopDivider:Hide()

frame.arcadeForcesBottomDivider = frame:CreateTexture(nil, "BORDER")
frame.arcadeForcesBottomDivider:SetTexture("Interface\\BUTTONS\\WHITE8X8")
frame.arcadeForcesBottomDivider:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -208)
frame.arcadeForcesBottomDivider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -208)
frame.arcadeForcesBottomDivider:SetHeight(1)
frame.arcadeForcesBottomDivider:Hide()

frame.arcadeForcesTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
frame.arcadeForcesTitle:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
frame.arcadeForcesTitle:SetTextColor(0.62, 0.68, 0.82)
frame.arcadeForcesTitle:SetJustifyH("LEFT")
frame.arcadeForcesTitle:Hide()

frame.arcadeForcesValue = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
frame.arcadeForcesValue:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
frame.arcadeForcesValue:SetTextColor(0.62, 0.68, 0.82)
frame.arcadeForcesValue:SetJustifyH("RIGHT")
frame.arcadeForcesValue:Hide()

-- Second-style timer bar (elapsed/base + +2/+3 marks)
frame.timerBarContainer = CreateFrame("Frame", nil, frame)
frame.timerBarContainer:SetHeight(16)
frame.timerBarContainer:Hide()

local tbBg = frame.timerBarContainer:CreateTexture(nil, "BACKGROUND")
tbBg:SetAllPoints(frame.timerBarContainer)
tbBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
tbBg:SetVertexColor(0.04, 0.04, 0.04, 0.95)

frame.timerBarFill = CreateFrame("Frame", nil, frame.timerBarContainer)
frame.timerBarFill:SetPoint("TOPLEFT", frame.timerBarContainer, "TOPLEFT", 1, -1)
frame.timerBarFill:SetWidth(1)
frame.timerBarFill:SetHeight(14)
local tbFill = frame.timerBarFill:CreateTexture(nil, "ARTWORK")
tbFill:SetAllPoints(frame.timerBarFill)
tbFill:SetTexture("Interface\\BUTTONS\\WHITE8X8")
tbFill:SetVertexColor(1.0, 0.93, 0.10, 0.95)

local tbTextFrame = CreateFrame("Frame", nil, frame.timerBarContainer)
tbTextFrame:SetAllPoints(frame.timerBarContainer)
tbTextFrame:SetFrameLevel(frame.timerBarContainer:GetFrameLevel() + 20)
frame.timerBar = {}
frame.timerBar.text = tbTextFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
frame.timerBar.text:SetPoint("LEFT", tbTextFrame, "LEFT", 4, 0)
frame.timerBar.text:SetPoint("RIGHT", tbTextFrame, "RIGHT", -4, 0)
frame.timerBar.text:SetJustifyH("LEFT")
frame.timerBar.text:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
frame.timerBar.text:SetTextColor(1, 1, 1)

frame.timerBarMark2 = frame.timerBarContainer:CreateTexture(nil, "OVERLAY")
frame.timerBarMark2:SetTexture("Interface\\BUTTONS\\WHITE8X8")
frame.timerBarMark2:SetSize(2, 16)
frame.timerBarMark2:SetVertexColor(0, 0, 0, 1)
frame.timerBarMark2:Hide()

frame.timerBarMark3 = frame.timerBarContainer:CreateTexture(nil, "OVERLAY")
frame.timerBarMark3:SetTexture("Interface\\BUTTONS\\WHITE8X8")
frame.timerBarMark3:SetSize(2, 16)
frame.timerBarMark3:SetVertexColor(0, 0, 0, 1)
frame.timerBarMark3:Hide()

frame.timerBarPlus2 = tbTextFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
frame.timerBarPlus2:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
frame.timerBarPlus2:SetJustifyH("LEFT")
frame.timerBarPlus2:SetDrawLayer("OVERLAY", 7)
frame.timerBarPlus2:Hide()

frame.timerBarPlus3 = tbTextFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
frame.timerBarPlus3:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
frame.timerBarPlus3:SetJustifyH("LEFT")
frame.timerBarPlus3:SetDrawLayer("OVERLAY", 7)
frame.timerBarPlus3:Hide()


-- Строки боссов: динамическая высота (16px = 1 строка, 28px = 2 строки с переносом)
-- Позиции пересчитываются в UpdateBossLayout после каждого SetText на строке
local MAX_BOSSES = 5
local BOSS_LINE_H1    = 16  -- одна строка (~14px + 2px зазор)
local BOSS_LINE_H2    = 28  -- две строки
local BOSS_FIRST_OFFSET = 8  -- отступ от top блока боссов до первой строки
local FRAME_INNER_W   = 264   -- 280 - 2*8 (горизонтальные отступы)
frame.bossLines = {}
frame.bossRightLines = {}
frame.bossRightKillLines = {}
frame.bossRightDeltaLines = {}
frame.bossRowBgs = {}
frame.bossStatusIcons = {}
frame.bossLineH = {}  -- текущая высота каждой строки (16 или 28)
for i = 1, MAX_BOSSES do
    local rowBg = frame:CreateTexture(nil, "BORDER")
    rowBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    rowBg:SetVertexColor(0.42, 0.54, 0.78, 0.20)
    rowBg:SetDrawLayer("BORDER", 0)
    rowBg:Hide()
    frame.bossRowBgs[i] = rowBg

    local bossIcon = frame:CreateTexture(nil, "OVERLAY")
    bossIcon:SetTexture("Interface\\AddOns\\MythicPlusTimer\\Media\\arcade_boss_indicator.blp")
    bossIcon:SetSize(6, 6)
    bossIcon:Hide()
    frame.bossStatusIcons[i] = bossIcon

    local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetWidth(FRAME_INNER_W)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    fs:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
    fs:SetTextColor(1, 1, 1)
    fs:SetText("")
    fs:Hide()
    frame.bossLines[i] = fs

    local right = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    right:SetJustifyH("RIGHT")
    right:SetWordWrap(false)
    right:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
    right:SetTextColor(1, 1, 1)
    right:SetText("")
    right:Hide()
    frame.bossRightLines[i] = right

    local rightKill = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rightKill:SetJustifyH("RIGHT")
    rightKill:SetWordWrap(false)
    rightKill:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
    rightKill:SetTextColor(1, 1, 1)
    rightKill:SetText("")
    rightKill:Hide()
    frame.bossRightKillLines[i] = rightKill

    local rightDelta = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rightDelta:SetJustifyH("RIGHT")
    rightDelta:SetWordWrap(false)
    rightDelta:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
    rightDelta:SetTextColor(1, 1, 1)
    rightDelta:SetText("")
    rightDelta:Hide()
    frame.bossRightDeltaLines[i] = rightDelta

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

-- Дополнительный сегмент справа от основного заполнения:
-- показывает % спуленного пака более тёмным цветом.
frame.forcesBarPullFill = CreateFrame("Frame", nil, frame.forcesBarContainer)
frame.forcesBarPullFill:SetPoint("TOPLEFT", frame.forcesBarFill, "TOPRIGHT", 0, 0)
frame.forcesBarPullFill:SetWidth(0)
frame.forcesBarPullFill:SetHeight(14)
frame.forcesBarPullFill:Hide()
local fbPullFill = frame.forcesBarPullFill:CreateTexture(nil, "ARTWORK")
fbPullFill:SetAllPoints(frame.forcesBarPullFill)
fbPullFill:SetTexture("Interface\\BUTTONS\\WHITE8X8")

-- Таблица текстур для прогресс-бара (имя → путь)
local SM_BAR = "Interface\\AddOns\\SharedMedia\\Media\\Statusbar\\"
MPT.BAR_TEXTURES = {
    { name = "Blank",              path = "Interface\\BUTTONS\\WHITE8X8" },
    { name = "Aluminium",          path = SM_BAR.."Aluminium" },
    { name = "Armory",             path = SM_BAR.."Armory" },
    { name = "BantoBar",           path = SM_BAR.."BantoBar" },
    { name = "Bars",               path = SM_BAR.."Bars" },
    { name = "Bezo",               path = SM_BAR.."Bezo" },
    { name = "Bezo Dark",          path = SM_BAR.."Bezo-dark1" },
    { name = "Bezo Darker",        path = SM_BAR.."Bezo-dark2" },
    { name = "Blinkii",            path = SM_BAR.."Blinkii" },
    { name = "BuiOnePixel",        path = SM_BAR.."BuiOnePixel" },
    { name = "Bumps",              path = SM_BAR.."Bumps" },
    { name = "Button",             path = SM_BAR.."Button" },
    { name = "Charcoal",           path = SM_BAR.."Charcoal" },
    { name = "Cilo",               path = SM_BAR.."Cilo" },
    { name = "Cloud",              path = SM_BAR.."Cloud" },
    { name = "Combo",              path = SM_BAR.."Combo" },
    { name = "Comet",              path = SM_BAR.."Comet" },
    { name = "Dabs",               path = SM_BAR.."Dabs" },
    { name = "DarkBottom",         path = SM_BAR.."DarkBottom" },
    { name = "Diagonal",           path = SM_BAR.."Diagonal" },
    { name = "Empty",              path = SM_BAR.."Empty" },
    { name = "Falumn",             path = SM_BAR.."Falumn" },
    { name = "Ferous 1",           path = SM_BAR.."Ferous1" },
    { name = "Ferous 2",           path = SM_BAR.."Ferous2" },
    { name = "Ferous 3",           path = SM_BAR.."Ferous3" },
    { name = "Ferous 4",           path = SM_BAR.."Ferous4" },
    { name = "Ferous 5",           path = SM_BAR.."Ferous5" },
    { name = "Ferous 6",           path = SM_BAR.."Ferous6" },
    { name = "Ferous 7",           path = SM_BAR.."Ferous7" },
    { name = "Ferous 8",           path = SM_BAR.."Ferous8" },
    { name = "Ferous 9",           path = SM_BAR.."Ferous9" },
    { name = "Ferous 10",          path = SM_BAR.."Ferous10" },
    { name = "Ferous 11",          path = SM_BAR.."Ferous11" },
    { name = "Ferous 12",          path = SM_BAR.."Ferous12" },
    { name = "Ferous 13",          path = SM_BAR.."Ferous13" },
    { name = "Ferous 14",          path = SM_BAR.."Ferous14" },
    { name = "Ferous 15",          path = SM_BAR.."Ferous15" },
    { name = "Ferous 16",          path = SM_BAR.."Ferous16" },
    { name = "Ferous 17",          path = SM_BAR.."Ferous17" },
    { name = "Ferous 18",          path = SM_BAR.."Ferous18" },
    { name = "Ferous 19",          path = SM_BAR.."Ferous19" },
    { name = "Ferous 20",          path = SM_BAR.."Ferous20" },
    { name = "Ferous 21",          path = SM_BAR.."Ferous21" },
    { name = "Ferous 22",          path = SM_BAR.."Ferous22" },
    { name = "Ferous 23",          path = SM_BAR.."Ferous23" },
    { name = "Ferous 24",          path = SM_BAR.."Ferous24" },
    { name = "Ferous 25",          path = SM_BAR.."Ferous25" },
    { name = "Ferous 26",          path = SM_BAR.."Ferous26" },
    { name = "Ferous 27",          path = SM_BAR.."Ferous27" },
    { name = "Ferous 28",          path = SM_BAR.."Ferous28" },
    { name = "Ferous 29",          path = SM_BAR.."Ferous29" },
    { name = "Ferous 30",          path = SM_BAR.."Ferous30" },
    { name = "Ferous 31",          path = SM_BAR.."Ferous31" },
    { name = "Ferous 32",          path = SM_BAR.."Ferous32" },
    { name = "Ferous 33",          path = SM_BAR.."Ferous33" },
    { name = "Ferous 34",          path = SM_BAR.."Ferous34" },
    { name = "Ferous 35",          path = SM_BAR.."Ferous35" },
    { name = "Ferous 36",          path = SM_BAR.."Ferous36" },
    { name = "Ferous 37",          path = SM_BAR.."Ferous37" },
    { name = "Fifths",             path = SM_BAR.."Fifths" },
    { name = "Flat",               path = SM_BAR.."Flat" },
    { name = "Fourths",            path = SM_BAR.."Fourths" },
    { name = "Frost",              path = SM_BAR.."Frost" },
    { name = "Glamour",            path = SM_BAR.."Glamour" },
    { name = "Glamour2",           path = SM_BAR.."Glamour2" },
    { name = "Glamour3",           path = SM_BAR.."Glamour3" },
    { name = "Glamour4",           path = SM_BAR.."Glamour4" },
    { name = "Glamour5",           path = SM_BAR.."Glamour5" },
    { name = "Glamour6",           path = SM_BAR.."Glamour6" },
    { name = "Glamour7",           path = SM_BAR.."Glamour7" },
    { name = "Glass",              path = SM_BAR.."Glass" },
    { name = "Glaze",              path = SM_BAR.."Glaze" },
    { name = "Glaze v2",           path = SM_BAR.."Glaze2" },
    { name = "Gloss",              path = SM_BAR.."Gloss" },
    { name = "Graphite",           path = SM_BAR.."Graphite" },
    { name = "Grid",               path = SM_BAR.."Grid" },
    { name = "Hatched",            path = SM_BAR.."Hatched" },
    { name = "Healbot",            path = SM_BAR.."Healbot" },
    { name = "LiteStep",           path = SM_BAR.."LiteStep" },
    { name = "LiteStepLite",       path = SM_BAR.."LiteStepLite" },
    { name = "Lyfe",               path = SM_BAR.."Lyfe" },
    { name = "Melli",              path = SM_BAR.."Melli" },
    { name = "Melli Dark",         path = SM_BAR.."MelliDark" },
    { name = "Melli Dark Rough",   path = SM_BAR.."MelliDarkRough" },
    { name = "Minimalist",         path = SM_BAR.."Minimalist" },
    { name = "Norm",               path = SM_BAR.."Norm" },
    { name = "Otravi",             path = SM_BAR.."Otravi" },
    { name = "Outline",            path = SM_BAR.."Outline" },
    { name = "Perl",               path = SM_BAR.."Perl" },
    { name = "Perl v2",            path = SM_BAR.."Perl2" },
    { name = "Pill",               path = SM_BAR.."Pill" },
    { name = "Raeli 1",            path = SM_BAR.."Raeli1.tga" },
    { name = "Raeli 2",            path = SM_BAR.."Raeli2.tga" },
    { name = "Raeli 3",            path = SM_BAR.."Raeli3.tga" },
    { name = "Raeli 4",            path = SM_BAR.."Raeli4.tga" },
    { name = "Raeli 5",            path = SM_BAR.."Raeli5.tga" },
    { name = "Raeli 6",            path = SM_BAR.."Raeli6.tga" },
    { name = "Rain",               path = SM_BAR.."Rain" },
    { name = "Rocks",              path = SM_BAR.."Rocks" },
    { name = "Round",              path = SM_BAR.."Round" },
    { name = "Ruben",              path = SM_BAR.."Ruben" },
    { name = "Runes",              path = SM_BAR.."Runes" },
    { name = "Skewed",             path = SM_BAR.."Skewed" },
    { name = "Smooth",             path = SM_BAR.."Smooth" },
    { name = "Smooth v2",          path = SM_BAR.."Smoothv2" },
    { name = "Smudge",             path = SM_BAR.."Smudge" },
    { name = "Steel",              path = SM_BAR.."Steel" },
    { name = "Striped",            path = SM_BAR.."Striped" },
    { name = "ToxiUI Clean",       path = SM_BAR.."ToxiUI-clean" },
    { name = "ToxiUI Dark",        path = SM_BAR.."ToxiUI-dark" },
    { name = "ToxiUI Half",        path = SM_BAR.."ToxiUI-half" },
    { name = "ToxiUI Tx Left",     path = SM_BAR.."ToxiUI-g1" },
    { name = "ToxiUI Tx Mid",      path = SM_BAR.."ToxiUI-grad" },
    { name = "ToxiUI Tx Right",    path = SM_BAR.."ToxiUI-g2" },
    { name = "Tube",               path = SM_BAR.."Tube" },
    { name = "TX WorldState Score",path = SM_BAR.."TX-WorldState-Score" },
    { name = "Water",              path = SM_BAR.."Water" },
    { name = "Wglass",             path = SM_BAR.."Wglass" },
    { name = "Wisps",              path = SM_BAR.."Wisps" },
    { name = "Xeon",               path = SM_BAR.."Xeon" },
}

-- Таблица шрифтов (имя → путь).
-- По умолчанию — встроенный Blizzard-шрифт. Список расширяется из LibSharedMedia-3.0 в PLAYER_LOGIN.
local SM_FONT = "Interface\\AddOns\\SharedMedia\\Media\\Fonts\\"
MPT.FONTS = {
    { name = "Friz Quadrata (default)", path = "Fonts\\FRIZQT__.TTF" },
}

-- Расширить MPT.FONTS и MPT.BAR_TEXTURES данными из LibSharedMedia-3.0 (если установлен).
-- Вызывается из Options.lua в PLAYER_LOGIN, когда LibStub уже доступен.
function MPT:RefreshMediaLists()
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if not LSM then
        -- SharedMedia не установлен — используем компактный встроенный список
        if #MPT.FONTS <= 1 then
            local fallback = {
                { name = "Accidental Presidency", path = SM_FONT.."AccidentalPresidency.ttf" },
                { name = "Blender Pro",           path = SM_FONT.."BlenderPro.ttf" },
                { name = "Blender Pro Bold",      path = SM_FONT.."BlenderProBold.ttf" },
                { name = "Celestia Medium Redux",  path = SM_FONT.."CelestiaMediumRedux.ttf" },
                { name = "DejaVu Sans",           path = SM_FONT.."DejaVuLGCSans.ttf" },
                { name = "DejaVu Serif",          path = SM_FONT.."DejaVuLGCSerif.ttf" },
                { name = "Expressway",            path = SM_FONT.."Expressway.ttf" },
                { name = "FORCED SQUARE",         path = SM_FONT.."FORCEDSQUARE.ttf" },
                { name = "Futura PT Bold",        path = SM_FONT.."FuturaPTBold.ttf" },
                { name = "Futura PT Book",        path = SM_FONT.."FuturaPTBook.ttf" },
                { name = "Futura PT Medium",      path = SM_FONT.."FuturaPTMedium.ttf" },
                { name = "Hack",                  path = SM_FONT.."Hack.ttf" },
                { name = "Impact",                path = SM_FONT.."Impact.ttf" },
                { name = "Liberation Sans",       path = SM_FONT.."LiberationSans.ttf" },
                { name = "PT Sans Narrow",        path = SM_FONT.."PTSansNarrow.ttf" },
                { name = "Quicksand",             path = SM_FONT.."Quicksand.ttf" },
                { name = "Steelfish Rg",          path = SM_FONT.."SteelfishRg.ttf" },
                { name = "Ubuntu Condensed",      path = SM_FONT.."UbuntuCondensed.ttf" },
                { name = "Ubuntu Light",          path = SM_FONT.."UbuntuLight.ttf" },
                { name = "Yanone Kaffeesatz",     path = SM_FONT.."YanoneKaffeesatzRegular.ttf" },
            }
            for _, f in ipairs(fallback) do
                MPT.FONTS[#MPT.FONTS + 1] = f
            end
        end
        return
    end

    -- === Шрифты из LSM ===
    local lsmFonts = LSM:HashTable("font")  -- { name -> path }
    local newFonts = { { name = "Friz Quadrata (default)", path = "Fonts\\FRIZQT__.TTF" } }
    local names = {}
    for name in pairs(lsmFonts) do
        names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
        newFonts[#newFonts + 1] = { name = name, path = lsmFonts[name] }
    end
    MPT.FONTS = newFonts

    -- === Текстуры баров из LSM ===
    local lsmBars = LSM:HashTable("statusbar")  -- { name -> path }
    local newBars = { { name = "Blank", path = "Interface\\BUTTONS\\WHITE8X8" } }
    local barNames = {}
    for name in pairs(lsmBars) do
        barNames[#barNames + 1] = name
    end
    table.sort(barNames)
    for _, name in ipairs(barNames) do
        newBars[#newBars + 1] = { name = name, path = lsmBars[name] }
    end
    MPT.BAR_TEXTURES = newBars
end

local function GetBarTexturePath(name)
    for _, t in ipairs(MPT.BAR_TEXTURES) do
        if t.name == name then return t.path end
    end
    return "Interface\\BUTTONS\\WHITE8X8"
end

local function ApplyForcesColor()
    local r, g, b = 0.25, 0.55, 1.0
    if MPT.db and MPT.db.forcesColor then
        local c = MPT.db.forcesColor
        if type(c.r) == "number" and type(c.g) == "number" and type(c.b) == "number" then
            r, g, b = c.r, c.g, c.b
        end
    end
    local mainR, mainG, mainB = r, g, b
    if IsArcadeStyle() then
        -- Arcade: keep forces fill a bit brighter for readability.
        mainR = math.min(1, r * 1.15 + 0.02)
        mainG = math.min(1, g * 1.15 + 0.02)
        mainB = math.min(1, b * 1.15 + 0.02)
        local r0 = mainR * 0.55
        local g0 = mainG * 0.55
        local b0 = mainB * 0.55
        local gradAlpha = fbFill["SetGradientAlpha"]
        local ok = false
        if type(gradAlpha) == "function" then
            ok = pcall(gradAlpha, fbFill, "HORIZONTAL", r0, g0, b0, 0.9, mainR, mainG, mainB, 0.9)
        end
        if not ok then
            ok = pcall(function()
                fbFill:SetGradient("HORIZONTAL", CreateColor(r0, g0, b0, 0.9), CreateColor(mainR, mainG, mainB, 0.9))
            end)
        end
        if not ok then
            fbFill:SetVertexColor(mainR, mainG, mainB, 0.9)
        end
    else
        fbFill:SetVertexColor(mainR, mainG, mainB, 0.9)
    end
    fbPullFill:SetVertexColor(mainR * 0.55, mainG * 0.55, mainB * 0.55, 0.95)
end

local function SetHorizontalGradientSafe(tex, r, g, b, a)
    if not tex then return end
    a = a or 0.95
    local r0 = r * 0.55
    local g0 = g * 0.55
    local b0 = b * 0.55
    if tex.SetGradientAlpha then
        tex:SetGradientAlpha("HORIZONTAL", r0, g0, b0, a, r, g, b, a)
    else
        tex:SetVertexColor(r, g, b, a)
    end
end

local function SetVerticalGradientSafe(tex, r, g, b, a)
    if not tex then return end
    a = a or 0.92
    local rt = math.min(1, r + 0.02)
    local gt = math.min(1, g + 0.02)
    local bt = math.min(1, b + 0.02)
    local rb = math.max(0, r - 0.03)
    local gb = math.max(0, g - 0.03)
    local bb = math.max(0, b - 0.03)
    local ok = false
    if tex.SetGradientAlpha then
        ok = pcall(function()
            tex:SetGradientAlpha("VERTICAL", rt, gt, bt, a, rb, gb, bb, a)
        end)
    end
    if (not ok) and tex.SetGradient then
        ok = pcall(function()
            tex:SetGradient("VERTICAL", CreateColor(rt, gt, bt, a), CreateColor(rb, gb, bb, a))
        end)
    end
    if not ok then
        tex:SetVertexColor(r, g, b, a)
    end
end

local function ApplyForcesTexture()
    local name = GetStyleOption("forcesTexture", "Blank")
    local path = GetBarTexturePath(name)
    fbFill:SetTexture(path)
    fbPullFill:SetTexture(path)
    ApplyForcesColor()
end
ApplyForcesTexture()

-- Прозрачный Frame поверх заполнения — создаётся после forcesBarFill,
-- поэтому рисуется выше него; его FontString всегда виден поверх бара.
local fbTextFrame = CreateFrame("Frame", nil, frame.forcesBarContainer)
fbTextFrame:SetAllPoints(frame.forcesBarContainer)

frame.forcesBar = {}  -- таблица для совместимости с остальным кодом
frame.forcesBar.text = fbTextFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
frame.forcesBar.text:SetPoint("LEFT",  fbTextFrame, "LEFT",  4, 0)
frame.forcesBar.text:SetPoint("RIGHT", fbTextFrame, "RIGHT", -4, 0)
frame.forcesBar.text:SetJustifyH("CENTER")
frame.forcesBar.text:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
frame.forcesBar.text:SetTextColor(1, 1, 1)

-- SetValue: обновляет ширину заполнения (0-100%) и pull-сегмента.
frame.forcesBar.SetValue = function(_, pct, pullPct)
    local arcadeStyle = IsArcadeStyle()
    local inset = arcadeStyle and 0 or 1
    local containerW = frame.forcesBarContainer:GetWidth()
    if not containerW or containerW <= 0 then
        containerW = FRAME_INNER_W
    end
    local innerW = math.max(1, math.floor(containerW - (inset * 2) + 0.5))
    local basePct = math.max(0, math.min(pct or 0, 100))
    local fillW = math.max(1, math.floor(innerW * basePct / 100 + 0.5))
    frame.forcesBarFill:SetWidth(fillW)
    local pull = math.max(0, pullPct or 0)
    local maxPull = math.max(0, 100 - basePct)
    local shownPullPct = math.min(pull, maxPull)
    local pullW = math.floor(innerW * shownPullPct / 100 + 0.5)
    if pullW > 0 then
        frame.forcesBarPullFill:SetWidth(pullW)
        frame.forcesBarPullFill:Show()
    else
        frame.forcesBarPullFill:SetWidth(0)
        frame.forcesBarPullFill:Hide()
    end
end

frame.forcesBarContainer:Hide()

function MPT:RefreshForcesColor()
    ApplyForcesColor()
end

function MPT:RefreshForcesTexture()
    ApplyForcesTexture()
end

function MPT:IsPreviewActive()
    return not state.running and frame and frame:IsShown()
end

function MPT:RefreshAllColors()
    ApplyForcesColor()
    self:ApplyButtonColors()
    self:ApplyDeathsBrIconColors()
    if IsCustomStyle() then
        local bgr, bgg, bgb = GetColor("colorBackground")
        if IsArcadeStyle() then
            bg:SetVertexColor(0, 0, 0, 0)
            arcadeFrame:Show()
            local hr = math.min(1, bgr + 0.08)
            local hg = math.min(1, bgg + 0.08)
            local hb = math.min(1, bgb + 0.08)
            SetVerticalGradientSafe(arcadeUnifiedBg, bgr, bgg, bgb, 0.94)
            arcadeUnifiedBg:Show()
            arcadeMiddleBg:SetVertexColor(0, 0, 0, 0)
            arcadeHeaderBg:SetVertexColor(0, 0, 0, 0)
            arcadeBottomBg:SetVertexColor(0, 0, 0, 0)
            arcadeHeaderBorder:Hide()
            arcadeMiddleBorder:Hide()
            arcadeBottomBorder:Show()
            arcadeBottomBorder:SetVertexColor(0.56, 0.61, 0.70, 0.42)
            arcadeMidBorderLeft:Hide()
            arcadeMidBorderRight:Hide()
            SetArcadeOuterBorderVisible(true, 0.56, 0.61, 0.70, 0.62)
            arcadeHeaderDivider:Show()
            arcadeHeaderDivider:SetVertexColor(0.56, 0.61, 0.70, 0.42)
        else
            arcadeUnifiedBg:Hide()
            bg:SetVertexColor(bgr, bgg, bgb, 0.72)
            arcadeFrame:Hide()
            arcadeMiddleBorder:Hide()
            arcadeBottomBorder:Hide()
            arcadeHeaderDivider:Hide()
            SetArcadeOuterBorderVisible(false)
        end
        local tr, tg, tb = GetColor("colorTimer")
        frame.timerBar.text:SetTextColor(tr, tg, tb)
    else
        arcadeUnifiedBg:Hide()
        arcadeFrame:Hide()
        arcadeHeaderDivider:Hide()
        SetArcadeOuterBorderVisible(false)
    end
    if state.level and (state.dungeonName or state.mapID) then
        local lvlStr = "+" .. state.level
        local name  = (state.mapID and shortDungeonName[state.mapID]) or state.dungeonName or ""
        lastTitleText = string.format("%s%s %s|r", RGBToHex(GetColor("colorTitle")), lvlStr, name)
        frame.title:SetText(lastTitleText)
    end
    if lastDisplayedAffixIDs and #lastDisplayedAffixIDs > 0 then
        MPT:RefreshAffixes(lastDisplayedAffixIDs)
    end
    UpdateDisplay()
end

local function GetFontPath(name)
    if MPT.FONTS then
        for _, f in ipairs(MPT.FONTS) do
            if f.name == name then return f.path end
        end
    end
    return "Fonts\\FRIZQT__.TTF"
end

local function GetArcadeFontPath()
    if MPT.FONTS then
        for _, f in ipairs(MPT.FONTS) do
            if type(f.name) == "string" and string.lower(f.name):find("avanti", 1, true) then
                return f.path or "Fonts\\FRIZQT__.TTF"
            end
        end
    end
    return "Interface\\AddOns\\SharedMedia\\Media\\Fonts\\Avanti.ttf"
end

local function SetFontSafe(fs, path, size, flags, fallback)
    if not fs then return end
    local ok = fs:SetFont(path, size, flags or "")
    if (not ok) and fallback then
        fs:SetFont(fallback, size, flags or "")
    end
end

local function ApplyFont()
    local path = GetFontPath(GetStyleOption("font", "Friz Quadrata (default)"))
    local isArcade = IsArcadeStyle()
    if isArcade then
        path = GetArcadeFontPath()
    end
    SetFontSafe(frame.title, path, 13, "", "Fonts\\FRIZQT__.TTF")
    SetFontSafe(frame.affixes, path, 11, "", "Fonts\\FRIZQT__.TTF")
    SetFontSafe(frame.affixesLine2, path, 11, "", "Fonts\\FRIZQT__.TTF")
    SetFontSafe(frame.timer, path, 20, "", "Fonts\\FRIZQT__.TTF")
    SetFontSafe(frame.pauseLabel, path, 20, "", "Fonts\\FRIZQT__.TTF")
    SetFontSafe(frame.plus2, path, 12, "", "Fonts\\FRIZQT__.TTF")
    SetFontSafe(frame.plus3, path, 12, "", "Fonts\\FRIZQT__.TTF")
    SetFontSafe(frame.timerBar.text, path, 12, "", "Fonts\\FRIZQT__.TTF")
    SetFontSafe(frame.timerBarPlus2, path, 11, "", "Fonts\\FRIZQT__.TTF")
    SetFontSafe(frame.timerBarPlus3, path, 11, "", "Fonts\\FRIZQT__.TTF")
    SetFontSafe(frame.arcadeBaseTimer, path, 12, "", "Fonts\\FRIZQT__.TTF")
    SetFontSafe(frame.arcadePlus3Label, path, 11, "", "Fonts\\FRIZQT__.TTF")
    SetFontSafe(frame.arcadePlus2Label, path, 11, "", "Fonts\\FRIZQT__.TTF")
    SetFontSafe(frame.arcadePlus3Remain, path, 11, "", "Fonts\\FRIZQT__.TTF")
    SetFontSafe(frame.arcadePlus2Remain, path, 11, "", "Fonts\\FRIZQT__.TTF")
    for i = 1, MAX_BOSSES do
        SetFontSafe(frame.bossLines[i], path, 11, "", "Fonts\\FRIZQT__.TTF")
        SetFontSafe(frame.bossRightLines[i], path, 11, "", "Fonts\\FRIZQT__.TTF")
        SetFontSafe(frame.bossRightKillLines[i], path, 11, "", "Fonts\\FRIZQT__.TTF")
        SetFontSafe(frame.bossRightDeltaLines[i], path, 11, "", "Fonts\\FRIZQT__.TTF")
    end
    SetFontSafe(frame.forces, path, 11, "", "Fonts\\FRIZQT__.TTF")
    SetFontSafe(frame.forcesBar.text, path, 11, "", "Fonts\\FRIZQT__.TTF")
    SetFontSafe(frame.arcadeForcesTitle, path, 11, "", "Fonts\\FRIZQT__.TTF")
    SetFontSafe(frame.arcadeForcesValue, path, 11, "", "Fonts\\FRIZQT__.TTF")
    SetFontSafe(frame.arcadeDeathPenaltyText, path, 11, "", "Fonts\\FRIZQT__.TTF")
    SetFontSafe(frame.deaths, path, 11, "", "Fonts\\FRIZQT__.TTF")
    SetFontSafe(frame.battleRes, path, 11, "", "Fonts\\FRIZQT__.TTF")

    -- Second style keeps outlined/shadowed overlay text even after font switch.
    if IsSecondStyle() then
        SetFontSafe(frame.timerBar.text, path, 13, "OUTLINE", "Fonts\\FRIZQT__.TTF")
        SetFontSafe(frame.timerBarPlus2, path, 11, "OUTLINE", "Fonts\\FRIZQT__.TTF")
        SetFontSafe(frame.timerBarPlus3, path, 11, "OUTLINE", "Fonts\\FRIZQT__.TTF")
        SetFontSafe(frame.forcesBar.text, path, 11, "OUTLINE", "Fonts\\FRIZQT__.TTF")
        frame.forcesBar.text:SetShadowOffset(1, -1)
        frame.forcesBar.text:SetShadowColor(0, 0, 0, 1)
        for i = 1, MAX_BOSSES do
            SetFontSafe(frame.bossRightLines[i], path, 12, "OUTLINE", "Fonts\\FRIZQT__.TTF")
        end
    elseif IsArcadeStyle() then
        SetFontSafe(frame.timerBar.text, path, 13, "", "Fonts\\FRIZQT__.TTF")
        SetFontSafe(frame.timerBarPlus2, path, 11, "", "Fonts\\FRIZQT__.TTF")
        SetFontSafe(frame.timerBarPlus3, path, 11, "", "Fonts\\FRIZQT__.TTF")
        SetFontSafe(frame.forcesBar.text, path, 11, "", "Fonts\\FRIZQT__.TTF")
        frame.forcesBar.text:SetShadowOffset(0, 0)
        frame.forcesBar.text:SetShadowColor(0, 0, 0, 0)
        -- Keep both header texts without outline in Arcade.
        SetFontSafe(frame.arcadeLevel, path, 14, "", "Fonts\\FRIZQT__.TTF")
        SetFontSafe(frame.arcadeDungeon, path, 14, "", "Fonts\\FRIZQT__.TTF")
        for i = 1, MAX_BOSSES do
            SetFontSafe(frame.bossLines[i], path, 11, "", "Fonts\\FRIZQT__.TTF")
            SetFontSafe(frame.bossRightLines[i], path, 11, "", "Fonts\\FRIZQT__.TTF")
            SetFontSafe(frame.bossRightKillLines[i], path, 11, "", "Fonts\\FRIZQT__.TTF")
            SetFontSafe(frame.bossRightDeltaLines[i], path, 11, "", "Fonts\\FRIZQT__.TTF")
        end
    else
        frame.forcesBar.text:SetShadowOffset(0, 0)
        frame.forcesBar.text:SetShadowColor(0, 0, 0, 0)
    end
end

function MPT:RefreshFont()
    ApplyFont()
end

-- Смерти: иконка черепа + текст (число и штраф); выравнивание по низу строки
local DEATHS_ROW_H = 12
frame.deathsIcon = frame:CreateTexture(nil, "OVERLAY")
frame.deathsIcon:SetSize(12, 12)
frame.deathsIcon:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 8, -124 - BOSS_LINE_H1 - DEATHS_ROW_H)
frame.deathsIcon:SetTexture("Interface\\AddOns\\MythicPlusTimer\\Media\\skull.blp")

frame.deaths = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
frame.deaths:SetPoint("BOTTOMLEFT", frame.deathsIcon, "BOTTOMRIGHT", 2, 0)
frame.deaths:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
frame.deaths:SetTextColor(1, 1, 1)
frame.deaths:SetText("|cff888888—|r")

-- Боевые воскрешения (справа от строки смертей; число из стандартного трекера)
local function GetBattleResCount()
    local f = _G["ScenarioObjectiveTrackerChallengeModeBlockBattleResurrection"]
    if not f then return nil end
    if f.GetText then
        local n = tonumber(f:GetText())
        if n and n >= 0 and n <= 10 then return n end
    end
    if f.GetNumRegions then
        for i = 1, f:GetNumRegions() do
            local r = select(i, f:GetRegions())
            if r and r.GetObjectType and r:GetObjectType() == "FontString" and r.GetText then
                local n = tonumber(r:GetText())
                if n and n >= 0 and n <= 10 then return n end
            end
        end
    end
    return nil
end

-- Боевые воскрешения: иконка сердца + число; выравнивание по низу с текстом
frame.battleResIcon = frame:CreateTexture(nil, "OVERLAY")
frame.battleResIcon:SetSize(12, 12)
frame.battleResIcon:SetPoint("BOTTOMLEFT", frame.deaths, "BOTTOMRIGHT", 14, 0)
frame.battleResIcon:SetTexture("Interface\\AddOns\\MythicPlusTimer\\Media\\heart.blp")

frame.battleRes = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
frame.battleRes:SetPoint("BOTTOMLEFT", frame.battleResIcon, "BOTTOMRIGHT", 6, 0)
frame.battleRes:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
frame.battleRes:SetTextColor(1, 1, 1)
frame.battleRes:SetJustifyH("LEFT")
frame.battleRes:SetText("|cff888888—|r")

frame.arcadeDeathsDivider = frame:CreateTexture(nil, "BORDER")
frame.arcadeDeathsDivider:SetTexture("Interface\\BUTTONS\\WHITE8X8")
frame.arcadeDeathsDivider:SetSize(1, 14)
frame.arcadeDeathsDivider:SetVertexColor(0.56, 0.61, 0.70, 0.42)
frame.arcadeDeathsDivider:Hide()

frame.arcadeDeathPenaltyFrame = CreateFrame("Frame", nil, frame)
frame.arcadeDeathPenaltyFrame:SetSize(34, 14)
frame.arcadeDeathPenaltyFrame:Hide()
frame.arcadeDeathPenaltyBg = frame.arcadeDeathPenaltyFrame:CreateTexture(nil, "BACKGROUND")
frame.arcadeDeathPenaltyBg:SetAllPoints(frame.arcadeDeathPenaltyFrame)
frame.arcadeDeathPenaltyBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
frame.arcadeDeathPenaltyBg:SetVertexColor(0.95, 0.36, 0.42, 0.0)
frame.arcadeDeathPenaltyBorderTop = frame.arcadeDeathPenaltyFrame:CreateTexture(nil, "BORDER")
frame.arcadeDeathPenaltyBorderTop:SetTexture("Interface\\BUTTONS\\WHITE8X8")
frame.arcadeDeathPenaltyBorderTop:SetPoint("TOPLEFT", frame.arcadeDeathPenaltyFrame, "TOPLEFT", 0, 0)
frame.arcadeDeathPenaltyBorderTop:SetPoint("TOPRIGHT", frame.arcadeDeathPenaltyFrame, "TOPRIGHT", 0, 0)
frame.arcadeDeathPenaltyBorderTop:SetHeight(1)
frame.arcadeDeathPenaltyBorderTop:SetVertexColor(0.88, 0.36, 0.42, 0.0)
frame.arcadeDeathPenaltyBorderBottom = frame.arcadeDeathPenaltyFrame:CreateTexture(nil, "BORDER")
frame.arcadeDeathPenaltyBorderBottom:SetTexture("Interface\\BUTTONS\\WHITE8X8")
frame.arcadeDeathPenaltyBorderBottom:SetPoint("BOTTOMLEFT", frame.arcadeDeathPenaltyFrame, "BOTTOMLEFT", 0, 0)
frame.arcadeDeathPenaltyBorderBottom:SetPoint("BOTTOMRIGHT", frame.arcadeDeathPenaltyFrame, "BOTTOMRIGHT", 0, 0)
frame.arcadeDeathPenaltyBorderBottom:SetHeight(1)
frame.arcadeDeathPenaltyBorderBottom:SetVertexColor(0.88, 0.36, 0.42, 0.0)
frame.arcadeDeathPenaltyBorderLeft = frame.arcadeDeathPenaltyFrame:CreateTexture(nil, "BORDER")
frame.arcadeDeathPenaltyBorderLeft:SetTexture("Interface\\BUTTONS\\WHITE8X8")
frame.arcadeDeathPenaltyBorderLeft:SetPoint("TOPLEFT", frame.arcadeDeathPenaltyFrame, "TOPLEFT", 0, -1)
frame.arcadeDeathPenaltyBorderLeft:SetPoint("BOTTOMLEFT", frame.arcadeDeathPenaltyFrame, "BOTTOMLEFT", 0, 1)
frame.arcadeDeathPenaltyBorderLeft:SetWidth(1)
frame.arcadeDeathPenaltyBorderLeft:SetVertexColor(0.88, 0.36, 0.42, 0.0)
frame.arcadeDeathPenaltyBorderRight = frame.arcadeDeathPenaltyFrame:CreateTexture(nil, "BORDER")
frame.arcadeDeathPenaltyBorderRight:SetTexture("Interface\\BUTTONS\\WHITE8X8")
frame.arcadeDeathPenaltyBorderRight:SetPoint("TOPRIGHT", frame.arcadeDeathPenaltyFrame, "TOPRIGHT", 0, -1)
frame.arcadeDeathPenaltyBorderRight:SetPoint("BOTTOMRIGHT", frame.arcadeDeathPenaltyFrame, "BOTTOMRIGHT", 0, 1)
frame.arcadeDeathPenaltyBorderRight:SetWidth(1)
frame.arcadeDeathPenaltyBorderRight:SetVertexColor(0.88, 0.36, 0.42, 0.0)
frame.arcadeDeathPenaltyText = frame.arcadeDeathPenaltyFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
frame.arcadeDeathPenaltyText:SetPoint("CENTER", frame.arcadeDeathPenaltyFrame, "CENTER", 0, 0)
frame.arcadeDeathPenaltyText:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
frame.arcadeDeathPenaltyText:SetTextColor(1.0, 0.46, 0.46)
frame.arcadeDeathPenaltyText:SetText("+0с")

local function SetArcadePenaltyText(text)
    frame.arcadeDeathPenaltyText:SetText(text or "+0с")
    local w = math.floor((frame.arcadeDeathPenaltyText:GetStringWidth() or 0) + 5.5)
    if w < 22 then w = 22 end
    if w > 38 then w = 38 end
    frame.arcadeDeathPenaltyFrame:SetWidth(w)
end

-- ============================================================
-- Кнопки управления (развёрнутый режим: 14×14, у нижнего правого угла)
-- ============================================================

-- Кнопка "Сдаться" (развёрнутый режим)
local forfeitBtn = CreateFrame("Button", nil, frame)
forfeitBtn:SetWidth(12)
forfeitBtn:SetHeight(12)
forfeitBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -5, 14)
forfeitBtn:SetFrameLevel(frame:GetFrameLevel() + 20)
local forfeitTex = forfeitBtn:CreateTexture(nil, "ARTWORK")
forfeitTex:SetAllPoints(forfeitBtn)
forfeitTex:SetTexture("Interface\\AddOns\\MythicPlusTimer\\Media\\forfeit.blp")
local forfeitArcadeBg = forfeitBtn:CreateTexture(nil, "BACKGROUND")
forfeitArcadeBg:SetAllPoints(forfeitBtn)
forfeitArcadeBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
forfeitArcadeBg:SetVertexColor(0.20, 0.26, 0.38, 0.92)
forfeitArcadeBg:Hide()
local forfeitArcadeBorder = forfeitBtn:CreateTexture(nil, "BORDER")
forfeitArcadeBorder:SetAllPoints(forfeitBtn)
forfeitArcadeBorder:SetTexture("Interface\\BUTTONS\\WHITE8X8")
forfeitArcadeBorder:SetVertexColor(0.56, 0.61, 0.70, 0.0)
forfeitArcadeBorder:Hide()
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
pauseBtn:SetFrameLevel(frame:GetFrameLevel() + 20)
local pauseTex = pauseBtn:CreateTexture(nil, "ARTWORK")
pauseTex:SetAllPoints(pauseBtn)
pauseTex:SetTexture("Interface\\AddOns\\MythicPlusTimer\\Media\\pause.blp")
local pauseArcadeBg = pauseBtn:CreateTexture(nil, "BACKGROUND")
pauseArcadeBg:SetAllPoints(pauseBtn)
pauseArcadeBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
pauseArcadeBg:SetVertexColor(0.20, 0.26, 0.38, 0.92)
pauseArcadeBg:Hide()
local pauseArcadeBorder = pauseBtn:CreateTexture(nil, "BORDER")
pauseArcadeBorder:SetAllPoints(pauseBtn)
pauseArcadeBorder:SetTexture("Interface\\BUTTONS\\WHITE8X8")
pauseArcadeBorder:SetVertexColor(0.56, 0.61, 0.70, 0.0)
pauseArcadeBorder:Hide()
pauseBtn:SetScript("OnClick", function()
    pcall(function() C_ChallengeMode.Pause() end)
end)
pauseBtn:SetScript("OnEnter", function(self)
    local ok, v = pcall(function() return C_ChallengeMode.IsPaused() end)
    local label = (ok and v) and "Снять паузу" or "Поставить паузу"
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(label, 1, 1, 0.4, 1)
    GameTooltip:Show()
end)
pauseBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function UpdateArcadeButtonFrames(isArcade)
    local arcadeIconSize = 9
    if isArcade then
        forfeitArcadeBg:Show()
        forfeitArcadeBorder:Hide()
        pauseArcadeBg:Show()
        pauseArcadeBorder:Hide()
        forfeitTex:ClearAllPoints()
        forfeitTex:SetSize(arcadeIconSize, arcadeIconSize)
        forfeitTex:SetPoint("CENTER", forfeitBtn, "CENTER", 0, 0)
        pauseTex:ClearAllPoints()
        pauseTex:SetSize(arcadeIconSize, arcadeIconSize)
        pauseTex:SetPoint("CENTER", pauseBtn, "CENTER", 0, 0)
    else
        forfeitArcadeBg:Hide()
        forfeitArcadeBorder:Hide()
        pauseArcadeBg:Hide()
        pauseArcadeBorder:Hide()
        forfeitTex:ClearAllPoints()
        forfeitTex:SetSize(0, 0)
        forfeitTex:SetAllPoints(forfeitBtn)
        pauseTex:ClearAllPoints()
        pauseTex:SetSize(0, 0)
        pauseTex:SetAllPoints(pauseBtn)
    end
end

-- ============================================================
-- Кнопка сворачивания (TOPRIGHT, 10×10)
-- ============================================================
local collapseBtn = CreateFrame("Button", nil, frame)
collapseBtn:SetWidth(10)
collapseBtn:SetHeight(10)
-- Выравнивание по вертикали с заголовком (title: -6, шрифт 13px → центр ~12.5; кнопка 10px → top -8)
collapseBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -8)
collapseBtn:SetFrameLevel(frame:GetFrameLevel() + 30)
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
forfeitSmall:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -18, -8)
forfeitSmall:SetFrameLevel(frame:GetFrameLevel() + 20)
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
pauseSmall:SetFrameLevel(frame:GetFrameLevel() + 20)
pauseSmall:Hide()
local pauseSmallTex = pauseSmall:CreateTexture(nil, "ARTWORK")
pauseSmallTex:SetAllPoints(pauseSmall)
pauseSmallTex:SetTexture("Interface\\AddOns\\MythicPlusTimer\\Media\\pause.blp")
pauseSmall:SetScript("OnClick", function()
    pcall(function() C_ChallengeMode.Pause() end)
end)
pauseSmall:SetScript("OnEnter", function(self)
    local ok, v = pcall(function() return C_ChallengeMode.IsPaused() end)
    local label = (ok and v) and "Снять паузу" or "Поставить паузу"
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(label, 1, 1, 0.4, 1)
    GameTooltip:Show()
end)
pauseSmall:SetScript("OnLeave", function() GameTooltip:Hide() end)

function MPT:ApplyButtonColors()
    local r, g, b = GetColor("colorButtons")
    if collapseTex then collapseTex:SetVertexColor(r, g, b, 1) end
    if forfeitSmallTex then forfeitSmallTex:SetVertexColor(r, g, b, 1) end
    if pauseSmallTex then pauseSmallTex:SetVertexColor(r, g, b, 1) end
    if forfeitTex then forfeitTex:SetVertexColor(r, g, b, 1) end
    if pauseTex then pauseTex:SetVertexColor(r, g, b, 1) end
end

function MPT:ApplyDeathsBrIconColors()
    local rD, gD, bD = GetColor("colorDeathsIcon")
    local rBR, gBR, bBR = GetColor("colorBattleResIcon")
    if frame.deathsIcon then frame.deathsIcon:SetVertexColor(rD, gD, bD, 1) end
    if frame.battleResIcon then frame.battleResIcon:SetVertexColor(rBR, gBR, bBR, 1) end
end
MPT:ApplyButtonColors()
MPT:ApplyDeathsBrIconColors()

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
    if IsCustomStyle() then
        collapsed = false
        collapseTex:SetTexture("Interface\\AddOns\\MythicPlusTimer\\Media\\minus.blp")
        frame:SetHeight(expandedHeight)
        frame.timerBarContainer:Show()
        forfeitBtn:Show()
        pauseBtn:Show()
        forfeitSmall:Hide()
        pauseSmall:Hide()
        titleTooltipFrame:EnableMouse(true)
        affixTooltipFrame:EnableMouse(true)
        return
    end
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
        frame.timerBarContainer:Hide()
        frame.timerBarPlus2:Hide()
        frame.timerBarPlus3:Hide()
        frame.arcadeForcesTopDivider:Hide()
        frame.arcadeForcesBottomDivider:Hide()
        frame.arcadeForcesTitle:Hide()
        frame.arcadeForcesValue:Hide()
        for i = 1, MAX_BOSSES do frame.bossLines[i]:Hide() end
        for i = 1, MAX_BOSSES do frame.bossRightLines[i]:Hide() end
        for i = 1, MAX_BOSSES do frame.bossRightKillLines[i]:Hide() end
        for i = 1, MAX_BOSSES do frame.bossRightDeltaLines[i]:Hide() end
        for i = 1, MAX_BOSSES do frame.bossStatusIcons[i]:Hide() end
        frame.forces:Hide()
        frame.forcesBarContainer:Hide()
        frame.deathsIcon:Hide()
        frame.deaths:Hide()
        frame.arcadeDeathsDivider:Hide()
        frame.arcadeDeathPenaltyFrame:Hide()
        frame.battleRes:Hide()
        frame.battleResIcon:Hide()
        frame.pauseLabel:Hide()
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
            local dungeon = (state.mapID and shortDungeonName[state.mapID]) or state.dungeonName or ""
            local collapsedTime
            local isReverse = MPT.db and MPT.db.reverseTimer
            local dOkC, dC, tC = pcall(function() return C_ChallengeMode.GetDeathCount() end)
            local deathLostC = 0
            if dOkC and type(dC) == "number" then
                deathLostC = type(tC) == "number" and tC or (dC * 5)
            end
            local effC = state.elapsed + deathLostC
            if isReverse then
                collapsedTime = FormatTime(effC)
            else
                local limit2c = GetPlus2Plus3Limits()
                local baseC = limit2c and math.floor(limit2c / 0.80 + 0.5)
                collapsedTime = baseC and FormatCountdown(baseC - effC) or FormatTime(effC)
            end
            timerStr = string.format("%s%s  %s  %s|r", RGBToHex(GetColor("colorTitle")), collapsedTime, lvlStr, dungeon)
            local okP, isPausedCollapsed = pcall(function() return C_ChallengeMode.IsPaused() end)
            if okP and isPausedCollapsed then
                timerStr = timerStr .. "  " .. RGBToHex(GetColor("colorTimerFailed")) .. "Пауза|r"
            end
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
        frame.timerBarContainer:Hide()
        frame.timerBarPlus2:Hide()
        frame.timerBarPlus3:Hide()
        SetForcesMode((MPT.db and MPT.db.forcesBar or false) or IsCustomStyle())
        frame.deathsIcon:Show()
        frame.deaths:Show()
        frame.battleRes:Show()
        frame.battleResIcon:Show()
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
    if IsCustomStyle() then return end
    SetCollapsed(not collapsed)
end)
collapseBtn:SetScript("OnEnter", function(self)
    if IsCustomStyle() then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(collapsed and "Развернуть" or "Свернуть" --[[@as string]], 1, 1, 1, 1)
    GameTooltip:Show()
end)
collapseBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Зона перетаскивания: весь фрейм (без тултипа аффиксов)
titleTooltipFrame = CreateFrame("Frame", nil, frame)
titleTooltipFrame:SetPoint("TOPLEFT",  frame, "TOPLEFT",  0, 0)
titleTooltipFrame:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -44, -64)
titleTooltipFrame:EnableMouse(true)
titleTooltipFrame:SetScript("OnMouseDown", function(_, button)
    if button == "LeftButton" then StartFrameDrag() end
end)
titleTooltipFrame:SetScript("OnMouseUp", function(_, button)
    if button == "LeftButton" then StopFrameDrag() end
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
    GameTooltip:Show()
end

-- Невидимый фрейм поверх аффиксов — показывает тултип при наведении (текст и/или иконки).
-- Границы пересчитываются в RefreshAffixes, чтобы покрывать текущий блок аффиксов.
affixTooltipFrame = CreateFrame("Frame", nil, frame)
affixTooltipFrame:SetPoint("TOPLEFT",  frame, "TOPLEFT",  0, -22)
affixTooltipFrame:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, -64)
affixTooltipFrame:SetFrameLevel(frame:GetFrameLevel() + 5)
affixTooltipFrame:EnableMouse(true)
affixTooltipFrame:SetScript("OnMouseDown", function(_, button)
    if button == "LeftButton" then StartFrameDrag() end
end)
affixTooltipFrame:SetScript("OnMouseUp", function(_, button)
    if button == "LeftButton" then StopFrameDrag() end
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

    if IsSecondStyle() or IsArcadeStyle() then
        local rowH = IsArcadeStyle() and 26 or 19
        local forcesH = 16
        local timerBarTop = IsArcadeStyle() and -56 or -24
        local bossTop = timerBarTop - (IsArcadeStyle() and 40 or 23)
        local arcadeStyle = IsArcadeStyle()
        local rightW = 118
        local leftW = math.max(110, frame:GetWidth() - rightW - 18)
        local killW, deltaW, colGap = 46, 40, 8
        if arcadeStyle then
            leftW = math.max(110, frame:GetWidth() - (killW + deltaW + colGap) - 20)
        end

        frame.timerBarContainer:ClearAllPoints()
        frame.timerBarContainer:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, timerBarTop)
        frame.timerBarContainer:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, timerBarTop)

        local nextBossIndex = nil
        if IsArcadeStyle() and state and state.bosses then
            for j = 1, count do
                if state.bosses[j] and not state.bosses[j].killed then
                    nextBossIndex = j
                    break
                end
            end
        end

        for i = 1, count do
            local y = bossTop - (i - 1) * rowH
            local rowBg = frame.bossRowBgs[i]
            if rowBg then
                rowBg:ClearAllPoints()
                if arcadeStyle then
                    rowBg:SetTexture("Interface\\AddOns\\MythicPlusTimer\\Media\\arcade_row_highlight.blp")
                    rowBg:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, y + 1)
                    rowBg:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, y + 1)
                    rowBg:SetHeight(rowH - 4)
                else
                    rowBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
                    rowBg:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, y - 1)
                    rowBg:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, y - 1)
                    rowBg:SetHeight(rowH - 2)
                end
                if arcadeStyle and nextBossIndex and i == nextBossIndex then
                    rowBg:SetVertexColor(0.42, 0.54, 0.78, 0.16)
                    rowBg:Show()
                else
                    rowBg:Hide()
                end
            end
            local left = frame.bossLines[i]
            left:ClearAllPoints()
            left:SetWordWrap(false)

            local right = frame.bossRightLines[i]
            right:ClearAllPoints()
            if arcadeStyle then
                local iconTex = frame.bossStatusIcons[i]
                iconTex:ClearAllPoints()
                iconTex:SetPoint("LEFT", rowBg, "LEFT", 8, 0)
                iconTex:SetSize(6, 6)
                iconTex:Show()
                right:Hide()
                local rightDelta = frame.bossRightDeltaLines[i]
                local rightKill = frame.bossRightKillLines[i]
                rightDelta:ClearAllPoints()
                rightDelta:SetPoint("RIGHT", rowBg, "RIGHT", -10, 0)
                rightDelta:SetWidth(deltaW)
                rightDelta:Show()
                rightKill:ClearAllPoints()
                rightKill:SetPoint("RIGHT", rightDelta, "LEFT", -colGap, 0)
                rightKill:SetWidth(killW)
                rightKill:Show()
                left:SetPoint("LEFT", iconTex, "RIGHT", 6, 0)
                left:SetPoint("RIGHT", rightKill, "LEFT", -12, 0)
            else
                frame.bossStatusIcons[i]:Hide()
                left:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, y)
                left:SetWidth(leftW)
                right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, y)
                right:SetWidth(rightW)
                right:Show()
                frame.bossRightKillLines[i]:Hide()
                frame.bossRightDeltaLines[i]:Hide()
            end
        end
        for i = count + 1, MAX_BOSSES do
            if frame.bossRowBgs[i] then frame.bossRowBgs[i]:Hide() end
            frame.bossStatusIcons[i]:Hide()
            frame.bossRightLines[i]:Hide()
            frame.bossRightKillLines[i]:Hide()
            frame.bossRightDeltaLines[i]:Hide()
        end

        local forcesBarY
        local forcesBottomDividerY
        if arcadeStyle then
            local forcesTopDividerY = bossTop - count * rowH - 4
            local forcesTitleY = forcesTopDividerY - 10
            forcesBarY = forcesTitleY - 17
            forcesBottomDividerY = forcesBarY - 14

            frame.arcadeForcesTopDivider:ClearAllPoints()
            frame.arcadeForcesTopDivider:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, forcesTopDividerY)
            frame.arcadeForcesTopDivider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, forcesTopDividerY)
            frame.arcadeForcesTopDivider:SetVertexColor(0.56, 0.61, 0.70, 0.42)
            frame.arcadeForcesTopDivider:Show()

            frame.arcadeForcesTitle:ClearAllPoints()
            frame.arcadeForcesTitle:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, forcesTitleY)
            frame.arcadeForcesTitle:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, forcesTitleY)
            frame.arcadeForcesTitle:Show()

            frame.arcadeForcesValue:ClearAllPoints()
            frame.arcadeForcesValue:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, forcesTitleY)
            frame.arcadeForcesValue:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, forcesTitleY)
            frame.arcadeForcesValue:Show()

            frame.arcadeForcesBottomDivider:Hide()
        else
            -- Keep Reloe spacing tight under boss list.
            forcesBarY = bossTop - count * rowH - 2
            forcesBottomDividerY = forcesBarY - forcesH - 6
            frame.arcadeForcesTopDivider:Hide()
            frame.arcadeForcesBottomDivider:Hide()
            frame.arcadeForcesTitle:Hide()
            frame.arcadeForcesValue:Hide()
        end

        frame.forcesBarContainer:ClearAllPoints()
        frame.forcesBarContainer:SetPoint("TOPLEFT", frame, "TOPLEFT", arcadeStyle and 8 or 4, forcesBarY)
        frame.forcesBarContainer:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, forcesBarY)

        local btnSize = IsArcadeStyle() and 18 or 10
        local btnGap = 6
        local bottomPad = 1
        forfeitBtn:SetSize(btnSize, btnSize)
        pauseBtn:SetSize(btnSize, btnSize)
        UpdateArcadeButtonFrames(arcadeStyle)
        forfeitBtn:ClearAllPoints()
        if arcadeStyle then
            forfeitBtn:SetPoint("TOPRIGHT", arcadeBottomBorder, "BOTTOMRIGHT", -8, -btnGap)
        else
            forfeitBtn:SetPoint("TOPRIGHT", frame.forcesBarContainer, "BOTTOMRIGHT", 0, -btnGap)
        end
        pauseBtn:ClearAllPoints()
        pauseBtn:SetPoint("RIGHT", forfeitBtn, "LEFT", -4, 0)

        local controlsBottom
        if arcadeStyle then
            controlsBottom = forcesBottomDividerY - btnGap - forfeitBtn:GetHeight()
        else
            controlsBottom = forcesBarY - forcesH - btnGap - forfeitBtn:GetHeight()
        end
        local bottomY = controlsBottom - bottomPad
        frame:SetHeight(-bottomY + 8)
        return
    end

    for i = 1, MAX_BOSSES do
        if frame.bossRowBgs[i] then frame.bossRowBgs[i]:Hide() end
    end
    frame.arcadeForcesTopDivider:Hide()
    frame.arcadeForcesBottomDivider:Hide()
    frame.arcadeForcesTitle:Hide()
    frame.arcadeForcesValue:Hide()
    frame.arcadeDeathsDivider:Hide()
    frame.arcadeDeathPenaltyFrame:Hide()
    for i = 1, MAX_BOSSES do frame.bossStatusIcons[i]:Hide() end
    for i = 1, MAX_BOSSES do
        frame.bossRightLines[i]:Hide()
        frame.bossRightKillLines[i]:Hide()
        frame.bossRightDeltaLines[i]:Hide()
        local left = frame.bossLines[i]
        left:SetWidth(FRAME_INNER_W)
        left:SetWordWrap(true)
    end
    forfeitBtn:SetSize(12, 12)
    pauseBtn:SetSize(12, 12)
    UpdateArcadeButtonFrames(false)
    forfeitBtn:ClearAllPoints()
    forfeitBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -5, 14)
    pauseBtn:ClearAllPoints()
    pauseBtn:SetPoint("BOTTOMRIGHT", forfeitBtn, "BOTTOMLEFT", -4, 0)
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
    -- deathsY: под баром/текстом + зазор
    if frame.forcesBarContainer:IsShown() then
        deathsY = forcesY - FORCES_BAR_H - 10
    else
        -- бар скрыт — текст forces занимает ~14px, даём 6px зазор
        deathsY = forcesY - 14 - 6
    end

    frame.forces:ClearAllPoints()
    frame.forces:SetPoint("TOPLEFT",  frame, "TOPLEFT",  8, forcesY)
    frame.forces:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, forcesY)

    frame.forcesBarContainer:ClearAllPoints()
    frame.forcesBarContainer:SetPoint("TOPLEFT",  frame, "TOPLEFT",  8, forcesY)
    frame.forcesBarContainer:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, forcesY)

    local deathsBottomY = deathsY - DEATHS_ROW_H
    frame.deathsIcon:ClearAllPoints()
    frame.deathsIcon:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 8, deathsBottomY)
    frame.deaths:ClearAllPoints()
    frame.deaths:SetPoint("BOTTOMLEFT", frame.deathsIcon, "BOTTOMRIGHT", 2, 0)

    frame.battleResIcon:ClearAllPoints()
    frame.battleResIcon:SetPoint("BOTTOMLEFT", frame.deaths, "BOTTOMRIGHT", 14, 0)
    frame.battleRes:ClearAllPoints()
    frame.battleRes:SetPoint("BOTTOMLEFT", frame.battleResIcon, "BOTTOMRIGHT", 6, 0)

    frame:SetHeight(-deathsY + 24)
end

local function SetBossCount(count)
    count = math.max(0, math.min(count, MAX_BOSSES))
    local secondStyle = IsCustomStyle()
    local arcadeStyle = IsArcadeStyle()
    for i = 1, MAX_BOSSES do
        if i <= count then
            frame.bossLines[i]:Show()
            if secondStyle then
                frame.bossRightLines[i]:Show()
                if arcadeStyle then
                    frame.bossRightLines[i]:Hide()
                    frame.bossRightKillLines[i]:Show()
                    frame.bossRightDeltaLines[i]:Show()
                    frame.bossStatusIcons[i]:Show()
                else
                    frame.bossRightKillLines[i]:Hide()
                    frame.bossRightDeltaLines[i]:Hide()
                    frame.bossStatusIcons[i]:Hide()
                end
            else
                frame.bossRightLines[i]:Hide()
                frame.bossRightKillLines[i]:Hide()
                frame.bossRightDeltaLines[i]:Hide()
                frame.bossStatusIcons[i]:Hide()
            end
        else
            frame.bossLines[i]:Hide()
            frame.bossRightLines[i]:Hide()
            frame.bossRightKillLines[i]:Hide()
            frame.bossRightDeltaLines[i]:Hide()
            frame.bossStatusIcons[i]:Hide()
        end
    end
    UpdateBossLayout(count)
end

-- ============================================================
-- Перетаскивание (паттерн из Omen: OnMouseDown/OnMouseUp)
-- Разрешено только в режиме превью (не во время активного ключа)
-- ============================================================
frame:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" then StartFrameDrag() end
end)

frame:SetScript("OnMouseUp", function(_, button)
    if button == "LeftButton" then StopFrameDrag() end
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
    if frame.affixesIcons:IsShown() and not IsCustomStyle() then
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
    if IsCustomStyle() then
        useBar = true
    end
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
    local isPaused = false
    if state.running and C_ChallengeMode and C_ChallengeMode.IsPaused then
        local ok, v = pcall(function() return C_ChallengeMode.IsPaused() end)
        isPaused = ok and v == true
    end

    if state.running then
        if isPaused then
            state.wasPaused = true
            -- elapsed не обновляем — время заморожено
        else
            if state.wasPaused then
                state.startTime = GetTime() - state.elapsed
                state.wasPaused = false
            end
            state.elapsed = GetTime() - state.startTime
        end
    end

    -- Метка "Пауза" справа от таймера
    if state.running and isPaused then
        frame.pauseLabel:Show()
    else
        frame.pauseLabel:Hide()
    end

    -- Иконка кнопки паузы: pause.blp ↔ resume.blp
    local pauseIcon = (state.running and isPaused)
        and "Interface\\AddOns\\MythicPlusTimer\\Media\\resume.blp"
        or  "Interface\\AddOns\\MythicPlusTimer\\Media\\pause.blp"
    pauseTex:SetTexture(pauseIcon)
    pauseSmallTex:SetTexture(pauseIcon)

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

    -- Таймер
    local useReverse = MPT.db and MPT.db.reverseTimer
    local active = state.running or state.completed
    local secondStyle = IsCustomStyle()
    local arcadeStyle = IsArcadeStyle()
    local displayTimerText = "--:--"
    if active and state.elapsed then
        local timerText
        local overBase = baseLimit and (effElapsed > baseLimit)
        if secondStyle then
            if baseLimit then
                timerText = FormatTime(effElapsed) .. "/" .. FormatTime(baseLimit)
            else
                timerText = FormatTime(effElapsed)
            end
        elseif useReverse then
            -- Обратный режим (текущий): elapsed+deaths / baseLimit
            local elapsedStr = FormatTime(effElapsed)
            local limitStr   = baseLimit and FormatTime(baseLimit) or nil
            timerText = limitStr and (elapsedStr .. "/" .. limitStr) or elapsedStr
        else
            -- Прямой режим: убывает от лимита к 0, затем отрицательный
            if baseLimit then
                local remaining = baseLimit - effElapsed
                timerText = FormatCountdown(remaining)
            else
                timerText = FormatTime(effElapsed)
            end
        end

        local tr, tg, tb = GetColor("colorTimer")
        local tfr, tfg, tfb = GetColor("colorTimerFailed")
        if state.completed then
            if overBase then
                frame.timer:SetTextColor(tfr, tfg, tfb)
            else
                frame.timer:SetTextColor(tr, tg, tb)
            end
            frame.timer:SetText(timerText .. " [done]")
        else
            if not useReverse and baseLimit and (baseLimit - effElapsed) < 0 then
                frame.timer:SetTextColor(tfr, tfg, tfb)
            elseif overBase then
                frame.timer:SetTextColor(tfr, tfg, tfb)
            else
                frame.timer:SetTextColor(tr, tg, tb)
            end
            frame.timer:SetText(timerText)
        end
        displayTimerText = timerText
    else
        frame.timer:SetTextColor(0.5, 0.5, 0.5)
        frame.timer:SetText("--:--")
        displayTimerText = "--:--"
    end

    if secondStyle then
        frame:SetWidth(arcadeStyle and ARCADE_WIDTH or 320)
        local arcadeFontPath = GetArcadeFontPath()
        local bgr, bgg, bgb = GetColor("colorBackground")
        if arcadeStyle then
            bg:SetVertexColor(0, 0, 0, 0)
            arcadeFrame:Show()
            local hr = math.min(1, bgr + 0.08)
            local hg = math.min(1, bgg + 0.08)
            local hb = math.min(1, bgb + 0.08)
            SetVerticalGradientSafe(arcadeUnifiedBg, bgr, bgg, bgb, 0.94)
            arcadeUnifiedBg:Show()
            arcadeMiddleBg:SetVertexColor(0, 0, 0, 0)
            arcadeHeaderBg:SetVertexColor(0, 0, 0, 0)
            arcadeBottomBg:SetVertexColor(0, 0, 0, 0)
            arcadeHeaderBorder:Hide()
            arcadeMiddleBorder:Hide()
            arcadeBottomBorder:Show()
            arcadeBottomBorder:SetVertexColor(0.56, 0.61, 0.70, 0.42)
            arcadeMidBorderLeft:Hide()
            arcadeMidBorderRight:Hide()
            SetArcadeOuterBorderVisible(true, 0.56, 0.61, 0.70, 0.62)
            arcadeHeaderDivider:Show()
        else
            arcadeUnifiedBg:Hide()
            bg:SetVertexColor(bgr, bgg, bgb, 0.72)
            arcadeFrame:Hide()
            arcadeMiddleBorder:Hide()
            arcadeBottomBorder:Hide()
            arcadeHeaderDivider:Hide()
            SetArcadeOuterBorderVisible(false)
        end
        SetFontSafe(frame.title, arcadeStyle and arcadeFontPath or "Fonts\\FRIZQT__.TTF", 14, arcadeStyle and "" or "OUTLINE", "Fonts\\FRIZQT__.TTF")
        frame.title:SetWordWrap(false)
        frame.title:ClearAllPoints()
        frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", arcadeStyle and 10 or 4, arcadeStyle and -8 or -3)
        collapseBtn:Hide()
        forfeitBtn:Show()
        pauseBtn:Show()
        UpdateArcadeButtonFrames(arcadeStyle)
        forfeitSmall:Hide()
        pauseSmall:Hide()

        frame.plus2:Hide()
        frame.plus3:Hide()
        frame.pauseLabel:Hide()
        frame.affixes:Hide()
        frame.affixesLine2:Hide()
        frame.forcesBarContainer:SetHeight(arcadeStyle and 6 or 16)
        frame.forcesBarFill:ClearAllPoints()
        if arcadeStyle then
            frame.forcesBarFill:SetPoint("TOPLEFT", frame.forcesBarContainer, "TOPLEFT", 0, 0)
            frame.forcesBarFill:SetHeight(6)
            frame.forcesBarPullFill:SetHeight(6)
            fbBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
            fbFill:SetTexture("Interface\\BUTTONS\\WHITE8X8")
            fbPullFill:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        else
            frame.forcesBarFill:SetPoint("TOPLEFT", frame.forcesBarContainer, "TOPLEFT", 1, -1)
            frame.forcesBarFill:SetHeight(14)
            frame.forcesBarPullFill:SetHeight(14)
            fbBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
            fbFill:SetTexture("Interface\\BUTTONS\\WHITE8X8")
            fbPullFill:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        end
        ApplyForcesColor()
        if arcadeStyle then
            fbBg:SetVertexColor(0.20, 0.27, 0.40, 0.95)
        else
            fbBg:SetVertexColor(0.04, 0.04, 0.04, 0.95)
        end
        SetFontSafe(frame.forcesBar.text, arcadeStyle and arcadeFontPath or "Fonts\\FRIZQT__.TTF", 11, arcadeStyle and "" or "OUTLINE", "Fonts\\FRIZQT__.TTF")
        frame.forcesBar.text:SetShadowOffset(arcadeStyle and 0 or 1, arcadeStyle and 0 or -1)
        frame.forcesBar.text:SetShadowColor(0, 0, 0, arcadeStyle and 0 or 1)
        local timerR, timerG, timerB = GetColor("colorTimer")

        if arcadeStyle then
            frame.title:Hide()
            frame.arcadeForcesTitle:Show()
            frame.arcadeForcesValue:Show()
            local lvlText = state.level and ("+" .. state.level) or "+?"
            local dungeonText = (state.mapID and shortDungeonName[state.mapID]) or state.dungeonName or ""
            frame.arcadeLevel:SetText(RGBToHex(GetColor("colorTitle")) .. lvlText .. "|r")
            frame.arcadeDungeon:SetText(RGBToHex(GetColor("colorAffixes")) .. dungeonText .. "|r")
            frame.arcadeLevel:Show()
            frame.arcadeDungeon:Show()
            frame.arcadeTimerDivider:Show()
            frame.arcadeTimerDivider:SetVertexColor(0.56, 0.61, 0.70, 0.42)

            -- Left: main timer and base time below.
            frame.timer:Show()
            frame.timer:ClearAllPoints()
            frame.timer:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -42)
            frame.timer:SetTextColor(timerR, timerG, timerB)
            SetFontSafe(frame.timer, arcadeFontPath, 24, "", "Fonts\\FRIZQT__.TTF")
            SetFontSafe(frame.arcadeBaseTimer, arcadeFontPath, 12, "", "Fonts\\FRIZQT__.TTF")
            SetFontSafe(frame.arcadePlus3Label, arcadeFontPath, 11, "", "Fonts\\FRIZQT__.TTF")
            SetFontSafe(frame.arcadePlus2Label, arcadeFontPath, 11, "", "Fonts\\FRIZQT__.TTF")
            SetFontSafe(frame.arcadePlus3Remain, arcadeFontPath, 11, "", "Fonts\\FRIZQT__.TTF")
            SetFontSafe(frame.arcadePlus2Remain, arcadeFontPath, 11, "", "Fonts\\FRIZQT__.TTF")
            frame.timer:SetText(FormatTime(effElapsed))
            if baseLimit then
                frame.arcadeBaseTimer:SetText("|cff7b88a7/ " .. FormatTime(baseLimit) .. "|r")
            else
                frame.arcadeBaseTimer:SetText("")
            end
            frame.arcadeBaseTimer:ClearAllPoints()
            frame.arcadeBaseTimer:SetPoint("TOPLEFT", frame.timer, "BOTTOMLEFT", 2, -2)
            frame.arcadeBaseTimer:Show()

            -- Hide legacy combined bar for Arcade timer section.
            frame.timerBarContainer:Hide()
            frame.timerBarMark2:Hide()
            frame.timerBarMark3:Hide()
            frame.timerBarPlus2:Hide()
            frame.timerBarPlus3:Hide()

            -- Right: +3/+2 rows with mini-bars and remaining time at right.
            local blockX = 98
            local barW = 124
            local rowTop = -44
            local rowGap = 18
            local function placeArcadeRow(rowIndex, limit, labelFs, barContainer, barBgTex, fillFrame, fillTex, remainFs, labelColorR, labelColorG, labelColorB, fillR, fillG, fillB)
                if not (active and baseLimit and limit and limit > 0) then
                    labelFs:Hide()
                    barContainer:Hide()
                    remainFs:Hide()
                    return
                end
                local y = rowTop - ((rowIndex - 1) * rowGap)
                labelFs:ClearAllPoints()
                labelFs:SetPoint("TOPLEFT", frame, "TOPLEFT", blockX, y)
                labelFs:SetTextColor(labelColorR, labelColorG, labelColorB)
                labelFs:Show()

                barContainer:ClearAllPoints()
                barContainer:SetPoint("TOPLEFT", frame, "TOPLEFT", blockX + 20, y - 2)
                barContainer:SetWidth(barW)
                barContainer:Show()
                barBgTex:SetVertexColor(0.20, 0.27, 0.40, 0.95)
                SetHorizontalGradientSafe(fillTex, fillR, fillG, fillB, 0.95)
                local pct = math.max(0, math.min(1, effElapsed / limit))
                fillFrame:SetWidth(math.max(1, math.floor(barW * pct + 0.5)))

                remainFs:ClearAllPoints()
                remainFs:SetPoint("TOPLEFT", frame, "TOPLEFT", blockX + 20 + barW + 8, y)
                remainFs:SetTextColor(labelColorR, labelColorG, labelColorB)
                local remain = (limit - effElapsed)
                if remain >= 0 then
                    remainFs:SetText("-" .. FormatTime(remain))
                else
                    remainFs:SetText("+" .. FormatTime(-remain))
                end
                remainFs:Show()
            end
            placeArcadeRow(1, limit3, frame.arcadePlus3Label, frame.arcadePlus3BarContainer, frame.arcadePlus3BarBg, frame.arcadePlus3BarFillFrame, frame.arcadePlus3BarFill, frame.arcadePlus3Remain, 1.0, 0.90, 0.32, 1.0, 0.90, 0.32)
            placeArcadeRow(2, limit2, frame.arcadePlus2Label, frame.arcadePlus2BarContainer, frame.arcadePlus2BarBg, frame.arcadePlus2BarFillFrame, frame.arcadePlus2BarFill, frame.arcadePlus2Remain, 0.55, 0.68, 1.0, 0.55, 0.68, 1.0)
        else
            frame.title:Show()
            frame.arcadeForcesTopDivider:Hide()
            frame.arcadeForcesBottomDivider:Hide()
            frame.arcadeForcesTitle:Hide()
            frame.arcadeForcesValue:Hide()
            frame.arcadeLevel:Hide()
            frame.arcadeDungeon:Hide()
            frame.arcadeBaseTimer:Hide()
            frame.arcadePlus3Label:Hide()
            frame.arcadePlus2Label:Hide()
            frame.arcadePlus3Remain:Hide()
            frame.arcadePlus2Remain:Hide()
            frame.arcadePlus3BarContainer:Hide()
            frame.arcadePlus2BarContainer:Hide()
            frame.arcadeTimerDivider:Hide()

            -- Reloe keeps existing combined timer bar.
            frame.timer:Hide()
            frame.timerBarContainer:Show()
            frame.timerBarContainer:SetHeight(16)
            frame.timerBarFill:SetHeight(14)
            SetFontSafe(frame.timerBar.text, "Fonts\\FRIZQT__.TTF", 13, "OUTLINE", "Fonts\\FRIZQT__.TTF")
            local tbr, tbg, tbb = GetColor("colorTimerBar")
            tbFill:SetVertexColor(tbr, tbg, tbb, 0.95)
            fbBg:SetVertexColor(0.04, 0.04, 0.04, 0.95)
            fbFill:SetTexture("Interface\\BUTTONS\\WHITE8X8")
            frame.timerBar.text:SetTextColor(timerR, timerG, timerB)
            frame.timerBarMark2:SetVertexColor(timerR, timerG, timerB, 1)
            frame.timerBarMark3:SetVertexColor(timerR, timerG, timerB, 1)
            frame.timerBarMark2:SetSize(2, 16)
            frame.timerBarMark3:SetSize(2, 16)
            SetFontSafe(frame.timerBarPlus2, "Fonts\\FRIZQT__.TTF", 11, "OUTLINE", "Fonts\\FRIZQT__.TTF")
            SetFontSafe(frame.timerBarPlus3, "Fonts\\FRIZQT__.TTF", 11, "OUTLINE", "Fonts\\FRIZQT__.TTF")

            local barInnerW = math.max(10, frame:GetWidth() - 18)
            local barFillW = 0
            if active and baseLimit and baseLimit > 0 then
                barFillW = math.min(barInnerW - 2, math.max(1, math.floor((barInnerW - 2) * math.min(effElapsed, baseLimit) / baseLimit + 0.5)))
            end
            frame.timerBarFill:SetWidth(math.max(1, barFillW))
            frame.timerBar.text:SetText(displayTimerText)
            local function placeTimerMark(limit, markTex, labelFs)
                if not (active and baseLimit and limit and limit > 0 and limit <= baseLimit) then
                    markTex:Hide()
                    labelFs:Hide()
                    return
                end
                if effElapsed and effElapsed >= limit then
                    markTex:Hide()
                    labelFs:Hide()
                    return
                end
                local x = math.floor((barInnerW - 2) * (limit / baseLimit) + 0.5)
                markTex:ClearAllPoints()
                markTex:SetPoint("TOPLEFT", frame.timerBarContainer, "TOPLEFT", 1 + x, -1)
                markTex:Show()
                labelFs:ClearAllPoints()
                labelFs:SetPoint("RIGHT", markTex, "LEFT", -2, 0)
                local rem = limit - effElapsed
                labelFs:SetText(RGBToHex(GetColor("colorTimer")) .. FormatTime(math.abs(rem)) .. "|r")
                labelFs:Show()
            end
            placeTimerMark(limit2, frame.timerBarMark2, frame.timerBarPlus2)
            placeTimerMark(limit3, frame.timerBarMark3, frame.timerBarPlus3)
        end

        frame.deathsIcon:ClearAllPoints()
        frame.deathsIcon:SetSize(11, 11)
        frame.deaths:ClearAllPoints()
        frame.deaths:SetText(RGBToHex(GetColor("colorDeaths")) .. tostring(deathCount or 0) .. "|r")
        frame.arcadeDeathsDivider:ClearAllPoints()
        frame.battleResIcon:ClearAllPoints()
        frame.battleResIcon:SetSize(11, 11)
        frame.battleRes:ClearAllPoints()
        if arcadeStyle then
            frame.deathsIcon:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 10)
            frame.deaths:SetPoint("LEFT", frame.deathsIcon, "RIGHT", 2, 0)
            frame.arcadeDeathPenaltyFrame:ClearAllPoints()
            frame.arcadeDeathPenaltyFrame:SetPoint("LEFT", frame.deaths, "RIGHT", 2, 0)
            frame.arcadeDeathPenaltyFrame:Show()
            frame.arcadeDeathsDivider:SetPoint("LEFT", frame.arcadeDeathPenaltyFrame, "RIGHT", 8, 0)
            frame.arcadeDeathsDivider:Show()
            frame.battleResIcon:SetPoint("LEFT", frame.arcadeDeathsDivider, "RIGHT", 8, 0)
            frame.battleRes:SetPoint("LEFT", frame.battleResIcon, "RIGHT", 2, 0)
        else
            local topCounterTextGap = -3
            frame.deathsIcon:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -5)
            frame.deaths:SetPoint("RIGHT", frame.deathsIcon, "LEFT", topCounterTextGap, 0)
            frame.battleResIcon:SetPoint("RIGHT", frame.deaths, "LEFT", -10, 0)
            frame.battleRes:SetPoint("RIGHT", frame.battleResIcon, "LEFT", topCounterTextGap, 0)
            frame.arcadeDeathsDivider:Hide()
            frame.arcadeDeathPenaltyFrame:Hide()
        end
        frame.deathsIcon:Show()
        frame.deaths:Show()
        frame.battleRes:Show()
        frame.battleResIcon:Show()
    else
        arcadeUnifiedBg:Hide()
        bg:SetVertexColor(0, 0, 0, 0)
        arcadeFrame:Hide()
        arcadeHeaderDivider:Hide()
        SetArcadeOuterBorderVisible(false)
        UpdateArcadeButtonFrames(false)
        frame.arcadeForcesTopDivider:Hide()
        frame.arcadeForcesBottomDivider:Hide()
        frame.arcadeForcesTitle:Hide()
        frame.arcadeForcesValue:Hide()
        frame.arcadeDeathsDivider:Hide()
        frame.arcadeDeathPenaltyFrame:Hide()
        frame.arcadeBaseTimer:Hide()
        frame.arcadePlus3Label:Hide()
        frame.arcadePlus2Label:Hide()
        frame.arcadePlus3Remain:Hide()
        frame.arcadePlus2Remain:Hide()
        frame.arcadePlus3BarContainer:Hide()
        frame.arcadePlus2BarContainer:Hide()
        frame.arcadeTimerDivider:Hide()
        frame.arcadeLevel:Hide()
        frame.arcadeDungeon:Hide()
        frame.title:Show()
        frame:SetWidth(280)
        local path = GetFontPath(GetStyleOption("font", "Friz Quadrata (default)"))
        frame.title:SetFont(path, 13, "")
        frame.timer:SetFont(path, 20, "")
        frame.forcesBarContainer:SetHeight(16)
        frame.forcesBarFill:ClearAllPoints()
        frame.forcesBarFill:SetPoint("TOPLEFT", frame.forcesBarContainer, "TOPLEFT", 1, -1)
        frame.forcesBarFill:SetHeight(14)
        frame.forcesBarPullFill:SetHeight(14)
        fbBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        fbPullFill:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        fbBg:SetVertexColor(0.05, 0.05, 0.05, 0.9)
        ApplyForcesTexture()
        frame.forcesBar.text:SetFont(path, 11, "")
        frame.forcesBar.text:SetShadowOffset(0, 0)
        frame.forcesBar.text:SetShadowColor(0, 0, 0, 0)
        frame.title:SetWordWrap(true)
        frame.title:ClearAllPoints()
        frame.title:SetPoint("TOPLEFT",  frame, "TOPLEFT",  8, -6)
        frame.title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -6)
        collapseBtn:Show()
        frame.timer:Show()
        frame.timerBarContainer:Hide()
        frame.timerBarMark2:Hide()
        frame.timerBarMark3:Hide()
        frame.timerBarMark2:SetVertexColor(0, 0, 0, 1)
        frame.timerBarMark3:SetVertexColor(0, 0, 0, 1)
        frame.timerBarPlus2:Hide()
        frame.timerBarPlus3:Hide()
        frame.deathsIcon:SetSize(12, 12)
        frame.deathsIcon:Show()
        frame.deaths:Show()
        frame.battleRes:Show()
        frame.battleResIcon:Show()
        if not collapsed then
            forfeitBtn:Show()
            pauseBtn:Show()
            forfeitSmall:Hide()
            pauseSmall:Hide()
        end
    end

    -- В свёрнутом режиме показываем "12:10  +15  Данж" в заголовке (+ "Пауза" если пауза)
    if collapsed then
        if active and state.elapsed then
            local lvlStr  = state.level and ("+" .. state.level) or "?"
            local dungeon = (state.mapID and shortDungeonName[state.mapID]) or state.dungeonName or ""
            local titleStr = string.format("%s%s  %s  %s|r", RGBToHex(GetColor("colorTitle")), FormatTime(effElapsed), lvlStr, dungeon)
            if isPaused then
                titleStr = titleStr .. "  " .. RGBToHex(GetColor("colorTimerFailed")) .. "Пауза|r"
            end
            frame.title:SetText(titleStr)
        else
            frame.title:SetText(lastTitleText)
        end
        return
    end

    -- Строки +2 / +3: основной текст + таймер "осталось до конца" (пока не просрочено)
    local hexPlus23 = RGBToHex(GetColor("colorPlus23"))
    local hexPlus23Exp = RGBToHex(GetColor("colorPlus23Expired"))
    local hexPlus23Rem = RGBToHex(GetColor("colorPlus23Remaining"))
    local showPlus2, showPlus3 = false, false
    if (not secondStyle) and active and state.elapsed and (limit2 or limit3) then
        if limit2 then
            showPlus2 = true
            local rem2 = limit2 - effElapsed
            if useReverse then
                if rem2 < 0 then
                    frame.plus2:SetText(string.format("%s+2 (%s)|r", hexPlus23Exp, FormatTime(limit2)))
                else
                    frame.plus2:SetText(string.format("%s+2 (%s) %s%s|r", hexPlus23, FormatTime(limit2), hexPlus23Rem, FormatTime(rem2)))
                end
            else
                local deadline2 = baseLimit and (baseLimit - limit2) or 0
                local remaining = baseLimit and (baseLimit - effElapsed) or 0
                if remaining < deadline2 then
                    frame.plus2:SetText(string.format("%s+2 (%s)|r", hexPlus23Exp, FormatTime(deadline2)))
                else
                    frame.plus2:SetText(string.format("%s+2 (%s) %s%s|r", hexPlus23, FormatTime(deadline2), hexPlus23Rem, FormatTime(rem2)))
                end
            end
        end
        if limit3 then
            showPlus3 = true
            local rem3 = limit3 - effElapsed
            if useReverse then
                if rem3 < 0 then
                    frame.plus3:SetText(string.format("%s+3 (%s)|r", hexPlus23Exp, FormatTime(limit3)))
                else
                    frame.plus3:SetText(string.format("%s+3 (%s) %s%s|r", hexPlus23, FormatTime(limit3), hexPlus23Rem, FormatTime(rem3)))
                end
            else
                local deadline3 = baseLimit and (baseLimit - limit3) or 0
                local remaining = baseLimit and (baseLimit - effElapsed) or 0
                if remaining < deadline3 then
                    frame.plus3:SetText(string.format("%s+3 (%s)|r", hexPlus23Exp, FormatTime(deadline3)))
                else
                    frame.plus3:SetText(string.format("%s+3 (%s) %s%s|r", hexPlus23, FormatTime(deadline3), hexPlus23Rem, FormatTime(rem3)))
                end
            end
        end
    end

    local bossTopY
    if secondStyle then
        bossTopY = UpdateTimerLayout(false, false)
    else
        bossTopY = UpdateTimerLayout(showPlus2, showPlus3)
    end
    if state.bosses and #state.bosses > 0 then
        UpdateBossLayout(math.min(#state.bosses, MAX_BOSSES), bossTopY)
    else
        UpdateBossLayout(0, bossTopY)
    end

    -- Прогресс (одно значение = %, 0-100)
    local forces = GetForces()
    local useBar = (MPT.db and MPT.db.forcesBar) or secondStyle
    local arcadeForcesTitleHex = "|cff7b88a7"
    local hexForcesPct = RGBToHex(GetColor("colorForcesPct"))
    local hexForcesPull = RGBToHex(GetColor("colorForcesPull"))
    local hexGrey = RGBToHex(GetColor("colorBossKilled"))
    if arcadeStyle then
        frame.arcadeForcesTitle:SetText(arcadeForcesTitleHex .. "Силы противника|r")
    end
    if forces then
        local pctColor = forces >= 100 and hexForcesPull or hexForcesPct
        local pctEnd   = "|r"
        local baseText = string.format("%.1f%%", forces)
        local pullText = ""
        local pullPct = 0
        if (MPT.db and MPT.db.showForcesPullPct ~= false) and engagedForcesTotal >= 0.05 then
            local engagedCount = 0
            for _ in pairs(engagedGuids) do engagedCount = engagedCount + 1 end
            pullPct = engagedForcesTotal
            pullText = string.format(" %s+%.2f%% (%d)|r", hexForcesPull, engagedForcesTotal, engagedCount)
            baseText = baseText .. pullText
        end
        if useBar then
            frame.forcesBar:SetValue(math.min(forces, 100), pullPct)
            if arcadeStyle then
                frame.forcesBar.text:SetText("")
                frame.arcadeForcesValue:SetText(pctColor .. string.format("%.1f%%", forces) .. "|r" .. pullText)
            else
                frame.forcesBar.text:SetText(pctColor .. baseText .. pctEnd)
            end
        else
            frame.forces:SetText(string.format("%sУбито врагов: |r%s%s%s", pctColor, pctColor, baseText, pctEnd))
        end
    else
        if useBar then
            frame.forcesBar:SetValue(0, 0)
            if arcadeStyle then
                frame.forcesBar.text:SetText("")
                frame.arcadeForcesValue:SetText(hexGrey .. "—|r")
            else
                frame.forcesBar.text:SetText(hexGrey .. "—|r")
            end
        else
            frame.forces:SetText(string.format("%sУбито врагов: |r%s—|r", hexForcesPct, hexGrey))
        end
    end

    -- Смерти (иконка черепа + число и штраф)
    local hexDeaths = RGBToHex(GetColor("colorDeaths"))
    local hexDeathsPenalty = RGBToHex(GetColor("colorDeathsPenalty"))
    if secondStyle then
        frame.deaths:SetText(hexDeaths .. tostring(deathCount or 0) .. "|r")
        if arcadeStyle then
            SetArcadePenaltyText(hexDeathsPenalty .. "+" .. tostring(deathLost or 0) .. "с|r")
            frame.arcadeDeathPenaltyFrame:Show()
            frame.arcadeDeathsDivider:Show()
        else
            frame.arcadeDeathPenaltyFrame:Hide()
            frame.arcadeDeathsDivider:Hide()
        end
    elseif deathCount > 0 then
        local deathSign = (useReverse or secondStyle) and "+" or "-"
        frame.deaths:SetText(string.format(
            "%s%d|r %s(%s%dс)|r", hexDeaths, deathCount, hexDeathsPenalty, deathSign, deathLost))
        frame.arcadeDeathPenaltyFrame:Hide()
        frame.arcadeDeathsDivider:Hide()
    else
        frame.deaths:SetText(hexDeaths .. "0|r")
        frame.arcadeDeathPenaltyFrame:Hide()
        frame.arcadeDeathsDivider:Hide()
    end

    -- Боевые воскрешения (иконка сердца + число) — свой цвет для цифры БР
    local hexBattleRes = RGBToHex(GetColor("colorBattleRes"))
    local brCount = GetBattleResCount()
    frame.battleRes:SetText(hexBattleRes .. (brCount ~= nil and tostring(brCount) or "—") .. "|r")
    if secondStyle then
        if arcadeStyle then
            frame.forcesBar.text:ClearAllPoints()
            frame.forcesBar.text:SetPoint("LEFT", frame.forcesBarContainer, "LEFT", 4, 0)
            frame.forcesBar.text:SetPoint("RIGHT", frame.forcesBarContainer, "RIGHT", -4, 0)
            frame.forcesBar.text:SetJustifyH("CENTER")
        else
            frame.forcesBar.text:ClearAllPoints()
            frame.forcesBar.text:SetPoint("LEFT", frame.forcesBarContainer, "LEFT", 4, 0)
            frame.forcesBar.text:SetPoint("RIGHT", frame.forcesBarContainer, "RIGHT", -4, 0)
            frame.forcesBar.text:SetJustifyH("LEFT")
        end
    else
        frame.forcesBar.text:ClearAllPoints()
        frame.forcesBar.text:SetPoint("LEFT",  fbTextFrame, "LEFT",  4, 0)
        frame.forcesBar.text:SetPoint("RIGHT", fbTextFrame, "RIGHT", -4, 0)
        frame.forcesBar.text:SetJustifyH("CENTER")
    end
    NotifyDisplayChanged()
end

-- Forward declaration: UpdateBossDisplay определена ниже, после ShowPreview.
-- Нужна здесь чтобы StartTimer мог её вызвать.
local UpdateBossDisplay

-- ============================================================
-- OnUpdate — тик 0.1с (только пока фрейм видим)
-- ============================================================
local throttle = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    if isDraggingFrame and IsArcadeStyle() then
        -- Keep frame on physical pixel grid during drag, so 1px borders stay stable.
        SnapFrameToPixelGrid()
    end
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
local listeners = {}
local nextListenerId = 0

local function BuildRunSnapshot()
    local bossesCopy = nil
    if type(state.bosses) == "table" then
        bossesCopy = {}
        for i, b in ipairs(state.bosses) do
            bossesCopy[i] = {
                name = b.name,
                killed = b.killed and true or false,
                killTime = b.killTime,
            }
        end
    end
    return {
        running = state.running and true or false,
        completed = state.completed and true or false,
        elapsed = state.elapsed,
        startTime = state.startTime,
        level = state.level,
        affixes = state.affixes,
        dungeonName = state.dungeonName,
        mapID = state.mapID,
        bosses = bossesCopy,
        styleId = (MPT.GetActiveStyleId and MPT:GetActiveStyleId()) or (MPT.db and MPT.db.activeStyle) or "default",
    }
end

local function GetDeathsSnapshot()
    local dOk, d, t = pcall(function() return C_ChallengeMode.GetDeathCount() end)
    if dOk and type(d) == "number" then
        return d, (type(t) == "number" and t or (d * 5))
    end
    return localDeathCount, localDeathLost
end

NotifyDisplayChanged = function()
    if not next(listeners) then return end
    local payload = MPT:GetDisplayData()
    for id, fn in pairs(listeners) do
        local ok = pcall(fn, payload)
        if not ok then
            listeners[id] = nil
        end
    end
end

function MPT:GetRunSnapshot()
    return BuildRunSnapshot()
end

function MPT:GetDisplayData()
    local snap = BuildRunSnapshot()
    local deathCount, deathLost = GetDeathsSnapshot()
    local isPaused = false
    if state.running and C_ChallengeMode and C_ChallengeMode.IsPaused then
        local ok, v = pcall(function() return C_ChallengeMode.IsPaused() end)
        isPaused = ok and v == true
    end
    snap.isPaused = isPaused
    snap.deathCount = deathCount
    snap.deathLost = deathLost
    snap.enemyForces = GetForces()
    snap.battleResCount = GetBattleResCount()
    snap.plus2Limit, snap.plus3Limit = GetPlus2Plus3Limits()
    return snap
end

function MPT:RegisterDisplayListener(callback)
    if type(callback) ~= "function" then return nil end
    nextListenerId = nextListenerId + 1
    listeners[nextListenerId] = callback
    return nextListenerId
end

function MPT:UnregisterDisplayListener(listenerId)
    listeners[listenerId] = nil
end

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
local sirusTrackerSuppressed = false  -- пока true — перехватываем Show()

local function HideSirusTracker()
    sirusTrackerSuppressed = true
    for _, name in ipairs(sirusTrackerFrames) do
        local f = _G[name]
        if f and type(f.IsShown) == "function" then
            local ok, shown = pcall(function() return f:IsShown() end)
            sirusTrackerWasShown[name] = ok and shown or false
            -- Вешаем OnShow-хук чтобы перехватывать повторные Show() от Sirus
            if f.HookScript and not f.__mptHooked then
                f.__mptHooked = true
                pcall(function()
                    f:HookScript("OnShow", function(self)
                        if sirusTrackerSuppressed then
                            self:Hide()
                        end
                    end)
                end)
            end
            pcall(function() f:Hide() end)
        end
    end
end

local function RestoreSirusTracker()
    sirusTrackerSuppressed = false
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

-- Применить видимость стандартного трекера по настройке (для смены опции во время ключа).
function MPT:ApplyDefaultTrackerVisibility()
    if state.running then
        if self.db and self.db.hideDefaultTracker then
            HideSirusTracker()
        else
            RestoreSirusTracker()
        end
    end
end

function MPT:LoadTimerPosition()
    frame:ClearAllPoints()
    local scale = GetStyleOption("scale", 1.0)
    if IsArcadeStyle() then
        -- Arcade baseline: treat 0.9 as visual "1.0".
        scale = (scale or 1) * 0.9
    end
    frame:SetScale(scale)
    local pos
    if self.charDb then
        local sid = GetCurrentStyleId()
        if type(self.charDb.timerPosByStyle) == "table" and type(self.charDb.timerPosByStyle[sid]) == "table" then
            pos = self.charDb.timerPosByStyle[sid]
        else
            pos = self.charDb.timerPos
        end
    end
    if pos and pos.x then
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos.x, pos.y)
    else
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", 250, 300)
    end
    SnapFrameToPixelGrid()
end

-- Последний набор affix ID, переданных в RefreshAffixes.
-- Нужен чтобы RefreshCurrentAffixes работал и в превью, и в активном ключе.
lastDisplayedAffixIDs = nil

-- Обновляет строки аффиксов в зависимости от настроек affixText / affixIcons.
-- Опции независимы: можно показывать обе, одну, или ни одной.
-- Если обе — сначала текст, под ним иконки.
-- affixIDs: таблица id аффиксов или nil.
function MPT:RefreshAffixes(affixIDs)
    lastDisplayedAffixIDs = affixIDs
    local secondStyle = IsCustomStyle()
    local arcadeStyle = IsArcadeStyle()
    local useText  = GetStyleOption("affixText", true)
    local useIcons = GetStyleOption("affixIcons", false)
    if secondStyle then
        useText = false
        useIcons = true
    end

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
        local prefix = RGBToHex(GetColor("colorAffixes"))
        local suffix = "|r"
        frame.affixes:SetText(line1 and (prefix .. line1 .. suffix) or "")
        frame.affixes:Show()
        if line2 and #line2 > 0 then
            frame.affixesLine2:SetText(prefix .. line2 .. suffix)
            frame.affixesLine2:Show()
        end
    end

    -- Блок иконок (скруглённые Frame+Texture)
    if useIcons then
        local iconSize = arcadeStyle and 16 or (secondStyle and 12 or AFFIX_ICON_SIZE)
        local iconGap = arcadeStyle and 4 or (secondStyle and 3 or AFFIX_ICON_GAP)
        -- Скрываем все иконки из пула
        for i = 1, MAX_AFFIX_ICONS do
            frame.affixIconFrames[i]:Hide()
        end
        -- Якорь контейнера: под последней видимой текстовой строкой
        frame.affixesIcons:ClearAllPoints()
        if arcadeStyle then
            frame.affixesIcons:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -8)
        elseif secondStyle then
            frame.affixesIcons:SetPoint("LEFT", frame.title, "RIGHT", 3, 0)
        elseif frame.affixesLine2:IsShown() then
            frame.affixesIcons:SetPoint("TOPLEFT", frame.affixesLine2, "BOTTOMLEFT",  0, -8)
        elseif frame.affixes:IsShown() then
            frame.affixesIcons:SetPoint("TOPLEFT", frame.affixes,      "BOTTOMLEFT",  0, -8)
        else
            frame.affixesIcons:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -24)
        end
        -- Расставляем иконки горизонтально
        local count = math.min(#affixIDs, MAX_AFFIX_ICONS)
        local totalW = count * iconSize + math.max(0, count - 1) * iconGap
        frame.affixesIcons:SetWidth(math.max(totalW, 1))
        frame.affixesIcons:SetHeight(iconSize)
        for i = 1, count do
            local id = affixIDs[i]
            local _, _, icon = GetAffixInfoSafe(id)
            local iconFrame = frame.affixIconFrames[i]
            iconFrame:ClearAllPoints()
            iconFrame:SetSize(iconSize, iconSize)
            if iconFrame.border then iconFrame.border:Hide() end
            if iconFrame.arcadeCornerMask then iconFrame.arcadeCornerMask:Hide() end
            if iconFrame.arcadeRoundBorder then iconFrame.arcadeRoundBorder:Hide() end
            if i == 1 then
                iconFrame:SetPoint("TOPLEFT", frame.affixesIcons, "TOPLEFT", 0, 0)
            else
                iconFrame:SetPoint("TOPLEFT", frame.affixIconFrames[i-1], "TOPRIGHT", iconGap, 0)
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

    -- Область тултипа аффиксов: покрывает текст и/или иконки (подсказка при наведении)
    do
        affixTooltipFrame:ClearAllPoints()
        local topAnchor, topPoint = frame, "TOPLEFT"
        local topX, topY = 8, -24
        local botAnchor, botPoint = frame, "TOPRIGHT"
        local botX, botY = -8, -24
        if frame.affixes:IsShown() then
            topAnchor, topPoint = frame.affixes, "TOPLEFT"
            topX, topY = -8, 4
            botAnchor = frame.affixesLine2:IsShown() and frame.affixesLine2 or frame.affixes
            botPoint = "BOTTOMRIGHT"
            botX, botY = 8, -4
        end
        if frame.affixesIcons:IsShown() then
            if not frame.affixes:IsShown() then
                topAnchor, topPoint = frame.affixesIcons, "TOPLEFT"
                topX, topY = -8, 4
            end
            botAnchor = frame.affixesIcons
            botPoint = "BOTTOMRIGHT"
            botX, botY = 8, -4
        end
        affixTooltipFrame:SetPoint("TOPLEFT",  topAnchor, topPoint, topX, topY)
        affixTooltipFrame:SetPoint("BOTTOMRIGHT", botAnchor, botPoint, botX, botY)
    end

    local bossTopY = UpdateTimerLayout()
    UpdateBossLayout(lastBossCount, bossTopY)
end

function MPT:RefreshCurrentAffixes()
    self:RefreshAffixes(lastDisplayedAffixIDs)
end

function MPT:RefreshForcesMode()
    SetForcesMode((self.db and self.db.forcesBar or false) or IsCustomStyle())
    if frame and frame:IsShown() then
        -- В режиме превью нужна полная перерисовка (UpdateTimerLayout(true,true) + UpdateBossLayout),
        -- иначе только UpdateDisplay() даёт неверный layout и бар «уезжает» вверх.
        if not state.running and not state.completed and self.ShowPreview then
            self:ShowPreview()
        elseif UpdateDisplay then
            UpdateDisplay()
        end
    end
end

function MPT:StartTimer()
    state.running   = true
    state.completed = false
    ClearEngaged()
    if self.db and self.db.hideDefaultTracker then
        HideSirusTracker()
    end
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
    local name   = (state.mapID and shortDungeonName[state.mapID]) or state.dungeonName or ""
    lastTitleText = string.format("%s%s %s|r", RGBToHex(GetColor("colorTitle")), lvlStr, name)
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
                frame.bossRightLines[i]:SetText("")
                frame.bossRightLines[i]:Hide()
                frame.bossRightKillLines[i]:SetText("")
                frame.bossRightKillLines[i]:Hide()
                frame.bossRightDeltaLines[i]:SetText("")
                frame.bossRightDeltaLines[i]:Hide()
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
    if self.db and self.db.hideDefaultTracker then
        RestoreSirusTracker()
    end
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
    local secondStyle = IsCustomStyle()
    local arcadeStyle = IsArcadeStyle()
    local arcadeFontPath = GetArcadeFontPath()

    if secondStyle then
        frame:SetWidth(arcadeStyle and ARCADE_WIDTH or 320)
        local arcadeFontPath = GetArcadeFontPath()
        local bgr, bgg, bgb = GetColor("colorBackground")
        if arcadeStyle then
            bg:SetVertexColor(0, 0, 0, 0)
            arcadeFrame:Show()
            local hr = math.min(1, bgr + 0.08)
            local hg = math.min(1, bgg + 0.08)
            local hb = math.min(1, bgb + 0.08)
            SetVerticalGradientSafe(arcadeUnifiedBg, bgr, bgg, bgb, 0.94)
            arcadeUnifiedBg:Show()
            arcadeMiddleBg:SetVertexColor(0, 0, 0, 0)
            arcadeHeaderBg:SetVertexColor(0, 0, 0, 0)
            arcadeBottomBg:SetVertexColor(0, 0, 0, 0)
            arcadeHeaderBorder:Hide()
            arcadeMiddleBorder:Hide()
            arcadeBottomBorder:Show()
            arcadeBottomBorder:SetVertexColor(0.56, 0.61, 0.70, 0.42)
            arcadeMidBorderLeft:Hide()
            arcadeMidBorderRight:Hide()
            SetArcadeOuterBorderVisible(true, 0.56, 0.61, 0.70, 0.62)
            arcadeHeaderDivider:Show()
        else
            arcadeUnifiedBg:Hide()
            bg:SetVertexColor(bgr, bgg, bgb, 0.72)
            arcadeFrame:Hide()
            arcadeMiddleBorder:Hide()
            arcadeBottomBorder:Hide()
            arcadeHeaderDivider:Hide()
            SetArcadeOuterBorderVisible(false)
        end
        SetFontSafe(frame.title, arcadeStyle and arcadeFontPath or "Fonts\\FRIZQT__.TTF", 14, arcadeStyle and "" or "OUTLINE", "Fonts\\FRIZQT__.TTF")
        frame.title:SetWordWrap(false)
        frame.title:ClearAllPoints()
        frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", arcadeStyle and 10 or 4, arcadeStyle and -8 or -3)
        collapseBtn:Hide()
        forfeitBtn:Show()
        pauseBtn:Show()
        UpdateArcadeButtonFrames(arcadeStyle)
        forfeitSmall:Hide()
        pauseSmall:Hide()
        frame.timer:Hide()
        frame.plus2:Hide()
        frame.plus3:Hide()
        frame.pauseLabel:Hide()
        frame.battleRes:Show()
        frame.battleResIcon:SetSize(11, 11)
        frame.battleResIcon:ClearAllPoints()
        frame.battleRes:ClearAllPoints()
        frame.deathsIcon:SetSize(11, 11)
        frame.deathsIcon:ClearAllPoints()
        frame.deaths:ClearAllPoints()
        frame.arcadeDeathsDivider:ClearAllPoints()
        if arcadeStyle then
            frame.deathsIcon:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 10)
            frame.deaths:SetPoint("LEFT", frame.deathsIcon, "RIGHT", 2, 0)
            SetArcadePenaltyText(RGBToHex(GetColor("colorDeathsPenalty")) .. "+20с|r")
            frame.arcadeDeathPenaltyFrame:ClearAllPoints()
            frame.arcadeDeathPenaltyFrame:SetPoint("LEFT", frame.deaths, "RIGHT", 2, 0)
            frame.arcadeDeathPenaltyFrame:Show()
            frame.arcadeDeathsDivider:SetPoint("LEFT", frame.arcadeDeathPenaltyFrame, "RIGHT", 8, 0)
            frame.arcadeDeathsDivider:Show()
            frame.battleResIcon:SetPoint("LEFT", frame.arcadeDeathsDivider, "RIGHT", 8, 0)
            frame.battleRes:SetPoint("LEFT", frame.battleResIcon, "RIGHT", 2, 0)
        else
            local topCounterTextGap = -3
            frame.battleResIcon:SetPoint("RIGHT", frame.deaths, "LEFT", -10, 0)
            frame.battleRes:SetPoint("RIGHT", frame.battleResIcon, "LEFT", topCounterTextGap, 0)
            frame.deathsIcon:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -5)
            frame.deaths:SetPoint("RIGHT", frame.deathsIcon, "LEFT", topCounterTextGap, 0)
            frame.arcadeDeathsDivider:Hide()
            frame.arcadeDeathPenaltyFrame:Hide()
        end
    else
        arcadeUnifiedBg:Hide()
        bg:SetVertexColor(0, 0, 0, 0)
        arcadeFrame:Hide()
        arcadeHeaderDivider:Hide()
        SetArcadeOuterBorderVisible(false)
        UpdateArcadeButtonFrames(false)
        frame.arcadeBaseTimer:Hide()
        frame.arcadePlus3Label:Hide()
        frame.arcadePlus2Label:Hide()
        frame.arcadePlus3Remain:Hide()
        frame.arcadePlus2Remain:Hide()
        frame.arcadePlus3BarContainer:Hide()
        frame.arcadePlus2BarContainer:Hide()
        frame.arcadeLevel:Hide()
        frame.arcadeDungeon:Hide()
        frame.arcadeDeathsDivider:Hide()
        frame.arcadeDeathPenaltyFrame:Hide()
        frame.title:Show()
        local path = GetFontPath(GetStyleOption("font", "Friz Quadrata (default)"))
        frame.title:SetFont(path, 13, "")
        frame.title:SetWordWrap(true)
        frame.forcesBarContainer:SetHeight(16)
        frame.forcesBarFill:ClearAllPoints()
        frame.forcesBarFill:SetPoint("TOPLEFT", frame.forcesBarContainer, "TOPLEFT", 1, -1)
        frame.forcesBarFill:SetHeight(14)
        frame.forcesBarPullFill:SetHeight(14)
        frame.title:ClearAllPoints()
        frame.title:SetPoint("TOPLEFT",  frame, "TOPLEFT",  8, -6)
        frame.title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -6)
        collapseBtn:Show()
        forfeitBtn:Show()
        pauseBtn:Show()
        forfeitSmall:Hide()
        pauseSmall:Hide()
        frame.battleRes:Show()
        frame.battleResIcon:Show()
    end

    lastTitleText = string.format("%s+15 Кузня Крови|r", RGBToHex(GetColor("colorTitle")))
    frame.title:SetText(lastTitleText)
    -- Аффиксы превью: 4 иконки с разными способами скругления для теста
    local previewAffixIDs = { 10, 2, 12, 3 }
    self:RefreshAffixes(previewAffixIDs)
    local tr, tg, tb = GetColor("colorTimer")
    frame.timer:SetTextColor(tr, tg, tb)
    local hexP23 = RGBToHex(GetColor("colorPlus23"))
    local hexP23Rem = RGBToHex(GetColor("colorPlus23Remaining"))
    if secondStyle then
        local arcadeFontPath = GetArcadeFontPath()
        frame.timer:SetText("12:44")
        frame.timerBarContainer:Show()
        frame.timerBarContainer:SetHeight(arcadeStyle and 12 or 16)
        frame.timerBarFill:SetHeight(arcadeStyle and 10 or 14)
        frame.forcesBarContainer:SetHeight(arcadeStyle and 6 or 16)
        frame.forcesBarFill:ClearAllPoints()
        if arcadeStyle then
            frame.forcesBarFill:SetPoint("TOPLEFT", frame.forcesBarContainer, "TOPLEFT", 0, 0)
            frame.forcesBarFill:SetHeight(6)
            frame.forcesBarPullFill:SetHeight(6)
            fbBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
            fbFill:SetTexture("Interface\\BUTTONS\\WHITE8X8")
            fbPullFill:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        else
            frame.forcesBarFill:SetPoint("TOPLEFT", frame.forcesBarContainer, "TOPLEFT", 1, -1)
            frame.forcesBarFill:SetHeight(14)
            frame.forcesBarPullFill:SetHeight(14)
            fbBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
            fbFill:SetTexture("Interface\\BUTTONS\\WHITE8X8")
            fbPullFill:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        end
        SetFontSafe(frame.timerBar.text, arcadeStyle and arcadeFontPath or "Fonts\\FRIZQT__.TTF", 13, arcadeStyle and "" or "OUTLINE", "Fonts\\FRIZQT__.TTF")
        frame.timerBar.text:SetTextColor(tr, tg, tb)
        local tbr, tbg, tbb = GetColor("colorTimerBar")
        tbFill:SetVertexColor(tbr, tbg, tbb, 0.95)
        if arcadeStyle then
            fbBg:SetVertexColor(0.20, 0.27, 0.40, 0.95)
        else
            fbBg:SetVertexColor(0.04, 0.04, 0.04, 0.95)
        end
        fbFill:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        ApplyForcesColor()
        SetFontSafe(frame.forcesBar.text, arcadeStyle and arcadeFontPath or "Fonts\\FRIZQT__.TTF", 11, arcadeStyle and "" or "OUTLINE", "Fonts\\FRIZQT__.TTF")
        frame.forcesBar.text:SetShadowOffset(arcadeStyle and 0 or 1, arcadeStyle and 0 or -1)
        frame.forcesBar.text:SetShadowColor(0, 0, 0, arcadeStyle and 0 or 1)
        frame.timerBarMark2:SetVertexColor(tr, tg, tb, 1)
        frame.timerBarMark3:SetVertexColor(tr, tg, tb, 1)
        frame.timerBarMark2:SetSize(arcadeStyle and 1 or 2, arcadeStyle and 12 or 16)
        frame.timerBarMark3:SetSize(arcadeStyle and 1 or 2, arcadeStyle and 12 or 16)
        SetFontSafe(frame.timerBarPlus2, arcadeStyle and arcadeFontPath or "Fonts\\FRIZQT__.TTF", 11, arcadeStyle and "" or "OUTLINE", "Fonts\\FRIZQT__.TTF")
        SetFontSafe(frame.timerBarPlus3, arcadeStyle and arcadeFontPath or "Fonts\\FRIZQT__.TTF", 11, arcadeStyle and "" or "OUTLINE", "Fonts\\FRIZQT__.TTF")
        if arcadeStyle then
            frame.title:Hide()
            frame.arcadeLevel:SetText(RGBToHex(GetColor("colorTitle")) .. "+15|r")
            frame.arcadeDungeon:SetText(RGBToHex(GetColor("colorAffixes")) .. "Кузня Крови|r")
            frame.arcadeLevel:Show()
            frame.arcadeDungeon:Show()
        else
            frame.title:Show()
            frame.arcadeLevel:Hide()
            frame.arcadeDungeon:Hide()
        end
        frame.timerBar.text:SetText("12:44/35:00")
        frame.timerBarFill:SetWidth(math.floor((frame:GetWidth() - 18) * 0.36))
        frame.timerBarMark2:Show()
        frame.timerBarMark3:Show()
        frame.timerBarPlus2:Show()
        frame.timerBarPlus3:Show()
        if arcadeStyle then
            frame.timerBarContainer:Hide()
            frame.timerBarMark2:Hide()
            frame.timerBarMark3:Hide()
            frame.timerBarPlus2:Hide()
            frame.timerBarPlus3:Hide()
            frame.timer:Show()
            frame.timer:ClearAllPoints()
            frame.timer:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -42)
            SetFontSafe(frame.timer, arcadeFontPath, 24, "", "Fonts\\FRIZQT__.TTF")
            SetFontSafe(frame.arcadeBaseTimer, arcadeFontPath, 12, "", "Fonts\\FRIZQT__.TTF")
            SetFontSafe(frame.arcadePlus3Label, arcadeFontPath, 11, "", "Fonts\\FRIZQT__.TTF")
            SetFontSafe(frame.arcadePlus2Label, arcadeFontPath, 11, "", "Fonts\\FRIZQT__.TTF")
            SetFontSafe(frame.arcadePlus3Remain, arcadeFontPath, 11, "", "Fonts\\FRIZQT__.TTF")
            SetFontSafe(frame.arcadePlus2Remain, arcadeFontPath, 11, "", "Fonts\\FRIZQT__.TTF")
            frame.arcadeBaseTimer:SetText("|cff7b88a7/ 35:00|r")
            frame.arcadeBaseTimer:ClearAllPoints()
            frame.arcadeBaseTimer:SetPoint("TOPLEFT", frame.timer, "BOTTOMLEFT", 2, -2)
            frame.arcadeBaseTimer:Show()
            frame.arcadeTimerDivider:Show()
            frame.arcadeTimerDivider:SetVertexColor(0.56, 0.61, 0.70, 0.42)
            local blockX = 98
            local barW = 124
            frame.arcadePlus3Label:Show()
            frame.arcadePlus3Label:ClearAllPoints()
            frame.arcadePlus3Label:SetPoint("TOPLEFT", frame, "TOPLEFT", blockX, -44)
            frame.arcadePlus3BarContainer:Show()
            frame.arcadePlus3BarContainer:ClearAllPoints()
            frame.arcadePlus3BarContainer:SetPoint("TOPLEFT", frame, "TOPLEFT", blockX + 20, -46)
            frame.arcadePlus3BarContainer:SetWidth(barW)
            frame.arcadePlus3BarFillFrame:SetWidth(44)
            frame.arcadePlus3BarBg:SetVertexColor(0.20, 0.27, 0.40, 0.95)
            SetHorizontalGradientSafe(frame.arcadePlus3BarFill, 1.0, 0.90, 0.32, 0.95)
            frame.arcadePlus3Remain:Show()
            frame.arcadePlus3Remain:SetText("-17:44")
            frame.arcadePlus3Remain:ClearAllPoints()
            frame.arcadePlus3Remain:SetPoint("TOPLEFT", frame, "TOPLEFT", blockX + 20 + barW + 8, -44)
            frame.arcadePlus2Label:Show()
            frame.arcadePlus2Label:ClearAllPoints()
            frame.arcadePlus2Label:SetPoint("TOPLEFT", frame, "TOPLEFT", blockX, -62)
            frame.arcadePlus2BarContainer:Show()
            frame.arcadePlus2BarContainer:ClearAllPoints()
            frame.arcadePlus2BarContainer:SetPoint("TOPLEFT", frame, "TOPLEFT", blockX + 20, -64)
            frame.arcadePlus2BarContainer:SetWidth(barW)
            frame.arcadePlus2BarFillFrame:SetWidth(62)
            frame.arcadePlus2BarBg:SetVertexColor(0.20, 0.27, 0.40, 0.95)
            SetHorizontalGradientSafe(frame.arcadePlus2BarFill, 0.55, 0.68, 1.0, 0.95)
            frame.arcadePlus2Remain:Show()
            frame.arcadePlus2Remain:SetTextColor(0.55, 0.68, 1.0)
            frame.arcadePlus2Remain:SetText("-12:08")
            frame.arcadePlus2Remain:ClearAllPoints()
            frame.arcadePlus2Remain:SetPoint("TOPLEFT", frame, "TOPLEFT", blockX + 20 + barW + 8, -62)
        else
            frame.arcadeBaseTimer:Hide()
            frame.arcadePlus3Label:Hide()
            frame.arcadePlus2Label:Hide()
            frame.arcadePlus3Remain:Hide()
            frame.arcadePlus2Remain:Hide()
            frame.arcadePlus3BarContainer:Hide()
            frame.arcadePlus2BarContainer:Hide()
            frame.arcadeTimerDivider:Hide()
        end
        frame.plus2:Hide()
        frame.plus3:Hide()
    elseif MPT.db and MPT.db.reverseTimer then
        frame.timerBarContainer:Hide()
        frame.timer:SetText("12:44/35:00")
        frame.plus2:SetText(string.format("%s+2 (28:00) %s15:16|r", hexP23, hexP23Rem))
        frame.plus3:SetText(string.format("%s+3 (22:24) %s9:40|r", hexP23, hexP23Rem))
    else
        frame.timerBarContainer:Hide()
        fbBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        fbBg:SetVertexColor(0.05, 0.05, 0.05, 0.9)
        ApplyForcesTexture()
        local path = GetFontPath(GetStyleOption("font", "Friz Quadrata (default)"))
        frame.forcesBar.text:SetFont(path, 11, "")
        frame.forcesBar.text:SetShadowOffset(0, 0)
        frame.forcesBar.text:SetShadowColor(0, 0, 0, 0)
        frame.timer:SetText("22:16")
        frame.plus2:SetText(string.format("%s+2 (7:00) %s15:16|r", hexP23, hexP23Rem))
        frame.plus3:SetText(string.format("%s+3 (12:36) %s9:40|r", hexP23, hexP23Rem))
    end

    -- Боссы: берём из статической базы для Кузни Крови
    local previewDungeon = "Кузня Крови"
    local previewBossList = self:GetDungeonBosses(previewDungeon) or {}
    local previewTexts = {}
    local showRecord = true
    if MPT.db and MPT.db.showBossRecord ~= nil then
        showRecord = not not MPT.db.showBossRecord
    end
    local hexBossKilled = RGBToHex(GetColor("colorBossKilled"))
    local hexBossPending = RGBToHex(GetColor("colorBossPending"))
    for j, bossName in ipairs(previewBossList) do
        if j == 1 then
            -- Время убийства от старта ключа; рекорд 4:01, текущий 3:41 = -0:20
            if secondStyle then
                if arcadeStyle then
                    local hexNameDone = "|cff9aa7bb"
                    local hexTimeDone = "|cff7b88a7"
                    local hexGood = "|cff58ff96"
                    previewTexts[j] = { left = string.format("%s%s|r", hexNameDone, bossName), kill = string.format("%s2:03|r", hexTimeDone), delta = string.format("%s-0:20|r", hexGood) }
                elseif showRecord then
                    previewTexts[j] = { left = string.format("%s%s|r", hexBossKilled, bossName), right = string.format("%s-0:20  3:41|r", hexBossKilled) }
                else
                    previewTexts[j] = { left = string.format("%s%s|r", hexBossKilled, bossName), right = string.format("%s3:41|r", hexBossKilled) }
                end
            elseif showRecord then
                previewTexts[j] = string.format("%s[+] %s  3:41 (Рекорд 4:01, -0:20)|r", hexBossKilled, bossName)
            else
                previewTexts[j] = string.format("%s[+] %s  3:41|r", hexBossKilled, bossName)
            end
        elseif j == 2 then
            if secondStyle then
                if arcadeStyle then
                    local hexNameDone = "|cff9aa7bb"
                    local hexTimeDone = "|cff7b88a7"
                    local hexBad = "|cffff6a6a"
                    previewTexts[j] = { left = string.format("%s%s|r", hexNameDone, bossName), kill = string.format("%s4:51|r", hexTimeDone), delta = string.format("%s+0:07|r", hexBad) }
                elseif showRecord then
                    local hexBad = RGBToHex(GetColor("colorTimerFailed"))
                    previewTexts[j] = { left = string.format("%s%s|r", hexBossKilled, bossName), right = string.format("%s+0:07  7:22|r", hexBad) }
                else
                    previewTexts[j] = { left = string.format("%s%s|r", hexBossKilled, bossName), right = string.format("%s7:22|r", hexBossKilled) }
                end
            elseif showRecord then
                previewTexts[j] = string.format("%s[+] %s  7:22 (Рекорд 7:15, +0:07)|r", hexBossKilled, bossName)
            else
                previewTexts[j] = string.format("%s[+] %s  7:22|r", hexBossKilled, bossName)
            end
        else
            if secondStyle then
                if arcadeStyle then
                    previewTexts[j] = { left = string.format("|cffffffff%s|r", bossName), kill = "|cff7b88a7--|r", delta = "|cff7b88a7--|r" }
                else
                    previewTexts[j] = { left = string.format("%s%s|r", hexBossPending, bossName), right = "" }
                end
            else
                previewTexts[j] = string.format("%s[ ] %s|r", hexBossPending, bossName)
            end
        end
    end
    local previewCount = math.min(#previewTexts, MAX_BOSSES)
    for i = 1, previewCount do
        local fs = frame.bossLines[i]
        if secondStyle then
            if arcadeStyle then
                SetFontSafe(fs, arcadeFontPath, 11, "", "Fonts\\FRIZQT__.TTF")
                SetFontSafe(frame.bossRightKillLines[i], arcadeFontPath, 11, "", "Fonts\\FRIZQT__.TTF")
                SetFontSafe(frame.bossRightDeltaLines[i], arcadeFontPath, 11, "", "Fonts\\FRIZQT__.TTF")
            else
                fs:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
            end
            fs:SetText(previewTexts[i].left)
            if arcadeStyle then
                frame.bossRightLines[i]:Hide()
                frame.bossRightKillLines[i]:SetText(previewTexts[i].kill or "|cff7b88a7--|r")
                frame.bossRightDeltaLines[i]:SetText(previewTexts[i].delta or "|cff7b88a7--|r")
                frame.bossRightKillLines[i]:Show()
                frame.bossRightDeltaLines[i]:Show()
            else
                frame.bossRightLines[i]:SetText(previewTexts[i].right)
                frame.bossRightLines[i]:Show()
                frame.bossRightKillLines[i]:Hide()
                frame.bossRightDeltaLines[i]:Hide()
            end
        else
            fs:SetText(previewTexts[i])
            frame.bossRightLines[i]:Hide()
            frame.bossRightKillLines[i]:Hide()
            frame.bossRightDeltaLines[i]:Hide()
        end
        local h = fs:GetStringHeight() or 0
        frame.bossLineH[i] = (h > BOSS_LINE_H1 + 2) and BOSS_LINE_H2 or BOSS_LINE_H1
        fs:Show()
    end
    for i = previewCount + 1, MAX_BOSSES do
        frame.bossLines[i]:Hide()
        frame.bossRightLines[i]:Hide()
        frame.bossRightKillLines[i]:Hide()
        frame.bossRightDeltaLines[i]:Hide()
    end
    local previewBossTopY = secondStyle and 0 or UpdateTimerLayout(true, true)
    local useForcesBar = secondStyle or (MPT.db and MPT.db.forcesBar)
    SetForcesMode(useForcesBar)
    UpdateBossLayout(previewCount, previewBossTopY)
    if arcadeStyle then
        for i = 1, MAX_BOSSES do
            local rowBg = frame.bossRowBgs[i]
            if rowBg and i <= previewCount then
                if i == 3 then
                    rowBg:SetVertexColor(0.42, 0.54, 0.78, 0.16)
                    rowBg:Show()
                else
                    rowBg:Hide()
                end
            elseif rowBg then
                rowBg:Hide()
            end
            local iconTex = frame.bossStatusIcons[i]
            if iconTex and i <= previewCount then
                if i <= 2 then
                    iconTex:SetVertexColor(0.62, 1.00, 0.70, 1)
                else
                    iconTex:SetVertexColor(0.62, 0.80, 1.00, 1)
                end
                iconTex:Show()
            elseif iconTex then
                iconTex:Hide()
            end
        end
    else
        for i = 1, MAX_BOSSES do
            if frame.bossStatusIcons[i] then frame.bossStatusIcons[i]:Hide() end
        end
    end

    local showPullPct = MPT.db and MPT.db.showForcesPullPct ~= false
    local hexFPct = RGBToHex(GetColor("colorForcesPct"))
    local hexFPull = RGBToHex(GetColor("colorForcesPull"))
    local hexD = RGBToHex(GetColor("colorDeaths"))
    local hexDPen = RGBToHex(GetColor("colorDeathsPenalty"))
    local forcesPreviewText = showPullPct and string.format("%s70.0%%|r %s+ 5.40%% (7)|r", hexFPct, hexFPull) or (hexFPct .. "70.0%|r")
    if useForcesBar then
        frame.forcesBar:SetValue(70, showPullPct and 5.40 or 0)
        if arcadeStyle then
            frame.arcadeForcesTitle:SetText("|cff7b88a7Силы противника|r")
            frame.arcadeForcesValue:SetText(showPullPct and string.format("%s70.0%%|r %s+5.40%% (7)|r", hexFPct, hexFPull) or string.format("%s70.0%%|r", hexFPct))
            frame.forcesBar.text:SetText("")
        else
            frame.forcesBar.text:SetText(forcesPreviewText)
        end
        if secondStyle then
            frame.forcesBar.text:ClearAllPoints()
            frame.forcesBar.text:SetPoint("LEFT", frame.forcesBarContainer, "LEFT", 4, 0)
            frame.forcesBar.text:SetPoint("RIGHT", frame.forcesBarContainer, "RIGHT", -4, 0)
            frame.forcesBar.text:SetJustifyH(arcadeStyle and "CENTER" or "LEFT")
        end
    else
        local textPreview = showPullPct and string.format("%sУбито врагов: |r%s70.0%%|r %s+5.40%% (7)|r", hexFPct, hexFPct, hexFPull) or string.format("%sУбито врагов: |r%s70.0%%|r", hexFPct, hexFPct)
        frame.forces:SetText(textPreview)
    end
    if secondStyle then
        frame.deaths:SetText(string.format("%s2|r", hexD))
    elseif MPT.db and MPT.db.reverseTimer then
        frame.deaths:SetText(string.format("%s2|r %s(+10с)|r", hexD, hexDPen))
    else
        frame.deaths:SetText(string.format("%s2|r %s(-10с)|r", hexD, hexDPen))
    end
    if secondStyle then
        local hexBR = RGBToHex(GetColor("colorBattleRes"))
        frame.battleRes:SetText(hexBR .. "1|r")
    else
        local hexBR = RGBToHex(GetColor("colorBattleRes"))
        frame.battleRes:SetText(hexBR .. "1|r")
    end

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
-- Рекорды боссов: лучшее время убийства от старта ключа (kt в секундах).
-- Хранятся в MPT.db.bossRecords[dungeonName][keystoneLevel][bossName] = { kt = killTime }
-- ============================================================
local function GetBossRecord(bossName)
    if not MPT.db or not MPT.db.bossRecords then return nil end
    local dn = tostring(state.dungeonName)
    local lv = tonumber(state.level) or 0
    if lv <= 0 then return end
    if not dn or not lv then return nil end
    local dr = MPT.db.bossRecords[dn]
    local lr = dr and dr[lv]
    return lr and lr[bossName] or nil
end

local function UpdateBossRecord(bossName, killTime)
    if not MPT.db or not state.dungeonName or not state.level then return end
    if not killTime or killTime < 0 then return end
    if not MPT.db.bossRecords then MPT.db.bossRecords = {} end
    local records = MPT.db.bossRecords
    local dn = state.dungeonName
    local lv = state.level
    if not records[dn] then records[dn] = {} end
    local dnRec = records[dn]
    if not dnRec[lv] then dnRec[lv] = {} end
    local lvRec = dnRec[lv]
    local rec = lvRec[bossName]
    if not rec then
        lvRec[bossName] = { kt = killTime }
    elseif not rec.kt or killTime < rec.kt then
        rec.kt = killTime
    end
end

-- Форматирует отклонение от рекорда: -0:20 (быстрее рекорда) или +0:04 (медленнее)
local function FormatDelta(currentKillTime, recordKillTime)
    local delta = currentKillTime - recordKillTime
    local sign  = delta >= 0 and "+" or "-"
    local abs   = math.abs(delta)
    return sign .. string.format("%d:%02d", math.floor(abs / 60), math.floor(abs % 60))
end

UpdateBossDisplay = function()
    if not state.bosses or #state.bosses == 0 then return end
    local secondStyle = IsCustomStyle()
    local arcadeStyle = IsArcadeStyle()
    local hexKilled = RGBToHex(GetColor("colorBossKilled"))
    local hexPending = RGBToHex(GetColor("colorBossPending"))
    local hexFailed = RGBToHex(GetColor("colorTimerFailed"))
    local arcadeFontPath = arcadeStyle and GetArcadeFontPath() or "Fonts\\FRIZQT__.TTF"
    local count = math.min(#state.bosses, MAX_BOSSES)
    for i = 1, count do
        frame.bossLines[i]:Show()
        if secondStyle then
            if arcadeStyle then
                frame.bossRightLines[i]:Hide()
                frame.bossRightKillLines[i]:Show()
                frame.bossRightDeltaLines[i]:Show()
                frame.bossStatusIcons[i]:Show()
            else
                frame.bossRightLines[i]:Show()
                frame.bossRightKillLines[i]:Hide()
                frame.bossRightDeltaLines[i]:Hide()
                frame.bossStatusIcons[i]:Hide()
            end
        else
            frame.bossRightLines[i]:Hide()
            frame.bossRightKillLines[i]:Hide()
            frame.bossRightDeltaLines[i]:Hide()
            frame.bossStatusIcons[i]:Hide()
        end
    end
    for i = count + 1, MAX_BOSSES do
        frame.bossLines[i]:Hide()
        frame.bossRightLines[i]:Hide()
        frame.bossRightKillLines[i]:Hide()
        frame.bossRightDeltaLines[i]:Hide()
        frame.bossStatusIcons[i]:Hide()
    end
    for i = 1, count do
        local boss = state.bosses[i]
        local line
        local rightText = ""
        local rightKillText = ""
        local rightDeltaText = ""
        local showRecord = true
        if MPT.db and MPT.db.showBossRecord ~= nil then
            showRecord = not not MPT.db.showBossRecord
        end
        local rec = GetBossRecord(boss.name)
        if boss.killed then
            local kt = boss.killTime
            if kt then
                local ktStr = FormatTime(kt)
                if rec and rec.kt and showRecord then
                    if secondStyle then
                        if arcadeStyle then
                            local delta = FormatDelta(kt, rec.kt)
                            local isSlower = (kt - rec.kt) > 0
                            local hexNameDone = "|cff9aa7bb"
                            local hexTimeDone = "|cff7b88a7"
                            local hexDelta = isSlower and "|cffff6a6a" or "|cff58ff96"
                            line = string.format("%s%s|r", hexNameDone, boss.name)
                            rightKillText = string.format("%s%s|r", hexTimeDone, ktStr)
                            rightDeltaText = string.format("%s%s|r", hexDelta, delta)
                        else
                            local delta = FormatDelta(kt, rec.kt)
                            local isSlower = (kt - rec.kt) > 0
                            local rightColor = isSlower and hexFailed or hexKilled
                            line = string.format("%s%s|r", hexKilled, boss.name)
                            rightText = string.format("%s%s|r %s%s|r", rightColor, delta, rightColor, ktStr)
                        end
                    else
                        local delta = FormatDelta(kt, rec.kt)
                        line = string.format("%s[+] %s  %s (Рекорд %s, %s)|r",
                            hexKilled, boss.name, ktStr, FormatTime(rec.kt), delta)
                    end
                else
                    if secondStyle then
                        if arcadeStyle then
                            local hexNameDone = "|cff9aa7bb"
                            local hexTimeDone = "|cff7b88a7"
                            line = string.format("%s%s|r", hexNameDone, boss.name)
                            rightKillText = string.format("%s%s|r", hexTimeDone, ktStr)
                            rightDeltaText = "|cff7b88a7--|r"
                        else
                            line = string.format("%s%s|r", hexKilled, boss.name)
                            -- showBossRecord=false: keep only kill time, always green
                            rightText = string.format("%s%s|r", hexKilled, ktStr)
                        end
                    else
                        line = string.format("%s[+] %s  %s|r", hexKilled, boss.name, ktStr)
                    end
                end
            else
                if secondStyle then
                    if arcadeStyle then
                        line = string.format("|cff9aa7bb%s|r", boss.name)
                        rightKillText = "|cff7b88a7--|r"
                        rightDeltaText = "|cff7b88a7--|r"
                    else
                        line = string.format("%s%s|r", hexKilled, boss.name)
                        rightText = hexKilled .. "—|r"
                    end
                else
                    line = string.format("%s[+] %s|r", hexKilled, boss.name)
                end
            end
        else
            if secondStyle then
                if arcadeStyle then
                    line = string.format("|cffffffff%s|r", boss.name)
                    rightKillText = "|cff7b88a7--|r"
                    rightDeltaText = "|cff7b88a7--|r"
                else
                    line = string.format("%s%s|r", hexPending, boss.name)
                    if showRecord and rec and rec.kt then
                        rightText = hexPending .. FormatTime(rec.kt) .. "|r"
                    else
                        rightText = ""
                    end
                end
            else
                line = string.format("%s[ ] %s|r", hexPending, boss.name)
            end
        end
        local fs = frame.bossLines[i]
        if secondStyle then
            SetFontSafe(fs, arcadeFontPath, arcadeStyle and 11 or 12, arcadeStyle and "" or "OUTLINE", "Fonts\\FRIZQT__.TTF")
        end
        fs:SetText(line)
        if secondStyle then
            if arcadeStyle then
                frame.bossRightLines[i]:Hide()
                SetFontSafe(frame.bossRightKillLines[i], arcadeFontPath, 11, "", "Fonts\\FRIZQT__.TTF")
                SetFontSafe(frame.bossRightDeltaLines[i], arcadeFontPath, 11, "", "Fonts\\FRIZQT__.TTF")
                frame.bossRightKillLines[i]:SetText(rightKillText)
                frame.bossRightDeltaLines[i]:SetText(rightDeltaText)
                frame.bossRightKillLines[i]:Show()
                frame.bossRightDeltaLines[i]:Show()
                if frame.bossStatusIcons[i] then
                    if boss.killed then
                        frame.bossStatusIcons[i]:SetVertexColor(0.62, 1.00, 0.70, 1)
                    else
                        frame.bossStatusIcons[i]:SetVertexColor(0.62, 0.80, 1.00, 1)
                    end
                    frame.bossStatusIcons[i]:Show()
                end
            else
                SetFontSafe(frame.bossRightLines[i], arcadeFontPath, 12, "OUTLINE", "Fonts\\FRIZQT__.TTF")
                frame.bossRightLines[i]:SetText(rightText)
                frame.bossRightLines[i]:Show()
                frame.bossRightKillLines[i]:Hide()
                frame.bossRightDeltaLines[i]:Hide()
                if frame.bossStatusIcons[i] then frame.bossStatusIcons[i]:Hide() end
            end
        end
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
evFrame:RegisterEvent("PLAYER_REGEN_ENABLED")       -- выход из боя → сбрасываем engaged
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

    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Вышли из боя — все engaged мобы либо убиты, либо сброшены
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
            -- Сливаем с текущим состоянием: сохраняем killTime для уже убитых
            local oldBosses = state.bosses
            if oldBosses then
                for _, newBoss in ipairs(newBosses) do
                    for _, oldBoss in ipairs(oldBosses) do
                        if oldBoss.name == newBoss.name and oldBoss.killed then
                            -- Сохраняем локальное состояние (ASMSG может прислать status=0 для убитого босса)
                            newBoss.killed   = true
                            newBoss.killTime = oldBoss.killTime
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
        -- WotLK 3.3.5: 1=timestamp, 2=event, 3=sourceGUID, 4=sourceName, 5=sourceFlags, 6=destGUID, 7=destName, 8=destFlags
        local eventType = select(2, ...)
        local destGUID  = select(6, ...)
        local destFlags = select(8, ...)

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
            -- Моб убит — убираем из engaged (вызываем всегда: если GUID не в таблице, DisengageGuid ничего не сделает)
            DisengageGuid(destGUID)
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
        if state.bosses and bossName and state.running then
            for _, boss in ipairs(state.bosses) do
                if boss.name == bossName then
                    boss.killed   = true
                    -- GetTime() даёт актуальное значение прямо сейчас, а не из прошлого OnUpdate-кадра
                    boss.killTime = state.startTime and (GetTime() - state.startTime) or state.elapsed
                    UpdateBossRecord(boss.name, boss.killTime)
                    break
                end
            end
            UpdateBossDisplay()
        end
    end
end)
