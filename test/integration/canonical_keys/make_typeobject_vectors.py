"""Independent XTypes MinimalStruct witnesses using packing and hashlib."""
import hashlib
import pathlib
import struct


def encode(members):
    data = bytearray.fromhex("00070000")

    def number(fmt, value):
        size = struct.calcsize(fmt)
        data.extend(bytes((-len(data)) % min(size, 4)))
        data.extend(struct.pack("<" + fmt, value))

    def header():
        number("I", 0)
        return len(data) - 4

    def end(offset):
        struct.pack_into("<I", data, offset, len(data) - offset - 4)

    outer = header()
    data.extend(bytes([0xF1, 0x51]))  # EK_MINIMAL, TK_STRUCTURE
    number("H", 4)  # IS_MUTABLE
    detail = header()
    data.append(0)  # TK_NONE base
    end(detail)
    sequence = header()
    number("I", len(members))
    for member_id, name, kind in sorted(members):
        member = header()
        number("I", member_id)
        number("H", 0x21)  # TRY_CONSTRUCT_DISCARD | IS_KEY
        data.append(kind)
        data.extend(hashlib.md5(name.encode("utf-8")).digest()[:4])
        end(member)
    end(sequence)
    end(outer)
    return data


schemas = {
    "Sequential": [(8, "a", 2), (9, "b", 4), (2, "c", 2), (3, "d", 4)],
    "Hashed": [(0x0FA5DD70, "color", 2), (0x047790DA, "size", 4)],
}
rows = []
for name, members in schemas.items():
    data = encode(members)
    digest = hashlib.md5(data[4:]).digest()[:14]
    rows.append(f"{name} {data.hex()} {digest.hex()}\n")
pathlib.Path(__file__).with_name("typeobjects.txt").write_text("".join(rows))
