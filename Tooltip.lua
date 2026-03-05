-- MythicPlusTimer: Tooltip
-- Показывает % прогресса сил врагов при наведении на NPC

local MPT = MythicPlusTimer

-- WotLK GUID → NPC ID
local function GetNPCIdFromGUID(guid)
    if not guid then return nil end
    if string.sub(guid, 1, 3) ~= "0xF" then return nil end
    return tonumber(string.sub(guid, 9, 12), 16) or nil
end

-- Флаг: уже добавили строку для текущего тултипа.
-- Сбрасывается через OnTooltipCleared (надёжнее чем сканировать текст).
local addedToCurrentTooltip = false

local function AddForcesLine(tooltip, unit)
    if not unit then return end
    if UnitIsPlayer(unit) then return end

    local guid = UnitGUID(unit)
    if not guid then return end

    local npcID = GetNPCIdFromGUID(guid)
    if not npcID then return end

    -- Защита от двойного добавления (оба хука OnShow+OnTooltipSetUnit могут сработать)
    if addedToCurrentTooltip then return end

    local pct, isApprox, isUncertain = MPT:GetNpcForces(npcID)

    local line
    if pct == nil then
        -- Неизвестный NPC — показываем только в активном M+
        local diffID = select(3, GetInstanceInfo())
        if diffID ~= 3 then return end
        line = "|cff888888[M+] неизвестно|r"
    elseif pct == 0 then
        line = "|cff888888[M+] 0%|r"
    else
        local mark = ""
        if isApprox    then mark = mark .. " |cffff8800(~)|r" end
        if isUncertain then mark = mark .. " |cffff0000(?)|r" end
        line = string.format("|cff00ccff[M+]|r |cffffd700%.2f%%%s|r", pct, mark)
    end

    addedToCurrentTooltip = true
    tooltip:AddLine(line)
    -- НЕ вызываем tooltip:Show() — это приводит к рекурсии через OnShow хук
end

-- Основной хук
GameTooltip:HookScript("OnTooltipSetUnit", function(self)
    local _, unit = self:GetUnit()
    if unit then AddForcesLine(self, unit) end
end)

-- Резервный хук: на Sirus OnTooltipSetUnit может не стрелять для враждебных NPC
GameTooltip:HookScript("OnShow", function(self)
    local _, unit = self:GetUnit()
    if unit then AddForcesLine(self, unit) end
end)

-- Сброс флага при очистке тултипа (смена цели или закрытие)
GameTooltip:HookScript("OnTooltipCleared", function()
    addedToCurrentTooltip = false
end)
