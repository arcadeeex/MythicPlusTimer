-- MythicPlusTimer: KeystoneSlot
-- Автоматически вставляет ключ в чашу при её открытии.
-- Ключ определяется по itemID 374584.
-- Триггер: события открытия чаши ключа (ASMSG_* / CHALLENGE_MODE_*).

local MPT = MythicPlusTimer

local KEYSTONE_ITEM_ID = 374584
local lastWorldEnterTime = 0
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

-- Sirus отправляет ASMSG_* как обычные события (не CHAT_MSG_ADDON)
ksFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
ksFrame:RegisterEvent("GOSSIP_SHOW")
pcall(function() ksFrame:RegisterEvent("CHAT_MSG_ADDON") end)
pcall(function() ksFrame:RegisterEvent("ASMSG_CHALLENGE_MODE_KEYSTONE_RECEPTABLE_OPEN") end)
pcall(function() ksFrame:RegisterEvent("CHALLENGE_MODE_KEYSTONE_RECEPTACLE_OPEN") end)
pcall(function() ksFrame:RegisterEvent("CHALLENGE_MODE_KEYSTONE_OPENED") end)

ksFrame:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "PLAYER_ENTERING_WORLD" then
        lastWorldEnterTime = GetTime() or 0
        return
    end

    if event == "GOSSIP_SHOW" then
        -- Игнорируем авто-срабатывание сразу после входа в мир,
        -- но реагируем на реальные клики по чаше.
        local now = GetTime() or 0
        if now - lastWorldEnterTime < 5 then
            return
        end
        pendingSlotTime = now + 0.1

    elseif event == "CHAT_MSG_ADDON" then
        -- CHAT_MSG_ADDON: arg1=prefix, arg2=message
        local prefix = tostring(arg1 or "")
        local message = tostring(arg2 or "")
        if prefix == "ASMSG_CHALLENGE_MODE_KEYSTONE_RECEPTABLE_OPEN"
            or prefix:find("KEYSTONE_RECEPT", 1, true)
            or message:find("KEYSTONE_RECEPT", 1, true) then
            pendingSlotTime = (GetTime() or 0) + 0.1
        end

    elseif event == "ASMSG_CHALLENGE_MODE_KEYSTONE_RECEPTABLE_OPEN"
        or event == "CHALLENGE_MODE_KEYSTONE_RECEPTACLE_OPEN"
        or event == "CHALLENGE_MODE_KEYSTONE_OPENED" then
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
