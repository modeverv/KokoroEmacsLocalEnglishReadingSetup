"""Audit every bundled Mach-O slice for CPU, minimum OS, and external libraries."""
import argparse
import json
from pathlib import Path
import struct

CPU = {0x1000007: "x86_64", 0x100000C: "arm64"}


def version(value):
    return (value >> 16, (value >> 8) & 255, value & 255)


def slices(data, offset=0):
    magic = data[offset:offset + 4]
    if magic in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        count, = struct.unpack_from(">I", data, offset + 4)
        wide = magic[-1] == 0xBF
        for index in range(count):
            record = offset + 8 + index * (32 if wide else 20)
            start, = struct.unpack_from(">Q" if wide else ">I", data, record + 8)
            yield from slices(data, offset + start)
        return
    if magic not in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"):
        return
    endian = "<" if magic[0] == 0xCF else ">"
    cpu, = struct.unpack_from(endian + "I", data, offset + 4)
    count, = struct.unpack_from(endian + "I", data, offset + 16)
    position = offset + 32
    minimum, libraries = None, []
    for _ in range(count):
        command, size = struct.unpack_from(endian + "II", data, position)
        if size < 8 or position + size > len(data):
            raise ValueError("invalid Mach-O load command")
        if command == 0x32:
            platform, value = struct.unpack_from(endian + "II", data, position + 8)
            if platform != 1:
                raise ValueError("non-macOS binary")
            minimum = version(value)
        elif command == 0x24:
            minimum = version(struct.unpack_from(endian + "I", data, position + 8)[0])
        elif command in (0xC, 0x80000018, 0x8000001F, 0x80000023):
            start, = struct.unpack_from(endian + "I", data, position + 8)
            libraries.append(data[position + start:position + size].split(b"\0")[0].decode())
        position += size
    yield dict(arch=CPU.get(cpu, str(cpu)), minimum=minimum, libraries=libraries)


def verify(app):
    app = Path(app).resolve()
    report = []
    for path in sorted(app.rglob("*")):
        if path.is_symlink():
            if not path.exists() or not path.resolve().is_relative_to(app):
                raise ValueError(f"non-portable symlink: {path.relative_to(app)}")
            continue
        if not path.is_file():
            continue
        with path.open("rb") as stream:
            magic = stream.read(4)
            if magic not in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"):
                continue
            stream.seek(0)
            records = list(slices(stream.read()))
        relative = str(path.relative_to(app))
        expected = {"arm64", "x86_64"} if "/MacOS/" in relative else set()
        for arch in ("arm64", "x86_64"):
            if f"runtime-{arch}/" in relative:
                expected = {arch}
        if not expected <= {r["arch"] for r in records}:
            raise ValueError(f"missing architecture {expected}: {relative}")
        for record in records:
            # Universal vendor libraries may contain additional slices. Every
            # shipped slice must still satisfy the deployment target.
            if record["minimum"] is None or record["minimum"] > (12, 0, 0):
                raise ValueError(f"requires macOS newer than 12: {relative}: {record}")
            for library in record["libraries"]:
                if library.startswith("/") and not library.startswith(("/System/Library/", "/usr/lib/")):
                    raise ValueError(f"external dependency in {relative}: {library}")
            report.append(dict(file=relative, **record))
    if not report:
        raise ValueError("no Mach-O binaries found")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app")
    args = parser.parse_args()
    print(json.dumps(verify(args.app), indent=2))
