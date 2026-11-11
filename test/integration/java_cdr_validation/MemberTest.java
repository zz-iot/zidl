import java.nio.*;
public class MemberTest {
    static void reject(String type, String method, ByteBuffer b, Class<?> error, int pos) throws Exception {
        int limit = b.limit();
        try { FrameTest.call(type, method, b, 0, 2); throw new AssertionError("accepted invalid member"); }
        catch (RuntimeException e) { if (e.getClass() != error) throw new AssertionError(type + ": expected " + error.getSimpleName(), e); }
        FrameTest.check(b.limit() == limit); FrameTest.check(b.position() == pos);
    }
    public static void main(String[] args) throws Exception {
        FrameTest.prefix = args[0];
        for (String method : new String[]{"deserializeFrom", "deserializeKey"}) {
            reject("MutText", method, FrameTest.wire(8, 0x40000000, 4, 2, 0), BufferUnderflowException.class, 12);
            reject("MutText", method, FrameTest.wire(12, 0x40000000, 4, 2, 0), BufferUnderflowException.class, 16);
            reject("MutText", method, FrameTest.wire(8, 0x40000000, -1), BufferUnderflowException.class, 12);
            reject("MutText", method, FrameTest.wire(8, 0x60000000, -1), IllegalArgumentException.class, 8);
            reject("MutText", method, FrameTest.wire(4, 0x40000000, 4), BufferUnderflowException.class, 8);
            reject("MutText", method, FrameTest.wire(8, 0xa0000009, 7), IllegalArgumentException.class, 8);
            ByteBuffer unknown = FrameTest.wire(8, 0x20000009, 7, 11);
            FrameTest.call("MutText", method, unknown, 0, 2);
            FrameTest.check(unknown.position() == 12); FrameTest.check(unknown.getInt() == 11);
        }
        ByteBuffer known = FrameTest.wire(16, 0x40000000, 8, 7, 99, 11);
        Object value = FrameTest.call("Mut", "deserializeFrom", known, 0, 2);
        FrameTest.check(value.getClass().getMethod("get_value").invoke(value).equals(7));
        FrameTest.check(known.position() == 20); FrameTest.check(known.getInt() == 11);
        reject("Mut", "deserializeFrom", FrameTest.wire(5, 0x00000000, 7), BufferUnderflowException.class, 8);
        for (String type : new String[]{"AppChoice", "MutChoice"}) {
            reject(type, "deserializeFrom", FrameTest.wire(4, 0, 7), BufferUnderflowException.class, 8);
            reject(type, "deserializeFrom", FrameTest.wire(-1, 0), BufferUnderflowException.class, 4);
        }
        reject("MutChoice", "deserializeFrom", FrameTest.wire(8, 0xa0000009, 7), IllegalArgumentException.class, 8);
        reject("MutChoice", "deserializeFrom", FrameTest.wire(8, 0x40000001, 4, 7), BufferUnderflowException.class, 12);
        reject("MutChoice", "deserializeFrom", FrameTest.wire(4, 0x50000009, 7), BufferUnderflowException.class, 8);
        ByteBuffer unknownUnion = FrameTest.wire(24, 0x20000000, 0, 0x20000009, 99, 0x20000001, 7, 11);
        Object knownUnion = FrameTest.call("MutChoice", "deserializeFrom", unknownUnion, 0, 2);
        FrameTest.check(knownUnion.getClass().getMethod("get_value").invoke(knownUnion).equals(7));
        FrameTest.check(unknownUnion.position() == 28); FrameTest.check(unknownUnion.getInt() == 11);
        ByteBuffer union = FrameTest.wire(12, 0, 7, 99, 11);
        FrameTest.call("AppChoice", "deserializeFrom", union, 0, 2);
        FrameTest.check(union.position() == 16); FrameTest.check(union.getInt() == 11);
        ByteBuffer mutable = FrameTest.wire(16, 0x20000000, 0, 0x20000001, 7, 11);
        FrameTest.call("MutChoice", "deserializeFrom", mutable, 0, 2);
        FrameTest.check(mutable.position() == 20); FrameTest.check(mutable.getInt() == 11);
        System.out.println("Java CDR member bounds passed");
    }
}
