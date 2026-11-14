"""Independent key-only XCDR2 witnesses; no generated-code dependency."""
import hashlib
import pathlib
import struct

CANONICAL = {
    "Example": (bytes.fromhex("1234567800000005424c554500"), True),
    "Nested": (bytes.fromhex("12345678"), False),
    "Sequential": (bytes.fromhex("cc00000001020304aa00000005060708"), False),
    "Hashed": (bytes.fromhex("01020304aa"), False),
    "ArrayKey": (bytes.fromhex("000000080102030405060708"), False),
    "SeqAgg": (bytes.fromhex("0000000c000000020102030405060708"), False),
    "UnkeyedNested": (bytes.fromhex("1234aa"), False),
}
rows = []
for order in (0, 1):
    endian = "<" if order == 0 else ">"
    def u32(n): return struct.pack(endian + "I", n)
    def frame(fields):
        body = bytearray()
        for member, payload, lc in fields:
            body.extend(bytes((-len(body)) % 4))
            body.extend(u32(member | ((4 if lc is None else lc) << 28)))
            if lc is None: body.extend(u32(len(payload)))
            body.extend(payload)
        return u32(len(body)) + body
    def nested(value): return frame([(0, u32(value), 2)])
    string = u32(5) + b"BLUE\0"
    elements = nested(0x01020304) + nested(0x05060708)
    payloads = {
        "Example": frame([(40, string, None), (30, nested(0x12345678), None)]),
        "Nested": nested(0x12345678),
        "Sequential": frame([(8, b"\xaa", 0), (9, u32(0x05060708), 2), (2, b"\xcc", 0), (3, u32(0x01020304), 2)]),
        "Hashed": frame([(0x0fa5dd70, b"\xaa", 0), (0x047790da, u32(0x01020304), 2)]),
        "ArrayKey": u32(len(elements)) + elements,
        "SeqAgg": u32(4 + len(elements)) + u32(2) + elements,
        "UnkeyedNested": b"\xaa\0" + struct.pack(endian + "H", 0x1234),
    }
    for name, body in payloads.items():
        mutable = name in ("Example", "Nested", "Sequential", "Hashed")
        rid = (0x000b if mutable else 0x0007) - order
        data = struct.pack(">HH", rid, 0) + body
        canonical, force = CANONICAL[name]
        digest = hashlib.md5(canonical).digest() if force else canonical.ljust(16, b"\0")
        rows.append(f"{name} {order} {data.hex()} {digest.hex()}\n")
pathlib.Path(__file__).with_name("key_wire.txt").write_text("".join(rows))
