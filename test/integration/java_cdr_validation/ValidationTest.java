import java.lang.reflect.InvocationTargetException;
import java.nio.*;
import java.util.Arrays;

public class ValidationTest {
    static Class<?> type;
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    static Object call(String method, ByteBuffer buffer) throws Exception {
        return call(method, buffer, 0);
    }
    static Object call(String method, ByteBuffer buffer, int base) throws Exception {
        try {
            if (method.equals("deserializeSelected"))
                return type.getMethod(method, ByteBuffer.class, int.class, int.class, long.class)
                    .invoke(null, buffer, base, 2, 0L);
            return type.getMethod(method, ByteBuffer.class, int.class, int.class)
                .invoke(null, buffer, base, 2);
        } catch (InvocationTargetException e) {
            Throwable cause = e.getCause();
            if (cause instanceof RuntimeException) throw (RuntimeException) cause;
            throw e;
        }
    }
    static void reject(String method, byte[] bytes, Class<?> error, int position) throws Exception {
        ByteBuffer buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
        try { call(method, buffer); throw new AssertionError("accepted malformed string"); }
        catch (RuntimeException e) { check(e.getClass() == error); }
        check(buffer.position() == position);
        check(buffer.limit() == bytes.length);
    }
    public static void main(String[] args) throws Exception {
        type = Class.forName(args[0] + "Narrow");
        for (String method : new String[]{"deserializeFrom", "skip", "deserializeSelected"}) {
            reject(method, new byte[]{0,0,0,0}, IllegalArgumentException.class, 4);
            reject(method, new byte[]{-1,-1,-1,-1}, BufferUnderflowException.class, 4);
            reject(method, new byte[]{-1,-1,-1,127}, BufferUnderflowException.class, 4);
            reject(method, new byte[]{2,0,0,0,120,1}, IllegalArgumentException.class, 4);
            reject(method, new byte[]{2,0,0,0,120}, BufferUnderflowException.class, 4);
            reject(method, new byte[]{1,0,0}, BufferUnderflowException.class, 0);
            ByteBuffer valid = ByteBuffer.wrap(new byte[]{3,0,0,0,-61,-87,0}).order(ByteOrder.LITTLE_ENDIAN);
            Object result = call(method, valid);
            check(valid.position() == 7);
            if (method.equals("deserializeFrom")) check(type.getMethod("get_text").invoke(result).equals("é"));
            ByteBuffer empty = ByteBuffer.wrap(new byte[]{1,0,0,0,0}).order(ByteOrder.LITTLE_ENDIAN);
            call(method, empty); check(empty.position() == 5);
        }
        for (String method : new String[]{"deserializeFrom", "skip", "deserializeSelected"}) {
            for (int mode = 0; mode < 3; mode++) {
                ByteBuffer padded = mode == 1 ? ByteBuffer.allocateDirect(20) : ByteBuffer.allocate(20);
                padded.order(ByteOrder.LITTLE_ENDIAN);
                padded.position(8); padded.putInt(2); padded.put((byte)'x'); padded.put((byte)0);
                padded.position(5); padded.limit(14);
                if (mode == 2) padded = padded.asReadOnlyBuffer().order(ByteOrder.LITTLE_ENDIAN);
                call(method, padded, 4);
                check(padded.position() == 14); check(padded.limit() == 14);
            }
        }
        Object value = type.getConstructor().newInstance();
        type.getMethod("set_text", String.class).invoke(value, "x");
        byte[] bytes = new byte[8]; Arrays.fill(bytes, (byte)127);
        ByteBuffer shortBuffer = ByteBuffer.wrap(bytes); shortBuffer.position(1);
        try {
            type.getMethod("serialize", ByteBuffer.class, int.class, int.class).invoke(value, shortBuffer, 0, 2);
            throw new AssertionError("accepted short output");
        } catch (InvocationTargetException e) { check(e.getCause() instanceof BufferOverflowException); }
        check(shortBuffer.position() == 1);
        for (byte b : bytes) check(b == 127);
        System.out.println("Java CDR validation passed");
    }
}
