-- MythicPlusTimer: DataCollector
-- Автоматически собирает данные из C_ChallengeMode во время ключей
-- и сохраняет в SavedVariables для последующего анализа.
-- После верификации API этот файл можно убрать из TOC.

local MPT = MythicPlusTimer

-- ============================================================
-- Вспомогательные функции (из KeystonesSirus, подтверждены)
-- ============================================================

-- Sirus Mythic+ difficulty ID = 3
local function IsInMythicDungeon()
    local inInstance, instanceType = IsInInstance()
    if not inInstance or instanceType ~= "party" then return false end
    local diffID = select(3, GetInstanceInfo())
    return diffID == 3
end

-- Читаем прогресс из UI StatusBar (0-100)
local function GetProgressBarValue()
    local bar = _G["ScenarioObjectiveTrackerPoolFrameScenarioProgressBarTemplate1_77Bar"]
    if bar and bar.GetValue then
        return bar:GetValue()
    end
    -- Резервный поиск по паттерну
    for k, v in pairs(_G) do
        if type(k) == "string"
            and string.find(k, "^ScenarioObjectiveTrackerPoolFrameScenarioProgressBarTemplate.*Bar$")
            and type(v) == "table" and v.GetObjectType
            and v:GetObjectType() == "StatusBar"
        then
            return v:GetValue()
        end
    end
    return nil
end

-- WotLK GUID → NPC ID (hex позиции 9-12)
local function GetNPCIdFromGUID(guid)
    if not guid then return nil end
    if string.sub(guid, 1, 3) ~= "0xF" then return nil end
    return tonumber(string.sub(guid, 9, 12), 16) or nil
end

-- Собрать снапшот всех доступных данных
local function TakeSnapshot(label)
    if not MPT or not MPT.db then return end
    if not MPT.db.snapshots then MPT.db.snapshots = {} end

    local snap = {
        event     = label,
        timestamp = time(),
        time_fmt  = date("%H:%M:%S"),
    }

    -- IsChallengeModeActive
    local ok, val = pcall(function() return C_ChallengeMode.IsChallengeModeActive() end)
    snap.IsActive = ok and val or ("ERR: " .. tostring(val))

    -- IsPaused
    ok, val = pcall(function() return C_ChallengeMode.IsPaused() end)
    snap.IsPaused = ok and val or ("ERR: " .. tostring(val))

    -- GetActiveChallengeMapID
    ok, val = pcall(function() return C_ChallengeMode.GetActiveChallengeMapID() end)
    snap.MapID = ok and val or ("ERR: " .. tostring(val))

    -- Sirus: difficulty ID + IsInMythicDungeon()
    snap.InMythic = IsInMythicDungeon()
    local _, _, diffID = GetInstanceInfo()
    snap.DifficultyID = diffID

    -- Sirus: прогресс через UI StatusBar
    snap.ProgressBar = GetProgressBarValue()

    -- GetActiveKeystoneInfo — сохраняем все возвращаемые значения
    ok, val = pcall(function()
        local a, b, c, d, e, f = C_ChallengeMode.GetActiveKeystoneInfo()
        return { a, b, c, d, e, f }
    end)
    if ok then
        snap.KeystoneInfo = {}
        for i, v in ipairs(val) do
            if type(v) == "table" then
                snap.KeystoneInfo["r" .. i] = "{table len=" .. #v .. "}"
                -- Если это массив аффиксов — разворачиваем
                local inner = {}
                for k2, v2 in ipairs(v) do
                    inner[k2] = v2
                end
                snap.KeystoneInfo["r" .. i .. "_arr"] = table.concat(inner, ",")
            else
                snap.KeystoneInfo["r" .. i] = tostring(v)
            end
        end
    else
        snap.KeystoneInfo = "ERR: " .. tostring(val)
    end

    -- GetEnemyForcesProgress — сохраняем все значения
    ok, val = pcall(function()
        local a, b, c, d = C_ChallengeMode.GetEnemyForcesProgress()
        return { a, b, c, d }
    end)
    if ok then
        snap.EnemyForces = {}
        for i, v in ipairs(val) do
            snap.EnemyForces["r" .. i] = tostring(v)
        end
    else
        snap.EnemyForces = "ERR: " .. tostring(val)
    end

    -- C_GlobalStorage: ASMSG_CHALLENGE_MODE_CREATURE_KILLED
    -- Sirus-специфичный API — содержит прогресс и, возможно, данные об убитом NPC
    ok, val = pcall(function()
        local data = C_GlobalStorage.GetVar("ASMSG_CHALLENGE_MODE_CREATURE_KILLED")
        return data
    end)
    if ok and val ~= nil then
        if type(val) == "table" then
            snap.CreatureKilled = {}
            for k, v in pairs(val) do
                if type(v) == "table" then
                    snap.CreatureKilled[tostring(k)] = "{table}"
                    for k2, v2 in pairs(v) do
                        snap.CreatureKilled[tostring(k) .. "." .. tostring(k2)] = tostring(v2)
                    end
                else
                    snap.CreatureKilled[tostring(k)] = tostring(v)
                end
            end
        else
            snap.CreatureKilled = tostring(val)
        end
    elseif not ok then
        snap.CreatureKilled = "ERR: " .. tostring(val)
    else
        snap.CreatureKilled = "nil"
    end

    -- GetDeathCount
    ok, val = pcall(function()
        local a, b = C_ChallengeMode.GetDeathCount()
        return { deaths = a, timeLost = b }
    end)
    snap.DeathCount = ok and val or ("ERR: " .. tostring(val))

    -- GetCompletionInfo — сохраняем все значения
    ok, val = pcall(function()
        local a, b, c, d, e, f, g, h = C_ChallengeMode.GetCompletionInfo()
        return { a, b, c, d, e, f, g, h }
    end)
    if ok then
        snap.CompletionInfo = {}
        for i, v in ipairs(val) do
            snap.CompletionInfo["r" .. i] = tostring(v)
        end
    else
        snap.CompletionInfo = "ERR: " .. tostring(val)
    end

    -- GetSlottedKeystoneInfo
    ok, val = pcall(function()
        local a, b, c = C_ChallengeMode.GetSlottedKeystoneInfo()
        return { mapID = a, affixes = b, level = c }
    end)
    snap.SlottedKeystone = ok and val or ("ERR: " .. tostring(val))

    -- GetMapTable — список mapID подземелий
    local mtOk, mtVal = pcall(function()
        return C_ChallengeMode.GetMapTable()
    end)
    if mtOk and type(mtVal) == "table" then
        snap.MapTable = {}
        for i, entry in ipairs(mtVal) do
            if type(entry) == "table" then
                local e = {}
                for k, v in pairs(entry) do
                    e[tostring(k)] = tostring(v)
                end
                snap.MapTable[i] = e
            else
                snap.MapTable[i] = tostring(entry)
            end
        end
    elseif mtOk then
        snap.MapTable = tostring(mtVal)
    else
        snap.MapTable = "ERR: " .. tostring(mtVal)
    end

    -- GetMapUIInfo для всех mapID — ищем лимит времени в возвращаемых значениях
    if C_ChallengeMode.GetMapUIInfo then
        local allIDs = {}
        -- Собираем все известные mapID из GetMapTable
        local mtOk2, mt2 = pcall(function() return C_ChallengeMode.GetMapTable() end)
        if mtOk2 and type(mt2) == "table" then
            for _, mid in ipairs(mt2) do allIDs[#allIDs+1] = mid end
        end
        -- Текущий mapID в начало (если есть и не дублируется)
        local midOk, midVal = pcall(function() return C_ChallengeMode.GetActiveChallengeMapID() end)
        if midOk and type(midVal) == "number" then
            local found = false
            for _, v in ipairs(allIDs) do if v == midVal then found = true; break end end
            if not found then table.insert(allIDs, 1, midVal) end
        end
        if #allIDs > 0 then
            snap.MapUIInfoAll = {}
            for _, mid in ipairs(allIDs) do
                local uiOk, a,b,c,d,e,f,g,h,ii,j,k = pcall(function()
                    return C_ChallengeMode.GetMapUIInfo(mid)
                end)
                snap.MapUIInfoAll[tostring(mid)] = uiOk
                    and { tostring(a),tostring(b),tostring(c),tostring(d),tostring(e),
                          tostring(f),tostring(g),tostring(h),tostring(ii),tostring(j),tostring(k) }
                    or ("ERR: " .. tostring(a))
            end
        end
    end

    -- Сканирование UI прогресс-бара ключа — ищем метки +2/+3 по позиции X
    do
        local barFrame
        for k, v in pairs(_G) do
            if type(k) == "string"
                and string.find(k, "^ScenarioObjectiveTrackerPoolFrameScenarioProgressBarTemplate.*Bar$")
                and type(v) == "table" and v.GetObjectType
                and v:GetObjectType() == "StatusBar"
            then
                barFrame = v; break
            end
        end
        if barFrame then
            local barW = barFrame:GetWidth()
            local barMin, barMax = barFrame:GetMinMaxValues()
            local children = {}
            local numR = barFrame:GetNumRegions()
            for i = 1, numR do
                local r = select(i, barFrame:GetRegions())
                if r then
                    local t = r:GetObjectType()
                    local x, y = r:GetCenter()
                    children[#children+1] = string.format("region%d: type=%s center=(%.1f,%.1f) w=%.1f h=%.1f",
                        i, tostring(t), x or 0, y or 0, r:GetWidth(), r:GetHeight())
                end
            end
            snap.ProgressBarScan = {
                barWidth = barW,
                barMin = barMin,
                barMax = barMax,
                regions = children,
            }
            -- Ищем дочерние фреймы
            local childFrames = {}
            if barFrame.GetNumChildren then
                for i = 1, barFrame:GetNumChildren() do
                    local ch = select(i, barFrame:GetChildren())
                    if ch then
                        local cht = ch:GetObjectType()
                        local chx, chy = ch:GetCenter()
                        childFrames[#childFrames+1] = string.format("child%d: type=%s name=%s center=(%.1f,%.1f)",
                            i, tostring(cht), tostring(ch:GetName()), chx or 0, chy or 0)
                    end
                end
            end
            snap.ProgressBarScan.children = childFrames
        end
    end

    -- Дебаг воскрешений: пробуем все методы C_ChallengeMode, похожие на res/brez/soul/charge
    if MPT.db.debug then
        snap.ResurrectionAPI = {}
        if type(C_ChallengeMode) == "table" then
            for key, val in pairs(C_ChallengeMode) do
                local k = tostring(key):lower()
                if k:find("resurrect") or k:find("res") or k:find("soul") or k:find("battle") or k:find("brez") or k:find("charge") or k:find("revive") or k:find("death") then
                    local ok, result = pcall(function()
                        if type(val) == "function" then
                            return val()
                        end
                        return val
                    end)
                    snap.ResurrectionAPI[tostring(key)] = ok and tostring(result) or ("ERR: " .. tostring(result))
                end
            end
        end
    end

    -- Сохраняем снапшот (держим только последние, чтобы не раздувать SavedVariables)
    table.insert(MPT.db.snapshots, snap)
    local MAX_SNAPSHOTS = 10
    while #MPT.db.snapshots > MAX_SNAPSHOTS do
        table.remove(MPT.db.snapshots, 1)
    end

    if MPT.db.debug then
        MPT:Print(string.format("Снапшот #%d сохранён: %s", #MPT.db.snapshots, label))

        -- GetActiveKeystoneInfo: ищем лимит времени (r3-r6 пока неизвестны)
        if type(snap.KeystoneInfo) == "table" then
            MPT:Print(string.format("  KeystoneInfo: level=%s affixes=[%s] r3=%s r4=%s r5=%s r6=%s",
                snap.KeystoneInfo["r1"] or "nil",
                snap.KeystoneInfo["r2_arr"] or "?",
                snap.KeystoneInfo["r3"] or "nil",
                snap.KeystoneInfo["r4"] or "nil",
                snap.KeystoneInfo["r5"] or "nil",
                snap.KeystoneInfo["r6"] or "nil"))
        end

        -- GetCompletionInfo: ищем лимит времени (нужен до/после финиша)
        if type(snap.CompletionInfo) == "table" then
            MPT:Print(string.format("  CompletionInfo: r1=%s r2=%s r3=%s r4=%s r5=%s r6=%s r7=%s r8=%s",
                snap.CompletionInfo["r1"] or "nil",
                snap.CompletionInfo["r2"] or "nil",
                snap.CompletionInfo["r3"] or "nil",
                snap.CompletionInfo["r4"] or "nil",
                snap.CompletionInfo["r5"] or "nil",
                snap.CompletionInfo["r6"] or "nil",
                snap.CompletionInfo["r7"] or "nil",
                snap.CompletionInfo["r8"] or "nil"))
        end
        if type(snap.ResurrectionAPI) == "table" and next(snap.ResurrectionAPI) then
            MPT:Print("  ResurrectionAPI (C_ChallengeMode):")
            for k, v in pairs(snap.ResurrectionAPI) do
                MPT:Print(string.format("    %s = %s", k, v))
            end
        end
    end
end

-- Сканирует фреймы и C_ChallengeMode для поиска источника данных о воскрешениях (сердечко/цифра).
-- Вызов: /mpt resdebug или MPT:DumpResurrectionSources()
local function ScanFrameForText(frame, depth, results, seen)
    if not frame or type(frame) ~= "table" or seen[frame] or depth > 8 then return end
    seen[frame] = true
    local name = frame.GetName and frame:GetName() or ""
    local objType = frame.GetObjectType and pcall(function() return frame:GetObjectType() end) and frame:GetObjectType() or "?"
    if objType == "FontString" and frame.GetText then
        local ok, text = pcall(function() return frame:GetText() end)
        if ok and text and text ~= "" then
            results[#results + 1] = { name = name or "(noname)", text = text, depth = depth }
        end
    end
    if frame.GetNumChildren then
        for i = 1, frame:GetNumChildren() do
            local ch = select(i, frame:GetChildren())
            if ch then ScanFrameForText(ch, depth + 1, results, seen) end
        end
    end
    local numRegions = frame.GetNumRegions and frame:GetNumRegions()
    if numRegions then
        for i = 1, numRegions do
            local r = select(i, frame:GetRegions())
            if r and r.GetObjectType and r:GetObjectType() == "FontString" and r.GetText then
                local ok, text = pcall(function() return r:GetText() end)
                if ok and text and text ~= "" then
                    results[#results + 1] = { name = name or "(regions of " .. tostring(frame) .. ")", text = text, depth = depth }
                end
            end
        end
    end
end

function MPT:DumpResurrectionSources()
    if not self.Print then return end
    self:Print("=== Дебаг воскрешений (сердечко/цифра) ===")

    -- 1) Все ключи C_ChallengeMode (чтобы увидеть возможные Get*Resurrection* и т.п.)
    self:Print("--- C_ChallengeMode (все ключи) ---")
    if type(C_ChallengeMode) ~= "table" then
        self:Print("  C_ChallengeMode не таблица: " .. tostring(C_ChallengeMode))
    else
        local keys = {}
        for k in pairs(C_ChallengeMode) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local val = C_ChallengeMode[k]
            local typ = type(val)
            if typ == "function" then
                local ok, res = pcall(val)
                self:Print(string.format("  %s = function -> %s", k, ok and tostring(res) or ("ERR: " .. tostring(res))))
            else
                self:Print(string.format("  %s = %s (%s)", k, tostring(val), typ))
            end
        end
    end

    -- 2) Сканирование фреймов Scenario/Objective/Challenge — ищем текст (цифры рядом с сердечком/надгробием)
    self:Print("--- Фреймы Scenario/Objective/Tracker (FontString текст) ---")
    local results = {}
    local seen = {}
    for globalName, v in pairs(_G) do
        if type(globalName) == "string" and (globalName:find("Scenario") or globalName:find("Objective") or globalName:find("Challenge") or globalName:find("Tracker")) then
            if type(v) == "table" and v.GetObjectType then
                local ok = pcall(function() ScanFrameForText(v, 0, results, seen) end)
                if not ok then
                    self:Print(string.format("  [%s] scan err", globalName))
                end
            end
        end
    end
    for _, r in ipairs(results) do
        self:Print(string.format("  [%s] depth=%d text=%s", r.name, r.depth, r.text))
    end
    if #results == 0 then
        self:Print("  Нет найденного текста. Открой стандартный UI ключа (трекер целей) и снова введи /mpt resdebug")
    end
    self:Print("=== Конец дебага воскрешений ===")
end

-- Буфер недавних убийств для тестирования GUID парсинга (первые 30 убийств)
local recentKillsDebug = {}
local MAX_KILL_DEBUG = 30
-- Последнее значение полоски прогресса (для дельты при обучении по убийствам).
-- Должно обновляться часто (0.15 с), иначе дельта при убийстве будет включать несколько мобов.
local lastForcesBar = 0
-- Очередь NPC для отложенного обучения: полоска прогресса обновляется после убийства с задержкой,
-- поэтому учим не в момент UNIT_DIED, а когда в тикере увидим изменение бара.
local pendingLearnQueue = {}
local MAX_PENDING_LEARN = 30

-- Периодический сбор данных во время ключа (каждые 30 сек) + частое обновление lastForcesBar (0.15 с)
local ticker = CreateFrame("Frame")
local tickInterval = 30
local lastTick = 0
local forcesUpdateThrottle = 0
local FORCES_UPDATE_INTERVAL = 0.15
ticker:SetScript("OnUpdate", function(self, elapsed)
    if not MPT or not MPT.db then return end
    lastTick = lastTick + elapsed
    forcesUpdateThrottle = forcesUpdateThrottle + elapsed
    local inKey = C_ChallengeMode.IsChallengeModeActive() or IsInMythicDungeon()
    -- Частое обновление lastForcesBar + отложенное обучение: полоска обновляется после убийства с задержкой,
    -- поэтому при изменении бара списываем дельту на первого NPC из очереди убийств.
    if inKey and forcesUpdateThrottle >= FORCES_UPDATE_INTERVAL then
        forcesUpdateThrottle = 0
        local bar = GetProgressBarValue()
        if bar and type(bar) == "number" then
            if #pendingLearnQueue > 0 and (bar - lastForcesBar) >= 0 and (bar - lastForcesBar) <= 5 then
                local delta = bar - lastForcesBar
                local npcID = table.remove(pendingLearnQueue, 1)
                if npcID and MPT and MPT.LearnNpcForces then
                    local pct = (delta < 0.01) and 0 or delta
                    local knownPct = MPT:GetNpcForces(npcID)
                    if knownPct == nil then
                        MPT:LearnNpcForces(npcID, pct)
                    elseif math.abs(pct - knownPct) > 0.1 then
                        MPT:LearnNpcForces(npcID, pct, true)
                    end
                end
            end
            lastForcesBar = bar
        end
    end
    if lastTick >= tickInterval then
        lastTick = 0
        if inKey then
            lastForcesBar = GetProgressBarValue() or lastForcesBar
            TakeSnapshot("TICK_" .. tickInterval .. "s")
        end
    end
end)

-- Слушаем события Challenge Mode
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("CHALLENGE_MODE_START")
eventFrame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
eventFrame:RegisterEvent("CHALLENGE_MODE_DEATH_COUNT_UPDATED")
eventFrame:RegisterEvent("CHALLENGE_MODE_CRITERIA_UPDATE")
eventFrame:RegisterEvent("BOSS_KILL")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

-- Также регистрируем всё с "CHALLENGE" в названии — ловим неизвестные события Sirus
eventFrame:RegisterAllEvents()

local knownChallengeEvents = {
    CHALLENGE_MODE_START               = true,
    CHALLENGE_MODE_COMPLETED           = true,
    CHALLENGE_MODE_DEATH_COUNT_UPDATED = true,
    CHALLENGE_MODE_CRITERIA_UPDATE     = true,
}

eventFrame:SetScript("OnEvent", function(self, event, ...)
    -- Ловим все неизвестные CHALLENGE_* события
    if event:find("CHALLENGE") and not knownChallengeEvents[event] then
        if MPT and MPT.db and MPT.db.debug then
            MPT:Print("Неизвестное событие: " .. event .. " args: " .. tostring(...))
        end
        if not MPT.db.unknownEvents then MPT.db.unknownEvents = {} end
        table.insert(MPT.db.unknownEvents, { event = event, args = { ... }, t = time() })
        while #MPT.db.unknownEvents > 20 do table.remove(MPT.db.unknownEvents, 1) end
        return
    end

    if event == "CHALLENGE_MODE_START" then
        lastForcesBar = GetProgressBarValue() or 0
        pendingLearnQueue = {}
        TakeSnapshot("CHALLENGE_MODE_START")

    elseif event == "CHALLENGE_MODE_COMPLETED" then
        TakeSnapshot("CHALLENGE_MODE_COMPLETED")
        -- При завершении ключа логируем GetCompletionInfo подробно — там должен быть лимит времени
        if MPT and MPT.db then
            if not MPT.db.completionDumps then MPT.db.completionDumps = {} end
            local dump = { t = time() }
            local getCI = C_ChallengeMode.GetCompletionInfo ---@diagnostic disable-line: deprecated
            local ok, a,b,c,d,e,f,g,h = pcall(getCI)
            if ok then
                dump.CompletionInfo = { tostring(a),tostring(b),tostring(c),tostring(d),tostring(e),tostring(f),tostring(g),tostring(h) }
            else
                dump.CompletionInfo = "ERR: " .. tostring(a)
            end
            -- GetMapUIInfo для всех mapID — там может быть timeLimit
            if C_ChallengeMode.GetMapUIInfo and C_ChallengeMode.GetMapTable then
                local mtOk, mt = pcall(function() return C_ChallengeMode.GetMapTable() end)
                if mtOk and type(mt) == "table" then
                    dump.MapUIInfoAll = {}
                    for _, mid in ipairs(mt) do
                        local uiOk, r1,r2,r3,r4,r5,r6,r7,r8,r9,r10,r11 = pcall(function()
                            return C_ChallengeMode.GetMapUIInfo(mid)
                        end)
                        if uiOk then
                            dump.MapUIInfoAll[tostring(mid)] = {
                                tostring(r1),tostring(r2),tostring(r3),tostring(r4),
                                tostring(r5),tostring(r6),tostring(r7),tostring(r8),
                                tostring(r9),tostring(r10),tostring(r11),
                            }
                        end
                    end
                end
            end
            table.insert(MPT.db.completionDumps, dump)
            while #MPT.db.completionDumps > 5 do table.remove(MPT.db.completionDumps, 1) end
            if MPT.db.debug then
                MPT:Print("CHALLENGE_MODE_COMPLETED: данные сохранены в MythicPlusTimerDB.completionDumps")
            end
        end

    elseif event == "CHALLENGE_MODE_DEATH_COUNT_UPDATED" then
        TakeSnapshot("DEATH_COUNT_UPDATED")

    elseif event == "CHALLENGE_MODE_CRITERIA_UPDATE" then
        -- Срабатывает при каждом убийстве моба (прогресс изменился)
        -- Захватываем CreatureKilled сразу — данные могут обновиться до следующего тика
        if MPT and MPT.db then
            if not MPT.db.criteriaSnapshots then MPT.db.criteriaSnapshots = {} end
            while #MPT.db.criteriaSnapshots >= 50 do table.remove(MPT.db.criteriaSnapshots, 1) end
            if #MPT.db.criteriaSnapshots < 50 then  -- первые 50 убийств в сессии
                local entry = {
                    t = time(),
                    args = { tostring(select(1,...)), tostring(select(2,...)), tostring(select(3,...)) },
                }
                -- C_GlobalStorage сразу после события
                local ok, data = pcall(function()
                    return C_GlobalStorage.GetVar("ASMSG_CHALLENGE_MODE_CREATURE_KILLED")
                end)
                if ok and type(data) == "table" then
                    entry.creatureKilled = {}
                    for k, v in pairs(data) do
                        entry.creatureKilled[tostring(k)] = tostring(v)
                    end
                elseif ok then
                    entry.creatureKilled = tostring(data)
                else
                    entry.creatureKilled = "ERR: " .. tostring(data)
                end
                -- Текущий прогресс
                local ok2, p1, p2 = pcall(function()
                    return C_ChallengeMode.GetEnemyForcesProgress()
                end)
                entry.forces = ok2 and { p1, p2 } or "ERR"
                table.insert(MPT.db.criteriaSnapshots, entry)
                if MPT.db.debug then
                    MPT:Print(string.format("Убийство #%d: total=%s forces={%s,%s}",
                        #MPT.db.criteriaSnapshots,
                        entry.creatureKilled and entry.creatureKilled["total"] or "?",
                        tostring(p1), tostring(p2)))
                end
            end
        end

    elseif event == "BOSS_KILL" then
        local bossIndex, bossName = ...
        TakeSnapshot("BOSS_KILL_" .. tostring(bossName or bossIndex))

    elseif event == "PLAYER_ENTERING_WORLD" then
        recentKillsDebug = {}
        lastForcesBar = 0
        pendingLearnQueue = {}
        if C_ChallengeMode.IsChallengeModeActive() or IsInMythicDungeon() then
            TakeSnapshot("RECONNECT_IN_KEY")
        end

    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        if not IsInMythicDungeon() then return end
        local eventType = select(2, ...)
        if eventType ~= "UNIT_DIED" and eventType ~= "PARTY_KILL" then return end
        -- WotLK 3.3.5: 6=destGUID, 7=destName, 8=destFlags
        local destGUID  = select(6, ...)
        local destName  = select(7, ...)
        local destFlags = select(8, ...)
        if not destFlags then return end

        local HOSTILE  = 0x00000040
        local NEUTRAL  = 0x00000020  -- жёлтые мобы
        local IS_NPC   = 0x00000800
        local IS_PET   = 0x00001000
        local IS_GUARD = 0x00002000
        local CTRL_PLR = 0x00000100
        if not (
            (bit.band(destFlags, HOSTILE) ~= 0 or bit.band(destFlags, NEUTRAL) ~= 0) and
            bit.band(destFlags, IS_NPC)   ~= 0 and
            bit.band(destFlags, IS_PET)   == 0 and
            bit.band(destFlags, IS_GUARD) == 0 and
            bit.band(destFlags, CTRL_PLR) == 0
        ) then return end

        local npcID = GetNPCIdFromGUID(destGUID)
        if not npcID or npcID == 0 then return end

        -- Обучение отложенное: полоска прогресса в UI обновляется после убийства с задержкой (сервер),
        -- поэтому в момент UNIT_DIED бар ещё старый и дельта = 0. Кладём npcID в очередь; в тикере
        -- при следующем изменении бара спишем дельту на первого в очереди.
        if #pendingLearnQueue < MAX_PENDING_LEARN then
            table.insert(pendingLearnQueue, npcID)
        end

        if #recentKillsDebug < MAX_KILL_DEBUG and MPT and MPT.db then
            if not MPT.db.killLog then MPT.db.killLog = {} end
            local entry = {
                t      = GetTime(),
                guid   = destGUID,
                name   = destName,
                npcID  = npcID,
                bar    = GetProgressBarValue(),
                flags  = destFlags,
            }
            table.insert(recentKillsDebug, entry)
            table.insert(MPT.db.killLog, entry)
            while #MPT.db.killLog > 100 do table.remove(MPT.db.killLog, 1) end
            if MPT.db.debug then
                MPT:Print(string.format("KILL: %s npcID=%d bar=%.2f%%",
                    tostring(destName), npcID, entry.bar or 0))
            end
        end
    end
end)
