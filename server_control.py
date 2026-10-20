import os
import re
import sys
import time
import socket
import hashlib
import subprocess

SPP_ROOT = os.environ.get("SPP_ROOT", os.path.join(os.path.expanduser("~"), "Desktop", "Games", "SPP_Classics_V2", "SPP_Server"))
DB_DIR = os.path.join(SPP_ROOT, "Server", "Database")
MYSQLD = os.path.join(DB_DIR, "bin", "mysqld.exe")
MYSQL = os.path.join(DB_DIR, "bin", "mysql.exe")
MYSQL_ADMIN = os.path.join(DB_DIR, "bin", "mysqladmin.exe")
INI_PATH = os.path.join(DB_DIR, "SPP-Database.ini")

VANILLA_BIN = os.path.join(SPP_ROOT, "Server", "Binaries", "vanilla", "Bin64")
REALMD = os.path.join(VANILLA_BIN, "realmd.exe")
MANGOSD = os.path.join(VANILLA_BIN, "mangosd.exe")
SETTINGS_DIR = os.path.join(SPP_ROOT, "Settings", "vanilla")
def _load_dotenv():
    """KEY=value lines from .env next to this file (never committed), unless already in the environment."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                k, sep, v = line.strip().partition("=")
                if sep and k and not k.startswith("#"):
                    os.environ.setdefault(k.strip(), v.strip().strip('"'))
    except OSError:
        pass


_load_dotenv()
# SPP's bundled MySQL ships with root/123456. Change it, then put MYSQL_USER / MYSQL_PASSWORD in .env.
MYSQL_HOST = os.environ.get("MYSQL_HOST", "127.0.0.1")
MYSQL_PORT = os.environ.get("MYSQL_PORT", "3310")
MYSQL_USER = os.environ.get("MYSQL_USER", "root")
MYSQL_PASSWORD = os.environ.get("MYSQL_PASSWORD", "123456")


def db_args():
    """Connection arguments for the mysql tools. The password is never on the command line (db_env)."""
    return ["-h", MYSQL_HOST, "-P", str(MYSQL_PORT), "-u", MYSQL_USER]


def db_env():
    return {**os.environ, "MYSQL_PWD": MYSQL_PASSWORD}


def sql_value(v):
    """Last guard before a value is put into SQL text: names, hex and IPs only."""
    v = str(v)
    if not re.fullmatch(r"[A-Za-z0-9.:]{1,128}", v):
        raise ValueError("unsafe SQL value")
    return v

# Keep handles only for services this process actually starts, so Stop does not kill
# unrelated MySQL or WoW server instances on the same PC.
started_processes = {}

# WoW SRP6 Constants
N = 0x894B645E89E1535BBDAD5B8B290650530801B18EBFBF5E8FAB3C82872A3E9BB7
g = 7

def is_port_open(port, host="127.0.0.1", timeout=1.0):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except (socket.timeout, ConnectionRefusedError, OSError):
        return False

def generate_srp6(username, password):
    salt = os.urandom(32)
    h1 = hashlib.sha1(f"{username.upper()}:{password.upper()}".encode('utf-8')).digest()  # nosec B324 - SHA1 is mandated by the 1.12.1 SRP6 login protocol
    # Hash the salt in the byte order used by the Classic SRP6 handshake.
    h2 = hashlib.sha1(salt[::-1] + h1).digest()  # nosec B324 - SHA1 is mandated by the 1.12.1 SRP6 login protocol
    x = int.from_bytes(h2, byteorder='little')
    v = pow(g, x, N)
    v_bytes = int.to_bytes(v, 32, byteorder='little')
    return salt.hex().upper(), v_bytes[::-1].hex().upper()

def run_mysql_query(query):
    p = subprocess.Popen([MYSQL, *db_args()], env=db_env(),
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    out, err = p.communicate(input=query)
    return p.returncode, out, err

def start_database():
    if is_port_open(3310):
        print("[DB] MySQL is already running on port 3310.")
        return True

    print("[DB] Starting MySQL daemon on port 3310...")
    cmd = [
        MYSQLD,
        f"--defaults-file={INI_PATH}",
        f"--basedir={DB_DIR}",
        f"--datadir={os.path.join(DB_DIR, 'data')}",
        "--console",
        "--standalone",
        "--explicit_defaults_for_timestamp",
        "--log_syslog=0",
        '--sql-mode='
    ]
    DETACHED = 0x00000008 | 0x00000200 # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
    started_processes["mysql"] = subprocess.Popen(
        cmd, cwd=SPP_ROOT, creationflags=DETACHED,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    
    # Wait for MySQL to accept connections
    for _ in range(25):
        if is_port_open(3310):
            print("[DB] MySQL connected successfully.")
            return True
        time.sleep(0.5)

    print("[DB] ERROR: MySQL failed to start in time.")
    return False

def start_realmd():
    if is_port_open(3724):
        print("[REALMD] Realmd is already running on port 3724.")
        return True
    print("[REALMD] Starting realmd.exe on port 3724...")
    DETACHED = 0x00000008 | 0x00000200
    started_processes["realmd"] = subprocess.Popen(
        [REALMD, "-c", "realmd.conf"], cwd=SETTINGS_DIR, creationflags=DETACHED,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    for _ in range(20):
        if is_port_open(3724):
            print("[REALMD] Realmd listening on port 3724.")
            return True
        time.sleep(0.5)
    return is_port_open(3724)

def start_mangosd():
    if is_port_open(8085):
        print("[MANGOSD] Mangosd is already running on port 8085.")
        return True
    print("[MANGOSD] Starting mangosd.exe on port 8085...")
    DETACHED = 0x00000008 | 0x00000200
    startup_log = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mangosd-startup.log")
    log_file = open(startup_log, "a", encoding="utf-8", errors="replace")
    started_processes["mangosd_log"] = log_file
    started_processes["mangosd"] = subprocess.Popen(
        [MANGOSD, "-c", "mangosd.conf"], cwd=SETTINGS_DIR, creationflags=DETACHED,
        stdin=subprocess.DEVNULL, stdout=log_file, stderr=subprocess.STDOUT
    )
    for _ in range(300):
        if is_port_open(8085):
            print("[MANGOSD] Mangosd listening on port 8085.")
            return True
        if started_processes["mangosd"].poll() is not None:
            print(f"[MANGOSD] Mangosd exited during startup. Check {startup_log}.")
            return False
        time.sleep(0.5)
    print(f"[MANGOSD] Mangosd did not listen after 150 seconds; check {startup_log}.")
    return is_port_open(8085)

def check_status():
    print("--- Server Status Check ---")
    print(f"MySQL (3310): {'RUNNING' if is_port_open(3310) else 'STOPPED'}")
    print(f"Realmd Auth (3724): {'RUNNING' if is_port_open(3724) else 'STOPPED'}")
    print(f"Mangosd World (8085): {'RUNNING' if is_port_open(8085) else 'STOPPED'}")

def stop_started_services():
    """Stop only backend services launched by this Python process."""
    mysql_proc = started_processes.get("mysql")
    if mysql_proc and mysql_proc.poll() is None and is_port_open(3310):
        try:
            subprocess.run(
                [MYSQL_ADMIN, *db_args(), "shutdown"], env=db_env(),
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10, check=False
            )
        except (OSError, subprocess.TimeoutExpired):
            pass

    for name in ("mangosd", "realmd"):
        proc = started_processes.get(name)
        if proc and proc.poll() is None:
            subprocess.run(
                ["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False
            )
    log = started_processes.get("mangosd_log")
    if log:
        try:
            log.close()
        except Exception:
            pass
    started_processes.clear()

def start_all():
    print("=== Starting SPP Classics Vanilla Server ===")
    if not start_database():
        print("Aborting: Database failed to start.")
        return False
    if not start_realmd():
        print("Aborting: Authentication server failed to start.")
        return False
    if not start_mangosd():
        print("Aborting: World server failed to become ready.")
        return False
    check_status()
    return True

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "status":
        check_status()
    elif len(sys.argv) > 1 and sys.argv[1] == "start":
        start_all()
    else:
        start_all()

