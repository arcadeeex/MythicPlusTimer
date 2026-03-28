-- MythicPlusTimer: BossDatabase
-- Статическая база данных боссов по данжам.
-- Ключ: имя инстанса (GetInstanceInfo() — русский клиент Sirus).
-- Значение: список имён боссов в порядке встречи.
--
-- Имена данжей подтверждены из GetMapUIInfo() (снапшоты 2025-03):
--   mapID 4  → "Крепость Утгард"
--   mapID 5  → "Бастионы Адского Пламени"
--   mapID 6  → "Узилище"
--   mapID 8  → "Крепость Драк'Тарон"
--   mapID 9  → "Чертоги Молний"
--   mapID 10 → "Кузня Крови"
--   mapID 11 → "Гробницы Маны"
--   mapID 12 → "Ан'кахет: Старое Королевство"
--
-- Имена боссов: как приходят в ASMSG_INSTANCE_ENCOUNTERS_STATE (русский).
-- Частично подтверждены из bossRecords SavedVariables.

local MPT = MythicPlusTimer

-- Поиск по mapID (приоритет) — надёжнее чем имя инстанса (может быть на английском)
local bossByMapID = {
    [4]  = { "Принц Келесет", "Скарвальд и Далронн", "Ингвар Расхититель" },
    [5]  = { "Начальник стражи Гарголмар", "Омор Неодолимый", "Вазруден Глашатай" },
    [6]  = { "Менну Предатель", "Рокмар Трескун", "Зыбун" },
    [8]  = { "Кровотролль", "Новос Призыватель", "Король Дред", "Пророк Тарон'джа" },
    [9]  = { "Генерал Бьярнгрим", "Волхан", "Ионар", "Локен" },
    [10] = { "Мастер", "Броггок", "Кели'дан Разрушитель" },
    [11] = { "Пандемоний", "Таварок", "Принц Шаффар" },
    [12] = { "Старейшина Надокс", "Принц Талдарам", "Джедога Искательница Теней", "Аманитар", "Глашатай Волаж" },
}

-- Fallback по имени инстанса (русский клиент Sirus)
local bossByDungeon = {
    ["Крепость Утгард"]              = bossByMapID[4],
    ["Бастионы Адского Пламени"]     = bossByMapID[5],
    ["Узилище"]                      = bossByMapID[6],
    ["Крепость Драк'Тарон"]          = bossByMapID[8],
    ["Чертоги Молний"]               = bossByMapID[9],
    ["Кузня Крови"]                  = bossByMapID[10],
    ["Гробницы Маны"]                = bossByMapID[11],
    ["Ан'кахет: Старое Королевство"] = bossByMapID[12],
}

-- Получить список боссов по mapID (приоритет) или имени инстанса (fallback).
-- mapID берётся из C_ChallengeMode.GetActiveChallengeMapID().
-- dungeonName берётся из GetInstanceInfo() — может быть на английском.
function MPT:GetDungeonBosses(dungeonName, mapID)
    if mapID and bossByMapID[mapID] then
        return bossByMapID[mapID]
    end
    if dungeonName and bossByDungeon[dungeonName] then
        return bossByDungeon[dungeonName]
    end
    return nil
end

-- EncounterID (WotLK 3.3.x / Sirus) → каноническое имя из списка боссов данжа.
-- Если на ядре другой ID — сработает сопоставление по имени (ResolveEncounterToBossName).
-- Только проверенные ID (остальные данжи — по имени, чтобы не записать бой на чужого босса).
local bossEncounterIdByMapID = {
    [4] = {
        [1603] = "Принц Келесет",
        [1604] = "Скарвальд и Далронн",
        [1605] = "Ингвар Расхититель",
    },
    [5] = {
        -- Бастионы Адского Пламени: финальный босс может идти как "Назан" / "Вазруден Глашатай"
        [1593] = "Начальник стражи Гарголмар",
        [1594] = "Омор Неодолимый",
        [1609] = "Вазруден Глашатай", -- Nazan (start)
        [1595] = "Вазруден Глашатай", -- Vazruden the Herald (end)
    },
    [6] = {
        [1606] = "Менну Предатель",
        [1607] = "Рокмар Трескун",
        [1608] = "Зыбун",
    },
    [8] = {
        [1610] = "Кровотролль",
        [1611] = "Новос Призыватель",
        [1612] = "Король Дред",
        [1613] = "Пророк Тарон'джа",
    },
    [9] = {
        [1617] = "Генерал Бьярнгрим",
        [1618] = "Волхан",
        [1619] = "Ионар",
        [1620] = "Локен",
    },
    [10] = {
        [1596] = "Мастер",
        [1597] = "Броггок",
        [1598] = "Кели'дан Разрушитель",
    },
    [11] = {
        [1621] = "Пандемоний",
        [1622] = "Таварок",
        [1623] = "Принц Шаффар",
    },
    [12] = {
        [1624] = "Старейшина Надокс",
        [1625] = "Принц Талдарам",
        [1626] = "Джедога Искательница Теней",
        [1627] = "Аманитар",
        [1628] = "Глашатай Волаж",
    },
}

local function normEncounterKey(s)
    if type(s) ~= "string" then return "" end
    s = s:lower()
    s = s:gsub("ё", "е")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("%s+", " ")
    return s
end

--- Сопоставить ENCOUNTER_* с именем босса из статической базы (для записи fightTime).
--- @return string|nil каноническое имя как в ASMSG / state.bosses
function MPT:ResolveEncounterToBossName(mapID, encounterID, encounterName)
    local list = self:GetDungeonBosses(nil, mapID)
    if not list or #list == 0 then return nil end

    if encounterID and bossEncounterIdByMapID[mapID] then
        local byId = bossEncounterIdByMapID[mapID][encounterID]
        if byId then
            for _, bn in ipairs(list) do
                if bn == byId then return bn end
            end
        end
    end

    local nEnc = normEncounterKey(encounterName)
    if nEnc ~= "" then
        -- Частный случай Бастиона: этап дракона "Назан" = тот же финальный босс.
        if mapID == 5 and nEnc == "назан" then
            for _, bn in ipairs(list) do
                if bn == "Вазруден Глашатай" then
                    return bn
                end
            end
        end
        for _, bn in ipairs(list) do
            if normEncounterKey(bn) == nEnc then return bn end
        end
        for _, bn in ipairs(list) do
            local nb = normEncounterKey(bn)
            if nb ~= "" and nEnc ~= "" and (nb:find(nEnc, 1, true) or nEnc:find(nb, 1, true)) then
                return bn
            end
        end
        local fe = nEnc:match("^(%S+)")
        if fe and #fe >= 3 then
            for _, bn in ipairs(list) do
                local nb = normEncounterKey(bn)
                local fb = nb:match("^(%S+)")
                if fb and (fe == fb or nb:find(fe, 1, true) or nEnc:find(fb, 1, true)) then
                    return bn
                end
            end
        end
    end
    return nil
end
