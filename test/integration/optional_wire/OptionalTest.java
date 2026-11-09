import java.lang.reflect.*;
import java.nio.*;
import java.nio.file.*;
import java.util.*;

public final class OptionalTest {
    static String prefix;
    static Class<?> type(String name) throws Exception { return Class.forName(prefix+name); }
    static Object value(String name) throws Exception { return type(name).getConstructor().newInstance(); }
    static void set(Object o, String name, Object v) throws Exception {
        for (Method m:o.getClass().getMethods()) if (m.getName().equals("set_"+name)) { m.invoke(o,v); return; }
        throw new AssertionError(name);
    }
    static void check(boolean v, String why) { if (!v) throw new AssertionError(why); }
    static byte[] hex(String s) {
        byte[] b=new byte[s.length()/2];
        for (int i=0;i<b.length;i++) b[i]=(byte)Integer.parseInt(s.substring(2*i,2*i+2),16);
        return b;
    }
    static Object sample(String name, boolean present) throws Exception {
        Object o=value(name); set(o,"tail",0x1122334455667788L);
        if (!present) return o;
        if (name.equals("Values")) {
            set(o,"number",0x0102030405060708L); set(o,"text","");
            Object pair=value("Pair"); set(pair,"values",new long[]{42,43}); set(o,"numbers",pair);
            set(o,"texts",Arrays.asList("blue","orange"));
        } else {
            Object inner=value("Inner"); set(inner,"prefix",(byte)0xa5);
            set(inner,"value",0x0102030405060708L); set(inner,"tail",99L);
            set(o,"item",inner); set(o,"extra","extra");
        }
        return o;
    }
    static void read(String name, byte[] bytes, int version, boolean key, boolean valid, boolean present) throws Exception {
        ByteBuffer b=ByteBuffer.wrap(bytes).asReadOnlyBuffer().order(ByteOrder.LITTLE_ENDIAN); b.position(4);
        try {
            Object o=type(name).getMethod(key ? "deserializeKeyValue" : "deserializeFrom",ByteBuffer.class,int.class,int.class).invoke(null,b,4,version);
            check(valid,"accepted truncation "+name);
            check(b.position()==bytes.length,"reader position "+name);
            check((long)o.getClass().getMethod("get_tail").invoke(o)==0x1122334455667788L,"tail");
            Object optional=o.getClass().getMethod(name.equals("Values") ? "get_number" : "get_item").invoke(o);
            check((optional!=null)==present,"optional presence");
            if (present && name.equals("Values")) {
                check((long)optional==0x0102030405060708L,"optional number");
                Object pair=o.getClass().getMethod("get_numbers").invoke(o);
                check(Arrays.equals((long[])pair.getClass().getMethod("get_values").invoke(pair),new long[]{42,43}),"array values");
                check(o.getClass().getMethod("get_texts").invoke(o).equals(Arrays.asList("blue","orange")),"sequence values");
            }
            Object text=o.getClass().getMethod(name.equals("Values") ? "get_text" : "get_extra").invoke(o);
            check(present ? text.equals(name.equals("Values") ? "" : "extra") : text==null,"optional text");
        } catch (InvocationTargetException e) {
            check(!valid && e.getCause() instanceof RuntimeException,"unexpected decode "+e.getCause());
        } finally { check(b.limit()==bytes.length,"restore reader limit"); }
    }
    public static void main(String[] args) throws Exception {
        prefix=args[1]; int checked=0;
        for (String line:Files.readAllLines(Paths.get(args[0]))) {
            String[] f=line.split(" +"); if (!f[3].equals("0")) continue;
            String name=f[0]; boolean present=f[1].equals("1"); int version=Integer.parseInt(f[2]);
            byte[] full=hex(f[4]), compact=hex(f[5]); Object o=sample(name,present);
            for (boolean key:new boolean[]{false,true}) {
                ByteBuffer b=ByteBuffer.allocate(1024).order(ByteOrder.LITTLE_ENDIAN); b.put(full,0,4);
                o.getClass().getMethod(key ? "serializeKeyValue" : "serialize",ByteBuffer.class,int.class,int.class).invoke(o,b,4,version);
                check(Arrays.equals(full,Arrays.copyOf(b.array(),b.position())),"wire bytes "+name+" "+version);
                for (byte[] bytes:new byte[][]{full,compact}) {
                    read(name,bytes,version,key,true,present);
                    for (long mask:new long[]{0,0xffff,name.equals("Values") ? 16 : 2}) {
                        ByteBuffer selected=ByteBuffer.wrap(bytes).asReadOnlyBuffer().order(ByteOrder.LITTLE_ENDIAN); selected.position(4);
                        Object decoded=type(name).getMethod("deserializeSelected",ByteBuffer.class,int.class,int.class,long.class).invoke(null,selected,4,version,mask);
                        check(selected.position()==bytes.length && selected.limit()==bytes.length,"selected bounds");
                        if (mask!=0 || name.equals("Derived")) check((long)decoded.getClass().getMethod("get_tail").invoke(decoded)==0x1122334455667788L,"selected tail");
                    }
                    if (name.equals("Values")) {
                        Method getter=type(name).getMethod("getFieldFromCdr",byte[].class,String.class);
                        check((long)getter.invoke(null,bytes,"tail")==0x1122334455667788L,"filter tail");
                        Object number=getter.invoke(null,bytes,"number");
                        check(present ? (long)number==0x0102030405060708L : number==null,"filter optional number");
                        Object text=getter.invoke(null,bytes,"text");
                        check(present ? text.equals("") : text==null,"filter optional text");
                    }
                    for (int n=4;n<bytes.length;n++) read(name,Arrays.copyOf(bytes,n),version,key,false,present);
                }
            }
            checked++;
        }
        check(checked==8,"vector count"); System.out.println("Java optional wire vectors passed");
    }
}
