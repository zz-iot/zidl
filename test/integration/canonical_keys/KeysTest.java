// Independent canonical byte/hash witnesses, shared with C, C++ and Zig.
// Reflection runs the identical checks against single-file and split Java output.
import java.lang.reflect.Array;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class KeysTest {
    static String prefix;
    static int checked;
    static final Map<String, String[]> vectors = new LinkedHashMap<>();
    static Class<?> type(String name) throws Exception { return Class.forName(prefix + name); }
    static Object value(String name) throws Exception { return type(name).getConstructor().newInstance(); }
    static void set(Object obj, String field, Object val) throws Exception {
        for (Method method : obj.getClass().getMethods()) {
            if (method.getName().equals("set_" + field)) { method.invoke(obj, val); return; }
        }
        throw new AssertionError("missing setter: " + field);
    }
    static Object array(String name, Object... values) throws Exception {
        Object result = Array.newInstance(type(name), values.length);
        for (int i = 0; i < values.length; i++) Array.set(result, i, values[i]);
        return result;
    }
    static byte[] hex(String text) {
        byte[] result = new byte[text.length() / 2];
        for (int i = 0; i < result.length; i++) result[i] = (byte)Integer.parseInt(text.substring(i*2, i*2+2), 16);
        return result;
    }
    static void check(boolean ok, String what) { if (!ok) throw new AssertionError(what); }
    static byte[] hash(Object obj) throws Exception { return (byte[])obj.getClass().getMethod("computeKeyHash").invoke(obj); }
    static byte[] holder(Object obj, int base, boolean direct) throws Exception {
        ByteBuffer buf = direct ? ByteBuffer.allocateDirect(4096) : ByteBuffer.allocate(4096);
        while (buf.hasRemaining()) buf.put((byte)0xcc);
        buf.position(base).order(ByteOrder.BIG_ENDIAN);
        obj.getClass().getMethod("serializeKeyHolder", ByteBuffer.class, int.class).invoke(obj, buf, base);
        check(buf.order() == ByteOrder.BIG_ENDIAN, "holder preserves byte order");
        byte[] result = new byte[buf.position() - base];
        buf.position(base); buf.get(result);
        return result;
    }
    static void witness(String name, Object obj) throws Exception {
        String[] vector = vectors.get(name);
        byte[] bytes = hex(vector[1]);
        byte[] digest = hex(vector[2]);
        check(Arrays.equals(bytes, holder(obj, 0, false)), name + " bytes");
        check(Arrays.equals(bytes, holder(obj, 7, true)), name + " direct/nonzero origin bytes");
        check(Arrays.equals(digest, hash(obj)), name + " hash");
        check(obj.getClass().getField("KEY_HASH_FORCE_MD5").getBoolean(null) == vector[3].equals("1"), name + " policy");
        checked++;
    }
    static void fromWire(Object obj, int version, int id, String vector) throws Exception {
        ByteBuffer buf = ByteBuffer.allocate(4096).order(ByteOrder.LITTLE_ENDIAN);
        buf.put((byte)0).put((byte)id).putShort((short)0);
        obj.getClass().getMethod("serialize",ByteBuffer.class,int.class,int.class).invoke(obj,buf,4,version);
        byte[] payload = Arrays.copyOf(buf.array(),buf.position());
        byte[] actual = (byte[])obj.getClass().getMethod("computeKeyHashFromCdr",byte[].class).invoke(null,(Object)payload);
        check(Arrays.equals(actual,hex(vectors.get(vector)[2])),vector + " full wire hash XCDR" + version);
    }
    static void rejects(Object obj) throws Exception {
        try { hash(obj); throw new AssertionError("accepted invalid key"); }
        catch (InvocationTargetException e) { check(e.getCause() instanceof IllegalArgumentException, "checked bound error"); }
    }
    static void checkKeyFrame(byte[] data,boolean ok) throws Exception {
        ByteBuffer buf=ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN); buf.position(4); int limit=buf.limit();
        try {
            Object result=type("Example").getMethod("deserializeKey",ByteBuffer.class,int.class,int.class).invoke(null,buf,4,2);
            check(ok,"accepted malformed key frame");
            check(Arrays.equals(hash(result),hex(vectors.get("Example")[2])),"key frame hash");
            check(buf.position()==data.length,"key frame end");
        } catch(InvocationTargetException e) { check(!ok && e.getCause() instanceof RuntimeException,"key frame failure"); }
        check(buf.limit()==limit,"key frame restores parent limit");
    }
    static void selectedNestedKeys() throws Exception {
        Object inner=value("SelectedInner"); set(inner,"ignored",99); set(inner,"id",42);
        Object outer=value("SelectedOuter"); set(outer,"inner",inner); set(outer,"tail",7);
        byte[] expected=hex("0000002a000000070000000000000000");
        for (int version=1;version<=2;version++) {
            ByteBuffer buf=ByteBuffer.allocate(64).order(ByteOrder.LITTLE_ENDIAN);
            buf.put(new byte[]{0,(byte)(version==1 ? 1 : 7),0,0});
            outer.getClass().getMethod("serialize",ByteBuffer.class,int.class,int.class).invoke(outer,buf,4,version);
            byte[] full=Arrays.copyOf(buf.array(),buf.position());
            buf.flip(); buf.position(4);
            Object selected=type("SelectedOuter").getMethod("deserializeSelected",ByteBuffer.class,int.class,int.class,long.class).invoke(null,buf,4,version,3L);
            Object nested=selected.getClass().getMethod("get_inner").invoke(selected);
            check(nested.getClass().getMethod("get_id").invoke(nested).equals(42),"selected nested key");
            check(selected.getClass().getMethod("get_tail").invoke(selected).equals(7),"selected trailing key");
            check(buf.position()==buf.limit() && Arrays.equals(hash(selected),expected),"selected full-sample extent/hash");
            byte[] fromFull=(byte[])type("SelectedOuter").getMethod("computeKeyHashFromCdr",byte[].class).invoke(null,(Object)full);
            check(Arrays.equals(fromFull,expected),"nested full-sample hash");

            buf.clear(); buf.put(new byte[]{0,(byte)(version==1 ? 1 : 7),0,0});
            outer.getClass().getMethod("serializeKey",ByteBuffer.class,int.class,int.class).invoke(outer,buf,4,version);
            buf.flip(); buf.position(4);
            Object key=type("SelectedOuter").getMethod("deserializeKey",ByteBuffer.class,int.class,int.class).invoke(null,buf,4,version);
            nested=key.getClass().getMethod("get_inner").invoke(key);
            check(nested.getClass().getMethod("get_ignored").invoke(nested).equals(0),"nested key-only projection");
            check(buf.position()==buf.limit() && Arrays.equals(hash(key),expected),"nested key-only extent/hash");
        }
    }
    static Object enumValue(String name, int number) throws Exception {
        return type(name).getMethod("valueOf", int.class).invoke(null, number);
    }
    static void arrayKeys() throws Exception {
        Object zero = enumValue("ArrayEnum", 0), one = enumValue("ArrayEnum", 1);
        Object e16 = value("EnumArray16"); set(e16, "values", array("ArrayEnum", zero, one, zero));
        Object e20 = value("EnumArray20"); set(e20, "values", array("ArrayEnum", zero, one, zero, one));
        Object grid = value("EnumGrid");
        Object rows = Array.newInstance(type("ArrayEnum"), 2, 2);
        Array.set(rows, 0, array("ArrayEnum", zero, one));
        Array.set(rows, 1, array("ArrayEnum", one, zero));
        set(grid, "values", rows);
        Object m16 = value("MaskArray16"), m17 = value("MaskArray17");
        int[] bytes16 = new int[12], bytes17 = new int[13];
        for (int i = 0; i < 12; i++) bytes16[i] = bytes17[i] = (i % 2 == 0 ? 1 : 2);
        bytes17[12] = 1;
        set(m16, "values", bytes16); set(m17, "values", bytes17);
        Object narrow = value("NarrowArray"); set(narrow, "lead", (byte)0xaa); set(narrow, "tail", (byte)0xbb);
        set(narrow, "values", array("ArrayEnum8", enumValue("ArrayEnum8", 0), enumValue("ArrayEnum8", 1), enumValue("ArrayEnum8", 0)));
        Object medium = value("Enum16Array");
        set(medium, "values", array("ArrayEnum16", enumValue("ArrayEnum16", 0), enumValue("ArrayEnum16", 1)));
        Object wide = value("Mask64Array"); set(wide, "values", new long[]{1, 2});
        Object primitive = value("PrimitiveGrid"); set(primitive, "values", new int[][]{{1, 2}, {3, 4}});
        String[] names = {"EnumArray16", "EnumArray20", "EnumGrid", "MaskArray16", "MaskArray17", "NarrowArray", "Enum16Array", "Mask64Array", "PrimitiveGrid"};
        Object[] values = {e16, e20, grid, m16, m17, narrow, medium, wide, primitive};
        for (int i = 0; i < names.length; i++) {
            witness(names[i], values[i]);
            fromWire(values[i], 1, 1, names[i]);
            fromWire(values[i], 2, 7, names[i]);
        }
    }
    public static void main(String[] args) throws Exception {
        prefix = args[1];
        selectedNestedKeys();
        List<String> allVectors = new java.util.ArrayList<>(Files.readAllLines(Paths.get(args[0])));
        allVectors.addAll(Files.readAllLines(Paths.get(args[0]).resolveSibling("array_vectors.txt")));
        for (String line : allVectors) {
            String[] parts = line.trim().split(" +");
            if (parts.length == 4) vectors.put(parts[0], parts);
        }
        arrayKeys();
        Object align = value("Align"); set(align,"a",(byte)0xaa); set(align,"b",0x0102030405060708L); witness("Align",align);
        Object nested = value("Nested"); set(nested,"m_long",0x12345678); set(nested,"u",99); set(nested,"w",88);
        Object example = value("Example"); set(example,"label","BLUE"); set(example,"m_nested",nested); witness("Example",example);
        Object b16 = value("Bounded16"); set(b16,"text","BLUE"); witness("Bounded16",b16);
        Object b17 = value("Bounded17"); set(b17,"text","BLUE"); witness("Bounded17",b17);
        Object unbounded = value("Unbounded"); set(unbounded,"text",""); witness("Unbounded",unbounded);
        set(unbounded,"text","abcdefghijklmnopqrstuvwxyz"); witness("UnboundedLong",unbounded);
        witness("Seq16",value("Seq16")); witness("Seq17",value("Seq17"));
        Object inner = value("InnerNoKeys"); set(inner,"hi",(byte)0xaa); set(inner,"lo",(short)0x1234);
        Object unkeyed = value("UnkeyedNested"); set(unkeyed,"inner",inner); witness("UnkeyedNested",unkeyed);
        Object first = value("Nested"); set(first,"m_long",0x01020304);
        Object second = value("Nested"); set(second,"m_long",0x05060708);
        Object arrayKey = value("ArrayKey"); set(arrayKey,"values",array("Nested",first,second)); witness("ArrayKey",arrayKey);
        Object seq = value("SeqAgg"); set(seq,"values",Arrays.asList(first,second)); witness("SeqAgg",seq);
        Object choice = value("Choice"); set(choice,"small",(byte)0xab);
        Object union = value("UnionKey"); set(union,"selection",choice); witness("UnionKey",union);
        Object wide = value("Wide16"); set(wide,"text","A\u1234"); witness("Wide16",wide);
        Object wide17 = value("Wide17"); set(wide17,"text",""); witness("Wide17",wide17);
        Object derived = value("Derived"); set(derived,"base_value",0x01020304); set(derived,"value",(byte)0xaa); witness("Derived",derived);
        Object sequential = value("Sequential"); set(sequential,"a",(byte)0xaa); set(sequential,"b",0x05060708); set(sequential,"c",(byte)0xcc); set(sequential,"d",0x01020304); witness("Sequential",sequential);
        Object hashed = value("Hashed"); set(hashed,"color",(byte)0xaa); set(hashed,"size",0x01020304); witness("Hashed",hashed);
        Object autoDerived = value("AutoDerived"); set(autoDerived,"base_value",0x05060708); set(autoDerived,"tail",(byte)0xaa); set(autoDerived,"value",0x01020304); witness("AutoDerived",autoDerived);
        Object idChoice = value("IdChoice"); set(idChoice,"other",0x01020304);
        Object unionDefault = value("UnionDefault"); set(unionDefault,"selection",idChoice); witness("UnionDefault",unionDefault);
        List<String> wireLines = Files.readAllLines(Paths.get(args[0]).resolveSibling("wire_ids.txt"));
        Object[] wireValues = { sequential, hashed, unionDefault };
        for (int i=0; i<wireValues.length; i++) {
            Object obj=wireValues[i]; String[] parts=wireLines.get(i).split(" +");
            ByteBuffer buf=ByteBuffer.allocate(512).order(ByteOrder.LITTLE_ENDIAN);
            buf.put((byte)0).put((byte)(i==2 ? 7 : 11)).putShort((short)0);
            obj.getClass().getMethod("serialize",ByteBuffer.class,int.class,int.class).invoke(obj,buf,4,2);
            check(Arrays.equals(Arrays.copyOf(buf.array(),buf.position()),hex(parts[1])),parts[0]+" wire IDs");
            fromWire(obj,2,i==2 ? 7 : 11,parts[0]);
        }
        Object wideSeq=value("WideSeq"); set(wideSeq,"values",Arrays.asList("A\u1234","")); witness("WideSeq",wideSeq);
        check(checked == vectors.size(), "all independent vectors checked");
        fromWire(align,1,1,"Align"); fromWire(align,2,7,"Align");
        fromWire(example,2,11,"Example"); fromWire(b16,2,9,"Bounded16");
        set(choice,"big","BLUE");
        byte[] unionBig = hex("0000000100000005424c554500");
        check(Arrays.equals(holder(union,0,false),unionBig),"variable union arm bytes");
        check(Arrays.equals(hash(union),java.security.MessageDigest.getInstance("MD5").digest(unionBig)),"variable union arm hash");
        for (String line : Files.readAllLines(Paths.get(args[0]).resolveSibling("wide_wire.txt"))) {
            String[] parts=line.split(" +"); int version=Integer.parseInt(parts[1]);
            if (!parts[2].equals("0")) {
                // Split helpers honor caller byte order, including read-only input.
                if (prefix.equals("canonicalkeys.") && !parts[0].equals("seq")) {
                    Class<?> utils=Class.forName("canonicalkeys.KeysCdrUtils");
                    ByteBuffer input=ByteBuffer.wrap(hex(parts[3])).asReadOnlyBuffer().order(ByteOrder.BIG_ENDIAN);
                    input.position(4);
                    String decoded=(String)utils.getMethod("_cdrReadWstring",ByteBuffer.class,int.class).invoke(null,input,4);
                    check(decoded.equals(parts[0].equals("empty") ? "" : parts[0].equals("pair") ? "\ud83d\ude00" : "A\u1234"),"BE wide helper");
                    check(input.position()==input.limit(),"BE wide helper span");
                    input.position(4);
                    utils.getMethod("_cdrSkipWstring",ByteBuffer.class,int.class).invoke(null,input,4);
                    check(input.position()==input.limit(),"BE read-only wide skip");
                }
                continue; // Generated Java wire APIs remain LE.
            }
            boolean empty=parts[0].equals("empty");
            boolean wideSequence=parts[0].equals("seq");
            Object obj=value(wideSequence ? "WideSeq" : empty ? "Wide17" : "Wide16");
            if (wideSequence) set(obj,"values",Arrays.asList("A\u1234",""));
            else set(obj,"text",empty ? "" : parts[0].equals("pair") ? "\ud83d\ude00" : "A\u1234");
            ByteBuffer buf=ByteBuffer.allocate(512).order(ByteOrder.LITTLE_ENDIAN);
            buf.put((byte)0).put((byte)(version==1 ? 1 : 7)).putShort((short)0);
            obj.getClass().getMethod("serialize",ByteBuffer.class,int.class,int.class).invoke(obj,buf,4,version);
            byte[] expected=hex(parts[3]);
            check(Arrays.equals(Arrays.copyOf(buf.array(),buf.position()),expected),"wide wire bytes");
            byte[] actual=(byte[])obj.getClass().getMethod("computeKeyHashFromCdr",byte[].class).invoke(null,(Object)expected);
            check(Arrays.equals(hash(obj),actual),"wide full wire hash");
            for(int n=4;n<expected.length;n++) {
                try {
                    obj.getClass().getMethod("computeKeyHashFromCdr",byte[].class).invoke(null,(Object)Arrays.copyOf(expected,n));
                    throw new AssertionError("accepted truncated wide string");
                } catch(InvocationTargetException e) { check(e.getCause() instanceof java.nio.BufferUnderflowException,"wide truncation"); }
            }
            byte[] odd=Arrays.copyOf(expected,expected.length); odd[wideSequence ? (version==1 ? 8 : 12) : 4]=3;
            try {
                obj.getClass().getMethod("computeKeyHashFromCdr",byte[].class).invoke(null,(Object)odd);
                throw new AssertionError("accepted odd wide byte count");
            } catch(InvocationTargetException e) { check(e.getCause() instanceof IllegalArgumentException,"odd wide byte count"); }
        }
        Map<String,Object> keyValues=new LinkedHashMap<>();
        keyValues.put("Example",example); keyValues.put("Nested",nested); keyValues.put("Sequential",sequential); keyValues.put("Hashed",hashed);
        keyValues.put("ArrayKey",arrayKey); keyValues.put("SeqAgg",seq); keyValues.put("UnkeyedNested",unkeyed);
        for(String line:Files.readAllLines(Paths.get(args[0]).resolveSibling("key_wire.txt"))) {
            String[] parts=line.split(" +"); if(!parts[1].equals("0")) continue;
            Object obj=keyValues.get(parts[0]); byte[] expected=hex(parts[2]);
            ByteBuffer buf=ByteBuffer.allocate(512).order(ByteOrder.LITTLE_ENDIAN);
            buf.put(expected,0,4);
            obj.getClass().getMethod("serializeKey",ByteBuffer.class,int.class,int.class).invoke(obj,buf,4,2);
            check(Arrays.equals(Arrays.copyOf(buf.array(),buf.position()),expected),parts[0]+" key-only bytes");
            byte[] digest=(byte[])obj.getClass().getMethod("computeKeyHashFromCdrKeyOnly",byte[].class).invoke(null,(Object)expected);
            check(Arrays.equals(digest,hex(parts[3])),parts[0]+" key-only hash");
            for(int n=4;n<expected.length;n++) {
                try {
                    obj.getClass().getMethod("computeKeyHashFromCdrKeyOnly",byte[].class).invoke(null,(Object)Arrays.copyOf(expected,n));
                    throw new AssertionError("accepted truncated key-only payload");
                } catch(InvocationTargetException e) { check(e.getCause() instanceof RuntimeException,"truncated key-only error"); }
            }
        }
        ByteBuffer unsupported=ByteBuffer.allocate(16); unsupported.position(4);
        try {
            type("Nested").getMethod("serializeKey",ByteBuffer.class,int.class,int.class).invoke(nested,unsupported,4,1);
            throw new AssertionError("accepted mutable key XCDR1");
        } catch(InvocationTargetException e) { check(e.getCause() instanceof IllegalArgumentException && unsupported.position()==4,"unsupported encoding before writes"); }
        byte[] baseKey=hex(Files.readAllLines(Paths.get(args[0]).resolveSibling("key_wire.txt")).get(0).split(" +")[2]);
        for(int mode=0;mode<3;mode++) {
            byte[] bad=Arrays.copyOf(baseKey,baseKey.length);
            ByteBuffer.wrap(bad).order(ByteOrder.LITTLE_ENDIAN).putInt(mode==0 ? 4 : mode==1 ? 12 : 36,mode==0 ? 12 : 4);
            checkKeyFrame(bad,false);
        }
        byte[] future=new byte[baseKey.length+4]; System.arraycopy(baseKey,0,future,0,25);
        System.arraycopy(new byte[]{'F','U','T','R'},0,future,25,4); System.arraycopy(baseKey,25,future,29,baseKey.length-25);
        ByteBuffer.wrap(future).order(ByteOrder.LITTLE_ENDIAN).putInt(4,44).putInt(12,13); checkKeyFrame(future,true);
        byte[] borrowedLength=new byte[baseKey.length-4]; System.arraycopy(baseKey,0,borrowedLength,0,12); System.arraycopy(baseKey,16,borrowedLength,12,baseKey.length-16);
        ByteBuffer.wrap(borrowedLength).order(ByteOrder.LITTLE_ENDIAN).putInt(4,36).putInt(8,0x50000028); checkKeyFrame(borrowedLength,true);
        for(int mu=0;mu<2;mu++) {
            byte[] unknown=Arrays.copyOf(baseKey,baseKey.length+8);
            ByteBuffer.wrap(unknown).order(ByteOrder.LITTLE_ENDIAN).putInt(4,48).putInt(48,0x20000063|(mu==1 ? 0x80000000 : 0)).putInt(52,42);
            checkKeyFrame(unknown,mu==0);
        }
        for(int lc=4;lc<=7;lc++) {
            byte[] overflow=Arrays.copyOf(baseKey,baseKey.length+8);
            ByteBuffer.wrap(overflow).order(ByteOrder.LITTLE_ENDIAN).putInt(4,48).putInt(48,(lc<<28)|99).putInt(52,-1);
            checkKeyFrame(overflow,false);
        }
        // A supplementary character contributes two UTF-16 units, without NUL/BOM.
        set(wide,"text","\ud83d\ude00");
        check(Arrays.equals(holder(wide,0,false),hex("00000004d83dde00")),"surrogate pair");
        // Retry beyond the initial 256-byte hash buffer without changing the policy.
        char[] chars = new char[1024]; Arrays.fill(chars,'a'); set(unbounded,"text",new String(chars));
        byte[] large = new byte[1029]; ByteBuffer.wrap(large).order(ByteOrder.BIG_ENDIAN).putInt(1025);
        Arrays.fill(large,4,1028,(byte)'a');
        check(Arrays.equals(hash(unbounded),java.security.MessageDigest.getInstance("MD5").digest(large)),"hash buffer growth");
        set(b17,"text","1234567890123"); rejects(b17);
        set(b16,"text","\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9"); rejects(b16); // 12 UTF-8 bytes
        Object seq16 = value("Seq16"); set(seq16,"values",Collections.nCopies(13,(byte)0)); rejects(seq16);
        set(wide17,"text","12345678"); rejects(wide17);
        // Normative example from a manually authored valid mutable key-only payload.
        byte[] payload = hex("000b0000250000001e0000400c000000080000000000002078563412280000400900000005000000424c554500");
        byte[] fromKey = (byte[])type("Example").getMethod("computeKeyHashFromCdrKeyOnly",byte[].class).invoke(null,(Object)payload);
        check(Arrays.equals(fromKey,hex(vectors.get("Example")[2])),"mutable key-only decode/hash");
        System.out.println("canonical Java key checks passed (" + checked + " vectors)");
    }
}
