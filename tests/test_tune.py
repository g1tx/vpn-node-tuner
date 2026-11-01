#!/usr/bin/env python3
"""Integration tests: real Bash/filesystem; simulated kernel and systemd only.
Run as root on Linux: sudo python3 tests/test_tune.py. No network is used.
"""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "tune.sh"
PFIFO = "qdisc pfifo_fast 0: root refcnt 2 bands 3 priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1"
FAKE = r'''#!/usr/bin/python3
import json, os, pathlib, subprocess, sys
root = pathlib.Path(os.environ["EXIT_NODE_TEST_ROOT"])
f = root / "kernel.json"
s = json.loads(f.read_text())
name, a = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
cmd = name + " " + " ".join(a)
def save():
    f.write_text(json.dumps(s, sort_keys=True))
def change():
    s["calls"].append(cmd)
    save()
def fail():
    if s.get("always_fail") and s["always_fail"] in cmd:
        change()
        print("persistent injected failure: " + cmd, file=sys.stderr)
        sys.exit(1)
    if s.get("fail") and s["fail"] in cmd:
        s["fail"] = None
        change()
        print("injected failure: " + cmd, file=sys.stderr)
        sys.exit(1)
def fq_parameters(tokens):
    result, i = {}, 0
    while i < len(tokens):
        opt = tokens[i]
        count = 18 if opt == "bands" else 3 if opt == "weights" else 0 if opt in ("pacing", "nopacing", "horizon_drop", "horizon_cap") else 1
        result[opt] = tokens[i+1:i+1+count]
        i += 1 + count
    return result
if name in ("cp", "mv"):
    fail()
    os.execv("/usr/bin/" + name, [name, *a])
elif name == "ip":
    print("default via 192.0.2.1 dev eth0" if "route" in a else "eth0 UP 192.0.2.2/24")
elif name == "sysctl":
    if "-w" in a:
        fail()
        key, val = a[-1].split("=", 1)
        if key not in s["sysctl"]: sys.exit(1)
        s["sysctl"][key] = val
        change()
    else:
        key = a[-1]
        if key not in s["sysctl"]: sys.exit(1)
        print(s["sysctl"][key] if "-n" in a else key + " = " + s["sysctl"][key])
elif name == "tc":
    if "filter" in a:
        print(s.get("filters", ""), end="")
    elif "show" in a:
        print("\n".join(s["qdisc"]))
    elif any(op in a for op in ("replace", "add", "del")):
        fail()
        if "root" in a: position, cursor = "root", a.index("root") + 1
        else:
            cursor = a.index("parent") + 1
            position = "parent " + a[cursor]
            cursor += 1
        matches = lambda old: " root " in old if position == "root" else position + " " in old
        old = next((old for old in s["qdisc"] if matches(old)), None)
        if "del" in a:
            default = s["sysctl"]["net.core.default_qdisc"]
            options = "limit 10240p flows 1024 quantum 1514 target 5ms interval 100ms memory_limit 32Mb ecn drop_batch 64" if default == "fq_codel" else ""
            row = f"qdisc {default} 0: {position} refcnt 2" + (" " + options if options else "")
            s["qdisc"] = [row if matches(value) else value for value in s["qdisc"]]
            change(); sys.exit(0)
        handle = None
        if a[cursor] == "handle":
            handle, cursor = a[cursor+1], cursor+2
        kind, opts = a[cursor], a[cursor+1:]
        if handle is not None:
            for value in s["qdisc"]:
                words = value.split()
                if words[2] == handle and (words[1] != kind or not matches(value)):
                    print("Invalid qdisc name or occupied handle", file=sys.stderr); sys.exit(1)
        elif old and old.split()[1] == kind and old.split()[2] != "0:":
            handle = old.split()[2]
        else:
            counter = s.get("next_handle", 0x8001)
            occupied = {value.split()[2] for value in s["qdisc"]}
            while f"{counter:x}:" in occupied: counter += 1
            handle = f"{counter:x}:" if kind != "pfifo_fast" else "0:"
            s["next_handle"] = counter + 1
        inplace = old and old.split()[1:3] == [kind, handle] and handle != "0:"
        if "add" in a and old and old.split()[2] != "0:":
            print("Qdisc already exists", file=sys.stderr); sys.exit(1)
        if inplace and kind == "fq_codel" and "flows" in opts:
            print("fq_codel flows is immutable after initialization", file=sys.stderr); sys.exit(1)
        if inplace and kind == "fq_codel" and "flows" not in opts:
            old_words = old.split()
            if "flows" in old_words: opts[2:2] = ["flows", old_words[old_words.index("flows")+1]]
        if kind == "fq":
            # Real tc changes a same-handle fq in place: omitted options, notably
            # nopacing and queue caps, retain their previous values.
            existing = {}
            for old in s["qdisc"]:
                words = old.split()
                matches = " root " in old if position == "root" else position + " " in old
                if matches and words[1:3] == [kind, handle]:
                    start = 4 if words[3] == "root" else 5
                    if words[start:start+1] == ["refcnt"]: start += 2
                    existing = fq_parameters(words[start:])
            for opt, values in fq_parameters(opts).items():
                if opt == "pacing":
                    if not s.get("ignore_pacing"): existing.pop("nopacing", None)
                    continue  # tc displays only nopacing, not enabled pacing.
                if opt in ("horizon_drop", "horizon_cap"):
                    existing.pop("horizon_cap" if opt == "horizon_drop" else "horizon_drop", None)
                existing[opt] = values
            order = ("limit", "flow_limit", "buckets", "orphan_mask", "nopacing", "bands", "weights",
                     "quantum", "initial_quantum", "maxrate", "defrate", "low_rate_threshold", "refill_delay",
                     "ce_threshold", "timer_slack", "horizon", "horizon_drop", "horizon_cap", "offload_horizon")
            opts = [token for opt in order if opt in existing for token in [opt, *existing[opt]]]
        # pfifo_fast prints its immutable priomap but cannot parse those options.
        if kind == "pfifo_fast":
            assert not opts, "pfifo_fast display options were incorrectly replayed"
            opts = "bands 3 priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1".split()
        else:
            for i, opt in enumerate(opts[:-1]):
                if opt in ("limit", "flow_limit") and not opts[i+1].endswith("p"):
                    opts[i+1] += "p"
        row = f"qdisc {kind} {handle} {position} refcnt 2"
        if opts: row += " " + " ".join(opts)
        s["qdisc"] = [row if (" root " in old if position == "root" else position + " " in old) else old for old in s["qdisc"]]
        change()
    else: raise AssertionError(cmd)
elif name == "modprobe":
    if not s.get("loadable", False): sys.exit(1)
    if "-n" not in a:
        fail()
        s["sysctl"]["net.ipv4.tcp_available_congestion_control"] += " bbr"
        change()
elif name == "docker":
    if a == ["ps", "-q"]: print("abc123")
    elif a[0] == "inspect": print('/proxy network=host ulimits=null memory=0 cpus=0')
    else: raise AssertionError(cmd)
elif name == "systemd-analyze":
    assert a == ["cat-config", "sysctl.d"], cmd
    fail()
    for path in sorted((root / "etc/sysctl.d").glob("*.conf")):
        print("# /etc/sysctl.d/" + path.name)
        print(path.read_text())
elif name == "systemctl":
    op = a[0]
    unit = next((v for v in a[1:] if v.endswith(".service")), None)
    unitfile = root / "etc/systemd/system" / str(unit)
    loaded = unit in s["installed"] or unitfile.exists()
    state = s["services"].get(unit, {"enabled": "not-found", "active": "inactive"})
    if op == "cat":
        if not loaded: sys.exit(1)
        print("[Service]\nExecStart=/bin/true")
    elif op == "show":
        assert "@.service" not in str(unit), "systemd show cannot inspect an uninstantiated template"
        if "--value" in a:
            prop = a[a.index("-p") + 1]
            limits = s.get("unit_limits", {}).get(unit, {"soft": "1024", "hard": "524288"})
            if prop == "LimitNOFILESoft": print(limits["soft"])
            elif prop == "LimitNOFILE": print(limits["hard"])
            else: print("loaded" if loaded else "not-found")
        else: print("LoadState=" + ("loaded" if loaded else "not-found") + "\nLimitNOFILE=1024")
    elif op == "is-enabled":
        print(state["enabled"])
        sys.exit(0 if state["enabled"] in ("enabled", "enabled-runtime") else 1)
    elif op == "is-active":
        if "--quiet" not in a: print(state["active"])
        sys.exit(0 if state["active"] == "active" else 3)
    elif op == "daemon-reload":
        fail(); change()
    elif op in ("enable", "disable", "restart", "stop"):
        fail()
        if not loaded and op in ("restart", "stop"): sys.exit(5)
        if op == "enable": state["enabled"] = "enabled-runtime" if "--runtime" in a else "enabled"
        elif op == "disable":
            state["enabled"] = "disabled" if loaded else "not-found"
            if "--now" in a: state["active"] = "inactive"
        else: state["active"] = "active" if op == "restart" else "inactive"
        s["services"][unit] = state
        change()
        if op == "restart" and unit == "exit-node-optimizer-fq.service":
            helper = root / "usr/local/sbin/exit-node-optimizer-fq"
            ret = subprocess.run(["bash", str(helper), "eth0"]).returncode
            if ret: sys.exit(ret)
    else: raise AssertionError(cmd)
else: raise AssertionError(cmd)
'''


class TunerTests(unittest.TestCase):
    def setUp(self):
        if os.geteuid() != 0:
            self.skipTest("apply/revert tests require root; use sudo (all host commands are simulated)")
        self.tmp = tempfile.TemporaryDirectory(prefix="exit-node-test-")
        self.root = Path(self.tmp.name)
        for path in ("sys/class/net/eth0", "proc", "run/systemd/system", "bin", "var/lib"):
            (self.root / path).mkdir(parents=True, exist_ok=True)
        (self.root / ".exit-node-test-root").touch()
        (self.root / "proc/meminfo").write_text("MemTotal: 1048576 kB\n")
        command = self.root / "bin/fake"
        command.write_text(FAKE)
        command.chmod(0o755)
        for name in ("ip", "tc", "sysctl", "systemctl", "systemd-analyze", "modprobe", "docker", "cp", "mv"):
            (self.root / "bin" / name).symlink_to("fake")
        self.model = {
            "sysctl": {
                "net.core.default_qdisc": "pfifo_fast",
                "net.ipv4.tcp_congestion_control": "cubic",
                "net.ipv4.tcp_moderate_rcvbuf": "1",
                "net.ipv4.tcp_mtu_probing": "0",
                "net.core.rmem_max": "212992",
                "net.core.wmem_max": "212992",
                "net.ipv4.tcp_rmem": "4096 131072 6291456",
                "net.ipv4.tcp_wmem": "4096 16384 4194304",
                "net.ipv4.tcp_available_congestion_control": "reno cubic bbr",
            },
            "qdisc": [PFIFO], "calls": [],
            "installed": ["xray.service", "xray-core@.service"], "services": {},
        }
        self.write_model()
        self.env = dict(os.environ, EXIT_NODE_TESTING="1", EXIT_NODE_TEST_ROOT=str(self.root),
                        PATH=str(self.root / "bin") + ":" + os.environ["PATH"])
        for key in ("NIC", "BANDWIDTH_MBIT", "BDP_RTT_MS", "NOFILE", "PROFILE"):
            self.env.pop(key, None)

    def tearDown(self):
        if hasattr(self, "tmp"):
            self.tmp.cleanup()

    def write_model(self):
        (self.root / "kernel.json").write_text(json.dumps(self.model, sort_keys=True))

    def read_model(self):
        return json.loads((self.root / "kernel.json").read_text())

    def run_tune(self, *args, ok=True, **env):
        result = subprocess.run(["bash", str(SCRIPT), *args], env=self.env | env,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(result.returncode == 0, ok, result.stdout)
        return result.stdout

    def file(self, path, content, mode=0o640):
        f = self.root / path.lstrip("/")
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(content)
        f.chmod(mode)
        return f

    def managed(self, path):
        return self.root / path.lstrip("/")

    def stable_model(self):
        m = self.read_model()
        m.pop("calls", None)
        m.pop("fail", None)
        m.pop("next_handle", None)
        # Kernel-assigned qdisc identities can change when restoring an implicit
        # 0: snapshot. Explicit-handle restoration is asserted separately below.
        m["qdisc"] = [" ".join([*row.split()[:2], "*:", *row.split()[3:]]) for row in m["qdisc"]]
        m["services"] = {k: v for k, v in m["services"].items() if v["enabled"] != "not-found"}
        return m

    def test_readonly_modes_have_no_mutation_or_state(self):
        before = (self.root / "kernel.json").read_bytes()
        self.assertIn("socket target=16777216B", self.run_tune("--dry-run"))
        diagnostics = self.run_tune("--diagnose")
        self.assertIn("network=host", diagnostics)
        self.assertIn("Actual egress qdisc on eth0", diagnostics)
        self.assertIn(PFIFO, diagnostics)
        self.assertEqual(before, (self.root / "kernel.json").read_bytes())
        self.assertFalse(self.managed("/var/lib/exit-node-optimizer").exists())

    def test_readonly_modes_work_without_root(self):
        self.root.chmod(0o755)
        # The checkout can live below /root (a real lab or a root CI job).
        # Give the unprivileged process a readable copy inside its fixture.
        readonly_script = self.root / "readonly-tune.sh"
        readonly_script.write_bytes(SCRIPT.read_bytes())
        readonly_script.chmod(0o644)
        before = (self.root / "kernel.json").read_bytes()
        def unprivileged():
            os.setgroups([])
            os.setgid(65534)
            os.setuid(65534)
        for mode in ("--dry-run", "--diagnose"):
            result = subprocess.run(["bash", str(readonly_script), mode], env=self.env,
                                    preexec_fn=unprivileged, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(before, (self.root / "kernel.json").read_bytes())
        self.assertFalse(self.managed("/var/lib/exit-node-optimizer").exists())

    def test_invalid_inputs_never_mutate(self):
        for name, bad in (("NIC", "eth0;touch /tmp/injected"), ("NIC", "../eth0"),
                          ("BANDWIDTH_MBIT", "0"), ("BANDWIDTH_MBIT", "999999999999"),
                          ("BANDWIDTH_MBIT", "1+2"), ("BDP_RTT_MS", "$(touch /tmp/injected)"),
                          ("BDP_RTT_MS", "2001"), ("NOFILE", "2097152")):
            with self.subTest(name=name, value=bad):
                self.run_tune("--apply", ok=False, **{name: bad})
                self.assertEqual(self.read_model()["calls"], [])
                self.assertFalse(self.managed("/var/lib/exit-node-optimizer").exists())

    def test_bounded_arithmetic_and_existing_allocations(self):
        (self.root / "proc/meminfo").write_text("MemTotal: 1024 kB\n")
        text = self.run_tune("--dry-run", BANDWIDTH_MBIT="100000", BDP_RTT_MS="2000")
        self.assertIn("BDP=25000000000B socket target=32768B", text)
        self.assertIn("net.ipv4.tcp_rmem = 4096 131072 6291456", text)
        text = self.run_tune("--dry-run", BANDWIDTH_MBIT="00001", BDP_RTT_MS="00001")
        self.assertIn("socket target=250B", text)

    def test_unsupported_bbr_and_qdisc_fail_preflight(self):
        self.model["sysctl"]["net.ipv4.tcp_available_congestion_control"] = "reno cubic"
        self.write_model()
        self.assertIn("BBR is unavailable", self.run_tune("--apply", ok=False, PROFILE="bbr"))
        self.assertEqual(self.read_model()["calls"], [])
        self.model["qdisc"] = ["qdisc cake 8001: root bandwidth 100Mbit"]
        self.write_model()
        self.assertIn("unsupported/custom", self.run_tune("--apply", ok=False))
        self.assertFalse(self.managed("/var/lib/exit-node-optimizer").exists())

    def test_repeated_apply_keeps_original_and_restarts_service(self):
        original = self.stable_model()
        custom = self.file("/etc/sysctl.d/90-exit-node-optimizer.conf", "# operator original\n", 0o640)
        limits = self.file("/etc/systemd/system/xray.service.d/90-exit-node-optimizer.conf", "[Service]\nLimitNOFILE=2048\n")
        self.run_tune("--apply")
        snapshot = self.managed("/var/lib/exit-node-optimizer/original/sysctl").read_bytes()
        self.run_tune("--apply", BANDWIDTH_MBIT="250", NOFILE="131072")
        self.assertEqual(snapshot, self.managed("/var/lib/exit-node-optimizer/original/sysctl").read_bytes())
        self.assertIn("LimitNOFILE=131072", limits.read_text())
        calls = self.read_model()["calls"]
        self.assertEqual(calls.count("systemctl restart exit-node-optimizer-fq.service"), 2)
        self.assertFalse(any("restart docker" in c or "restart xray" in c for c in calls))
        self.assertFalse(self.managed("/etc/systemd/system/xray.d/90-exit-node-optimizer.conf").exists())
        self.assertFalse(self.managed("/etc/systemd/system/xray-core@.service.d/90-exit-node-optimizer.conf").exists())
        self.run_tune("--revert")
        self.assertEqual(self.stable_model(), original)
        self.assertEqual(custom.read_text(), "# operator original\n")
        self.assertEqual(custom.stat().st_mode & 0o777, 0o640)
        self.assertEqual(limits.read_text(), "[Service]\nLimitNOFILE=2048\n")
        self.assertFalse(self.managed("/usr/local/sbin/exit-node-optimizer-fq").exists())
        self.assertFalse(self.managed("/etc/systemd/system/exit-node-optimizer-fq.service").exists())

    def test_apply_failure_rolls_back_runtime_files_and_services(self):
        for failure in ("sysctl -q -w net.ipv4.tcp_mtu_probing=1",
                        "systemctl restart exit-node-optimizer-fq.service", "tc qdisc replace"):
            with self.subTest(failure=failure):
                original = self.stable_model()
                self.model = self.read_model() | {"fail": failure}
                self.write_model()
                output = self.run_tune("--apply", ok=False)
                self.assertIn("transaction rolled back", output)
                self.assertEqual(self.stable_model(), original)
                self.assertFalse(self.managed("/etc/sysctl.d/90-exit-node-optimizer.conf").exists())
                self.assertFalse(self.managed("/var/lib/exit-node-optimizer/original").exists())

    def test_failed_reapply_restores_checkpoint_and_retains_original(self):
        original = self.stable_model()
        self.run_tune("--apply")
        applied = self.stable_model()
        content = self.managed("/etc/sysctl.d/90-exit-node-optimizer.conf").read_bytes()
        self.model = self.read_model() | {"fail": "sysctl -q -w net.ipv4.tcp_mtu_probing=1"}
        self.write_model()
        self.assertIn("transaction rolled back", self.run_tune("--apply", ok=False, BANDWIDTH_MBIT="100"))
        self.assertEqual(self.stable_model(), applied)
        self.assertEqual(self.managed("/etc/sysctl.d/90-exit-node-optimizer.conf").read_bytes(), content)
        self.run_tune("--revert")
        self.assertEqual(self.stable_model(), original)

    def test_mq_preserved_and_each_leaf_restored(self):
        self.model["qdisc"] = ["qdisc mq 0: root", "qdisc pfifo_fast 0: parent :1 refcnt 2 bands 3 priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1",
                               "qdisc fq_codel 8002: parent :2 refcnt 2 limit 2048p flows 1024 quantum 1514 target 5ms interval 100ms memory_limit 32Mb ecn drop_batch 64"]
        self.write_model()
        original = copy.deepcopy(self.model["qdisc"])
        self.run_tune("--apply", PROFILE="bbr")
        self.assertEqual(self.read_model()["qdisc"][0], "qdisc mq 0: root")
        self.assertTrue(all(row.startswith("qdisc fq ") for row in self.read_model()["qdisc"][1:]))
        self.run_tune("--revert")
        restored = self.read_model()["qdisc"]
        for before, after in zip(original, restored):
            words = after.split()
            if before.split()[2] == "0:": words[2] = "0:"
            self.assertEqual(" ".join(words), before)

    def test_fq_codel_apply_revert_cycles_with_explicit_and_implicit_handles(self):
        options = "limit 2048p flows 1024 quantum 1514 target 5ms interval 100ms memory_limit 32Mb ecn drop_batch 64"
        for handle in ("0:", "8004:"):
            with self.subTest(handle=handle):
                self.model = self.read_model()
                self.model["sysctl"]["net.core.default_qdisc"] = "fq_codel"
                self.model["qdisc"] = [f"qdisc fq_codel {handle} root refcnt 2 {options}"]
                self.write_model()
                for _ in range(2):
                    before = self.read_model()["qdisc"][0]
                    self.run_tune("--apply", PROFILE="bbr")
                    self.run_tune("--revert")
                    after = self.read_model()["qdisc"][0]
                    words = after.split()
                    if before.split()[2] == "0:": words[2] = "0:"
                    self.assertEqual(" ".join(words), before)

    def test_rollback_before_qdisc_change_handles_initialized_fq_codel(self):
        self.model["sysctl"]["net.core.default_qdisc"] = "fq_codel"
        self.model["qdisc"] = ["qdisc fq_codel 8004: root refcnt 2 limit 2048p flows 1024 quantum 1514 target 5ms interval 100ms memory_limit 32Mb ecn drop_batch 64"]
        original = copy.deepcopy(self.model)
        self.model["fail"] = "sysctl -q -w net.ipv4.tcp_mtu_probing=1"
        self.write_model()
        self.assertIn("transaction rolled back", self.run_tune("--apply", ok=False, PROFILE="bbr"))
        self.assertEqual(self.read_model()["qdisc"], original["qdisc"])

    def test_revert_recreates_fq_codel_when_immutable_flows_differ(self):
        self.model["sysctl"]["net.core.default_qdisc"] = "fq_codel"
        self.model["qdisc"] = ["qdisc fq_codel 8004: root refcnt 2 limit 2048p flows 1024 quantum 1514 target 5ms interval 100ms memory_limit 32Mb ecn drop_batch 64"]
        before = copy.deepcopy(self.model["qdisc"])
        self.write_model()
        self.run_tune("--apply", PROFILE="bbr")
        self.model = self.read_model()
        self.model["qdisc"] = [before[0].replace("flows 1024", "flows 2048")]
        self.write_model()
        self.run_tune("--revert")
        self.assertEqual(self.read_model()["qdisc"], before)

    def test_revert_refuses_swapped_mq_handles_before_qdisc_mutation(self):
        options = "limit 2048p flows 1024 quantum 1514 target 5ms interval 100ms memory_limit 32Mb ecn drop_batch 64"
        original = ["qdisc mq 1: root", f"qdisc fq_codel 8004: parent 1:1 refcnt 2 {options}",
                    f"qdisc fq_codel 8005: parent 1:2 refcnt 2 {options}"]
        self.model["qdisc"] = original
        self.write_model()
        self.run_tune("--apply", PROFILE="bbr")
        self.model = self.read_model()
        self.model["qdisc"] = [original[0], original[1].replace("8004:", "8005:"), original[2].replace("8005:", "8004:")]
        before = copy.deepcopy(self.model["qdisc"])
        self.model["calls"] = []
        self.write_model()
        self.assertIn("belongs to another attachment", self.run_tune("--revert", ok=False))
        self.assertEqual(self.read_model()["qdisc"], before)
        self.assertFalse(any(command.startswith("tc qdisc") for command in self.read_model()["calls"]))

    def test_mq_kind_changes_reserve_original_handles(self):
        options = "limit 2048p flows 1024 quantum 1514 target 5ms interval 100ms memory_limit 32Mb ecn drop_batch 64"
        original = ["qdisc mq 1: root", f"qdisc fq_codel 8002: parent 1:1 refcnt 2 {options}",
                    f"qdisc fq_codel 9000: parent 1:2 refcnt 2 {options}"]
        self.model.update(qdisc=original, next_handle=0x8001)
        self.write_model()
        self.run_tune("--apply", PROFILE="bbr")
        self.assertTrue(all(row.split()[2] not in ("8002:", "9000:") for row in self.read_model()["qdisc"][1:]))
        self.run_tune("--revert")
        self.assertEqual(self.read_model()["qdisc"], original)

    def test_boot_helper_reserves_original_handles_including_mq_root(self):
        options = "limit 2048p flows 1024 quantum 1514 target 5ms interval 100ms memory_limit 32Mb ecn drop_batch 64"
        original = ["qdisc mq fffe: root", f"qdisc fq_codel fffd: parent fffe:1 refcnt 2 {options}",
                    f"qdisc fq_codel 9000: parent fffe:2 refcnt 2 {options}"]
        self.model["qdisc"] = original
        self.write_model()
        self.run_tune("--apply", PROFILE="bbr")
        self.model = self.read_model()
        self.model["qdisc"] = [original[0], original[2].replace("9000:", "0:"), original[1].replace("fffd:", "0:")]
        self.write_model()
        helper = self.managed("/usr/local/sbin/exit-node-optimizer-fq")
        result = subprocess.run(["bash", str(helper), "eth0"], env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(all(row.split()[2] not in ("fffe:", "fffd:", "9000:") for row in self.read_model()["qdisc"][1:]))
        self.run_tune("--revert")
        self.assertEqual(sorted(self.read_model()["qdisc"]), sorted(original))

    def test_boot_helper_reserves_original_handles_with_implicit_fq_leaves(self):
        original_options = "limit 2048p flows 1024 quantum 1514 target 5ms interval 100ms memory_limit 32Mb ecn drop_batch 64"
        original = ["qdisc mq 1: root", f"qdisc fq_codel 8002: parent 1:1 refcnt 2 {original_options}",
                    f"qdisc fq_codel 9000: parent 1:2 refcnt 2 {original_options}"]
        self.model["qdisc"] = original
        self.write_model()
        self.run_tune("--apply", PROFILE="bbr")
        self.model = self.read_model()
        self.model.update(next_handle=0x8001, qdisc=[original[0],
            "qdisc fq 0: parent 1:1 refcnt 2 limit 10000p flow_limit 100p",
            "qdisc fq 0: parent 1:2 refcnt 2 limit 10000p flow_limit 100p"])
        self.write_model()
        helper = self.managed("/usr/local/sbin/exit-node-optimizer-fq")
        result = subprocess.run(["bash", str(helper), "eth0"], env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(all(row.split()[2] not in ("8002:", "9000:") for row in self.read_model()["qdisc"][1:]))
        self.run_tune("--revert")
        self.assertEqual(self.read_model()["qdisc"], original)

    def test_fq_options_replay_without_packet_or_size_display_suffixes(self):
        self.model["qdisc"] = ["qdisc fq 8001: root refcnt 2 limit 1234p flow_limit 55p buckets 1024 orphan_mask 1023 quantum 1514b initial_quantum 10Kb low_rate_threshold 550Kbit refill_delay 40ms timer_slack 10us horizon 10s horizon_drop"]
        self.write_model()
        self.run_tune("--apply")
        self.run_tune("--revert")
        restore = [c for c in self.read_model()["calls"] if c.startswith("tc qdisc replace")][-1]
        self.assertIn("limit 1234 flow_limit 55", restore)
        self.assertIn("quantum 1514 initial_quantum 10240", restore)
        self.assertIn("low_rate_threshold 550Kbit", restore)

    def test_existing_fq_enables_pacing_and_retains_queue_caps(self):
        for qdiscs in (["qdisc fq 8001: root refcnt 2 limit 1234p flow_limit 55p nopacing quantum 1514"],
                       ["qdisc mq 0: root", "qdisc fq 8001: parent :1 refcnt 2 limit 1234p flow_limit 55p nopacing quantum 1514"]):
            with self.subTest(qdiscs=qdiscs):
                self.model = self.read_model() | {"qdisc": qdiscs}
                self.write_model()
                original = self.stable_model()
                self.run_tune("--apply")
                active = self.read_model()["qdisc"][-1]
                self.assertEqual(self.read_model()["sysctl"]["net.ipv4.tcp_congestion_control"], "cubic")
                self.assertNotIn("nopacing", active)
                self.assertIn("limit 1234p flow_limit 55p", active)
                self.run_tune("--apply")
                self.assertNotIn("nopacing", self.read_model()["qdisc"][-1])
                self.run_tune("--revert")
                self.assertEqual(self.stable_model(), original)

    def test_fq_pacing_verification_failure_rolls_back(self):
        self.model.update(qdisc=["qdisc fq 8001: root refcnt 2 limit 1234p nopacing"], ignore_pacing=True)
        self.write_model()
        original = self.stable_model()
        output = self.run_tune("--apply", ok=False)
        self.assertIn("pacing verification failed", output)
        self.assertIn("transaction rolled back", output)
        self.assertEqual(self.stable_model(), original)

    def test_modern_fq_bands_weights_preserved_and_restored(self):
        options = "limit 1234p flow_limit 55p nopacing bands 3 priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1 weights 589824 196608 65536 quantum 1514"
        self.model["qdisc"] = ["qdisc fq 8001: root refcnt 2 " + options]
        self.write_model()
        original = self.stable_model()
        self.run_tune("--apply")
        self.assertIn("bands 3 priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1", self.read_model()["qdisc"][0])
        self.assertIn("weights 589824 196608 65536", self.read_model()["qdisc"][0])
        self.assertNotIn("nopacing", self.read_model()["qdisc"][0])
        self.run_tune("--revert")
        self.assertEqual(self.stable_model(), original)
        replay = [command for command in self.read_model()["calls"] if command.startswith("tc qdisc replace")][-1]
        self.assertIn("weights 589824 196608 65536", replay)

    def test_malformed_fq_bands_and_weights_fail_before_mutation(self):
        valid_map = "1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1"
        invalid_options = ("bands 2 priomap " + valid_map, "bands 3 priomap 1 2 0",
                           "bands 3 priomap " + valid_map[:-1] + "3",
                           "bands 3 priomap " + valid_map + " bands 3 priomap " + valid_map,
                           "weights 589824 196608", "weights 589824 0 65536",
                           "weights 589824 1 65536", "weights 589824 -1 65536",
                           "weights 589824 2147483648 65536", "weights 589824 x 65536",
                           "weights 589824 196608 65536 weights 589824 196608 65536")
        for options in invalid_options:
            with self.subTest(options=options):
                self.model["qdisc"] = ["qdisc fq 8001: root " + options]
                self.write_model()
                self.run_tune("--apply", ok=False)
                self.assertEqual(self.read_model()["calls"], [])
                self.assertFalse(self.managed("/var/lib/exit-node-optimizer").exists())

    def test_legacy_helper_alone_requires_explicit_migration_and_restores(self):
        old = self.file("/usr/local/sbin/xray-reality-rps-xps.sh", "#!/bin/bash\n# legacy\n", 0o755)
        service = self.file("/etc/systemd/system/xray-reality-rps-xps.service", "[Service]\nExecStart=/bin/true\n")
        self.model["services"]["xray-reality-rps-xps.service"] = {"enabled": "enabled", "active": "active"}
        self.write_model()
        backup = self.file("/etc/docker/daemon.json.xray.bak.12345", '{"ipv6":true}\n')
        daemon = self.file("/etc/docker/daemon.json", '{"ipv6":false}\n')
        self.assertIn("--migrate-legacy", self.run_tune("--apply", ok=False))
        self.assertEqual(self.read_model()["calls"], [])
        self.run_tune("--apply", "--migrate-legacy")
        self.assertFalse(old.exists())
        self.assertFalse(service.exists())
        self.run_tune("--revert")
        self.assertEqual(old.read_text(), "#!/bin/bash\n# legacy\n")
        self.assertEqual(self.read_model()["services"]["xray-reality-rps-xps.service"], {"enabled": "enabled", "active": "active"})
        self.assertEqual(daemon.read_text(), '{"ipv6":false}\n')
        self.assertEqual(backup.read_text(), '{"ipv6":true}\n')

    def test_state_symlinks_and_writable_state_refused(self):
        state = self.managed("/var/lib/exit-node-optimizer")
        state.symlink_to(self.root / "proc", target_is_directory=True)
        self.assertIn("unsafe state", self.run_tune("--apply", ok=False))
        state.unlink()
        state.mkdir(mode=0o777)
        state.chmod(0o777)
        self.assertIn("root-owned, private", self.run_tune("--apply", ok=False))
        self.assertEqual(self.read_model()["calls"], [])

    def test_missing_parameter_fails_before_mutation(self):
        del self.model["sysctl"]["net.ipv4.tcp_mtu_probing"]
        self.write_model()
        self.assertIn("unsupported required", self.run_tune("--apply", ok=False))
        self.assertEqual(self.read_model()["calls"], [])

    def test_existing_filters_and_unknown_options_are_refused(self):
        self.model["filters"] = "filter parent 1: protocol all pref 1 bpf\n"
        self.write_model()
        self.assertIn("egress filters", self.run_tune("--apply", ok=False))
        self.model.pop("filters")
        self.model["qdisc"] = ["qdisc fq 8001: root limit 10000p unknown_new_option 2"]
        self.write_model()
        self.assertIn("unsupported fq option", self.run_tune("--apply", ok=False))
        self.assertEqual(self.read_model()["calls"], [])

    def test_concurrent_writer_is_refused(self):
        import fcntl
        state = self.managed("/var/lib/exit-node-optimizer")
        state.mkdir(mode=0o700)
        with (state / "lock").open("w") as lock:
            (state / "lock").chmod(0o600)
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertIn("holds the lock", self.run_tune("--apply", ok=False))
        self.assertEqual(self.read_model()["calls"], [])

    def test_unloaded_bbr_is_checked_and_loaded_only_on_apply(self):
        self.model["sysctl"]["net.ipv4.tcp_available_congestion_control"] = "reno cubic"
        self.model["loadable"] = True
        self.write_model()
        self.run_tune("--dry-run", PROFILE="bbr")
        self.assertEqual(self.read_model()["calls"], [])
        self.assertIn("leave the module loaded", self.run_tune("--apply", PROFILE="bbr"))
        self.run_tune("--revert")
        self.assertEqual(self.read_model()["sysctl"]["net.ipv4.tcp_congestion_control"], "cubic")
        self.assertIn("bbr", self.read_model()["sysctl"]["net.ipv4.tcp_available_congestion_control"])

    def test_existing_native_nofile_ceilings_are_preserved(self):
        self.model["unit_limits"] = {"xray.service": {"soft": "200000", "hard": "400000"}}
        self.write_model()
        self.run_tune("--apply")
        limits = self.managed("/etc/systemd/system/xray.service.d/90-exit-node-optimizer.conf")
        self.assertIn("LimitNOFILE=200000:400000", limits.read_text())
        self.run_tune("--revert")

    def test_template_nofile_is_skipped_without_clobbering_existing_dropin(self):
        template = self.file("/etc/systemd/system/xray-core@.service.d/90-exit-node-optimizer.conf",
                             "[Service]\nLimitNOFILE=1048576:1048576\n")
        original = template.read_bytes()
        output = self.run_tune("--apply")
        self.assertIn("xray-core@.service: uninstantiated template; limits unchanged", output)
        self.assertEqual(template.read_bytes(), original)
        self.run_tune("--apply", NOFILE="131072")
        self.assertEqual(template.read_bytes(), original)
        self.run_tune("--revert")
        self.assertEqual(template.read_bytes(), original)

    def test_incomplete_rollback_is_an_error_and_retains_snapshots(self):
        original = self.stable_model()
        self.model["always_fail"] = "tc qdisc replace"
        self.write_model()
        self.assertIn("ROLLBACK INCOMPLETE", self.run_tune("--apply", ok=False))
        self.assertTrue(self.managed("/var/lib/exit-node-optimizer/original").exists())
        self.assertTrue(self.managed("/var/lib/exit-node-optimizer/checkpoint").exists())
        self.model = self.read_model()
        self.model.pop("always_fail")
        self.write_model()
        self.run_tune("--revert")
        self.assertEqual(self.stable_model(), original)

    def test_initial_snapshot_copy_and_publish_failure_are_recoverable(self):
        custom = self.file("/etc/sysctl.d/90-exit-node-optimizer.conf", "# initial original\n")
        for failure in ("cp -a --", "mv -T"):
            with self.subTest(failure=failure):
                original = self.stable_model()
                self.model = self.read_model() | {"fail": failure}
                self.write_model()
                self.assertIn("snapshot setup failed", self.run_tune("--apply", ok=False))
                state = self.managed("/var/lib/exit-node-optimizer")
                self.assertFalse((state / "original").exists())
                self.assertFalse((state / "checkpoint").exists())
                self.assertFalse((state / "checkpoint-staging").exists())
                self.assertFalse((state / "original-staging").exists())
                self.assertEqual(self.stable_model(), original)
                self.assertEqual(custom.read_text(), "# initial original\n")
                self.run_tune("--apply")
                self.run_tune("--revert")
                self.assertEqual(self.stable_model(), original)

    def test_failed_checkpoint_acquisition_preserves_previous_original(self):
        original = self.stable_model()
        self.run_tune("--apply")
        state = self.managed("/var/lib/exit-node-optimizer")
        original_snapshot = (state / "original/sysctl").read_bytes()
        applied = self.stable_model()
        self.model = self.read_model() | {"fail": "cp -a --"}
        self.write_model()
        self.assertIn("snapshot setup failed", self.run_tune("--apply", ok=False))
        self.assertEqual((state / "original/sysctl").read_bytes(), original_snapshot)
        self.assertFalse((state / "checkpoint").exists())
        self.assertEqual(self.stable_model(), applied)
        self.run_tune("--revert")
        self.assertEqual(self.stable_model(), original)

    def test_later_sysctl_conflict_reports_source_and_rolls_back(self):
        for assignment in ("net.ipv4.tcp_mtu_probing = 0", "  -net/ipv4/tcp_mtu_probing = 0",
                           "/net/ipv4/tcp_mtu_probing = 0", "- /net/ipv4/tcp_mtu_probing = 0",
                           "//net//ipv4//tcp_mtu_probing = 0", ".net.ipv4.tcp_mtu_probing = 0",
                           "  - //net//ipv4//tcp_mtu_probing// = 0"):
            with self.subTest(assignment=assignment):
                operator = self.file("/etc/sysctl.d/99-local.conf", assignment + "\n")
                original = self.stable_model()
                output = self.run_tune("--apply", ok=False)
                self.assertIn("persistent sysctl conflict: net.ipv4.tcp_mtu_probing", output)
                self.assertIn("/etc/sysctl.d/99-local.conf", output)
                self.assertIn("transaction rolled back", output)
                self.assertEqual(self.stable_model(), original)
                self.assertEqual(operator.read_text(), assignment + "\n")
                self.assertFalse(self.managed("/etc/sysctl.d/90-exit-node-optimizer.conf").exists())
                self.assertFalse(self.managed("/var/lib/exit-node-optimizer/original").exists())
                self.assertNotIn("sysctl -q -w net.ipv4.tcp_mtu_probing=1", self.read_model()["calls"])

    def test_matching_persistent_values_and_unrelated_keys_are_allowed(self):
        self.file("/etc/sysctl.d/99-local.conf", """# Operator's matching explicit settings
net.ipv4.tcp_mtu_probing = 0
net.ipv4.tcp_mtu_probing = 1
-net/ipv4/tcp_rmem = 4096\t131072    16777216
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv4.tcp_* = 0
""")
        self.run_tune("--apply")
        self.assertEqual(self.read_model()["sysctl"]["net.ipv4.tcp_mtu_probing"], "1")
        self.assertFalse(any("disable_ipv6=" in command for command in self.read_model()["calls"]))
        self.run_tune("--revert")

    def test_native_sysctl_precedence_read_failure_rolls_back(self):
        original = self.stable_model()
        self.model["fail"] = "systemd-analyze cat-config sysctl.d"
        self.write_model()
        output = self.run_tune("--apply", ok=False)
        self.assertIn("cannot read native sysctl.d", output)
        self.assertIn("transaction rolled back", output)
        self.assertEqual(self.stable_model(), original)
        self.assertFalse(self.managed("/etc/sysctl.d/90-exit-node-optimizer.conf").exists())

    def test_balanced_preserves_cubic_fq_codel_without_bbr(self):
        self.model["sysctl"]["net.core.default_qdisc"] = "fq_codel"
        self.model["sysctl"]["net.ipv4.tcp_available_congestion_control"] = "reno cubic"
        self.model["qdisc"] = ["qdisc fq_codel 8004: root refcnt 2 limit 2345p flows 2048 quantum 1514 target 7ms interval 120ms memory_limit 16Mb noecn drop_batch 32"]
        original = copy.deepcopy(self.model["qdisc"])
        self.write_model()
        output = self.run_tune("--apply")
        self.assertIn("profile=balanced", output)
        self.assertEqual(self.read_model()["sysctl"]["net.ipv4.tcp_congestion_control"], "cubic")
        self.assertEqual(self.read_model()["sysctl"]["net.core.default_qdisc"], "fq_codel")
        self.assertEqual(self.read_model()["qdisc"], original)
        self.assertFalse(any(command.startswith(("tc qdisc", "modprobe")) for command in self.read_model()["calls"]))
        self.run_tune("--apply")
        self.assertEqual(self.read_model()["qdisc"], original)
        self.run_tune("--revert")
        self.assertEqual(self.read_model()["qdisc"], original)

    def test_balanced_fifo_fallback_and_supported_default_qdisc(self):
        for cc, default, fallback in (("cubic", "pfifo_fast", "fq_codel"), ("bbr", "pfifo_fast", "fq"),
                                      ("bbr2", "pfifo_fast", "fq"), ("cubic", "fq", "fq_codel"),
                                      ("bbr", "fq_codel", "fq")):
            with self.subTest(cc=cc, default=default):
                self.model = self.read_model()
                self.model["sysctl"]["net.ipv4.tcp_congestion_control"] = cc
                self.model["sysctl"]["net.core.default_qdisc"] = default
                self.model["qdisc"] = [PFIFO]
                self.write_model()
                self.run_tune("--apply")
                values = self.read_model()
                self.assertEqual(values["sysctl"]["net.ipv4.tcp_congestion_control"], cc)
                self.assertEqual(values["sysctl"]["net.core.default_qdisc"], default if default in ("fq", "fq_codel") else fallback)
                self.assertTrue(values["qdisc"][0].startswith("qdisc " + fallback + " "))
                self.run_tune("--revert")

    def test_profile_change_and_repeat_preserve_first_original(self):
        self.model["sysctl"]["net.core.default_qdisc"] = "fq_codel"
        self.model["qdisc"] = ["qdisc fq_codel 8004: root refcnt 2 limit 2345p flows 1024 quantum 1514 target 7ms interval 120ms memory_limit 16Mb ecn drop_batch 32"]
        self.write_model()
        original = self.stable_model()
        self.run_tune("--apply")
        snapshot = self.managed("/var/lib/exit-node-optimizer/original/sysctl").read_bytes()
        self.run_tune("--apply", PROFILE="bbr")
        self.assertEqual(self.read_model()["sysctl"]["net.ipv4.tcp_congestion_control"], "bbr")
        self.assertTrue(self.read_model()["qdisc"][0].startswith("qdisc fq "))
        self.run_tune("--apply")
        self.assertEqual(snapshot, self.managed("/var/lib/exit-node-optimizer/original/sysctl").read_bytes())
        self.run_tune("--revert")
        self.assertEqual(self.stable_model(), original)

    def test_generated_helper_captures_profile_and_fifo_fallback(self):
        for profile, fallback in (("balanced", "fq_codel"), ("bbr", "fq")):
            with self.subTest(profile=profile):
                self.model = self.read_model()
                self.model["sysctl"]["net.ipv4.tcp_congestion_control"] = "cubic"
                self.model["qdisc"] = [PFIFO]
                self.write_model()
                self.run_tune("--apply", PROFILE=profile)
                self.model = self.read_model()
                self.model["qdisc"] = [PFIFO]
                self.write_model()
                helper = self.managed("/usr/local/sbin/exit-node-optimizer-fq")
                result = subprocess.run(["bash", str(helper), "eth0"], env=self.env | {"PROFILE": "bbr" if profile == "balanced" else "balanced", "FALLBACK_QDISC": "fq" if fallback == "fq_codel" else "fq_codel"},
                                        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertTrue(self.read_model()["qdisc"][0].startswith("qdisc " + fallback + " "))
                self.run_tune("--revert")

    def test_invalid_profile_fails_before_any_mutation(self):
        for profile in ("", "fast", "BBR", "balanced;touch /tmp/injected"):
            with self.subTest(profile=profile):
                self.assertIn("PROFILE must be balanced or bbr", self.run_tune("--apply", PROFILE=profile, ok=False))
                self.assertEqual(self.read_model()["calls"], [])
                self.assertFalse(self.managed("/var/lib/exit-node-optimizer").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
