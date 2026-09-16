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
--
-- Resizing: Hyprland 0.56 gives a Lua layout no resize hook at all (only recalculate,
-- layout_msg and move_window), so the resize keys reach us as layout messages instead -
-- "resize x -100". We move the border next to the focused tile, keep the new share in the
-- live schema, and hand it to the plugin so the blueprint on disk follows along.

__omarchy_tiles = __omarchy_tiles or { workspaces = {} }

-- What the last recalculate produced: the box every node was given, and which children of
-- a split actually took space. Resizing needs both, because a tile whose apps are absent
-- collapses, and a collapsed neighbour must not be handed part of the drag.
local live = { boxes = {}, present = {}, windows = {}, dir = {} }

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
  live.boxes[node] = box
  if node.children then
    local present, weights, indices = {}, {}, {}
    for i, child in ipairs(node.children) do
      if occupied(child, assigned) then
        present[#present + 1] = child
        weights[#weights + 1] = (node.sizes and node.sizes[i]) or 1
        indices[#indices + 1] = i
      end
    end
    live.present[node] = indices
    local boxes = divide(box, node.dir == "v" and "v" or "h", weights)
    for i, child in ipairs(present) do place_node(child, boxes[i], assigned) end
    return
  end
  local windows = assigned[node]
  if not windows or #windows == 0 then return end
  -- Several windows in one tile: split it along its longer side, evenly unless the
  -- blueprint carries shares for exactly this many windows (a resize inside the tile).
  local dir = box.w >= box.h and "h" or "v"
  local shares = type(node.shares) == "table" and #node.shares == #windows and node.shares
  local weights, order = {}, {}
  for i = 1, #windows do weights[i] = shares and (tonumber(shares[i]) or 1) or 1 end
  local boxes = divide(box, dir, weights)
  for i, target in ipairs(windows) do
    target:place(boxes[i])
    order[i] = target.window
  end
  live.windows[node] = order
  live.dir[node] = dir
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
  live.boxes, live.present, live.windows, live.dir = {}, {}, {}, {}
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

-- ── resizing ────────────────────────────────────────────────────────────────────────────

-- A tile may not be dragged below this share of the split it sits in, so a border can
-- never be pushed past its neighbour or off the screen.
local MIN_SHARE = 0.05

-- The chain of nodes from the schema root down to target, with the child index taken at
-- each step, or nil when target is not in this schema.
local function find_path(node, target, nodes, indices)
  nodes[#nodes + 1] = node
  if node == target then return nodes, indices end
  if node.children then
    for i, child in ipairs(node.children) do
      indices[#indices + 1] = i
      if find_path(child, target, nodes, indices) then return nodes, indices end
      indices[#indices] = nil
    end
  end
  nodes[#nodes] = nil
  return nil
end

local function position_in(list, value)
  for i, item in ipairs(list) do
    if item == value then return i end
  end
end

-- The tile a window is laid out in: the first leaf that lists its class, or the largest
-- one, which is where recalculate sends anything unlisted.
local function leaf_of(schema, window)
  local leaves = collect_leaves(schema, {})
  for _, leaf in ipairs(leaves) do
    if leaf_wants(leaf, window) then return leaf end
  end
  return largest_leaf(schema, 1) or leaves[1]
end

local function active_schema()
  if not (hl and hl.get_active_window) then return nil end
  local ok, window = pcall(hl.get_active_window)
  if not ok or not window then return nil end
  local key = select(2, pcall(function() return tostring(window.workspace.id) end))
  if type(key) ~= "string" then return nil end
  return __omarchy_tiles.workspaces[key], key, window
end

-- Changed splits waiting to be written to the blueprint, keyed by workspace then by the
-- dotted child path of the split. Keystrokes repeat, so the write is debounced.
local pending, save_queued = {}, false

-- The layout file is separate and slower: Hyprland watches the files it loaded, so writing
-- it makes the compositor re-read every config file. The screen is already right by then,
-- so it waits until the keys have stopped. Each resize takes a ticket and only the last
-- one left goes through, which is a debounce without needing to cancel a timer.
local sync_epoch = 0

local function flush_saves()
  local command = __omarchy_tiles.persist
  for key, splits in pairs(pending) do
    local parts = {}
    for where, sizes in pairs(splits) do
      local numbers = {}
      for i, size in ipairs(sizes) do numbers[i] = string.format("%.4f", size) end
      parts[#parts + 1] = where .. "=" .. table.concat(numbers, ",")
    end
    if command and #parts > 0 then
      hl.exec_cmd(command .. " set-sizes " .. key .. " '" .. table.concat(parts, ";") .. "'")
    end
  end
  pending = {}
end

local function sync_layout()
  local command = __omarchy_tiles.persist
  if command then hl.exec_cmd(command .. " sync-layout") end
end

local function remember(key, kind, path, values)
  local copy = {}
  for i, value in ipairs(values) do copy[i] = value end
  pending[key] = pending[key] or {}
  pending[key][kind .. ":" .. path] = copy
  if not hl.timer then return end
  -- The flag goes up before the timer is made, so the state cannot get stuck if a timer
  -- ever runs its callback straight away.
  if not save_queued then
    save_queued = true
    hl.timer(function()
      save_queued = false
      flush_saves()
    end, { type = "oneshot", timeout = 400 })
  end
  sync_epoch = sync_epoch + 1
  local ticket = sync_epoch
  hl.timer(function()
    if ticket == sync_epoch then sync_layout() end
  end, { type = "oneshot", timeout = 5000 })
end

-- Move a border by delta pixels, taking from one side and giving to the other. Returns
-- the two new shares, or nil when the move would push a tile under the floor.
local function shift_border(values, mine, other, sign, delta, span)
  local total = 0
  for _, value in ipairs(values) do total = total + value end
  if span <= 0 or total <= 0 then return nil end
  local shift = delta / span * total * sign
  local a, b = values[mine] + shift, values[other] - shift
  local floor = MIN_SHARE * total
  if a < floor then b, a = b - (floor - a), floor end
  if b < floor then a, b = a - (floor - b), floor end
  if a < floor or b < floor then return nil end
  return a, b
end

-- Where the active window sits among the windows sharing its tile.
local function window_slot(leaf, window)
  local order = live.windows[leaf]
  if not order then return nil end
  for i, other in ipairs(order) do
    if other == window then return i, #order end
  end
  return nil
end

-- Move the border beside the focused window by delta pixels: negative is left or up,
-- positive right or down, which is how Hyprland's own resize bindings read. The border is
-- the one the window shares with the next neighbour, or with the previous one when it is
-- last, so a middle tile always gives ground on its right or bottom edge.
local function resize(axis, delta)
  delta = tonumber(delta) or 0
  local schema, key, window = active_schema()
  if not schema or delta == 0 then return false end
  local leaf = leaf_of(schema, window)
  local nodes, indices = nil, nil
  if leaf then nodes, indices = find_path(schema, leaf, {}, {}) end
  if not nodes then return false end

  local want = (axis == "y") and "v" or "h"

  -- Windows sharing one tile: the border between them lives in the tile's own shares.
  local slot, count = window_slot(leaf, window)
  if slot and count > 1 and live.dir[leaf] == want then
    local box = live.boxes[leaf]
    local shares = {}
    for i = 1, count do
      shares[i] = (type(leaf.shares) == "table" and tonumber(leaf.shares[i])) or 1 / count
    end
    local mine, other, sign
    if slot < count then mine, other, sign = slot, slot + 1, 1 else mine, other, sign = slot, slot - 1, -1 end
    local span = box and ((want == "h") and box.w or box.h) or 0
    local a, b = shift_border(shares, mine, other, sign, delta, span)
    if a then
      shares[mine], shares[other] = a, b
      leaf.shares = shares
      remember(key, "w", table.concat(indices, "."), shares)
      return true
    end
    return false
  end

  for depth = #nodes - 1, 1, -1 do
    local node = nodes[depth]
    local present = live.present[node]
    local box = live.boxes[node]
    local dir = (node.dir == "v") and "v" or "h"
    if dir == want and present and #present > 1 and box then
      local slot = position_in(present, indices[depth])
      if slot then
        -- The border on the side the tile actually shares with a neighbour: the one after
        -- it when there is one, so a middle tile gives ground on its right/bottom edge.
        local mine, other, sign
        if present[slot + 1] then
          mine, other, sign = indices[depth], present[slot + 1], 1
        else
          mine, other, sign = indices[depth], present[slot - 1], -1
        end
        local span = (dir == "h") and box.w or box.h
        local sizes = {}
        for i = 1, #node.children do sizes[i] = node.sizes[i] or 1 end
        -- Only the children that took space may trade: a collapsed tile has no border.
        local visible = {}
        for _, i in ipairs(present) do visible[#visible + 1] = sizes[i] end
        local a, b = shift_border(sizes, mine, other, sign, delta,
          span * (function()
            local all, shown = 0, 0
            for _, value in ipairs(sizes) do all = all + value end
            for _, value in ipairs(visible) do shown = shown + value end
            return shown > 0 and all / shown or 1
          end)())
        if a then
          sizes[mine], sizes[other] = a, b
          node.sizes = sizes
          remember(key, "s", table.concat(indices, ".", 1, depth - 1), sizes)
          return true
        end
      end
    end
  end
  return false
end

__omarchy_tiles.resize = resize

return {
  recalculate = recalculate,
  layout_msg = function(ctx, msg)
    local text = tostring(msg or "")
    local command, axis, delta = text:match("^(%S+)%s+(%S+)%s+(-?%d+)$")
    if command == "resize" then
      return resize(axis, delta) and true or "tiles: nothing to resize here"
    end
    if text:match("^(%S+)") == "reload" then
      return true
    end
    return "tiles: expected reload or resize"
  end,
}
