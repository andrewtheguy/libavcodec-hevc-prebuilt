//! Decode committed HEVC streams with the prebuilt libavcodec, and hold every frame to the bit
//! against the committed reference.
//!
//! Run by the pipeline on every target, because "the archives link" is a much weaker claim than
//! "the archives decode HEVC correctly, with the SIMD this machine has". A `cargo test` that only
//! builds proves the symbols resolved; this proves the decoder runs, on the CPU the artifact was
//! built for, and produces exactly the pictures the standard says it must.
//!
//! The streams and their references are the ones libde265-prebuilt's e2e binary uses, byte for
//! byte: x265 encoded them from ffmpeg's synthetic `testsrc2`, and each `.sha256` is one hash per
//! frame of a decode made by the Debian ffmpeg (7.1) — see `gen-testdata.sh`. That reference is
//! *not* this build checking itself: it is an older FFmpeg on another machine, and libde265 — an
//! independent implementation — reproduces the same hashes to the bit in its own repository.
//! Every stream also carries x265's MD5 picture-hash SEI, the encoder's own reconstruction, and
//! the decoder here verifies it in-band: a third witness.
//!
//! What it checks, in order:
//!
//!   1. the linked FFmpeg is the version this repository pins, under the LGPL;
//!   2. the archives hold exactly one codec — the HEVC decoder — and exactly one parser, and no
//!      HEVC encoder;
//!   3. FFmpeg detects the SIMD this architecture must have (SSE2 on x86_64, NEON on arm64), so
//!      the kernels build.sh counted are reachable here;
//!   4. the hand-written error constants (`AVERROR_EAGAIN`, `AVERROR_EOF`) are what libavcodec
//!      returns on this platform;
//!   5. every frame of both streams — 8-bit with B-frames, 10-bit with three slices per picture —
//!      decodes to exactly the reference, through the HEVC parser fed 4096- or 997-byte pieces,
//!      with SIMD on, with SIMD **off** (`av_force_cpu_flags(0)`), with four frame threads and
//!      with four slice threads (the streams use WPP), and with every in-band MD5 passing — and
//!      once more with SIMD on and off and the MD5 check off, the pair whose timings show the
//!      kernels are dispatched;
//!   6. with the loop filters skipped, the in-band MD5 check **fails** — proving it was live;
//!   7. a stream cut off at 60% drains to EOF with at most one error, and outputs reference
//!      pictures in display order — all but the one picture the cut landed in, which FFmpeg
//!      conceals and outputs, and which nothing sent before the cut can reference;
//!   8. on macOS, every frame of both streams decodes to exactly the reference through the
//!      VideoToolbox hwaccel too — each one a VideoToolbox picture, so FFmpeg's fallback to its
//!      own decoder cannot pass for it. A virtual Mac may have no hardware decoder to reach, so
//!      there an unavailable one is reported and not failed; anywhere else it fails.
//!
//! Nothing here is a benchmark, and no timing is asserted — a CI runner's clock is not a fact
//! about the decoder. The `-md5` rows are printed, with the SIMD speed-up they imply, because
//! they show at a glance whether the kernels are being dispatched at all: measured on this
//! repository's x86_64 builder, about 1.7× for 8-bit and 1.45× for 10-bit.

mod sha256;

// 10-bit samples come out as native-endian u16 and the reference hashed them little-endian.
#[cfg(target_endian = "big")]
compile_error!("the 10-bit reference hashes are of little-endian samples");

use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::ptr;
use std::time::Instant;

use avcodec_hevc_sys::*;

/// One committed stream and what it must decode to.
struct Stream {
    name: &'static str,
    bytes: &'static [u8],
    /// The per-frame SHA-256s, one per line, in output order.
    reference: &'static str,
    pix_fmt: AVPixelFormat,
    bit_depth: usize,
}

const STREAMS: [Stream; 2] = [
    Stream {
        name: "main",
        bytes: include_bytes!("../testdata/main.hevc"),
        reference: include_str!("../testdata/main.sha256"),
        pix_fmt: AVPixelFormat_AV_PIX_FMT_YUV420P,
        bit_depth: 8,
    },
    Stream {
        name: "main10",
        bytes: include_bytes!("../testdata/main10.hevc"),
        reference: include_str!("../testdata/main10.sha256"),
        pix_fmt: AVPixelFormat_AV_PIX_FMT_YUV420P10LE,
        bit_depth: 10,
    },
];

/// HEVC's class-D size, deliberately not a multiple of the 64x64 coding tree block.
const W: usize = 416;
const H: usize = 240;

/// How one decode is set up.
#[derive(Clone, Copy)]
struct Setup {
    label: &'static str,
    /// `false` forces libavutil's CPU flags to zero, so every DSP init picks the C functions.
    simd: bool,
    /// 1 decodes on the calling thread.
    threads: c_int,
    thread_type: c_int,
    /// How many bytes each `av_parser_parse2` call gets.
    chunk: usize,
    loop_filter: bool,
    /// Verify every picture against the stream's MD5 SEI (`AV_EF_CRCCHECK | AV_EF_EXPLODE`).
    /// Off only for the two timing rows: the MD5 is C, costs about as much as decoding a picture
    /// with the kernels, and would otherwise hide the SIMD speed-up it is there to show.
    md5: bool,
    /// The fraction of the stream fed in before the flush; 1.0 is all of it.
    keep: f64,
    /// Give the context a VideoToolbox device and ask for its pictures (8).
    videotoolbox: bool,
}

const SIMD: Setup = Setup {
    label: "simd",
    simd: true,
    threads: 1,
    thread_type: 0,
    chunk: 4096,
    loop_filter: true,
    md5: true,
    keep: 1.0,
    videotoolbox: false,
};
const SCALAR: Setup = Setup { label: "scalar", simd: false, ..SIMD };
const FRAME_THREADS: Setup = Setup {
    label: "4 frame thr",
    threads: 4,
    thread_type: FF_THREAD_FRAME as c_int,
    chunk: 997,
    ..SIMD
};
const SLICE_THREADS: Setup = Setup {
    label: "4 slice thr",
    threads: 4,
    thread_type: FF_THREAD_SLICE as c_int,
    chunk: 997,
    ..SIMD
};
const SIMD_NO_MD5: Setup = Setup { label: "simd -md5", md5: false, ..SIMD };
const SCALAR_NO_MD5: Setup = Setup { label: "scalar -md5", md5: false, ..SCALAR };
const NO_LOOP_FILTER: Setup = Setup { label: "no lf", loop_filter: false, ..SIMD };
const TRUNCATED: Setup = Setup { label: "cut at 60%", keep: 0.6, ..SIMD };
/// The MD5 check off: FFmpeg verifies the SEI against pictures it decoded itself, and a
/// VideoToolbox picture is not one.
const VIDEOTOOLBOX: Setup = Setup { label: "videotoolbox", md5: false, videotoolbox: true, ..SIMD };

fn main() {
    sha256::self_test();
    // FFmpeg logs to stderr, and the in-band hash failures (6) are logged at AV_LOG_ERROR. The
    // return codes carry everything this binary checks.
    // SAFETY: sets a global integer.
    unsafe { av_log_set_level(AV_LOG_QUIET) };

    // (1)
    let license = cstr(unsafe { avcodec_license() });
    println!(
        "libavcodec-hevc-e2e: FFmpeg {} (pinned {}), libavcodec {}, {license}",
        avcodec_hevc_sys::version(),
        avcodec_hevc_sys::PREBUILT_VERSION,
        dotted(unsafe { avcodec_version() }),
    );
    assert_eq!(
        avcodec_hevc_sys::version(),
        avcodec_hevc_sys::PREBUILT_VERSION,
        "the linked FFmpeg is not the version this repository pins — something else won the link"
    );
    assert_eq!(
        unsafe { avcodec_version() } >> 16,
        LIBAVCODEC_VERSION_MAJOR,
        "libavcodec's major version is not the one the committed headers declare"
    );
    assert_eq!(
        unsafe { avutil_version() } >> 16,
        LIBAVUTIL_VERSION_MAJOR,
        "libavutil's major version is not the one the committed headers declare"
    );
    assert_eq!(license, "LGPL version 2.1 or later", "the linked libavcodec is not LGPL");

    // (2)
    check_registry();
    // (3)
    check_cpu_flags();
    // (4)
    check_error_constants();

    let mut rows = Vec::new();
    let mut speed = Vec::new();
    for stream in &STREAMS {
        let reference: Vec<&str> = stream.reference.lines().collect();
        assert!(!reference.is_empty(), "{}: the reference hash list is empty", stream.name);

        // (5) exact, with every in-band hash passing.
        for setup in [SIMD, SCALAR, FRAME_THREADS, SLICE_THREADS, SIMD_NO_MD5, SCALAR_NO_MD5] {
            // The timing rows are the fastest of five decodes, each of them checked below: one
            // 48-frame pass on a busy machine measures the machine.
            let repeats = if setup.md5 { 1 } else { 5 };
            let run = (0..repeats)
                .map(|_| decode(stream, setup))
                .min_by_key(|run| if run.errors.is_empty() { run.micros } else { 0 })
                .unwrap();
            assert!(
                run.errors.is_empty(),
                "{} ({}): libavcodec returned {} — with AV_EF_CRCCHECK | AV_EF_EXPLODE this \
                 includes the stream's own MD5 check of every picture",
                stream.name,
                setup.label,
                describe(&run.errors)
            );
            assert!(
                run.eof,
                "{} ({}): the drained decoder never returned AVERROR_EOF",
                stream.name, setup.label
            );
            assert_eq!(
                run.frames.len(),
                reference.len(),
                "{} ({}): decoded {} frames, the reference has {}",
                stream.name,
                setup.label,
                run.frames.len(),
                reference.len()
            );
            if let Some(i) = first_mismatch(&run.frames, &reference) {
                panic!(
                    "{} ({}): frame {i} is not the reference picture — {} against {}",
                    stream.name, setup.label, run.frames[i], reference[i]
                );
            }
            speed.push((stream.name, setup.label, run.micros / run.frames.len().max(1) as u128));
            rows.push(row(stream, setup, &run, reference.len()));
        }

        // (6) The in-band check is live: skip a filter the encoder applied, and it must object.
        let run = decode(stream, NO_LOOP_FILTER);
        assert!(
            run.errors.contains(&AVERROR_INVALIDDATA),
            "{}: decoding with the loop filters skipped passed every MD5 picture hash ({}) — the \
             hash check is not running, so the passes above proved less than they claim",
            stream.name,
            describe(&run.errors)
        );
        assert!(
            run.frames.len() < reference.len() || first_mismatch(&run.frames, &reference).is_some(),
            "{}: decoding with the loop filters skipped produced the exact reference pictures — \
             skip_loop_filter did nothing",
            stream.name
        );
        rows.push(row(stream, NO_LOOP_FILTER, &run, reference.len()));

        // (7) A truncated stream. Not a prefix of the reference: a picture before the cut in
        // decode order can be after pictures that were cut off in display order (main outputs
        // 0..=20, the cut picture, then 24). So each output frame must be the *next* reference
        // picture it matches, and only the one picture the cut landed in may match none.
        let run = decode(stream, TRUNCATED);
        assert!(
            run.eof,
            "{}: the drained decoder never returned AVERROR_EOF after a cut at 60%",
            stream.name
        );
        assert!(
            run.errors.len() <= 1 && run.errors.iter().all(|&e| e == AVERROR_INVALIDDATA),
            "{}: a cut at 60% returned {} — at most one AVERROR_INVALIDDATA, for the cut picture",
            stream.name,
            describe(&run.errors)
        );
        let (intact, damaged) = in_order(&run.frames, &reference);
        assert!(
            damaged <= 1,
            "{}: {damaged} of {} frames after a cut at 60% are not reference pictures in display \
             order — only the picture the cut landed in may be wrong",
            stream.name,
            run.frames.len()
        );
        assert!(
            intact * 3 >= reference.len(),
            "{}: only {intact} reference pictures came out of a cut at 60%",
            stream.name
        );
        rows.push(row(stream, TRUNCATED, &run, reference.len()));

        // (8)
        if cfg!(target_os = "macos") {
            if let Some(run) = check_videotoolbox(stream, &reference) {
                rows.push(row(stream, VIDEOTOOLBOX, &run, reference.len()));
            }
        }
    }

    println!();
    println!("| stream | decode       | frames | exact | errors | µs/frame |");
    println!("|--------|--------------|--------|-------|--------|----------|");
    for r in &rows {
        println!("{r}");
    }
    println!();
    for stream in &STREAMS {
        let micros = |label: &str| {
            speed
                .iter()
                .find(|(s, l, _)| *s == stream.name && *l == label)
                .map(|(_, _, m)| *m as f64)
        };
        if let (Some(simd), Some(scalar)) = (micros(SIMD_NO_MD5.label), micros(SCALAR_NO_MD5.label))
        {
            println!(
                "{}: SIMD decodes {:.2}× as fast as scalar",
                stream.name,
                scalar / simd.max(1.0)
            );
        }
    }
    println!();
    println!(
        "ok: {} streams decoded bit-exactly, with SIMD and without, threaded and not, on {}",
        STREAMS.len(),
        std::env::consts::ARCH
    );
}

/// (2) Exactly one codec, the HEVC decoder; exactly one parser, HEVC's; no encoder to find.
fn check_registry() {
    let mut codecs = Vec::new();
    let mut opaque = ptr::null_mut();
    loop {
        // SAFETY: `opaque` is the iteration state av_codec_iterate owns; the codecs it returns
        // are static.
        let codec = unsafe { av_codec_iterate(&mut opaque) };
        if codec.is_null() {
            break;
        }
        let codec = unsafe { &*codec };
        let decoder = unsafe { av_codec_is_decoder(codec) } != 0;
        codecs.push(format!(
            "{} ({})",
            cstr(codec.name),
            if decoder { "decoder" } else { "encoder" }
        ));
    }
    assert_eq!(codecs, ["hevc (decoder)"], "the archive registers the wrong codecs");

    let mut parsers = Vec::new();
    let mut opaque = ptr::null_mut();
    loop {
        // SAFETY: as above.
        let parser = unsafe { av_parser_iterate(&mut opaque) };
        if parser.is_null() {
            break;
        }
        parsers.push(unsafe { (*parser).codec_ids });
    }
    assert_eq!(parsers.len(), 1, "the archive registers {} parsers, not one", parsers.len());
    assert!(
        parsers[0].contains(&AVCodecID_AV_CODEC_ID_HEVC),
        "the one parser is not HEVC's: {:?}",
        parsers[0]
    );
    assert!(
        unsafe { avcodec_find_encoder(AVCodecID_AV_CODEC_ID_HEVC) }.is_null(),
        "avcodec_find_encoder(HEVC) found something"
    );
    println!("registry: {} and the hevc parser, nothing else", codecs[0]);
}

/// (3) What FFmpeg's runtime CPU detection sees, and the floor this architecture guarantees.
fn check_cpu_flags() {
    // SAFETY: reads (and on first call computes) a global.
    let flags = unsafe { av_get_cpu_flags() } as u32;
    let named: &[(u32, &str)] = if cfg!(target_arch = "x86_64") {
        &[
            (AV_CPU_FLAG_SSE2, "sse2"),
            (AV_CPU_FLAG_SSSE3, "ssse3"),
            (AV_CPU_FLAG_SSE4, "sse4.1"),
            (AV_CPU_FLAG_AVX, "avx"),
            (AV_CPU_FLAG_AVX2, "avx2"),
            (AV_CPU_FLAG_AVX512, "avx512"),
        ]
    } else if cfg!(target_arch = "aarch64") {
        &[(AV_CPU_FLAG_NEON, "neon"), (AV_CPU_FLAG_DOTPROD, "dotprod"), (AV_CPU_FLAG_I8MM, "i8mm")]
    } else {
        &[]
    };
    let have: Vec<&str> =
        named.iter().filter(|(bit, _)| flags & bit != 0).map(|(_, n)| *n).collect();
    println!("cpu flags: {} (0x{flags:x})", have.join(" "));
    // The baseline of each architecture: x86-64 always has SSE2 and ARMv8-A always has NEON, so a
    // zero here means runtime detection is broken or compiled out — and every "simd" decode below
    // would silently be a second scalar one.
    if cfg!(target_arch = "x86_64") {
        assert!(flags & AV_CPU_FLAG_SSE2 != 0, "FFmpeg does not detect SSE2 on an x86_64 CPU");
    }
    if cfg!(target_arch = "aarch64") {
        assert!(flags & AV_CPU_FLAG_NEON != 0, "FFmpeg does not detect NEON on an arm64 CPU");
    }
}

/// (4) The constants lib.rs spells by hand, against what libavcodec actually returns here.
fn check_error_constants() {
    // SAFETY: a context opened and freed within this function, on this thread.
    unsafe {
        let codec = avcodec_find_decoder(AVCodecID_AV_CODEC_ID_HEVC);
        let mut ctx = avcodec_alloc_context3(codec);
        check(avcodec_open2(ctx, codec, ptr::null_mut()), "avcodec_open2");
        let mut frame = av_frame_alloc();
        let fresh = avcodec_receive_frame(ctx, frame);
        assert_eq!(
            fresh,
            AVERROR_EAGAIN,
            "a fresh decoder returned {} , not AVERROR(EAGAIN)",
            err_text(fresh)
        );
        check(avcodec_send_packet(ctx, ptr::null()), "avcodec_send_packet(NULL)");
        let drained = avcodec_receive_frame(ctx, frame);
        assert_eq!(
            drained,
            AVERROR_EOF,
            "an empty drained decoder returned {}, not AVERROR_EOF",
            err_text(drained)
        );
        av_frame_free(&mut frame);
        avcodec_free_context(&mut ctx);
    }
}

/// (8) Decode `stream` through the VideoToolbox hwaccel and hold it to the reference; `None` when
/// this is a virtual Mac with no hardware decoder to reach.
fn check_videotoolbox(stream: &Stream, reference: &[&str]) -> Option<Run> {
    let run = decode(stream, VIDEOTOOLBOX);
    if run.hardware == 0 {
        let why = run.device_error.map_or_else(
            || "FFmpeg decoded every picture itself".to_string(),
            |code| format!("no VideoToolbox device: {}", err_text(code)),
        );
        assert!(
            virtual_mac(),
            "{}: the VideoToolbox hwaccel decoded nothing ({why}) on a Mac that is not virtual",
            stream.name
        );
        println!("{}: VideoToolbox unavailable on this virtual Mac ({why}) — not checked", stream.name);
        return None;
    }
    assert!(run.errors.is_empty(), "{} (videotoolbox): libavcodec returned {}", stream.name, describe(&run.errors));
    assert_eq!(
        run.hardware,
        run.frames.len(),
        "{}: {} of {} pictures came from VideoToolbox, the rest from FFmpeg's own decoder",
        stream.name,
        run.hardware,
        run.frames.len()
    );
    assert_eq!(
        run.frames.len(),
        reference.len(),
        "{} (videotoolbox): decoded {} frames, the reference has {}",
        stream.name,
        run.frames.len(),
        reference.len()
    );
    if let Some(i) = first_mismatch(&run.frames, reference) {
        panic!(
            "{} (videotoolbox): frame {i} is not the reference picture — {} against {}",
            stream.name, run.frames[i], reference[i]
        );
    }
    Some(run)
}

/// Whether this Mac is a virtual machine, from the kernel's own `kern.hv_vmm_present`.
fn virtual_mac() -> bool {
    let out = std::process::Command::new("sysctl").args(["-n", "kern.hv_vmm_present"]).output();
    let out = out.expect("running sysctl -n kern.hv_vmm_present");
    assert!(out.status.success(), "sysctl -n kern.hv_vmm_present failed");
    String::from_utf8_lossy(&out.stdout).trim() == "1"
}

/// Choose VideoToolbox's pictures when the decoder offers them, and its default otherwise — which
/// is also what FFmpeg asks again for when the hwaccel fails to start.
unsafe extern "C" fn prefer_videotoolbox(
    ctx: *mut AVCodecContext,
    formats: *const AVPixelFormat,
) -> AVPixelFormat {
    let mut at = formats;
    while *at != AVPixelFormat_AV_PIX_FMT_NONE {
        if *at == AVPixelFormat_AV_PIX_FMT_VIDEOTOOLBOX {
            return *at;
        }
        at = at.add(1);
    }
    avcodec_default_get_format(ctx, formats)
}

/// What one decode produced.
struct Run {
    /// The SHA-256 of each output picture, planes packed without stride padding.
    frames: Vec<String>,
    /// Every error returned other than EAGAIN and EOF.
    errors: Vec<c_int>,
    eof: bool,
    /// Wall time in the decoder and parser, with the hashing of each output frame taken out —
    /// the hash is this binary's cost, not FFmpeg's, and would otherwise flatten the SIMD column.
    micros: u128,
    hash_micros: u128,
    /// How many of `frames` were VideoToolbox pictures.
    hardware: usize,
    /// What `av_hwdevice_ctx_create` returned, when it refused.
    device_error: Option<c_int>,
}

fn row(stream: &Stream, setup: Setup, run: &Run, expected: usize) -> String {
    let reference: Vec<&str> = stream.reference.lines().collect();
    let (exact, _) = in_order(&run.frames, &reference);
    format!(
        "| {:6} | {:12} | {:3}/{:<2} | {:5} | {:6} | {:8} |",
        stream.name,
        setup.label,
        run.frames.len(),
        expected,
        exact,
        run.errors.len(),
        run.micros / (run.frames.len().max(1) as u128)
    )
}

/// Match `frames` against `reference` as a subsequence, in order: (frames that are the next
/// reference picture after the previous match, frames that are no later reference picture).
fn in_order(frames: &[String], reference: &[&str]) -> (usize, usize) {
    let (mut next, mut matched) = (0, 0);
    for frame in frames {
        if let Some(i) = reference[next..].iter().position(|r| r == frame) {
            next += i + 1;
            matched += 1;
        }
    }
    (matched, frames.len() - matched)
}

fn first_mismatch(frames: &[String], reference: &[&str]) -> Option<usize> {
    frames.iter().zip(reference).position(|(a, b)| a != b)
}

/// Decode `stream` under `setup`: bytes through the parser, packets to the decoder, frames out.
fn decode(stream: &Stream, setup: Setup) -> Run {
    let mut run = Run {
        frames: Vec::new(),
        errors: Vec::new(),
        eof: false,
        micros: 0,
        hash_micros: 0,
        hardware: 0,
        device_error: None,
    };
    let input = &stream.bytes[..(stream.bytes.len() as f64 * setup.keep) as usize];

    // av_parser_parse2 reads up to AV_INPUT_BUFFER_PADDING_SIZE bytes past the `len` it is
    // given, and expects them zero — which neither the end of an include_bytes! nor the next
    // piece of the stream is. So each piece is copied into a buffer that has them.
    let padding = AV_INPUT_BUFFER_PADDING_SIZE as usize;
    let mut buf = vec![0u8; setup.chunk + padding];

    // SAFETY: every object is created here, used only on this thread, and freed exactly once at
    // the end. The parser's output buffer is sent (and copied by libavcodec, since the packet is
    // not reference-counted) before the parser is called again, and before `buf` is refilled.
    unsafe {
        // Process-wide, and read by each DSP init when the decoder opens: -1 restores detection.
        av_force_cpu_flags(if setup.simd { -1 } else { 0 });

        let codec = avcodec_find_decoder(AVCodecID_AV_CODEC_ID_HEVC);
        assert!(!codec.is_null(), "avcodec_find_decoder(HEVC) returned null");
        let mut ctx = avcodec_alloc_context3(codec);
        assert!(!ctx.is_null(), "avcodec_alloc_context3 returned null");
        (*ctx).thread_count = setup.threads;
        (*ctx).thread_type = setup.thread_type;
        // Verify every picture against the stream's MD5 SEI, and fail the frame if it differs.
        if setup.md5 {
            (*ctx).err_recognition = (AV_EF_CRCCHECK | AV_EF_EXPLODE) as c_int;
        }
        if !setup.loop_filter {
            (*ctx).skip_loop_filter = AVDiscard_AVDISCARD_ALL;
        }
        if setup.videotoolbox {
            let mut device = ptr::null_mut();
            let ret = av_hwdevice_ctx_create(
                &mut device,
                AVHWDeviceType_AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                ptr::null(),
                ptr::null_mut(),
                0,
            );
            if ret < 0 {
                run.device_error = Some(ret);
            } else {
                // The context takes its own reference; this one is dropped once it has.
                (*ctx).hw_device_ctx = av_buffer_ref(device);
                (*ctx).get_format = Some(prefer_videotoolbox);
                av_buffer_unref(&mut device);
            }
        }
        check(avcodec_open2(ctx, codec, ptr::null_mut()), "avcodec_open2");

        let mut parser = av_parser_init(AVCodecID_AV_CODEC_ID_HEVC);
        assert!(!parser.is_null(), "av_parser_init(HEVC) returned null");
        let mut packet = av_packet_alloc();
        let mut frame = av_frame_alloc();

        let started = Instant::now();
        for chunk in input.chunks(setup.chunk) {
            buf[..chunk.len()].copy_from_slice(chunk);
            buf[chunk.len()..].fill(0);
            let mut rest = &buf[..chunk.len()];
            while !rest.is_empty() {
                let (used, out, size) = parse(parser, ctx, rest.as_ptr(), rest.len());
                rest = &rest[used..];
                if size > 0 {
                    send(ctx, packet, frame, out, size, stream, &mut run);
                }
            }
        }
        // The parser holds back the last access unit until it is told the input has ended.
        let (_, out, size) = parse(parser, ctx, ptr::null(), 0);
        if size > 0 {
            send(ctx, packet, frame, out, size, stream, &mut run);
        }
        // And the decoder holds back its reorder queue until it is sent NULL.
        send(ctx, packet, frame, ptr::null_mut(), 0, stream, &mut run);
        run.micros = started.elapsed().as_micros().saturating_sub(run.hash_micros);

        av_frame_free(&mut frame);
        av_packet_free(&mut packet);
        av_parser_close(parser);
        parser = ptr::null_mut();
        let _ = parser;
        avcodec_free_context(&mut ctx);
        av_force_cpu_flags(-1);
    }
    run
}

/// One `av_parser_parse2` call: (bytes consumed, packet data, packet size).
///
/// # Safety
///
/// `parser` and `ctx` must be live; `data` must point at `len` readable bytes followed by
/// `AV_INPUT_BUFFER_PADDING_SIZE` zeroed ones, or be null with `len` 0 to flush.
unsafe fn parse(
    parser: *mut AVCodecParserContext,
    ctx: *mut AVCodecContext,
    data: *const u8,
    len: usize,
) -> (usize, *mut u8, c_int) {
    let mut out: *mut u8 = ptr::null_mut();
    let mut size: c_int = 0;
    let used = av_parser_parse2(
        parser,
        ctx,
        &mut out,
        &mut size,
        data,
        len as c_int,
        AV_NOPTS_VALUE,
        AV_NOPTS_VALUE,
        0,
    );
    assert!(used >= 0, "av_parser_parse2 failed: {}", err_text(used));
    (used as usize, out, size)
}

/// Send one packet (or, with null data, the end of the stream), receiving frames whenever the
/// decoder wants room.
///
/// # Safety
///
/// Every pointer must be live and owned by the calling thread.
unsafe fn send(
    ctx: *mut AVCodecContext,
    packet: *mut AVPacket,
    frame: *mut AVFrame,
    data: *mut u8,
    size: c_int,
    stream: &Stream,
    run: &mut Run,
) {
    let flushing = data.is_null();
    (*packet).data = data;
    (*packet).size = size;
    loop {
        let ret = avcodec_send_packet(ctx, if flushing { ptr::null() } else { packet });
        if ret == AVERROR_EAGAIN {
            // The send/receive contract: EAGAIN from send means output must be taken first, and
            // then the same packet sent again.
            receive(ctx, frame, stream, run);
            continue;
        }
        if ret < 0 && !(flushing && ret == AVERROR_EOF) {
            run.errors.push(ret);
        }
        break;
    }
    receive(ctx, frame, stream, run);
}

/// Take every frame the decoder has ready, hashing each.
///
/// # Safety
///
/// As for [`send`].
unsafe fn receive(ctx: *mut AVCodecContext, frame: *mut AVFrame, stream: &Stream, run: &mut Run) {
    loop {
        let ret = avcodec_receive_frame(ctx, frame);
        if ret == AVERROR_EAGAIN {
            return;
        }
        if ret == AVERROR_EOF {
            run.eof = true;
            return;
        }
        if ret < 0 {
            // A frame that failed (its MD5, with AV_EF_EXPLODE) is reported here and the queue
            // moves on: the next call returns the next frame, EAGAIN or EOF.
            run.errors.push(ret);
            continue;
        }
        let hashing = Instant::now();
        if (*frame).format == AVPixelFormat_AV_PIX_FMT_VIDEOTOOLBOX as c_int {
            // The picture is the media engine's; its samples are copied out to be hashed, into
            // the planar-interleaved format VideoToolbox decoded to (NV12, or P010 for 10-bit).
            let mut copy = av_frame_alloc();
            check(av_hwframe_transfer_data(copy, frame, 0), "av_hwframe_transfer_data");
            run.frames.push(frame_hash(&*copy, stream));
            run.hardware += 1;
            av_frame_free(&mut copy);
        } else {
            run.frames.push(frame_hash(&*frame, stream));
        }
        run.hash_micros += hashing.elapsed().as_micros();
        av_frame_unref(frame);
    }
}

/// Pack a decoded picture the way ffmpeg's `framehash` packs a raw frame — Y, then Cb, then Cr,
/// each row exactly `width × bytes-per-sample` long, stride padding left out — and hash it.
/// Checks the picture's shape on the way, since a wrong size would otherwise surface only as a
/// hash mismatch.
///
/// A VideoToolbox picture, copied out, is the same samples semi-planar: NV12's Cb and Cr
/// interleaved in one plane, and P010's, besides, with each 10-bit sample in the top bits of its
/// 16. Both are unpacked into the planar layout the reference hashed.
///
/// # Safety
///
/// `frame` must be a frame `avcodec_receive_frame` just filled, or a copy of one.
unsafe fn frame_hash(frame: &AVFrame, stream: &Stream) -> String {
    let semi_planar = match stream.bit_depth {
        8 => AVPixelFormat_AV_PIX_FMT_NV12,
        _ => AVPixelFormat_AV_PIX_FMT_P010LE,
    };
    if frame.format == semi_planar as c_int {
        return semi_planar_hash(frame, stream);
    }
    assert_eq!(
        frame.format,
        stream.pix_fmt as c_int,
        "{}: decoded {}, not {}",
        stream.name,
        cstr(av_get_pix_fmt_name(frame.format)),
        cstr(av_get_pix_fmt_name(stream.pix_fmt))
    );
    assert_eq!(
        (frame.width as usize, frame.height as usize),
        (W, H),
        "{}: wrong picture size",
        stream.name
    );
    let bytes_per_sample = if stream.bit_depth > 8 { 2 } else { 1 };
    let mut packed = Vec::with_capacity(W * H * 3 * bytes_per_sample / 2);
    for plane in 0..3 {
        let (width, height) = if plane == 0 { (W, H) } else { (W / 2, H / 2) };
        let data = frame.data[plane];
        let stride = frame.linesize[plane];
        assert!(!data.is_null(), "{}: plane {plane} is null", stream.name);
        let row_bytes = width * bytes_per_sample;
        assert!(
            stride as usize >= row_bytes,
            "{}: plane {plane} stride {stride} < {row_bytes}",
            stream.name
        );
        for row in 0..height {
            packed.extend_from_slice(std::slice::from_raw_parts(
                data.add(row * stride as usize),
                row_bytes,
            ));
        }
    }
    sha256::hex(&packed)
}

/// [`frame_hash`] for a semi-planar copy of a VideoToolbox picture.
///
/// # Safety
///
/// As for [`frame_hash`].
unsafe fn semi_planar_hash(frame: &AVFrame, stream: &Stream) -> String {
    assert_eq!(
        (frame.width as usize, frame.height as usize),
        (W, H),
        "{}: wrong picture size",
        stream.name
    );
    let bytes_per_sample = if stream.bit_depth > 8 { 2 } else { 1 };
    let row = |plane: usize, y: usize, bytes: usize| {
        let stride = frame.linesize[plane] as usize;
        assert!(stride >= bytes, "{}: plane {plane} stride {stride} < {bytes}", stream.name);
        std::slice::from_raw_parts(frame.data[plane].add(y * stride), bytes)
    };
    // One sample of `bytes_per_sample`, as the reference stores it: P010's 10 bits moved down.
    let push = |packed: &mut Vec<u8>, sample: &[u8]| {
        if bytes_per_sample == 1 {
            packed.push(sample[0]);
        } else {
            let value = u16::from_le_bytes([sample[0], sample[1]]) >> 6;
            packed.extend_from_slice(&value.to_le_bytes());
        }
    };
    let mut packed = Vec::with_capacity(W * H * 3 * bytes_per_sample / 2);
    for y in 0..H {
        for sample in row(0, y, W * bytes_per_sample).chunks(bytes_per_sample) {
            push(&mut packed, sample);
        }
    }
    // Cb is every first sample of the interleaved plane, Cr every second.
    for chroma in 0..2 {
        for y in 0..H / 2 {
            let pairs = row(1, y, W * bytes_per_sample);
            for pair in pairs.chunks(2 * bytes_per_sample) {
                push(&mut packed, &pair[chroma * bytes_per_sample..(chroma + 1) * bytes_per_sample]);
            }
        }
    }
    sha256::hex(&packed)
}

fn describe(codes: &[c_int]) -> String {
    if codes.is_empty() {
        return "nothing".into();
    }
    let mut seen = codes.to_vec();
    seen.sort_unstable();
    seen.dedup();
    seen.iter()
        .map(|&code| {
            format!("{} ({code}) ×{}", err_text(code), codes.iter().filter(|&&c| c == code).count())
        })
        .collect::<Vec<_>>()
        .join(", ")
}

fn err_text(code: c_int) -> String {
    let mut buf = [0 as c_char; 128];
    // SAFETY: av_strerror writes at most `len` bytes, NUL-terminated, into the buffer.
    unsafe { av_strerror(code, buf.as_mut_ptr(), buf.len()) };
    cstr(buf.as_ptr())
}

fn cstr(ptr: *const c_char) -> String {
    assert!(!ptr.is_null(), "FFmpeg returned a null string");
    // SAFETY: every string passed here is a NUL-terminated C string FFmpeg returned or wrote.
    unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned()
}

/// `AV_VERSION_INT` unpacked: major.minor.micro.
fn dotted(version: u32) -> String {
    format!("{}.{}.{}", version >> 16, (version >> 8) & 0xff, version & 0xff)
}

/// Turn an FFmpeg return code into a panic naming the call and FFmpeg's own text.
fn check(ret: c_int, what: &str) {
    if ret < 0 {
        panic!("{what} failed: {} ({ret})", err_text(ret));
    }
}
