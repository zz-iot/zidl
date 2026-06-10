# zidl Annotations

zidl supports a subset of IDL4 annotations (OMG IDL 4.2) plus a small set of
zidl-specific extensions.

## Standard OMG IDL4 Annotations

| Annotation | Target | Effect |
|---|---|---|
| `@key` | struct member | Member participates in the DDS key. |
| `@optional` | struct member | Member may be absent; Zig type becomes `?T`. |
| `@id(N)` | struct member | Explicit XTYPES member ID. |
| `@topic` | struct | Declares a DDS topic type. |
| `@nested` | struct | Suppresses DataWriter/DataReader generation. |
| `@extensibility(.final \| .appendable \| .mutable)` | struct / union | Sets the XCDR extensibility kind. |
| `@final` | struct / union | Shorthand for `@extensibility(.final)`. |
| `@appendable` | struct / union | Shorthand for `@extensibility(.appendable)`. |
| `@mutable` | struct / union | Shorthand for `@extensibility(.mutable)`. |
| `@bit_bound(N)` | enum / bitmask | Sets the storage width in bits. |
| `@must_understand` | struct member | Receiver must drop the sample if it does not know this member. |

## zidl-Specific Annotations

### `@callback`

**Target:** `interface`

Marks the interface as "user-implemented callback struct" — the generator
produces a plain C callback struct instead of a fat-pointer vtable entity.

```idl
@callback
interface WriterListener {
    void on_change(in DataWriter source, in Status st);
};
```

**Zig output (`--generate-interfaces` or `--generate-c-api`):**
```zig
pub const WriterListener = extern struct {
    listener_data: ?*anyopaque = null,
    on_change: ?*const fn (DDS.DataWriter, *const DDS.Status, ?*anyopaque) callconv(.c) void = null,
};

pub const noop_WriterListener: WriterListener = .{};
```

Key properties:
- All function pointers are nullable and default to `null`.
- `listener_data` is threaded as the last argument to every callback.
- `noop_WriterListener` is a zero-initialized constant — safe to pass when
  no callbacks are needed.
- The struct is `extern`, so it has a stable C-ABI layout identical to the
  C backend's `DDS_WriterListener` output.

**Usage:** Implement a listener by constructing the struct inline:
```zig
const my_listener = DDS.WriterListener{
    .listener_data = &my_ctx,
    .on_change = myOnChange,
};
dp.create_writer(&default_qos, &my_listener, DDS.CHANGE_STATUS);
```

**Deprecated fallback:** If an interface's name ends in `"Listener"` and does
not carry `@callback`, the backends apply the callback treatment automatically.
This heuristic exists for backwards compatibility with IDL files that predate
the `@callback` annotation.  Annotate your IDL files explicitly to suppress
the deprecation warning when it is added.

### `@pl_repeated`

**Target:** `sequence<T>` struct member inside a `@mutable` struct.

Internal annotation used by the RTPS discovery layer.  Emits one PID entry per
sequence element instead of a single length-prefixed sequence in the PL_CDR
encoding.  Not intended for user IDL.
