#!/usr/bin/python3
"""python3 tests/helper_test.py -- bin/tile-blueprints outside the shell.

Everything runs in a sandbox under $XDG_RUNTIME_DIR with the helper's path constants pointed
there. hyprctl, notifications and the detached apply are stubbed, so nothing here touches
Hyprland, the real blueprint file or the real generated layout."""
import contextlib
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bin"))
import plugin_safety as safe  # noqa: E402

LIBRARY_SHA256 = "bf8ffb9ff874caa1958526c1d0a9bd239a55842c979d41cd916675075cf8ec87"
HOSTILE_CLASSES = [
    'evil"]] os.execute("touch PWNED") --',
    "back\\slash",
    "]]",
    "[[long]]",
    "--[[",
    'quote"',
    "a'b",
    "$(touch PWNED)",
    "\\000",
    "café 中",
    "%s%d",
    "end) os.execute('touch PWNED') (function()",
]


def load_helper():
    loader = importlib.machinery.SourceFileLoader("tile_blueprints_under_test", str(ROOT / "bin" / "tile-blueprints"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def leaf(apps=(), leaf_id=None):
    node = {"apps": [dict(a) if isinstance(a, dict) else {"class": a, "name": a, "desktop": ""} for a in apps]}
    if leaf_id:
        node["id"] = leaf_id
    return node


def split(*children, direction="h", sizes=None):
    return {"dir": direction, "sizes": sizes or [1 / len(children)] * len(children), "children": list(children)}


def document(**workspaces):
    return {"version": 1, "workspaces": {k.lstrip("w"): {"root": v, "launch": True, "pin": True}
                                         for k, v in workspaces.items()}}


def hexed(data):
    return data.encode("utf-8").hex() if isinstance(data, str) else data.hex()


LUA_HARNESS = r"""
local path = ...
local out = {}
local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
hl = {
  layout = { register = function(name, t) out[#out + 1] = "layout " .. hex(name) end },
  workspace_rule = function(t) out[#out + 1] = "wsrule " .. hex(tostring(t.workspace)) .. " " .. hex(tostring(t.layout)) .. " " .. hex(tostring(t.monitor or "")) .. " " .. hex(tostring(t.persistent == true)) end,
  window_rule = function(t) out[#out + 1] = "rule " .. hex(t.match.class) .. " " .. hex(t.workspace) end,
  on = function(event, fn) out[#out + 1] = "on " .. hex(event); fn() end,
  exec_cmd = function(cmd) out[#out + 1] = "exec " .. hex(cmd) end,
  bind = function(keys, fn, opts) out[#out + 1] = "bind " .. hex(keys) end,
  unbind = function(keys) out[#out + 1] = "unbind " .. hex(keys) end,
  dispatch = function(d) out[#out + 1] = "dispatch" end,
  dsp = { window = { resize = function(t) return t end }, layout = function(msg) return msg end },
  timer = function(fn, opts) fn() return {} end,
  get_active_window = function() return nil end,
}
dofile(path)
local function walk(key, node)
  if node.children then
    for _, child in ipairs(node.children) do walk(key, child) end
  else
    for _, app in ipairs(node.apps) do out[#out + 1] = "app " .. key .. " " .. hex(app) end
  end
end
local sizes = io.open((path:gsub("generated%.lua$", "sizes.txt")), "w")
local function dump(node)
  if node.children then
    sizes:write(table.concat(node.sizes or {}, ","), "\n")
    for _, child in ipairs(node.children) do dump(child) end
  elseif node.shares then
    sizes:write(table.concat(node.shares, ","), "\n")
  end
end
for _, root in pairs(__omarchy_tiles.workspaces) do dump(root) end
sizes:close()
for key, root in pairs(__omarchy_tiles.workspaces) do walk(key, root) end
table.sort(out)
io.write(table.concat(out, "\n"), "\n")
"""


LUA_RESIZE_HARNESS = r"""
local path, classes, active, axis, delta, times, swap = ...
local registered, exec, timers, dispatched = nil, {}, {}, {}
ACTIVE = nil
hl = {
  layout = { register = function(name, t) registered = t end },
  workspace_rule = function() end,
  window_rule = function() end,
  on = function() end,
  exec_cmd = function(cmd) exec[#exec + 1] = cmd end,
  bind = function() end,
  unbind = function() end,
  dispatch = function(d) dispatched[#dispatched + 1] = tostring(d) end,
  dsp = { window = { resize = function(t) return t end }, layout = function(msg) return msg end },
  timer = function(fn) timers[#timers + 1] = fn return {} end,
  get_active_window = function() return ACTIVE end,
}
dofile(path)

local targets = {}
for class in classes:gmatch("[^,]+") do
  local window = { class = class, initial_class = class, workspace = { id = 1 } }
  targets[#targets + 1] = {
    window = window,
    place = function(self, box) self.box = box end,
  }
end
local ctx = {
  targets = targets,
  area = { x = 0, y = 0, w = 1000, h = 800 },
  grid_cell = function(self, i, cols) return { x = 0, y = 0, w = 10, h = 10 } end,
}

registered.recalculate(ctx)
if swap == "swap" then
  targets[1], targets[2] = targets[2], targets[1]
  ctx.targets = targets
  registered.recalculate(ctx)
end
ACTIVE = targets[tonumber(active)].window
local moved = false
for _ = 1, tonumber(times or 1) do
  moved = __omarchy_tiles.resize(axis, tonumber(delta))
  registered.recalculate(ctx)
end
for _, fn in ipairs(timers) do fn() end

io.write("moved ", tostring(moved), "\n")
for i, target in ipairs(targets) do io.write("order ", i, " ", target.window.class, "\n") end
for i, target in ipairs(targets) do
  io.write("box ", i, " ", target.box.x, " ", target.box.y, " ", target.box.w, " ", target.box.h, "\n")
end
for _, cmd in ipairs(exec) do io.write("exec ", cmd, "\n") end
for _, d in ipairs(dispatched) do io.write("dispatch ", d, "\n") end
"""


class Sandbox(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp(prefix="tile-blueprints-test.", dir=safe.runtime_dir()))
        h = self.h = load_helper()
        h.HOME = self.dir / "home"
        h.HOME.mkdir()
        h.CONFIG = self.dir / "config" / "omarchy" / "tile-blueprints.json"
        h.STATE = self.dir / "state" / "omarchy"
        h.GENERATED = h.STATE / "workspace-layouts" / "zz-tile-blueprints.lua"
        h.TREES = h.STATE / "tile-blueprints" / "trees.lua"
        h.USER_APP_DIRS = [h.HOME / ".local/share/applications",
                           h.HOME / ".local/share/flatpak/exports/share/applications"]
        h.SYSTEM_APP_DIRS = []
        engine = self.dir / "plugin" / "lua" / "tiles-engine.lua"
        engine.parent.mkdir(parents=True)
        shutil.copyfile(ROOT / "lua" / "tiles-engine.lua", engine)
        h.ENGINE = engine
        self.calls, self.notes, self.spawned = [], [], []
        self.eval_ok = True
        self.clients, self.active = [], {"id": 1}
        self.monitors = []
        h.hyprctl = self.fake_hyprctl
        h.notify = lambda summary, body="": self.notes.append((summary, body))
        h.spawn_apply = lambda: (self.spawned.append(True), 0)[1]
        h.launch_tools = lambda: ("/usr/bin/uwsm-app", "/usr/bin/gtk-launch")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def fake_hyprctl(self, args, timeout=None, max_output=None):
        self.calls.append(list(args))
        assert timeout is not None and timeout > 0
        payload = b""
        if args == ["-j", "clients"]:
            payload = json.dumps(self.clients).encode()
        elif args == ["-j", "activeworkspace"]:
            payload = json.dumps(self.active).encode()
        elif args == ["-j", "monitors"]:
            payload = json.dumps(self.monitors).encode()
        elif args == ["-j", "workspaces"]:
            payload = b"[]"
        elif args and args[0] == "eval":
            payload = b"ok\n" if self.eval_ok else b"error: no\n"
        return safe.Result(0, payload, b"", False, False)

    def write_config(self, value, raw=None):
        self.h.CONFIG.parent.mkdir(parents=True, exist_ok=True)
        self.h.CONFIG.write_bytes(raw if raw is not None else json.dumps(value).encode())

    def capture(self, fn, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = fn(*args)
        return code, out.getvalue(), err.getvalue()

    def lua(self, *argv):
        if not (safe.has_tool("lua") and safe.has_tool("luac")):
            self.skipTest("lua/luac not installed")
        return safe.run(list(argv), timeout=10, cwd=str(self.dir))


# ------------------------------------------------------------------ normalization

class Normalize(Sandbox):
    def strict(self, doc):
        return self.h.normalize_document(doc, strict=True)[0]

    def test_editor_document_round_trips(self):
        doc = document(w2=split(leaf(["code"], "t1"), split(leaf(["foot"], "t2"), leaf([], "t3"), direction="v"),
                                sizes=[0.6, 0.4]))
        out = self.strict(doc)
        root = out["workspaces"]["2"]["root"]
        self.assertEqual([c.get("id") for c in root["children"][1]["children"]], ["t2", "t3"])
        self.assertAlmostEqual(sum(root["sizes"]), 1.0)
        self.assertEqual(root["children"][0]["apps"], [{"class": "code", "name": "code", "desktop": ""}])

    def test_workspace_ids_are_1_to_99(self):
        for bad in ("0", "100", "01", "abc", "-1", "1.0", " 1", "1\n"):
            with self.assertRaises(self.h.Invalid, msg=bad):
                self.strict({"workspaces": {bad: {"root": leaf(["a"])}}})
            doc, problems = self.h.normalize_document({"workspaces": {bad: {"root": leaf(["a"])}, "3": {"root": leaf(["b"])}}})
            self.assertEqual(list(doc["workspaces"]), ["3"])
            self.assertEqual(len(problems), 1)
        self.assertEqual(list(self.strict({"workspaces": {"99": {"root": leaf(["a"])}, "1": {"root": leaf(["b"])}}})["workspaces"]),
                         ["1", "99"])

    def test_at_most_ten_workspaces(self):
        many = {"workspaces": {str(i): {"root": leaf([f"app{i}"])} for i in range(1, 12)}}
        with self.assertRaises(self.h.Invalid):
            self.strict(many)
        doc, problems = self.h.normalize_document(many)
        self.assertEqual(list(doc["workspaces"]), [str(i) for i in range(1, 11)])
        self.assertTrue(problems)

    def test_tile_limit(self):
        self.strict(document(w1=split(*[leaf() for _ in range(64)])))
        with self.assertRaises(self.h.Invalid):
            self.strict(document(w1=split(*[leaf() for _ in range(65)])))
        nested = split(*[split(*[leaf() for _ in range(9)], direction="v") for _ in range(8)])
        with self.assertRaises(self.h.Invalid):
            self.strict(document(w1=nested))
        doc, problems = self.h.normalize_document(document(w1=nested, w2=leaf(["ok"])))
        self.assertEqual(list(doc["workspaces"]), ["2"])
        self.assertIn("64 tiles", problems[0])

    def test_apps_per_tile_limit(self):
        self.strict(document(w1=leaf([f"a{i}" for i in range(32)])))
        with self.assertRaises(self.h.Invalid):
            self.strict(document(w1=leaf([f"a{i}" for i in range(33)])))

    def test_depth_limit(self):
        def chain(levels):
            node = leaf(["deep"])
            for _ in range(levels):
                node = split(node, leaf())
            return node
        self.strict(document(w1=chain(16)))
        with self.assertRaises(self.h.Invalid):
            self.strict(document(w1=chain(17)))

    def test_hostile_json_nesting_is_refused_before_normalizing(self):
        blob = ('{"workspaces":{"1":{"root":' + '{"children":[' * 200 + "{}" + "]}" * 200 + "}}}").encode()
        with self.assertRaises(safe.TooLarge):
            safe.loads(blob, **self.h.JSON_LIMITS)

    def test_class_name_rules(self):
        classes = ["x" * 256, "x" * 257, "line\nbreak", "nul\x00", "del\x7f", "c1\x85", "", "lone\ud800", "ok.App"]
        out = self.strict(document(w1=leaf([{"class": c, "name": c} for c in classes] + [{"class": 5}, "OK.APP"])))
        kept = [a["class"] for a in out["workspaces"]["1"]["root"]["apps"]]
        self.assertEqual(kept, ["x" * 256, "ok.App"])  # OK.APP is the same class, case-insensitively

    def test_desktop_ids_and_names(self):
        apps = [{"class": f"c{i}", "name": n, "desktop": d} for i, (n, d) in enumerate([
            ("Fine", "org.gnome.Nautilus"), ("x", "foo;rm -rf ~"), ("x", "-help"), ("x", "a/b"), ("x", "a" * 256),
            ("x", "a" * 255), ("tab\tname\n" + "n" * 400, "foo bar"), ("x", 7)])]
        got = self.strict(document(w1=leaf(apps)))["workspaces"]["1"]["root"]["apps"]
        self.assertEqual([a["desktop"] for a in got], ["org.gnome.Nautilus", "", "", "", "", "a" * 255, "", ""])
        self.assertEqual(len(got[6]["name"]), 256)
        self.assertNotIn("\n", got[6]["name"])

    def test_sizes_are_finite_positive(self):
        for sizes in ([float("nan"), 1], [float("inf"), 1], [-1, 1], [0, 0], [True, False], ["0.5", None],
                      [10 ** 400, 1], [1e-300, 1e300], [], None, "1,1"):
            out = self.strict(document(w1=split(leaf(["a"]), leaf(["b"]), sizes=sizes)))
            got = out["workspaces"]["1"]["root"]["sizes"]
            self.assertEqual(len(got), 2, sizes)
            self.assertTrue(all(isinstance(v, float) and 0 < v < 1 for v in got), (sizes, got))
            self.assertAlmostEqual(sum(got), 1.0)
            json.dumps(out, allow_nan=False)

    def test_duplicate_classes_and_ids_are_repaired(self):
        root = split(leaf(["foot"], "t1"), leaf(["FOOT", "code"], "t1"), leaf([], "bad id!"))
        out = self.strict(document(w1=root))["workspaces"]["1"]["root"]
        ids = [c["id"] for c in out["children"]]
        self.assertEqual(len(set(ids)), 3)
        self.assertEqual([[a["class"] for a in c["apps"]] for c in out["children"]], [["foot"], ["code"], []])

    def test_not_a_document(self):
        for bad in ([], "x", {"workspaces": []}, {}, None):
            with self.assertRaises(self.h.Invalid):
                self.h.normalize_document(bad, strict=True)

    def test_monitor_is_kept_only_when_it_is_a_usable_rule_value(self):
        good = ["desc:Dell Inc. DELL S2721DGF DCRD223", "DP-1", "0", "desc:a,b (c)+d-1"]
        for value in good:
            doc = document(w1=leaf(["a"]))
            doc["workspaces"]["1"]["monitor"] = value
            self.assertEqual(self.strict(doc)["workspaces"]["1"]["monitor"], value)
        # Anything that is not a printable string, or is too long, is dropped rather than
        # rejected: the workspace keeps its blueprint and just opens wherever it is.
        for bad in ("", "   ", "a\nb", "a\tb", "x" * 257, "\x00", 7, None, ["DP-1"], {"a": 1}):
            doc = document(w1=leaf(["a"]))
            doc["workspaces"]["1"]["monitor"] = bad
            self.assertNotIn("monitor", self.strict(doc)["workspaces"]["1"], repr(bad))


# ------------------------------------------------------------------ Lua

class Lua(Sandbox):
    def test_lua_str_is_printable_ascii_and_round_trips(self):
        samples = HOSTILE_CLASSES + ["\x00", "\n\r\t", "\\", '"', "\\\"", "]]==]", "\U0001f600", "\ud800x", "1\\0012"]
        for s in samples:
            literal = self.h.lua_str(s)
            self.assertTrue(all(0x20 <= ord(c) < 0x7F for c in literal), literal)
        chunk = self.dir / "strings.lua"
        chunk.write_text("local t = {\n" + "".join(f"  {self.h.lua_str(s)},\n" for s in samples) + "}\n"
                         "for _, s in ipairs(t) do io.write((s:gsub('.', function(c) return string.format('%02x', c:byte()) end)), '\\n') end\n")
        self.assertTrue(self.lua("luac", "-p", str(chunk)).ok)
        r = self.lua("lua", str(chunk))
        self.assertTrue(r.ok, r.stderr)
        expected = [s.encode("utf-8", "replace").hex() for s in samples]
        self.assertEqual(r.text().split("\n")[:-1], expected)

    def test_generated_file_parses_and_keeps_hostile_classes_as_data(self):
        apps = [{"class": c, "name": c, "desktop": d} for c, d in zip(
            HOSTILE_CLASSES, ["good.App", "x;touch PWNED", "-x", "$(x)"] + [""] * len(HOSTILE_CLASSES))]
        apps.append({"class": "new\nline", "name": "dropped", "desktop": "dropped"})
        doc = self.h.normalize_document(document(w3=split(leaf(apps[:6]), leaf(apps[6:]))), strict=True)[0]
        text = self.h.generate(doc)
        self.assertNotIn("new\nline", text)
        path = self.dir / "generated.lua"
        path.write_text(text)
        self.assertTrue(self.lua("luac", "-p", str(path)).ok)
        harness = self.dir / "harness.lua"
        harness.write_text(LUA_HARNESS)
        r = self.lua("lua", str(harness), str(path))
        self.assertTrue(r.ok, r.stderr.decode())
        self.assertFalse((self.dir / "PWNED").exists())
        lines = set(r.text().split("\n")[:-1])
        for cls in HOSTILE_CLASSES:
            self.assertIn(f"app 3 {hexed(cls)}", lines)
            self.assertIn(f"rule {hexed(self.h.class_regex(cls))} {hexed('3 silent')}", lines)
        self.assertIn(f"exec {hexed('/usr/bin/uwsm-app -- /usr/bin/gtk-launch good.App.desktop')}", lines)
        self.assertEqual(len([line for line in lines if line.startswith("exec ")]), 1)
        self.assertEqual(len([line for line in lines if line.startswith("app ")]), len(HOSTILE_CLASSES))

    def test_class_regex_matches_only_the_literal_class(self):
        import re
        for cls in HOSTILE_CLASSES + ["a.b", "a+b(c)", "x|y", "^$", "[abc]{2}"]:
            pattern = self.h.class_regex(cls)
            self.assertTrue(re.fullmatch(pattern, cls), cls)
        self.assertFalse(re.fullmatch(self.h.class_regex("a.b"), "aXb"))
        # A class the desktop id spelled differently still matches: a card can say "spotify"
        # while the window calls itself "Spotify".
        self.assertTrue(re.fullmatch(self.h.class_regex("spotify"), "Spotify"))
        self.assertFalse(re.fullmatch(self.h.class_regex("spotify"), "spotifyd"))

    def test_pin_and_launch_flags(self):
        doc = document(w1=leaf([{"class": "foot", "name": "Foot", "desktop": "foot"}]))
        doc["workspaces"]["1"].update(pin=False, launch=False)
        text = self.h.generate(self.h.normalize_document(doc, strict=True)[0])
        self.assertNotIn("hl.window_rule", text)
        self.assertNotIn("gtk-launch", text)

    def test_display_rule_is_persistent_and_escaped(self):
        monitor = 'desc:Dell "Inc" \\ 27in'
        doc = document(w3=leaf(["foot"]))
        doc["workspaces"]["3"]["monitor"] = monitor
        normalized = self.h.normalize_document(doc, strict=True)[0]
        self.assertEqual(normalized["workspaces"]["3"]["monitor"], monitor)
        text = self.h.generate(normalized)
        self.assertIn("persistent = true", text)
        path = self.dir / "generated.lua"
        path.write_text(text)
        self.assertTrue(self.lua("luac", "-p", str(path)).ok)
        harness = self.dir / "harness.lua"
        harness.write_text(LUA_HARNESS)
        r = self.lua("lua", str(harness), str(path))
        self.assertTrue(r.ok, r.stderr.decode())
        lines = set(r.text().split("\n")[:-1])
        self.assertIn(f"wsrule {hexed('3')} {hexed('lua:tile-blueprints')} {hexed(monitor)} {hexed('true')}", lines)
        # A workspace with no display chosen gets no monitor at all, so Hyprland places it.
        plain = self.h.generate(self.h.normalize_document(document(w4=leaf(["foot"])), strict=True)[0])
        self.assertNotIn("monitor =", plain)

    def test_no_launch_lines_without_trusted_tools(self):
        self.h.launch_tools = lambda: None
        doc = document(w1=leaf([{"class": "foot", "name": "Foot", "desktop": "foot"}]))
        self.assertNotIn("gtk-launch", self.h.generate(self.h.normalize_document(doc, strict=True)[0]))

    def test_engine_read_is_capped_and_refuses_links(self):
        doc = self.h.normalize_document(document(w1=leaf(["a"])), strict=True)[0]
        self.h.ENGINE.write_bytes(b"-" * (self.h.ENGINE_MAX + 1))
        with self.assertRaises(safe.TooLarge):
            self.h.generate(doc)
        link = self.dir / "plugin" / "lua" / "link.lua"
        link.symlink_to(self.h.ENGINE)
        self.h.ENGINE = link
        with self.assertRaises(safe.UnsafeError):
            self.h.generate(doc)

    def test_real_launch_tools_are_absolute(self):
        tools = load_helper().launch_tools()
        if tools is None:
            self.skipTest("uwsm-app/gtk-launch not installed")
        self.assertEqual(tools, ("/usr/bin/uwsm-app", "/usr/bin/gtk-launch"))


# ------------------------------------------------------------------ config file, apply

class Resize(Sandbox):
    """Resizing on a blueprint workspace: the engine moves the border, the helper writes it
    back, and the generated file is what routes the keys there."""

    def split(self, sizes=None):
        return {"dir": "h", "sizes": sizes or [0.5, 0.5],
                "children": [leaf([{"class": "foot", "name": "Foot", "desktop": ""}]),
                             leaf([{"class": "code", "name": "Code", "desktop": ""}])]}

    def resize_run(self, doc, classes, active, axis, delta, times=1, swap=False):
        text = self.h.generate(self.h.normalize_document(doc, strict=True)[0])
        path = self.dir / "generated.lua"
        path.write_text(text)
        harness = self.dir / "resize.lua"
        harness.write_text(LUA_RESIZE_HARNESS)
        r = self.lua("lua", str(harness), str(path), classes, str(active), axis, str(delta), str(times),
                     "swap" if swap else "")
        self.assertTrue(r.ok, r.stderr.decode())
        return r.stdout.decode()

    # ---- the engine

    def test_windows_sharing_a_tile_move_their_own_border(self):
        out = self.resize_run(document(w1=leaf([{"class": "foot", "name": "Foot", "desktop": ""},
                                                {"class": "code", "name": "Code", "desktop": ""}])),
                              "foot,code", 1, "x", -100)
        self.assertIn("moved true", out)
        widths = [int(line.split()[4]) for line in out.splitlines() if line.startswith("box")]
        self.assertEqual(widths, [400, 600])
        self.assertRegex(out, r"exec .*set-sizes 1 'w:=0\.4000,0\.6000'")

    def test_a_tile_gives_ground_to_the_next_tile(self):
        out = self.resize_run(document(w1=self.split()), "foot,code", 1, "x", -100)
        self.assertIn("moved true", out)
        widths = [int(line.split()[4]) for line in out.splitlines() if line.startswith("box")]
        self.assertEqual(widths, [400, 600])
        self.assertRegex(out, r"exec .*set-sizes 1 's:=0\.4000,0\.6000'")

    def test_the_last_tile_pushes_the_border_the_other_way(self):
        out = self.resize_run(document(w1=self.split()), "foot,code", 2, "x", -100)
        widths = [int(line.split()[4]) for line in out.splitlines() if line.startswith("box")]
        self.assertEqual(widths, [400, 600])

    def test_an_axis_the_split_does_not_run_along_is_left_alone(self):
        out = self.resize_run(document(w1=self.split()), "foot,code", 1, "y", -100)
        self.assertIn("moved false", out)
        self.assertNotIn("exec ", out)

    def test_a_border_stops_at_the_floor_instead_of_passing_its_neighbour(self):
        out = self.resize_run(document(w1=self.split()), "foot,code", 1, "x", -960)
        self.assertIn("moved true", out)
        widths = [int(line.split()[4]) for line in out.splitlines() if line.startswith("box")]
        self.assertEqual(widths, [50, 950])

    def test_one_window_alone_has_no_border_to_move(self):
        out = self.resize_run(document(w1=self.split()), "foot", 1, "x", -100)
        self.assertIn("moved false", out)

    def test_a_swap_inside_a_tile_is_written_back(self):
        doc = document(w1=leaf([{"class": "foot", "name": "Foot", "desktop": ""},
                                {"class": "code", "name": "Code", "desktop": ""}]))
        out = self.resize_run(doc, "foot,code", 1, "x", 0, swap=True)
        self.assertRegex(out, r"exec .*set-sizes 1 'o:=2,1'")

    def test_a_tile_is_laid_out_in_the_order_the_blueprint_lists(self):
        doc = document(w1=leaf([{"class": "code", "name": "Code", "desktop": ""},
                                {"class": "foot", "name": "Foot", "desktop": ""}]))
        # The windows arrive foot first; the blueprint says code first, and that wins on the
        # first layout - which is how a saved swap comes back after a restart.
        out = self.resize_run(doc, "foot,code", 1, "x", 0)
        widths = [line.split()[2] for line in out.splitlines() if line.startswith("box")]
        self.assertEqual(widths, ["0", "500"])
        order = [line.split()[2] for line in out.splitlines() if line.startswith("order")]
        self.assertEqual(order, ["foot", "code"])   # targets untouched; only the placement moved

    def test_set_sizes_reorders_a_tile(self):
        self.write_config(document(w1=leaf(["foot", "code", "mpv"])))
        self.assertEqual(self.capture(self.h.cmd_set_sizes, ["1", "o:=3,1,2"])[0], 0)
        apps = json.loads(self.h.CONFIG.read_bytes())["workspaces"]["1"]["root"]["apps"]
        self.assertEqual([a["class"] for a in apps], ["mpv", "foot", "code"])

    def test_an_order_that_is_not_a_permutation_is_ignored(self):
        self.write_config(document(w1=leaf(["foot", "code"])))
        for payload in ("o:=1,1", "o:=1", "o:=1,2,3", "o:=0,1", "o:=1.5,2"):
            self.assertEqual(self.capture(self.h.cmd_set_sizes, ["1", payload])[0], 0, payload)
        apps = json.loads(self.h.CONFIG.read_bytes())["workspaces"]["1"]["root"]["apps"]
        self.assertEqual([a["class"] for a in apps], ["foot", "code"])

    # ---- the generated file

    def test_the_resize_keys_are_taken_over_in_both_spellings(self):
        text = self.h.generate(self.h.normalize_document(document(w1=leaf(["foot"])), strict=True)[0])
        self.assertEqual(text.count("hl.bind("), len(self.h.RESIZE_KEYS))
        for mods, code, _axis, _delta, _description in self.h.RESIZE_KEYS:
            name = self.h.KEY_NAMES[code]
            self.assertIn(f'pcall(hl.unbind, "{mods}code:{code}")', text)
            self.assertIn(f'pcall(hl.unbind, "{mods}{name}")', text)
            self.assertIn(f'hl.bind("{mods}{name}", tile_resize(', text)

    def test_the_only_program_the_generated_file_names_is_the_helper(self):
        text = self.h.generate(self.h.normalize_document(document(w1=leaf(["foot"])), strict=True)[0])
        execs = [line.strip() for line in text.splitlines() if "hl.exec_cmd(" in line]
        self.assertEqual(len(execs), 1)                       # the one call back into this helper
        for line in execs:
            self.assertIn("hl.exec_cmd(command ..", line)   # always this helper, never a name from the document
        self.assertIn(f'__omarchy_tiles.persist = "{self.h.SELF}"', text)

    def test_a_resize_asks_hyprland_to_lay_the_workspace_out_again(self):
        out = self.resize_run(document(w1=self.split()), "foot,code", 1, "x", -100)
        self.assertIn("dispatch reload", out)   # without this the change waits for something else

    def test_a_refused_resize_asks_for_nothing(self):
        out = self.resize_run(document(w1=self.split()), "foot,code", 1, "y", -100)
        self.assertNotIn("dispatch", out)

    def test_a_run_of_resizes_saves_once(self):
        out = self.resize_run(document(w1=self.split()), "foot,code", 1, "x", -20, times=5)
        saves = [line for line in out.splitlines() if "set-sizes" in line]
        self.assertEqual(len(saves), 1, out)      # one write for the whole run
        self.assertIn("0.4000,0.6000", saves[0])  # carrying where the border ended up

    # ---- applying without a full reload

    def test_a_tile_change_goes_straight_to_hyprland(self):
        self.write_config(document(w1=self.split()))
        self.capture(self.h.cmd_apply, [])          # first apply writes the file the long way
        self.calls.clear()
        self.write_config(document(w1=self.split([0.2, 0.8])))
        self.capture(self.h.cmd_apply, [])
        commands = [c[0] for c in self.calls]
        self.assertIn("eval", commands)
        self.assertNotIn("reload", commands)
        pushed = next(c for c in self.calls if c[0] == "eval")[1]
        self.assertIn("__omarchy_tiles.workspaces = ", pushed)
        self.assertIn('hl.dsp.layout("reload")', pushed)

    def test_anything_but_tiles_still_reloads(self):
        self.write_config(document(w1=self.split()))
        self.capture(self.h.cmd_apply, [])
        for change in (document(w1=self.split(), w2=leaf(["mpv"])),          # a new workspace
                       {"version": 1, "workspaces": {"1": {"root": self.split(), "launch": True, "pin": False}}}):
            self.calls.clear()
            self.write_config(change)
            self.capture(self.h.cmd_apply, [])
            self.assertIn("reload", [c[0] for c in self.calls], change)

    def test_hyprland_refusing_the_push_falls_back_to_a_reload(self):
        self.write_config(document(w1=self.split()))
        self.capture(self.h.cmd_apply, [])
        self.calls.clear()
        self.eval_ok = False
        self.write_config(document(w1=self.split([0.2, 0.8])))
        self.capture(self.h.cmd_apply, [])
        self.assertIn("reload", [c[0] for c in self.calls])

    def test_a_background_save_pushes_before_it_hands_off(self):
        self.write_config(document(w1=self.split()))
        self.capture(self.h.cmd_apply, [])
        self.calls.clear()
        doc = json.dumps(document(w1=self.split([0.2, 0.8])))
        r, w = os.pipe()
        os.write(w, (doc + "\n").encode())
        os.close(w)
        self.h.stdin_fd = lambda: r
        self.capture(self.h.cmd_write, ["--background"])
        os.close(r)
        self.assertEqual([c[0] for c in self.calls], ["eval"])
        self.assertEqual(self.spawned, [True])

    def test_an_apply_that_changes_nothing_still_resets_what_a_resize_moved(self):
        self.write_config(document(w1=self.split()))
        self.capture(self.h.cmd_apply, [])
        self.capture(self.h.cmd_set_sizes, ["1", "s:=0.2,0.8"])     # as a resize would
        self.write_config(document(w1=self.split()))                 # the editor saves the old shares back
        self.calls.clear()
        self.capture(self.h.cmd_apply, [])
        commands = [c[0] for c in self.calls]
        self.assertIn("eval", commands)           # the live layout is put back in step
        self.assertNotIn("reload", commands)
        self.assertIn("0.5", self.h.TREES.read_text())

    def test_a_first_apply_reloads_because_there_is_nothing_to_compare(self):
        self.write_config(document(w1=self.split()))
        self.capture(self.h.cmd_apply, [])
        self.assertIn("reload", [c[0] for c in self.calls])

    def test_a_hostile_class_reaches_the_live_push_as_a_string(self):
        self.write_config(document(w1=self.split()))
        self.capture(self.h.cmd_apply, [])
        self.calls.clear()
        self.write_config(document(w1=leaf([{"class": 'a"]=os.exit()--', "name": "x", "desktop": ""}])))
        self.capture(self.h.cmd_apply, [])
        pushed = [c[1] for c in self.calls if c[0] == "eval"]
        for text in pushed:
            self.assertNotIn("os.exit()", text.replace('\\"', ""))

    # ---- the helper

    def test_set_sizes_stores_a_split_and_leaves_everything_else(self):
        self.write_config(document(w1=self.split()))
        self.assertEqual(self.capture(self.h.cmd_set_sizes, ["1", "s:=0.3,0.7"])[0], 0)
        doc = json.loads(self.h.CONFIG.read_bytes())
        self.assertEqual([round(v, 3) for v in doc["workspaces"]["1"]["root"]["sizes"]], [0.3, 0.7])
        self.assertEqual(len(doc["workspaces"]["1"]["root"]["children"]), 2)

    def test_set_sizes_stores_shares_inside_a_tile(self):
        self.write_config(document(w1=leaf(["foot", "code"])))
        self.assertEqual(self.capture(self.h.cmd_set_sizes, ["1", "w:=0.25,0.75"])[0], 0)
        doc = json.loads(self.h.CONFIG.read_bytes())
        self.assertEqual([round(v, 3) for v in doc["workspaces"]["1"]["root"]["shares"]], [0.25, 0.75])

    def test_set_sizes_reaches_a_nested_split(self):
        inner = self.split()
        outer = {"dir": "v", "sizes": [0.5, 0.5], "children": [leaf(["mpv"]), inner]}
        self.write_config(document(w1=outer))
        self.assertEqual(self.capture(self.h.cmd_set_sizes, ["1", "s:2=0.2,0.8"])[0], 0)
        doc = json.loads(self.h.CONFIG.read_bytes())
        self.assertEqual([round(v, 3) for v in doc["workspaces"]["1"]["root"]["children"][1]["sizes"]], [0.2, 0.8])

    def test_set_sizes_touches_the_document_only(self):
        self.write_config(document(w1=self.split()))
        self.capture(self.h.cmd_apply, [])
        before = self.h.GENERATED.read_bytes()
        self.calls.clear()
        self.capture(self.h.cmd_set_sizes, ["1", "s:=0.3,0.7"])
        self.assertEqual(self.h.GENERATED.read_bytes(), before)   # no write, so no auto-reload
        self.assertEqual(self.calls, [])

    def test_a_resize_writes_the_proportions_file_instead(self):
        self.write_config(document(w1=self.split()))
        self.capture(self.h.cmd_apply, [])
        layout = self.h.GENERATED.read_bytes()
        self.calls.clear()
        self.capture(self.h.cmd_set_sizes, ["1", "s:=0.3,0.7"])
        self.assertEqual(self.h.GENERATED.read_bytes(), layout)    # the watched file is untouched
        trees = self.h.TREES.read_text()
        self.assertTrue(trees.startswith("return "))
        self.assertIn("0.3", trees)
        self.assertEqual(self.calls, [])

    def test_the_layout_file_reads_the_proportions_back(self):
        self.write_config(document(w1=self.split()))
        self.capture(self.h.cmd_apply, [])
        self.capture(self.h.cmd_set_sizes, ["1", "s:=0.25,0.75"])
        path = self.dir / "generated.lua"
        path.write_text(self.h.GENERATED.read_text())
        harness = self.dir / "harness.lua"
        harness.write_text(LUA_HARNESS)
        r = self.lua("lua", str(harness), str(path))
        self.assertTrue(r.ok, r.stderr.decode())
        self.assertIn("0.25", (self.dir / "sizes.txt").read_text())

    def test_a_proportions_file_that_is_nonsense_is_ignored(self):
        self.write_config(document(w1=self.split()))
        self.capture(self.h.cmd_apply, [])
        for junk in ("return os.exit()", "this is not lua", "return 5", ""):
            self.h.TREES.write_text(junk)
            path = self.dir / "generated.lua"
            path.write_text(self.h.GENERATED.read_text())
            harness = self.dir / "harness.lua"
            harness.write_text(LUA_HARNESS)
            r = self.lua("lua", str(harness), str(path))
            self.assertTrue(r.ok, junk + ": " + r.stderr.decode())
            self.assertIn("0.5", (self.dir / "sizes.txt").read_text(), junk)

    def test_set_sizes_refuses_what_it_cannot_read(self):
        self.write_config(document(w1=self.split()))
        for args in (["1"], ["1", "s:=0.5,0.5", "extra"], ["0", "s:=0.5,0.5"], ["1", "nope"],
                     ["1", "x:=0.5,0.5"], ["1", "s:=a,b"], ["1", "s:=" + "0.1," * 2000]):
            self.assertEqual(self.capture(self.h.cmd_set_sizes, args)[0], 2, args)
        self.assertEqual(json.loads(self.h.CONFIG.read_bytes())["workspaces"]["1"]["root"]["sizes"], [0.5, 0.5])

    def test_set_sizes_shrugs_at_a_blueprint_that_moved_on(self):
        self.write_config(document(w1=self.split()))
        for args in (["2", "s:=0.3,0.7"], ["1", "s:9=0.3,0.7"], ["1", "s:=0.3,0.3,0.4"],
                     ["1", "w:=0.3,0.7"], ["1", "s:1=0.3,0.7"]):
            self.assertEqual(self.capture(self.h.cmd_set_sizes, args)[0], 0, args)
        self.assertEqual(json.loads(self.h.CONFIG.read_bytes())["workspaces"]["1"]["root"]["sizes"], [0.5, 0.5])

    def test_shares_for_a_different_number_of_windows_are_ignored(self):
        doc = document(w1=leaf(["foot", "code"]))
        doc["workspaces"]["1"]["root"]["shares"] = [0.2, 0.3, 0.5]
        text = self.h.generate(self.h.normalize_document(doc, strict=True)[0])
        self.assertIn("shares", text)
        out = self.resize_run(doc, "foot,code", 1, "x", 0)
        widths = [int(line.split()[4]) for line in out.splitlines() if line.startswith("box")]
        self.assertEqual(widths, [500, 500])


class FullSnapshot(Sandbox):
    """A snapshot takes the whole workspace: the tiling, what floats and where, and what was
    opened fullscreen."""

    def base(self, **extra):
        out = {"workspace": {"id": 2}, "floating": False, "mapped": True, "hidden": False,
               "at": [10, 20], "size": [300, 400], "fullscreen": 0}
        out.update(extra)
        return out

    def test_a_workspace_is_read_in_two_lists(self):
        self.clients = [self.base(**{"class": "foot"}),
                        self.base(**{"class": "mpv"}, floating=True, at=[100, 200], size=[640, 480], pinned=True),
                        self.base(**{"class": "brave"}, fullscreen=2),
                        self.base(**{"class": "zed"}, fullscreen=1)]
        state = self.h.workspace_windows(2)
        self.assertEqual([w["class"] for w in state["tiled"]], ["foot", "brave", "zed"])
        self.assertEqual(state["floating"], [{"class": "mpv", "name": "mpv", "desktop": "",
                                              "x": 100, "y": 200, "w": 640, "h": 480, "pinned": True}])
        self.assertEqual([w.get("state", "") for w in state["tiled"]], ["", "fullscreen", "maximized"])

    def test_a_snapshot_keeps_all_of_it(self):
        self.write_config(document())
        self.clients = [self.base(**{"class": "foot"}, at=[0, 0], size=[500, 800]),
                        self.base(**{"class": "brave"}, at=[500, 0], size=[500, 800], fullscreen=2),
                        self.base(**{"class": "mpv"}, floating=True, at=[100, 200], size=[640, 480])]
        self.active = {"id": 2}
        code, _, err = self.capture(self.h.cmd_snapshot, [])
        self.assertEqual(code, 0, err)
        ws = json.loads(self.h.CONFIG.read_bytes())["workspaces"]["2"]
        states = {a["class"]: a.get("state", "") for a in self.h.apps_of(ws["root"])}
        self.assertEqual(states, {"foot": "", "brave": "fullscreen"})
        self.assertEqual([(f["class"], f["x"], f["w"]) for f in ws["floating"]], [("mpv", 100, 640)])
        self.assertIn("floating window", self.notes[-1][1])

    def test_the_rules_put_it_all_back(self):
        doc = document(w1=leaf([{"class": "code", "name": "Code", "desktop": ""}]))
        doc["workspaces"]["1"]["root"]["apps"][0]["state"] = "fullscreen"
        doc["workspaces"]["1"]["floating"] = [{"class": "mpv", "name": "mpv", "desktop": "",
                                               "x": 100, "y": 200, "w": 640, "h": 480, "pinned": True,
                                               "state": "maximized"}]
        text = self.h.generate(self.h.normalize_document(doc, strict=True)[0])
        self.assertIn(f'hl.window_rule({{ match = {{ class = {self.h.lua_str(self.h.class_regex("code"))} }}, '
                      'fullscreen = true })', text)
        self.assertIn('hl.window_rule({ match = { class = ' + self.h.lua_str(self.h.class_regex("mpv")) + ' }, float = true, move = "100 200", '
                      'size = "640 480", pin = true, workspace = "1 silent" })', text)
        self.assertIn('hl.window_rule({ match = { class = ' + self.h.lua_str(self.h.class_regex("mpv")) + ' }, maximize = true })', text)

    def test_floating_windows_are_checked_like_everything_else(self):
        doc = document(w1=leaf([{"class": "code", "name": "Code", "desktop": ""}]))
        doc["workspaces"]["1"]["floating"] = [
            {"class": "ok", "name": "Ok", "desktop": "", "x": 1, "y": 2, "w": 3, "h": 4},
            {"class": "code", "name": "Code", "desktop": "", "x": 1, "y": 2, "w": 3, "h": 4},  # already tiled
            {"class": "nan", "x": float("nan"), "y": 2, "w": 3, "h": 4},
            {"class": "big", "x": 0, "y": 0, "w": 10 ** 9, "h": 4},
            {"class": "zero", "x": 0, "y": 0, "w": 0, "h": 4},
            {"class": "bool", "x": True, "y": 0, "w": 4, "h": 4},
            {"class": "gone", "x": 1, "y": 2, "w": 3},
            "not a window",
        ] + [{"class": f"many{i}", "x": 1, "y": 2, "w": 3, "h": 4} for i in range(40)]
        out, _ = self.h.normalize_document(doc, strict=True)
        kept = out["workspaces"]["1"]["floating"]
        self.assertEqual(kept[0], {"class": "ok", "name": "Ok", "desktop": "", "x": 1, "y": 2, "w": 3, "h": 4})
        self.assertEqual(len(kept), self.h.MAX_FLOATING)
        self.assertNotIn("code", [f["class"] for f in kept])
        self.assertNotIn("nan", [f["class"] for f in kept])
        self.assertNotIn("big", [f["class"] for f in kept])
        self.assertNotIn("zero", [f["class"] for f in kept])
        self.assertNotIn("gone", [f["class"] for f in kept])

    def test_a_state_that_is_not_a_state_is_dropped(self):
        doc = document(w1=leaf([{"class": "code", "name": "Code", "desktop": "", "state": "sideways"}]))
        out, _ = self.h.normalize_document(doc, strict=True)
        self.assertNotIn("state", list(self.h.apps_of(out["workspaces"]["1"]["root"]))[0])

    def test_a_floating_change_is_a_rules_change_so_it_reloads(self):
        self.write_config(document(w1=leaf(["code"])))
        self.capture(self.h.cmd_apply, [])
        self.calls.clear()
        doc = document(w1=leaf(["code"]))
        doc["workspaces"]["1"]["floating"] = [{"class": "mpv", "name": "mpv", "desktop": "",
                                               "x": 1, "y": 2, "w": 3, "h": 4}]
        self.write_config(doc)
        self.capture(self.h.cmd_apply, [])
        self.assertIn("reload", [c[0] for c in self.calls])


class Apply(Sandbox):
    def valid(self):
        return document(w2=split(leaf([{"class": "code", "name": "Code", "desktop": "code"}]), leaf(["foot"])))

    def test_apply_writes_generated_file_and_reloads(self):
        self.write_config(self.valid())
        code, out, _ = self.capture(self.h.cmd_apply, [])
        self.assertEqual(code, 0)
        self.assertEqual(self.h.GENERATED.stat().st_mode & 0o777, 0o644)
        self.assertIn(["reload"], self.calls)
        self.assertIn(["configerrors"], self.calls)
        self.assertEqual(self.notes[-1][0], "Tile blueprints applied")
        self.assertEqual([p.name for p in self.h.GENERATED.parent.iterdir()], ["zz-tile-blueprints.lua"])
        self.assertTrue(self.lua("luac", "-p", str(self.h.GENERATED)).ok)

    def test_symlinked_config_is_refused(self):
        target = self.dir / "elsewhere.json"
        target.write_text(json.dumps(self.valid()))
        self.h.CONFIG.parent.mkdir(parents=True)
        self.h.CONFIG.symlink_to(target)
        code, _, err = self.capture(self.h.main, ["tile-blueprints", "apply"])
        self.assertEqual(code, 1)
        self.assertIn("symlink", err)
        self.assertFalse(self.h.GENERATED.exists())
        self.assertNotIn(["reload"], self.calls)

    def test_oversized_or_malformed_config_leaves_generated_file_alone(self):
        self.h.GENERATED.parent.mkdir(parents=True)
        self.h.GENERATED.write_text("-- previous\n")
        for raw in (b" " * (self.h.CONFIG_MAX + 1), b"{not json", b"[1, 2]", b"\xff\xfe"):
            self.write_config(None, raw)
            code, _, _ = self.capture(self.h.cmd_apply, [])
            self.assertEqual(code, 1)
            self.assertEqual(self.h.GENERATED.read_text(), "-- previous\n")
        self.assertNotIn(["reload"], self.calls)

    def test_config_command_reports_problems(self):
        self.write_config(None, b"{not json")
        code, out, _ = self.capture(self.h.cmd_config, [])
        self.assertEqual(code, 0)
        doc = json.loads(out)
        self.assertEqual(doc["workspaces"], {})
        self.assertTrue(doc["problems"])
        broken = self.valid()
        broken["workspaces"]["4"] = {"root": split(*[leaf() for _ in range(65)])}
        self.write_config(broken)
        doc = json.loads(self.capture(self.h.cmd_config, [])[1])
        self.assertEqual(list(doc["workspaces"]), ["2"])
        self.assertIn("'4'", doc["problems"][0])

    def test_apply_skips_a_broken_workspace_and_applies_the_rest(self):
        broken = self.valid()
        broken["workspaces"]["4"] = {"root": split(*[leaf() for _ in range(65)])}
        self.write_config(broken)
        code, _, err = self.capture(self.h.cmd_apply, [])
        self.assertEqual(code, 0)
        text = self.h.GENERATED.read_text()
        self.assertIn('workspace = "2"', text)
        self.assertNotIn('workspace = "4"', text)
        self.assertIn("skipped", err)

    def test_nothing_configured_removes_generated_file(self):
        self.h.GENERATED.parent.mkdir(parents=True)
        self.h.GENERATED.write_text("-- old\n")
        self.write_config({"workspaces": {}})
        self.assertEqual(self.capture(self.h.cmd_apply, [])[0], 0)
        self.assertFalse(self.h.GENERATED.exists())
        self.assertIn(["reload"], self.calls)

    def test_remove_refuses_a_symlink(self):
        self.h.GENERATED.parent.mkdir(parents=True)
        victim = self.dir / "victim.lua"
        victim.write_text("keep")
        self.h.GENERATED.symlink_to(victim)
        code, _, _ = self.capture(self.h.main, ["tile-blueprints", "remove"])
        self.assertEqual(code, 1)
        self.assertEqual(victim.read_text(), "keep")

    def test_hyprland_errors_are_reported_not_arranged(self):
        def errors(args, timeout=None, max_output=None):
            self.calls.append(list(args))
            if args == ["configerrors"]:
                return safe.Result(0, b"zz-tile-blueprints.lua:3: boom\x1b[31m\nunrelated\n", b"", False, False)
            return safe.Result(0, b"[]", b"", False, False)
        self.h.hyprctl = errors
        self.write_config(self.valid())
        code, _, err = self.capture(self.h.cmd_apply, [])
        self.assertEqual(code, 1)
        self.assertNotIn(["-j", "clients"], self.calls)
        self.assertNotIn("\x1b", self.notes[-1][1])


# ------------------------------------------------------------------ write (stdin)

class Write(Sandbox):
    def payload(self, doc):
        return json.dumps(doc).encode()

    def run_write(self, data, args=("--background",), close=True):
        r, w = os.pipe()
        try:
            if data:
                os.write(w, data)
            if close:
                os.close(w)
                w = None
            self.h.stdin_fd = lambda: r
            return self.capture(self.h.cmd_write, list(args))
        finally:
            os.close(r)
            if w is not None:
                os.close(w)

    def test_one_line_without_eof_like_the_editor(self):
        doc = document(w1=leaf(["foot"]))
        code, out, err = self.run_write(self.payload(doc) + b"\n", close=False)
        self.assertEqual(code, 0, err)
        saved = json.loads(self.h.CONFIG.read_text())
        self.assertEqual(saved["workspaces"]["1"]["root"]["apps"][0]["class"], "foot")
        self.assertEqual(self.h.CONFIG.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.spawned, [True])
        self.assertNotIn(["reload"], self.calls)

    def test_eof_without_newline(self):
        code, _, err = self.run_write(self.payload(document(w1=leaf(["foot"]))))
        self.assertEqual(code, 0, err)

    def test_synchronous_write_applies(self):
        code, _, err = self.run_write(self.payload(document(w1=leaf(["foot"]))), args=())
        self.assertEqual(code, 0, err)
        self.assertIn(["reload"], self.calls)
        self.assertTrue(self.h.GENERATED.exists())

    def test_document_in_argv_is_refused(self):
        code, _, err = self.run_write(b"", args=[json.dumps(document(w1=leaf(["foot"])))])
        self.assertEqual(code, 2)
        self.assertIn("stdin", err)
        self.assertFalse(self.h.CONFIG.exists())

    def test_oversized_document_is_refused(self):
        big = self.dir / "big.json"
        big.write_bytes(b'{"workspaces":{"1":{"root":{"apps":[],"pad":"' + b"x" * (self.h.STDIN_MAX) + b'"}}}}')
        fd = os.open(big, os.O_RDONLY)
        try:
            self.h.stdin_fd = lambda: fd
            code, _, err = self.capture(self.h.cmd_write, ["--background"])
        finally:
            os.close(fd)
        self.assertEqual(code, 2)
        self.assertIn("512 KB", err)
        self.assertFalse(self.h.CONFIG.exists())

    def test_limits_reject_the_whole_save(self):
        many = {"workspaces": {str(i): {"root": leaf([f"a{i}"])} for i in range(1, 12)}}
        for bad in (many, document(w1=split(*[leaf() for _ in range(65)])), [], b"not json", b'{"a":NaN'):
            data = bad if isinstance(bad, bytes) else self.payload(bad)
            code, _, _ = self.run_write(data + b"\n", close=False)
            self.assertEqual(code, 2, bad)
        self.assertFalse(self.h.CONFIG.exists())
        self.assertEqual(self.spawned, [])

    def test_no_document_times_out(self):
        r, w = os.pipe()
        try:
            with self.assertRaises(TimeoutError):
                self.h.read_document(r, timeout=0.2)
        finally:
            os.close(r)
            os.close(w)

    def test_existing_symlink_destination_is_not_followed(self):
        victim = self.dir / "victim.txt"
        victim.write_text("keep")
        self.h.CONFIG.parent.mkdir(parents=True)
        self.h.CONFIG.symlink_to(victim)
        r, w = os.pipe()
        os.write(w, self.payload(document(w1=leaf(["foot"]))) + b"\n")
        try:
            self.h.stdin_fd = lambda: r
            code, _, err = self.capture(self.h.main, ["tile-blueprints", "write", "--background"])
        finally:
            os.close(r)
            os.close(w)
        self.assertEqual(code, 1)
        self.assertEqual(victim.read_text(), "keep")


# ------------------------------------------------------------------ arrange

class Arrange(Sandbox):
    def doc(self):
        return self.h.normalize_document(document(w2=leaf(["foot", "code"])), strict=True)[0]

    def client(self, address, ws=1, cls="foot", **extra):
        return {"address": address, "class": cls, "workspace": {"id": ws}, "floating": False, **extra}

    def test_only_checked_addresses_and_workspaces_are_dispatched(self):
        self.clients = [
            self.client("0x1a2B"),
            self.client('0x1" }) os.execute("x") --'),
            self.client("address:0x1"),
            self.client("0x"),
            self.client("0x" + "f" * 17),
            self.client(12345),
            self.client("0x2", ws="1"),
            self.client("0x3", ws=True),
            self.client("0x4", ws=-98),
            self.client("0x5", ws=2),
            self.client("0x6", floating=True),
            self.client("0x7", cls="other"),
            self.client("0x8", cls="co\nde"),
            "not a client",
        ]
        moved = self.h.arrange(self.doc())
        dispatches = [c for c in self.calls if c[0] == "dispatch"]
        self.assertEqual(moved, 1)
        self.assertEqual(dispatches, [["dispatch",
                                       'hl.dsp.window.move({ workspace = "2", follow = false, window = "address:0x1a2B" })']])

    def test_move_expression_refuses_unchecked_values(self):
        for target, address in (("2 silent", "0x1"), ('2"', "0x1"), ("2", "0xzz"), ("2", "0x1 "), ("100", "0x1")):
            with self.assertRaises(safe.UnsafeError):
                self.h.move_expression(target, address)

    def test_budget_bounds_the_moves(self):
        self.clients = [self.client(f"0x{i:x}") for i in range(1, 50)]
        self.assertEqual(self.h.arrange(self.doc(), budget=0), 0)
        self.assertFalse([c for c in self.calls if c[0] == "dispatch"])

    def test_at_most_256_clients_are_considered(self):
        self.clients = [self.client(f"0x{i:x}") for i in range(1, 400)]
        self.assertEqual(self.h.arrange(self.doc()), 256)


# ------------------------------------------------------------------ discovery

class Discovery(Sandbox):
    def apps_dir(self):
        d = self.h.USER_APP_DIRS[0]
        d.mkdir(parents=True, exist_ok=True)
        return d

    def entry(self, name, body):
        path = self.apps_dir() / name
        path.write_text(body)
        return path

    def test_user_entries_are_read_safely(self):
        self.entry("foot.desktop", "[Desktop Entry]\nType=Application\nName=Foot\nIcon=foot\nStartupWMClass=foot\n")
        self.entry("hidden.desktop", "[Desktop Entry]\nName=Hidden\nNoDisplay=true\n")
        self.entry("bad id.desktop", "[Desktop Entry]\nName=Bad\n")
        self.entry("-dash.desktop", "[Desktop Entry]\nName=Dash\n")
        self.entry("huge.desktop", "[Desktop Entry]\nName=Huge\n" + "#" * (self.h.DESKTOP_FILE_MAX + 10))
        self.entry("long.desktop", "[Desktop Entry]\nName=" + "N" * 1000 + "\nIcon=../../etc/x\nStartupWMClass=a\x01b\n")
        self.entry("notentry.desktop", "just text\n")
        os.mkfifo(self.apps_dir() / "fifo.desktop")
        real = self.h.HOME / "elsewhere" / "linked.desktop"
        real.parent.mkdir()
        real.write_text("[Desktop Entry]\nName=Linked\n")
        (self.apps_dir() / "linked.desktop").symlink_to(real)
        (self.apps_dir() / "passwd.desktop").symlink_to("/etc/passwd")
        outside = self.dir / "outside.desktop"
        outside.write_text("[Desktop Entry]\nName=Outside\n")
        (self.apps_dir() / "outside.desktop").symlink_to(outside)
        self.entry("ctl\x01.desktop", "[Desktop Entry]\nName=Control\n")
        entries = self.h.desktop_entries()
        self.assertEqual(sorted(entries), ["-dash", "bad id", "foot", "linked", "long"])
        self.assertEqual(entries["foot"], {"stem": "foot", "desktop": "foot", "name": "Foot", "icon": "foot", "wmclass": "foot"})
        # Listed so they can go in a tile, but never handed to gtk-launch.
        self.assertEqual((entries["bad id"]["desktop"], entries["-dash"]["desktop"]), ("", ""))
        self.clients = []
        apps = {a["class"]: a for a in json.loads(self.capture(self.h.cmd_apps, [])[1])}
        self.assertEqual(apps["bad id"]["desktop"], "")
        self.assertEqual(apps["foot"]["desktop"], "foot")
        self.assertEqual(len(entries["long"]["name"]), 256)
        self.assertEqual(entries["long"]["icon"], "")
        self.assertEqual(entries["long"]["wmclass"], "")

    def test_user_flatpak_export_links_resolve_under_home(self):
        app = self.h.HOME / ".local/share/flatpak/app/org.Example/current/active/export/share/applications"
        app.mkdir(parents=True)
        (app / "org.Example.desktop").write_text("[Desktop Entry]\nName=Example\n")
        exports = self.h.USER_APP_DIRS[1]
        exports.mkdir(parents=True)
        (exports / "org.Example.desktop").symlink_to(app / "org.Example.desktop")
        self.assertEqual(self.h.desktop_entries()["org.Example"]["name"], "Example")

    def test_user_entry_overrides_and_hides_system_entry(self):
        system = self.first_root_owned_entry()
        self.h.SYSTEM_APP_DIRS = [pathlib.Path(os.path.dirname(system))]
        desktop_id = os.path.basename(system)[:-len(".desktop")]
        self.entry(os.path.basename(system), "[Desktop Entry]\nName=Mine\nHidden=true\n")
        self.assertNotIn(desktop_id, self.h.desktop_entries())

    def first_root_owned_entry(self):
        for directory in ("/usr/share/applications", "/usr/local/share/applications"):
            try:
                names = sorted(os.listdir(directory))
            except OSError:
                continue
            for name in names:
                path = os.path.join(directory, name)
                st = os.lstat(path)
                if (name.endswith(".desktop") and self.h.valid_desktop(name[:-8]) and not os.path.islink(path)
                        and st.st_uid == 0 and st.st_size < self.h.DESKTOP_FILE_MAX):
                    return path
        self.skipTest("no root-owned desktop entry on this system")

    def test_system_reader(self):
        system = self.first_root_owned_entry()
        self.assertTrue(self.h.read_system_data(system, self.h.DESKTOP_FILE_MAX))
        with self.assertRaises(safe.TooLarge):
            self.h.read_system_data(system, 1)
        mine = self.dir / "mine.desktop"
        mine.write_text("[Desktop Entry]\nName=Mine\n")
        with self.assertRaises(safe.UnsafeError):
            self.h.read_system_data(mine, 1024)
        good_link = self.dir / "good.desktop"
        good_link.symlink_to(system)
        self.assertTrue(self.h.read_system_data(good_link, self.h.DESKTOP_FILE_MAX))
        for target in ("/etc/passwd", str(mine)):
            bad = self.dir / f"bad{len(target)}.desktop"
            bad.symlink_to(target)
            with self.assertRaises(safe.UnsafeError):
                self.h.read_system_data(bad, 1024)

    def test_system_dirs_must_be_root_owned(self):
        fake = self.dir / "usr-share-applications"
        fake.mkdir()
        (fake / "planted.desktop").write_text("[Desktop Entry]\nName=Planted\n")
        self.h.SYSTEM_APP_DIRS = [fake]
        self.assertEqual(self.h.desktop_entries(), {})

    def test_entry_count_is_capped(self):
        self.h.MAX_DESKTOP_ENTRIES = 5
        for i in range(10):
            self.entry(f"app{i}.desktop", f"[Desktop Entry]\nName=App {i}\n")
        self.assertEqual(len(self.h.desktop_entries()), 5)

    def test_icons(self):
        icon = self.h.HOME / "icons" / "app.png"
        icon.parent.mkdir()
        icon.write_bytes(b"\x89PNG")
        self.assertEqual(self.h.clean_icon("org.gnome.Nautilus"), "org.gnome.Nautilus")
        self.assertEqual(self.h.clean_icon(str(icon)), str(icon))
        for bad in ("a b", "/etc/passwd", str(self.h.HOME / "icons" / ".." / "icons" / "app.png"), "file:///x.png",
                    str(icon) + "\n", "/dev/zero.png", "x" * 2000, None):
            self.assertEqual(self.h.clean_icon(bad), "", bad)
        os.chmod(icon, 0o666)
        self.assertEqual(self.h.clean_icon(str(icon)), "")
        os.chmod(icon, 0o644)
        outside = self.dir / "outside.png"
        outside.write_bytes(b"\x89PNG")
        self.assertEqual(self.h.clean_icon(str(outside)), "")
        fifo = self.h.HOME / "icons" / "fifo.png"
        os.mkfifo(fifo)
        self.assertEqual(self.h.clean_icon(str(fifo)), "")

    def test_apps_output_is_bounded(self):
        self.h.MAX_APPS_OUT = 3
        self.clients = [{"class": f"app{i}", "workspace": {"id": 1}} for i in range(5)] + [{"class": "bad\x00"}]
        code, out, _ = self.capture(self.h.cmd_apps, [])
        self.assertEqual(code, 0)
        self.assertEqual([a["class"] for a in json.loads(out)], ["app0", "app1", "app2"])
        self.h.OUTPUT_MAX = 100
        self.assertLessEqual(len(json.loads(self.capture(self.h.cmd_apps, [])[1])), 1)

    def test_windows_output(self):
        base = {"workspace": {"id": 2}, "floating": False, "mapped": True, "hidden": False, "at": [10, 20], "size": [300, 400]}
        self.clients = ([dict(base, **{"class": "foot"}),
                         dict(base, **{"class": "fl"}, floating=True),
                         dict(base, **{"class": "hid"}, hidden=True),
                         dict(base, **{"class": "geo"}, at=["10", 20]),
                         dict(base, **{"class": "geo2"}, size=[True, 1]),
                         dict(base, **{"class": "ws"}, workspace={"id": "2"}),
                         dict(base, **{"class": "evil\n\"]]"})]
                        + [dict(base, **{"class": f"many{i}"}) for i in range(300)])
        code, out, _ = self.capture(self.h.cmd_windows, ["2"])
        state = json.loads(out)
        windows, floating = state["tiled"], state["floating"]
        self.assertEqual(code, 0)
        self.assertEqual(len(windows), 256 - 5)  # clients() itself stops at 256; the floating one is listed apart
        self.assertEqual(windows[0], {"class": "foot", "name": "foot", "desktop": "", "x": 10, "y": 20, "w": 300, "h": 400})
        self.assertEqual([w["class"] for w in floating], ["fl"])   # kept now, with where it sits
        self.assertEqual(windows[1]["class"], "")
        for bad in (["1; rm"], ["0"], ["100"], [], ["1", "2"], ["-1"]):
            self.assertEqual(self.capture(self.h.cmd_windows, bad)[0], 2, bad)

    def test_active_workspace(self):
        for value, code, printed in (({"id": 3}, 0, {"id": 3}), ({"id": "3"}, 1, {"id": None}),
                                     ({"id": -98}, 1, {"id": None}), ([], 1, {"id": None}), ({"id": True}, 1, {"id": None})):
            self.active = value
            got = self.capture(self.h.cmd_active_workspace, [])
            self.assertEqual((got[0], json.loads(got[1])), (code, printed), value)


# ------------------------------------------------------------------ snapshot

NODE_CAPTURE = r"""
const fs = require("fs")
const vm = require("vm")
const [file, casesJson] = process.argv.slice(1)
const ctx = {}
vm.runInNewContext(fs.readFileSync(file, "utf8").replace(/^\.pragma library\s*$/m, "") + "\nthis.capture = capture", ctx)
const out = JSON.parse(casesJson).map(ws => {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity
  for (const w of ws) { x0 = Math.min(x0, w.x); y0 = Math.min(y0, w.y); x1 = Math.max(x1, w.x + w.w); y1 = Math.max(y1, w.y + w.h) }
  return ctx.capture(ws, ws.length ? { x: x0, y: y0, w: x1 - x0, h: y1 - y0 } : { x: 0, y: 0, w: 0, h: 0 })
})
process.stdout.write(JSON.stringify(out))
"""


def win(cls, x, y, w, h):
    return {"class": cls, "name": cls, "desktop": "", "x": x, "y": y, "w": w, "h": h}


def guillotine(box, depth, seed):
    """Windows filling box through random straight cuts, 8 px apart, like a tiled workspace."""
    state = [seed]

    def rand():
        state[0] = (state[0] * 1103515245 + 12345) % (1 << 31)
        return state[0] / (1 << 31)

    out = []

    def cut(x, y, w, h, level):
        if level >= depth or w < 200 or h < 200 or rand() < 0.2:
            out.append(win(f"app{len(out)}", x + 4, y + 4, w - 8, h - 8))
            return
        across = (w >= h) == (rand() < 0.7)
        span = w if across else h
        edges = [0] + sorted(int(rand() * span) for _ in range(1 + int(rand() * 2))) + [span]
        for a, b in zip(edges, edges[1:]):
            if b - a < 60:
                continue
            if across:
                cut(x + a, y, b - a, h, level + 1)
            else:
                cut(x, y + a, w, b - a, level + 1)

    cut(*box, 0)
    return out


class Snapshot(Sandbox):
    def client(self, cls, x, y, w, h, ws=3, **extra):
        return {"address": "0x1", "class": cls, "workspace": {"id": ws}, "floating": False, "mapped": True,
                "hidden": False, "at": [x, y], "size": [w, h], **extra}

    def arranged(self, ws=3):
        return [self.client("code", 12, 39, 939, 949, ws), self.client("foot", 965, 39, 623, 468, ws),
                self.client("org.telegram.desktop", 965, 521, 623, 467, ws)]

    def windows_of(self, clients):
        return [win(c["class"], *c["at"], *c["size"]) for c in clients]

    def assertTreesEqual(self, got, want):
        if "children" in want:
            self.assertEqual((got["dir"], len(got["children"]), len(got["sizes"])),
                             (want["dir"], len(want["children"]), len(want["sizes"])))
            for a, b in zip(got["sizes"], want["sizes"]):
                self.assertAlmostEqual(a, b, places=9)
            for a, b in zip(got["children"], want["children"]):
                self.assertTreesEqual(a, b)
        else:
            self.assertEqual(got, want)

    def test_capture_reads_columns_and_rows(self):
        tree = self.h.capture_tree(self.windows_of(self.arranged()))
        self.assertEqual(tree["dir"], "h")
        self.assertEqual(round(tree["sizes"][0], 2), 0.6)
        self.assertEqual(tree["children"][1]["dir"], "v")
        self.assertEqual([c["apps"][0]["class"] for c in tree["children"][1]["children"]], ["foot", "org.telegram.desktop"])
        shared = self.h.capture_tree([win("a", 0, 0, 800, 800), win("b", 400, 400, 800, 800), win("A", 10, 10, 50, 50)])
        self.assertEqual([a["class"] for a in shared["apps"]], ["a", "b"])
        self.assertEqual(self.h.capture_tree([]), {"id": "t1", "apps": []})

    def test_capture_matches_the_editor(self):
        node = "/usr/bin/node"
        if not os.path.exists(node):
            self.skipTest("node not installed")
        cases = [self.windows_of(self.arranged()),
                 [win("a", 0, 0, 800, 800), win("b", 400, 400, 800, 800)],
                 [win("solo", 5, 5, 1000, 700)], [],
                 [win("a", 0, 0, 500, 500), win("b", 490, 0, 500, 500), win("c", 0, 510, 990, 300)],
                 [win("a", 0, 0, 600, 900), win("a", 610, 0, 600, 440), win("b", 610, 450, 600, 450)]]
        cases += [guillotine((0, 0, 2560, 1440), 4, seed) for seed in range(1, 60)]
        r = subprocess.run([node, "-e", NODE_CAPTURE, str(ROOT / "BlueprintModel.js"), json.dumps(cases)],
                           capture_output=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr.decode())
        expected = json.loads(r.stdout)
        self.assertEqual(len(expected), len(cases))
        self.assertGreater(max(len(c) for c in cases), 6)
        for case, want in zip(cases, expected):
            self.assertTreesEqual(self.h.capture_tree(case), want)

    def test_snapshot_saves_the_focused_workspace_and_applies(self):
        self.active = {"id": 3}
        self.clients = self.arranged() + [self.client("stray", 0, 0, 10, 10, ws=2),
                                          self.client("float", 1, 1, 50, 50, floating=True)]
        code, out, err = self.capture(self.h.cmd_snapshot, [])
        self.assertEqual(code, 0, err)
        saved = json.loads(self.h.CONFIG.read_text())
        ws = saved["workspaces"]["3"]
        self.assertEqual((ws["pin"], ws["launch"]), (False, False))
        self.assertEqual(sorted(a["class"] for a in self.h.apps_of(ws["root"])), ["code", "foot", "org.telegram.desktop"])
        self.assertEqual(self.h.CONFIG.stat().st_mode & 0o777, 0o600)
        self.assertIn(["reload"], self.calls)
        self.assertIn('workspace = "3"', self.h.GENERATED.read_text())
        self.assertEqual(self.notes[-1][0], "Workspace 3 saved as a blueprint")
        self.assertIn("3 tiles", self.notes[-1][1])
        self.assertIn("Layout only", self.notes[-1][1])

    def test_snapshot_keeps_flags_and_other_workspaces(self):
        doc = document(w2=leaf(["foot"]), w3=leaf(["old"]))
        doc["workspaces"]["3"].update(pin=True, launch=False)
        self.write_config(doc)
        self.clients = self.arranged()
        code, _, err = self.capture(self.h.cmd_snapshot, ["3"])
        self.assertEqual(code, 0, err)
        saved = json.loads(self.h.CONFIG.read_text())["workspaces"]
        self.assertEqual(sorted(saved), ["2", "3"])
        self.assertEqual((saved["3"]["pin"], saved["3"]["launch"]), (True, False))
        self.assertNotIn('"old"', json.dumps(saved["3"]))
        self.assertIn("Replaced", self.notes[-1][1])

    def test_monitors_lists_displays_and_prefers_the_stable_description(self):
        self.monitors = [
            {"name": "DP-1", "description": "Dell Inc. DELL S2721DGF DCRD223", "width": 2560, "height": 1440,
             "activeWorkspace": {"id": 1}},
            {"name": "DP-2", "description": "", "width": 1920, "height": 1080, "activeWorkspace": {"id": 2}},
            {"name": "HDMI-A-1", "description": "Odd\u2122 Panel", "width": 1280, "height": 720},
            {"name": "", "description": "nameless"},
        ]
        code, out, err = self.capture(self.h.cmd_monitors, [])
        self.assertEqual(code, 0, err)
        got = json.loads(out)
        self.assertEqual([m["rule"] for m in got],
                         ["desc:Dell Inc. DELL S2721DGF DCRD223", "DP-2", "HDMI-A-1"])
        self.assertEqual([m["workspace"] for m in got], [1, 2, 0])
        self.assertEqual(got[0]["width"], 2560)

    def test_monitors_fails_when_hyprland_cannot_answer(self):
        self.h.hypr_json = lambda *args: None
        self.assertEqual(self.capture(self.h.cmd_monitors, [])[0], 1)
        self.assertEqual(self.capture(self.h.cmd_monitors, ["1"])[0], 2)

    def test_snapshot_keeps_the_display_already_chosen(self):
        doc = document(w2=leaf(["foot"]))
        doc["workspaces"]["2"]["monitor"] = "desc:Dell Inc. DELL S2721DGF DCRD223"
        self.write_config(doc)
        self.clients = self.arranged(ws=3)
        code, _, err = self.capture(self.h.cmd_snapshot, ["3"])
        self.assertEqual(code, 0, err)
        saved = json.loads(self.h.CONFIG.read_text())["workspaces"]
        self.assertEqual(saved["2"]["monitor"], "desc:Dell Inc. DELL S2721DGF DCRD223")
        self.assertNotIn("monitor", saved["3"])   # a new snapshot records the layout only

    def test_snapshot_refusals_change_nothing(self):
        self.write_config(document(w2=leaf(["foot"])))
        before = self.h.CONFIG.read_bytes()
        for args in (["0"], ["100"], ["1", "2"], ["3;x"], ["-1"]):
            self.assertEqual(self.capture(self.h.cmd_snapshot, args)[0], 2, args)
        self.clients = self.arranged()
        self.active = {"id": -98}                    # a special workspace
        self.assertEqual(self.capture(self.h.cmd_snapshot, [])[0], 1)
        self.active = {"id": 4}                      # nothing tiled there
        self.assertEqual(self.capture(self.h.cmd_snapshot, [])[0], 1)
        self.assertEqual(self.h.CONFIG.read_bytes(), before)
        self.assertNotIn(["reload"], self.calls)

    def test_snapshot_respects_limits_and_unreadable_files(self):
        self.write_config({"workspaces": {str(i): {"root": leaf([f"a{i}"])} for i in range(1, 11)}})
        self.clients = self.arranged(ws=12)
        before = self.h.CONFIG.read_bytes()
        self.assertEqual(self.capture(self.h.cmd_snapshot, ["12"])[0], 1)
        self.assertEqual(self.h.CONFIG.read_bytes(), before)
        self.assertIn("10 workspaces", self.notes[-1][1])
        broken = document(w2=leaf(["foot"]))
        broken["workspaces"]["4"] = {"root": split(*[leaf() for _ in range(65)])}
        self.write_config(broken)
        before = self.h.CONFIG.read_bytes()
        self.clients = self.arranged()
        self.assertEqual(self.capture(self.h.cmd_snapshot, ["3"])[0], 1)
        self.assertEqual(self.h.CONFIG.read_bytes(), before)
        self.write_config(None, b"{not json")
        self.assertEqual(self.capture(self.h.cmd_snapshot, ["3"])[0], 1)
        self.assertEqual(self.h.CONFIG.read_bytes(), b"{not json")
        self.assertNotIn(["reload"], self.calls)

    def test_too_many_windows_for_one_blueprint(self):
        self.clients = [self.client(f"app{i}", i * 30, 0, 20, 20) for i in range(70)]
        self.assertEqual(self.capture(self.h.cmd_snapshot, ["3"])[0], 1)
        self.assertFalse(self.h.CONFIG.exists())
        self.assertIn("64", self.notes[-1][1])


# ------------------------------------------------------------------ packaging

class Launch(Sandbox):
    def setUp(self):
        super().setUp()
        self.commands = []
        self.h.launch_tools = lambda: ("/usr/bin/uwsm-app", "/usr/bin/gtk-launch")
        # Every launch goes through the helper's own spawn, so nothing here starts a program.
        self.h.spawn = lambda argv, timeout=None: self.commands.append(list(argv))

    def app(self, cls, desktop=None):
        return {"class": cls, "name": cls, "desktop": cls if desktop is None else desktop}

    def test_launch_starts_the_login_apps_in_order(self):
        doc = document(w1=leaf([self.app("firefox")]),
                       w2=leaf([self.app("foot")]))
        doc["workspaces"]["2"]["launch"] = False
        doc["workspaces"]["3"] = {"root": leaf([self.app("obsidian"), {"class": "Google Messages", "desktop": ""}]),
                                  "launch": True, "pin": True}
        doc["workspaces"]["3"]["floating"] = [{"class": "htop", "desktop": "htop", "x": 1, "y": 2, "w": 3, "h": 4}]
        self.write_config(doc)
        code, out, err = self.capture(self.h.cmd_launch, [])
        self.assertEqual(code, 0, err)
        self.assertEqual(self.commands, [
            ["/usr/bin/uwsm-app", "--", "/usr/bin/gtk-launch", "firefox.desktop"],
            ["/usr/bin/uwsm-app", "--", "/usr/bin/gtk-launch", "obsidian.desktop"],
            ["/usr/bin/uwsm-app", "--", "/usr/bin/gtk-launch", "htop.desktop"],
        ])
        self.assertIn("3 app", out)
        self.assertEqual(self.notes[-1][0], "Tile blueprints launching")

    def test_launch_is_what_the_generated_file_would_have_run(self):
        doc = document(w1=leaf([self.app("firefox"), self.app("foot", "")]),
                       w2=leaf([self.app("obsidian")]))
        doc["workspaces"]["2"]["launch"] = False
        normalized, _ = self.h.normalize_document(doc)
        text = self.h.generate(normalized)
        in_file = [line.split("gtk-launch ")[1].rsplit(".desktop", 1)[0]
                   for line in text.splitlines() if "gtk-launch " in line and "hl.exec_cmd" in line]
        self.assertEqual(self.h.login_launches(normalized), in_file)
        self.assertEqual(self.h.login_launches(normalized), ["firefox"])

    def test_launch_says_so_when_nothing_opens_at_login(self):
        doc = document(w1=leaf([self.app("firefox")]))
        doc["workspaces"]["1"]["launch"] = False
        self.write_config(doc)
        code, _, err = self.capture(self.h.cmd_launch, [])
        self.assertEqual(code, 1)
        self.assertEqual(self.commands, [])
        self.assertIn("login", self.notes[-1][1])

    def test_launch_needs_the_launchers_and_takes_no_arguments(self):
        self.write_config(document(w1=leaf([self.app("firefox")])))
        self.assertEqual(self.capture(self.h.cmd_launch, ["1"])[0], 2)
        self.h.launch_tools = lambda: None
        self.assertEqual(self.capture(self.h.cmd_launch, [])[0], 1)
        self.assertEqual(self.commands, [])
        self.write_config(None, b"{not json")
        self.assertEqual(self.capture(self.h.cmd_launch, [])[0], 1)
        self.assertEqual(self.commands, [])


class Packaging(unittest.TestCase):
    def test_interpreters_and_vendored_library(self):
        for script in ("tile-blueprints", "tile-blueprints-menu-install"):
            first = (ROOT / "bin" / script).read_text().split("\n", 1)[0]
            self.assertEqual(first, "#!/usr/bin/python3", script)
        self.assertEqual(hashlib.sha256((ROOT / "bin" / "plugin_safety.py").read_bytes()).hexdigest(), LIBRARY_SHA256)
        installer = (ROOT / "bin" / "tile-blueprints-menu-install").read_text()
        self.assertNotIn("@PLUGIN_ID@", installer)
        self.assertIn('PLUGIN_ID = "reidenxerx.tile-blueprints"', installer)

    def test_no_shell_or_ambient_path_in_helper(self):
        import re
        source = (ROOT / "bin" / "tile-blueprints").read_text()
        for forbidden in ("subprocess", "os.system", "os.popen", "shell=True", "/usr/bin/env", "read_text(",
                          "write_text(", "read_bytes(", "write_bytes(", "shutil", ".tmp\"", ".bak"):
            self.assertFalse(forbidden in source, forbidden)
        # The only raw open is the root-owned system data reader's os.open with O_NOFOLLOW.
        self.assertFalse(re.search(r"(?<![.\w])open\(", source), "builtin open()")
        self.assertEqual(source.count("os.open("), 1)

    def test_qml_talks_only_to_the_helper(self):
        files = sorted(ROOT.glob("*.qml"))
        self.assertEqual([p.name for p in files], ["EditorCard.qml", "EditorPanel.qml", "TileBlueprints.qml"])
        for path in files:
            text = path.read_text()
            for forbidden in ('"hyprctl"', "execDetached", "FileView", "bash", '"sh"', "command:"):
                self.assertFalse(forbidden in text, (path.name, forbidden))
            if path.name != "TileBlueprints.qml":
                self.assertNotIn("Process", text, path.name)
        qml = (ROOT / "TileBlueprints.qml").read_text()
        for required in ('readonly property string python: "/usr/bin/python3"',
                         "proc.command = [root.python, root.helper].concat(args)",
                         "stdinEnabled: true", '["write", "--background"]', '["active-workspace"]',
                         "target.signal(15)", "target.signal(9)"):
            self.assertTrue(required in qml, required)

    def test_editor_stays_loaded_so_it_can_ask_before_closing(self):
        manifest = json.loads((ROOT / "manifest.json").read_text())
        self.assertIs(manifest["keepLoaded"], True)
        self.assertIn("PanelWindow", (ROOT / "EditorPanel.qml").read_text())
        self.assertNotIn("PanelWindow", (ROOT / "TileBlueprints.qml").read_text())

    def test_menu_snippet_parses_and_offers_snapshot(self):
        import re
        raw = (ROOT / "menu.jsonc").read_text()
        routes = json.loads("{" + re.sub(r",(\s*)$", r"\1", raw.rstrip()) + "}")
        self.assertEqual(routes["setup.tile-blueprints.snapshot"]["action"], "@PLUGIN_BIN@/tile-blueprints snapshot")

    def test_cli_rejections_end_to_end(self):
        sandbox = tempfile.mkdtemp(prefix="tile-blueprints-cli.", dir=safe.runtime_dir())
        try:
            env = {k: v for k, v in os.environ.items() if not k.startswith("XDG_") or k == "XDG_RUNTIME_DIR"}
            env.update(XDG_CONFIG_HOME=os.path.join(sandbox, "config"), XDG_STATE_HOME=os.path.join(sandbox, "state"))
            helper = [safe.tool("python3"), str(ROOT / "bin" / "tile-blueprints")]

            def run(args, stdin=b""):
                return subprocess.run(helper + args, input=stdin, env=env, capture_output=True, timeout=30)

            self.assertEqual(run(["write", '{"workspaces":{}}']).returncode, 2)
            self.assertEqual(run(["write", "--background"], b"x" * (600 * 1024)).returncode, 2)
            self.assertEqual(run(["windows", "1;reboot"]).returncode, 2)
            self.assertEqual(run(["nonsense"]).returncode, 2)
            self.assertEqual(run(["launch", "1"]).returncode, 2)
            config = run(["config"])
            self.assertEqual(config.returncode, 0)
            self.assertEqual(json.loads(config.stdout)["workspaces"], {})
            self.assertFalse(os.path.exists(os.path.join(sandbox, "config")))
        finally:
            shutil.rmtree(sandbox, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=1)
