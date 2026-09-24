#!/usr/bin/env bash
set -euo pipefail
# Run from the zidl root. All outputs are isolated in a temporary directory.
: "${ZIDL_EXE:?Set ZIDL_EXE to the built experimental generator}"
: "${ZIG_EXE:?Set ZIG_EXE to Zig 0.16.0}"
probe_dir=$(mktemp -d /tmp/zidl-managed-generated.XXXXXX)
fixture=test/integration/managed_reference_experiment
"$ZIDL_EXE" -b c --generate-interfaces --no-typesupport --no-typeobject-support -o "$probe_dir/c" "$fixture/fixture.idl"
"$ZIDL_EXE" -b zig --generate-interfaces --no-typesupport --no-typeobject-support -o "$probe_dir/zig" "$fixture/fixture.idl"
cat > "$probe_dir/zig/root.zig" <<'ZIG'
comptime { const p = @import("fixture.zig").Probe; _ = &p.Probe_Value_ref_assign; _ = &p.Probe_Value_ref_clear; _ = &p.Probe_Value_get_value; _ = &p.Probe_Value_replace; _ = &p.Probe_Config_init; _ = &p.Probe_Config_fini; _ = &p.Probe_Config_clone; _ = &p.Probe_Config_set_group; _ = &p.Probe_Config_set_other; }
ZIG
"$ZIG_EXE" build-obj "$probe_dir/zig/root.zig" -O Debug -fPIC -femit-bin="$probe_dir/fixture.o" --cache-dir "$probe_dir/cache" --global-cache-dir /tmp/zidl-probe-global
cc -std=c11 -Wall -Wextra -Werror -I "$probe_dir/c" "$fixture/test.c" "$probe_dir/fixture.o" -o "$probe_dir/test" -lpthread -ldl -lm
"$probe_dir/test"
# Managed-language backends must not silently emit legacy lifetime semantics.
if "$ZIDL_EXE" -b cpp --generate-interfaces --no-typesupport -o "$probe_dir/cpp" "$fixture/fixture.idl" >"$probe_dir/rejected.log" 2>&1; then
    echo 'FAIL: unsupported C++ experiment accepted' >&2
    exit 1
fi
grep -q UnsupportedManagedReferenceExperiment "$probe_dir/rejected.log"
echo "PASS unsupported backend rejection; artifacts: $probe_dir"
# Mixed scalar/reference Configs and TOML are deliberately outside this experiment.
sed 's/Value other;/unsigned long other;/' "$fixture/fixture.idl" > "$probe_dir/invalid.idl"
for backend in c zig; do
    if "$ZIDL_EXE" -b "$backend" --generate-interfaces --no-typesupport -o "$probe_dir/invalid-$backend" "$probe_dir/invalid.idl" >"$probe_dir/invalid-$backend.log" 2>&1; then
        echo 'FAIL: unsupported Config shape accepted' >&2
        exit 1
    fi
    grep -q UnsupportedManagedReferenceExperiment "$probe_dir/invalid-$backend.log"
done
if "$ZIDL_EXE" -b zig --generate-interfaces --no-typesupport --zig-generate-toml-config -o "$probe_dir/toml" "$fixture/fixture.idl" >"$probe_dir/toml.log" 2>&1; then
    echo 'FAIL: unsupported TOML mode accepted' >&2
    exit 1
fi
grep -q UnsupportedManagedReferenceExperiment "$probe_dir/toml.log"
echo 'PASS Config shape and TOML rejection'
