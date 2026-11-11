import java.nio.*;
import java.util.*;
public class CollectionTest {
    static void reject(String type, String method, ByteBuffer b, Class<?> error, int position) throws Exception {
        int limit = b.limit();
        try { FrameTest.call(type, method, b, 0, 2); throw new AssertionError("accepted malformed collection"); }
        catch (RuntimeException e) { if (e.getClass() != error) throw new AssertionError(type + ": expected " + error.getSimpleName(), e); }
        FrameTest.check(b.position() == position); FrameTest.check(b.limit() == limit);
    }
    static Object get(Object value, String field) throws Exception { return value.getClass().getMethod("get_" + field).invoke(value); }
    public static void main(String[] args) throws Exception {
        FrameTest.prefix = args[0];
        reject("Numbers", "skip", FrameTest.wire(-1, 11), IllegalArgumentException.class, 4);
        for (String method : new String[]{"deserializeFrom", "deserializeKey", "skip", "deserializeSelected", "deserializeSelectedAll"}) {
            reject("Numbers", method, FrameTest.wire(-1, 11), IllegalArgumentException.class, 4);
            reject("Numbers", method, ByteBuffer.allocate(3), BufferUnderflowException.class, 0);
            reject("Numbers", method, FrameTest.wire(Integer.MAX_VALUE), BufferUnderflowException.class, 4);
            reject("Bounded", method, FrameTest.wire(3, 7, 8, 9), IllegalArgumentException.class, 4);
            reject("Words", method, FrameTest.wire(4, 1, 1, 0, 11), BufferUnderflowException.class, 8);
            reject("Words", method, FrameTest.wire(-1, 1), BufferUnderflowException.class, 4);
            reject("WordArray", method, FrameTest.wire(0, 1, 0, 11), BufferUnderflowException.class, 4);
        }
        for (String method : new String[]{"deserializeFrom", "skip"}) {
            reject("Dict", method, FrameTest.wire(8, 1, 1, 0, 11), BufferUnderflowException.class, 12);
            reject("BoundedMap", method, FrameTest.wire(-1), IllegalArgumentException.class, 4);
            reject("BoundedMap", method, FrameTest.wire(3), IllegalArgumentException.class, 4);
            reject("Dict", method, FrameTest.wire(4, Integer.MAX_VALUE), BufferUnderflowException.class, 8);
            reject("Dict", method, FrameTest.wire(16, Integer.MAX_VALUE, 1, 0, 7, 11), BufferUnderflowException.class, 20);
            reject("NestedValues", method, FrameTest.wire(8, 1, Integer.MAX_VALUE), BufferUnderflowException.class, 12);
        }
        ByteBuffer empty = FrameTest.wire(4, 3, 11);
        Object empties = FrameTest.call("EmptyValues", "deserializeFrom", empty, 0, 2);
        FrameTest.check(((List<?>) get(empties, "values")).size() == 3);
        FrameTest.check(get(empties, "tail").equals(11));
        ByteBuffer words = FrameTest.wire(12, 1, 1, 0, 11);
        Object value = FrameTest.call("Words", "deserializeFrom", words, 0, 2);
        FrameTest.check(((List<?>)get(value, "values")).equals(Collections.singletonList("")));
        FrameTest.check(get(value, "tail").equals(11));
        for (int version : new int[]{1,2}) {
            ByteBuffer wire = version == 1 ? FrameTest.wire(1, 1, 0, 11) : FrameTest.wire(12, 1, 1, 0, 11);
            FrameTest.call("Words", "skip", wire, 0, version); FrameTest.check(wire.position() == wire.limit());
        }
        ByteBuffer dict = FrameTest.wire(16, 1, 1, 0, 7, 11);
        Object dictValue = FrameTest.call("Dict", "deserializeFrom", dict, 0, 2);
        FrameTest.check(get(dictValue, "values").equals(Collections.singletonMap("",7)));
        FrameTest.check(get(dictValue, "tail").equals(11));
        for (int mode = 0; mode < 3; mode++) {
            ByteBuffer b = mode == 1 ? ByteBuffer.allocateDirect(32) : ByteBuffer.allocate(32);
            b.order(ByteOrder.LITTLE_ENDIAN); b.position(8);
            b.putInt(12).putInt(1).putInt(1).putInt(0).putInt(11); b.position(5);
            if (mode == 2) b = b.asReadOnlyBuffer();
            FrameTest.call("Words", "deserializeFrom", b, 4, 2);
            FrameTest.check(b.position() == 28); FrameTest.check(b.limit() == 32);
        }
        ByteBuffer nested = FrameTest.wire(16, 1, 2, 7, 8, 11);
        Object nestedValue = FrameTest.call("NestedValues", "deserializeFrom", nested, 0, 2);
        FrameTest.check(get(nestedValue, "tail").equals(11));
        FrameTest.check(((List<?>)get(nestedValue, "values")).get(0).equals(Arrays.asList(7,8)));
        System.out.println("Java CDR collection bounds passed");
    }
}
