# shellcheck shell=bash
# Fetch, verify and check out the pinned FFmpeg source. Sourced, not run — by build.sh, which
# compiles it, and by sync-prebuilt.sh, which takes the headers out of it.
#
# One copy of this rather than two, because it is where the repository's central promise lives:
# the commit is asserted *before* anything is compiled, so a tree that is not the pinned one
# never reaches a compiler, a header directory, or an artifact other projects link.

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# The configure switches that decide *what is in the library* — shared by build.sh, which adds
# the per-target ones, and by the header staging in sync-prebuilt.sh, so the headers are
# installed by the same configuration the archives are built with.
#
# `--disable-everything` and then two things back: the HEVC decoder and the HEVC parser. The
# parser is what turns an Annex B byte stream (or any arbitrary chunking of one) into the
# packets `avcodec_send_packet` wants; without it a consumer reading a raw `.hevc` file would
# have to find access-unit boundaries itself. No bitstream filters, no encoders (FFmpeg has no
# HEVC encoder of its own — see the README), no hwaccels.
#
# `--disable-autodetect`, because every autodetected dependency is a system library the archive
# would then need at every consumer's link: zlib, iconv, VideoToolbox, VAAPI, CUDA, Vulkan,
# libdrm, xlib, SDL. Measured on Debian 13: autodetect off still left `iconv` on (glibc carries
# it, so the probe succeeds with no library), hence `--disable-iconv` spelled out. Threads are
# autodetected too, and are turned back on per target in build.sh.
#
# Only libavcodec and libavutil are built: the decoder needs nothing else, and a consumer that
# wants demuxing or scaling has other crates for those.
# shellcheck disable=SC2034 # read by the scripts that source this file
FFMPEG_FEATURE_ARGS=(
  --disable-everything --disable-autodetect --disable-iconv
  --disable-programs --disable-doc
  --disable-avdevice --disable-avformat --disable-avfilter --disable-swscale --disable-swresample
  --disable-network
  --enable-decoder=hevc --enable-parser=hevc
)

# Leaves the checkout at build/ffmpeg-$FFMPEG_VERSION and echoes nothing; callers use that path
# directly. Idempotent: an existing checkout at the pinned commit is reused. One sitting at any
# other commit is *not* moved onto the pin — it fails with the commit mismatch below and has to
# be deleted — and a tree someone poked at by hand is reported rather than built.
ensure_source() {
  local src="build/ffmpeg-${FFMPEG_VERSION}"

  mkdir -p build
  if [ ! -d "$src/.git" ]; then
    echo ">> fetching FFmpeg ${FFMPEG_COMMIT} from ${FFMPEG_REPO}"
    rm -rf "$src"
    # Fetched **by commit**, one commit deep, rather than cloned by tag: the commit is then the
    # only thing that selects the tree, so there is no tag to move. LF whatever the host: Git for
    # Windows checks out CRLF by default, and the headers are compared byte for byte against the
    # committed (LF) copies.
    #
    # Assembled beside $src and renamed onto it only once the checkout exists. `$src/.git` is
    # what marks a finished fetch above, so a fetch that died half way must not leave one behind.
    local staging="$src.tmp.$$"
    rm -rf "$staging"
    if ! {
      git init --quiet "$staging" &&
        git -C "$staging" config core.autocrlf false &&
        git -C "$staging" config core.eol lf &&
        git -C "$staging" fetch --quiet --depth 1 "$FFMPEG_REPO" "$FFMPEG_COMMIT" &&
        git -C "$staging" checkout --quiet --detach FETCH_HEAD
    }; then
      rm -rf "$staging"
      echo "could not fetch ${FFMPEG_COMMIT} from ${FFMPEG_REPO}" >&2
      return 1
    fi
    mv "$staging" "$src"
  fi

  echo ">> verifying the checkout is ${FFMPEG_COMMIT}"
  local actual
  actual="$(git -C "$src" rev-parse HEAD)"
  [ "$actual" = "$FFMPEG_COMMIT" ] || {
    echo "commit mismatch in $src" >&2
    echo "  expected $FFMPEG_COMMIT" >&2
    echo "  actual   $actual" >&2
    echo "  (delete $src to re-clone, or fix FFMPEG_COMMIT in ffmpeg.env)" >&2
    return 1
  }

  # And that the commit is the release ffmpeg.env names. FFmpeg's release branches carry a
  # `RELEASE` file holding the version, bumped in the release commit itself — so a pin copied from
  # the wrong `ls-remote` line, or a version edited without the commit, fails here rather than
  # shipping one release's code under another's name.
  local release
  release="$(tr -d '\r\n' <"$src/RELEASE")"
  [ "$release" = "$FFMPEG_VERSION" ] || {
    echo "$FFMPEG_COMMIT is FFmpeg '$release' by its RELEASE file, not $FFMPEG_VERSION" >&2
    return 1
  }
  echo "   FFmpeg ${release}, unpatched"

  # A dirty tree is refused rather than cleaned: cleaning would silently discard work someone is
  # in the middle of. FFmpeg's configure runs out of tree (build.sh runs it from build/<target>),
  # so nothing this repository does writes into the checkout.
  if [ -n "$(git -C "$src" status --porcelain)" ]; then
    echo "$src has local modifications — the pinned commit is not what would be built" >&2
    git -C "$src" status --short >&2
    return 1
  fi
}

# On Windows, FFmpeg's configure has to be told to use MSVC — an MSYS2 shell has no gcc — and
# `link` has to *be* MSVC's linker. In MSYS2 `/usr/bin/link` is coreutils' link(1), which comes
# first on an inherited PATH and makes configure's first test program fail with a message about
# hard links. The developer environment names the toolset's directory; this puts it in front, for
# the calling script only, and sets `FFMPEG_TOOLCHAIN_ARGS` to the configure arguments that
# select MSVC — empty off Windows, where the function does nothing else. An array it sets rather
# than a value it prints, because `$(windows_toolchain)` would lose the PATH change to a subshell.
windows_toolchain() {
  FFMPEG_TOOLCHAIN_ARGS=()
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) ;;
    *) return 0 ;;
  esac
  [ -n "${VCToolsInstallDir:-}" ] || {
    echo "VCToolsInstallDir is unset — run this from a VS developer environment" >&2
    return 1
  }
  PATH="$(cygpath -u "$VCToolsInstallDir")bin/Hostx64/x64:$PATH"
  export PATH
  # shellcheck disable=SC2034 # read by the caller
  FFMPEG_TOOLCHAIN_ARGS=(--toolchain=msvc --arch=x86_64 --target-os=win64)
}

# Rewrite $1 with LF line endings, in place. `tr` rather than `sed -i`, whose in-place flag BSD
# and GNU spell differently.
to_lf() {
  tr -d '\r' <"$1" >"$1.lf" && mv "$1.lf" "$1"
}
