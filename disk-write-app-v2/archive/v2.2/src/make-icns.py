#!/usr/bin/env python3
"""把 iconset 目录里的 PNG 拼成 .icns。

iconutil 在只装命令行工具的机器上会报 Invalid Iconset，
这里直接按 ICNS 容器格式写入（PNG 压缩的 type code）。
"""

import os
import struct
import sys

TYPES = [
    ("ic11", "icon_16x16@2x.png"),   # 32
    ("ic12", "icon_32x32@2x.png"),   # 64
    ("ic07", "icon_128x128.png"),    # 128
    ("ic13", "icon_128x128@2x.png"), # 256
    ("ic08", "icon_256x256.png"),    # 256
    ("ic14", "icon_256x256@2x.png"), # 512
    ("ic09", "icon_512x512.png"),    # 512
    ("ic10", "icon_512x512@2x.png"), # 1024
]


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: make-icns.py <iconset-dir> <out.icns>")
        return 2

    source, target = sys.argv[1], sys.argv[2]
    chunks = b""
    for code, name in TYPES:
        path = os.path.join(source, name)
        if not os.path.exists(path):
            continue
        with open(path, "rb") as fh:
            data = fh.read()
        chunks += code.encode("ascii") + struct.pack(">I", len(data) + 8) + data

    with open(target, "wb") as fh:
        fh.write(b"icns" + struct.pack(">I", len(chunks) + 8) + chunks)
    print(f"wrote {target} ({len(chunks) + 8} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
