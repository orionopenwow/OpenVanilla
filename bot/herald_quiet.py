"""Quiet logging for Herald's polling loops: an error is printed once, then at most every 10 minutes with a
count, instead of every few seconds. A missing Python package is said once, with the fix.

    from herald_quiet import warn
    warn("bridge", "can't read openvanilla_world_log", e)
"""
import time

_seen = {}       # (tag, message) -> [first, last printed, count since]
QUIET_SECONDS = 600


def warn(tag, what, err):
    msg = f"{type(err).__name__}: {err}"
    key = (tag, what, msg)
    now = time.time()
    rec = _seen.get(key)
    if isinstance(err, ModuleNotFoundError):
        if rec is None:
            _seen[key] = [now, now, 0]
            pkg = getattr(err, "name", "") or str(err)
            print(f"[{tag}] {what}: Python package '{pkg}' is missing. Install it with:  py -3 -m pip install {pkg}"
                  f"   (Start_Herald.bat does this). Quiet until Herald restarts.")
        return
    if rec is None:
        _seen[key] = [now, now, 0]
        print(f"[{tag}] {what}: {msg}")
        return
    rec[2] += 1
    if now - rec[1] >= QUIET_SECONDS:
        print(f"[{tag}] still failing ({rec[2]} more times in {int((now - rec[1]) // 60)} min): {what}: {msg}")
        rec[1], rec[2] = now, 0


def ok(tag, what):
    """Say once that something recovered (and forget its errors)."""
    gone = [k for k in _seen if k[0] == tag and k[1] == what]
    if gone:
        for k in gone:
            del _seen[k]
        print(f"[{tag}] {what}: working again")
