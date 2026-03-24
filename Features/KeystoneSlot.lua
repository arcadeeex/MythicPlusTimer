-- MythicPlusTimer: KeystoneSlot
-- Автоматически вставляет ключ в чашу при её открытии.
-- Ключ определяется по itemID 374584.
-- Триггер: события открытия чаши ключа (ASMSG_* / CHALLENGE_MODE_*).

local MPT = MythicPlusTimer

local KEYSTONE_ITEM_ID = 374584
local PULL_COUNTDOWN_SECONDS = 5
local pendingSlotTime = nil
local pendingSlotRetries = 0
local pendingStartChallengeAt = nil
local pendingCountdownNextAt = nil
local pendingCountdownValue = nil
local actionFrame = nil
local pullButton = nil
local keystoneParentFrame = nil
local pendingAttachUntil = nil
local hadValidParentThisOpen = false

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

local function NormalizeSenderName(s)
    if type(s) ~= "string" then return nil end
    local name = s:match("^([^%-]+)")
    if not name or name == "" then return nil end
    return name
end

local function IsSenderMe(sender)
    local me = UnitName("player")
    if type(me) ~= "string" or me == "" then return false end
    local senderName = NormalizeSenderName(sender)
    return senderName ~= nil and senderName == me
end

local function GetKeystoneWindowFrame()
    local candidates = {
        "ChallengesKeystoneFrame",
        "ChallengeModeKeystoneFrame",
        "ChallengeModeFrame",
        "KeystoneFrame",
    }
    for _, name in ipairs(candidates) do
        local f = _G[name]
        if f and type(f.IsShown) == "function" and f:IsShown() then
            return f
        end
    end

    -- Runtime fallback: sometimes receptacle UI has different global name on private cores.
    local best = nil
    local bestScore = -1
    for k, v in pairs(_G) do
        if type(k) == "string" and type(v) == "table" and type(v.IsShown) == "function" then
            local okShown, shown = pcall(function() return v:IsShown() end)
            if okShown and shown then
                local lower = k:lower()
                local score = 0
                if lower:find("keystone", 1, true) then score = score + 5 end
                if lower:find("recept", 1, true) then score = score + 5 end
                if lower:find("challenge", 1, true) then score = score + 2 end
                if lower:find("challengemode", 1, true) then score = score + 2 end
                if score > bestScore then
                    best = v
                    bestScore = score
                end
            end
        end
    end
    if bestScore >= 5 then
        return best
    end
    return nil
end

local function BuildTokenSet(s)
    local out = {}
    if type(s) ~= "string" or s == "" then return out end
    -- Keep only letters/digits/spaces to handle separators like ":" and "-".
    s = s:gsub("[^%w%s]+", " ")
    for token in s:gmatch("%S+") do
        -- Skip tiny tokens/noise.
        if #token >= 3 then
            out[token] = true
        end
    end
    return out
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
    local matched = false
    if nCurrent ~= "" then
        -- 1) Direct substring in both directions.
        matched = nCurrent:find(wanted, 1, true) ~= nil
            or wanted:find(nCurrent, 1, true) ~= nil

        -- 2) Token subset match to handle reordered words:
        -- "Цитадель Адского Пламени: Бастионы" vs "Бастионы Адского Пламени"
        if not matched then
            local wantedTokens = BuildTokenSet(wanted)
            local currentTokens = BuildTokenSet(nCurrent)
            local wantedCount = 0
            local matchedCount = 0
            for tok in pairs(wantedTokens) do
                wantedCount = wantedCount + 1
                if currentTokens[tok] then
                    matchedCount = matchedCount + 1
                end
            end
            matched = wantedCount > 0 and matchedCount == wantedCount
        end
    end
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
    if not MPT.db or not MPT.db.autoKeystone then return false end
    if not C_ChallengeMode then
        return false
    end

    -- Если ключ уже вставлен — ничего не делаем
    if C_ChallengeMode.HasSlottedKeystone and C_ChallengeMode.HasSlottedKeystone() then
        return true
    end

    local bag, slot, itemLink = FindKeystoneInBags()
    if not bag then
        return false
    end
    local matched = IsKeystoneForCurrentLocation(itemLink)
    if not matched then
        return false
    end

    -- Берём ключ на курсор (WotLK / современные клиенты)
    local pickup = (PickupContainerItem or (C_Container and C_Container.PickupContainerItem))
    if pickup then
        local okPickup, errPickup = pcall(pickup, bag, slot)
        if not okPickup then
            return false
        end
    end

    if C_ChallengeMode.SlotKeystone then
        -- На большинстве клиентов SlotKeystone использует предмет с курсора
        local ok, err = pcall(function()
            return C_ChallengeMode.SlotKeystone()
        end)
        if ok then
            return true
        end
    end
    return false
end

local function IsGroupLeader()
    if UnitIsGroupLeader then
        local ok, v = pcall(UnitIsGroupLeader, "player")
        if ok and v then return true end
    end
    if UnitIsPartyLeader then
        local ok, v = pcall(UnitIsPartyLeader, "player")
        if ok and v then return true end
    end
    if IsPartyLeader then
        local ok, v = pcall(IsPartyLeader)
        if ok and v then return true end
    end
    -- Legacy fallback for WotLK clients.
    if GetNumRaidMembers and GetNumRaidMembers() > 0 and GetRaidRosterInfo then
        for i = 1, GetNumRaidMembers() do
            local name, rank = GetRaidRosterInfo(i)
            if name and UnitName("player") and name:match("^([^%-]+)") == UnitName("player") then
                -- rank: 2 = leader, 1 = assistant
                return rank == 2
            end
        end
    end
    return false
end

local function RunSlashCommand(cmd)
    if type(cmd) ~= "string" or cmd == "" then return false end
    if ChatFrameEditBox and ChatEdit_ParseText then
        ChatFrameEditBox:SetText(cmd)
        ChatEdit_ParseText(ChatFrameEditBox, 0)
        return true
    end
    return false
end

local function TryStartChallenge()
    if not C_ChallengeMode then return false end
    if C_ChallengeMode.StartChallengeMode then
        local ok = pcall(function() C_ChallengeMode.StartChallengeMode() end)
        if ok then return true end
    end
    local kf = _G["ChallengeModeKeystoneFrame"] or _G["ChallengesKeystoneFrame"]
    if kf and kf.StartButton and kf.StartButton.Click then
        local ok = pcall(function() kf.StartButton:Click() end)
        if ok then return true end
    end
    return false
end

local function SendGroupMessage(msg)
    if type(msg) ~= "string" or msg == "" then return end
    if SendChatMessage then
        local raidCount = GetNumRaidMembers and GetNumRaidMembers() or 0
        local partyCount = GetNumPartyMembers and GetNumPartyMembers() or 0
        if raidCount > 0 then
            SendChatMessage(msg, "RAID")
            return
        end
        if partyCount > 0 then
            SendChatMessage(msg, "PARTY")
            return
        end
    end
    if MPT and MPT.Print then
        MPT:Print(msg)
    end
end

local function SetPullButtonIdleText()
    if pullButton and pullButton.txt and pullButton.txt.SetText then
        pullButton.txt:SetText("Пул 5 секунд")
    end
end

local function SetPullButtonStopText()
    if pullButton and pullButton.txt and pullButton.txt.SetText then
        pullButton.txt:SetText("Остановить пул")
    end
end

-- Кнопки в стиле окна настроек (/mpt).
local BTN_THEME = {
    panel2 = { 0.10, 0.10, 0.10, 0.95 },
    border = { 0.20, 0.20, 0.20, 1.00 },
    yellow = { 1.00, 0.82, 0.00, 1.00 },
    text = { 0.95, 0.95, 0.95, 1.00 },
}

local function ApplyConfigLikeButtonStyle(btn)
    if not btn then return end
    btn:SetNormalTexture("")
    btn:SetHighlightTexture("")
    btn:SetPushedTexture("")
    btn:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        tile = false, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    btn:SetBackdropColor(BTN_THEME.panel2[1], BTN_THEME.panel2[2], BTN_THEME.panel2[3], BTN_THEME.panel2[4])
    btn:SetBackdropBorderColor(BTN_THEME.border[1], BTN_THEME.border[2], BTN_THEME.border[3], BTN_THEME.border[4])
    if btn.txt then
        btn.txt:SetTextColor(BTN_THEME.text[1], BTN_THEME.text[2], BTN_THEME.text[3], BTN_THEME.text[4])
    end
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(BTN_THEME.yellow[1], BTN_THEME.yellow[2], BTN_THEME.yellow[3], 1)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(BTN_THEME.border[1], BTN_THEME.border[2], BTN_THEME.border[3], BTN_THEME.border[4])
    end)
end

local function CreateConfigLikeButton(parent, width, height, text)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(width, height)
    btn.txt = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    btn.txt:SetPoint("CENTER", btn, "CENTER", 0, 0)
    btn.txt:SetText(text or "")
    ApplyConfigLikeButtonStyle(btn)
    return btn
end

local function CancelPullCountdown()
    pendingStartChallengeAt = nil
    pendingCountdownNextAt = nil
    pendingCountdownValue = nil
    SetPullButtonIdleText()
    SendGroupMessage("Запуск отменен")
end

local function StartPullCountdown()
    local now = GetTime() or 0
    pendingStartChallengeAt = now + PULL_COUNTDOWN_SECONDS
    pendingCountdownValue = PULL_COUNTDOWN_SECONDS
    pendingCountdownNextAt = now
    SetPullButtonStopText()
end

local function EnsureActionFrame()
    if actionFrame then return actionFrame end
    local parent = GetKeystoneWindowFrame() or UIParent
    local f = CreateFrame("Frame", "MPTKeystoneActionFrame", parent)
    f:SetSize(250, 62)
    if parent == UIParent then
        f:SetPoint("CENTER", UIParent, "CENTER", 0, -180)
    else
        f:SetPoint("TOP", parent, "BOTTOM", 0, -10)
    end
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        tile = false, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    f:SetBackdropColor(0.06, 0.06, 0.06, 0.95)
    f:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
    f:Hide()

    local pullBtn = CreateConfigLikeButton(f, 116, 22, "Пул 5 секунд")
    pullBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8)
    pullBtn:SetScript("OnClick", function()
        if pendingStartChallengeAt then
            CancelPullCountdown()
            return
        end

        StartPullCountdown()
    end)
    pullButton = pullBtn

    local readyBtn = CreateConfigLikeButton(f, 116, 22, "Проверка готовности")
    readyBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)
    readyBtn:SetScript("OnClick", function()
        if not IsGroupLeader() then
            if MPT and MPT.Print then
                MPT:Print("Проверка готовности доступна только лидеру группы.")
            end
            return
        end
        pcall(function()
            if DoReadyCheck then
                DoReadyCheck()
            else
                RunSlashCommand("/readycheck")
            end
        end)
    end)

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("BOTTOM", f, "BOTTOM", 0, 8)
    hint:SetText("MPT: быстрые действия для ключа")
    hint:SetTextColor(0.8, 0.8, 0.8, 1)

    actionFrame = f
    return f
end

local function PositionActionFrameNearParent(f, parent)
    if not f or not parent then return end

    local right = parent.GetRight and parent:GetRight() or nil
    local top = parent.GetTop and parent:GetTop() or nil

    -- Keep action frame outside the keystone window as a sibling of UIParent.
    f:SetParent(UIParent)
    f:ClearAllPoints()

    if right and top then
        local gap = 12
        -- Requested behavior: always place action frame on the right side.
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", right + gap, top)
        return
    end

    -- Last-resort fallback if coordinates are unavailable.
    f:SetPoint("TOP", parent, "BOTTOM", 0, -10)
end

local function AttachActionFrameToParent()
    local f = EnsureActionFrame()
    local parent = GetKeystoneWindowFrame()
    if not parent then
        keystoneParentFrame = nil
        f:ClearAllPoints()
        f:SetParent(UIParent)
        f:SetPoint("CENTER", UIParent, "CENTER", 0, -180)
        return
    end
    if keystoneParentFrame ~= parent then
        keystoneParentFrame = parent
        if parent.HookScript and not parent.__mptKsHooked then
            parent.__mptKsHooked = true
            parent:HookScript("OnHide", function()
                if actionFrame then actionFrame:Hide() end
                pendingStartChallengeAt = nil
                pendingCountdownNextAt = nil
                pendingCountdownValue = nil
                SetPullButtonIdleText()
            end)
        end
    end
    PositionActionFrameNearParent(f, parent)
end

local function IsQuickActionsEnabled()
    if not MPT or not MPT.db then return true end
    return MPT.db.showKeystoneActions ~= false
end

local ksFrame = CreateFrame("Frame")

-- Реагируем только на одно событие открытия окна мифика
pcall(function() ksFrame:RegisterEvent("CHAT_MSG_ADDON") end)
pcall(function() ksFrame:RegisterEvent("PLAYER_ENTERING_WORLD") end)

ksFrame:SetScript("OnEvent", function(_, event, prefix, msg, channel, sender)
    if event == "PLAYER_ENTERING_WORLD" then
        pendingStartChallengeAt = nil
        pendingCountdownNextAt = nil
        pendingCountdownValue = nil
        pendingAttachUntil = nil
        hadValidParentThisOpen = false
        SetPullButtonIdleText()
        if actionFrame then actionFrame:Hide() end
        return
    end
    if event == "CHAT_MSG_ADDON" and prefix == "ASMSG_CHALLENGE_MODE_KEYSTONE_RECEPTABLE_OPEN" then
        -- Небольшая задержка, чтобы окно успело полностью открыться
        pendingSlotTime = (GetTime() or 0) + 0.1
        pendingSlotRetries = 8
        pendingAttachUntil = (GetTime() or 0) + 1.5
        hadValidParentThisOpen = false
        if IsQuickActionsEnabled() then
            -- Кнопки показываем только на событии, которое пришло от нас.
            AttachActionFrameToParent()
            local f = EnsureActionFrame()
            if IsSenderMe(sender) then
                f:Show()
            else
                f:Hide()
            end
        elseif actionFrame then
            actionFrame:Hide()
        end
    end
end)

ksFrame:SetScript("OnUpdate", function(_, elapsed)
    local now = GetTime() or 0
    if not IsQuickActionsEnabled() then
        if actionFrame and actionFrame:IsShown() then
            actionFrame:Hide()
        end
        pendingStartChallengeAt = nil
        pendingCountdownNextAt = nil
        pendingCountdownValue = nil
    end

    -- Окно чаши может появляться с задержкой после события открытия.
    if pendingAttachUntil and now <= pendingAttachUntil then
        local parent = GetKeystoneWindowFrame()
        if parent then
            AttachActionFrameToParent()
            hadValidParentThisOpen = true
            pendingAttachUntil = nil
        end
    elseif pendingAttachUntil and now > pendingAttachUntil then
        pendingAttachUntil = nil
    end

    if actionFrame and actionFrame:IsShown() then
        -- Safety-net: скрываем кнопки, если окно чаши уже закрыто.
        local parent = GetKeystoneWindowFrame()
        if parent then
            hadValidParentThisOpen = true
        end
        -- Прячем только если на этом открытии мы уже видели валидный parent.
        if hadValidParentThisOpen and ((not parent) or (type(parent.IsShown) == "function" and not parent:IsShown())) then
            actionFrame:Hide()
            pendingStartChallengeAt = nil
        end
    end

    if not pendingSlotTime and not pendingStartChallengeAt and not pendingCountdownNextAt then return end
    if pendingCountdownNextAt and pendingCountdownValue and now >= pendingCountdownNextAt then
        SendGroupMessage(string.format("Запуск ключа через %d сек.", pendingCountdownValue))
        pendingCountdownValue = pendingCountdownValue - 1
        if pendingCountdownValue <= 0 then
            pendingCountdownNextAt = nil
            pendingCountdownValue = nil
        else
            pendingCountdownNextAt = pendingCountdownNextAt + 1
        end
    end
    if pendingStartChallengeAt and now >= pendingStartChallengeAt then
        pendingStartChallengeAt = nil
        pendingCountdownNextAt = nil
        pendingCountdownValue = nil
        SetPullButtonIdleText()
        SendGroupMessage("Запуск")
        TryStartChallenge()
        if actionFrame then actionFrame:Hide() end
    end
    if pendingSlotTime and now >= pendingSlotTime then
        local ok = TrySlotKeystone()
        if ok then
            pendingSlotTime = nil
            pendingSlotRetries = 0
        else
            pendingSlotRetries = (pendingSlotRetries or 0) - 1
            if pendingSlotRetries > 0 then
                -- Retry: right after zone/open APIs can lag for a moment.
                pendingSlotTime = now + 0.25
            else
                pendingSlotTime = nil
                pendingSlotRetries = 0
            end
        end
    end
end)
