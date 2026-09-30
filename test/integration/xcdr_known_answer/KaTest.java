// Known-answer checks for the Java backend against reference encodings of
// ka.idl from an independent XTypes implementation (vectors.txt; its path is
// args[0]).
//
// For each top-level type, in each reference encoding: zidl encodes the
// sample to exactly the reference bytes (except Mut, where the reference uses
// EMHEADER length codes 5-7 and zidl writes 4); the reference bytes decode to
// a value that re-encodes to zidl's encoding of the same sample, consuming
// every byte; and every truncated input fails.

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

public class KaTest {
    interface Ser<T> { void write(T v, ByteBuffer buf, int base, int xcdr); }
    interface De<T> { T read(ByteBuffer buf, int base, int xcdr); }

    static String vectors;

    static void check(boolean cond, String what) {
        if (!cond) {
            System.err.println("check failed: " + what);
            System.exit(1);
        }
    }

    static byte[] vector(String name, int xcdr) {
        String key = "data " + name + " xcdr" + xcdr + " ";
        int at = vectors.indexOf(key);
        check(at >= 0, "vector " + key);
        int end = vectors.indexOf('\n', at);
        String hex = vectors.substring(at + key.length(), end < 0 ? vectors.length() : end).trim();
        byte[] out = new byte[hex.length() / 2];
        for (int i = 0; i < out.length; i++) out[i] = (byte) Integer.parseInt(hex.substring(2 * i, 2 * i + 2), 16);
        return out;
    }

    static <T> byte[] encode(T v, int xcdr, Ser<T> ser) {
        ByteBuffer buf = ByteBuffer.allocate(4096).order(ByteOrder.LITTLE_ENDIAN);
        ser.write(v, buf, 0, xcdr);
        return Arrays.copyOf(buf.array(), buf.position());
    }

    static <T> T decode(byte[] bytes, int len, int xcdr, De<T> de) {
        ByteBuffer buf = ByteBuffer.wrap(bytes, 0, len).order(ByteOrder.LITTLE_ENDIAN);
        T v = de.read(buf, 0, xcdr);
        if (buf.position() != len) throw new IllegalStateException("trailing bytes");
        return v;
    }

    static <T> void check(String name, T sample, int xcdr, boolean compareBytes, Ser<T> ser, De<T> de) {
        byte[] reference = vector(name, xcdr);
        byte[] ours = encode(sample, xcdr, ser);
        if (compareBytes) check(Arrays.equals(ours, reference), name + " xcdr" + xcdr + " encodes to the reference bytes");
        T got = decode(reference, reference.length, xcdr, de);
        check(Arrays.equals(encode(got, xcdr, ser), ours), name + " xcdr" + xcdr + " decodes the reference bytes");
        for (int cut = 0; cut < reference.length; cut++) {
            boolean failed;
            try {
                decode(reference, cut, xcdr, de);
                failed = false;
            } catch (RuntimeException e) {
                failed = true;
            }
            check(failed, name + " xcdr" + xcdr + " rejects a " + cut + "-byte prefix");
        }
        System.out.println("  " + name + " xcdr" + xcdr + " ok");
    }

    @SafeVarargs
    static <T> List<T> list(T... items) {
        return new ArrayList<>(Arrays.asList(items));
    }

    static Ka.KA.U u(int d) {
        Ka.KA.U u = new Ka.KA.U();
        if (d == 1) u.set_i(7);
        else u.set_s("u");
        return u;
    }

    static Ka.KA.Prims prims() {
        Ka.KA.Prims v = new Ka.KA.Prims();
        v.set_s_long(list(1, -2, 3));
        v.set_s_octet(list((byte) 1, (byte) 2, (byte) 3));
        v.set_s_bool(list(true, false));
        v.set_s_ll(list(1L, -1L));
        v.set_s_dbl(list(1.5));
        v.set_s_short(list((short) 7, (short) -8, (short) 9));
        v.set_a_long(new int[][] {{1, 2}, {3, 4}});
        return v;
    }

    static Ka.KA.NonPrims nonPrims() {
        Ka.KA.NonPrims v = new Ka.KA.NonPrims();
        v.set_s_str(list("a", "bc"));
        v.set_s_bstr(list("xy", "z"));
        v.set_s_enum(list(Ka.KA.Color.GREEN, Ka.KA.Color.BLUE));
        v.set_s_bm(list(Ka.KA.Flags.F0 | Ka.KA.Flags.F2, Ka.KA.Flags.F1));
        v.set_s_struct(list(new Ka.KA.Named("n1", 1), new Ka.KA.Named("n2", 2)));
        v.set_s_astruct(list(new Ka.KA.NamedA("x")));
        v.set_s_union(list(u(1), u(2)));
        v.set_t_seq(list("t"));
        return v;
    }

    static Ka.KA.Nested nested() {
        Ka.KA.Nested v = new Ka.KA.Nested();
        v.set_s_seq(list(list(1, 2), list(3)));
        v.set_s_tseq(list(list(4), new ArrayList<Integer>()));
        v.set_s_seq_str(list(list("a"), list("b", "c")));
        v.set_s_seq_struct(list(list(new Ka.KA.Named("q", 1))));
        v.set_s_arr(list(new int[] {1, 2, 3}, new int[] {4, 5, 6}));
        v.set_s_barr(list(new int[] {7, 8, 9}));
        return v;
    }

    @SuppressWarnings("unchecked")
    static Ka.KA.Arrays arrays() {
        Ka.KA.Arrays v = new Ka.KA.Arrays();
        v.set_a_str(new String[] {"p", "q"});
        v.set_a_enum(new Ka.KA.Color[] {Ka.KA.Color.BLUE, Ka.KA.Color.RED});
        v.set_a_struct(new Ka.KA.Named[] {new Ka.KA.Named("s1", 1), new Ka.KA.Named("s2", 2)});
        v.set_a_str2(new String[][] {{"w", "x"}, {"y", "z"}});
        v.set_a_tarr(new int[][] {{1, 2, 3}, {4, 5, 6}});
        List<Integer>[] seqs = new List[] {list(1), list(2, 3)};
        v.set_a_seq(seqs);
        return v;
    }

    static Ka.KA.App app() {
        Ka.KA.App v = new Ka.KA.App();
        v.set_np(nonPrims());
        v.set_extra(list(new Ka.KA.Named("e", 5)));
        return v;
    }

    static Ka.KA.Mut mut() {
        Ka.KA.Mut v = new Ka.KA.Mut();
        v.set_s_str(list("m"));
        v.set_s_long(list(1, 2));
        v.set_s_octet(list((byte) 9));
        v.set_s_ll(list(5L));
        v.set_s_short(list((short) 3));
        v.set_s_struct(list(new Ka.KA.Named("k", 4)));
        v.set_name("nm");
        v.set_a_long(new int[] {6, 7});
        v.set_a_struct(new Ka.KA.Named[] {new Ka.KA.Named("a", 1), new Ka.KA.Named("b", 2)});
        v.set_nest(nested());
        return v;
    }

    public static void main(String[] args) throws Exception {
        vectors = new String(Files.readAllBytes(Paths.get(args[0])), "UTF-8");
        for (int x = 1; x <= 2; x++) {
            check("Prims", prims(), x, true, (v, b, base, xcdr) -> v.serialize(b, base, xcdr), Ka.KA.Prims::deserializeFrom);
            check("NonPrims", nonPrims(), x, true, (v, b, base, xcdr) -> v.serialize(b, base, xcdr), Ka.KA.NonPrims::deserializeFrom);
            check("Nested", nested(), x, true, (v, b, base, xcdr) -> v.serialize(b, base, xcdr), Ka.KA.Nested::deserializeFrom);
            check("Arrays", arrays(), x, true, (v, b, base, xcdr) -> v.serialize(b, base, xcdr), Ka.KA.Arrays::deserializeFrom);
            check("App", app(), x, true, (v, b, base, xcdr) -> v.serialize(b, base, xcdr), Ka.KA.App::deserializeFrom);
        }
        check("Mut", mut(), 2, false, (v, b, base, xcdr) -> v.serialize(b, base, xcdr), Ka.KA.Mut::deserializeFrom);
        System.out.println("xcdr_known_answer Java: all checks passed");
    }
}
