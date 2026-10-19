import sys, os
import server_control

def set_account(username, password, gmlevel=3):
    s, v = server_control.generate_srp6(username, password)
    sql = f"""
    USE classicrealmd;
    INSERT INTO account (username, s, v, gmlevel)
    VALUES ('{username.upper()}', '{s}', '{v}', {gmlevel})
    ON DUPLICATE KEY UPDATE s='{s}', v='{v}', gmlevel={gmlevel};
    """
    ret, out, err = server_control.run_mysql_query(sql)
    if ret == 0:
        print(f"[SUCCESS] Account '{username.upper()}' set with GM Level {gmlevel} and password '{password}'!")
        return True
    else:
        print(f"[ERROR] Failed: {err}")
        return False

if __name__ == '__main__':
    user = sys.argv[1] if len(sys.argv) > 1 else 'admin'
    pwd = sys.argv[2] if len(sys.argv) > 2 else 'admin'
    lvl = int(sys.argv[3]) if len(sys.argv) > 3 else 3
    set_account(user, pwd, lvl)
