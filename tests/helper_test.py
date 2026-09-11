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
  workspace_rule = function(t) out[#out + 1] = "wsrule " .. hex(t.workspace) .. " " .. hex(t.layout) end,
  window_rule = function(t) out[#out + 1] = "rule " .. hex(t.match.class) .. " " .. hex(t.workspace) end,
  on = function(event, fn) out[#out + 1] = "on " .. hex(event); fn() end,
  exec_cmd = function(cmd) out[#out + 1] = "exec " .. hex(cmd) end,
}
dofile(path)
local function walk(key, node)
  if node.children then
    for _, child in ipairs(node.children) do walk(key, child) end
  else
    for _, app in ipairs(node.apps) do out[#out + 1] = "app " .. key .. " " .. hex(app) end
  end
end
for key, root in pairs(__omarchy_tiles.workspaces) do walk(key, root) end
table.sort(out)
io.write(table.concat(out, "\n"), "\n")
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
        h.USER_APP_DIRS = [h.HOME / ".local/share/applications",
                           h.HOME / ".local/share/flatpak/exports/share/applications"]
        h.SYSTEM_APP_DIRS = []
        engine = self.dir / "plugin" / "lua" / "tiles-engine.lua"
        engine.parent.mkdir(parents=True)
        shutil.copyfile(ROOT / "lua" / "tiles-engine.lua", engine)
        h.ENGINE = engine
        self.calls, self.notes, self.spawned = [], [], []
        self.clients, self.active = [], {"id": 1}
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
        elif args == ["-j", "workspaces"]:
            payload = b"[]"
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

    def test_pin_and_launch_flags(self):
        doc = document(w1=leaf([{"class": "foot", "name": "Foot", "desktop": "foot"}]))
        doc["workspaces"]["1"].update(pin=False, launch=False)
        text = self.h.generate(self.h.normalize_document(doc, strict=True)[0])
        self.assertNotIn("hl.window_rule", text)
        self.assertNotIn("exec_cmd", text)

    def test_no_launch_lines_without_trusted_tools(self):
        self.h.launch_tools = lambda: None
        doc = document(w1=leaf([{"class": "foot", "name": "Foot", "desktop": "foot"}]))
        self.assertNotIn("exec_cmd", self.h.generate(self.h.normalize_document(doc, strict=True)[0]))

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
        windows = json.loads(out)
        self.assertEqual(code, 0)
        self.assertEqual(len(windows), 256 - 5)  # clients() itself stops at 256
        self.assertEqual(windows[0], {"class": "foot", "name": "foot", "desktop": "", "x": 10, "y": 20, "w": 300, "h": 400})
        self.assertEqual(windows[1]["class"], "")
        for bad in (["1; rm"], ["0"], ["100"], [], ["1", "2"], ["-1"]):
            self.assertEqual(self.capture(self.h.cmd_windows, bad)[0], 2, bad)

    def test_active_workspace(self):
        for value, code, printed in (({"id": 3}, 0, {"id": 3}), ({"id": "3"}, 1, {"id": None}),
                                     ({"id": -98}, 1, {"id": None}), ([], 1, {"id": None}), ({"id": True}, 1, {"id": None})):
            self.active = value
            got = self.capture(self.h.cmd_active_workspace, [])
            self.assertEqual((got[0], json.loads(got[1])), (code, printed), value)


# ------------------------------------------------------------------ packaging

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
        qml = (ROOT / "TileBlueprints.qml").read_text()
        for forbidden in ('"hyprctl"', "execDetached", "FileView", "bash", '"sh"', "command:"):
            self.assertFalse(forbidden in qml, forbidden)
        for required in ('readonly property string python: "/usr/bin/python3"',
                         "proc.command = [root.python, root.helper].concat(args)",
                         "stdinEnabled: true", '["write", "--background"]', '["active-workspace"]',
                         "target.signal(15)", "target.signal(9)"):
            self.assertTrue(required in qml, required)

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
            config = run(["config"])
            self.assertEqual(config.returncode, 0)
            self.assertEqual(json.loads(config.stdout)["workspaces"], {})
            self.assertFalse(os.path.exists(os.path.join(sandbox, "config")))
        finally:
            shutil.rmtree(sandbox, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=1)
