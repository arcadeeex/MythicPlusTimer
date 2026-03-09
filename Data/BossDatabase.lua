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
