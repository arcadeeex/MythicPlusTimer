-- MythicPlusTimer: StyleRegistry
-- Реестр визуальных стилей и доступ к style-specific настройкам/цветам.

local MPT = MythicPlusTimer

local styles = {}
local styleOrder = {}
local activeStyleId = "default"

local function cloneColor(c)
    return { r = c.r, g = c.g, b = c.b }
end

local function getStyleStore(styleId, create)
    if not MPT.db then return nil end
    if type(MPT.db.styles) ~= "table" then
        if not create then return nil end
        MPT.db.styles = {}
    end
    if type(MPT.db.styles[styleId]) ~= "table" then
        if not create then return nil end
        MPT.db.styles[styleId] = {}
    end
    local node = MPT.db.styles[styleId]
    if create and type(node.colors) ~= "table" then
        node.colors = {}
    end
    if create and type(node.options) ~= "table" then
        node.options = {}
    end
    return node
end

function MPT:RegisterStyle(def)
    if type(def) ~= "table" or type(def.id) ~= "string" or def.id == "" then
        return
    end
    local isNew = styles[def.id] == nil
    styles[def.id] = def
    if isNew then
        styleOrder[#styleOrder + 1] = def.id
    end
end

function MPT:GetStyle(styleId)
    return styles[styleId]
end

function MPT:GetStyleList()
    local out = {}
    for _, id in ipairs(styleOrder) do
        local def = styles[id]
        if def then
            out[#out + 1] = { id = id, label = def.label or id }
        end
    end
    return out
end

function MPT:GetActiveStyleId()
    return activeStyleId
end

function MPT:GetActiveStyle()
    return styles[activeStyleId]
end

function MPT:InitStyleRegistry()
    if not self.db then return end
    if type(self.db.activeStyle) ~= "string" or self.db.activeStyle == "" then
        self.db.activeStyle = "default"
    end
    local wanted = self.db.activeStyle
    if not styles[wanted] then
        wanted = "default"
    end
    if not styles[wanted] then
        for _, id in ipairs(styleOrder) do
            wanted = id
            break
        end
    end
    activeStyleId = wanted or "default"
    self.db.activeStyle = activeStyleId
end

function MPT:ApplyStyle(styleId)
    local nextId = styleId
    if not styles[nextId] then
        nextId = "default"
    end
    if not styles[nextId] then
        return false
    end
    local prev = styles[activeStyleId]
    if prev and prev.onUnmount and activeStyleId ~= nextId then
        prev.onUnmount(self, prev)
    end
    activeStyleId = nextId
    if self.db then
        self.db.activeStyle = nextId
    end
    local style = styles[nextId]
    getStyleStore(nextId, true)
    if style and style.onMount then
        style.onMount(self, style)
    end
    if style and style.onApply then
        style.onApply(self, style)
    end
    return true
end

function MPT:GetStyleColor(colorKey, fallback)
    local style = styles[activeStyleId]
    local store = getStyleStore(activeStyleId, true)
    local colors = store and store.colors
    local c = colors and colors[colorKey]
    if type(c) == "table" and type(c.r) == "number" and type(c.g) == "number" and type(c.b) == "number" then
        return c.r, c.g, c.b
    end
    if style and type(style.defaultColors) == "table" then
        local dc = style.defaultColors[colorKey]
        if type(dc) == "table" then
            if colors then colors[colorKey] = cloneColor(dc) end
            return dc.r, dc.g, dc.b
        end
    end
    if type(fallback) == "table" then
        return fallback.r or 1, fallback.g or 1, fallback.b or 1
    end
    return 1, 1, 1
end

function MPT:SetStyleColor(colorKey, r, g, b)
    local store = getStyleStore(activeStyleId, true)
    if not store or type(store.colors) ~= "table" then return end
    store.colors[colorKey] = { r = r, g = g, b = b }
end

function MPT:GetActiveStyleColorSchema()
    local style = styles[activeStyleId]
    if style and type(style.colorSchema) == "table" then
        return style.colorSchema
    end
    return {}
end

function MPT:ResetActiveStyleColors()
    local style = styles[activeStyleId]
    if not style or type(style.defaultColors) ~= "table" then return end
    local store = getStyleStore(activeStyleId, true)
    if not store then return end
    store.colors = {}
    for key, c in pairs(style.defaultColors) do
        store.colors[key] = cloneColor(c)
    end
    if self.RefreshAllColors then
        self:RefreshAllColors()
    end
end
