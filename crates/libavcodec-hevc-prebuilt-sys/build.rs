// Find the prebuilt libavcodec + libavutil for this target and emit the link flags. What this
// build script does *not* do is the point of the crate: no FFmpeg configure, no nasm, no C
// compiler, no vendored source tree, no `cc`, and no libclang.
//
// Three places the archives can come from, tried in this order:
//
//   1. `LIBAVCODEC_HEVC_PREBUILT_DIR` — a prefix you built or unpacked yourself. Used as-is.
//   2. `prebuilt/<target>/` next to this file — what `./build.sh` + `./sync-prebuilt.sh` leave
//      behind, and gitignored.
//   3. the repository's **latest** GitHub release, downloaded into
//      `$CARGO_HOME/libavcodec-hevc-prebuilt/<release tag>/` — one directory per release, so a
//      build links the archives of the release current when it runs rather than whichever one
//      this machine happened to download first.
//
// Two things get hashed on the way in, and neither hash is committed to this repository:
//
//   - the downloaded `.tar.gz`, against the `SHA256SUMS` asset the release job publishes beside
//     the archives;
//   - each extracted library, against the `sha256(avcodec)` and `sha256(avutil)` lines of the
//     MANIFEST inside the archive — on every resolution path, not just the download.
//
// Both are **corruption** checks, not tamper checks: each list travels with the files it covers.
// They earn their place because corruption is what actually happens — a truncated download, a
// cache half-written by a killed build — and each otherwise surfaces as a page of undefined
// symbols rather than one sentence naming the file. The pin that constrains somebody other than
// us is ffmpeg.env's commit, which build.sh asserts before compiling anything.
use std::path::{Path, PathBuf};
use std::process::Command;

const OVERRIDE: &str = "LIBAVCODEC_HEVC_PREBUILT_DIR";

fn main() {
    println!("cargo:rerun-if-env-changed={OVERRIDE}");

    // Before anything is hashed for real — see the note on the function.
    check_sha256_implementation();

    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let target = std::env::var("TARGET").unwrap();
    let version = ffmpeg_env(&manifest, "FFMPEG_VERSION");
    println!("cargo:rustc-env=FFMPEG_PREBUILT_VERSION={version}");

    let (prefix, provenance) = resolve(&manifest, &target, &version);
    let lib_dir = prefix.join("lib");
    let text = read_manifest(&prefix, &provenance);

    // libavcodec first: it references libavutil, and a single-pass linker resolves left to right.
    for name in ["avcodec", "avutil"] {
        // MSVC's convention for a static archive, and the name rustc looks for on that target:
        // `static=avcodec` resolves to `avcodec.lib` there and to `libavcodec.a` everywhere else.
        let file = if target.contains("windows-msvc") {
            format!("{name}.lib")
        } else {
            format!("lib{name}.a")
        };
        let path = lib_dir.join(&file);
        assert!(
            path.exists(),
            "no {file} in {} (from {provenance})\n\n{OVERRIDE} must name a prefix *containing* \
             lib/, not the lib/ directory itself.",
            lib_dir.display(),
        );
        verify_library(text.as_deref(), name, &path, &provenance);
        println!("cargo:rerun-if-changed={}", path.display());
    }

    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=static=avcodec");
    println!("cargo:rustc-link-lib=static=avutil");
    link_system_libs(&target, text.as_deref(), &provenance);

    // For a consumer compiling its own C against the same headers, via the
    // `DEP_AVCODEC_INCLUDE` that `links = "avcodec"` exposes.
    println!("cargo:include={}", manifest.join("include").display());
    // And the local cache, whichever path won: `resolve` prefers `prebuilt/<target>/` over a
    // download, so a `./sync-prebuilt.sh` run after a build that linked a cached release has to
    // make this script run again. `prebuilt/.gitkeep` is committed because a path that does not
    // exist reruns the script on every build.
    println!("cargo:rerun-if-changed={}", manifest.join("prebuilt").display());

    // `cargo:info`, not `cargo:warning`: this is the normal case. Visible under `cargo build -vv`.
    println!("cargo:info=FFmpeg {version} libavcodec (HEVC) linked statically from {provenance} ({target})");
    if let Some(text) = &text {
        for line in text.lines().filter(|l| {
            l.starts_with("cpu_floor") || l.starts_with("simd_evidence") || l.starts_with("license")
        }) {
            println!("cargo:info=libavcodec {line}");
        }
    }
    if provenance == OVERRIDE {
        println!("cargo:warning=libavcodec from {OVERRIDE} ({}) — unverified", prefix.display());
    }
}

/// One line of the MANIFEST, by key.
fn manifest_line<'a>(text: Option<&'a str>, key: &str) -> Option<&'a str> {
    let prefix = format!("{key} ");
    text.and_then(|text| text.lines().find_map(|line| line.strip_prefix(prefix.as_str())))
}

/// The MANIFEST beside the archives. Only a prefix from outside this repository may lack one,
/// and main() already warns that nothing about that one has been checked.
fn read_manifest(prefix: &Path, provenance: &str) -> Option<String> {
    match std::fs::read_to_string(prefix.join("MANIFEST")) {
        Ok(text) => Some(text),
        Err(_) if provenance == OVERRIDE => None,
        Err(e) => panic!(
            "no readable MANIFEST in {} (from {provenance}): {e}\n\nEvery archive this \
             repository publishes carries one.",
            prefix.display(),
        ),
    }
}

/// Emit a link flag for each system library the archives need.
///
/// `build.sh` measures this — from the archives' undefined symbols on Linux (libm, pthreads),
/// from FFmpeg's own tested `EXTRALIBS` on MSVC, where an undefined `__imp_` symbol does not say
/// which `.lib` holds it — and writes the answer as `system_libs`. On Apple targets it is `none`:
/// libm and pthreads are libSystem, which every binary links.
///
/// An archive with no MANIFEST gets the conservative answer for its platform, because a spare
/// `-lm` is a no-op while a missing one is a link failure.
fn link_system_libs(target: &str, text: Option<&str>, provenance: &str) {
    let libs: Vec<&str> = match manifest_line(text, "system_libs") {
        Some("none") => Vec::new(),
        Some(list) => list.split_whitespace().collect(),
        None => {
            println!(
                "cargo:warning=no system_libs line in the MANIFEST (from {provenance}) — linking \
                 the platform's usual set to be safe"
            );
            if target.contains("linux") {
                vec!["m", "pthread"]
            } else if target.contains("windows") {
                vec!["bcrypt"]
            } else {
                Vec::new()
            }
        }
    };
    for lib in libs {
        println!("cargo:rustc-link-lib=dylib={lib}");
    }
}

/// Hash one archive on disk and require it to be what the MANIFEST says was built.
///
/// Runs on every resolution path, not just the download: the cache is the copy most likely to be
/// wrong, because it survives across builds and nothing else ever looks at it again.
fn verify_library(text: Option<&str>, name: &str, library: &Path, provenance: &str) {
    let Some(text) = text else { return };
    let key = format!("sha256({name})");
    let expected = manifest_line(Some(text), &key)
        .unwrap_or_else(|| panic!("no {key} line in the MANIFEST beside {}", library.display()))
        .trim();

    let bytes =
        std::fs::read(library).unwrap_or_else(|e| panic!("cannot read {}: {e}", library.display()));
    let actual = sha256_hex(&bytes);
    if actual != expected {
        panic!(
            "\n\n{} does not match the MANIFEST beside it (from {provenance}).\n\
             \x20 MANIFEST says {expected}\n\
             \x20 the file is  {actual}\n\n\
             The archive is corrupt or was modified after it was built. Delete the directory \
             above and build again.\n",
            library.display(),
        );
    }
    println!("cargo:info=lib{name} sha256 {actual} matches the MANIFEST");
}

fn resolve(manifest: &Path, target: &str, version: &str) -> (PathBuf, String) {
    if let Some(dir) = std::env::var_os(OVERRIDE) {
        return (PathBuf::from(dir), OVERRIDE.into());
    }

    let name = prebuilt_dir(target);
    let local = manifest.join("prebuilt").join(name);
    if local.join("lib").is_dir() {
        return (local, format!("prebuilt/{name}"));
    }

    // `latest` is a moving pointer, so the cache is keyed by what it currently points at rather
    // than by the FFmpeg version: two releases of the same FFmpeg can carry different archives,
    // and a cache named after the version alone would answer for every one of them forever.
    let repo = ffmpeg_env(manifest, "PREBUILT_REPO");
    let Some(tag) = latest_release_tag(&repo) else {
        return offline_cache(name, version);
    };
    // The asset name carries the version, so a release of a different FFmpeg would otherwise
    // surface as a 404 on a URL nobody typed.
    if !tag.starts_with(&format!("v{version}-")) {
        println!(
            "cargo:warning=the latest release of {repo} is {tag}, which is not FFmpeg \
             {version} — the version this crate builds against. Falling back to the newest \
             cached FFmpeg {version} archive; depend on a tag of this repository whose release \
             is the current one, or set {OVERRIDE} to a prefix you built yourself."
        );
        return offline_cache(name, version);
    }

    let cached = cache_root().join(&tag).join(name);
    if cached.join("lib").is_dir() {
        return (cached, format!("cache/{tag}/{name}"));
    }

    (fetch(&repo, name, version, &tag, &cached), format!("{tag} asset for {name}"))
}

/// The repo's target names are not Rust triples — they name *artifacts*, one each.
fn prebuilt_dir(target: &str) -> &'static str {
    // **No musl.** FFmpeg is C, so the C++ argument libde265-prebuilt makes does not apply — but
    // the Linux archives are compiled against glibc's headers, and they reference names only
    // glibc provides: `__isoc99_sscanf`, `__xpg_strerror_r`, and the LFS64 aliases (`open64`,
    // `fstat64`, `mmap64`) that musl 1.2.4 stopped exporting. Measured on the linux-x86_64
    // archive, not assumed.
    match target {
        "aarch64-apple-darwin" => "macos-arm64",
        "x86_64-unknown-linux-gnu" => "linux-x86_64",
        "aarch64-unknown-linux-gnu" => "linux-aarch64",
        // Built with MSVC against the dynamic CRT, which is what Rust's MSVC target links.
        "x86_64-pc-windows-msvc" => "windows-x86_64-msvc",
        "x86_64-unknown-linux-musl" | "aarch64-unknown-linux-musl" => panic!(
            "no prebuilt libavcodec for {target}: the Linux archives are compiled against glibc \
             and reference glibc-only symbols (__isoc99_sscanf, open64, …). Set {OVERRIDE} to a \
             prefix holding libavcodec.a and libavutil.a you built against musl."
        ),
        "x86_64-apple-darwin" => panic!(
            "no prebuilt libavcodec for Intel macOS: the macOS artifact is arm64. Set {OVERRIDE} \
             to a prefix holding your own libavcodec.a and libavutil.a, or add the target to \
             build.sh."
        ),
        "x86_64-pc-windows-gnu" => panic!(
            "no prebuilt libavcodec for the MinGW target: the Windows archives are MSVC \
             `avcodec.lib`/`avutil.lib` against the dynamic CRT, which a GNU-ABI link cannot use. \
             Build with x86_64-pc-windows-msvc, or set {OVERRIDE} to your own prefix."
        ),
        other => panic!(
            "no prebuilt libavcodec for {other}. Supported: aarch64-apple-darwin, \
             x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu, x86_64-pc-windows-msvc. Set \
             {OVERRIDE} to a prefix holding your own libavcodec.a and libavutil.a for anything \
             else."
        ),
    }
}

/// Read one setting out of `ffmpeg.env`, which is where the shell build keeps the same values —
/// parsed rather than duplicated, so the two halves of this repository cannot disagree about
/// which FFmpeg this is or where its archives live.
fn ffmpeg_env(manifest: &Path, key: &str) -> String {
    let env_file = manifest.join("../../ffmpeg.env");
    println!("cargo:rerun-if-changed={}", env_file.display());
    let text = std::fs::read_to_string(&env_file).unwrap_or_else(|e| {
        panic!("cannot read {}: {e} — is this crate outside its repository?", env_file.display())
    });
    let prefix = format!("{key}=");
    text.lines()
        .find_map(|line| line.strip_prefix(&prefix))
        .unwrap_or_else(|| panic!("no {key} in ffmpeg.env"))
        .trim()
        .to_string()
}

/// SHA-256 (FIPS 180-4), by hand.
///
/// The alternatives are a crate — which every consumer would then compile, in a `-sys` crate
/// whose entire selling point is that it builds nothing — or shelling out to a different tool
/// per platform (`shasum`, `sha256sum`, `certutil`), none of which is guaranteed to exist
/// wherever cargo does. Fifty lines with a test vector beats both.
fn sha256_hex(bytes: &[u8]) -> String {
    #[rustfmt::skip]
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];

    // Pad to a multiple of 64 bytes: a 1 bit, zeros, then the length in bits, big-endian.
    let mut msg = Vec::with_capacity(bytes.len() + 72);
    msg.extend_from_slice(bytes);
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&(bytes.len() as u64 * 8).to_be_bytes());

    for block in msg.chunks_exact(64) {
        let mut w = [0u32; 64];
        for (word, src) in w.iter_mut().zip(block.chunks_exact(4)) {
            *word = u32::from_be_bytes([src[0], src[1], src[2], src[3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }

        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh] = h;
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ (!e & g);
            let t1 = hh.wrapping_add(s1).wrapping_add(ch).wrapping_add(K[i]).wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        for (slot, add) in h.iter_mut().zip([a, b, c, d, e, f, g, hh]) {
            *slot = slot.wrapping_add(add);
        }
    }

    h.iter().map(|word| format!("{word:08x}")).collect()
}

/// Which release `latest` is, right now.
///
/// `https://github.com/<repo>/releases/latest` redirects to `…/releases/tag/<tag>`, so the answer
/// is the Location header and nothing else is transferred: a HEAD, no body, and none of
/// `api.github.com`'s sixty-requests-an-hour ceiling for the unauthenticated. The alternative is
/// asking the API and parsing JSON, in a build script whose whole selling point is that it
/// compiles no dependencies.
///
/// `None` means **cannot ask**, never *no release*: cargo was told it is offline, or curl could
/// not reach GitHub, or the redirect was not one of these. The caller then falls back to the
/// newest release this machine already has, and the provenance line says that is what happened.
fn latest_release_tag(repo: &str) -> Option<String> {
    if std::env::var("CARGO_NET_OFFLINE").as_deref() == Ok("true") {
        println!("cargo:info=cargo is offline — using the newest cached release of libavcodec");
        return None;
    }

    let url = format!("https://github.com/{repo}/releases/latest");
    let out = Command::new("curl")
        .args(["-sS", "--fail", "--head", "--max-time", "30", "--retry", "2", &url])
        .output()
        .unwrap_or_else(|e| panic!("cannot run curl: {e}"));

    // A warning rather than a panic: a network that did not answer must not fail a build that
    // has a usable archive, and a warning rather than nothing because the archive it falls back
    // to may be older than what is published — which is the whole failure this keying exists to
    // end, and it should never happen quietly.
    let stale = |why: String| {
        println!(
            "cargo:warning=cannot ask {repo} which release is latest ({why}) — falling back to \
             the newest cached libavcodec archive, which may be out of date"
        );
        None
    };
    if !out.status.success() {
        return stale(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    // Read the header instead of asking curl's `--write-out` for `redirect_url`: the curl 8.8.0
    // shipped in Windows Server returns CURLE_BAD_FUNCTION_ARGUMENT (43) for every `-w`, even
    // though this same HEAD succeeds. A reverse search also selects the final response if a
    // proxy prepends its own header block.
    let headers = String::from_utf8_lossy(&out.stdout);
    let Some(location) = headers.lines().rev().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        name.eq_ignore_ascii_case("location").then_some(value.trim())
    }) else {
        return stale(format!("{url} returned no Location header"));
    };
    let Some((_, tag)) = location.rsplit_once("/releases/tag/") else {
        return stale(format!("{url} redirected to '{location}'"));
    };
    // The tag becomes a directory name below, so it may not be one that names somewhere else.
    if tag.is_empty() || tag.starts_with('.') || tag.contains(['/', '\\']) {
        return stale(format!("'{tag}' is not a usable directory name"));
    }
    Some(tag.to_string())
}

/// The newest cached release of this version, for a machine that cannot ask which one is current —
/// or whose answer is a release of a different FFmpeg, which has no archive for this version.
///
/// A tag's stamp is a fixed-width UTC timestamp (`v{version}-YYYYMMDDHHMMSS-<short sha>`), so
/// within one version the tags sort lexicographically in the order the releases happened and the
/// maximum is the newest archive set this machine holds. It can still be behind what the
/// repository has published — that is the unavoidable cost of not being able to look, and it is
/// why the provenance says so rather than reading like a fresh download.
fn offline_cache(name: &str, version: &str) -> (PathBuf, String) {
    let root = cache_root();
    let prefix = format!("v{version}-");
    let newest = std::fs::read_dir(&root)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let tag = entry.file_name().to_string_lossy().into_owned();
            (tag.starts_with(&prefix) && root.join(&tag).join(name).join("lib").is_dir())
                .then_some(tag)
        })
        .max();

    match newest {
        Some(tag) => {
            let path = root.join(&tag).join(name);
            (path, format!("cache/{tag}/{name}, not revalidated"))
        }
        None => panic!(
            "no cached FFmpeg {version} libavcodec for {name}, and no current release of it can be \
             downloaded (the warning above says why). Run ./build.sh {name} && \
             ./sync-prebuilt.sh, or set {OVERRIDE} to a prefix containing lib/."
        ),
    }
}

/// Download one target's archive from a named release and unpack it into the cache.
fn fetch(repo: &str, name: &str, version: &str, tag: &str, cached: &Path) -> PathBuf {
    let asset = format!("libavcodec-hevc-{version}-{name}.tar.gz");
    let base = format!("https://github.com/{repo}/releases/download/{tag}");

    // Staged under a pid-suffixed name so two cargo builds racing here cannot read each other's
    // half-written tarball. The loser of the race throws its copy away below.
    let staging = cached.with_extension(format!("tmp{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&staging);
    std::fs::create_dir_all(&staging).expect("cannot create the cache directory");
    let tarball = staging.join(&asset);
    let sums = staging.join("SHA256SUMS");

    println!("cargo:info=fetching {base}/{asset}");
    if !curl(&format!("{base}/{asset}"), &tarball) {
        panic!("cannot download {base}/{asset}");
    }
    // Both URLs name the same release rather than resolving `latest` a second time, so a
    // release published while the archive is in flight cannot swap it out from under the
    // checksums that are about to be read.
    if !curl(&format!("{base}/SHA256SUMS"), &sums) {
        panic!(
            "cannot download {base}/SHA256SUMS

Every release publishes one beside the \
             archives. If {tag} predates that, run this repository's release workflow \
             again, or set {OVERRIDE} to a prefix you built yourself."
        );
    }
    verify_download(&sums, &asset, &tarball, tag);

    // `tar` rather than a Rust tar crate: it is present on macOS, on every Linux image that can
    // run cargo, and in System32 on Windows 10 1803 and later, and a build dependency here
    // would be one every consumer compiles.
    run(Command::new("tar").arg("xzf").arg(&tarball).arg("-C").arg(&staging));
    std::fs::remove_file(&tarball).ok();
    std::fs::remove_file(&sums).ok();

    std::fs::create_dir_all(cached.parent().unwrap()).ok();
    if std::fs::rename(&staging, cached).is_err() {
        // Either another build populated the cache first — fine, use theirs — or the rename
        // genuinely failed, which the caller's `lib/` check will report.
        let _ = std::fs::remove_dir_all(&staging);
    }
    cached.to_path_buf()
}

/// The downloaded tarball against the SHA256SUMS published beside it on the same release.
///
/// Same standing as the MANIFEST check and for the same reason — the list travels with the
/// files it covers — so this catches a truncated or mangled download, not a dishonest release.
/// It replaces relying on `tar` to notice: gzip's CRC does catch corruption, but it reports it
/// as "unexpected end of file" from a program the user did not know was running, which is a
/// worse sentence than this one.
fn verify_download(sums: &Path, asset: &str, tarball: &Path, tag: &str) {
    let text = std::fs::read_to_string(sums).expect("cannot read the downloaded SHA256SUMS");
    // coreutils writes `<hex>  <name>`, and `sha256sum ./*.tar.gz` would prefix the name with
    // `./` — accepted here so that how the release job spelled its glob cannot break every
    // consumer's build.
    let expected = text
        .lines()
        .find_map(|line| {
            let (hash, rest) = line.split_once(char::is_whitespace)?;
            (rest.trim().trim_start_matches("./") == asset).then_some(hash)
        })
        .unwrap_or_else(|| panic!("SHA256SUMS on {tag} does not list {asset}:\n{text}"));

    let bytes = std::fs::read(tarball).expect("cannot read the downloaded archive");
    let actual = sha256_hex(&bytes);
    if actual != expected {
        panic!(
            "\n\n{asset} does not match the SHA256SUMS published beside it.\n\
             \x20 SHA256SUMS says {expected}\n\
             \x20 the download is {actual}\n\n\
             The download is corrupt, or a release was published while it was in flight. Try \
             again.\n"
        );
    }
    println!("cargo:info=libavcodec {asset} matches SHA256SUMS ({actual})");
}

/// `curl` one URL into one file, reporting whether it worked rather than dying, so that each
/// caller can say what a failure means.
fn curl(url: &str, out: &Path) -> bool {
    Command::new("curl")
        .args(["-sSL", "--fail", "--max-time", "300", "--retry", "3", "-o"])
        .arg(out)
        .arg(url)
        .status()
        .unwrap_or_else(|e| panic!("cannot run curl: {e}"))
        .success()
}

fn run(cmd: &mut Command) {
    let program = cmd.get_program().to_string_lossy().into_owned();
    match cmd.status() {
        Ok(status) if status.success() => {}
        Ok(status) => panic!("{program} failed: {status}"),
        Err(e) => panic!("cannot run {program}: {e}"),
    }
}

/// `$CARGO_HOME/libavcodec-hevc-prebuilt/<release tag>/`, one directory per release, so the download
/// happens once per machine rather than once per project — and so the many Docker builds that
/// already cache `~/.cargo` get it for free with no extra configuration.
fn cache_root() -> PathBuf {
    let home = std::env::var_os("CARGO_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cargo")))
        .or_else(|| std::env::var_os("USERPROFILE").map(|h| PathBuf::from(h).join(".cargo")))
        .expect("neither CARGO_HOME nor a home directory is set");
    home.join("libavcodec-hevc-prebuilt")
}

/// Check the hash against FIPS 180-4's published vectors, on every build.
///
/// Not a `#[cfg(test)] mod tests`, and that is the whole point of this comment. Cargo builds a
/// build script as a *binary it runs*, never as a test target — so a `#[test]` in this file is
/// compiled by nothing and run by nothing, and `cargo test` reports it as zero tests passing
/// while looking exactly like success. Fifty lines of hand-written hash guarded by a test that
/// does not exist is worse than fifty lines with no test at all, because the second kind gets
/// read carefully.
///
/// So it runs unconditionally, before the first hash that decides anything. Three short vectors
/// plus one megabyte of `'a'` — the long one is what exercises multi-block padding, the part
/// most likely to be wrong and least likely to show up on short inputs. The whole check costs
/// about a millisecond, once per build of this crate.
fn check_sha256_implementation() {
    for (input, expected) in [
        (Vec::new(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        (b"abc".to_vec(), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        (
            b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".to_vec(),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
        ),
        (vec![b'a'; 1_000_000], "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"),
    ] {
        let actual = sha256_hex(&input);
        assert_eq!(
            actual,
            expected,
            "this build script's SHA-256 is wrong on a published test vector ({} bytes of \
             input). Every archive integrity check in this file is meaningless until that is \
             fixed.",
            input.len(),
        );
    }
}
