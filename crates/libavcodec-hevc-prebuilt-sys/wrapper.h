// What bindgen reads: the parts of libavcodec's and libavutil's public interface a decoder loop
// uses — the codec API, the parser, packets, frames, pixel formats, errors, logging and the CPU
// flags. Everything these headers declare is bound, including what they include in turn: that
// brings libavutil/hwcontext.h, the generic device API a consumer hands the macOS archive's
// VideoToolbox hwaccel a device with. The rest of libavutil (hashes, ciphers, the tx API, each
// API's own hwcontext_*.h) is installed with the archive for a consumer compiling C against it,
// but is not what this crate is for.
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/cpu.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/imgutils.h>
#include <libavutil/log.h>
#include <libavutil/pixdesc.h>
