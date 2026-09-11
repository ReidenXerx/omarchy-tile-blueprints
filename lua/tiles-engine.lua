-- Tile schemas: a per-workspace tiling blueprint for Hyprland's Lua layout API.
--
-- A schema is a tree. A split node is { dir = "h" | "v", sizes = { 0.6, 0.4 }, children = {...} }
-- ("h" lays children left to right, "v" top to bottom). A leaf is { name = "editor",
-- apps = { "code", "dev.zed.Zed" } }. Windows go to the first leaf listing their class;
-- anything unlisted shares the schema's largest tile. Tiles with no window collapse and
-- their siblings take the space, so an unused slot never leaves a hole.
--
-- Schemas live in the global __omarchy_tiles.workspaces, keyed by workspace id, so they can
-- be replaced live (`hyprctl eval`) without re-registering the layout.

__omarchy_tiles = __omarchy_tiles or { workspaces = {} }

local function lower(s)
  return string.lower(tostring(s or ""))
end

local function leaf_wants(leaf, window)
  if not leaf.apps or not window then return false end
  local class, initial = lower(window.class), lower(window.initial_class)
  for _, app in ipairs(leaf.apps) do
    local a = lower(app)
    if a ~= "" and (a == class or a == initial) then return true end
  end
  return false
end

local function collect_leaves(node, out)
  if node.children then
    for _, child in ipairs(node.children) do collect_leaves(child, out) end
  else
    out[#out + 1] = node
  end
  return out
end

-- Split box along dir into pieces proportional to weights, in whole pixels, with the last
-- piece absorbing rounding so the pieces always add up exactly.
local function divide(box, dir, weights)
  local total = 0
  for _, w in ipairs(weights) do total = total + w end
  if total <= 0 then total = #weights end
  local out, offset = {}, 0
  local span = dir == "h" and box.w or box.h
  for i, w in ipairs(weights) do
    local size = (i == #weights) and (span - offset) or math.floor(span * (w > 0 and w or 1) / total + 0.5)
    if dir == "h" then
      out[i] = { x = box.x + offset, y = box.y, w = size, h = box.h }
    else
      out[i] = { x = box.x, y = box.y + offset, w = box.w, h = size }
    end
    offset = offset + size
  end
  return out
end

-- Nominal area share of every leaf in the full schema, to pick "the largest tile".
local function largest_leaf(node, share, best)
  best = best or { leaf = nil, share = -1 }
  if node.children then
    local total = 0
    for i = 1, #node.children do total = total + ((node.sizes and node.sizes[i]) or 1) end
    for i, child in ipairs(node.children) do
      local w = (node.sizes and node.sizes[i]) or 1
      largest_leaf(child, share * w / (total > 0 and total or 1), best)
    end
  elseif share > best.share then
    best.leaf, best.share = node, share
  end
  return best.leaf
end

local function occupied(node, assigned)
  if node.children then
    for _, child in ipairs(node.children) do
      if occupied(child, assigned) then return true end
    end
    return false
  end
  return assigned[node] ~= nil and #assigned[node] > 0
end

local function place_node(node, box, assigned)
  if node.children then
    local present, weights = {}, {}
    for i, child in ipairs(node.children) do
      if occupied(child, assigned) then
        present[#present + 1] = child
        weights[#weights + 1] = (node.sizes and node.sizes[i]) or 1
      end
    end
    local boxes = divide(box, node.dir == "v" and "v" or "h", weights)
    for i, child in ipairs(present) do place_node(child, boxes[i], assigned) end
    return
  end
  local windows = assigned[node]
  if not windows or #windows == 0 then return end
  -- Several windows in one tile: split it evenly along its longer side.
  local weights = {}
  for i = 1, #windows do weights[i] = 1 end
  local boxes = divide(box, box.w >= box.h and "h" or "v", weights)
  for i, target in ipairs(windows) do target:place(boxes[i]) end
end

local function workspace_key(targets)
  for _, target in ipairs(targets) do
    local window = target.window
    local ws = window and window.workspace
    if ws and ws.id ~= nil then return tostring(ws.id) end
  end
end

local function fallback_grid(ctx)
  local cols = math.max(1, math.ceil(math.sqrt(#ctx.targets)))
  for i, target in ipairs(ctx.targets) do
    target:place(ctx:grid_cell(i, cols))
  end
end

local function recalculate(ctx)
  local targets = ctx.targets
  if #targets == 0 then return end
  local key = workspace_key(targets)
  local schema = key and __omarchy_tiles.workspaces[key]
  if not schema then return fallback_grid(ctx) end

  local leaves = collect_leaves(schema, {})
  local assigned, spill = {}, {}
  for _, target in ipairs(targets) do
    local home
    for _, leaf in ipairs(leaves) do
      if leaf_wants(leaf, target.window) then home = leaf; break end
    end
    if home then
      assigned[home] = assigned[home] or {}
      table.insert(assigned[home], target)
    else
      spill[#spill + 1] = target
    end
  end
  if #spill > 0 then
    local big = largest_leaf(schema, 1) or leaves[1]
    assigned[big] = assigned[big] or {}
    for _, target in ipairs(spill) do table.insert(assigned[big], target) end
  end
  place_node(schema, ctx.area, assigned)
end

return {
  recalculate = recalculate,
  layout_msg = function(ctx, msg)
    local command = tostring(msg or ""):match("^(%S+)")
    if command == "reload" then
      return true
    end
    return "tiles: expected reload"
  end,
}
