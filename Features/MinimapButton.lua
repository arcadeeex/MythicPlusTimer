-- MythicPlusTimer: Minimap button

local MPT = MythicPlusTimer

local btn
local radius = 78
local dragging = false

local function EnsureMinimapDB()
    if not MPT.db then return nil end
    if type(MPT.db.minimap) ~= "table" then
        MPT.db.minimap = { hide = false, angle = 220 }
    end
    if type(MPT.db.minimap.hide) ~= "boolean" then
        MPT.db.minimap.hide = false
    end
    if type(MPT.db.minimap.angle) ~= "number" then
        MPT.db.minimap.angle = 220
    end
    return MPT.db.minimap
end

local function UpdatePosition()
    if not btn then return end
    local mm = EnsureMinimapDB()
    if not mm then return end
    local a = math.rad(mm.angle)
    local x = math.cos(a) * radius
    local y = math.sin(a) * radius
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function UpdateDragPosition()
    if not btn then return end
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local s = UIParent:GetScale()
    cx = cx / s
    cy = cy / s
    local angle = math.deg(math.atan2(cy - my, cx - mx))
    local mm = EnsureMinimapDB()
    if mm then
        mm.angle = angle
        UpdatePosition()
    end
end

function MPT:InitMinimapButton()
    if btn or not Minimap then return end
    local mm = EnsureMinimapDB()
    if not mm then return end

    btn = CreateFrame("Button", "MPTMinimapButton", Minimap)
    btn:SetSize(32, 32)
    btn:SetFrameStrata("MEDIUM")
    btn:SetMovable(false)
    btn:EnableMouse(true)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("RightButton")

    -- Use Blizzard minimap button framing to match standard circular icons.
    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetSize(20, 20)
    bg:SetPoint("CENTER", btn, "CENTER", 0, 0)

    local tex = btn:CreateTexture(nil, "ARTWORK")
    tex:SetTexture("Interface\\AddOns\\MythicPlusTimer\\Media\\minimap_m.blp")
    tex:SetSize(20, 20)
    tex:SetPoint("CENTER", btn, "CENTER", 0, 0)
    btn.icon = tex

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(54, 54)
    border:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)

    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:ClearLines()
        GameTooltip:AddLine("MythicPlus Timer", 1, 0.82, 0)
        GameTooltip:AddLine("ЛКМ: Открыть настройки", 1, 1, 1)
        GameTooltip:AddLine("ПКМ + drag: Переместить", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    btn:SetScript("OnClick", function(_, button)
        if button == "LeftButton" then
            if MPT.ToggleConfigWindow then
                MPT:ToggleConfigWindow()
            end
        end
    end)

    btn:SetScript("OnDragStart", function()
        dragging = true
        btn:SetScript("OnUpdate", UpdateDragPosition)
    end)
    btn:SetScript("OnDragStop", function()
        dragging = false
        btn:SetScript("OnUpdate", nil)
        UpdatePosition()
    end)

    if mm.hide then
        btn:Hide()
    else
        btn:Show()
    end
    UpdatePosition()
end

function MPT:SetMinimapButtonHidden(hidden)
    local mm = EnsureMinimapDB()
    if not mm then return end
    mm.hide = hidden and true or false
    if not btn then return end
    if mm.hide then btn:Hide() else btn:Show() end
end

function MPT:IsMinimapButtonHidden()
    local mm = EnsureMinimapDB()
    return mm and mm.hide or false
end
