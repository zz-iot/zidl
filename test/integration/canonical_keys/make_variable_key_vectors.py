"""Independent canonical collection witnesses: Python packing/hashlib only.

XTypes 1.3 §7.4.3.5.2 rules (9)/(12) retain non-primitive collection
DHEADERs; §7.6.8 projects aggregates to FINAL and uses schema maxima for MD5.
Collection payloads start at a four-aligned position. Arrays flatten dimensions;
sequences include a count. Padding is zero, including between variable elements.
"""
import hashlib
import pathlib
import struct

class Encoder:
    def __init__(self): self.data = bytearray()
    def uint(self, width, value):
        self.data.extend(bytes((-len(self.data)) % min(width, 4)))
        self.data.extend(value.to_bytes(width, "big"))
    def string(self, value):
        data = value.encode("utf-8") + b"\0"
        self.uint(4, len(data)); self.data.extend(data)
    def wide(self, units):
        self.uint(4, len(units) * 2)
        for unit in units: self.uint(2, unit)
    def collection(self, body):
        payload = Encoder(); body(payload)
        self.uint(4, len(payload.data)); self.data.extend(payload.data)
    def array(self, values, emit):
        self.collection(lambda p: [emit(p, value) for value in values])
    def sequence(self, values, emit):
        def body(p):
            p.uint(4, len(values))
            for value in values: emit(p, value)
        self.collection(body)
    def primitive_sequence(self, values):
        self.uint(4, len(values))
        for value in values: self.uint(4, value)


def encoded(fn):
    e = Encoder(); fn(e); return bytes(e.data)
def text(e, v): e.string(v)
def integer(e, v): e.uint(4, v)
def enums(e, v): e.array(v, integer)
def choice(e, v):
    tag, value = v; e.uint(4, tag)
    if tag == 0: e.string(value)
    else: e.uint(4, value)
def envelope(e):
    e.uint(1, 0xaa); e.sequence(["A"], text); e.uint(1, 0xbb)

# Values and maximum-size witnesses are intentionally separate.
cases = {
    "TextArray": (lambda e: e.array(["A", "BC"], text), lambda e: e.array(["XXXX"] * 2, text)),
    "TextGrid": (lambda e: e.array(["A", "BC", "", "D"], text), lambda e: e.array(["XXXX"] * 4, text)),
    "TextSeq": (lambda e: e.sequence(["A", "BC"], text), lambda e: e.sequence(["XXXX"] * 2, text)),
    "TextSeqEmpty": (lambda e: e.sequence([], text), lambda e: e.sequence(["XXXX"] * 2, text)),
    "TextSeqShort": (lambda e: e.sequence(["A"], text), lambda e: e.sequence(["XXXX"] * 2, text)),
    "ItemSeq": (lambda e: e.sequence([1, 2], integer), lambda e: e.sequence([0, 0], integer)),
    "ItemArray": (lambda e: e.array([1, 2], integer), lambda e: e.array([0, 0], integer)),
    "NestedSeq": (lambda e: e.sequence([[1, 2], []], lambda p, v: p.primitive_sequence(v)), lambda e: e.sequence([[0, 0]] * 2, lambda p, v: p.primitive_sequence(v))),
    "ArraySeq": (lambda e: e.sequence([[0, 1]], enums), lambda e: e.sequence([[0, 0]] * 2, enums)),
    "UnionSeq": (lambda e: e.sequence([(0, "A"), (1, 7)], choice), lambda e: e.sequence([(0, "XXXX")] * 2, choice)),
    "StringEnvelope": (envelope, lambda e: (e.uint(1, 0), e.sequence(["XXXX"] * 2, text), e.uint(1, 0))),
    "WideArray": (lambda e: e.array([[65], []], lambda p, v: p.wide(v)), lambda e: e.array([[0, 0]] * 2, lambda p, v: p.wide(v))),
}
rows = []
for name, (actual, maximum) in cases.items():
    data = encoded(actual); force = len(encoded(maximum)) > 16
    digest = hashlib.md5(data).digest() if force else data.ljust(16, b"\0")
    rows.append(f"{name} {data.hex()} {digest.hex()} {int(force)}\n")
here = pathlib.Path(__file__).resolve().parent
(here / "variable_vectors.txt").write_text("".join(rows))
# Correct the three pre-existing collection witnesses rather than retaining
# contradictory expectations for the same canonical encoding.
replacement = {
    "ArrayKey": (encoded(lambda e: e.array([0x01020304, 0x05060708], integer)), False),
    "SeqAgg": (encoded(lambda e: e.sequence([0x01020304, 0x05060708], integer)), False),
    "WideSeq": (encoded(lambda e: e.sequence([[65, 0x1234], []], lambda p, v: p.wide(v))), True),
}
old_rows = (here / "vectors.txt").read_text().splitlines()
for i, row in enumerate(old_rows):
    name = row.split()[0]
    if name in replacement:
        data, force = replacement[name]
        digest = hashlib.md5(data).digest() if force else data.ljust(16, b"\0")
        old_rows[i] = f"{name} {data.hex()} {digest.hex()} {int(force)}"
(here / "vectors.txt").write_text("\n".join(old_rows) + "\n")
