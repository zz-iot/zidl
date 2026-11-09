# zidl-rt

Temporary umbrella for the zzdds migration. New generated code imports
`zidl_cdr` and `zidl_bindings` directly; zidl's own consumers use those modules.
Codec and binding exports here alias the same canonical types and state.
Run `zig build test` for the alias and registry checks.

Migrate zzdds to the new imports next, then remove this package as soon as both
repositories pass validation. No extended deprecation period is planned.

See [package placement](../../docs/design/native-cdr-package-slice.md).
