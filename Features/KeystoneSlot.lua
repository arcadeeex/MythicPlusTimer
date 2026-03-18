-- MythicPlusTimer: KeystoneSlot
-- Автоматически вставляет ключ в чашу при её открытии.
-- Ключ определяется по itemID 374584.
-- Триггер: события открытия чаши ключа (ASMSG_* / CHALLENGE_MODE_*).

local MPT = MythicPlusTimer

local KEYSTONE_ITEM_ID = 374584
local pendingSlotTime = nil

local function NormalizeText(s)
    if type(s) ~= "string" then return "" end
    s = s:lower()
    s = s:gsub("ё", "е")
    s = s:gsub("%s+", " ")
    s = s:gsub("^%s+", "")
    s = s:gsub("%s+$", "")
    return s
end

local function ExtractKeystoneDungeonName(itemName)
    if type(itemName) ~= "string" or itemName == "" then return nil end
    local name = itemName
    -- Common prefixes:
    -- "Эпохальный ключ - Чертоги Молний"
    -- "Эпохальный ключ: Чертоги Молний"
    -- "Эпохальный ключ — Чертоги Молний"
    name = name:gsub("^Эпохальный ключ%s*[%-%—:]%s*", "")
    -- Generic fallback: cut by first separator if prefix is localized differently.
    if name == itemName then
        local generic = itemName:match("^.-%s*[%-%—:]%s*(.+)$")
        if generic and generic ~= "" then
            name = generic
        end
    end
    -- Strip optional suffixes like "(+10)" or "(10)".
    name = name:gsub("%s*%b()%s*$", "")
    -- Strip trailing "+10"/"10" style level hints if present.
    name = name:gsub("%s*%+%d+%s*$", "")
    name = name:gsub("%s+%d+%s*$", "")
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name ~= "" then return name end
    return nil
end

local function GetCurrentDungeonName()
    local instanceName = GetInstanceInfo()
    if type(instanceName) == "string" and instanceName ~= "" then
        return instanceName
    end
    -- Fallback when instance API is temporarily empty right after zoning.
    if GetRealZoneText then
        local z = GetRealZoneText()
        if type(z) == "string" and z ~= "" then return z end
    end
    return nil
end

local function IsKeystoneForCurrentLocation(itemLink)
    if type(itemLink) ~= "string" or itemLink == "" then return false, nil, nil end
    local itemName = itemLink:match("%[(.-)%]") or itemLink
    local dungeonName = ExtractKeystoneDungeonName(itemName)
    if not dungeonName then
        return false, nil, nil
    end
    local wanted = NormalizeText(dungeonName)
    if wanted == "" then return false, dungeonName, nil end
    local currentDungeon = GetCurrentDungeonName()
    if type(currentDungeon) ~= "string" or currentDungeon == "" then
        return false, dungeonName, nil
    end
    local nCurrent = NormalizeText(currentDungeon)
    local matched = nCurrent ~= "" and nCurrent:find(wanted, 1, true) ~= nil
    return matched, dungeonName, currentDungeon
end

-- Ищет ключ в сумках и возвращает bag, slot (или nil, nil если не найден)
local function FindKeystoneInBags()
    for bag = 0, 4 do
        local getSlots = (GetContainerNumSlots or (C_Container and C_Container.GetContainerNumSlots))
        local slots = getSlots and getSlots(bag)
        if slots and slots > 0 then
            local getItemID = (GetContainerItemID or (C_Container and C_Container.GetContainerItemID))
            local getItemLink = (GetContainerItemLink or (C_Container and C_Container.GetContainerItemLink))
            for slot = 1, slots do
                local itemID = getItemID and getItemID(bag, slot)
                if itemID == KEYSTONE_ITEM_ID then
                    return bag, slot, (getItemLink and getItemLink(bag, slot) or nil)
                end
            end
        end
    end
    return nil, nil, nil
end

-- Пытается вставить ключ в чашу
local function TrySlotKeystone()
    if not MPT.db or not MPT.db.autoKeystone then return end
    if not C_ChallengeMode then
        return
    end

    -- Если ключ уже вставлен — ничего не делаем
    if C_ChallengeMode.HasSlottedKeystone and C_ChallengeMode.HasSlottedKeystone() then
        return
    end

    local bag, slot, itemLink = FindKeystoneInBags()
    if not bag then
        return
    end
    local matched = IsKeystoneForCurrentLocation(itemLink)
    if not matched then
        return
    end

    -- Берём ключ на курсор (WotLK / современные клиенты)
    local pickup = (PickupContainerItem or (C_Container and C_Container.PickupContainerItem))
    if pickup then
        local okPickup, errPickup = pcall(pickup, bag, slot)
        if not okPickup then
            return
        end
    end

    if C_ChallengeMode.SlotKeystone then
        -- На большинстве клиентов SlotKeystone использует предмет с курсора
        local ok, err = pcall(function()
            return C_ChallengeMode.SlotKeystone()
        end)
    end
end

local ksFrame = CreateFrame("Frame")

-- Реагируем только на одно событие открытия окна мифика
pcall(function() ksFrame:RegisterEvent("CHAT_MSG_ADDON") end)

ksFrame:SetScript("OnEvent", function(_, event, subEvent)
    if event == "CHAT_MSG_ADDON" and subEvent == "ASMSG_CHALLENGE_MODE_KEYSTONE_RECEPTABLE_OPEN" then
        -- Небольшая задержка, чтобы окно успело полностью открыться
        pendingSlotTime = (GetTime() or 0) + 0.1
    end
end)

ksFrame:SetScript("OnUpdate", function(_, elapsed)
    if not pendingSlotTime then return end
    local now = GetTime() or 0
    if now >= pendingSlotTime then
        pendingSlotTime = nil
        TrySlotKeystone()
    end
end)
