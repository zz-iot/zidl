import java.lang.reflect.*;
import java.nio.*;
import java.util.*;
public class LifecycleTest {
  static String prefix;
  static boolean codecs;
  static void check(boolean ok) {
    if (!ok)
      throw new AssertionError();
  }
  static Object fresh(String type) throws Exception {
    return Class.forName(prefix + type).getConstructor().newInstance();
  }
  static Object get(Object value, String field) throws Exception {
    return value.getClass().getMethod("get_" + field).invoke(value);
  }
  static void set(Object value, String field, Class<?> type, Object arg)
      throws Exception {
    value.getClass().getMethod("set_" + field, type).invoke(value, arg);
  }
  static Object roundtrip(Object value) throws Exception {
    if (!codecs)
      return value;
    ByteBuffer out = ByteBuffer.allocate(4096);
    out.put(new byte[] {0, 7, 0, 0});
    value.getClass()
        .getMethod("serialize", ByteBuffer.class, int.class, int.class)
        .invoke(value, out, 4, 2);
    ByteBuffer in = ByteBuffer.wrap(Arrays.copyOf(out.array(), out.position()));
    in.position(4);
    Object decoded = value.getClass()
                         .getMethod("deserializeFrom", ByteBuffer.class,
                                    int.class, int.class)
                         .invoke(null, in, 4, 2);
    check(in.position() == out.position());
    return decoded;
  }
  static void texts(Object array) {
    for (Object row : (Object[])array)
      for (Object text : (Object[])row)
        check("".equals(text));
  }
  public static void main(String[] args) throws Exception {
    prefix = args[0];
    codecs = Boolean.parseBoolean(args[1]);
    Object e = fresh("EnumValue");
    check(get(e, "discriminator").toString().equals("First"));
    check(get(e, "text").equals(""));
    check(get(e, "words") == null);
    roundtrip(e);
    set(e, "number", int.class, 42);
    check(get(e, "discriminator").toString().equals("Second"));
    set(e, "words", List.class, new ArrayList<String>(Arrays.asList("hello")));
    check(get(e, "discriminator").toString().equals("Third"));
    check(((List<?>)get(roundtrip(e), "words")).equals(Arrays.asList("hello")));
    set(e, "text", String.class, "again");
    check(get(e, "discriminator").toString().equals("First"));
    check(get(roundtrip(e), "text").equals("again"));
    Object d = fresh("DefaultValue");
    check(get(d, "text").equals(""));
    roundtrip(d);
    set(d, "number", int.class, 42);
    set(d, "text", String.class, "default");
    check(((Number)get(d, "discriminator")).intValue() != 1);
    check(get(roundtrip(d), "text").equals("default"));
    Object ld = fresh("LeafDefault");
    check(get(get(ld, "member"), "name").equals(""));
    roundtrip(ld);
    if (codecs) {
      byte[] missing = {0, 11, 0, 0,          8, 0, 0, 0,
                        0, 0,  0, (byte)0xa0, 1, 0, 0, 0};
      ByteBuffer input = ByteBuffer.wrap(missing);
      input.position(4);
      Object omitted = fresh("ArrayValue")
                           .getClass()
                           .getMethod("deserializeFrom", ByteBuffer.class,
                                      int.class, int.class)
                           .invoke(null, input, 4, 2);
      for (Object member : (Object[])get(omitted, "leaves"))
        check(get(member, "name").equals(""));
      roundtrip(omitted);
    }
    Object none = fresh("NoDefault");
    check(((Number)get(none, "discriminator")).intValue() == 0 &&
          get(none, "text") == null);
    roundtrip(none);
    for (String name :
         Arrays.asList("BooleanFinal", "BooleanAppendable", "BooleanMutable")) {
      Object b = fresh(name);
      check(get(b, "discriminator").equals(false));
      roundtrip(b);
      set(b, "text", String.class, "true");
      check(get(b, "discriminator").equals(true));
      check(get(roundtrip(b), "text").equals("true"));
      set(b, "number", int.class, 7);
      check(get(b, "discriminator").equals(false));
      check(get(roundtrip(b), "number").equals(7));
    }
    Object wide = fresh("WideValue");
    check(get(wide, "text").equals(""));
    roundtrip(wide);
    set(wide, "number", int.class, 42);
    check(get(wide, "discriminator").equals(4294967296L));
    check(get(roundtrip(wide), "number").equals(42));
    set(wide, "text", String.class, "wide");
    check(get(roundtrip(wide), "text").equals("wide"));
    Object a = fresh("ArrayValue");
    texts(get(a, "texts"));
    texts(get(roundtrip(a), "texts"));
    check(get(a, "leaves") == null);
    Object ea = fresh("EnumArray");
    for (Object tag : (Object[])get(roundtrip(ea), "tag_values"))
      check(tag.toString().equals("First"));
    Object rec = fresh("Recursive");
    check(((List<?>)get(rec, "children")).isEmpty() &&
          get(rec, "node_value") == null);
    roundtrip(rec);
    Object leaf = fresh("Leaf");
    set(rec, "node_value", leaf.getClass(), leaf);
    check(((Number)get(rec, "discriminator")).intValue() != 0);
    roundtrip(rec);
    Object holder = fresh("Holder");
    check(get(get(holder, "enum_value"), "text").equals(""));
    roundtrip(holder);
    Object generic = fresh("GenericArray");
    for (Object list : (Object[])get(generic, "values"))
      check(((List<?>)list).isEmpty());
    List<?>[] lists = {Arrays.asList(4), Arrays.asList(5, 6)};
    set(generic, "values", List[].class, lists);
    Object[] decodedLists = (Object[])get(roundtrip(generic), "values");
    check(((List<?>)decodedLists[1]).equals(Arrays.asList(5, 6)));
    if (codecs) {
      byte[] missing = {0, 11, 0, 0, 8, 0, 0, 0, 0, 0, 0, (byte)0xa0, 0, 0, 0, 0};
      ByteBuffer input = ByteBuffer.wrap(missing);
      input.position(4);
      Object omitted = generic.getClass().getMethod("deserializeFrom", ByteBuffer.class, int.class, int.class).invoke(null, input, 4, 2);
      for (Object list : (Object[])get(omitted, "values"))
        check(((List<?>)list).isEmpty());
    }
    System.out.println("Java union lifecycle passed");
  }
}
