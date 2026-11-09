import java.lang.reflect.Array;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Map;

public final class ProjectionTest {
    static String prefix;
    static Class<?> type(String name) throws Exception { return Class.forName(prefix+name); }
    static Object value(String name) throws Exception { return type(name).getConstructor().newInstance(); }
    static void set(Object obj, String name, Object value) throws Exception {
        for (Method m:obj.getClass().getMethods()) if (m.getName().equals("set_"+name)) { m.invoke(obj,value); return; }
        throw new AssertionError("missing setter "+name);
    }
    static void check(boolean ok, String message) { if (!ok) throw new AssertionError(message); }
    static byte[] hex(String s) {
        byte[] bytes=new byte[s.length()/2];
        for (int i=0;i<bytes.length;i++) bytes[i]=(byte)Integer.parseInt(s.substring(i*2,i*2+2),16);
        return bytes;
    }
    static byte[] hash(Object obj) throws Exception { return (byte[])obj.getClass().getMethod("computeKeyHash").invoke(obj); }
    static Object mutable(String key) throws Exception {
        Object obj=value("MDerived"); set(obj,"ignored",99); set(obj,"key",key); set(obj,"tail",77); return obj;
    }
    static Object bridge(String name, int before, String key, int after) throws Exception {
        Object obj=value(name); set(obj,"before",before); set(obj,"inner",mutable(key));
        if (name.equals("MutBridge")) set(obj,"after",after);
        return obj;
    }
    static Object decode(String name, byte[] bytes, int version, boolean key, boolean valid) throws Exception {
        ByteBuffer buf=ByteBuffer.wrap(bytes).asReadOnlyBuffer().order(ByteOrder.LITTLE_ENDIAN); buf.position(4);
        int limit=buf.limit();
        try {
            Object obj=type(name).getMethod(key ? "deserializeKey" : "deserializeFrom",ByteBuffer.class,int.class,int.class).invoke(null,buf,4,version);
            check(valid,"accepted malformed "+name);
            check(buf.position()==bytes.length,"reader extent "+name);
            return obj;
        } catch (InvocationTargetException e) {
            check(!valid && e.getCause() instanceof RuntimeException,"unexpected read error "+name+": "+e.getCause());
            return null;
        } finally { check(buf.limit()==limit,"reader limit restored "+name); }
    }
    static void boundaries(String name, byte[] bytes, int version) throws Exception {
        if (version!=2) return;
        int[] offsets=(name.equals("ADerived") || name.equals("MDerived")) ? new int[]{4} : name.equals("RootMut") ? new int[]{4,12,16,32,36} : name.equals("RootArray") ? new int[]{4,8,16} : name.equals("RootSeq") ? new int[]{4,12,32} : new int[0];
        for (int offset:offsets) {
            byte[] shortened=Arrays.copyOf(bytes,bytes.length);
            ByteBuffer buf=ByteBuffer.wrap(shortened).order(ByteOrder.LITTLE_ENDIAN);
            buf.putInt(offset,buf.getInt(offset)-4);
            decode(name,shortened,version,true,false);
        }
    }
    public static void main(String[] args) throws Exception {
        prefix=args[1];
        Map<String,Object> values=new LinkedHashMap<>();
        Object f=value("FDerived"); set(f,"ignored",99); set(f,"id",42); set(f,"middle",88); set(f,"tail",77); values.put("FDerived",f);
        Object a=value("ADerived"); set(a,"ignored",99); set(a,"id",42); set(a,"tail",77); values.put("ADerived",a);
        values.put("MDerived",mutable("blue"));
        for (String name:new String[]{"RootBridge","RootInherited"}) {
            Object inner=value(name.equals("RootBridge") ? "Bridge" : "InheritedBridge"); set(inner,"before",11); set(inner,"inner",f); set(inner,"after",22);
            Object outer=value(name); set(outer,"item",inner); set(outer,"ignored",66); values.put(name,outer);
        }
        Object rootMut=value("RootMut"); set(rootMut,"item",bridge("MutBridge",11,"blue",22)); set(rootMut,"token",33); set(rootMut,"ignored",66); values.put("RootMut",rootMut);
        Object array=Array.newInstance(type("AppBridge"),2); Array.set(array,0,bridge("AppBridge",11,"blue",22)); Array.set(array,1,bridge("AppBridge",33,"orange",44));
        Object rootArray=value("RootArray"); set(rootArray,"values",array); set(rootArray,"ignored",66); values.put("RootArray",rootArray);
        Object rootSeq=value("RootSeq"); set(rootSeq,"values",Arrays.asList(bridge("MutBridge",11,"blue",22),bridge("MutBridge",33,"orange",44))); set(rootSeq,"dynamic_values",Arrays.asList(bridge("MutBridge",11,"blue",22),bridge("MutBridge",33,"orange",44))); set(rootSeq,"ignored",66); values.put("RootSeq",rootSeq);
        int checked=0;
        for (String line:Files.readAllLines(Paths.get(args[0]))) {
            String[] row=line.split(" +"); if (!row[2].equals("0")) continue;
            String name=row[0]; int version=Integer.parseInt(row[1]); Object obj=values.get(name); byte[] expectedHash=hex(row[5]);
            check(Arrays.equals(hash(obj),expectedHash),"independent object hash "+name);
            for (int key=0;key<2;key++) {
                byte[] expected=hex(row[3+key]);
                ByteBuffer buf=ByteBuffer.allocate(1024).order(ByteOrder.LITTLE_ENDIAN); buf.put(expected,0,4);
                obj.getClass().getMethod(key==1 ? "serializeKey" : "serialize",ByteBuffer.class,int.class,int.class).invoke(obj,buf,4,version);
                check(Arrays.equals(Arrays.copyOf(buf.array(),buf.position()),expected),"independent wire bytes "+name+" key="+key);
                check(Arrays.equals(hash(decode(name,expected,version,key==1,true)),expectedHash),"decoded hash "+name);
                byte[] actualHash=(byte[])type(name).getMethod(key==1 ? "computeKeyHashFromCdrKeyOnly" : "computeKeyHashFromCdr",byte[].class).invoke(null,(Object)expected);
                check(Arrays.equals(actualHash,expectedHash),"wire callback hash "+name);
                for (int n=4;n<expected.length;n++) decode(name,Arrays.copyOf(expected,n),version,key==1,false);
                if (key==1) boundaries(name,expected,version);
            }
            checked++;
        }
        check(checked==12,"vector count");
        System.out.println("Java key projection: all vectors passed");
    }
}
