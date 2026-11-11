#!/usr/bin/env python3
"""Tiny model-pack ZIPs for the Swift tests (stored entries, like the real packs), including a ZIP64 variant."""
import hashlib
import json
import struct
import zipfile
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "Tests/VoiceCloneCoreTests/Fixtures"
NAMES = ["tokenizer.json", "text_encoder.onnx", "dit_step.onnx", "duration.onnx", "context_kv.onnx",
         "speaker_encoder.onnx", "dacvae_encode.onnx", "dacvae_decode.onnx"]


def payloads():
    return {name: (name.encode() * 40 + bytes(range(256)) * 3) for name in NAMES}


def manifest(files, bad_hash=None):
    entries = []
    for name, data in files.items():
        digest = hashlib.sha256(data).hexdigest()
        if name == bad_hash:
            digest = "0" * 64
        entries.append({"name": name, "size": len(data), "sha256": digest})
    return json.dumps({"format_version": 1, "profile": "mf-mixed8", "flow": "mf", "precision": "mixed8",
                       "deterministic_encoder": True, "files": entries}).encode()


def write_stored(path, items, compression=zipfile.ZIP_STORED):
    with zipfile.ZipFile(path, "w", compression=compression, allowZip64=True) as z:
        for name, data in items:
            z.writestr(name, data)


def write_zip64(path, items):
    """Hand-written ZIP whose central directory uses ZIP64 extra fields (sizes/offsets stored as 0xFFFFFFFF)."""
    body = b""
    central = b""
    for name, data in items:
        raw = name.encode()
        crc = zipfile.crc32(data)
        offset = len(body)
        body += struct.pack("<IHHHHHIIIHH", 0x04034b50, 45, 0, 0, 0, 0, crc, len(data), len(data), len(raw), 0) + raw + data
        extra = struct.pack("<HHQQQ", 1, 24, len(data), len(data), offset)
        central += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014b50, 45, 45, 0, 0, 0, 0, crc, 0xFFFFFFFF, 0xFFFFFFFF,
                               len(raw), len(extra), 0, 0, 0, 0, 0xFFFFFFFF) + raw + extra
    directory_offset = len(body)
    zip64_end = struct.pack("<IQHHIIQQQQ", 0x06064b50, 44, 45, 45, 0, 0, len(items), len(items), len(central), directory_offset)
    locator = struct.pack("<IIQI", 0x07064b50, 0, directory_offset + len(central), 1)
    end = struct.pack("<IHHHHIIH", 0x06054b50, 0, 0, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0)
    Path(path).write_bytes(body + central + zip64_end + locator + end)


if __name__ == "__main__":
    files = payloads()
    good = list(files.items()) + [("manifest.json", manifest(files))]
    write_stored(OUT / "pack_ok.zip", good)
    write_zip64(OUT / "pack_zip64.zip", good)
    write_stored(OUT / "pack_badhash.zip", list(files.items()) + [("manifest.json", manifest(files, bad_hash="dit_step.onnx"))])
    write_stored(OUT / "pack_deflated.zip", good, compression=zipfile.ZIP_DEFLATED)
    write_stored(OUT / "pack_extra_file.zip", good + [("evil.sh", b"echo hi")])
    write_stored(OUT / "pack_missing.zip", good[:-2] + [good[-1]])
    (OUT / "pack_manifest.json").write_bytes(manifest(files))
    print("pack fixtures written")
