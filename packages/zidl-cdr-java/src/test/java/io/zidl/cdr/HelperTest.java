package io.zidl.cdr;

import java.nio.*;
import java.util.Arrays;

public final class HelperTest {
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
    private static ByteBuffer wire(int... words) {
        ByteBuffer b=ByteBuffer.allocate(words.length*4).order(ByteOrder.LITTLE_ENDIAN);
        for(int word:words) b.putInt(word);
        b.flip(); return b;
    }
    private static void memberFailure(ByteBuffer b, Class<?> expected, int position) {
        int limit=b.limit();
        try { Cdr.readMember(b,0); throw new AssertionError(); }
        catch(RuntimeException e) { check(e.getClass()==expected); }
        check(b.position()==position && b.limit()==limit);
    }
    public static void main(String[] args) {
        for(int lc=0;lc<8;lc++) {
            int size=lc<4 ? 1<<lc : lc==4 ? 3 : 4+(lc==5 ? 2 : lc==6 ? 8 : 16);
            ByteBuffer b=ByteBuffer.allocate(64).order(ByteOrder.LITTLE_ENDIAN);
            int word=(lc<<28)|0x80000009;
            b.putInt(word);
            if(lc==4) b.putInt(size);
            int start=b.position();
            if(lc>4) b.putInt(2);
            b.limit(start+size); b.position(0);
            long member=Cdr.readMember(b,0);
            check((int)(member>>>32)==word); check((int)member==start+size);
            check(b.position()==start); check(b.limit()==start+size);
        }
        ByteBuffer padding=ByteBuffer.allocate(4); padding.position(1);
        check(Cdr.readMember(padding,0)==-1 && padding.position()==4);
        memberFailure(wire(0x40000009),BufferUnderflowException.class,4);
        memberFailure(wire(0x50000009),BufferUnderflowException.class,4);
        memberFailure(wire(0x60000009,-1),IllegalArgumentException.class,4);
        memberFailure(wire(0x40000009,-1),BufferUnderflowException.class,8);
        memberFailure(wire(0x20000009),BufferUnderflowException.class,4);
        ByteBuffer frame=wire(4,7,11);
        check(Cdr.readFrameEnd(frame,0)==8 && frame.position()==4);
        ByteBuffer count=wire(3);
        try { Cdr.readCount(count,0,2); throw new AssertionError(); }
        catch(IllegalArgumentException expected) { check(count.position()==4); }
        for(ByteOrder order:new ByteOrder[]{ByteOrder.LITTLE_ENDIAN,ByteOrder.BIG_ENDIAN}) {
            ByteBuffer wide=ByteBuffer.allocate(32).order(order);
            Cdr.writeWstring(wide,0,"A\ud800"); int end=wide.position(); wide.flip();
            check(Cdr.readWstring(wide,0).equals("A\ud800")); check(wide.position()==end);
            wide.rewind(); Cdr.skipWstring(wide,0); check(wide.position()==end);
        }
        try { Cdr.readWstring(wire(1,0),0); throw new AssertionError(); }
        catch(IllegalArgumentException expected) { }
        ByteBuffer fixed=ByteBuffer.allocate(8);
        Cdr.writeFixed(fixed,5,2,123.45); Cdr.writeFixed(fixed,8,2,-1234.56);
        check(Arrays.equals(fixed.array(),new byte[]{0x12,0x34,0x5c,0,1,0x23,0x45,0x6d}));
        fixed.flip(); check(Cdr.readFixed(fixed,5,2)==123.45); check(Cdr.readFixed(fixed,8,2)==-1234.56);
        ByteBuffer key=ByteBuffer.allocate(20); key.put(new byte[]{1,2,3});
        byte[] padded=Cdr.computeKeyHash(key); check(padded.length==16 && padded[2]==3 && padded[3]==0 && key.position()==3);
        check(Arrays.equals(Cdr.computeKeyHash(key,true),new byte[]{0x52,(byte)0x89,(byte)0xdf,0x73,0x7d,(byte)0xf5,0x73,0x26,(byte)0xfc,(byte)0xdd,0x22,0x59,0x7a,(byte)0xfb,0x1f,(byte)0xac}));
        check(Cdr.detectXcdr(new byte[]{0,1,0,0})==1);
        for(byte id:new byte[]{7,9,11}) check(Cdr.detectXcdr(new byte[]{0,id,0,0})==2);
        try { Cdr.detectXcdr(new byte[]{0,0,0,0}); throw new AssertionError(); }
        catch(IllegalArgumentException expected) { }
        for(int version:new int[]{1,2}) {
            ByteBuffer b=ByteBuffer.allocate(32).order(ByteOrder.LITTLE_ENDIAN);
            int patch=Cdr.beginOptionalWrite(b,0,version,5,false,true);
            Cdr.align(b,0,4); b.putInt(7); Cdr.endOptionalWrite(b,patch); int end=b.position(); b.flip();
            Cdr.OptionalScope scope=Cdr.beginOptionalRead(b,0,version,5);
            check(scope.present); Cdr.align(b,scope.base,4); check(b.getInt()==7); scope.close();
            check(b.position()==end && b.limit()==end);
        }
        ByteBuffer bounded=wire(0x00087f01,5,4,7,11);
        Cdr.OptionalScope scope=Cdr.beginOptionalRead(bounded,0,1,5);
        try { bounded.getLong(); throw new AssertionError(); }
        catch(BufferUnderflowException expected) { }
        finally { scope.close(); }
        check(bounded.position()==16 && bounded.limit()==20);
        System.out.println("Java CDR shared helper API 2 passed");
    }
}
