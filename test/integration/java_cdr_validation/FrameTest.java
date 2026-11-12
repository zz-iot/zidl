import java.lang.reflect.InvocationTargetException;
import java.nio.*;

public class FrameTest {
    static String prefix;
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    static Object call(String type, String method, ByteBuffer b, int base, int version) throws Exception {
        Class<?> c = Class.forName(prefix + type);
        try {
            if (method.startsWith("deserializeSelected"))
                return c.getMethod("deserializeSelected", ByteBuffer.class, int.class, int.class, long.class).invoke(null, b, base, version, method.endsWith("All") ? -1L : 0L);
            return c.getMethod(method, ByteBuffer.class, int.class, int.class).invoke(null, b, base, version);
        } catch (InvocationTargetException e) {
            if (e.getCause() instanceof RuntimeException) throw (RuntimeException)e.getCause();
            throw e;
        }
    }
    static ByteBuffer wire(int... words) {
        ByteBuffer b = ByteBuffer.allocate(words.length * 4).order(ByteOrder.LITTLE_ENDIAN);
        for (int word : words) b.putInt(word);
        b.flip(); return b;
    }
    static void reject(String type, String method, ByteBuffer b, int position) throws Exception {
        int limit = b.limit();
        try { call(type, method, b, 0, 2); throw new AssertionError("accepted invalid frame"); }
        catch (BufferUnderflowException expected) { }
        check(b.position() == position); check(b.limit() == limit);
    }
    public static void main(String[] args) throws Exception {
        prefix = args[0];
        for (String method : new String[]{"deserializeFrom", "deserializeKey", "deserializeSelected", "deserializeSelectedAll"}) {
            reject("App", method, wire(0, 7), 4);
            reject("AppText", method, wire(4, 2, 0), 8);
        }
        for (String method : new String[]{"deserializeFrom", "deserializeKey", "deserializeSelected", "deserializeSelectedAll", "skip"}) {
            reject("App", method, wire(-1, 7), 4);
            reject("App", method, wire(12, 7), 4);
            reject("App", method, ByteBuffer.allocate(3), 0);
            ByteBuffer valid = wire(8, 7, 99, 11);
            call("App", method, valid, 0, 2);
            check(valid.position() == 12); check(valid.getInt() == 11);
            ByteBuffer v1 = wire(7, 11);
            call("App", method, v1, 0, 1); check(v1.position() == 4);
            for (int mode = 0; mode < 3; mode++) {
                ByteBuffer b = mode == 1 ? ByteBuffer.allocateDirect(20) : ByteBuffer.allocate(20);
                b.order(ByteOrder.LITTLE_ENDIAN); b.position(8); b.putInt(4); b.putInt(7);
                b.position(5);
                if (mode == 2) b = b.asReadOnlyBuffer();
                call("App", method, b, 4, 2);
                check(b.position() == 16); check(b.limit() == 20);
            }
        }
        ByteBuffer nested = wire(8, 7, 99, 11);
        Object parent = call("Parent", "deserializeFrom", nested, 0, 2);
        check(parent.getClass().getMethod("get_tail").invoke(parent).equals(11));
        check(nested.position() == 16);
        reject("Parent", "deserializeFrom", wire(0, 7), 4);
        ByteBuffer mutable = wire(8, 0x20000000, 7);
        call("Mut", "skip", mutable, 0, 2); check(mutable.position() == 12);
        reject("Mut", "skip", wire(20, 7), 4);
        System.out.println("Java CDR frame bounds passed");
    }
}
