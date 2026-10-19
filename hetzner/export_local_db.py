"""Export local MySQL database for migration to Hetzner cloud VPS.
Dumps classicrealmd, classiccharacters, and classicmangos to hetzner/database/dumps/.
"""
import os
import sys
import subprocess
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import server_control
DUMP_DIR = os.path.join(HERE, "database", "dumps")
os.makedirs(DUMP_DIR, exist_ok=True)

MYSQLDUMP = os.path.join(server_control.DB_DIR, "bin", "mysqldump.exe")
if not os.path.isfile(MYSQLDUMP):
    MYSQLDUMP = "mysqldump"

DATABASES = ["classicrealmd", "classiccharacters", "classicmangos"]

def export_db():
    print(f"=== Open Vanilla Database Exporter for Hetzner Migration ===")
    print(f"Source: 127.0.0.1:3310 (MySQL)")
    print(f"Destination folder: {DUMP_DIR}\n")
    
    success = True
    for db in DATABASES:
        out_file = os.path.join(DUMP_DIR, f"{db}.sql")
        print(f"[*] Dumping database '{db}' -> {os.path.basename(out_file)}...")
        cmd = [
            MYSQLDUMP,
            *server_control.db_args(),
            "--single-transaction",
            "--routines",
            "--triggers",
            db
        ]
        try:
            with open(out_file, "w", encoding="utf-8") as f:
                r = subprocess.run(cmd, stdout=f, stderr=subprocess.PIPE, text=True, env=server_control.db_env())
            if r.returncode == 0:
                size_mb = os.path.getsize(out_file) / (1024 * 1024)
                print(f"    [+] Success: {size_mb:.2f} MB written.")
            else:
                print(f"    [!] Error dumping '{db}': {r.stderr.strip()}")
                success = False
        except Exception as e:
            print(f"    [!] Exception: {e}")
            success = False

    if success:
        print("\n[+] All databases exported successfully!")
        print(f"    Transfer {DUMP_DIR} to your Hetzner VPS.")
    else:
        print("\n[!] One or more database exports failed.")
    return success

if __name__ == "__main__":
    if not export_db():
        sys.exit(1)
