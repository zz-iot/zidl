import java.nio.*;
import java.lang.reflect.*;
import java.util.*;
public class AdmissionTest {
    static String prefix;
    static void check(boolean ok){if(!ok)throw new AssertionError();}
    static byte[] word(int id,int value){return ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putInt(id|0x20000000|(id==0?0x80000000:0)).putInt(value).array();}
    static byte[] text(int id){ByteBuffer b=ByteBuffer.allocate(77).order(ByteOrder.LITTLE_ENDIAN);b.putInt(id|0x40000000).putInt(69).putInt(65);for(int i=0;i<64;i++)b.put((byte)'x');b.put((byte)0);return b.array();}
    static byte[] unknown(boolean mu){return ByteBuffer.allocate(5).order(ByteOrder.LITTLE_ENDIAN).putInt(50|(mu?0x80000000:0)).put((byte)0x7e).array();}
    static byte[] message(byte[]... parts){ByteBuffer b=ByteBuffer.allocate(1024).order(ByteOrder.LITTLE_ENDIAN);b.put(new byte[]{0,11,0,0}).putInt(0);for(byte[]p:parts){while(b.position()%4!=0)b.put((byte)0);b.put(p);}b.putInt(4,b.position()-8);return Arrays.copyOf(b.array(),b.position());}
    static Object read(String name,byte[]bytes,boolean valid)throws Exception{
        Class<?> c=Class.forName(prefix+name);ByteBuffer b=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);b.position(4);
        try{Object out=c.getMethod("deserializeFrom",ByteBuffer.class,int.class,int.class).invoke(null,b,4,2);check(valid && b.position()==bytes.length && b.limit()==bytes.length);return out;}
        catch(InvocationTargetException e){check(!valid && (e.getCause() instanceof IllegalArgumentException || e.getCause() instanceof BufferUnderflowException));check(b.position()<=bytes.length && b.limit()==bytes.length);return null;}
    }
    static Object field(Object o,String name)throws Exception{return o.getClass().getMethod("get_"+name).invoke(o);}
    static void roundtrip(String name,byte[]bytes)throws Exception{Object o=read(name,bytes,true);ByteBuffer out=ByteBuffer.allocate(1024).order(ByteOrder.LITTLE_ENDIAN);out.put(new byte[]{0,11,0,0});o.getClass().getMethod("serialize",ByteBuffer.class,int.class,int.class).invoke(o,out,4,2);check(Arrays.equals(bytes,Arrays.copyOf(out.array(),out.position())));}
    public static void main(String[]args)throws Exception{prefix=args[0];byte[]disc=word(0,1),value=text(20),unk=unknown(false),mu=unknown(true);
        roundtrip("Value",message(disc,value));read("Value",message(value,disc),false);read("Value",message(),false);
        Object missing=read("Value",message(disc),true);check(field(missing,"text").equals(""));
        read("Value",message(disc,disc,value),false);read("Value",message(disc,value,disc),false);read("Value",message(disc,value,value),false);
        read("Value",message(disc,text(30)),false);Object out=read("Value",message(unk,disc,unk,value,unk),true);check(((String)field(out,"text")).length()==64);
        read("Value",message(disc,value,mu),false);read("Value",message(mu,disc,value),false);
        byte[]oversized=Arrays.copyOf(disc,12);ByteBuffer.wrap(oversized).order(ByteOrder.LITTLE_ENDIAN).putInt(0xb0000000);read("Value",message(oversized,value),false);
        byte[]valid=message(disc,value);for(int cut=4;cut<valid.length;cut++)read("Value",Arrays.copyOf(valid,cut),false);
        roundtrip("DefaultFirst",message(word(0,99),text(40)));roundtrip("EnumValue",message(word(0,1),text(20)));
        Object none=read("NoDefault",message(word(0,99)),true);check(((Number)field(none,"discriminator")).intValue()==99);
        byte[]bool=ByteBuffer.allocate(5).order(ByteOrder.LITTLE_ENDIAN).putInt(0x80000000).put((byte)1).array();roundtrip("BooleanValue",message(bool,text(20)));bool[4]=2;read("BooleanValue",message(bool,text(20)),false);
        byte[]wide=ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN).putInt(0xb0000000).putLong(4294967296L).array();roundtrip("LongValue",message(wide,word(10,42)));
        byte[]small=ByteBuffer.allocate(5).order(ByteOrder.LITTLE_ENDIAN).putInt(0x80000000).put((byte)1).array();roundtrip("SmallValue",message(small,text(20)));
        System.out.println("Java mutable union admission passed");
    }
}
