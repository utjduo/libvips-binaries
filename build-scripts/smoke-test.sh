#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# smoke-test.sh - compile build-scripts/smoke-test.c against a package this
# repository built, run it, and report what that library can really do.
#
# build-scripts/win.sh calls it against target/ just before the tarball is
# made; build-scripts/posix.sh calls it straight after "meson install", because
# that script then deletes target/lib/pkgconfig, filters target/lib and renames
# the libraries.  It can also be run by hand against either a build tree or an
# unpacked artifact:
#
#   bash build.sh win-x64
#   bash build-scripts/smoke-test.sh spng openjpeg jpeg-xl nsgif
#   TARGET=/path/to/unpacked/libvips bash build-scripts/smoke-test.sh all
#
# The arguments are the codecs the build selected - the same names build.sh
# takes, including "all", "none" and the aliases (jxl, exr, jp2, ...).  The
# preset and feature switches are taken from the environment (PRESET, LEAN and
# FEATURES are exported by build-scripts/codecs.sh) and, when the script runs on
# its own, from the entries the build wrote to target/versions.json.  Formats
# that trimming removed on purpose are reported as trimmed instead of counted
# as failures; a codec that was asked for and is missing fails the run.
#
# Everything is resolved from the package itself: --cflags and --libs come from
# $TARGET/lib/pkgconfig/vips.pc, or from paths derived from $TARGET when that
# directory has already been cleaned up.  Set SMOKE_TEST=0 to skip this script
# from a build.
# ---------------------------------------------------------------------------

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PACKAGE_DIR="$(dirname "$SCRIPT_DIR")"
SRC="$SCRIPT_DIR/smoke-test.c"

fail() {
	echo "smoke-test: $*" >&2
	exit 1
}

[ -f "$SRC" ] || fail "missing $SRC"

# --- which platform are we on? ------------------------------------------------
# MSYS2 reports MSYS_NT-* or MINGW64_NT-*, msys2-based CI shells report
# MINGW64_NT-*; all three need the Windows treatment (.exe suffix, PATH instead
# of LD_LIBRARY_PATH, no OpenEXR).
IS_WINDOWS=""
IS_DARWIN=""
case "$(uname -s)" in
	MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;;
	Darwin) IS_DARWIN=1 ;;
esac

# --- where is the package? --------------------------------------------------
# win.sh runs this from inside target/, posix.sh passes TARGET explicitly.
if [ -z "${TARGET:-}" ]; then
  if [ -f "$PWD/lib/pkgconfig/vips.pc" ]; then
    TARGET="$PWD"
  else
    TARGET="$PACKAGE_DIR/target"
  fi
fi
[ -d "$TARGET/include/vips" ] || fail "no headers in $TARGET/include/vips - build the package first"
[ -d "$TARGET/lib" ] || fail "no libraries in $TARGET/lib - build the package first"

# --- what was the package supposed to contain? ------------------------------
PRESET="${PRESET:-}"
LEAN="${LEAN:-}"
# codecs.sh exports FEATURES already lower-case and space separated; a hand run
# of this script may get the comma separated spelling the build accepts, so
# normalise it here as well - feature_state() matches on whole " name=on " words.
FEATURES="$(printf '%s' "${FEATURES:-}" | tr '[:upper:]' '[:lower:]' | tr ',;' ' ')"
VIPS_VERSION="${VERSION_VIPS:-}"
VERSIONS_JSON="$TARGET/versions.json"
if [ -f "$VERSIONS_JSON" ]; then
  json_field() {
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$VERSIONS_JSON" | head -n 1
  }
  [ -n "$PRESET" ] || PRESET="$(json_field preset)"
  [ -n "$LEAN" ] || LEAN="$(json_field lean)"
  [ -n "$FEATURES" ] || FEATURES="$(json_field features)"
  [ -n "$VIPS_VERSION" ] || VIPS_VERSION="$(json_field vips)"
fi

# posix.sh runs this before it has written versions.json, so fall back to the
# pkg-config file meson has just installed; win.sh keeps the same file in the
# artifact, and an unpacked tarball carries versions.json, so one of the two is
# always available.
if [ -z "$VIPS_VERSION" ] && [ -f "$TARGET/lib/pkgconfig/vips.pc" ]; then
  VIPS_VERSION="$(sed -n 's/^Version:[[:space:]]*//p' "$TARGET/lib/pkgconfig/vips.pc" | head -n 1)"
fi

# --- which codecs were asked for? -------------------------------------------
normalise_codec() {
  case "$1" in
    jxl|jpegxl|libjxl) echo "jpeg-xl" ;;
    exr|open-exr) echo "openexr" ;;
    jp2|jpeg2000|openjpeg2|open-jpeg) echo "openjpeg" ;;
    libspng|png-spng) echo "spng" ;;
    libraw) echo "raw" ;;
    fits|libcfitsio) echo "cfitsio" ;;
    mat|matlab) echo "matio" ;;
    fft|libfftw) echo "fftw" ;;
    gif) echo "cgif" ;;
    *) echo "$1" ;;
  esac
}

CODEC_ARG=" "
if [ "$#" -eq 0 ]; then
  # Called with no arguments: trust the codec list the build exported, if any.
  CODEC_ARG=" ${CODECS:-} "
else
  # win.sh and posix.sh forward the codec selection unquoted, and CODECS is a
  # comma separated list, so a selection like "spng,openjpeg" arrives here as one
  # word.  Split commas (and semicolons) before reading the arguments, or every
  # codec in the list would be neither required nor skipped.
  set -- $(printf '%s' "$*" | tr ',;' '  ')
  for c in "$@"; do
    case "$c" in
      all) CODEC_ARG="$CODEC_ARG spng openjpeg openexr jpeg-xl fftw cfitsio matio raw ppm analyze radiance qoi nsgif cgif" ;;
      none|off) ;;
      *) CODEC_ARG="$CODEC_ARG $(normalise_codec "$c")" ;;
    esac
  done
fi
# codec_on() matches " name " so the list has to end with a space as well as
# start with one; without this the last codec on the command line was never
# seen and its check silently dropped out of both lists.
CODEC_ARG="$CODEC_ARG "

codec_on() {
  case "$CODEC_ARG" in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# on / off / unknown - "unknown" means the build did not record the feature, so
# the check is reported but not required.
feature_state() {
  case " $FEATURES " in
    *" $1=on "*) echo on ;;
    *" $1=off "*) echo off ;;
    *) echo unknown ;;
  esac
}

# --- which checks must work, which were trimmed on purpose ------------------
require="png,jpeg,webp,avif,thumbnail,buffer,memory,metadata,colourspace"
skip=""
add_require() { require="$require,$1"; }
add_skip() { skip="$skip,$1"; }

vips_at_least() {
  case "$VIPS_VERSION" in
    [0-9]*) ;;
    *) return 1 ;;
  esac
  have_major="${VIPS_VERSION%%.*}"
  have_minor="${VIPS_VERSION#*.}"
  have_minor="${have_minor%%.*}"
  want_major="${1%%.*}"
  want_minor="${1#*.}"
  [ "$have_major" -gt "$want_major" ] && return 0
  [ "$have_major" -eq "$want_major" ] && [ "$have_minor" -ge "$want_minor" ] && return 0
  return 1
}

# jpeg, png, webp, gif loading, heif/avif and lcms are core: win.sh and
# posix.sh always link them, so they always have to work.
if codec_on nsgif; then add_require gifload; else add_skip gifload; fi
if codec_on openjpeg; then add_require jp2; else add_skip jp2; fi
if codec_on jpeg-xl; then add_require jxl; else add_skip jxl; fi
if codec_on fftw; then add_require sharpen; else add_skip sharpen; fi
if codec_on cfitsio; then add_require fits; else add_skip fits; fi
if codec_on matio; then add_require mat; else add_skip mat; fi
if codec_on raw; then add_require raw; else add_skip raw; fi
if codec_on ppm; then add_require ppm; else add_skip ppm; fi
if codec_on analyze; then add_require analyze; else add_skip analyze; fi
if codec_on radiance; then add_require rad; else add_skip rad; fi

if codec_on openexr; then
  # OpenEXR is not available in the MSYS2 package set win.sh uses, so a Windows
  # build cannot be expected to have it even when the codec was selected.
  if [ -n "${IS_WINDOWS:-}" ]; then
    echo "smoke-test: openexr is not buildable on Windows, checking it as optional"
    add_skip openexr
  else
    add_require openexr
  fi
fi

if codec_on qoi; then
  if vips_at_least 8.19; then
    add_require qoi
  else
    echo "smoke-test: libvips $VIPS_VERSION has no QOI, checking it as optional"
    add_skip qoi
  fi
fi

# The feature switches from build-scripts/codecs.sh.
apply_feature() {
  case "$(feature_state "$1")" in
    on) add_require "$2" ;;
    off) add_skip "$2" ;;
    *) ;;
  esac
}
apply_feature tiff tiff
apply_feature dzsave dz
apply_feature svg svgload
apply_feature text text
apply_feature uhdr uhdr
apply_feature imagequant gif

# A .heic round-trip needs both halves of libheif: libde265 to read and x265 to
# write. AVIF is unaffected - libaom is always linked - so "avif" stays required.
heif_enc="$(feature_state heif_enc)"
heif_dec="$(feature_state heif_dec)"
if [ "$heif_enc" = on ] && [ "$heif_dec" != off ]; then
  add_require heic
elif [ "$heif_enc" = off ] || [ "$heif_dec" = off ]; then
  add_skip heic
fi

# --- compile ----------------------------------------------------------------
CC_BIN="${CC:-}"
if [ -z "$CC_BIN" ]; then
  for candidate in gcc clang cc; do
    if command -v "$candidate" >/dev/null 2>&1; then
      CC_BIN="$candidate"
      break
    fi
  done
fi
[ -n "$CC_BIN" ] || fail "no C compiler found - set CC, or run this from a shell that has one (on Windows, an MSYS2 or MinGW terminal)"

to_posix_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else echo "$1"; fi
}

LIB_DIR="$(to_posix_path "$TARGET/lib")"
INC_DIR="$(to_posix_path "$TARGET/include")"
PKG_CONFIG_PATH="$TARGET/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export PKG_CONFIG_PATH

PKG_CONFIG_BIN="${PKG_CONFIG:-pkg-config}"
VIPS_CFLAGS=""
VIPS_LIBS=""
if command -v "$PKG_CONFIG_BIN" >/dev/null 2>&1; then
  VIPS_CFLAGS="$("$PKG_CONFIG_BIN" --cflags vips 2>/dev/null)"
  VIPS_LIBS="$("$PKG_CONFIG_BIN" --libs vips 2>/dev/null)"
fi
if [ -z "$VIPS_CFLAGS" ] || [ -z "$VIPS_LIBS" ]; then
  # pkg-config is unavailable, or posix.sh has already removed
  # target/lib/pkgconfig: pick whichever file can actually be linked against.
  # The shipped libvips-42.dll is a runtime file and ld cannot take it with -l,
  # so import/link libraries are searched for first.
  lib_file=""
  for pattern in 'libvips.*\.dll\.a$' 'libvips.*\.so$' 'libvips.*\.dylib$' \
    'libvips.*\.a$' 'libvips.*\.so\.'
  do
    lib_file=$(ls "$TARGET/lib" 2>/dev/null | grep -E "^$pattern" | head -n 1)
    [ -n "$lib_file" ] && break
  done
  [ -n "$lib_file" ] || fail "no libvips library in $TARGET/lib to link against"
  case "$lib_file" in
    *.dll.a) link_name="${lib_file%.dll.a}" ;;
    *.dylib) link_name="${lib_file%.dylib}" ;;
    *.so) link_name="${lib_file%.so}" ;;
    *.a) link_name="${lib_file%.a}" ;;
    *) link_name="" ;;
  esac
  VIPS_CFLAGS="-I$INC_DIR -I$INC_DIR/vips"
  # vips.h includes glib, so the glib headers have to be reachable too.  The
  # artifact ships its own copy - target/include/glib-2.0 plus the generated
  # glibconfig.h under target/lib - which is exactly what vips.pc lists; when the
  # package carries no glib (posix builds link the system one), ask pkg-config.
  [ -d "$INC_DIR/glib-2.0" ] && VIPS_CFLAGS="$VIPS_CFLAGS -I$INC_DIR/glib-2.0"
  [ -d "$LIB_DIR/glib-2.0/include" ] &&
    VIPS_CFLAGS="$VIPS_CFLAGS -I$LIB_DIR/glib-2.0/include"
  if [ ! -d "$INC_DIR/glib-2.0" ] && command -v "$PKG_CONFIG_BIN" >/dev/null 2>&1; then
    VIPS_CFLAGS="$VIPS_CFLAGS $("$PKG_CONFIG_BIN" --cflags glib-2.0 gobject-2.0 2>/dev/null)"
  fi
  if [ -n "$link_name" ]; then
    # -l wants the file name without its "lib" prefix and without the suffix.
    VIPS_LIBS="-L$LIB_DIR -l${link_name#lib}"
  else
    # A versioned soname (libvips.so.42) with no unversioned link to go with it:
    # GNU ld matches the exact file name when asked as -l:name.
    VIPS_LIBS="-L$LIB_DIR -l:$lib_file"
  fi
  echo "smoke-test: pkg-config unavailable, linking against $lib_file"
fi

WORK="${TMPDIR:-${TMP:-/tmp}}"
[ -d "$WORK" ] || WORK="."
WORK="$WORK/vips-smoke-test.$$"
mkdir -p "$WORK" || fail "cannot create the work directory $WORK"
BIN="$WORK/smoke-test"
[ -n "${IS_WINDOWS:-}" ] && BIN="$BIN.exe"

CFLAGS_EXTRA=""
LDFLAGS_EXTRA="-Wl,-rpath,$LIB_DIR"
if [ -n "${IS_WINDOWS:-}" ]; then
  CFLAGS_EXTRA="-D_POSIX_C_SOURCE=200809L"
  LDFLAGS_EXTRA=""
fi

echo "smoke-test: compiling $SRC"
# The library flags have to come after the source: with an import library
# (libvips.dll.a) or a static archive, ld drops a library it saw too early and
# every vips symbol ends up undefined.
# -Wall matters here: libvips' variadic load/save calls are declared with
# __attribute__((sentinel__)), so a missing terminating NULL is a warning rather
# than a crash only when warnings are on.
if ! "$CC_BIN" $VIPS_CFLAGS $CFLAGS_EXTRA -Wall -o "$BIN" "$SRC" $VIPS_LIBS $LDFLAGS_EXTRA; then
  rm -rf "$WORK"
  fail "the smoke test did not compile against $TARGET"
fi

# --- run --------------------------------------------------------------------
if [ -n "${IS_WINDOWS:-}" ]; then
  PATH="$LIB_DIR:$PATH"
  export PATH
  RUN_WORKDIR="$WORK"
  if command -v cygpath >/dev/null 2>&1; then
    RUN_WORKDIR="$(cygpath -w "$WORK")"
  fi
elif [ -n "${IS_DARWIN:-}" ]; then
  DYLD_LIBRARY_PATH="$LIB_DIR${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  export DYLD_LIBRARY_PATH
  RUN_WORKDIR="$WORK"
else
  LD_LIBRARY_PATH="$LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export LD_LIBRARY_PATH
  RUN_WORKDIR="$WORK"
fi

echo "smoke-test: package $TARGET, preset ${PRESET:-unset}, lean ${LEAN:-unset}"
echo "smoke-test: required $(echo "$require" | tr ',' ' ')"
echo "smoke-test: trimmed  $(echo "$skip" | tr ',' ' ')"

"$BIN" --require "$require" --skip "$skip" --workdir "$RUN_WORKDIR"
status=$?

if [ "$status" -eq 0 ]; then
  rm -rf "$WORK"
else
  echo "smoke-test: the package failed, work files left in $WORK" >&2
fi

exit "$status"

