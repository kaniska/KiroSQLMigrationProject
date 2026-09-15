"""
migkit.platform_compat — the few things that differ between Windows, Linux and macOS.

* file_lock(path)   inter-process exclusive lock on <path>.lock (fcntl on POSIX, msvcrt on Windows)
* utf8_stdio()      make stdout/stderr UTF-8 so '→', '—' and non-ASCII SQL never raise
                    UnicodeEncodeError when output is piped (Windows defaults to the ANSI code page)
* host_name()       portable replacement for os.uname().nodename
* detach_kwargs()   subprocess options for a background process that outlives its parent
"""
import contextlib
import os
import pathlib
import platform
import subprocess
import sys
import time

IS_WINDOWS = os.name == "nt"

try:
    import fcntl  # POSIX
except ImportError:  # Windows
    fcntl = None
try:
    import msvcrt  # Windows
except ImportError:  # POSIX
    msvcrt = None


@contextlib.contextmanager
def file_lock(path, timeout: float = 30.0):
    """Exclusive advisory lock held for the duration of the with-block. Uses a sidecar
    '<name>.lock' file so the data file itself can be opened in any mode."""
    lock_path = pathlib.Path(str(path) + ".lock")
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    fh = open(lock_path, "a+b")
    try:
        if fcntl is not None:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
        elif msvcrt is not None:
            deadline = time.monotonic() + timeout
            while True:
                try:
                    fh.seek(0)
                    msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
                    break
                except OSError:
                    if time.monotonic() > deadline:
                        raise TimeoutError(f"could not lock {lock_path} within {timeout}s")
                    time.sleep(0.02)
        yield
    finally:
        try:
            if fcntl is not None:
                fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
            elif msvcrt is not None:
                fh.seek(0)
                msvcrt.locking(fh.fileno(), msvcrt.LK_UNLCK, 1)
        except OSError:
            pass
        fh.close()


def utf8_stdio():
    for stream in (sys.stdout, sys.stderr):
        try:
            if (getattr(stream, "encoding", "") or "").lower().replace("-", "") != "utf8":
                stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass


def host_name() -> str:
    return platform.node() or os.environ.get("COMPUTERNAME") or os.environ.get("HOSTNAME") or "unknown-host"


def detach_kwargs() -> dict:
    if IS_WINDOWS:
        flags = getattr(subprocess, "DETACHED_PROCESS", 0x00000008) | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200)
        return {"creationflags": flags, "close_fds": True}
    return {"start_new_session": True}
