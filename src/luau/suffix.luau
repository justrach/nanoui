
end)()
assert(type(renderer) == "function", "Source must return a render function")
return function(x, y, width, height, dark, reduced_motion)
    return renderer(table.freeze {
        pointer_x = x, pointer_y = y, width = width, height = height,
        dark = dark, reduced_motion = reduced_motion,
    })
end
