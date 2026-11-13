-- This small DSL returns data, not host objects or callable capabilities.
local function node(kind)
    return function(props)
        assert(type(props) == "table", "UI properties must be a table")
        local out = table.clone(props)
        out.kind = kind
        return out
    end
end
local function motion(mode)
    return function(props)
        local out = table.clone(props)
        out.mode = mode
        return out
    end
end
local ui = table.freeze {
    column = node("column"), row = node("row"), layer = node("layer"),
    rect = node("rect"), text = node("text"),
    spring = motion("spring"), tween = motion("tween"),
}
local renderer = (function()
