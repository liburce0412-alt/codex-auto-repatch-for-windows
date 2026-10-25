"""Inspect selected Desktop ASAR assets without extracting or modifying the package."""
import argparse
import json
import re
import struct
from pathlib import Path


def read_exact(stream, size):
    data = stream.read(size)
    if len(data) != size:
        raise ValueError("Incomplete ASAR read; no absence conclusion is valid")
    return data


def entries(node, prefix=""):
    for name, value in node.get("files", {}).items():
        path = prefix + name
        if "files" in value:
            yield from entries(value, path + "/")
        else:
            yield path, value


def inspect(path):
    markers = {
        "dots_route": "wy=`/dots`",  # historical spelling; regex below handles renames
        "dots_deep_link": "codex://dots",
        "dots_home_destination": "dotsHome",
        "side_orb_gate": "side-orb-enabled",
        "cloud_mode_gate": "aeon-cloud-mode",
        "account_tbo_eligibility": "tbo_available",
        "primary_dot_api": "/tbo/primary",
    }
    evidence = {name: [] for name in markers}
    scanned = []
    total = 0
    with path.open("rb") as stream:
        prefix = read_exact(stream, 16)
        pickle_size = struct.unpack_from("<I", prefix, 4)[0]
        json_size = struct.unpack_from("<I", prefix, 12)[0]
        if not 0 < json_size <= 32 * 1024 * 1024 or pickle_size < json_size + 8:
            raise ValueError("Unsupported ASAR header")
        tree = json.loads(read_exact(stream, json_size))
        base = 8 + pickle_size
        file_size = path.stat().st_size
        for name, value in entries(tree):
            if not re.fullmatch(
                r"(?:webview/assets/app-initial-[^/]+|\.vite/build/(?:bootstrap|main|src)-[^/]+)\.js", name
            ):
                continue
            if value.get("unpacked") or "offset" not in value:
                raise ValueError("Selected asset is unpacked or linked; inspection incomplete")
            size, offset = int(value["size"]), int(value["offset"])
            total += size
            if size < 0 or offset < 0 or size > 32 * 1024 * 1024 or total > 96 * 1024 * 1024:
                raise ValueError("Asset read budget exceeded; inspection incomplete")
            if base + offset + size > file_size:
                raise ValueError("Asset lies outside ASAR; inspection incomplete")
            stream.seek(base + offset)
            source = read_exact(stream, size).decode("utf-8")
            scanned.append(name)
            for marker, text in markers.items():
                found = bool(re.search(r"[`\"']/dots[`\"']", source)) if marker == "dots_route" else text in source
                if found:
                    evidence[marker].append(name)
    if not scanned:
        raise ValueError("No supported assets found; package layout needs fresh investigation")
    return {
        "asar": str(path.resolve()),
        "inspection": "selected-assets-only",
        "bytes_read": total,
        "assets_scanned": scanned,
        "markers": {key: {"detected": bool(files), "assets": files} for key, files in evidence.items()},
        "account_eligibility": "not-queried",
        "runtime_validation": "not-performed",
        "interpretation": "Detected code is not proof of enabled UI or cloud access. Undetected markers require investigation; they do not prove feature absence.",
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--asar", required=True, type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(inspect(args.asar), ensure_ascii=True, indent=2))
    except (OSError, ValueError, KeyError, TypeError, struct.error) as error:
        print(json.dumps({"inspection": "failed", "error": str(error)}, ensure_ascii=True))
        raise SystemExit(1)
