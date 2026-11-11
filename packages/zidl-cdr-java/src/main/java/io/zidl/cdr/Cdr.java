package io.zidl.cdr;

/** Stateless Java CDR buffer operations. Byte order belongs to the caller. */
public final class Cdr {
    public static final int API_LEVEL = 2;

    private Cdr() {}

    public static void requireApi(int required) {
        if (required < 1 || required > API_LEVEL)
            throw new LinkageError("zidl Java CDR API " + required + " required; runtime provides " + API_LEVEL);
    }

    public static void align(java.nio.ByteBuffer _buf, int _cdrBase, int _align) {
        if (_align <= 1) return;
        int _p = (_buf.position() - _cdrBase) % _align;
        if (_p != 0) _buf.position(_buf.position() + (_align - _p));
    }

    public static void alignKey(java.nio.ByteBuffer _buf, int _cdrBase, int _align) {
        int _padding = (_align - (_buf.position() - _cdrBase) % _align) % _align;
        for (int _i = 0; _i < _padding; _i++) _buf.put((byte)0);
    }

    public static int stringEnd(java.nio.ByteBuffer _buf, int _cdrBase) {
        long _offset = (long)_buf.position() - _cdrBase;
        if (_offset < 0) throw new IllegalArgumentException("invalid CDR base");
        int _pad = (int)((4 - _offset % 4) % 4);
        if (_buf.remaining() < _pad || _buf.remaining() - _pad < 4) throw new java.nio.BufferUnderflowException();
        _buf.position(_buf.position() + _pad);
        long _len = Integer.toUnsignedLong(_buf.getInt());
        if (_len == 0) throw new IllegalArgumentException("zero CDR string length");
        if (_len > _buf.remaining()) throw new java.nio.BufferUnderflowException();
        int _end = _buf.position() + (int)_len;
        if (_buf.get(_end - 1) != 0) throw new IllegalArgumentException("missing CDR string terminator");
        return _end;
    }

    public static void writeString(java.nio.ByteBuffer _buf, int _cdrBase, String _s) {
        long _offset = (long)_buf.position() - _cdrBase;
        if (_offset < 0) throw new IllegalArgumentException("invalid CDR base");
        int _pad = (int)((4 - _offset % 4) % 4);
        byte[] _bytes = _s.getBytes(java.nio.charset.StandardCharsets.UTF_8);
        if ((long)_pad + 4 + _bytes.length + 1 > _buf.remaining()) throw new java.nio.BufferOverflowException();
        _buf.position(_buf.position() + _pad);
        _buf.putInt(_bytes.length + 1); _buf.put(_bytes); _buf.put((byte)0);
    }

    public static String readString(java.nio.ByteBuffer _buf, int _cdrBase) {
        int _end = stringEnd(_buf, _cdrBase);
        byte[] _bytes = new byte[_end - _buf.position() - 1];
        _buf.get(_bytes); _buf.position(_end);
        return new String(_bytes, java.nio.charset.StandardCharsets.UTF_8);
    }

    public static void skipString(java.nio.ByteBuffer _buf, int _cdrBase) {
        _buf.position(stringEnd(_buf, _cdrBase));
    }
    public static int beginOptionalWrite(java.nio.ByteBuffer b, int base, int version, int id, boolean mu, boolean present) {
        if (version == 2) { b.put(present ? (byte)1 : (byte)0); return -1; }
        align(b, base, 4); b.putShort((short)0x7f01); b.putShort((short)8);
        b.putInt(id | (mu ? 0x40000000 : 0)); int offset = b.position(); b.putInt(0); return offset;
    }

    public static void endOptionalWrite(java.nio.ByteBuffer b, int offset) {
        if (offset >= 0) b.putInt(offset, b.position() - offset - 4);
    }

    public static final class OptionalScope {
        public final java.nio.ByteBuffer buffer;
        public final int base, limit, end;
        public final boolean present;
        OptionalScope(java.nio.ByteBuffer b, int origin, int parentLimit, int valueEnd, boolean exists) {
            buffer = b; base = origin; limit = parentLimit; end = valueEnd; present = exists;
        }
        public void close() { closeOptional(buffer, limit, end); }
    }

    public static OptionalScope beginOptionalRead(java.nio.ByteBuffer b, int base, int version, int id) {
        if (version == 2) {
            byte flag = b.get(); if (flag != 0 && flag != 1) throw new IllegalArgumentException("invalid optional presence");
            return new OptionalScope(b, base, b.limit(), -1, flag != 0);
        }
        align(b, base, 4); int pid = Short.toUnsignedInt(b.getShort());
        long size = Short.toUnsignedInt(b.getShort()); int actual = pid & 0x3fff;
        if ((pid & 0x8000) != 0) throw new IllegalArgumentException("optional implementation extension");
        if (actual == 0x3f01) {
            if (size != 8) throw new IllegalArgumentException("invalid optional extended header");
            int word = b.getInt(); if ((word & 0x80000000) != 0) throw new IllegalArgumentException("optional implementation extension");
            actual = word & 0x0fffffff; size = Integer.toUnsignedLong(b.getInt());
        } else if (actual > 0x3f00) throw new IllegalArgumentException("reserved optional member ID");
        if (actual != id) throw new IllegalArgumentException("unexpected optional member ID");
        if (size > b.remaining()) throw new java.nio.BufferUnderflowException();
        int start = b.position(), end = start + (int)size, limit = b.limit(); b.limit(end);
        return new OptionalScope(b, start, limit, end, size != 0);
    }

    public static void writeWstring(java.nio.ByteBuffer _buf, int _cdrBase, String _s) {
        if (_s.length() > Integer.MAX_VALUE / 2) throw new IllegalArgumentException("wide string length overflow");
        alignKey(_buf, _cdrBase, 4); _buf.putInt(_s.length() * 2);
        for (int _i = 0; _i < _s.length(); _i++) _buf.putChar(_s.charAt(_i));
    }

    public static int wstringBytes(java.nio.ByteBuffer _buf, int _cdrBase) {
        int _pad = (4 - (_buf.position() - _cdrBase) % 4) % 4;
        if (_pad > _buf.remaining()) throw new java.nio.BufferUnderflowException();
        _buf.position(_buf.position() + _pad); int _bytes = _buf.getInt();
        if ((_bytes & 1) != 0) throw new IllegalArgumentException("odd wide string byte count");
        if (_bytes < 0 || _bytes > _buf.remaining()) throw new java.nio.BufferUnderflowException();
        return _bytes;
    }

    public static String readWstring(java.nio.ByteBuffer _buf, int _cdrBase) {
        int _bytes = wstringBytes(_buf, _cdrBase); char[] _units = new char[_bytes / 2];
        for (int _i = 0; _i < _units.length; _i++) _units[_i] = _buf.getChar();
        return new String(_units);
    }

    public static void skipWstring(java.nio.ByteBuffer _buf, int _cdrBase) {
        int _bytes = wstringBytes(_buf, _cdrBase); _buf.position(_buf.position() + _bytes);
    }

    public static int readFrameEnd(java.nio.ByteBuffer _buf, int _cdrBase) {
        long _offset = (long)_buf.position() - _cdrBase;
        if (_offset < 0) throw new IllegalArgumentException("invalid CDR base");
        int _pad = (int)((4 - _offset % 4) % 4);
        if (_buf.remaining() < _pad || _buf.remaining() - _pad < 4) throw new java.nio.BufferUnderflowException();
        _buf.position(_buf.position() + _pad);
        long _size = Integer.toUnsignedLong(_buf.getInt());
        if (_size > _buf.remaining()) throw new java.nio.BufferUnderflowException();
        return _buf.position() + (int)_size;
    }

    public static int readCount(java.nio.ByteBuffer _buf, int _cdrBase, int _bound) {
        long _offset = (long)_buf.position() - _cdrBase;
        if (_offset < 0) throw new IllegalArgumentException("invalid CDR base");
        int _pad = (int)((4 - _offset % 4) % 4);
        if (_buf.remaining() < _pad || _buf.remaining() - _pad < 4) throw new java.nio.BufferUnderflowException();
        _buf.position(_buf.position() + _pad);
        long _count = Integer.toUnsignedLong(_buf.getInt());
        if (_count > _bound) throw new IllegalArgumentException("CDR collection count exceeds Java or IDL bound");
        return (int)_count;
    }

    public static void writeFixed(java.nio.ByteBuffer _buf, int _d, int _s, double _v) {
        int _n = (_d / 2) + 1; int _n2 = _n * 2; int _pad = _n2 - _d - 1;
        boolean _neg = _v < 0.0;
        double _sf = Math.pow(10, _s); long _iv = (long)(Math.abs(_v) * _sf + 0.5);
        byte[] _dig = new byte[_d];
        for (int _i = _d - 1; _i >= 0; _i--) { _dig[_i] = (byte)(_iv % 10); _iv /= 10; }
        byte[] _nib = new byte[_n2];
        for (int _i = 0; _i < _d; _i++) _nib[_pad + _i] = _dig[_i];
        _nib[_n2 - 1] = _neg ? (byte)0x0D : (byte)0x0C;
        byte[] _bcd = new byte[_n];
        for (int _i = 0; _i < _n; _i++) _bcd[_i] = (byte)((_nib[2*_i] << 4) | _nib[2*_i+1]);
        _buf.put(_bcd);
    }

    public static double readFixed(java.nio.ByteBuffer _buf, int _d, int _s) {
        int _n = (_d / 2) + 1; int _n2 = _n * 2; int _pad = _n2 - _d - 1;
        byte[] _bcd = new byte[_n]; _buf.get(_bcd);
        byte[] _nib = new byte[_n2];
        for (int _i = 0; _i < _n; _i++) { _nib[2*_i] = (byte)((_bcd[_i]>>4)&0x0F); _nib[2*_i+1] = (byte)(_bcd[_i]&0x0F); }
        long _iv = 0; for (int _k = 0; _k < _d; _k++) _iv = _iv * 10 + _nib[_pad + _k];
        boolean _neg = (_nib[_n2-1] == 0x0D || _nib[_n2-1] == 0x0B);
        double _r = (double)_iv / Math.pow(10, _s); return _neg ? -_r : _r;
    }

    public static byte[] computeKeyHash(java.nio.ByteBuffer _buf) { return computeKeyHash(_buf, false); }

    public static byte[] computeKeyHash(java.nio.ByteBuffer _buf, boolean _forceMd5) {
        int _len = _buf.position();
        byte[] _key = new byte[_len];
        _buf.position(0); _buf.get(_key);
        if (!_forceMd5 && _len <= 16) {
            byte[] _out = new byte[16];
            System.arraycopy(_key, 0, _out, 0, _len);
            return _out;
        }
        try { return java.security.MessageDigest.getInstance("MD5").digest(_key); }
        catch (java.security.NoSuchAlgorithmException _e) { throw new IllegalStateException(_e); }
    }

    public static int detectXcdr(byte[] _payload) {
        int _id = ((_payload[0] & 0xFF) << 8) | (_payload[1] & 0xFF);
        if (_id == 0x0001) return 1;
        if (_id == 0x0007 || _id == 0x0009 || _id == 0x000b) return 2;
        throw new IllegalArgumentException("zidl: unsupported CDR encapsulation id 0x" + Integer.toHexString(_id));
    }

    public static void closeOptional(java.nio.ByteBuffer buffer, int limit, int end) {
        buffer.limit(limit); if (end >= 0) buffer.position(end);
    }

    /** Upper 32 bits: EMHEADER; lower 32 bits: payload end. -1 means trailing padding. */
    public static long readMember(java.nio.ByteBuffer buffer, int base) {
        int pad = (4 - (buffer.position() - base) % 4) % 4;
        if (pad > buffer.remaining()) throw new java.nio.BufferUnderflowException();
        buffer.position(buffer.position() + pad);
        if (!buffer.hasRemaining()) return -1;
        int word = buffer.getInt(), lc = (word >>> 28) & 7;
        long payload;
        if (lc < 4) payload = 1L << lc;
        else if (lc == 4) payload = Integer.toUnsignedLong(buffer.getInt());
        else {
            if (buffer.remaining() < 4) throw new java.nio.BufferUnderflowException();
            long count = Integer.toUnsignedLong(buffer.getInt(buffer.position()));
            payload = 4 + count * (lc == 5 ? 1L : lc == 6 ? 4L : 8L);
        }
        if (payload > 0xFFFFFFFFL) throw new IllegalArgumentException("EMHEADER size overflow");
        if (payload > buffer.remaining()) throw new java.nio.BufferUnderflowException();
        int end = buffer.position() + (int)payload;
        return ((long)word << 32) | Integer.toUnsignedLong(end);
    }
}
