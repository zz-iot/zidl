"""Independent XTypes 1.3 array/sequence key witnesses (no zidl/runtime imports).

§7.6.8: serialize the FINAL key holder as PLAIN_CDR2 BE, with zero
padding and alignment capped at four; use the schema maximum for MD5 policy.
§7.4.3.5.2 rules (5)-(9): enum/bitmask arrays have a collection DHEADER;
primitive arrays do not. Multidimensional arrays are flattened (§7.4.3.5.1).
Sequence witnesses distinguish actual extent from the schema maximum, including
empty sequences whose types still require MD5.
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
# Explicit schema maxima, independently of the currently supplied value.
maxima = {name: len(data) for name, data in cases.items()}
def sequence(width, values):
    formats = {1: "B", 2: "H", 4: "I", 8: "Q"}
    body = struct.pack(">I", len(values)) + b"".join(struct.pack(">" + formats[width], v) for v in values)
    return struct.pack(">I", len(body)) + body

sequences = {
    "EnumSeq16": (sequence(4, [0, 1]), 16),
    "EnumSeq16Empty": (sequence(4, []), 16),
    "EnumSeq20": (sequence(4, [0, 1, 0]), 20),
    "EnumSeq20Empty": (sequence(4, []), 20),
    "EnumSeq20Short": (sequence(4, [1]), 20),
    "MaskSeq16": (sequence(1, [1, 2] * 4), 16),
    "MaskSeq17": (sequence(1, [1, 2] * 4 + [1]), 17),
    "MaskSeq17Empty": (sequence(1, []), 17),
    "Enum8Seq17": (sequence(1, [0, 1, 0]), 17),
    "Enum16Seq16": (sequence(2, [0, 1]), 16),
    "Mask64Seq16": (sequence(8, [2]), 16),
    "EnumUnboundedSeq": (sequence(4, []), None),
    "PrimitiveSeq16": (struct.pack(">4I", 3, 1, 2, 3), 16),
    "PrimitiveSeq16Empty": (struct.pack(">I", 0), 16),
    "EnumSeqAlign": (b"\xaa\0\0\0" + sequence(1, [0, 1]) + b"\xbb", 16),
}
for name, (data, maximum) in sequences.items():
    cases[name] = data
    maxima[name] = maximum
rows = []
for name, data in cases.items():
    force = maxima[name] is None or maxima[name] > 16
    digest = hashlib.md5(data).digest() if force else data.ljust(16, b"\0")
    rows.append(f"{name} {data.hex()} {digest.hex()} {int(force)}\n")
pathlib.Path(__file__).with_name("array_vectors.txt").write_text("".join(rows))
