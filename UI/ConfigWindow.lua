-- MythicPlusTimer: standalone config window (/mpt)

local MPT = MythicPlusTimer

local cfg
local contentScroll
local contentChild
local contentHeight = 460
local activeSection = "general"
local sectionFrames = {}

local styleDD
local textureDD
local fontDD
local scaleSlider
local scaleValue
local previewToggleBtn
local affixTextCheck
local affixIconsCheck
local reverseTimerAppearanceCheck
local forcesBarAppearanceCheck
local appearanceHint
local textureLabelRef
local fontLabelRef
local scaleHeaderRef

local generalChecks = {}
local colorRows = {}
local navButtons = {}
local dropdowns = {}

local THEME = {
    bg = { 0.03, 0.03, 0.03, 0.96 },
    panel = { 0.07, 0.07, 0.07, 0.92 },
    panel2 = { 0.10, 0.10, 0.10, 0.95 },
    border = { 0.20, 0.20, 0.20, 1.00 },
    text = { 0.95, 0.95, 0.95, 1.00 },
    yellow = { 1.00, 0.82, 0.00, 1.00 },
    muted = { 0.65, 0.65, 0.65, 1.00 },
}

local function clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

local function ApplyPanelStyle(frame, useAlt)
    frame:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        tile = false, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    local bg = useAlt and THEME.panel2 or THEME.panel
    frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])
    frame:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3], THEME.border[4])
end

local function StyleActionButton(btn)
    btn:SetNormalTexture("")
    btn:SetHighlightTexture("")
    btn:SetPushedTexture("")
    ApplyPanelStyle(btn, true)
    if btn.txt then
        btn.txt:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3], 1)
    end
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(THEME.yellow[1], THEME.yellow[2], THEME.yellow[3], 1)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3], 1)
    end)
end

local function CreateStyledButton(parent, width, height, text)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(width, height)
    btn.txt = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    btn.txt:SetPoint("CENTER", btn, "CENTER", 0, 0)
    btn.txt:SetText(text or "")
    btn.txt:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3], 1)
    StyleActionButton(btn)
    return btn
end

-- -----------------------------------------------------------------------------
-- Scrollable custom dropdown with optional preview renderer
-- -----------------------------------------------------------------------------
local DD_ITEM_H = 18
local DD_PADDING = 4

local function CreateMPTDropDown(parent, width, maxVisible, items, onSelect, renderRow, itemH)
    itemH = itemH or DD_ITEM_H

    local btn = CreateFrame("Button", nil, parent)
    btn:SetWidth(width)
    btn:SetHeight(22)
    ApplyPanelStyle(btn, true)

    local btnLabel = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    btnLabel:SetPoint("LEFT", btn, "LEFT", 8, 0)
    btnLabel:SetPoint("RIGHT", btn, "RIGHT", -18, 0)
    btnLabel:SetJustifyH("LEFT")
    btnLabel:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3], 1)
    btnLabel:SetText("—")

    local arrow = btn:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
    arrow:SetWidth(10)
    arrow:SetHeight(10)
    arrow:SetPoint("RIGHT", btn, "RIGHT", -6, 0)
    arrow:SetVertexColor(THEME.yellow[1], THEME.yellow[2], THEME.yellow[3], 1)

    local popup = CreateFrame("Frame", nil, UIParent)
    popup:SetWidth(width + 20)
    popup:SetFrameStrata("TOOLTIP")
    popup:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        tile = false, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    popup:SetBackdropColor(THEME.panel2[1], THEME.panel2[2], THEME.panel2[3], 0.98)
    popup:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3], 1)
    popup:Hide()

    local clip = CreateFrame("Frame", nil, popup)
    clip:SetPoint("TOPLEFT", popup, "TOPLEFT", DD_PADDING, -DD_PADDING)
    clip:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -DD_PADDING - 16, DD_PADDING)

    local rowBtns = {}
    for i = 1, maxVisible do
        local row = CreateFrame("Button", nil, clip)
        row:SetHeight(itemH)
        row:SetPoint("LEFT", clip, "LEFT", 0, 0)
        row:SetPoint("RIGHT", clip, "RIGHT", 0, 0)

        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        hl:SetVertexColor(THEME.yellow[1], THEME.yellow[2], THEME.yellow[3], 0.15)

        local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl:SetPoint("LEFT", row, "LEFT", 4, 0)
        lbl:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        lbl:SetJustifyH("LEFT")
        row.lbl = lbl
        rowBtns[i] = row
    end

    local currentItems = items or {}
    local selectedValue = nil
    local selectedText = "—"
    local scrollOffset = 0

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
            row:ClearAllPoints()
            row:SetPoint("LEFT", clip, "LEFT", 0, 0)
            row:SetPoint("RIGHT", clip, "RIGHT", 0, 0)
            row:SetPoint("TOP", clip, "TOP", 0, -(i - 1) * itemH)
            if idx <= total then
                local item = currentItems[idx]
                row.lbl:SetText(item.name or "")
                row.lbl:SetFont("Fonts\\FRIZQT__.TTF", 12, "")
                if renderRow then renderRow(row, item) end
                if item.value == selectedValue then
                    row.lbl:SetTextColor(1, 0.82, 0)
                else
                    row.lbl:SetTextColor(1, 1, 1)
                end
                row:SetScript("OnClick", function()
                    selectedValue = item.value
                    selectedText = item.name or tostring(item.value or "")
                    btnLabel:SetText(selectedText)
                    popup:Hide()
                    if onSelect then onSelect(item) end
                end)
                row:Show()
            else
                row:Hide()
            end
        end

        if popup.scrollBar then
            local maxOff = math.max(0, total - maxVisible)
            if total > maxVisible then
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

    local scrollBar = CreateFrame("Slider", nil, popup)
    scrollBar:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -3, -3)
    scrollBar:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -3, 3)
    scrollBar:SetWidth(12)
    ApplyPanelStyle(scrollBar, true)
    scrollBar:SetMinMaxValues(0, 0)
    scrollBar:SetValueStep(1)
    scrollBar:SetThumbTexture("Interface\\BUTTONS\\WHITE8X8")
    local thumb = scrollBar:GetThumbTexture()
    if thumb then
        thumb:SetWidth(8)
        thumb:SetHeight(24)
        thumb:SetVertexColor(THEME.yellow[1], THEME.yellow[2], THEME.yellow[3], 0.95)
    end
    scrollBar:SetScript("OnValueChanged", function(_, value)
        value = math.floor(value + 0.5)
        if value ~= scrollOffset then
            scrollOffset = value
            updateRows()
        end
    end)
    popup.scrollBar = scrollBar

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
            return
        end
        local visible = math.min(#currentItems, maxVisible)
        local innerH = visible * itemH
        popup:SetHeight(innerH + DD_PADDING * 2)
        clip:SetHeight(innerH)
        popup:ClearAllPoints()
        popup:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
        scrollOffset = 0
        updateRows()
        popup:Show()
        if popup:GetBottom() and popup:GetBottom() < 0 then
            popup:ClearAllPoints()
            popup:SetPoint("BOTTOMLEFT", btn, "TOPLEFT", 0, 2)
        end
    end)

    local dd = {}

    function dd.setItems(newItems)
        currentItems = newItems or {}
        scrollOffset = 0
        if popup:IsShown() then updateRows() end
    end

    function dd.setValue(value, displayName)
        selectedValue = value
        selectedText = displayName or tostring(value or "—")
        for _, item in ipairs(currentItems) do
            if item.value == value then
                selectedText = item.name
                break
            end
        end
        btnLabel:SetText(selectedText)
        if popup:IsShown() then updateRows() end
    end

    function dd.getSelectedValue()
        return selectedValue
    end

    dd.button = btn
    dd.popup = popup
    dd.label = btnLabel
    dropdowns[#dropdowns + 1] = dd
    return dd
end

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------
local function UpdateContentHeight(h)
    local target = h or contentHeight
    if target < contentHeight then target = contentHeight end
    contentChild:SetHeight(target)
    contentScroll:SetVerticalScroll(0)
end

local function IsTimerVisible()
    local timerFrame = _G["MPTTimerFrame"]
    return timerFrame and timerFrame:IsShown() or false
end

local function UpdatePreviewButtonText()
    if not previewToggleBtn or not previewToggleBtn.txt then return end
    if IsTimerVisible() then
        previewToggleBtn.txt:SetText("Скрыть превью")
    else
        previewToggleBtn.txt:SetText("Показать превью")
    end
end

local function GetStyleOption(key, fallback)
    if MPT.GetStyleOption then
        return MPT:GetStyleOption(key, fallback)
    end
    if MPT.db and MPT.db[key] ~= nil then
        return MPT.db[key]
    end
    return fallback
end

local function SetStyleOption(key, value)
    if MPT.SetStyleOption then
        MPT:SetStyleOption(key, value)
        return
    end
    if MPT.db then
        MPT.db[key] = value
    end
end

local function ShowSection(id)
    for _, dd in ipairs(dropdowns) do
        if dd and dd.popup and dd.popup:IsShown() then
            dd.popup:Hide()
        end
    end
    activeSection = id
    for sid, f in pairs(sectionFrames) do
        if sid == id then
            f:Show()
        else
            f:Hide()
        end
    end
    local sf = sectionFrames[id]
    if sf and sf.contentHeight then
        sf:SetHeight(sf.contentHeight)
    end
    UpdateContentHeight(sf and sf.contentHeight or contentHeight)
    for sid, b in pairs(navButtons) do
        if sid == id then
            b.txt:SetTextColor(THEME.yellow[1], THEME.yellow[2], THEME.yellow[3], 1)
            b:SetBackdropBorderColor(THEME.yellow[1], THEME.yellow[2], THEME.yellow[3], 1)
        else
            b.txt:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3], 1)
            b:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3], 1)
        end
    end
end

local function CreateCheck(parent, label, key, y, onApply, styleSpecific)
    local cb = CreateFrame("CheckButton", nil, parent)
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, y)
    cb:SetSize(22, 22)
    local box = CreateFrame("Frame", nil, cb)
    box:SetPoint("LEFT", cb, "LEFT", 0, 0)
    box:SetSize(18, 18)
    ApplyPanelStyle(box, true)
    cb.box = box

    local mark = box:CreateTexture(nil, "ARTWORK")
    mark:SetAllPoints(box)
    mark:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    mark:SetVertexColor(THEME.yellow[1], THEME.yellow[2], THEME.yellow[3], 1)
    mark:Hide()
    cb.mark = mark

    local txt = cb:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    txt:SetPoint("LEFT", box, "RIGHT", 6, 0)
    txt:SetText(label)
    txt:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3], 1)
    cb.txt = txt
    cb.key = key

    cb:SetChecked(false)
    cb:SetScript("OnShow", function(self)
        self.mark:SetShown(self:GetChecked() and true or false)
    end)
    cb:SetScript("OnClick", function(self)
        local v = (self:GetChecked() == 1 or self:GetChecked() == true)
        self.mark:SetShown(v)
        if styleSpecific then
            SetStyleOption(key, v)
        elseif MPT.db then
            MPT.db[key] = v
        end
        if onApply then onApply(v) end
    end)
    return cb
end

-- -----------------------------------------------------------------------------
-- Sections
-- -----------------------------------------------------------------------------
local function BuildAppearanceSection()
    local frame = CreateFrame("Frame", nil, contentChild)
    frame:SetPoint("TOPLEFT", contentChild, "TOPLEFT", 0, 0)
    frame:SetPoint("TOPRIGHT", contentChild, "TOPRIGHT", 0, 0)
    frame:SetHeight(330)
    sectionFrames.appearance = frame

    local header = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -10)
    header:SetText("Стиль и отображение")
    header:SetTextColor(THEME.yellow[1], THEME.yellow[2], THEME.yellow[3], 1)

    reverseTimerAppearanceCheck = CreateCheck(frame, "Обратный таймер", "reverseTimer", -34, function()
        if MPT.IsPreviewActive and MPT:IsPreviewActive() and MPT.ShowPreview then MPT:ShowPreview() end
    end)
    forcesBarAppearanceCheck = CreateCheck(frame, "Показывать процент прогресс баром", "forcesBar", -74, function()
        if MPT.RefreshForcesMode then MPT:RefreshForcesMode() end
    end)

    affixTextCheck = CreateCheck(frame, "Показывать аффиксы текстом", "affixText", -114, function(v)
        SetStyleOption("affixText", v)
        if MPT.RefreshCurrentAffixes then MPT:RefreshCurrentAffixes() end
    end, true)
    affixIconsCheck = CreateCheck(frame, "Показывать аффиксы иконками", "affixIcons", -154, function(v)
        SetStyleOption("affixIcons", v)
        if MPT.RefreshCurrentAffixes then MPT:RefreshCurrentAffixes() end
    end, true)

    local textureLabel = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    textureLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -194)
    textureLabel:SetText("Текстура")
    textureLabel:SetTextColor(THEME.yellow[1], THEME.yellow[2], THEME.yellow[3], 1)
    textureLabelRef = textureLabel

    textureDD = CreateMPTDropDown(frame, 300, 10, {}, function(item)
        SetStyleOption("forcesTexture", item.value)
        if MPT.RefreshForcesTexture then MPT:RefreshForcesTexture() end
    end, function(row, item)
        if not row._texBar then
            row._texBar = row:CreateTexture(nil, "ARTWORK")
            row._texBar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 4, 2)
            row._texBar:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4, 2)
            row._texBar:SetHeight(6)
            row.lbl:ClearAllPoints()
            row.lbl:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -1)
            row.lbl:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -1)
            row.lbl:SetHeight(13)
        end
        if item.path then
            row._texBar:SetTexture(item.path)
            row._texBar:SetVertexColor(1, 1, 1, 1)
            row._texBar:Show()
        else
            row._texBar:Hide()
        end
    end, 24)
    textureDD.button:SetPoint("TOPLEFT", textureLabel, "BOTTOMLEFT", 0, -4)

    local fontLabel = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fontLabel:SetPoint("TOPLEFT", textureDD.button, "BOTTOMLEFT", 0, -12)
    fontLabel:SetText("Шрифт")
    fontLabel:SetTextColor(THEME.yellow[1], THEME.yellow[2], THEME.yellow[3], 1)
    fontLabelRef = fontLabel

    fontDD = CreateMPTDropDown(frame, 300, 12, {}, function(item)
        SetStyleOption("font", item.value)
        if MPT.RefreshFont then MPT:RefreshFont() end
    end, function(row, item)
        row.lbl:SetFont("Fonts\\FRIZQT__.TTF", 12, "")
        if item.path then
            row.lbl:SetFont(item.path, 12, "")
        end
    end, 20)
    fontDD.button:SetPoint("TOPLEFT", fontLabel, "BOTTOMLEFT", 0, -4)

    local scaleHeader = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    scaleHeader:SetPoint("TOPLEFT", fontDD.button, "BOTTOMLEFT", 0, -16)
    scaleHeader:SetText("Масштаб таймера")
    scaleHeader:SetTextColor(THEME.yellow[1], THEME.yellow[2], THEME.yellow[3], 1)
    scaleHeaderRef = scaleHeader

    scaleSlider = CreateFrame("Slider", nil, frame)
    scaleSlider:SetPoint("TOPLEFT", scaleHeader, "BOTTOMLEFT", 0, -8)
    scaleSlider:SetWidth(260)
    scaleSlider:SetHeight(16)
    scaleSlider:SetOrientation("HORIZONTAL")
    scaleSlider:SetMinMaxValues(0.5, 2.0)
    scaleSlider:SetValueStep(0.1)
    scaleSlider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    scaleSlider:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
        edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 3, right = 3, top = 6, bottom = 6 },
    })
    scaleSlider:SetScript("OnValueChanged", function(_, value)
        value = math.floor(value * 10 + 0.5) / 10
        SetStyleOption("scale", value)
        if scaleValue then scaleValue:SetText(string.format("%.1f", value)) end
        local timerFrame = _G["MPTTimerFrame"]
        if timerFrame then timerFrame:SetScale(value) end
    end)

    scaleValue = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    scaleValue:SetPoint("LEFT", scaleSlider, "RIGHT", 10, 0)
    appearanceHint = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    appearanceHint:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -194)
    appearanceHint:SetTextColor(THEME.muted[1], THEME.muted[2], THEME.muted[3], 1)
    appearanceHint:SetText("Для этого стиля дополнительные настройки пока не добавлены.")
    appearanceHint:Hide()

    frame.contentHeight = 430
    frame:SetHeight(frame.contentHeight)
end

local function BuildGeneralSection()
    local frame = CreateFrame("Frame", nil, contentChild)
    frame:SetPoint("TOPLEFT", contentChild, "TOPLEFT", 0, 0)
    frame:SetPoint("TOPRIGHT", contentChild, "TOPRIGHT", 0, 0)
    frame:SetHeight(400)
    sectionFrames.general = frame

    local header = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -10)
    header:SetText("Общие настройки")
    header:SetTextColor(THEME.yellow[1], THEME.yellow[2], THEME.yellow[3], 1)

    local rows = {
        { label = "Закрепить окно", key = "locked" },
        { label = "Показывать рекорд подземелья", key = "showBossRecord", onApply = function()
            if MPT.IsPreviewActive and MPT:IsPreviewActive() and MPT.ShowPreview then MPT:ShowPreview() end
        end },
        { label = "Вставлять ключ автоматически", key = "autoKeystone" },
        { label = "Скрывать стандартный интерфейс", key = "hideDefaultTracker", onApply = function()
            if MPT.ApplyDefaultTrackerVisibility then MPT:ApplyDefaultTrackerVisibility() end
        end },
        { label = "Показывать % в тултипе NPC", key = "showForcesInTooltip" },
        { label = "Показывать % за спуленный пак", key = "showForcesPullPct", onApply = function()
            if MPT.IsPreviewActive and MPT:IsPreviewActive() and MPT.ShowPreview then MPT:ShowPreview() end
        end },
    }

    local y = -34
    local lastRowY = -34
    for i, row in ipairs(rows) do
        local cb = CreateCheck(frame, row.label, row.key, y, row.onApply)
        generalChecks[i] = cb
        lastRowY = y
        y = y - 40
    end

    -- под последним чекбоксом (высота чекбокса ~22, отступ 10)
    local resetBtnY = lastRowY - 22 - 10
    local resetLearnedBtn = CreateStyledButton(frame, 260, 28, "Сбросить выученные %")
    resetLearnedBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, resetBtnY)
    resetLearnedBtn:SetScript("OnClick", function()
        if MPT.db then
            MPT.db.learnedForces = {}
            if MPT.Print then
                MPT:Print("Выученные проценты NPC сброшены (используется статическая база).")
            end
        end
    end)
    resetLearnedBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Сбросить выученные %", 1, 1, 1)
        GameTooltip:AddLine(
            "Очищает learnedForces в сохранённых настройках: автоматически накопленные проценты за мобов. Статическая база аддона не меняется.",
            0.8, 0.8, 0.8,
            true
        )
        GameTooltip:Show()
    end)
    resetLearnedBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    frame.contentHeight = math.max(380, math.abs(resetBtnY) + 28 + 24)
    frame:SetHeight(frame.contentHeight)
end

local function BuildColorsSection()
    local frame = CreateFrame("Frame", nil, contentChild)
    frame:SetPoint("TOPLEFT", contentChild, "TOPLEFT", 0, 0)
    frame:SetPoint("TOPRIGHT", contentChild, "TOPRIGHT", 0, 0)
    frame:SetHeight(400)
    sectionFrames.colors = frame

    local header = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -10)
    header:SetText("Цвета активного стиля")
    header:SetTextColor(THEME.yellow[1], THEME.yellow[2], THEME.yellow[3], 1)

    local function rebuildRows()
        local schema = MPT:GetActiveStyleColorSchema()
        local rowH = 32
        for _, row in ipairs(colorRows) do row:Hide() end
        for i, opt in ipairs(schema) do
            local row = colorRows[i]
            if not row then
                row = CreateFrame("Button", nil, frame)
                row:SetSize(460, rowH)
                local sw = CreateFrame("Button", nil, row)
                sw:SetSize(30, 22)
                sw:SetPoint("LEFT", row, "LEFT", 0, 0)
                local border = sw:CreateTexture(nil, "BORDER")
                border:SetAllPoints()
                border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
                local tex = sw:CreateTexture(nil, "ARTWORK")
                tex:SetPoint("TOPLEFT", 5, -5)
                tex:SetPoint("BOTTOMRIGHT", -5, 5)
                tex:SetTexture("Interface\\BUTTONS\\WHITE8X8")
                row.tex = tex
                row.sw = sw

                local lbl = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
                lbl:SetPoint("LEFT", sw, "RIGHT", 8, 0)
                lbl:SetPoint("RIGHT", row, "RIGHT", 0, 0)
                lbl:SetJustifyH("LEFT")
                lbl:SetFont("Fonts\\FRIZQT__.TTF", 14, "")
                row.lbl = lbl

                row.sw:SetScript("OnClick", function()
                    if not row.key or not ColorPickerFrame then return end
                    local key = row.key
                    local r, g, b = MPT:GetStyleColor(key, MPT.COLOR_DEFAULTS and MPT.COLOR_DEFAULTS[key] or nil)
                    local function applyColor(nr, ng, nb)
                        MPT:SetStyleColor(key, clamp01(nr), clamp01(ng), clamp01(nb))
                        if MPT.RefreshAllColors then MPT:RefreshAllColors() end
                        if MPT.IsPreviewActive and MPT:IsPreviewActive() and MPT.ShowPreview then
                            MPT:ShowPreview()
                        end
                        row.tex:SetVertexColor(clamp01(nr), clamp01(ng), clamp01(nb))
                    end
                    ColorPickerFrame.func = function()
                        local nr, ng, nb = ColorPickerFrame:GetColorRGB()
                        applyColor(nr, ng, nb)
                    end
                    ColorPickerFrame.hasOpacity = false
                    ColorPickerFrame.previousValues = { r, g, b }
                    ColorPickerFrame.cancelFunc = function(prev)
                        local pr, pg, pb = unpack(prev or ColorPickerFrame.previousValues)
                        applyColor(pr, pg, pb)
                    end
                    ColorPickerFrame:SetColorRGB(r, g, b)
                    ColorPickerFrame:Hide()
                    ColorPickerFrame:Show()
                end)
                colorRows[i] = row
            end

            row.key = opt.key
            row.lbl:SetText(opt.label or opt.key)
            local r, g, b = MPT:GetStyleColor(opt.key, MPT.COLOR_DEFAULTS and MPT.COLOR_DEFAULTS[opt.key] or nil)
            row.tex:SetVertexColor(r, g, b)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -40 - (i - 1) * rowH)
            row:Show()
        end

        local resetY = -46 - (#schema * rowH)
        if not frame.resetBtn then
            local btn = CreateStyledButton(frame, 260, 24, "Сбросить цвета активного стиля")
            btn:SetScript("OnClick", function()
                MPT:ResetActiveStyleColors()
                rebuildRows()
                MPT:Print("Цвета активного стиля сброшены.")
            end)
            frame.resetBtn = btn
        end
        frame.resetBtn:ClearAllPoints()
        frame.resetBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, resetY)
        frame.resetBtn:SetShown(#schema > 0)
        frame.contentHeight = math.max(360, (-resetY) + 50)
        frame:SetHeight(frame.contentHeight)
        if activeSection == "colors" then
            UpdateContentHeight(frame.contentHeight)
        end
    end

    frame.rebuildRows = rebuildRows
    rebuildRows()
end

local function RefreshSections()
    -- Appearance dropdown values and preview lists
    if styleDD then
        local styleItems = {}
        for _, s in ipairs(MPT:GetStyleList() or {}) do
            styleItems[#styleItems + 1] = { name = s.label or s.id, value = s.id }
        end
        styleDD.setItems(styleItems)
        local id = MPT:GetActiveStyleId() or "default"
        styleDD.setValue(id, id)
    end
    if textureDD then
        local texItems = {}
        for _, t in ipairs(MPT.BAR_TEXTURES or {}) do
            texItems[#texItems + 1] = { name = t.name, value = t.name, path = t.path }
        end
        textureDD.setItems(texItems)
        textureDD.setValue(GetStyleOption("forcesTexture", "Blank"))
    end
    if fontDD then
        local fontItems = {}
        for _, f in ipairs(MPT.FONTS or {}) do
            fontItems[#fontItems + 1] = { name = f.name, value = f.name, path = f.path }
        end
        fontDD.setItems(fontItems)
        fontDD.setValue(GetStyleOption("font", "Friz Quadrata (default)"))
    end
    if scaleSlider and scaleValue then
        local scale = GetStyleOption("scale", 1.0)
        scaleSlider:SetValue(scale)
        scaleValue:SetText(string.format("%.1f", scale))
    end
    local schema = MPT.GetActiveStyleOptionsSchema and MPT:GetActiveStyleOptionsSchema() or {}
    local activeStyleId = (MPT.GetActiveStyleId and MPT:GetActiveStyleId()) or (MPT.db and MPT.db.activeStyle) or "default"
    local showDefaultOnly = (activeStyleId == "default")
    local has = {}
    for _, opt in ipairs(schema) do
        has[opt.key] = true
    end
    local hasAny = next(has) ~= nil
    if textureDD and textureDD.button then textureDD.button:SetShown(has.forcesTexture == true) end
    if textureLabelRef then textureLabelRef:SetShown(has.forcesTexture == true) end
    if fontDD and fontDD.button then fontDD.button:SetShown(has.font == true) end
    if fontLabelRef then fontLabelRef:SetShown(has.font == true) end
    if scaleSlider then scaleSlider:SetShown(has.scale == true) end
    if scaleValue then scaleValue:SetShown(has.scale == true) end
    if scaleHeaderRef then scaleHeaderRef:SetShown(has.scale == true) end
    if reverseTimerAppearanceCheck then reverseTimerAppearanceCheck:SetShown(showDefaultOnly) end
    if forcesBarAppearanceCheck then forcesBarAppearanceCheck:SetShown(showDefaultOnly) end
    if affixTextCheck then affixTextCheck:SetShown(has.affixText == true) end
    if affixIconsCheck then affixIconsCheck:SetShown(has.affixIcons == true) end
    if appearanceHint then appearanceHint:SetShown((not hasAny) and (not showDefaultOnly)) end

    -- Reflow appearance controls so visible items always start at top.
    local ap = sectionFrames.appearance
    if ap then
        local y = -34
        local function placeCheck(cb)
            if cb and cb:IsShown() then
                cb:ClearAllPoints()
                cb:SetPoint("TOPLEFT", ap, "TOPLEFT", 10, y)
                y = y - 40
            end
        end
        placeCheck(reverseTimerAppearanceCheck)
        placeCheck(forcesBarAppearanceCheck)
        placeCheck(affixTextCheck)
        placeCheck(affixIconsCheck)

        local function placeDropdown(label, dd)
            if label and dd and dd.button and label:IsShown() and dd.button:IsShown() then
                label:ClearAllPoints()
                label:SetPoint("TOPLEFT", ap, "TOPLEFT", 10, y)
                dd.button:ClearAllPoints()
                dd.button:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -4)
                y = y - 56
            end
        end
        placeDropdown(textureLabelRef, textureDD)
        placeDropdown(fontLabelRef, fontDD)

        if scaleHeaderRef and scaleSlider and scaleHeaderRef:IsShown() and scaleSlider:IsShown() then
            scaleHeaderRef:ClearAllPoints()
            scaleHeaderRef:SetPoint("TOPLEFT", ap, "TOPLEFT", 10, y)
            scaleSlider:ClearAllPoints()
            scaleSlider:SetPoint("TOPLEFT", scaleHeaderRef, "BOTTOMLEFT", 0, -8)
            if scaleValue then
                scaleValue:ClearAllPoints()
                scaleValue:SetPoint("LEFT", scaleSlider, "RIGHT", 10, 0)
            end
            y = y - 60
        end

        if appearanceHint and appearanceHint:IsShown() then
            appearanceHint:ClearAllPoints()
            appearanceHint:SetPoint("TOPLEFT", ap, "TOPLEFT", 10, y)
            y = y - 30
        end

        ap.contentHeight = math.max(340, -y + 40)
        ap:SetHeight(ap.contentHeight)
        if activeSection == "appearance" then
            UpdateContentHeight(ap.contentHeight)
        end
    end

    if affixTextCheck and has.affixText then
        local v = GetStyleOption("affixText", true)
        affixTextCheck:SetChecked(v)
        if affixTextCheck.mark then affixTextCheck.mark:SetShown(v and true or false) end
    end
    if affixIconsCheck and has.affixIcons then
        local v = GetStyleOption("affixIcons", false)
        affixIconsCheck:SetChecked(v)
        if affixIconsCheck.mark then affixIconsCheck.mark:SetShown(v and true or false) end
    end
    UpdatePreviewButtonText()

    -- General checkboxes
    for _, cb in ipairs(generalChecks) do
        if cb and cb.key then
            local v = MPT.db and MPT.db[cb.key] or false
            cb:SetChecked(v)
            if cb.mark then cb.mark:SetShown(v and true or false) end
        end
    end
    if reverseTimerAppearanceCheck then
        local v = MPT.db and MPT.db.reverseTimer or false
        reverseTimerAppearanceCheck:SetChecked(v)
        if reverseTimerAppearanceCheck.mark then reverseTimerAppearanceCheck.mark:SetShown(v and true or false) end
    end
    if forcesBarAppearanceCheck then
        local v = MPT.db and MPT.db.forcesBar or false
        forcesBarAppearanceCheck:SetChecked(v)
        if forcesBarAppearanceCheck.mark then forcesBarAppearanceCheck.mark:SetShown(v and true or false) end
    end

    -- Colors
    if sectionFrames.colors and sectionFrames.colors.rebuildRows then
        sectionFrames.colors.rebuildRows()
    end
end

-- -----------------------------------------------------------------------------
-- Window
-- -----------------------------------------------------------------------------
local function CreateWindow()
    if cfg then return end

    cfg = CreateFrame("Frame", "MPTConfigWindow", UIParent)
    cfg:SetSize(760, 560)
    cfg:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    cfg:SetFrameStrata("DIALOG")
    cfg:SetMovable(true)
    cfg:EnableMouse(true)
    cfg:RegisterForDrag("LeftButton")
    cfg:SetScript("OnDragStart", function(self) self:StartMoving() end)
    cfg:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    cfg:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        tile = false, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    cfg:SetBackdropColor(THEME.bg[1], THEME.bg[2], THEME.bg[3], THEME.bg[4])
    cfg:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3], 1)
    cfg:Hide()

    local title = cfg:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", cfg, "TOPLEFT", 16, -16)
    title:SetText("Mythic Plus Timer")
    title:SetTextColor(THEME.yellow[1], THEME.yellow[2], THEME.yellow[3], 1)

    local styleTopLabel = cfg:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    styleTopLabel:SetPoint("TOPLEFT", cfg, "TOPLEFT", 214, -18)
    styleTopLabel:SetText("Стиль")
    styleTopLabel:SetTextColor(THEME.yellow[1], THEME.yellow[2], THEME.yellow[3], 1)

    styleDD = CreateMPTDropDown(cfg, 170, 8, {}, function(item)
        MPT:ApplyStyle(item.value)
        MPT:RefreshConfigWindow()
    end)
    styleDD.button:SetPoint("LEFT", styleTopLabel, "RIGHT", 8, 0)

    previewToggleBtn = CreateStyledButton(cfg, 150, 22, "Показать превью")
    previewToggleBtn:SetPoint("LEFT", styleDD.button, "RIGHT", 8, 0)
    previewToggleBtn:SetScript("OnClick", function()
        local timerFrame = _G["MPTTimerFrame"]
        if timerFrame and timerFrame:IsShown() then
            timerFrame:Hide()
        else
            if MPT.ShowPreview then MPT:ShowPreview() end
        end
        UpdatePreviewButtonText()
    end)

    local close = CreateFrame("Button", nil, cfg, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", cfg, "TOPRIGHT", -6, -6)

    local nav = CreateFrame("Frame", nil, cfg)
    nav:SetPoint("TOPLEFT", cfg, "TOPLEFT", 14, -44)
    nav:SetSize(180, 500)
    ApplyPanelStyle(nav, false)

    local navHeader = nav:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    navHeader:SetPoint("TOPLEFT", nav, "TOPLEFT", 4, -4)
    navHeader:SetText("Разделы")
    navHeader:SetTextColor(THEME.yellow[1], THEME.yellow[2], THEME.yellow[3], 1)

    local function addNavButton(id, text, y)
        local b = CreateFrame("Button", nil, nav)
        b:SetSize(168, 24)
        b:SetPoint("TOPLEFT", nav, "TOPLEFT", 4, y)
        ApplyPanelStyle(b, true)
        local txt = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        txt:SetPoint("CENTER", b, "CENTER", 0, 0)
        txt:SetText(text)
        txt:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3], 1)
        b.txt = txt
        b:SetScript("OnClick", function() ShowSection(id) end)
        b:SetScript("OnEnter", function(self)
            if activeSection ~= id then
                self:SetBackdropBorderColor(THEME.yellow[1], THEME.yellow[2], THEME.yellow[3], 0.6)
            end
        end)
        b:SetScript("OnLeave", function(self)
            if activeSection ~= id then
                self:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3], 1)
            end
        end)
        navButtons[id] = b
        return b
    end

    addNavButton("general", "Общие", -28)
    addNavButton("appearance", "Стиль и отображение", -56)
    addNavButton("colors", "Цвета", -84)

    local contentWrap = CreateFrame("Frame", nil, cfg)
    contentWrap:SetPoint("TOPLEFT", cfg, "TOPLEFT", 204, -44)
    contentWrap:SetSize(540, 500)
    ApplyPanelStyle(contentWrap, false)

    contentScroll = CreateFrame("ScrollFrame", nil, contentWrap)
    contentScroll:SetPoint("TOPLEFT", contentWrap, "TOPLEFT", 0, 0)
    contentScroll:SetPoint("BOTTOMRIGHT", contentWrap, "BOTTOMRIGHT", -20, 0)
    contentScroll:EnableMouseWheel(true)
    contentScroll:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local maxV = self:GetVerticalScrollRange()
        local nextV = cur - delta * 24
        if nextV < 0 then nextV = 0 end
        if nextV > maxV then nextV = maxV end
        self:SetVerticalScroll(nextV)
    end)

    contentChild = CreateFrame("Frame", nil, contentScroll)
    contentChild:SetWidth(510)
    contentChild:SetHeight(contentHeight)
    contentScroll:SetScrollChild(contentChild)

    local scrollWrap = CreateFrame("Frame", nil, contentWrap)
    scrollWrap:SetPoint("TOPLEFT", contentScroll, "TOPRIGHT", 4, 0)
    scrollWrap:SetPoint("BOTTOMLEFT", contentScroll, "BOTTOMRIGHT", 4, 0)
    scrollWrap:SetWidth(14)
    ApplyPanelStyle(scrollWrap, true)

    local upBtn = CreateStyledButton(scrollWrap, 14, 14, "")
    upBtn:SetPoint("TOPLEFT", scrollWrap, "TOPLEFT", 0, 0)
    local upTex = upBtn:CreateTexture(nil, "OVERLAY")
    upTex:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
    upTex:SetSize(8, 8)
    upTex:SetPoint("CENTER", upBtn, "CENTER", 0, 0)
    upTex:SetTexCoord(0, 1, 1, 0)
    upTex:SetVertexColor(THEME.text[1], THEME.text[2], THEME.text[3], 1)

    local downBtn = CreateStyledButton(scrollWrap, 14, 14, "")
    downBtn:SetPoint("BOTTOMLEFT", scrollWrap, "BOTTOMLEFT", 0, 0)
    local downTex = downBtn:CreateTexture(nil, "OVERLAY")
    downTex:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
    downTex:SetSize(8, 8)
    downTex:SetPoint("CENTER", downBtn, "CENTER", 0, 0)
    downTex:SetVertexColor(THEME.text[1], THEME.text[2], THEME.text[3], 1)

    local scrollBar = CreateFrame("Slider", nil, scrollWrap)
    scrollBar:SetPoint("TOPLEFT", upBtn, "BOTTOMLEFT", 0, -2)
    scrollBar:SetPoint("BOTTOMLEFT", downBtn, "TOPLEFT", 0, 2)
    scrollBar:SetWidth(14)
    ApplyPanelStyle(scrollBar, false)
    scrollBar:SetMinMaxValues(0, 0)
    scrollBar:SetValueStep(1)
    scrollBar.scrollStep = 24
    scrollBar:SetThumbTexture("Interface\\BUTTONS\\WHITE8X8")
    local scrollThumb = scrollBar:GetThumbTexture()
    if scrollThumb then
        scrollThumb:SetWidth(10)
        scrollThumb:SetHeight(24)
        scrollThumb:SetVertexColor(0.60, 0.60, 0.60, 0.95)
    end

    local syncLock = false
    local function SetScrollValue(v)
        if syncLock then return end
        syncLock = true
        local maxVal = contentScroll:GetVerticalScrollRange() or 0
        if v < 0 then v = 0 end
        if v > maxVal then v = maxVal end
        contentScroll:SetVerticalScroll(v)
        scrollBar:SetValue(v)
        syncLock = false
    end

    scrollBar:SetScript("OnValueChanged", function(_, value)
        if syncLock then return end
        SetScrollValue(value)
    end)
    upBtn:SetScript("OnClick", function()
        SetScrollValue((contentScroll:GetVerticalScroll() or 0) - (scrollBar.scrollStep or 24))
    end)
    downBtn:SetScript("OnClick", function()
        SetScrollValue((contentScroll:GetVerticalScroll() or 0) + (scrollBar.scrollStep or 24))
    end)
    contentScroll:SetScript("OnScrollRangeChanged", function(_, _, yRange)
        local maxVal = yRange or 0
        scrollBar:SetMinMaxValues(0, maxVal)
        if maxVal > 0 then
            scrollWrap:Show()
        else
            scrollWrap:Hide()
        end
        SetScrollValue(contentScroll:GetVerticalScroll() or 0)
    end)
    contentScroll:SetScript("OnVerticalScroll", function(self, offset)
        if syncLock then return end
        syncLock = true
        scrollBar:SetValue(offset)
        syncLock = false
    end)
    contentScroll:SetScript("OnMouseWheel", function(_, delta)
        SetScrollValue((contentScroll:GetVerticalScroll() or 0) - delta * (scrollBar.scrollStep or 24))
    end)
    SetScrollValue(0)

    BuildAppearanceSection()
    BuildGeneralSection()
    BuildColorsSection()
    ShowSection("general")

    cfg:SetScript("OnShow", function()
        if MPT.RefreshMediaLists then MPT:RefreshMediaLists() end
        RefreshSections()
        ShowSection(activeSection or "general")
    end)
    cfg:SetScript("OnHide", function()
        for _, dd in ipairs(dropdowns) do
            if dd and dd.popup and dd.popup:IsShown() then
                dd.popup:Hide()
            end
        end
    end)
end

function MPT:RefreshConfigWindow()
    if not cfg then return end
    RefreshSections()
    ShowSection(activeSection or "general")
end

function MPT:ShowConfigWindow()
    if not cfg then CreateWindow() end
    cfg:Show()
    self:RefreshConfigWindow()
end

function MPT:HideConfigWindow()
    if cfg then cfg:Hide() end
end

function MPT:ToggleConfigWindow()
    if not cfg then CreateWindow() end
    if cfg:IsShown() then
        cfg:Hide()
    else
        cfg:Show()
        self:RefreshConfigWindow()
    end
end

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")
    if MPT.RefreshMediaLists then MPT:RefreshMediaLists() end
end)
