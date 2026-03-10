-- MythicPlusTimer: Options
-- Панель настроек в Interface → Модификации

local MPT = MythicPlusTimer

-- ── Кастомный скроллируемый dropdown ────────────────────────────────────────
-- CreateMPTDropDown(parent, width, maxVisible, items, onSelect, renderRow, itemH)
--   items     = { {name=..., ...}, ... }  — таблица элементов
--   onSelect  = function(item)            — вызывается при выборе
--   renderRow = function(row, item)       — опциональная кастомная отрисовка строки
--   itemH     = высота одной строки (по умолчанию 18)
-- Возвращает { button, setItems, setValue, getSelected }
local MPTDD_ITEM_H  = 18
local MPTDD_PADDING = 4

local function CreateMPTDropDown(parent, width, maxVisible, items, onSelect, renderRow, itemH)
    itemH = itemH or MPTDD_ITEM_H

    -- Кнопка-заголовок
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetWidth(width)
    btn:SetHeight(22)

    -- Стрелка на кнопке
    local arrow = btn:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
    arrow:SetWidth(10)
    arrow:SetHeight(10)
    arrow:SetPoint("RIGHT", btn, "RIGHT", -6, 0)

    -- Popup-фрейм
    local popup = CreateFrame("Frame", nil, UIParent)
    popup:SetWidth(width + 20) -- добавляем место под скроллбар справа
    popup:SetFrameStrata("TOOLTIP")
    popup:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left=4, right=4, top=4, bottom=4 },
    })
    popup:Hide()

    -- Область для строк (в 3.3.5 нет SetClipsChildren, полагаемся на высоту popup)
    local clip = CreateFrame("Frame", nil, popup)
    clip:SetPoint("TOPLEFT",     popup, "TOPLEFT",  MPTDD_PADDING, -MPTDD_PADDING)
    clip:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -MPTDD_PADDING - 16, MPTDD_PADDING)

    -- Пул кнопок строк (дочерние clip-фрейма)
    local rowBtns = {}
    for i = 1, maxVisible do
        local row = CreateFrame("Button", nil, clip)
        row:SetHeight(itemH)
        row:SetPoint("LEFT",  clip, "LEFT",  0, 0)
        row:SetPoint("RIGHT", clip, "RIGHT", 0, 0)

        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        hl:SetVertexColor(1, 1, 1, 0.15)

        local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl:SetPoint("LEFT",  row, "LEFT",  4, 0)
        lbl:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        lbl:SetJustifyH("LEFT")
        row.lbl = lbl
        rowBtns[i] = row
    end

    local currentItems = items or {}
    local selectedName = ""
    local scrollOffset = 0  -- 0-based индекс первого видимого элемента

    local function clampOffset()
        local total = #currentItems
        local maxOff = math.max(0, total - maxVisible)
        if scrollOffset < 0 then scrollOffset = 0 end
        if scrollOffset > maxOff then scrollOffset = maxOff end
    end

    local function updateRows()
        clampOffset()
        local total = #currentItems
        for i = 1, maxVisible do
            local idx = scrollOffset + i
            local row = rowBtns[i]
            -- позиционируем строку по Y внутри clip
            row:ClearAllPoints()
            row:SetPoint("LEFT",  clip, "LEFT",  0, 0)
            row:SetPoint("RIGHT", clip, "RIGHT", 0, 0)
            row:SetPoint("TOP",   clip, "TOP",   0, -(i-1) * itemH)
            if idx <= total then
                local item = currentItems[idx]
                row.lbl:SetText(item.name)
                if renderRow then
                    renderRow(row, item)
                end
                if item.name == selectedName then
                    row.lbl:SetTextColor(1, 0.82, 0)
                else
                    row.lbl:SetTextColor(1, 1, 1)
                end
                row:SetScript("OnClick", function()
                    selectedName = item.name
                    btn:SetText(item.name)
                    popup:Hide()
                    if onSelect then onSelect(item) end
                end)
                row:Show()
            else
                row:Hide()
            end
        end

        -- Обновление скроллбара
        local total2 = total
        local maxOff = math.max(0, total2 - maxVisible)
        if popup.scrollBar then
            if total2 > maxVisible then
                popup.scrollBar:SetMinMaxValues(0, maxOff)
                popup.scrollBar:SetValue(scrollOffset)
                popup.scrollBar:Show()
            else
                popup.scrollBar:SetMinMaxValues(0, 0)
                popup.scrollBar:SetValue(0)
                popup.scrollBar:Hide()
            end
        end
    end

    -- Скроллбар справа (UIPanelScrollBarTemplate уже даёт стрелки и ползунок)
    local scrollBar = CreateFrame("Slider", nil, popup, "UIPanelScrollBarTemplate")
    scrollBar:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -2, -18)
    scrollBar:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -2, 18)
    scrollBar:SetMinMaxValues(0, 0)
    scrollBar:SetValueStep(1)
    -- SetObeyStepOnDrag() нет в WotLK 3.3.5, шаг контролируем сами
    scrollBar:SetWidth(16)
    scrollBar:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5)
        if value ~= scrollOffset then
            scrollOffset = value
            updateRows()
        end
    end)
    popup.scrollBar = scrollBar

    -- Скролл колесом мыши
    popup:EnableMouseWheel(true)
    popup:SetScript("OnMouseWheel", function(_, delta)
        if popup.scrollBar and popup.scrollBar:IsShown() then
            popup.scrollBar:SetValue(scrollOffset - delta)
        else
            scrollOffset = scrollOffset - delta
            updateRows()
        end
    end)

    btn:SetScript("OnClick", function()
        if popup:IsShown() then
            popup:Hide()
        else
            local visible = math.min(#currentItems, maxVisible)
            local innerH  = visible * itemH
            popup:SetHeight(innerH + MPTDD_PADDING * 2)
            clip:SetHeight(innerH)
            popup:ClearAllPoints()
            popup:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
            scrollOffset = 0
            updateRows()
            popup:Show()
        end
    end)

    local dd = {}

    function dd.setItems(newItems)
        currentItems = newItems or {}
        scrollOffset = 0
        if popup:IsShown() then updateRows() end
    end

    function dd.setValue(name)
        selectedName = name
        btn:SetText(name)
        if popup:IsShown() then updateRows() end
    end

    function dd.getSelected()
        return selectedName
    end

    dd.button = btn
    dd.popup  = popup

    return dd
end

-- PLAYER_LOGIN: к этому моменту весь UI Blizzard загружен и InterfaceOptions_AddCategory доступен
local optInitFrame = CreateFrame("Frame")
optInitFrame:RegisterEvent("PLAYER_LOGIN")
optInitFrame:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")

    -- Обновляем списки шрифтов и текстур из LibSharedMedia-3.0 (если установлен).
    -- Вызываем здесь: к PLAYER_LOGIN LibStub и LSM уже инициализированы.
    if MPT.RefreshMediaLists then MPT:RefreshMediaLists() end

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

    -- Чекбокс: Закрепить окно (правый верхний угол)
    local lockCheck = CreateFrame("CheckButton", "MPTLockCheck", panel, "InterfaceOptionsSmallCheckButtonTemplate")
    lockCheck:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -16, -16)

    local lockCheckText = _G["MPTLockCheckText"]
    if lockCheckText then
        lockCheckText:SetText("Закрепить окно")
        lockCheckText:ClearAllPoints()
        lockCheckText:SetPoint("RIGHT", lockCheck, "LEFT", -2, 0)
    end
    lockCheck.tooltipText = "Закрепить окно"
    lockCheck.tooltipRequirement = "Запрещает перетаскивание окна таймера мышью"

    lockCheck:HookScript("OnClick", function(check)
        if MPT.db then
            MPT.db.locked = check:GetChecked() == 1 or check:GetChecked() == true
        end
    end)

    -- ── Раздел: Общее (слева) ─────────────────────────────────────
    local checkHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    checkHeader:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -20)
    checkHeader:SetText("Общее")

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

    -- Чекбокс: Показать рекорд подземелья
    local recordCheck = CreateFrame("CheckButton", "MPTDungeonRecordCheck", panel, "InterfaceOptionsSmallCheckButtonTemplate")
    recordCheck:SetPoint("TOPLEFT", debugCheck, "BOTTOMLEFT", 0, -4)

    local recordCheckText = _G["MPTDungeonRecordCheckText"]
    if recordCheckText then
        recordCheckText:SetText("Показывать рекорд подземелья")
    end
    recordCheck.tooltipText = "Рекорд подземелья"
    recordCheck.tooltipRequirement = "Показывать строку с рекордом и отклонением возле убитого босса"

    recordCheck:HookScript("OnClick", function(check)
        if MPT.db then
            MPT.db.showBossRecord = check:GetChecked() == 1 or check:GetChecked() == true
            local timerFrame = _G["MPTTimerFrame"]
            if timerFrame and timerFrame:IsShown() and MPT.ShowPreview then
                MPT:ShowPreview()
            end
        end
    end)

    -- ── Раздел: Прогресс убитых мобов (справа) ────────────────────
    local progressHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    progressHeader:SetPoint("TOPLEFT", checkHeader, "TOPLEFT", 260, 0)
    progressHeader:SetText("Прогресс убитых мобов")

    -- Чекбокс: Прогресс бар сил
    local forcesBarCheck = CreateFrame("CheckButton", "MPTForcesBarCheck", panel, "InterfaceOptionsSmallCheckButtonTemplate")
    forcesBarCheck:SetPoint("TOPLEFT", progressHeader, "BOTTOMLEFT", -2, -8)

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

    -- ── Раздел: Аффиксы (под блоком прогресса справа) ───────────────
    local affixHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    affixHeader:SetPoint("TOPLEFT", progressHeader, "BOTTOMLEFT", 0, -162)
    affixHeader:SetText("Аффиксы")

    -- Чекбокс: Аффиксы текстом
    local affixTextCheck = CreateFrame("CheckButton", "MPTAffixTextCheck", panel, "InterfaceOptionsSmallCheckButtonTemplate")
    affixTextCheck:SetPoint("TOPLEFT", affixHeader, "BOTTOMLEFT", -2, -8)

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

    -- Цвет прогресс-бара (отдельной строкой под чекбоксом прогресса)
    local forcesColorSwatch = CreateFrame("Button", nil, panel)
    forcesColorSwatch:SetSize(18, 18)
    forcesColorSwatch:SetPoint("TOPLEFT", forcesBarCheck, "BOTTOMLEFT", 2, -8)
    -- Рамка вокруг свотча
    local border = forcesColorSwatch:CreateTexture(nil, "BORDER")
    border:SetAllPoints()
    border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    forcesColorSwatch.border = border
    -- Внутренний цветной квадрат
    local swatchTex = forcesColorSwatch:CreateTexture(nil, "ARTWORK")
    swatchTex:SetPoint("TOPLEFT", 3, -3)
    swatchTex:SetPoint("BOTTOMRIGHT", -3, 3)
    swatchTex:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    forcesColorSwatch.tex = swatchTex

    local forcesColorLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    forcesColorLabel:SetPoint("LEFT", forcesColorSwatch, "RIGHT", 6, 0)
    forcesColorLabel:SetText("Цвет прогресс бара")

    -- ── Текстура прогресс-бара (скроллируемый dropdown) ──────────────
    local texLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    texLabel:SetPoint("TOPLEFT", forcesColorSwatch, "BOTTOMLEFT", 0, -14)
    texLabel:SetText("Текстура полосы:")

    local texDD = CreateMPTDropDown(panel, 180, 10, MPT.BAR_TEXTURES or {}, function(item)
        if MPT.db then MPT.db.forcesTexture = item.name end
        if MPT.RefreshForcesTexture then MPT:RefreshForcesTexture() end
    end, function(row, item)
        -- Создаём превью-бар один раз при первом рендере строки
        if not row._texBar then
            row._texBar = row:CreateTexture(nil, "ARTWORK")
            row._texBar:SetPoint("BOTTOMLEFT",  row, "BOTTOMLEFT",  4, 3)
            row._texBar:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4, 3)
            row._texBar:SetHeight(7)
            -- Смещаем lbl в верхнюю часть строки, чтобы не перекрывался с баром
            row.lbl:ClearAllPoints()
            row.lbl:SetPoint("TOPLEFT",  row, "TOPLEFT",  4, -2)
            row.lbl:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -2)
            row.lbl:SetHeight(14)
        end
        if item.path then
            row._texBar:SetTexture(item.path)
            row._texBar:SetVertexColor(1, 1, 1, 1)
            row._texBar:Show()
        else
            row._texBar:Hide()
        end
    end, 26)
    texDD.button:SetPoint("TOPLEFT", texLabel, "BOTTOMLEFT", 0, -4)

    local function UpdateTexDropFromDB()
        texDD.setValue((MPT.db and MPT.db.forcesTexture) or "Blank")
    end
    UpdateTexDropFromDB()

    local resetLearnedBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    resetLearnedBtn:SetPoint("TOPLEFT", texDD.button, "BOTTOMLEFT", 0, -8)
    resetLearnedBtn:SetWidth(220)
    resetLearnedBtn:SetHeight(22)
    resetLearnedBtn:SetText("Сбросить выученные данные")
    resetLearnedBtn:SetScript("OnClick", function()
        if MPT.db then
            MPT.db.learnedForces = {}
            MPT:Print("Выученные данные сброшены.")
        end
    end)
    resetLearnedBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        GameTooltip:SetText("Сбросить выученные данные", 1, 1, 1)
        GameTooltip:AddLine("Удаляет данные о % прогресса мобов,\nнакопленные автоматически во время ключей.\nСтатическая база данных не затрагивается.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    resetLearnedBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    local function UpdateSwatchFromDB()
        local r, g, b = 0.25, 0.55, 1.0
        if MPT.db and MPT.db.forcesColor then
            local c = MPT.db.forcesColor
            if type(c.r) == "number" and type(c.g) == "number" and type(c.b) == "number" then
                r, g, b = c.r, c.g, c.b
            end
        end
        swatchTex:SetVertexColor(r, g, b)
    end
    UpdateSwatchFromDB()

    forcesColorSwatch:SetScript("OnClick", function()
        if not ColorPickerFrame then return end
        local r, g, b = 0.25, 0.55, 1.0
        if MPT.db and MPT.db.forcesColor then
            local c = MPT.db.forcesColor
            if type(c.r) == "number" and type(c.g) == "number" and type(c.b) == "number" then
                r, g, b = c.r, c.g, c.b
            end
        end

        local function setColor(nr, ng, nb)
            if not MPT.db then return end
            MPT.db.forcesColor = { r = nr, g = ng, b = nb }
            UpdateSwatchFromDB()
            UpdateTexDropFromDB()
            if MPT.RefreshForcesColor then
                MPT:RefreshForcesColor()
            end
        end

        ColorPickerFrame.func = function()
            local nr, ng, nb = ColorPickerFrame:GetColorRGB()
            setColor(nr, ng, nb)
        end
        ColorPickerFrame.hasOpacity = false
        ColorPickerFrame.previousValues = { r, g, b }
        ColorPickerFrame.cancelFunc = function(prev)
            local pr, pg, pb = unpack(prev or ColorPickerFrame.previousValues)
            setColor(pr, pg, pb)
        end
        ColorPickerFrame:SetColorRGB(r, g, b)
        ColorPickerFrame:Hide()
        ColorPickerFrame:Show()
    end)

    -- Чекбокс: Авто-вставка ключа (в разделе "Общее" слева)
    local autoKeystoneCheck = CreateFrame("CheckButton", "MPTAutoKeystoneCheck", panel, "InterfaceOptionsSmallCheckButtonTemplate")
    autoKeystoneCheck:SetPoint("TOPLEFT", recordCheck, "BOTTOMLEFT", 0, -4)

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

    -- Чекбокс: Обратный таймер
    local reverseTimerCheck = CreateFrame("CheckButton", "MPTReverseTimerCheck", panel, "InterfaceOptionsSmallCheckButtonTemplate")
    reverseTimerCheck:SetPoint("TOPLEFT", autoKeystoneCheck, "BOTTOMLEFT", 0, -4)

    local reverseTimerText = _G["MPTReverseTimerCheckText"]
    if reverseTimerText then
        reverseTimerText:SetText("Обратный таймер")
    end
    reverseTimerCheck.tooltipText = "Обратный таймер"
    reverseTimerCheck.tooltipRequirement = "Таймер считает от максимума до нуля (текущий режим). Если выключено — таймер убывает от лимита к нулю"

    reverseTimerCheck:HookScript("OnClick", function(check)
        if MPT.db then
            MPT.db.reverseTimer = check:GetChecked() == 1 or check:GetChecked() == true
        end
    end)

    -- Чекбокс: Скрывать стандартный интерфейс ключа
    local hideDefaultTrackerCheck = CreateFrame("CheckButton", "MPTHideDefaultTrackerCheck", panel, "InterfaceOptionsSmallCheckButtonTemplate")
    hideDefaultTrackerCheck:SetPoint("TOPLEFT", reverseTimerCheck, "BOTTOMLEFT", 0, -4)

    local hideDefaultTrackerText = _G["MPTHideDefaultTrackerCheckText"]
    if hideDefaultTrackerText then
        hideDefaultTrackerText:SetText("Скрывать стандартный интерфейс")
    end
    hideDefaultTrackerCheck.tooltipText = "Скрывать стандартный интерфейс"
    hideDefaultTrackerCheck.tooltipRequirement = "Скрывает стандартный трекер целей ключа (прогресс, боссы) во время прохождения. Если выключено — оба интерфейса видны."

    hideDefaultTrackerCheck:HookScript("OnClick", function(check)
        if MPT.db then
            MPT.db.hideDefaultTracker = check:GetChecked() == 1 or check:GetChecked() == true
            if MPT.ApplyDefaultTrackerVisibility then
                MPT:ApplyDefaultTrackerVisibility()
            end
        end
    end)

    -- ── Шрифт текста (скроллируемый dropdown) ────────────────────────
    local fontLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fontLabel:SetPoint("TOPLEFT", hideDefaultTrackerCheck, "BOTTOMLEFT", 2, -10)
    fontLabel:SetText("Шрифт текста:")

    local DEFAULT_FONT = "Fonts\\FRIZQT__.TTF"
    local FONT_PREVIEW_SIZE = 13

    local fontDD = CreateMPTDropDown(panel, 180, 12, MPT.FONTS or {}, function(item)
        if MPT.db then MPT.db.font = item.name end
        if MPT.RefreshFont then MPT:RefreshFont() end
    end, function(row, item)
        -- Сначала сброс до дефолта, чтобы при неудачной загрузке не оставался
        -- шрифт предыдущего элемента (строки переиспользуются в пуле)
        row.lbl:SetFont(DEFAULT_FONT, FONT_PREVIEW_SIZE, "")
        if item.path then
            row.lbl:SetFont(item.path, FONT_PREVIEW_SIZE, "")
        end
    end)
    fontDD.button:SetPoint("TOPLEFT", fontLabel, "BOTTOMLEFT", 0, -4)

    local function UpdateFontDropFromDB()
        fontDD.setValue((MPT.db and MPT.db.font) or "Friz Quadrata (default)")
    end
    UpdateFontDropFromDB()

    -- ── Кнопка превью (под аффиксами, по центру) ────────────────────
    local previewBtn = CreateFrame("Button", "MPTPreviewBtn", panel, "UIPanelButtonTemplate")
    previewBtn:SetPoint("BOTTOM", affixIconsCheck, "BOTTOM", 0, -56)
    previewBtn:SetPoint("LEFT", panel, "CENTER", -100, 0)
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

    -- ── Раздел: Масштаб (под превью, по центру, с запасом) ────────
    local scaleHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    scaleHeader:SetPoint("TOP", previewBtn, "BOTTOM", 0, -12)
    scaleHeader:SetText("Масштаб")

    local scaleLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    scaleLabel:SetPoint("TOP", scaleHeader, "BOTTOM", 0, -6)
    scaleLabel:SetText("1.0")

    local scaleSlider = CreateFrame("Slider", "MPTScaleSlider", panel)
    scaleSlider:SetPoint("TOP", scaleLabel, "BOTTOM", 0, -4)
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
        lockCheck:SetChecked(MPT.db and MPT.db.locked or false)
        debugCheck:SetChecked(MPT.db and MPT.db.debug or false)
        if recordCheck then
            recordCheck:SetChecked(MPT.db and (MPT.db.showBossRecord ~= false) or false)
        end
        affixTextCheck:SetChecked(MPT.db and MPT.db.affixText or false)
        affixIconsCheck:SetChecked(MPT.db and MPT.db.affixIcons or false)
        forcesBarCheck:SetChecked(MPT.db and MPT.db.forcesBar or false)
        autoKeystoneCheck:SetChecked(MPT.db and MPT.db.autoKeystone or false)
        reverseTimerCheck:SetChecked(MPT.db and MPT.db.reverseTimer or false)
        if hideDefaultTrackerCheck then
            hideDefaultTrackerCheck:SetChecked(MPT.db and MPT.db.hideDefaultTracker or false)
        end
        UpdateTexDropFromDB()
        UpdateFontDropFromDB()
        if forcesColorSwatch and forcesColorSwatch:IsShown() then
            local r, g, b = 0.25, 0.55, 1.0
            if MPT.db and MPT.db.forcesColor then
                local c = MPT.db.forcesColor
                if type(c.r) == "number" and type(c.g) == "number" and type(c.b) == "number" then
                    r, g, b = c.r, c.g, c.b
                end
            end
            forcesColorSwatch.tex:SetVertexColor(r, g, b)
        end

        local scale = (MPT.db and MPT.db.scale) or 1.0
        scaleLabel:SetText(string.format("%.1f", scale))
        scaleSlider:SetValue(scale)

        local timerFrame = _G["MPTTimerFrame"]
        local shown = timerFrame and timerFrame:IsShown()
        previewBtn:SetText(shown and "Скрыть превью" or "Показать превью")
    end)

    InterfaceOptions_AddCategory(panel)
end)
