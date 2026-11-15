import java.nio.*;
import java.util.*;
public class AdmissionTest {
  static void check(boolean ok) {
    if (!ok)
      throw new AssertionError();
  }
  static final byte[] missing = {0, 7, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0};
  static final byte[] mu = {0, 7, 0,  0, 7, 0,          0,  0, 8, 0,
                            0, 0, 50, 0, 0, (byte)0xa0, 42, 0, 0, 0};
  static final byte[] valid = {0, 7, 0, 0, 7, 0,    0,  0, 8, 0,
                               0, 0, 1, 0, 0, 0x20, 42, 0, 0, 0};
  static ByteBuffer input(byte[] bytes) {
    ByteBuffer b = ByteBuffer.wrap(bytes);
    b.position(4);
    return b;
  }
  public static void main(String[] args) {
    byte[] badMap = {0, 7, 0, 0, 12, 0, 0, 0, 1, 0,
                     0, 0, 7, 0, 0,  0, 0, 0, 0, 0};
    try {
      Shapes.Traversal.MapTopic.deserializeFrom(input(badMap), 4, 2);
      throw new AssertionError();
    } catch (IllegalArgumentException expected) {
    }
    ByteBuffer r = input(mu);
    Shapes.Traversal.StructTopic.skip(r, 4, 2);
    check(r.position() == mu.length);
    try {
      Shapes.Traversal.StructTopic.deserializeFrom(input(mu), 4, 2);
      throw new AssertionError();
    } catch (IllegalArgumentException expected) {
    }
    // Java union traversal decodes a discarded value, so this path is stronger.
    try {
      Shapes.Traversal.UnionTopic.skip(input(missing), 4, 2);
      throw new AssertionError();
    } catch (IllegalArgumentException expected) {
    }
    try {
      Shapes.Traversal.UnionTopic.deserializeFrom(input(missing), 4, 2);
      throw new AssertionError();
    } catch (IllegalArgumentException expected) {
    }
    for (int cut = 4; cut < mu.length; cut++) {
      try {
        Shapes.Traversal.StructTopic.skip(input(Arrays.copyOf(mu, cut)), 4, 2);
        throw new AssertionError();
      } catch (IllegalArgumentException | BufferUnderflowException expected) {
      }
    }
    Shapes.Traversal.StructTopic v =
        Shapes.Traversal.StructTopic.deserializeFrom(input(valid), 4, 2);
    check(v.get_id() == 7 && v.get_payload().get_number() == 42);
  }
}
