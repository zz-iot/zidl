package io.zidl.cdr;

import java.nio.*;
import java.util.Arrays;

public final class CdrTest {
    private static void check(boolean value) { if (!value) throw new AssertionError(); }

    private static void reject(byte[] bytes, Class<?> expected, int position) {
        ByteBuffer buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
        try { Cdr.readString(buffer, 0); throw new AssertionError("accepted malformed string"); }
        catch (RuntimeException error) { check(error.getClass() == expected); }
        check(buffer.position() == position); check(buffer.limit() == bytes.length);
    }

    public static void main(String[] args) {
        Cdr.requireApi(1);
        try { Cdr.requireApi(2); throw new AssertionError("accepted newer API"); }
        catch (LinkageError error) { check(error.getMessage().contains("runtime provides 1")); }
        byte[] bytes = new byte[12]; Arrays.fill(bytes, (byte)127);
        ByteBuffer buffer = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN);
        buffer.position(5); Cdr.align(buffer,4,4);
        check(buffer.position() == 8); check(buffer.order() == ByteOrder.BIG_ENDIAN);
        for (byte b : bytes) check(b == 127);
        buffer.position(5); Cdr.alignKey(buffer,4,4);
        check(bytes[4] == 127 && bytes[5] == 0 && bytes[6] == 0 && bytes[7] == 0 && bytes[8] == 127);
        ByteBuffer readOnly = buffer.asReadOnlyBuffer(); readOnly.position(5);
        Cdr.align(readOnly,4,4); check(readOnly.position() == 8);
        readOnly.position(5);
        try { Cdr.alignKey(readOnly,4,4); throw new AssertionError(); }
        catch (ReadOnlyBufferException expected) { }
        reject(new byte[]{0,0,0,0}, IllegalArgumentException.class,4);
        reject(new byte[]{-1,-1,-1,-1}, BufferUnderflowException.class,4);
        reject(new byte[]{2,0,0,0,120,1}, IllegalArgumentException.class,4);
        reject(new byte[]{2,0,0,0,120}, BufferUnderflowException.class,4);
        reject(new byte[]{1,0,0}, BufferUnderflowException.class,0);
        for (int mode = 0; mode < 3; mode++) {
            ByteBuffer wire = mode == 1 ? ByteBuffer.allocateDirect(32) : ByteBuffer.allocate(32);
            wire.order(ByteOrder.LITTLE_ENDIAN); wire.position(5);
            Cdr.writeString(wire,4,"é"); check(wire.position() == 15);
            wire.limit(15); wire.position(5);
            if (mode == 2) wire = wire.asReadOnlyBuffer().order(ByteOrder.LITTLE_ENDIAN);
            check(Cdr.readString(wire,4).equals("é")); check(wire.position() == 15);
            wire.position(5); Cdr.skipString(wire,4); check(wire.position() == 15);
        }
        byte[] shortBytes = new byte[8]; Arrays.fill(shortBytes,(byte)127);
        ByteBuffer shortBuffer = ByteBuffer.wrap(shortBytes); shortBuffer.position(1);
        try { Cdr.writeString(shortBuffer,0,"x"); throw new AssertionError(); }
        catch (BufferOverflowException expected) { }
        check(shortBuffer.position() == 1);
        for (byte b : shortBytes) check(b == 127);
        for (ByteOrder order : new ByteOrder[]{ByteOrder.BIG_ENDIAN,ByteOrder.LITTLE_ENDIAN}) {
            ByteBuffer wire = ByteBuffer.allocate(16).order(order);
            Cdr.writeString(wire,0,"é"); check(wire.order() == order);
            wire.flip(); check(Cdr.readString(wire,0).equals("é")); check(wire.order() == order);
        }
        ByteBuffer invalidUtf8 = ByteBuffer.wrap(new byte[]{2,0,0,0,(byte)0xc3,0}).order(ByteOrder.LITTLE_ENDIAN);
        check(Cdr.readString(invalidUtf8,0).equals("\ufffd"));
        ByteBuffer surrogate = ByteBuffer.allocate(6).order(ByteOrder.LITTLE_ENDIAN);
        Cdr.writeString(surrogate,0,"\ud800");
        check(Arrays.equals(surrogate.array(),new byte[]{2,0,0,0,63,0}));
        System.out.println("Java CDR runtime API 1 passed");
    }
}
