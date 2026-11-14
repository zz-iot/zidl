use std::{env, path::PathBuf};

fn main() {
    println!("cargo:rerun-if-env-changed=ZIDL_CDR_PREFIX");
    let prefix = PathBuf::from(env::var_os("ZIDL_CDR_PREFIX")
        .expect("set ZIDL_CDR_PREFIX to an installed native CDR archive"));
    assert!(prefix.is_absolute(), "ZIDL_CDR_PREFIX must be absolute");
    let target = env::var("TARGET").unwrap();
    let msvc = target.contains("windows-msvc");
    assert!(!target.contains("windows") || msvc, "Windows experiment requires MSVC");
    let archive = prefix.join("lib").join(if msvc { "zidl_cdr.lib" } else { "libzidl_cdr.a" });
    assert!(archive.is_file(), "native archive missing");
    println!("cargo:rerun-if-changed={}", archive.display());
    println!("cargo:rustc-link-search=native={}", prefix.join("lib").display());
    println!("cargo:rustc-link-lib=static=zidl_cdr");
    if msvc { println!("cargo:rustc-link-lib=ntdll"); }
    else { println!("cargo:rustc-link-lib=m"); }
}
