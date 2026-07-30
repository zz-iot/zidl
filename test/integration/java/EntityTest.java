// Integration test for the Java JNI entity bridge (interface generation +
// entity boxing/unboxing) against test/integration/java/entity.idl, backed
// by the hand-written native implementation in entity_native.c.
//
// Compiled and run by `zig build integration-test`.

public class EntityTest {
    static { System.loadLibrary("entity_jni"); }

    static native long nGetFactory();

    static void check(boolean cond, String msg) {
        if (!cond) throw new AssertionError("FAIL: " + msg);
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

        System.out.println("All Java entity JNI integration tests passed.");
    }
}
