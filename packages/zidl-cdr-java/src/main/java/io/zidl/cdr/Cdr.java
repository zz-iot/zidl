package io.zidl.cdr;

/** Stateless Java CDR buffer operations. Byte order belongs to the caller. */
public final class Cdr {
    public static final int API_LEVEL = 1;

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
}
