import java.nio.*;
import java.util.*;
public class MapTest {
  static final byte[] bytes = {0, 7, 0,   0, 18, 0,   0, 0, 1, 0, 0,
                               0, 2, 0,   0, 0,  'k', 0, 0, 0, 2, 0,
                               0, 0, 'v', 0, 0,  0,   7, 0, 0, 0};
  static void check(boolean b) {
    if (!b)
      throw new AssertionError();
  }
  static void read(byte[] b, boolean valid) {
    ByteBuffer r = ByteBuffer.wrap(b);
    r.position(4);
    try {
      Shapes.MapAudit.Owned v = Shapes.MapAudit.Owned.deserializeFrom(r, 4, 2);
      check(valid && r.position() == b.length &&
            v.get_values().get("k").equals("v"));
      ByteBuffer w = ByteBuffer.allocate(128);
      w.put(new byte[] {0, 7, 0, 0});
      v.serialize(w, 4, 2);
      check(Arrays.equals(bytes, Arrays.copyOf(w.array(), w.position())));
    } catch (IllegalArgumentException | BufferUnderflowException e) {
      check(!valid);
    }
  }
  public static void main(String[] args) {
    byte[] nested = {0, 7, 0,   0,  30, 0, 0, 0, 1, 0, 0,   0, 9,
                     0, 0, 0,   18, 0,  0, 0, 1, 0, 0, 0,   2, 0,
                     0, 0, 'k', 0,  0,  0, 2, 0, 0, 0, 'v', 0};
    ByteBuffer nr = ByteBuffer.wrap(nested);
    nr.position(4);
    Shapes.MapAudit.Nested nv =
        Shapes.MapAudit.Nested.deserializeFrom(nr, 4, 2);
    check(nv.get_values().get(9).get("k").equals("v"));
    ByteBuffer nw = ByteBuffer.allocate(128);
    nw.put(new byte[] {0, 7, 0, 0});
    nv.serialize(nw, 4, 2);
    check(Arrays.equals(nested, Arrays.copyOf(nw.array(), nw.position())));
    read(bytes, true);
    for (int n = 4; n < bytes.length; n++)
      read(Arrays.copyOf(bytes, n), false);
    byte[] dup = new byte[48];
    System.arraycopy(bytes, 0, dup, 0, 12);
    dup[4] = 34;
    dup[8] = 2;
    System.arraycopy(bytes, 12, dup, 12, 16);
    System.arraycopy(bytes, 12, dup, 28, 16);
    System.arraycopy(bytes, 28, dup, 44, 4);
    read(dup, false);
  }
}
