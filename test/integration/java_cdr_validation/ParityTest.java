import java.nio.*;
import java.util.Arrays;
public class ParityTest {
    public static void main(String[] args) throws Exception {
        FrameTest.prefix = args[0];
        Class<?> type = Class.forName(args[0] + "FixedValues");
        byte[] expected = {0x12,0x34,0x5c,0,1,0x23,0x45,0x6d,7,0,0,0};
        for (int version : new int[]{1,2}) {
            Object value = type.getConstructor().newInstance();
            type.getMethod("set_small", double.class).invoke(value,123.45);
            type.getMethod("set_large", double.class).invoke(value,-1234.56);
            type.getMethod("set_tail", int.class).invoke(value,7);
            ByteBuffer b = ByteBuffer.allocate(12);
            type.getMethod("serialize", ByteBuffer.class,int.class,int.class).invoke(value,b,0,version);
            FrameTest.check(Arrays.equals(b.array(),expected));
            b.flip();
            Object decoded = FrameTest.call("FixedValues","deserializeFrom",b,0,version);
            FrameTest.check(CollectionTest.get(decoded,"small").equals(123.45));
            FrameTest.check(CollectionTest.get(decoded,"large").equals(-1234.56));
            FrameTest.check(CollectionTest.get(decoded,"tail").equals(7));
            FrameTest.check(b.position() == 12);
            b.rewind(); FrameTest.call("FixedValues","skip",b,0,version);
            FrameTest.check(b.position() == 12);
        }
        Class<?> optional = Class.forName(args[0] + "OptionalValues");
        for (int version : new int[]{1,2}) {
            for (Integer field : new Integer[]{null,7}) {
                Object value = optional.getConstructor().newInstance();
                optional.getMethod("set_value",Integer.class).invoke(value,field);
                optional.getMethod("set_tail",int.class).invoke(value,11);
                ByteBuffer wire = ByteBuffer.allocate(64);
                optional.getMethod("serialize",ByteBuffer.class,int.class,int.class).invoke(value,wire,0,version);
                int end = wire.position(); wire.flip();
                Object decoded = FrameTest.call("OptionalValues","deserializeFrom",wire,0,version);
                FrameTest.check(java.util.Objects.equals(CollectionTest.get(decoded,"value"),field));
                FrameTest.check(CollectionTest.get(decoded,"tail").equals(11));
                FrameTest.check(wire.position() == end);
                wire.rewind(); FrameTest.call("OptionalValues","skip",wire,0,version);
                FrameTest.check(wire.position() == end);
            }
        }
        Class<?> flags = Class.forName(args[0] + "Flags");
        Object bits = flags.getConstructor().newInstance();
        flags.getMethod("set_value",short.class).invoke(bits,(short)0xabc);
        ByteBuffer b = ByteBuffer.allocate(4); b.position(1);
        flags.getMethod("serialize",ByteBuffer.class,int.class,int.class).invoke(bits,b,0,2);
        FrameTest.check(Arrays.equals(b.array(),new byte[]{0,0,(byte)0xbc,0x0a}));
        b.position(1);
        Object decodedBits = FrameTest.call("Flags","deserializeFrom",b,0,2);
        FrameTest.check(((Number)CollectionTest.get(decodedBits,"value")).intValue() == 0xabc);
        System.out.println("Java CDR output parity passed");
    }
}
