#!/usr/bin/env python3
"""Independent XTypes 1.3 optional-header and alignment witnesses."""
from pathlib import Path
import struct

class Wire:
    def __init__(self, version, order, compact=False):
        self.v, self.order, self.compact = version, order, compact
        self.data = bytearray()
        self.origin = 0
    def align(self, n):
        self.data += b'\0' * (-(len(self.data) - self.origin) % n)
    def u(self, value, n):
        self.align(min(n, 8 if self.v == 1 else 4))
        self.data += value.to_bytes(n, self.order)
    def text(self, value):
        raw = value.encode() + b'\0'
        self.u(len(raw), 4)
        self.data += raw
    def optional(self, id, value, encode):
        if self.v == 2:
            self.u(value is not None, 1)
            if value is not None: encode(value)
            return
        self.align(4)
        compact = self.compact and id <= 0x3f00
        if compact:
            self.u(id, 2); offset = len(self.data); self.u(0, 2)
        else:
            self.u(0x7f01, 2); self.u(8, 2); self.u(id, 4)
            offset = len(self.data); self.u(0, 4)
        origin, start = self.origin, len(self.data)
        self.origin = start
        if value is not None: encode(value)
        size = len(self.data) - start
        self.data[offset:offset+(2 if compact else 4)] = size.to_bytes(2 if compact else 4, self.order)
        self.origin = origin
    def frame(self, encode):
        if self.v == 1: return encode()
        self.align(4); offset = len(self.data); self.u(0, 4)
        encode()
        self.data[offset:offset+4] = (len(self.data)-offset-4).to_bytes(4,self.order)
    def inner(self):
        self.u(0xa5, 1)
        self.optional(7, 0x0102030405060708, lambda x:self.u(x,8))
        self.u(99, 8)
    def values(self, present):
        self.optional(0, 0x0102030405060708 if present else None, lambda x:self.u(x,8))
        self.optional(0x3f00, '' if present else None, self.text)
        self.optional(0x3f01, [42,43] if present else None, lambda xs:[self.u(x,8) for x in xs])
        def seq(xs):
            def body():
                self.u(len(xs),4)
                for x in xs:self.text(x)
            if self.v == 2:self.frame(body)
            else:body()
        self.optional(31, ['blue','orange'] if present else None, seq)
        self.u(0x1122334455667788,8)
    def derived(self,present):
        def body():
            self.optional(0, True if present else None, lambda _:self.inner())
            self.optional(1, 'extra' if present else None,self.text)
            self.u(0x1122334455667788,8)
        self.frame(body)

def payload(name,present,version,order,compact):
    w=Wire(version,order,compact)
    (w.values if name=='Values' else w.derived)(present)
    id=(0 if version==1 else 6 if name=='Values' else 8)+(order=='little')
    return id.to_bytes(2,'big')+b'\0\0'+w.data
rows=[]
for name in ['Values','Derived']:
    for present in [False,True]:
        for version in [1,2]:
            for order in ['little','big']:
                rows.append(f'{name} {int(present)} {version} {int(order=="big")} '+payload(name,present,version,order,False).hex()+' '+payload(name,present,version,order,True).hex())
Path(__file__).with_name('vectors.txt').write_text('\n'.join(rows)+'\n')
