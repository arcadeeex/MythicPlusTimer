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

    -- Сохраняем снапшот
    table.insert(MPT.db.snapshots, snap)

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
    end
end

-- Буфер недавних убийств для тестирования GUID парсинга (первые 30 убийств)
local recentKillsDebug = {}
local MAX_KILL_DEBUG = 30
-- Последнее значение полоски прогресса (для дельты при обучении по убийствам)
local lastForcesBar = 0

-- Периодический сбор данных во время ключа (каждые 30 сек)
local ticker = CreateFrame("Frame")
local tickInterval = 30
local lastTick = 0
ticker:SetScript("OnUpdate", function(self, elapsed)
    if not MPT or not MPT.db then return end
    lastTick = lastTick + elapsed
    if lastTick >= tickInterval then
        lastTick = 0
        -- Используем оба способа детекции ключа
        if C_ChallengeMode.IsChallengeModeActive() or IsInMythicDungeon() then
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
        return
    end

    if event == "CHALLENGE_MODE_START" then
        lastForcesBar = GetProgressBarValue() or 0
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
            if #MPT.db.criteriaSnapshots < 50 then  -- первые 50 убийств
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
        if C_ChallengeMode.IsChallengeModeActive() or IsInMythicDungeon() then
            TakeSnapshot("RECONNECT_IN_KEY")
        end

    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        if not IsInMythicDungeon() then return end
        local _, eventType, a3, _, _, a6, a7, a8, a9 = ...
        if eventType ~= "UNIT_DIED" and eventType ~= "PARTY_KILL" then return end
        -- Авто-определение формата:
        --   WotLK 3.3.5: timestamp, subevent, srcGUID, srcName, srcFlags, destGUID, destName, destFlags
        --   Cata+:        timestamp, subevent, hideCaster(bool), srcGUID, srcName, srcFlags, destGUID, destName, destFlags
        local destGUID, destName, destFlags
        if type(a3) == "boolean" then
            destGUID, destName, destFlags = a7, a8, a9  -- Cata+
        else
            destGUID, destName, destFlags = a6, a7, a8  -- WotLK
        end
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

        -- Обучение базы: записываем дельту прогресса при каждом убийстве.
        -- lastForcesBar обновляем всегда, иначе дельта накапливает вклад пропущенных мобов.
        local currentBar = GetProgressBarValue()
        if currentBar and type(currentBar) == "number" then
            local delta = currentBar - lastForcesBar
            if delta > 0 and delta <= 5 and MPT and MPT.GetNpcForces then
                local knownPct = MPT:GetNpcForces(npcID)
                if knownPct == nil then
                    -- Неизвестный NPC — просто учим
                    MPT:LearnNpcForces(npcID, delta)
                elseif math.abs(delta - knownPct) > 0.1 then
                    -- Известный NPC, но значение изменилось на сервере — перезаписываем
                    MPT:LearnNpcForces(npcID, delta, true)
                end
            end
            lastForcesBar = currentBar
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
            if MPT.db.debug then
                MPT:Print(string.format("KILL: %s npcID=%d bar=%.2f%%",
                    tostring(destName), npcID, entry.bar or 0))
            end
        end
    end
end)
