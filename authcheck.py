import hashlib, os, socket, struct

N = int("894B645E89E1535BBDAD5B8B290650530801B18EBFBF5E8FAB3C82872A3E9BB7", 16)
G = 7

def _sha(*parts):
    h = hashlib.sha1()
    for p in parts:
        h.update(p)
    return h.digest()

def _le(n, size=32):
    return n.to_bytes(size, "little")

def _recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("realmd closed the connection")
        buf += chunk
    return buf

def verify_realm_login(username, password, host="127.0.0.1", port=3724, timeout=5.0):
    """Log in to realmd with the 1.12.1 SRP6 handshake, exactly as the game client does.

    Returns (ok, detail). ok is True only when realmd accepted the password proof, so a
    freshly created account is known to work before the player ever sees the login screen.
    """
    user = username.upper().encode("ascii")
    pwd = password.upper().encode("ascii")
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        body = (b"WoW\x00" + bytes([1, 12, 1]) + struct.pack("<H", 5875) +
                b"68x\x00" + b"niW\x00" + b"SUne" + struct.pack("<I", 0) +
                socket.inet_aton("127.0.0.1") + bytes([len(user)]) + user)
        sock.sendall(bytes([0x00, 0x03]) + struct.pack("<H", len(body)) + body)

        cmd, _unk, result = _recv_exact(sock, 3)
        if cmd != 0x00:
            return False, f"unexpected reply opcode {cmd:#x}"
        if result != 0:
            return False, f"logon challenge refused (code {result:#04x})"
        B = int.from_bytes(_recv_exact(sock, 32), "little")
        g = int.from_bytes(_recv_exact(sock, _recv_exact(sock, 1)[0]), "little")
        n = int.from_bytes(_recv_exact(sock, _recv_exact(sock, 1)[0]), "little")
        salt = _recv_exact(sock, 32)
        _recv_exact(sock, 16)            # CRC salt
        flags = _recv_exact(sock, 1)[0]  # security flags (PIN/matrix/token)
        if flags:
            return False, f"account requires extra security (flags {flags:#x})"
        if g != G or n != N:
            return False, "realmd uses unexpected SRP parameters"

        a = int.from_bytes(os.urandom(32), "little") % N
        A = pow(G, a, N)
        Ab, Bb = _le(A), _le(B)
        x = int.from_bytes(_sha(salt, _sha(user + b":" + pwd)), "little")
        u = int.from_bytes(_sha(Ab, Bb), "little")
        S = pow((B - 3 * pow(G, x, N)) % N, a + u * x, N)
        Sb = _le(S)
        even, odd = _sha(Sb[0::2]), _sha(Sb[1::2])
        K = bytes(b for pair in zip(even, odd) for b in pair)
        hn, hg = _sha(_le(N)), _sha(_le(G, 1))
        M1 = _sha(bytes(x1 ^ x2 for x1, x2 in zip(hn, hg)), _sha(user), salt, Ab, Bb, K)

        sock.sendall(bytes([0x01]) + Ab + M1 + bytes(20) + bytes([0, 0]))
        cmd, result = _recv_exact(sock, 2)
        if cmd != 0x01:
            return False, f"unexpected proof reply opcode {cmd:#x}"
        if result != 0:
            return False, f"password proof rejected (code {result:#04x})"
        M2 = _recv_exact(sock, 20)
        if M2 != _sha(Ab, M1, K):
            return False, "server proof mismatch"
        return True, "login verified"
