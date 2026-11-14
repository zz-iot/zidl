"""Independent XTypes 1.3 array key witnesses (no zidl/runtime imports).

§7.6.8: serialize the FINAL key holder as PLAIN_CDR2 BE, with zero
padding and alignment capped at four; use the schema maximum for MD5 policy.
§7.4.3.5.2 rules (5)-(9): enum/bitmask arrays have a collection DHEADER;
primitive arrays do not. Multidimensional arrays are flattened (§7.4.3.5.1).
All witnesses here have fixed size, so actual and maximum extents coincide.
"""
import hashlib
import pathlib
import struct


def collection(width, values):
    formats = {1: "B", 2: "H", 4: "I", 8: "Q"}
    body = b"".join(struct.pack(">" + formats[width], v) for v in values)
    return struct.pack(">I", len(body)) + body


cases = {
    "EnumArray16": collection(4, [0, 1, 0]),
    "EnumArray20": collection(4, [0, 1, 0, 1]),
    "EnumGrid": collection(4, [0, 1, 1, 0]),
    "MaskArray16": collection(1, [1, 2] * 6),
    "MaskArray17": collection(1, [1, 2] * 6 + [1]),
    "NarrowArray": b"\xaa\0\0\0" + collection(1, [0, 1, 0]) + b"\xbb",
    "Enum16Array": collection(2, [0, 1]),
    "Mask64Array": collection(8, [1, 2]),
    "PrimitiveGrid": struct.pack(">4I", 1, 2, 3, 4),
}
rows = []
for name, data in cases.items():
    force = len(data) > 16
    digest = hashlib.md5(data).digest() if force else data.ljust(16, b"\0")
    rows.append(f"{name} {data.hex()} {digest.hex()} {int(force)}\n")
pathlib.Path(__file__).with_name("array_vectors.txt").write_text("".join(rows))
