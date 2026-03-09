-- MythicPlusTimer: KeystoneSlot
-- Автоматически вставляет ключ в чашу при её открытии.
-- Ключ определяется по itemID 374584.
-- Триггер: события открытия чаши ключа (ASMSG_* / CHALLENGE_MODE_*).

local MPT = MythicPlusTimer

local KEYSTONE_ITEM_ID = 374584
local pendingSlotTime = nil

-- Ищет ключ в сумках и возвращает bag, slot (или nil, nil если не найден)
local function FindKeystoneInBags()
    for bag = 0, 4 do
        local getSlots = (GetContainerNumSlots or (C_Container and C_Container.GetContainerNumSlots))
        local slots = getSlots and getSlots(bag)
        if slots and slots > 0 then
            local getItemID = (GetContainerItemID or (C_Container and C_Container.GetContainerItemID))
            for slot = 1, slots do
                local itemID = getItemID and getItemID(bag, slot)
                if itemID == KEYSTONE_ITEM_ID then
                    return bag, slot
                end
            end
        end
    end
    return nil, nil
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

    local bag, slot = FindKeystoneInBags()
    if not bag then
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
