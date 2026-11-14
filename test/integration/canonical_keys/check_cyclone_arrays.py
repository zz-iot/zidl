"""Optional independent serializer check. No networking, participant or pcap.

Uses Cyclone's explicitly KEYHASH-mode XCDR2 BE extractor on native key-only
samples (all fields are keys in these FINAL fixtures). Build artefacts go into a temporary directory.
"""
import argparse
import pathlib
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--cyclone", type=pathlib.Path, required=True)
args = parser.parse_args()
cyclone = args.cyclone.resolve()
here = pathlib.Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="zidl-array-oracle-") as temp:
    tmp = pathlib.Path(temp)
    subprocess.run([str(cyclone / "build/bin/idlc"), "-x", "final", "-o", temp,
                    str(here / "array_keys.idl")], check=True)
    includes = ["src/core/ddsc/include", "src/core/ddsi/include", "src/core/cdr/include",
                "src/ddsrt/include", "src/ddsrt/include/posix", "build/src/ddsrt/include",
                "build/src/core/include"]
    cmd = ["cc", "-std=c99", "-Wall", "-Wextra", "-Werror", "-I" + temp, "-I" + str(here)]
    cmd += ["-I" + str(cyclone / path) for path in includes]
    lib = str(cyclone / "build/lib")
    cmd += [str(here / "cyclone_array_oracle.c"), str(tmp / "array_keys.c"),
            "-L" + lib, "-Wl,-rpath," + lib, "-lddsc", "-o", str(tmp / "oracle")]
    subprocess.run(cmd, check=True)
    expected = {}
    for line in (here / "array_vectors.txt").read_text().splitlines():
        name, data, digest, force = line.split()
        expected[name] = (data, force)
    actual = {}
    for line in subprocess.check_output([str(tmp / "oracle")], text=True).splitlines():
        name, data, force = line.split()
        actual[name] = (data, force)
    if actual != expected:
        raise SystemExit(f"Cyclone differs:\nexpected={expected}\nactual={actual}")
    print(f"Cyclone key-hash bytes and maximum-size policy agree for {len(actual)} collection witnesses.")
