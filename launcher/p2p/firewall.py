"""Windows Firewall rules for the host's two game ports (netsh advfirewall), added on Start hosting and
removed on Stop hosting. netsh needs an elevated process: when the launcher isn't elevated the
add fails and the host is told (Windows then asks on the first incoming connection instead, or the
relay carries the players). Elsewhere these are no-ops."""
import subprocess
import sys

RULE_PREFIX = "Open Vanilla Host TCP "


def _run_default(argv):
    kw = {"creationflags": 0x08000000} if sys.platform == "win32" else {}
    return subprocess.run(argv, capture_output=True, text=True, timeout=20, **kw)


def rule_name(port):
    return f"{RULE_PREFIX}{int(port)}"


def add_rules(ports, run=None, windows=None):
    """-> {port: True/False}. True when the rule exists afterwards."""
    windows = sys.platform == "win32" if windows is None else windows
    if not windows:
        return {int(p): True for p in ports}
    run = run or _run_default
    out = {}
    for p in ports:
        p = int(p)
        remove_rules([p], run, windows)   # never stack duplicates
        try:
            r = run(["netsh", "advfirewall", "firewall", "add", "rule", f"name={rule_name(p)}", "dir=in",
                     "action=allow", "protocol=TCP", f"localport={p}", "profile=any"])
            out[p] = r.returncode == 0
        except (OSError, subprocess.SubprocessError):
            out[p] = False
    return out


def remove_rules(ports, run=None, windows=None):
    windows = sys.platform == "win32" if windows is None else windows
    if not windows:
        return True
    run = run or _run_default
    ok = True
    for p in ports:
        try:
            run(["netsh", "advfirewall", "firewall", "delete", "rule", f"name={rule_name(int(p))}"])
        except (OSError, subprocess.SubprocessError):
            ok = False
    return ok
