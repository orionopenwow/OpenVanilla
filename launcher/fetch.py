"""Resumable downloads and safe zip extraction, shared by the updater (updater.py) and Play Solo (spp.py).

    download(url, dest, sha256=None, size=None, progress=None, cancel=None, opener=None)
    safe_extract(zip_path, dest, strip_top=False, progress=None, cancel=None)

Standard library only; every network call goes through `opener` so tests can fake it.
"""
import hashlib
import http.client
import os
import re
import shutil
import socket
import time
import urllib.error
import urllib.request
import zipfile

USER_AGENT = "OpenVanilla-Launcher"


class FetchError(Exception):
    """A download or unpack problem, worded for the player."""


class Cancelled(FetchError):
    pass


def _check(cancel):
    if cancel is not None and (cancel() if callable(cancel) else cancel.get("cancel")):
        raise Cancelled("Cancelled.")


def sha256_file(path, cancel=None):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            _check(cancel)
            h.update(block)
    return h.hexdigest()


def human_size(n):
    n = float(n or 0)
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit in ("B", "KB") else f"{n:.1f} {unit}"
        n /= 1024
    return ""


def download(url, dest, sha256=None, size=None, progress=None, cancel=None, opener=None, chunk=1 << 19,
             retries=4, sleep=time.sleep, timeout=30):
    """Download url to dest through dest.part (resumed with a Range request), then check size and SHA-256.

    progress(done, total) is called as bytes arrive. A checksum mismatch removes the partial file and
    raises FetchError. Returns dest."""
    if not str(url).lower().startswith(("https://", "http://")):
        raise FetchError("Only web (http/https) downloads are allowed.")
    opener = opener or urllib.request.urlopen
    progress = progress or (lambda done, total: None)
    part = dest + ".part"
    os.makedirs(os.path.dirname(os.path.abspath(dest)), exist_ok=True)
    if os.path.isfile(dest) and (not sha256 or sha256_file(dest, cancel) == sha256.lower()) \
            and (not size or os.path.getsize(dest) == int(size)):
        return dest
    attempt = 0
    while True:
        _check(cancel)
        have = os.path.getsize(part) if os.path.isfile(part) else 0
        if size and have > int(size):
            os.remove(part)
            have = 0
        if size and have == int(size):
            break
        headers = {"User-Agent": USER_AGENT, "Accept": "*/*"}
        if have:
            headers["Range"] = f"bytes={have}-"
        try:
            resp = opener(urllib.request.Request(url, headers=headers), timeout=timeout)
        except urllib.error.HTTPError as e:
            if e.code == 416 and have:
                break
            if e.code in (401, 403, 404, 410) or attempt >= retries:
                raise FetchError(f"The download server answered {e.code} for {url}.")
            attempt += 1
            sleep(min(2 ** attempt, 20))
            continue
        except (urllib.error.URLError, OSError) as e:
            if attempt >= retries:
                raise FetchError(f"Can't reach the download server ({getattr(e, 'reason', e)}). "
                                 "Check your connection and try again: the download resumes where it stopped.")
            attempt += 1
            sleep(min(2 ** attempt, 20))
            continue
        with resp:
            status = getattr(resp, "status", None) or resp.getcode()
            mode = "ab" if have else "wb"
            if have and status == 200:
                have, mode = 0, "wb"   # the server ignored Range: start over
            elif have and status == 206:
                m = re.match(r"bytes (\d+)-", resp.headers.get("Content-Range", "") or "")
                if not m or int(m.group(1)) != have:
                    have, mode = 0, "wb"
            length = resp.headers.get("Content-Length")
            total = int(size) if size else (have + int(length) if length and str(length).isdigit() else None)
            if total:
                try:
                    free = shutil.disk_usage(os.path.dirname(os.path.abspath(dest))).free
                except OSError:
                    free = None
                if free is not None and free < total - have + 50e6:
                    raise FetchError(f"Not enough disk space: need {human_size(total - have)}, {human_size(free)} free.")
            done = have
            try:
                with open(part, mode) as f:
                    while True:
                        _check(cancel)
                        block = resp.read(chunk)
                        if not block:
                            break
                        f.write(block)
                        done += len(block)
                        progress(done, total)
            except (OSError, http.client.IncompleteRead, socket.timeout):
                if attempt >= retries:
                    raise FetchError("The download stopped. Try again: it resumes where it stopped.")
                attempt += 1
                sleep(min(2 ** attempt, 20))
                continue
        if not size or os.path.getsize(part) >= int(size):
            break
        attempt += 1
        if attempt > retries:
            raise FetchError("The download stopped early. Try again: it resumes where it stopped.")
    got = os.path.getsize(part) if os.path.isfile(part) else 0
    if size and got != int(size):
        os.remove(part)
        raise FetchError("The download came out the wrong size and was removed. Try again.")
    if sha256 and sha256_file(part, cancel) != sha256.lower():
        os.remove(part)
        raise FetchError("The download was damaged (checksum mismatch) and was removed. Try again.")
    os.replace(part, dest)
    return dest


def safe_member(name):
    """The member's path parts, or None for anything that would leave the folder."""
    name = name.replace("\\", "/")
    if name.startswith("/") or re.match(r"^[A-Za-z]:", name):
        return None
    parts = [p for p in name.split("/") if p not in ("", ".")]
    if not parts or any(p == ".." for p in parts):
        return None
    return parts


def zip_top_folder(names):
    """The one folder every member is under ("OpenVanilla_1.17.0_Win64"), or None."""
    tops = {n.replace("\\", "/").split("/", 1)[0] for n in names if n.strip("/")}
    if len(tops) == 1:
        top = tops.pop()
        if all(n.replace("\\", "/").startswith(top + "/") or n.rstrip("/") == top for n in names):
            return top
    return None


def safe_extract(zip_path, dest, strip_top=False, progress=None, cancel=None):
    """Extract zip_path into dest, refusing paths that escape it. strip_top drops a single top folder.
    Returns the number of files written. Raises FetchError for a damaged zip."""
    progress = progress or (lambda done, total: None)
    try:
        z = zipfile.ZipFile(zip_path)
    except (zipfile.BadZipFile, OSError) as e:
        raise FetchError(f"The download isn't a valid zip ({e}).")
    with z:
        infos = z.infolist()
        top = zip_top_folder([i.filename for i in infos]) if strip_top else None
        total = sum(i.file_size for i in infos) or 1
        done = n = 0
        os.makedirs(dest, exist_ok=True)
        for info in infos:
            _check(cancel)
            parts = safe_member(info.filename)
            if parts is None:
                raise FetchError(f"Unsafe path in the zip: {info.filename}")
            if top:
                if parts[0] != top:
                    raise FetchError(f"Unexpected file in the zip: {info.filename}")
                parts = parts[1:]
                if not parts:
                    continue
            target = os.path.join(dest, *parts)
            if info.is_dir() or info.filename.endswith("/"):
                os.makedirs(target, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            try:
                with z.open(info) as src, open(target, "wb") as out:
                    shutil.copyfileobj(src, out, 1 << 20)
            except (zipfile.BadZipFile, EOFError, zlib_error()) as e:
                raise FetchError(f"The zip is damaged ({e}). Download it again.")
            done += info.file_size
            n += 1
            progress(done, total)
    return n


def zlib_error():
    import zlib
    return zlib.error
