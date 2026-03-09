-- MythicPlusTimer: Tooltip
-- Показывает % прогресса сил врагов при наведении на NPC

local MPT = MythicPlusTimer

-- WotLK GUID → NPC ID
-- Формат: "0xF1SSSSNNNNIIIIEE", позиции 9-12 = NPC entry ID (4 hex символа)
local function GetNPCIdFromGUID(guid)
    if not guid then return nil end
    if string.sub(guid, 1, 3) ~= "0xF" then return nil end
    return tonumber(string.sub(guid, 9, 12), 16) or nil
end

-- Добавляет строку с % в тултип. Возвращает true если строка добавлена.
local function AddForcesLine(tooltip, unit)
    if not unit then return end
    if UnitIsPlayer(unit) then return end

    local guid = UnitGUID(unit)
    if not guid then return end

    local npcID = GetNPCIdFromGUID(guid)
    if not npcID then return end

    local pct, isApprox, isUncertain = MPT:GetNpcForces(npcID)

    local line
    if pct == nil then
        -- Неизвестный NPC — показываем только в M+ подземелье
        local inKey = C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive
                   and C_ChallengeMode.IsChallengeModeActive()
        local diffID = select(3, GetInstanceInfo())
        if not inKey and diffID ~= 3 then return end
        line = "|cff888888[M+] неизвестно|r"
    elseif pct == 0 then
        line = "|cff888888[M+] 0%|r"
    else
        local mark = ""
        if isApprox    then mark = mark .. " |cffff8800(~)|r" end
        if isUncertain then mark = mark .. " |cffff0000(?)|r" end
        line = string.format("|cff00ccff[M+]|r |cffffd700%.2f%%%s|r", pct, mark)
    end

    -- TipTac заполняет строки через SetFormattedText (не через AddLine), поэтому
    -- NumLines() не отражает реальное количество занятых строк. Сканируем
    -- FontString-ы за пределами NumLines и «регистрируем» их через AddLine с тем же
    -- содержимым и цветом — без визуальных изменений, только счётчик догоняет факт.
    -- После этого наш AddLine встаёт в первую по-настоящему свободную позицию.
    local n = tooltip:NumLines()
    for i = n + 1, n + 10 do
        local fs = _G["GameTooltipTextLeft" .. i]
        if not fs then break end
        local t = fs:GetText()
        if not t or t == "" then break end
        if t:find("[M+]", 1, true) then break end  -- наша строка уже там
        local r, g, b = fs:GetTextColor()
        tooltip:AddLine(t, r, g, b)
    end

    tooltip:AddLine(line)
    return true
end

-- Получить unit из тултипа.
-- Sirus WotLK: GetUnit() возвращает (name, unitToken) — берём b или a.
local function ResolveUnit(self)
    local a, b = self:GetUnit()
    local unit = b or a

    if not unit then
        local mFocus = GetMouseFocus()
        if mFocus and mFocus.unit then
            unit = mFocus.unit
        end
    end

    if not unit and UnitExists("mouseover") then
        unit = "mouseover"
    end

    return unit
end

-- Проверить: есть ли уже наша строка в тултипе.
-- Все варианты строки содержат буквальный текст "[M+]".
local function HasOurLine(tooltip)
    for i = 1, tooltip:NumLines() do
        local fs = _G["GameTooltipTextLeft" .. i]
        if fs then
            local t = fs:GetText()
            if t and t:find("[M+]", 1, true) then
                return true
            end
        end
    end
    return false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Регистрируем хуки в PLAYER_LOGIN — ПОСЛЕ всех аддонов (TipTac регистрирует
-- в VARIABLES_LOADED, наш хук стреляет строго после TipTac).
--
-- Почему только OnTooltipSetUnit, без OnShow:
--   TipTac в OnTooltipSetUnit пишет "+80 Гуманоид" в позицию 3 (lineIndex=3,
--   т.к. hasGuildTitle=true для NPC с подзаголовком). OnShow стреляет ДО этого
--   и добавляет нашу строку в позицию 3, которую TipTac тут же перезаписывает.
--   OnTooltipSetUnit (наш) стреляет ПОСЛЕ TipTac — TipTac уже занял позиции 1-3,
--   наш AddLine добавляет позицию 4, которую TipTac не трогает никогда.
--
-- HasOurLine() вместо булевого флага: при периодическом обновлении тултипа
-- на Sirus OnTooltipCleared не стреляет, булев флаг застревает в true.
-- HasOurLine() проверяет актуальное содержимое тултипа каждый раз.
--
-- self:Show() после AddLine обновляет TipTac::gtt_newHeight (через TipTac's
-- gtt.Show override), гарантируя что наша строка включена в финальный размер
-- и не срезается GTTHook_OnUpdate.
-- ─────────────────────────────────────────────────────────────────────────────
local tooltipInitFrame = CreateFrame("Frame")
tooltipInitFrame:RegisterEvent("PLAYER_LOGIN")
tooltipInitFrame:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")

    GameTooltip:HookScript("OnTooltipSetUnit", function(self)
        if HasOurLine(self) then return end
        local unit = ResolveUnit(self)
        if not unit then return end
        if AddForcesLine(self, unit) then
            self:Show()
        end
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Диагностическая команда /mpttest
-- ─────────────────────────────────────────────────────────────────────────────
local function p(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[MPT]|r " .. tostring(msg))
end

SLASH_MPTTEST1 = "/mpttest"
SlashCmdList["MPTTEST"] = function()
    p("=== Диагностика тултипа ===")
    local moExists = UnitExists("mouseover")
    p("UnitExists('mouseover') = " .. tostring(moExists))
    if moExists then
        local moGUID = UnitGUID("mouseover")
        p("UnitGUID('mouseover') = " .. tostring(moGUID))
        if moGUID then
            local npcID = GetNPCIdFromGUID(moGUID)
            p("npcID = " .. tostring(npcID))
            if npcID then
                local pct, isApprox, isUncertain = MPT:GetNpcForces(npcID)
                p("GetNpcForces(" .. npcID .. ") = pct=" .. tostring(pct)
                  .. " approx=" .. tostring(isApprox)
                  .. " uncertain=" .. tostring(isUncertain))
            end
        end
    end
    local a, b = GameTooltip:GetUnit()
    p("GameTooltip:GetUnit() a='" .. tostring(a) .. "' b='" .. tostring(b) .. "'")
    p("GameTooltip:IsVisible() = " .. tostring(GameTooltip:IsVisible()))
    p("GameTooltip:NumLines() = " .. tostring(GameTooltip:NumLines()))
    p("HasOurLine = " .. tostring(HasOurLine(GameTooltip)))
    local inKey = C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive
               and C_ChallengeMode.IsChallengeModeActive()
    local _, instanceType, diffID = GetInstanceInfo()
    p("IsChallengeModeActive = " .. tostring(inKey))
    p("instanceType='" .. tostring(instanceType) .. "' diffID=" .. tostring(diffID))
    p("=== Конец диагностики ===")
end
