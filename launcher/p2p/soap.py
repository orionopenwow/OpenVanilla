"""mangosd console commands over SOAP (127.0.0.1 only), with the inputs checked first.

Commands are CMaNGOS classic's: `account create`, `account set password`, `kick`, `ban character`,
`unban character`, `announce`, `saveall`, `server info`.
"""
import re
import secrets

from . import P2PError, play_local

CHAR_RE = re.compile(r"^[A-Za-zÀ-ſ]{2,12}$")
ACCOUNT_RE = re.compile(r"^[A-Z0-9]{3,16}$")
PASSWORD_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"


def random_password(n=16):
    """16 characters: the 1.12 login screen's limit, upper case (SRP6 upper-cases them anyway)."""
    return "".join(secrets.choice(PASSWORD_ALPHABET) for _ in range(n))


def clean_text(text, limit=200):
    text = "".join(ch for ch in str(text) if ch.isprintable() and ch not in "<>")
    return text.strip()[:limit]


class Soap:
    def __init__(self, user, password, port, send=None):
        self.user, self.password, self.port = user, password, int(port)
        self._send = send   # send(command) -> reply text (tests)

    def command(self, cmd):
        if self._send:
            return self._send(cmd)
        P = play_local()
        try:
            return P.soap_command(cmd, self.user, self.password, self.port)
        except (P.SoloError, OSError) as e:
            raise P2PError(f"The world server didn't answer ({e}).") from None

    def create_account(self, name, password):
        if not ACCOUNT_RE.match(name) or not re.fullmatch(r"[A-Z0-9]{4,16}", password):
            raise ValueError("bad account name or password")
        return self.command(f"account create {name} {password}")

    def set_password(self, name, password):
        if not ACCOUNT_RE.match(name) or not re.fullmatch(r"[A-Z0-9]{4,16}", password):
            raise ValueError("bad account name or password")
        return self.command(f"account set password {name} {password} {password}")

    def kick(self, character):
        if not CHAR_RE.match(character or ""):
            raise P2PError("That isn't a character name.")
        return self.command(f"kick {character}")

    def ban(self, character, reason="Banned by the host", duration="-1"):
        if not CHAR_RE.match(character or ""):
            raise P2PError("That isn't a character name.")
        if not re.fullmatch(r"-1|\d{1,4}[smhdw]?", str(duration)):
            raise ValueError("bad duration")
        return self.command(f"ban character {character} {duration} {clean_text(reason, 100) or 'host'}")

    def unban(self, character):
        if not CHAR_RE.match(character or ""):
            raise P2PError("That isn't a character name.")
        return self.command(f"unban character {character}")

    def announce(self, text):
        text = clean_text(text)
        if not text:
            raise P2PError("Write something to announce.")
        return self.command(f"announce {text}")

    def saveall(self):
        return self.command("saveall")

    def info(self):
        return self.command("server info")
