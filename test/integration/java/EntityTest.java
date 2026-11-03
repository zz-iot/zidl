// Integration test for the Java JNI entity bridge (interface generation +
// entity boxing/unboxing) against test/integration/java/entity.idl, backed
// by the hand-written native implementation in entity_native.c.
//
// Compiled and run by `zig build integration-test`.

public class EntityTest {
    static { System.loadLibrary("entity_jni"); }

    static native long nGetFactory();
    static native int nTurns();

    static void check(boolean cond, String msg) {
        if (!cond) throw new AssertionError("FAIL: " + msg);
    }

    // A freed gear's address comes back as a spring (entity_native.c). The
    // free is not reported, as from a provider without the retire hook, and
    // the gear's wrapper stays strongly reachable, so its identity-cache
    // entry is still live: boxing the spring must not hand back the gear.
    static void checkReusedAddress(Entity.Widgets.Factory factory) {
        Entity.Widgets.Gear gear = factory.create_gear(12);
        check(gear.get_teeth() == 12, "gear.get_teeth() returns the teeth passed to create_gear");
        check(factory.current_part() == gear, "a part returned as its base type is the same object as the gear");

        factory.forget_part(gear);
        Entity.Widgets.Spring spring = factory.create_spring(5);
        Object boxed = spring;
        check(boxed instanceof Entity.Widgets.Spring,
              "a spring at a deleted gear's address is a Spring, not the cached " + boxed.getClass().getName());
        check(spring.get_rate() == 5, "spring.get_rate() returns the rate passed to create_spring");
        check(factory.current_part() == spring, "a part returned as its base type is the same object as the spring");
        check(gear != null, "keep the gear's wrapper reachable until here");
    }

    // A reported free retires the wrapper: its methods return without
    // reaching the native side (@retired_result's value, or zero), and the
    // address gets a new wrapper.
    static void checkRetired(Entity.Widgets.Factory factory) {
        Entity.Widgets.Gear gear = factory.create_gear(30);
        int turns = nTurns();
        check(gear.turn() == 0 && nTurns() == turns + 1, "a live gear's turn() reaches the native side");

        factory.delete_part(gear);
        check(gear.turn() == 9, "a retired gear's turn() returns @retired_result's value");
        check(nTurns() == turns + 1, "a retired gear's turn() does not reach the native side");
        check(gear.get_teeth() == 0, "a retired gear's get_teeth() returns zero");

        Entity.Widgets.Gear again = factory.create_gear(31);
        check(again != gear, "the freed address gets a new wrapper");
        check(again.get_teeth() == 31, "the new wrapper reaches the new gear");
        check(factory.current_part() == again, "the new gear keeps its own identity");
    }

    public static void main(String[] args) {
        System.out.println("Java entity JNI integration test:");

        Entity.Widgets.Factory factory = new FactoryImpl(nGetFactory());

        Entity.Widgets.Widget w = factory.create_widget(42);
        check(w instanceof WidgetImpl, "create_widget returns a boxed WidgetImpl");
        check(w.get_value() == 42, "widget.get_value() round-trips the value passed to create_widget");

        Entity.Widgets.Widget w2 = factory.create_widget(7);
        check(w.get_value() == 42, "first widget unaffected by creating a second one");
        check(w2.get_value() == 7, "second widget holds its own value");

        int viaFactory = factory.get_widget_value(w);
        check(viaFactory == 42, "factory.get_widget_value(w) unboxes the widget back to its native handle");

        checkReusedAddress(factory);
        checkRetired(factory);

        System.out.println("All Java entity JNI integration tests passed.");
    }
}
