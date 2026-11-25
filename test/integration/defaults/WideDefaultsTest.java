// Generated Java defaults (wide_defaults.idl): a wide string literal or a
// constant's text, a supplementary character as its surrogate pair, and a
// default naming a constant as the constant's value, not its holder class.
public class WideDefaultsTest {
    static void check(boolean cond, String msg) {
        if (!cond) throw new AssertionError("FAIL: " + msg);
    }

    public static void main(String[] args) {
        Wide_defaults.wd.WideDefaults d = new Wide_defaults.wd.WideDefaults();
        check("hi".equals(Wide_defaults.wd.GREETING.value), "the constant's text");
        check("hi".equals(d.get_named()), "a constant's default");
        check("lit".equals(d.get_literal()), "a literal default");
        check("hi".equals(d.get_bounded()), "a bounded member's default");
        check("\uD83D\uDE00".equals(d.get_emoji()), "a supplementary character");
        check(d.get_count() == 5, "a default naming a long constant");
        check(d.get_all_bits() == 0xFFFFFFFF, "an unsigned long default beyond int's range, its bits kept");
        System.out.println("java wide defaults: all checks passed");
    }
}
