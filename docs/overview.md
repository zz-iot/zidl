# zidl — Overview and Documentation Index

zidl is a fully-featured, spec-compliant OMG IDL 4.2 parser and multi-language code generator
written in Zig. It generates type definitions, CDR serialization code, and TypeObject/TypeIdentifier
streams from IDL source files. It also generates the DCPS abstract API binding layer used to
bootstrap a DDS runtime (`--generate-interfaces`).

---

## What zidl Generates

For each IDL source file, zidl produces language-specific output depending on the selected backend.
All backends generate:
- Type definitions (structs, enums, unions, constants, typedefs)
- CDR serialize/deserialize functions
- `serializeKey`, `deserializeKey`, and `computeKeyHash` for types with `@key` members

| Backend | Flag | Output | Runtime dependency |
|---|---|---|---|
| Zig | `-b zig` | `.zig` source | `zidl-rt` (included in this repo) |
| C | `-b c` | `.h` + `.c` | `zidl-cdr` (included in this repo) |
| C++11 | `-b cpp` | `.hpp` (header-only) | `zidl-cdr` (included in this repo) |
| Java | `-b java` | `.java` | none (CDR inlined) |
| Python *(planned)* | `-b python` | `.py` | none (CDR inlined) |
| C# *(planned)* | `-b csharp` | `.cs` | none (CDR inlined) |
| Rust *(planned)* | `-b rust` | `.rs` | `zidl-rs` (future crate) |

See the per-backend reference documents for type mapping tables, generated function signatures,
and backend-specific options and limitations.

---

## How zidl Fits Into a DDS Stack

zidl is the code-generation component of a forthcoming Zig-native DDS implementation. It is not
itself a DDS runtime. See [`ecosystem.md`](ecosystem.md) for a full description of how zidl fits
into a DDS stack, the full-DDS vs XRCE profile distinction, and how the `--generate-interfaces`
option generates the abstract DCPS API layer.

---

## Documentation Index

### User guides
| Document | Contents |
|---|---|
| [`backend_zig.md`](backend_zig.md) | Zig type mapping, generated file structure, TypeObject output, serialization API |
| [`backend_c.md`](backend_c.md) | C type mapping, `.h`/`.c` structure, `zidl-cdr` usage, known limitations |
| [`backend_cpp.md`](backend_cpp.md) | C++11 type mapping, `.hpp` structure, `zidl-cdr` usage, known limitations |
| [`backend_java.md`](backend_java.md) | Java type mapping, `.java` structure, inline CDR, options |
| [`runtime_libraries.md`](runtime_libraries.md) | `zidl-rt`, `zidl-cdr`, `zidl-xtypes` API reference; CDR runtime strategy per language |
| [`features.md`](features.md) | Completed feature inventory per backend; test coverage summary |
| [`testing.md`](testing.md) | Running tests; golden files; Cyclone DDS interop harness |
| [`ecosystem.md`](ecosystem.md) | zidl's role in a DDS stack; Full DDS vs XRCE; `--generate-interfaces`; TypeObject/type discovery |

### Reference material
| Document | Contents |
|---|---|
| [`idl4_annotations.md`](idl4_annotations.md) | All 24 built-in IDL 4.2 annotations; pre-interpreted vs raw handling in zidl |
| [`xcdr_encoding.md`](xcdr_encoding.md) | XCDR1/XCDR2 wire encoding rules; DHEADER/EMHEADER; alignment |
| [`xtypes_typeobject.md`](xtypes_typeobject.md) | TypeIdentifier/TypeObject discriminants, stream layouts, EquivalenceHash algorithm |
| [`idl4_grammar.md`](idl4_grammar.md) | Complete IDL 4.2 Annex A grammar (all 227 rules); zidl parser coverage notes |
| [`dcps_idl.md`](dcps_idl.md) | Normative DCPS IDL (DDS v1.4 §2.3.3); reference for `--generate-interfaces` |

### Contributor references
| Document | Contents |
|---|---|
| [`architecture.md`](architecture.md) | Internal pipeline (preprocessor → lexer → parser → IR → backend); design decisions |
| [`backend_interface.md`](backend_interface.md) | Backend vtable contract; how to add a new backend; annotation handling |
| [`implementation_status.md`](implementation_status.md) | Per-source-file design notes, test counts, key invariants, known limitations |
| [`roadmap.md`](roadmap.md) | Planned backends and future work |

---

## Specification References

### Primary
- [OMG IDL 4.2 (formal/18-01-05)](https://www.omg.org/spec/IDL/4.2/) — primary reference
  - Grammar: Annex A (pages 123–132); lexical rules: §7.2
  - Preprocessing: §7.3; annotation placement: §8.2; default extensibility: §8.3.1
  - `::+` in the grammar denotes rule extension (adds alternatives, not a new rule)
  - Building blocks: Core Data Types, Extended Data-Types, Anonymous Types, Annotations,
    Interfaces–Basic/Full, Value Types, Components, Template Modules, CCM, CORBA-Specific

### Language Mappings — IDL4-Native
- [IDL4 to C++ v1.0 (formal/25-03-03)](https://www.omg.org/spec/IDL4-CPP/1.0/) (March 2025)
- [IDL4 to Java v1.0 (formal/21-08-01)](https://www.omg.org/spec/IDL4-JAVA/1.0/) (April 2022)
- [IDL4 to C# v1.0 Beta (ptc/20-03-02)](https://www.omg.org/spec/IDL4-CSHARP/1.0/)

### Language Mappings — Legacy/CORBA-Era
- [C Language Mapping (formal/99-07-35)](https://www.omg.org/spec/C/1.0/) (June 1999)
- [IDL to C++11 v1.7 (formal/24-07-01)](https://www.omg.org/spec/CPP11/1.7/)
- [IDL to Java v1.3 (formal/08-01-11)](https://www.omg.org/spec/I2JAV/1.3/)

### DDS Specs
- [DDS v1.4: DCPS API (formal/15-04-10)](https://www.omg.org/spec/DDS/1.4/) — primary reference for `--generate-interfaces`
- [DDS-XTYPES v1.3 (formal/20-02-04)](https://www.omg.org/spec/DDS-XTypes/1.3/) — TypeObject/TypeIdentifier/TypeMapping
- [RTPS 2.5](https://www.omg.org/spec/DDSI-RTPS/2.5/) — CDR encoding, key hash, participant discovery
- [DDS-XRCE v1.0 (formal/20-02-01)](https://www.omg.org/spec/DDS-XRCE/1.0/) — primary reference for `--profile xrce`
- [DDS-RPC v1.0 (formal/17-04-01)](https://www.omg.org/spec/DDS-RPC/1.0/) (deferred; architecture must not preclude it)
- [DDS Security v1.2 (formal/25-03-06)](https://www.omg.org/spec/DDS-SECURITY/1.2/) (2025)
