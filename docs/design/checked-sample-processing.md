# Checked native sample processing

Generated C/C++ structs now expose `<Type>_process_sample_from_cdr(payload, len,
key_only, hash)`. The helper decodes the complete ordinary value for ALIVE data,
or the genuine key projection for lifecycle data, before computing and publishing
the hash. Keyless ALIVE values are decoded too; they do not use the old constant
zero-hash shortcut. Output remains untouched on malformed input or allocation
failure. C++ catches bad_alloc/length_error around construction and processing;
STL/PMR and the existing exception-disabled allocation policy are unchanged.

This uses ordinary codec admission and evolution defaults. It deliberately does
not impose the all-required-member policy of Zig's `deserializeValidated`, and it
is not a new exhaustive validator for every IDL constraint. Unknown extension
fields inside valid delimited bodies retain their normal treatment. Extra bytes
outside the decoded value reject, except for up to three zero octets aligning an
RTPS payload to a four-byte boundary. Genuine key-only input is explicitly
selected by the integer flag (0 or 1); it is not detected heuristically.

C temporaries are zero-initialized and freed on every outcome. Owning helpers are
omitted under `--c-no-free`, because generated cleanup is unavailable in that
mode; existing application-provided free conventions do not imply a checked
processing guarantee. C++ temporaries use RAII. Hash publication happens last.

The helper has no middleware dependency. With a matching zzdds checked API:

```c
zzdds_register_type_support_checked(
    participant, "Module::Topic", Module_Topic_process_sample_from_cdr,
    Module_Topic_has_key, NULL);
```

Install before creating topics. This is an explicit opt-in: existing generated
registration helpers and legacy hash callbacks keep their existing contracts.
The middleware checks callback status before protocol/history admission, even
when inline QoS supplied a hash. Its ctx variant supports bindings which supply
one shared native trampoline; Java/Zig registration glue is not silently migrated.

`test-checked-sample-processing` covers C, STL and PMR, ordinary/key-only and
keyless values, both representations/byte orders, canonical nonzero/zero hashes,
truncation and padding, evolution defaults, every allocation failpoint and both
C++ allocation exception classes. A long default string exercises construction
before decoding. Adjacent middleware integration tests compile an actual generated
C helper and reject malformed keyed/keyless samples on a real DataReader.
