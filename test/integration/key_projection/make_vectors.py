"""Independent declaration-order wire and canonical hash witnesses."""
import hashlib
import pathlib
import struct


class Wire:
    def __init__(self, version=2, order=0):
        self.version, self.order, self.data = version, order, bytearray()

    def align(self, width):
        self.data.extend(bytes((-len(self.data)) % min(width, 8 if self.version == 1 else 4)))

    def u32(self, value):
        self.align(4)
        self.data.extend(self.word(value))

    def word(self, value):
        return struct.pack(">I" if self.order else "<I", value)

    def text(self, value):
        body = value.encode() + b"\0"
        self.u32(len(body))
        self.data.extend(body)

    def begin(self):
        self.align(4)
        pos = len(self.data)
        self.u32(0)
        return pos

    def end(self, pos):
        self.data[pos:pos+4] = self.word(len(self.data) - pos - 4)

    def member(self, member_id, emit, lc=None):
        self.u32(member_id | ((4 if lc is None else lc) << 28))
        pos = self.begin() if lc is None else None
        emit()
        if pos is not None:
            self.end(pos)


def final(w, key):
    if not key:
        w.u32(99)
    w.u32(42)
    if not key:
        w.u32(88)
        w.u32(77)


def appendable(w, key):
    pos = w.begin() if w.version == 2 else None
    if not key:
        w.u32(99)
    w.u32(42)
    if not key:
        w.u32(77)
    if pos is not None:
        w.end(pos)


def mutable(w, key, text="blue"):
    pos = w.begin()
    if not key:
        w.member(0, lambda: w.u32(99), 2)
    w.member(8, lambda: w.text(text))
    if not key:
        w.member(9, lambda: w.u32(77), 2)
    w.end(pos)


def bridge(w, key):
    w.u32(11)
    final(w, key)
    w.u32(22)


def mut_bridge(w, key, before=11, text="blue", after=22):
    pos = w.begin()
    w.member(0, lambda: w.u32(before), 2)
    w.member(1, lambda: mutable(w, key, text))
    w.member(2, lambda: w.u32(after), 2)
    w.end(pos)


def app_bridge(w, key, before=11, text="blue"):
    pos = w.begin()
    w.u32(before)
    mutable(w, key, text)
    w.end(pos)


def root_bridge(w, key):
    bridge(w, key)
    if not key:
        w.u32(66)


def root_mut(w, key):
    pos = w.begin()
    w.member(0, lambda: mut_bridge(w, key))
    w.member(1, lambda: w.u32(33), 2)
    if not key:
        w.member(2, lambda: w.u32(66), 2)
    w.end(pos)


def root_array(w, key):
    pos = w.begin()
    app_bridge(w, key)
    app_bridge(w, key, 33, "orange")
    w.end(pos)
    if not key:
        w.u32(66)


def root_seq(w, key):
    pos = w.begin()
    w.u32(2)
    mut_bridge(w, key)
    mut_bridge(w, key, 33, "orange", 44)
    w.end(pos)
    pos = w.begin()
    w.u32(2)
    mut_bridge(w, key)
    mut_bridge(w, key, 33, "orange", 44)
    w.end(pos)
    if not key:
        w.u32(66)


def canonical(name):
    w = Wire(order=1)
    if name in ("FDerived", "ADerived"):
        w.u32(42)
        force = False
    elif name == "MDerived":
        w.text("blue")
        force = True
    elif name in ("RootBridge", "RootInherited"):
        for n in (11, 42, 22):
            w.u32(n)
        force = False
    elif name == "RootMut":
        w.u32(11); w.text("blue"); w.u32(22); w.u32(33)
        force = True
    else:
        for _ in range(2 if name == "RootSeq" else 1):
            if name == "RootSeq":
                w.u32(2)
            for before, text, after in ((11, "blue", 22), (33, "orange", 44)):
                w.u32(before); w.text(text)
                if name == "RootSeq":
                    w.u32(after)
        force = True
    data = bytes(w.data)
    return hashlib.md5(data).digest() if force else data.ljust(16, b"\0")


cases = [("FDerived", final, 0, True), ("ADerived", appendable, 1, True),
         ("MDerived", mutable, 2, False), ("RootBridge", root_bridge, 0, True),
         ("RootInherited", root_bridge, 0, True), ("RootMut", root_mut, 2, False),
         ("RootArray", root_array, 0, False), ("RootSeq", root_seq, 0, False)]
rows = []
for name, emit, ext, xcdr1 in cases:
    for version in ((1, 2) if xcdr1 else (2,)):
        for order in (0, 1):
            rid = (0x0001 if version == 1 else (7, 9, 11)[ext]) - order
            payloads = []
            for key in (False, True):
                w = Wire(version, order)
                emit(w, key)
                payloads.append((struct.pack(">HH", rid, 0) + w.data).hex())
            rows.append(f"{name} {version} {order} {' '.join(payloads)} {canonical(name).hex()}\n")
pathlib.Path(__file__).with_name("vectors.txt").write_text("".join(rows))
