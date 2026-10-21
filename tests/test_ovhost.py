"""host/ovhost (macOS/Linux realm hosting) against fake tools: Docker, uname, sw_vers, lsof.

Each test builds a bin folder whose `docker` answers like Docker Desktop / OrbStack / Docker Engine on
the OS and CPU the test picks, then runs ovhost with that bin first on PATH. The real wenilla-realm
`realmctl` runs too when OVHOST_TEST_WENILLA_REALM points at a checkout of it (skipped otherwise).
"""
import os
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OVHOST = os.path.join(ROOT, "host", "ovhost")
WENILLA_REALM = os.environ.get("OVHOST_TEST_WENILLA_REALM", "")

DOCKER = r'''#!/usr/bin/env python3
import os, sys
a = sys.argv[1:]
log = os.environ["FAKE_LOG"]
with open(log, "a") as f:
    f.write("docker " + " ".join(a) + "\n")
j = " ".join(a)
def out(s, rc=0):
    sys.stdout.write(s + ("\n" if s else "")); sys.exit(rc)
if os.environ.get("FAKE_DOCKER_DOWN") and a[:1] in (["info"], ["ps"], ["version"]):
    sys.exit(1)
if a[:1] == ["--version"]: out("Docker version 27.3.1, build ce12230")
if a[:1] == ["info"]:
    if "MemTotal" in j: out(os.environ.get("FAKE_MEM", str(8 * 1024 ** 3)))
    if "OperatingSystem" in j: out(os.environ.get("FAKE_ENGINE", "Docker Desktop|docker-desktop|[name=seccomp]"))
    out("ok")
if a[:1] == ["version"]: out("27.3.1")
if a[:2] == ["compose", "version"]: out(os.environ.get("FAKE_COMPOSE", "2.29.7"))
if a[:1] == ["run"]:
    if "uname" in a: out(os.environ.get("FAKE_AMD64", "x86_64"), 0 if os.environ.get("FAKE_AMD64", "x86_64") else 1)
    if "/data/mmaps/" in j: sys.exit(int(os.environ.get("FAKE_MMAPS_RC", "1")))
    if "curlimages/curl" in j:
        sys.stdin.read()
        out("<SOAP-ENV:Envelope><ns1:executeCommandResponse><result>CMaNGOS/0.18 uptime 3 minutes</result></ns1:executeCommandResponse></SOAP-ENV:Envelope>")
    out("")
if a[:1] == ["inspect"]:
    if "Health" in j: out("healthy")
    if "Networks" in j: out("openvanilla-realm_default ")
    out("")
if a[:1] == ["ps"]: out("")
if a[:1] == ["volume"]:
    if "ls" in a:
        for f in a:
            if f.startswith("label=com.docker.compose.volume="):
                out(os.environ.get("FAKE_PROJECT", "openvanilla-realm") + "_" + f.split("=")[-1])
    out("")
if a[:1] == ["pull"]: out("")
if a[:1] == ["compose"]:
    if "exec" in a and "setup-token" in j: out("TOKEN-123")
    if "exec" in a and "mariadb" in a:
        q = sys.stdin.read()
        with open(log, "a") as f:
            f.write("SQL " + q.replace("\n", " ") + "\n")
        out("1" if "ROW_COUNT" in q else "")
    if "ps" in a and "-q" in a: out("cid123")
    out("")
out("")
'''


def write(path, text, mode=0o755):
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, mode)


class OvhostCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ovhost-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = os.path.join(self.tmp, "bin")
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.bin)
        os.makedirs(self.home)
        self.log = os.path.join(self.tmp, "calls.log")
        open(self.log, "w").close()
        write(os.path.join(self.bin, "docker"), DOCKER)
        write(os.path.join(self.bin, "uname"), '#!/bin/sh\ncase "$1" in -s) echo "$FAKE_UNAME_S";; -m) echo "$FAKE_UNAME_M";; *) echo "$FAKE_UNAME_S";; esac\n')
        write(os.path.join(self.bin, "sw_vers"), "#!/bin/sh\necho 15.1\n")
        write(os.path.join(self.bin, "sudo"), '#!/bin/sh\n[ "$1" = -n ] && shift\nexec "$@"\n')   # runs as non-root too
        write(os.path.join(self.bin, "lsof"), '#!/bin/sh\nfor p in $FAKE_BUSY; do case "$*" in *":$p "*|*":$p") exit 0;; esac; done\nexit 1\n')
        write(os.path.join(self.bin, "df"), '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted"\necho "/dev/x 100000000 1 ${FAKE_FREE_KB:-90000000} 1% /"\n')
        write(os.path.join(self.bin, "ipconfig"), "#!/bin/sh\necho 192.168.1.20\n")
        self.osrel = os.path.join(self.tmp, "os-release")
        write(self.osrel, 'ID=ubuntu\nID_LIKE=debian\nPRETTY_NAME="Ubuntu 24.04 LTS"\n', 0o644)
        self.data = os.path.join(self.home, "World of Warcraft", "Data")
        os.makedirs(self.data)
        for n in ("dbc.MPQ", "model.MPQ", "patch.MPQ"):
            open(os.path.join(self.data, n), "w").close()

    def env(self, **kw):
        e = {"PATH": self.bin + os.pathsep + os.environ["PATH"], "HOME": self.home, "FAKE_LOG": self.log,
             "FAKE_UNAME_S": "Linux", "FAKE_UNAME_M": "x86_64", "OVHOST_OS_RELEASE": self.osrel, "TERM": "dumb"}
        e.update({k: str(v) for k, v in kw.items()})
        return e

    def no_docker_path(self):
        """A PATH with the basic tools and the fakes, but no docker at all."""
        os.remove(os.path.join(self.bin, "docker"))
        sysbin = os.path.join(self.tmp, "sysbin")
        os.makedirs(sysbin, exist_ok=True)
        for t in ("bash", "sh", "sed", "sudo", "grep", "awk", "cat", "head", "tail", "tr", "cut", "sort", "ls", "find", "dirname",
                  "mktemp", "rm", "wc", "id", "python3", "env", "printf", "mkdir", "chmod", "date", "basename", "uname"):
            real = shutil.which(t)
            if real and not os.path.exists(os.path.join(self.bin, t)):
                os.symlink(real, os.path.join(sysbin, t))
        return self.bin + os.pathsep + sysbin

    def run_ov(self, *args, **kw):
        r = subprocess.run(["bash", OVHOST, *args], env=self.env(**kw), capture_output=True, text=True,
                           stdin=subprocess.DEVNULL, timeout=120)
        return r.returncode, r.stdout + r.stderr

    def calls(self):
        return open(self.log).read()


class Doctor(OvhostCase):
    def test_linux_ready(self):
        rc, out = self.run_ov("doctor", "--dir", self.tmp)
        self.assertEqual(rc, 0, out)
        self.assertIn("Ubuntu 24.04", out)
        self.assertIn("Ready to host", out)
        self.assertIn(self.data, out)          # found the game under ~/World of Warcraft

    def test_mac_apple_silicon_without_rosetta(self):
        rc, out = self.run_ov("doctor", FAKE_UNAME_S="Darwin", FAKE_UNAME_M="arm64", FAKE_AMD64="")
        self.assertEqual(rc, 1, out)
        self.assertIn("macOS 15.1, arm64", out)
        self.assertIn("can't run x86-64 containers", out)
        self.assertIn("Use Rosetta", out)

    def test_mac_with_rosetta_and_orbstack(self):
        rc, out = self.run_ov("doctor", FAKE_UNAME_S="Darwin", FAKE_UNAME_M="arm64",
                              FAKE_ENGINE="OrbStack|orbstack|[name=seccomp]")
        self.assertEqual(rc, 0, out)
        self.assertIn("OrbStack", out)
        self.assertIn("x86-64 emulation works", out)

    def test_docker_missing_on_mac_names_the_options(self):
        env_path = self.no_docker_path()
        r = subprocess.run(["bash", OVHOST, "doctor"], env=dict(self.env(FAKE_UNAME_S="Darwin", FAKE_UNAME_M="arm64"), PATH=env_path),
                           capture_output=True, text=True, stdin=subprocess.DEVNULL)
        out = r.stdout + r.stderr
        self.assertEqual(r.returncode, 1, out)
        self.assertIn("OrbStack", out)
        self.assertIn("Colima", out)

    def test_low_docker_memory_and_old_compose(self):
        rc, out = self.run_ov("doctor", FAKE_MEM=str(2 * 1024 ** 3), FAKE_COMPOSE="2.20.2")
        self.assertEqual(rc, 1, out)
        self.assertIn("2048 MB", out)
        self.assertIn("too old", out)

    def test_little_disk(self):
        rc, out = self.run_ov("doctor", FAKE_FREE_KB=str(5 * 1024 * 1024))
        self.assertEqual(rc, 1, out)
        self.assertIn("5 GB free", out)

    def test_busy_port_suggests_other_ports(self):
        rc, out = self.run_ov("doctor", FAKE_BUSY="443")
        self.assertIn("port 443 is already in use", out)
        self.assertIn("--https-port 8443", out)

    def test_docker_install_per_distro(self):
        cases = {("arch", "", "Arch Linux"): "pacman -S --needed --noconfirm docker docker-compose",
                 ("fedora", "", "Fedora 41"): "get.docker.com",
                 ("linuxmint", "ubuntu debian", "Linux Mint 22"): "apt-get install -y docker.io docker-compose-v2",
                 ("opensuse-tumbleweed", "opensuse suse", "openSUSE"): "zypper install -y docker docker-compose",
                 ("ubuntu", "debian", "Ubuntu 24.04"): "get.docker.com"}
        for (i, like, name), want in cases.items():
            write(self.osrel, 'ID=%s\nID_LIKE="%s"\nPRETTY_NAME="%s"\n' % (i, like, name), 0o644)
            env_path = self.no_docker_path() if os.path.exists(os.path.join(self.bin, "docker")) else self.bin + os.pathsep + os.path.join(self.tmp, "sysbin")
            r = subprocess.run(["bash", OVHOST, "install", "--yes", "--local", "--dir", self.tmp], capture_output=True, text=True,
                               stdin=subprocess.DEVNULL, env=dict(self.env(OVHOST_DRY=1), PATH=env_path))
            self.assertIn(want, r.stdout + r.stderr, name)

    def test_steamos_install_explains(self):
        write(self.osrel, 'ID=steamos\nID_LIKE=arch\nPRETTY_NAME="SteamOS"\n', 0o644)
        env_path = self.no_docker_path()
        r = subprocess.run(["bash", OVHOST, "install", "--yes", "--local", "--dir", self.tmp], capture_output=True,
                           text=True, stdin=subprocess.DEVNULL, env=dict(self.env(), PATH=env_path))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("SteamOS", r.stdout + r.stderr)


class HelpAndManual(OvhostCase):
    def test_help_lists_every_command(self):
        rc, out = self.run_ov("help")
        self.assertEqual(rc, 0, out)
        for c in ("doctor", "install", "status", "backup", "restore FILE", "make-gm", "token", "manual"):
            self.assertIn(c, out)

    def test_help_for_one_command(self):
        rc, out = self.run_ov("help", "install")
        self.assertIn("--datapack DIR", out)
        self.assertIn("--native-ports", out)
        rc, out = self.run_ov("help", "nonsense")
        self.assertIn("No help for 'nonsense'", out)

    def test_manual_reads_the_chapter_and_its_sections(self):
        rc, out = self.run_ov("manual")
        self.assertEqual(rc, 0, out)
        self.assertIn("## Troubleshooting", out)
        self.assertNotIn("{#", out)              # the anchors are for the website
        self.assertNotIn("slug: host-mac-linux", out)
        rc, out = self.run_ov("manual", "trouble")
        self.assertIn("## Troubleshooting", out)
        self.assertNotIn("## Before you start", out)
        rc, out = self.run_ov("manual", "nosuch")
        self.assertNotEqual(rc, 0)

    def test_every_message_in_the_troubleshooting_table_exists_in_the_script(self):
        """The manual quotes ovhost's messages: they must still be what it prints."""
        import re
        manual = open(os.path.join(ROOT, "docs", "manual", "11b-host-mac-linux.md"), encoding="utf-8").read()
        script = open(OVHOST, encoding="utf-8").read()
        trouble = manual.split("## Troubleshooting", 1)[1].split("Other problems", 1)[0]
        quoted = re.findall(r"^\| \*\*(.+?)\*\*", trouble, re.M)
        self.assertGreater(len(quoted), 10)
        for q in quoted:
            core = re.split(r"\.\.\.", q)[0].strip()
            pat = re.sub(r"(?<![\w-])(\d+|N|DOMAIN)\b", lambda m: "\0", core)
            pat = re.escape(pat).replace("\x00", r"\S+").replace("\\\x00", r"\S+")
            self.assertRegex(script, pat, q)

    def test_every_command_in_the_manual_exists(self):
        import re
        manual = open(os.path.join(ROOT, "docs", "manual", "11b-host-mac-linux.md"), encoding="utf-8").read()
        used = set(re.findall(r"bash host/ovhost ([a-z-]+)", manual))
        rc, out = self.run_ov("help")
        for c in used:
            self.assertIn(c, out, c)


@unittest.skipUnless(WENILLA_REALM and os.path.isfile(os.path.join(WENILLA_REALM, "realmctl")),
                     "set OVHOST_TEST_WENILLA_REALM to a wenilla-realm checkout")
class Install(OvhostCase):
    def install(self, *args, **kw):
        self.dir = os.path.join(self.tmp, "realmhost")
        self.uplog = os.path.join(self.tmp, "up.log")
        stub = os.path.join(self.tmp, "realm_up_stub.sh")
        write(stub, '#!/usr/bin/env bash\nenv | grep -E "^(OW_|DOCKER_DEFAULT_PLATFORM)" | sort > "%s"\n' % self.uplog)
        return self.run_ov("install", "--yes", "--dir", self.dir, *args, OVHOST_REALM_UP=stub,
                           OVHOST_WENILLA_REALM="file://" + WENILLA_REALM, **kw)

    def read(self, *p):
        with open(os.path.join(self.dir, *p)) as f:
            return f.read()

    def compose_host(self):
        import yaml

        class L(yaml.SafeLoader):
            pass
        L.add_constructor("!override", lambda loader, node: loader.construct_sequence(node))
        return yaml.load(self.read("openvanilla-realm", "compose.host.yaml"), Loader=L)

    def test_local_on_linux_x86(self):
        rc, out = self.install("--local", "--data", os.path.join(self.home, "World of Warcraft"))
        self.assertEqual(rc, 0, out)
        env = self.read("openvanilla-realm", ".env")
        self.assertIn("REALM_DOMAIN=localhost\n", env)
        self.assertIn("CLIENT_DATA='%s'\n" % self.data, env)
        self.assertIn("COMPOSE_FILE=compose.yaml:compose.override.yaml:compose.host.yaml\n", env)
        self.assertEqual(oct(os.stat(os.path.join(self.dir, "openvanilla-realm", ".env")).st_mode & 0o777), "0o600")
        doc = self.compose_host()
        self.assertEqual(doc["services"]["caddy"]["ports"], ["127.0.0.1:80:80", "127.0.0.1:443:443", "127.0.0.1:443:443/udp"])
        self.assertNotIn("platform", str(doc))
        self.assertIn("openvanilla-mangos", self.read("openvanilla-realm", "compose.override.yaml"))
        up = open(self.uplog).read()
        self.assertIn("OW_COMMUNITY=1", up)
        self.assertNotIn("DOCKER_DEFAULT_PLATFORM", up)
        self.assertIn("--profile extract run --rm extract", self.calls())
        self.assertIn("TOKEN-123", out)
        self.assertIn("https://localhost", out)
        conf = self.read("ovhost.conf")
        self.assertIn("MODE=local", conf)

    def test_mac_apple_silicon_lan_with_desktop_ports(self):
        rc, out = self.install("--lan", "--native-ports", "--data", self.data, FAKE_UNAME_S="Darwin", FAKE_UNAME_M="arm64")
        self.assertEqual(rc, 0, out)
        self.assertIn("REALM_DOMAIN=192.168.1.20\n", self.read("openvanilla-realm", ".env"))
        doc = self.compose_host()["services"]
        for svc in ("db-init", "realmd", "mangosd", "realm", "extract"):
            self.assertEqual(doc[svc]["platform"], "linux/amd64", svc)
        self.assertNotIn("platform", doc.get("caddy", {}))      # caddy and mariadb stay native arm64
        self.assertEqual(doc["realmd"]["ports"], ["3724:3724"])
        self.assertEqual(doc["mangosd"]["ports"], ["8085:8085"])
        self.assertIn("DOCKER_DEFAULT_PLATFORM=linux/amd64", open(self.uplog).read())

    def compose_config(self):
        """The real `docker compose config` (no daemon needed) on the merged files, when it's installed."""
        real = shutil.which("docker")
        if not real or subprocess.run([real, "compose", "version"], capture_output=True).returncode != 0:
            self.skipTest("docker compose isn't installed here")
        r = subprocess.run([real, "compose", "config"], cwd=os.path.join(self.dir, "openvanilla-realm"),
                           capture_output=True, text=True, env={k: v for k, v in os.environ.items() if not k.startswith("COMPOSE")})
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def test_merged_compose_is_valid(self):
        rc, out = self.install("--lan", "--native-ports", "--https-port", "8443", "--http-port", "8080", "--data", self.data,
                               FAKE_UNAME_S="Darwin", FAKE_UNAME_M="arm64")
        self.assertEqual(rc, 0, out)
        cfg = self.compose_config()
        self.assertIn("ghcr.io/orionopenwow/openvanilla-mangos", cfg)
        self.assertIn("platform: linux/amd64", cfg)
        self.assertIn("published: \"8443\"", cfg)
        self.assertNotIn("published: \"443\"", cfg)             # !override replaced upstream's 80/443
        self.assertIn("World of Warcraft/Data", cfg)            # the quoted path with spaces survived

    def test_busy_443_moves_to_8443(self):
        rc, out = self.install("--local", "--data", self.data, FAKE_BUSY="443")
        self.assertEqual(rc, 0, out)
        self.assertIn("REALM_DOMAIN=localhost:8443\n", self.read("openvanilla-realm", ".env"))
        self.assertEqual(self.compose_host()["services"]["caddy"]["ports"][1], "127.0.0.1:8443:443")
        self.assertIn("https://localhost:8443", out)

    def test_mac_folder_docker_cannot_see(self):
        outside = os.path.join(self.tmp, "external", "Data")    # not under $HOME: Colima can't mount it
        os.makedirs(outside)
        open(os.path.join(outside, "dbc.MPQ"), "w").close()
        rc, out = self.install("--local", "--data", outside, FAKE_UNAME_S="Darwin", FAKE_UNAME_M="x86_64",
                               FAKE_ENGINE="colima|colima|[name=seccomp]")
        self.assertNotEqual(rc, 0, out)
        self.assertIn("can't read", out)

    def test_wrong_data_folder(self):
        empty = os.path.join(self.tmp, "nothing")
        os.makedirs(empty)
        rc, out = self.install("--local", "--data", empty)
        self.assertNotEqual(rc, 0)
        self.assertIn("no .MPQ archives", out)

    def test_manual_token_and_restore(self):
        rc, out = self.install("--local", "--data", self.data)
        self.assertEqual(rc, 0, out)
        self.assertIn("## Troubleshooting", self.read("MANUAL.md"))   # installed next to the realm
        self.assertIn("bash ovhost manual", out)
        rc, out = self.run_ov("token", "--dir", self.dir)
        self.assertIn("TOKEN-123", out)
        backup = os.path.join(self.home, "Downloads", "realm-20261020-0400.tar.gz")
        os.makedirs(os.path.dirname(backup))
        open(backup, "w").close()
        rc, out = self.run_ov("restore", backup, "--dir", self.dir)
        self.assertEqual(rc, 0, out)
        self.assertTrue(os.path.isfile(os.path.join(self.dir, "openvanilla-realm", "backups", "realm-20261020-0400.tar.gz")))
        self.assertIn("/opt/realm/restore.sh /backups/realm-20261020-0400.tar.gz", self.calls())

    def test_gm_tools(self):
        rc, out = self.install("--local", "--data", self.data)
        self.assertEqual(rc, 0, out)
        rc, out = self.run_ov("make-gm", "wr000041", "3", "--dir", self.dir)
        self.assertEqual(rc, 0, out)
        self.assertIn("WR000041 is GM level 3", out)
        self.assertIn("UPDATE account SET gmlevel = 3 WHERE username = 'WR000041'", self.calls())
        rc, out = self.run_ov("make-gm", "x'; DROP TABLE account; --", "--dir", self.dir)
        self.assertNotEqual(rc, 0)
        rc, out = self.run_ov("gm", ".server info", "--dir", self.dir)
        self.assertEqual(rc, 0, out)
        self.assertIn("CMaNGOS/0.18", out)
        self.assertIn("'OVHOST', 3", self.calls())               # the console account is made on first use
        self.assertTrue(os.path.isfile(os.path.join(self.dir, "ovhost.secret")))


@unittest.skipUnless(WENILLA_REALM and os.path.isfile(os.path.join(WENILLA_REALM, "realmctl")),
                     "set OVHOST_TEST_WENILLA_REALM to a wenilla-realm checkout")
class RealmUpCommunity(OvhostCase):
    """hetzner/openvanilla_realm_up.sh in community mode (OW_COMMUNITY=1), as ovhost runs it: every download and
    Docker call faked, then the compose files it writes checked with the real `docker compose config`."""

    def test_writes_a_valid_override_without_discord_or_root_paths(self):
        realm = os.path.join(self.tmp, "OpenVanillaRealm", "openvanilla-realm")
        shutil.copytree(WENILLA_REALM, realm, ignore=shutil.ignore_patterns(".git"))
        cp = os.path.join(self.tmp, "OpenVanillaRealm", "classicplus")
        r = subprocess.run(["bash", "realmctl", "init", "--yes", "--domain", "localhost", "--client-data", self.data,
                            "--mmaps", "1"], cwd=realm, env=self.env(), capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        envf = os.path.join(realm, ".env")
        with open(envf) as f:   # realmctl writes the path unquoted; ovhost quotes it (spaces: "World of Warcraft")
            lines = [l for l in f if not l.startswith("CLIENT_DATA=")]
        with open(envf, "w") as f:
            f.writelines(lines + ["CLIENT_DATA='%s'\n" % self.data, "COMPOSE_FILE=compose.yaml:compose.override.yaml\n"])
        write(os.path.join(self.bin, "curl"), '#!/bin/sh\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && { echo "# stub" > "$2"; exit 0; }; shift; done\nexit 0\n')
        script = os.path.join(ROOT, "hetzner", "openvanilla_realm_up.sh")
        r = subprocess.run(["bash", script], cwd=self.tmp, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120,
                           env=self.env(OW_REALM_DIR=realm, OW_CP=cp, OW_COMMUNITY=1, OW_WARN_MIN=0))
        out = r.stdout + r.stderr
        self.assertEqual(r.returncode, 0, out)
        self.assertIn("community realm: sign in with a password or play as a guest", out)
        self.assertNotIn("Bot token", out)                       # never asks for Discord keys
        self.assertIn("DONE. Open Vanilla is on your realm", out)
        with open(os.path.join(realm, ".env")) as f:
            env = f.read()
        self.assertIn("QUEUE_ENABLED=0", env)
        with open(os.path.join(realm, "compose.override.yaml")) as f:
            override = f.read()
        self.assertIn(cp + "/www:/app/www/ow:ro", override)
        self.assertIn(os.path.join(cp, "community-public"), override)   # not /opt/openvanilla-herald
        self.assertNotIn("/opt/", override)
        self.assertTrue(os.path.isfile(os.path.join(self.data, "patch-Z.MPQ")))
        self.assertTrue(os.path.isfile(os.path.join(cp, "www", "data-version.json")))
        real = shutil.which("docker")
        if real and subprocess.run([real, "compose", "version"], capture_output=True).returncode == 0:
            for d in ("www", "community-public"):
                os.makedirs(os.path.join(cp, d), exist_ok=True)
            c = subprocess.run([real, "compose", "config", "--quiet"], cwd=realm, capture_output=True, text=True,
                               env={k: v for k, v in os.environ.items() if not k.startswith("COMPOSE")})
            self.assertEqual(c.returncode, 0, c.stderr)


if __name__ == "__main__":
    unittest.main()
