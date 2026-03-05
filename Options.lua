-- MythicPlusTimer: Options
-- Панель настроек в Interface → Модификации

local MPT = MythicPlusTimer

-- PLAYER_LOGIN: к этому моменту весь UI Blizzard загружен и InterfaceOptions_AddCategory доступен
local optInitFrame = CreateFrame("Frame")
optInitFrame:RegisterEvent("PLAYER_LOGIN")
optInitFrame:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")

    if not InterfaceOptions_AddCategory then return end

    local panel = CreateFrame("Frame", "MythicPlusTimerOptions")
    panel.name = "MythicPlus Timer"

    -- Заголовок
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("MythicPlus Timer")

    -- Подзаголовок
    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    subtitle:SetText("Таймер и трекер для Mythic+ данжей на Sirus")

    -- ── Раздел: Чекбоксы ─────────────────────────────────────────
    local checkHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    checkHeader:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -20)
    checkHeader:SetText("Отображение")

    -- Чекбокс: Debug режим
    local debugCheck = CreateFrame("CheckButton", "MPTDebugCheck", panel, "InterfaceOptionsSmallCheckButtonTemplate")
    debugCheck:SetPoint("TOPLEFT", checkHeader, "BOTTOMLEFT", -2, -8)

    local debugCheckText = _G["MPTDebugCheckText"]
    if debugCheckText then
        debugCheckText:SetText("Debug режим")
    end
    debugCheck.tooltipText = "Debug режим"
    debugCheck.tooltipRequirement = "Выводит отладочную информацию в чат"

    debugCheck:HookScript("OnClick", function(check)
        if MPT.db then
            MPT.db.debug = check:GetChecked() == 1 or check:GetChecked() == true
        end
    end)

    -- Чекбокс: Аффиксы текстом
    local affixTextCheck = CreateFrame("CheckButton", "MPTAffixTextCheck", panel, "InterfaceOptionsSmallCheckButtonTemplate")
    affixTextCheck:SetPoint("TOPLEFT", debugCheck, "BOTTOMLEFT", 0, -4)

    local affixTextLabel = _G["MPTAffixTextCheckText"]
    if affixTextLabel then
        affixTextLabel:SetText("Показывать аффиксы текстом")
    end
    affixTextCheck.tooltipText = "Аффиксы текстом"
    affixTextCheck.tooltipRequirement = "Показывает текстовые названия аффиксов"

    affixTextCheck:HookScript("OnClick", function(check)
        if MPT.db then
            MPT.db.affixText = check:GetChecked() == 1 or check:GetChecked() == true
            MPT:RefreshCurrentAffixes()
        end
    end)

    -- Чекбокс: Аффиксы иконками
    local affixIconsCheck = CreateFrame("CheckButton", "MPTAffixIconsCheck", panel, "InterfaceOptionsSmallCheckButtonTemplate")
    affixIconsCheck:SetPoint("TOPLEFT", affixTextCheck, "BOTTOMLEFT", 0, -4)

    local affixIconsText = _G["MPTAffixIconsCheckText"]
    if affixIconsText then
        affixIconsText:SetText("Показывать аффиксы иконками")
    end
    affixIconsCheck.tooltipText = "Аффиксы иконками"
    affixIconsCheck.tooltipRequirement = "Показывает иконки аффиксов"

    affixIconsCheck:HookScript("OnClick", function(check)
        if MPT.db then
            MPT.db.affixIcons = check:GetChecked() == 1 or check:GetChecked() == true
            MPT:RefreshCurrentAffixes()
        end
    end)

    -- Чекбокс: Прогресс бар сил
    local forcesBarCheck = CreateFrame("CheckButton", "MPTForcesBarCheck", panel, "InterfaceOptionsSmallCheckButtonTemplate")
    forcesBarCheck:SetPoint("TOPLEFT", affixIconsCheck, "BOTTOMLEFT", 0, -4)

    local forcesBarText = _G["MPTForcesBarCheckText"]
    if forcesBarText then
        forcesBarText:SetText("Показывать прогресс баром")
    end
    forcesBarCheck.tooltipText = "Прогресс бар"
    forcesBarCheck.tooltipRequirement = "Показывает прогресс убийств в виде прогресс бара"

    forcesBarCheck:HookScript("OnClick", function(check)
        if MPT.db then
            MPT.db.forcesBar = check:GetChecked() == 1 or check:GetChecked() == true
            MPT:RefreshForcesMode()
        end
    end)

    -- Чекбокс: Авто-вставка ключа
    local autoKeystoneCheck = CreateFrame("CheckButton", "MPTAutoKeystoneCheck", panel, "InterfaceOptionsSmallCheckButtonTemplate")
    autoKeystoneCheck:SetPoint("TOPLEFT", forcesBarCheck, "BOTTOMLEFT", 0, -4)

    local autoKeystoneText = _G["MPTAutoKeystoneCheckText"]
    if autoKeystoneText then
        autoKeystoneText:SetText("Вставлять ключ автоматически")
    end
    autoKeystoneCheck.tooltipText = "Авто-вставка ключа"
    autoKeystoneCheck.tooltipRequirement = "Автоматически вставляет ключ в чашу при её открытии"

    autoKeystoneCheck:HookScript("OnClick", function(check)
        if MPT.db then
            MPT.db.autoKeystone = check:GetChecked() == 1 or check:GetChecked() == true
        end
    end)

    -- ── Кнопка превью ─────────────────────────────────────────────
    local previewBtn = CreateFrame("Button", "MPTPreviewBtn", panel, "UIPanelButtonTemplate")
    previewBtn:SetPoint("TOPLEFT", autoKeystoneCheck, "BOTTOMLEFT", 2, -16)
    previewBtn:SetWidth(140)
    previewBtn:SetHeight(22)
    previewBtn:SetText("Показать превью")
    previewBtn:SetScript("OnClick", function()
        local timerFrame = _G["MPTTimerFrame"]
        if timerFrame and timerFrame:IsShown() then
            timerFrame:Hide()
            previewBtn:SetText("Показать превью")
        else
            MPT:ShowPreview()
            previewBtn:SetText("Скрыть превью")
        end
    end)

    -- ── Раздел: Масштаб ───────────────────────────────────────────
    local scaleHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    scaleHeader:SetPoint("TOPLEFT", previewBtn, "BOTTOMLEFT", -2, -20)
    scaleHeader:SetText("Масштаб")

    local scaleLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    scaleLabel:SetPoint("TOPLEFT", scaleHeader, "BOTTOMLEFT", 2, -6)
    scaleLabel:SetText("1.0")

    local scaleSlider = CreateFrame("Slider", "MPTScaleSlider", panel)
    scaleSlider:SetPoint("TOPLEFT", scaleLabel, "BOTTOMLEFT", 0, -4)
    scaleSlider:SetWidth(200)
    scaleSlider:SetHeight(16)
    scaleSlider:SetOrientation("HORIZONTAL")
    scaleSlider:SetMinMaxValues(0.5, 2.0)
    scaleSlider:SetValueStep(0.1)
    scaleSlider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    scaleSlider:SetBackdrop({
        bgFile   = "Interface\\Buttons\\UI-SliderBar-Background",
        edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 3, right = 3, top = 6, bottom = 6 },
    })

    local sliderLow = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sliderLow:SetPoint("TOPLEFT", scaleSlider, "BOTTOMLEFT", 0, -2)
    sliderLow:SetText("0.5")

    local sliderHigh = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sliderHigh:SetPoint("TOPRIGHT", scaleSlider, "BOTTOMRIGHT", 0, -2)
    sliderHigh:SetText("2.0")

    scaleSlider:SetScript("OnValueChanged", function(_, value)
        value = math.floor(value * 10 + 0.5) / 10
        scaleLabel:SetText(string.format("%.1f", value))
        if MPT.db then
            MPT.db.scale = value
        end
        local timerFrame = _G["MPTTimerFrame"]
        if timerFrame then
            timerFrame:SetScale(value)
        end
    end)

    -- Синхронизация состояния при открытии панели
    panel:SetScript("OnShow", function()
        debugCheck:SetChecked(MPT.db and MPT.db.debug or false)
        affixTextCheck:SetChecked(MPT.db and MPT.db.affixText or false)
        affixIconsCheck:SetChecked(MPT.db and MPT.db.affixIcons or false)
        forcesBarCheck:SetChecked(MPT.db and MPT.db.forcesBar or false)
        autoKeystoneCheck:SetChecked(MPT.db and MPT.db.autoKeystone or false)

        local scale = (MPT.db and MPT.db.scale) or 1.0
        scaleLabel:SetText(string.format("%.1f", scale))
        scaleSlider:SetValue(scale)

        local timerFrame = _G["MPTTimerFrame"]
        local shown = timerFrame and timerFrame:IsShown()
        previewBtn:SetText(shown and "Скрыть превью" or "Показать превью")
    end)

    InterfaceOptions_AddCategory(panel)
end)
