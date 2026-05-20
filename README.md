# zidl — An OMG IDL Parser and Code Generator

A spec-compliant OMG IDL 4.2 parser and code generator written in Zig.
zidl generates language bindings and type support (CDR serialization, TypeObject/TypeIdentifier)
for all supported targets.

## Goals

- Parse IDL 4.2 per OMG formal/18-01-05
- Generate correct output for (in priority order):
  - Zig — type definitions + CDR serialization + TypeObject/TypeIdentifier (primary target, implemented)
  - C — type definitions + serialization (embedded FFI and standalone use, implemented)
  - C++11 — type definitions + serialization (formal/25-03-03 v1.0, IDL4-native, implemented)
  - Java — type definitions + serialization (formal/21-08-01 v1.0, desktop/server only, implemented)
  - Python 3.10+ — planned
  - C# / .NET — planned
  - Rust — planned
- Generate DCPS abstract API from IDL for bootstrapping a Zig DDS runtime (`--generate-interfaces`)
- Extensible backend interface so new mappings can be added cleanly
- Hand-written recursive descent parser (no parser generator, no combinator library)
- Ship companion runtime packages (`zidl-rt`, `zidl-xtypes`, `zidl-cdr`)

## Build

Requires Zig 0.16.0.

```sh
zig build                         # build the zidl binary (output: zig-out/bin/zidl)
zig build -Doptimize=ReleaseFast  # optimised release build
```

## CLI Reference

| Option | Purpose |
|---|---|
| `<file> [<file>...]` | Input IDL file(s) |
| `-o <dir>` | Output directory |
| `-b <backend>` | Target language (`c`, `cpp`, `java`, `zig`) |
| `-I <dir>` | Preprocessor include path (repeatable) |
| `-D <MACRO>[=value]` | Define preprocessor macro (repeatable) |
| `-E` | Preprocess only; emit expanded IDL |
| `--default-extensibility <final\|appendable\|mutable>` | Default extensibility (spec default: `final`) |
| `--no-typesupport` | Suppress CDR serialization output |
| `--no-typeobject-support` | Suppress TypeObject/TypeIdentifier output (all backends) |
| `--generate-interfaces` | Emit DDS API binding layer for IDL `interface` declarations |
| `--split-files` | One file per type instead of single output file |
| `--single-file` | Single monolithic output file (default) |
| `--type-prefix <pfx>` | Prefix prepended to all generated type names (all backends) |
| `--profile <full\|xrce>` | `full` (default) or `xrce` (XCDR1+@final+bounded only) |
| `--c-header-guard-prefix <pfx>` | Include guard prefix (C, C++ backends) |
| `--c-export-macro <macro>` | DLL export macro for function declarations (C, C++ backends) |
| `--c-pragma-once` | `#pragma once` instead of `#ifndef` guards (C, C++ backends) |
| `--c-extern-c` | Wrap header in `extern "C" {}` (C backend) |
| `--cpp-namespace <ns>` | Wrap all output in an outer namespace (C++ backend) |
| `--java-package <pkg>` | Java package prefix (Java backend) |
| `--java-jni-library <name>` | `System.loadLibrary()` name for JNI bridge (Java backend) |
| `--zig-pl-cdr` | Generate PL_CDR functions for `@mutable` types (Zig backend) |
| `--zig-version <0.16.0\|0.15.1>` | Output compatibility target (Zig backend) |
| `--version` / `--help` | Standard |

## Documentation

Full documentation, specification references, and a complete document index are in
[`docs/overview.md`](docs/overview.md).

Quick links:
- [Zig backend](docs/backend_zig.md) · [C backend](docs/backend_c.md) · [C++ backend](docs/backend_cpp.md) · [Java backend](docs/backend_java.md)
- [Testing guide](docs/testing.md) · [Feature inventory](docs/features.md)
- [Architecture](docs/architecture.md) · [DDS ecosystem](docs/ecosystem.md)
