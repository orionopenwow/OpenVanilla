import os

from .. import soap as soap_mod

DB_NAMES = {
    "realmd": os.environ.get("STUDIO_DB_REALMD", "classicrealmd"),
    "characters": os.environ.get("STUDIO_DB_CHARACTERS", "classiccharacters"),
    "world": os.environ.get("STUDIO_DB_WORLD", "classicmangos"),
}


class Adapter:
    """What every host kind provides. Methods that touch processes are async."""
    mode = "base"
    label = "Realm"
    soap_url = "http://127.0.0.1:7878/"

    def __init__(self, base_dir, state_dir):
        self.base_dir = base_dir
        self.state_dir = state_dir
        self.data = None  # SqlRealmData-like
        self.backups_dir = os.path.join(state_dir, "backups")

    async def ready(self, refresh=False):
        """Make self.data usable (locate the database). refresh=True after a connection error."""

    async def services(self):
        """[{id, label, detail, state: running|starting|stopped|unknown, cpu, mem_mb, controllable}]"""
        raise NotImplementedError

    async def control(self, action, service, creds=None):
        """action: start|stop|restart; service: an id from services() or 'all'. Returns a message."""
        raise NotImplementedError

    def log_sources(self):
        return []

    async def logs(self, source, lines=200):
        return []

    async def dump(self, path):
        """Write a full SQL dump of the three databases to path."""
        raise NotImplementedError

    async def soap(self, command, user, password):
        return await soap_mod.run(self.soap_url, user, password, command)

    def security_checks(self):
        return []

    def describe(self):
        return {"mode": self.mode, "label": self.label}
