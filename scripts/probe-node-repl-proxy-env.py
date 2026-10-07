"""Read-only x64 Windows environment probe. Report proxy names, never values."""
import argparse
import ctypes as c
from ctypes import wintypes as w
import json
import platform
import sys

PROXY_NAMES = ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "WS_PROXY", "WSS_PROXY")
MAX_ENVIRONMENT_BYTES = 4 * 1024 * 1024


def read_exact(read_chunk, address, size):
    if not address:
        raise RuntimeError("Null process memory pointer")
    result = bytearray()
    while len(result) < size:
        chunk = read_chunk(address + len(result), size - len(result))
        if not chunk or len(chunk) > size - len(result):
            raise RuntimeError("Incomplete process memory read")
        result.extend(chunk)
    return bytes(result)


def read_environment(read_chunk, address, limit=MAX_ENVIRONMENT_BYTES):
    if not address or address % 2:
        raise RuntimeError("Invalid UTF-16 environment pointer")
    data = bytearray()
    while len(data) < limit:
        previous = len(data)
        chunk = read_chunk(address + previous, min(4096, limit - previous))
        if not chunk or len(chunk) % 2 or len(chunk) > min(4096, limit - previous):
            raise RuntimeError("Incomplete UTF-16 environment read")
        data.extend(chunk)
        # The terminator may straddle a memory region; only UTF-16 boundaries count.
        end = data.find(b"\0\0\0\0", max(0, previous - 2))
        while end >= 0 and end % 2:
            end = data.find(b"\0\0\0\0", end + 1)
        if end >= 0:
            try:
                entries = bytes(data[:end]).decode("utf-16-le").split("\0")
            except UnicodeDecodeError:
                raise RuntimeError("Invalid UTF-16 environment block") from None
            names = set()
            for entry in entries:
                if not entry or entry.startswith("="):
                    continue
                if "=" not in entry:
                    raise RuntimeError("Malformed environment entry")
                names.add(entry.split("=", 1)[0].upper())
            return [name for name in PROXY_NAMES if name in names]
    raise RuntimeError("Environment block exceeds read limit without a terminator")


class MemoryRegion(c.Structure):
    _fields_ = [("BaseAddress", c.c_void_p), ("AllocationBase", c.c_void_p),
                ("AllocationProtect", w.DWORD), ("PartitionId", w.WORD),
                ("RegionSize", c.c_size_t), ("State", w.DWORD),
                ("Protect", w.DWORD), ("Type", w.DWORD)]


class WindowsReader:
    def __init__(self, pid):
        self.kernel = c.WinDLL("kernel32", use_last_error=True)
        self.nt = c.WinDLL("ntdll")
        self.kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
        self.kernel.OpenProcess.restype = w.HANDLE
        self.kernel.CloseHandle.argtypes = [w.HANDLE]
        self.kernel.CloseHandle.restype = w.BOOL
        self.kernel.IsWow64Process.argtypes = [w.HANDLE, c.POINTER(w.BOOL)]
        self.kernel.IsWow64Process.restype = w.BOOL
        self.kernel.VirtualQueryEx.argtypes = [w.HANDLE, c.c_void_p, c.POINTER(MemoryRegion), c.c_size_t]
        self.kernel.VirtualQueryEx.restype = c.c_size_t
        self.kernel.ReadProcessMemory.argtypes = [w.HANDLE, c.c_void_p, c.c_void_p, c.c_size_t, c.POINTER(c.c_size_t)]
        self.kernel.ReadProcessMemory.restype = w.BOOL
        self.nt.NtQueryInformationProcess.argtypes = [w.HANDLE, w.ULONG, c.c_void_p, w.ULONG, c.POINTER(w.ULONG)]
        self.nt.NtQueryInformationProcess.restype = w.LONG
        self.handle = self.kernel.OpenProcess(0x410, False, pid)
        if not self.handle:
            raise RuntimeError(f"OpenProcess failed ({c.get_last_error()})")

    def close(self):
        self.kernel.CloseHandle(self.handle)

    def read_chunk(self, address, requested):
        region = MemoryRegion()
        queried = self.kernel.VirtualQueryEx(self.handle, address, c.byref(region), c.sizeof(region))
        if queried != c.sizeof(region):
            raise RuntimeError(f"VirtualQueryEx failed ({c.get_last_error()})")
        if region.State != 0x1000 or region.Protect & 0x100 or (region.Protect & 0xFF) not in (2, 4, 8, 0x20, 0x40, 0x80):
            raise RuntimeError("Environment memory is not readable")
        size = min(requested, int(region.BaseAddress or 0) + region.RegionSize - address)
        if size <= 0:
            raise RuntimeError("Invalid process memory region")
        buffer = c.create_string_buffer(size)
        got = c.c_size_t()
        ok = self.kernel.ReadProcessMemory(self.handle, address, buffer, size, c.byref(got))
        if not ok or got.value != size:
            raise RuntimeError(f"Incomplete ReadProcessMemory ({c.get_last_error()})")
        return buffer.raw

    def proxy_names(self):
        wow64 = w.BOOL()
        if not self.kernel.IsWow64Process(self.handle, c.byref(wow64)) or wow64.value:
            raise RuntimeError("Target must be a readable x64 Windows process")
        basic = (c.c_ulonglong * 6)()
        length = w.ULONG()
        status = self.nt.NtQueryInformationProcess(self.handle, 0, c.byref(basic), c.sizeof(basic), c.byref(length))
        if status or length.value != c.sizeof(basic) or not basic[1]:
            raise RuntimeError(f"NtQueryInformationProcess failed ({status})")
        pointer = lambda address: int.from_bytes(read_exact(self.read_chunk, address, 8), "little")
        parameters = pointer(basic[1] + 0x20)
        if not parameters:
            raise RuntimeError("Null process parameters")
        environment = pointer(parameters + 0x80)
        names = read_environment(self.read_chunk, environment)
        if pointer(basic[1] + 0x20) != parameters or pointer(parameters + 0x80) != environment:
            raise RuntimeError("Environment pointer changed during probe; retry")
        return names


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, action="append", required=True)
    args = parser.parse_args()
    if sys.platform != "win32" or c.sizeof(c.c_void_p) != 8 or platform.machine().lower() not in ("amd64", "x86_64"):
        parser.error("Run with x64 Python on x64 Windows; no process was modified")
    failed = False
    for pid in args.pid:
        reader = None
        try:
            if not 0 < pid <= 0xFFFFFFFF:
                raise RuntimeError("Invalid process ID")
            reader = WindowsReader(pid)
            result = {"pid": pid, "complete": True, "proxyKeysPresent": reader.proxy_names()}
        except (RuntimeError, OSError) as error:
            result = {"pid": pid, "complete": False, "error": str(error)}
            failed = True
        finally:
            if reader is not None:
                reader.close()
        print(json.dumps(result))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
