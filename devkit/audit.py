"""Pre-release checks. Run: py -3 audit.py   (exit code 1 when something needs fixing)

1. secrets / personal data in every tracked text file and inside the zips in www/downloads
2. bandit (Python security lint) and pip-audit (known-vulnerable packages), if installed:
       py -3 -m pip install bandit pip-audit
"""
import os
import re
import shutil
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # the repo root (this file is in devkit/)
SKIP_DIRS = {".git", "node_modules", "release", "SPP_Server", "mysql", "CaddyData", "__pycache__", "Data", "assets"}
PATTERNS = {
    "home IP": re.compile(rb"\b72\.195\.220\.77\b"),
    "Windows user path": re.compile(rb"[Cc]:[\\/]+Users[\\/]+(?!Public)[A-Za-z0-9_.-]+[\\/]"),
    "personal email": re.compile(rb"[A-Za-z0-9._%+-]+@(gmail|outlook|hotmail|yahoo|icloud)\.com"),
    "password on a command line": re.compile(rb"""["']-p[^"'\s{]{3,}["']"""),
    "private key": re.compile(rb"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "Discord bot token": re.compile(rb"[MN][A-Za-z\d]{23}\.[\w-]{6}\.[\w-]{27}"),
    "GitHub token": re.compile(rb"gh[pousr]_[A-Za-z0-9]{36}"),
}
TEXT = re.compile(r"\.(py|js|html|json|txt|md|bat|ps1|sh|yml|yaml|toml|cfg|ini|conf|service|example)$|Caddyfile", re.I)
ALLOW = {"audit.py", "Purge_History.bat"}  # they name the patterns on purpose


def scan(name, data, problems):
    for label, rx in PATTERNS.items():
        m = rx.search(data)
        if m:
            line = data.count(b"\n", 0, m.start()) + 1
            problems.append(f"{name}:{line}: {label}")


def main():
    problems = []
    for root, dirs, files in os.walk(HERE):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for fn in files:
            path = os.path.join(root, fn)
            rel = os.path.relpath(path, HERE)
            if fn in ALLOW:
                continue
            if TEXT.search(fn):
                with open(path, "rb") as f:
                    scan(rel, f.read(), problems)
            elif fn.lower().endswith(".zip") and os.path.getsize(path) < 500e6:
                with zipfile.ZipFile(path) as z:
                    for n in z.namelist():
                        if TEXT.search(n):
                            scan(f"{rel}!{n}", z.read(n), problems)
    print(f"[1] secrets / personal data: {len(problems)} found")
    for p in problems:
        print("    " + p)

    rc = 1 if problems else 0
    py = [sys.executable, "-m"]
    if shutil.which("bandit") or subprocess.run(py + ["bandit", "--version"], capture_output=True).returncode == 0:
        r = subprocess.run(py + ["bandit", "-q", "-r", HERE, "-x", ",".join(os.path.join(HERE, d) for d in SKIP_DIRS),
                                 "-lll"], capture_output=True, text=True)  # high severity only
        print("[2] bandit (high severity):", "clean" if r.returncode == 0 else "")
        if r.returncode:
            print(r.stdout[-4000:])
            rc = 1
    else:
        print("[2] bandit not installed (py -3 -m pip install bandit)")
    req = os.path.join(HERE, "requirements.txt")
    if subprocess.run(py + ["pip_audit", "--version"], capture_output=True).returncode == 0:
        r = subprocess.run(py + ["pip_audit", "-r", req], capture_output=True, text=True)
        print("[3] pip-audit:", "clean" if r.returncode == 0 else "\n" + r.stdout[-4000:])
        rc |= r.returncode != 0
    else:
        print("[3] pip-audit not installed (py -3 -m pip install pip-audit)")
    sys.exit(rc)


if __name__ == "__main__":
    main()
