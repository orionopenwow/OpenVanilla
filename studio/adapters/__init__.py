"""Where the realm runs. One adapter per kind of host; the rest of Studio never cares which.

  docker  the wenilla-realm Docker Compose stack (wenilla's recommended host; Linux VPS)
  spp     SPP Classics on a Windows PC (Open Vanilla Server's original setup)
  demo    a pretend realm in memory, for trying Studio without a server
"""
import os


def make_adapter(mode, base_dir, state_dir):
    mode = (mode or "").lower() or detect(base_dir)
    if mode == "docker":
        from .docker import DockerAdapter
        return DockerAdapter(base_dir, state_dir)
    if mode == "spp":
        from .spp import SppAdapter
        return SppAdapter(base_dir, state_dir)
    if mode == "demo":
        from .demo import DemoAdapter
        return DemoAdapter(base_dir, state_dir)
    raise ValueError(f"unknown Studio mode {mode!r} (use docker, spp or demo)")


def detect(base_dir):
    if os.environ.get("STUDIO_MODE"):
        return os.environ["STUDIO_MODE"].lower()
    compose_dir = os.environ.get("STUDIO_COMPOSE_DIR", "/opt/wenilla-realm")
    if os.name != "nt" and any(os.path.isfile(os.path.join(compose_dir, f)) for f in ("compose.yaml", "compose.yml", "docker-compose.yml")):
        return "docker"
    if os.name == "nt":
        return "spp"
    return "demo"
