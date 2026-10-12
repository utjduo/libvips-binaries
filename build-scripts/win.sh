#!/usr/bin/env bash
set -e

## Native Windows build for libvips that links every dependency statically into
## a single self-contained DLL. Runs inside an MSYS2 shell (UCRT64 or MINGW64).
##
## Based on build/posix.sh from lovell/sharp-libvips (Apache 2.0)
## Copyright 2017 Lovell Fuller and others.
## SPDX-License-Identifier: Apache-2.0

# Dependency version numbers
if [ -f "$PWD/versions.properties" ]; then
  source "$PWD/versions.properties"
fi

PLATFORM="${PLATFORM:-win-x64}"

if [ -z "${MSYSTEM:-}" ]; then
  echo "ERROR: build-scripts/win.sh must be run from an MSYS2 shell (MSYSTEM is unset)." >&2
  exit 1
fi

MINGW_PREFIX_DIR="${MINGW_PREFIX:-/ucrt64}"
export PATH="${MINGW_PREFIX_DIR}/bin:${PATH}"

DEPS="$PWD/deps"
TARGET="$PWD/target"
PACKAGE="$PWD"
# Relocated MSYS2 files are stashed here. It must live OUTSIDE $DEPS because
# $DEPS is wiped at the start of every run, and it is moved back on exit so the
# MSYS2 installation is never permanently damaged by a local build.
IMPORT_LIBS="$PWD/.import-libs-backup"

# A run that was killed mid-way (or an older layout that kept this stash inside
# $DEPS) leaves relocated MSYS2 files behind. Put them back before wiping
# anything, otherwise a later run permanently damages the MSYS2 install.
if [ -d "$IMPORT_LIBS" ]; then
  find "$IMPORT_LIBS" -maxdepth 1 -name '*.dll.a' -exec mv -f {} "${MINGW_PREFIX_DIR}/lib/" \; 2>/dev/null || true
  if [ -d "$IMPORT_LIBS/AOM" ]; then
    mkdir -p "${MINGW_PREFIX_DIR}/lib/cmake"
    mv -f "$IMPORT_LIBS/AOM" "${MINGW_PREFIX_DIR}/lib/cmake/AOM" 2>/dev/null || true
  fi
  if [ -f "$IMPORT_LIBS/libgcc_s.a.orig" ]; then
    cp -f "$IMPORT_LIBS/libgcc_s.a.orig" "${MINGW_PREFIX_DIR}/lib/libgcc_s.a" 2>/dev/null || true
  fi
  rm -rf "$IMPORT_LIBS"
fi
rm -rf "$DEPS" "$TARGET"
mkdir -p "$DEPS" "$TARGET" "$IMPORT_LIBS"

CURL="curl --silent --location --retry 3 --retry-max-time 30"

# fetch_archive <url> <destination dir> [extra tar options]
#
# Piping $CURL straight into tar is fragile: curl without --fail writes the body of
# an error page into the pipe, tar then unpacks nothing, and the build only dies
# much later with something like
#   CMake Error: The source directory ".../deps/jpeg-xl" does not appear to contain
#   CMakeLists.txt.
# GitHub source archives also end with a harmless "A lone zero block" warning that
# makes tar exit non-zero even though everything unpacked, so the archive is fetched
# to a file first, unpacked, and the unpacked tree is verified before continuing.
fetch_archive() {
  local url="$1" dest="$2"
  shift 2
  local tmp="$DEPS/.fetch-$(basename "$url")"
  local attempt
  mkdir -p "$DEPS"
  for attempt in 1 2 3; do
    if $CURL --fail -o "$tmp" "$url"; then
      break
    fi
    echo "Warning: download failed (attempt $attempt/3): $url" >&2
    sleep 5
  done
  if [ ! -s "$tmp" ]; then
    echo "ERROR: could not download $url" >&2
    exit 1
  fi
  mkdir -p "$dest"
  # -a picks the compression from the file name; the lone-zero-block noise is
  # filtered but anything else tar reports is kept.
  tar -xaf "$tmp" -C "$dest" --strip-components=1 "$@" 2>&1 |
    grep -v -e 'lone zero block' -e 'Ignoring bad extended header' >&2 || true
  rm -f "$tmp"
  if [ ! -d "$dest" ] || [ -z "$(ls -A "$dest" 2>/dev/null)" ]; then
    echo "ERROR: $url unpacked into an empty directory: $dest" >&2
    exit 1
  fi
}

# config.guess reports the MSYS runtime as "x86_64-pc-cygwin" even in a UCRT64
# shell, which makes configure scripts take the wrong platform branches - e.g.
# libarchive then skips archive_windows.c and the finished DLL fails to link
# with undefined __la_read/__la_write/__la_dosmaperr. Pin the triple to the one
# the toolchain actually targets (cc -dumpmachine).
MINGW_HOST="$(cc -dumpmachine)"
CONFIGURE_HOST=""
case "$MINGW_HOST" in
  *mingw*) CONFIGURE_HOST="--build=$MINGW_HOST --host=$MINGW_HOST" ;;
esac

# Codec selection (shared with build-scripts/posix.sh)
source "$PWD/build-scripts/codecs.sh"

echo "Building ${PLATFORM} with MSYS2 ${MSYSTEM} (CODECS='${CODECS:-default}')"

# ---------------------------------------------------------------------------
# Install dependencies from MSYS2 packages. Unlike most distributions these
# ship both shared and static libraries, which lets us link everything into a
# single DLL.
# ---------------------------------------------------------------------------
install_pkgs() {
  if pacman -S --noconfirm --needed "$@" >/dev/null 2>&1; then
    return 0
  fi
  local pkg
  for pkg in "$@"; do
    pacman -S --noconfirm --needed "$pkg" >/dev/null 2>&1 \
      || echo "Warning: MSYS2 package not available, skipping: ${pkg}"
  done
}

PKG="${MINGW_PACKAGE_PREFIX:-mingw-w64-ucrt-x86_64}"

# Build tools: MSYS `make` (for autotools source builds) and a CMake.
# diffutils is needed by libarchive's configure script, which otherwise fails its
# internal checks with "cmp: command not found" / "diff: command not found".
install_pkgs make diffutils "${PKG}-cmake"

# Core dependencies (always included).
# libiconv: GLib links MSYS2's static libintl.a, whose gettext helpers call
# libiconv_open()/libiconv(); see the -liconv entry in VIPS_LINK_ARGS below.
install_pkgs \
  "${PKG}-glib2" \
  "${PKG}-libiconv" \
  "${PKG}-expat" \
  "${PKG}-libjpeg-turbo" \
  "${PKG}-libpng" \
  "${PKG}-libwebp" \
  "${PKG}-libheif" \
  "${PKG}-libffi" \
  "${PKG}-highway" \
  "${PKG}-zlib"

# Metadata and colour management. Small (a few hundred KB together) and every
# codec in this build stores EXIF/ICC profiles, so they are on unless something
# switches them off (FEATURES=exif=off,lcms=off).
if [ "${HAVE_EXIF}" = 1 ]; then install_pkgs "${PKG}-libexif"; fi
if [ "${HAVE_LCMS}" = 1 ]; then install_pkgs "${PKG}-lcms2"; fi

# libde265 is the HEVC *decoder* libheif uses to read .heic. Without it heifload
# is still registered but every real .heic fails with "Unsupported compression",
# which is indistinguishable from a broken build, so it stays on in every preset.
if [ "${HAVE_HEIF_DEC}" = 1 ]; then install_pkgs "${PKG}-libde265"; fi

# TIFF is part of the historical core set; LEAN=2 drops it (and with it the
# zstd/lzma/jbig/libdeflate archives MSYS2's libtiff drags in).
if [ "${HAVE_TIFF}" = 1 ]; then
  install_pkgs "${PKG}-libtiff"
fi

# The svgload stack: librsvg pulls cairo + pixman + gdk-pixbuf + libxml2, and
# cairo pulls freetype + fontconfig. Together they are ~15 MB of the DLL.
if [ "${HAVE_SVG}" = 1 ]; then
  install_pkgs "${PKG}-libxml2" "${PKG}-freetype" "${PKG}-fontconfig" \
    "${PKG}-cairo" "${PKG}-librsvg"
fi

# The textload stack: pango pulls harfbuzz + fribidi (+ graphite2, datrie, thai).
if [ "${HAVE_TEXT_STACK}" = 1 ]; then
  install_pkgs "${PKG}-fribidi" "${PKG}-harfbuzz" "${PKG}-pango"
fi

if [ "${HAVE_IMAGEQUANT}" = 1 ]; then
  install_pkgs "${PKG}-libimagequant"
fi

if [ "${HAVE_DZSAVE}" = 1 ]; then
  install_pkgs "${PKG}-libarchive"
fi

# x265 is only needed to *encode* HEVC/HEIC through libheif; HEVC *decoding*
# uses libde265, which every preset keeps. x265 alone is ~21 MB of the DLL and
# it is GPL, so it is opt-in (FEATURES=heif_enc=on, or HEIF_HEVC_ENCODER=on).
if [ "${HAVE_HEIF_ENC}" = 1 ]; then
  install_pkgs "${PKG}-x265"
fi
# MSYS2 does not package cgif, so it is built from source below (GIF *save*;
# GIF *load* uses the bundled nsgif).

# Optional codecs
if codec_on spng; then install_pkgs "${PKG}-libspng"; fi
if codec_on openjpeg; then install_pkgs "${PKG}-openjpeg2"; fi
if codec_on openexr; then install_pkgs "${PKG}-openexr"; fi
# jpeg-xl and cfitsio are built from source below (their MSYS2 static archives
# reference the hwy / curl DLL import stubs)
if codec_on jpeg-xl; then install_pkgs "${PKG}-brotli"; fi
if codec_on fftw; then install_pkgs "${PKG}-fftw"; fi
# matio is built from source below (its MSYS2 package requires shared-only hdf5)
if codec_on raw; then install_pkgs "${PKG}-libraw"; fi

# ---------------------------------------------------------------------------
# Force static linking
# ---------------------------------------------------------------------------
# MinGW's linker prefers the *.dll.a import libraries over the *.a static
# archives for `-lfoo`, so move the import libraries aside. Only the static
# archives remain and every dependency ends up inside libvips.dll.
#
# Everything relocated out of ${MINGW_PREFIX_DIR} is put in $IMPORT_LIBS and
# moved back by the EXIT trap, so the MSYS2 install is left exactly as we found
# it (a CI runner does not care, but a local build must not destroy it).
restore_msys2_prefix() {
  local rc=$?
  if [ -d "$IMPORT_LIBS" ]; then
    find "$IMPORT_LIBS" -maxdepth 1 -name '*.dll.a' -exec mv -f {} "${MINGW_PREFIX_DIR}/lib/" \; 2>/dev/null
    if [ -d "$IMPORT_LIBS/AOM" ]; then
      mkdir -p "${MINGW_PREFIX_DIR}/lib/cmake"
      mv -f "$IMPORT_LIBS/AOM" "${MINGW_PREFIX_DIR}/lib/cmake/AOM" 2>/dev/null
    fi
    if [ -f "$IMPORT_LIBS/libgcc_s.a.orig" ]; then
      cp -f "$IMPORT_LIBS/libgcc_s.a.orig" "${MINGW_PREFIX_DIR}/lib/libgcc_s.a" 2>/dev/null
    fi
    if [ -f "${MINGW_PREFIX_DIR}/lib/pkgconfig/libhwy.pc.bak" ]; then
      mv -f "${MINGW_PREFIX_DIR}/lib/pkgconfig/libhwy.pc.bak" \
           "${MINGW_PREFIX_DIR}/lib/pkgconfig/libhwy.pc" 2>/dev/null
    fi
    rm -rf "$IMPORT_LIBS"
  fi
  return $rc
}
trap restore_msys2_prefix EXIT

find "${MINGW_PREFIX_DIR}/lib" -maxdepth 1 -name '*.dll.a' -exec mv -f {} "$IMPORT_LIBS/" \; 2>/dev/null || true
if [ ! -f "${MINGW_PREFIX_DIR}/lib/libglib-2.0.a" ]; then
  echo "ERROR: static glib (libglib-2.0.a) not found; cannot build a single DLL." >&2
  exit 1
fi

# MSYS2 ships ${MINGW_PREFIX_DIR}/lib/libgcc_s.a as a dlltool *import thunk*
# (it is full of __imp_* stubs plus a `..._dll_iname` marker), not as the real
# unwinder. x265.pc lists -lgcc_s/-lgcc in Libs.private and meson resolves them
# to that archive by absolute path, so the finished DLL ends up importing
# libgcc_s_seh-1.dll - the one dependency that would have to ship next to it.
# Swap the thunk for gcc's genuine static unwinder for the duration of the
# build; the EXIT trap puts the original back.
GCCS_ARCHIVE="${MINGW_PREFIX_DIR}/lib/libgcc_s.a"
if [ -f "$GCCS_ARCHIVE" ] && grep -qa 'dll_iname' "$GCCS_ARCHIVE"; then
  mv -f "$GCCS_ARCHIVE" "$IMPORT_LIBS/libgcc_s.a.orig"
  GCC_EH="$(cc -print-file-name=libgcc_eh.a)"
  if [ -f "$GCC_EH" ]; then
    cp -f "$GCC_EH" "$GCCS_ARCHIVE"
    echo "Using gcc's static unwinder in place of the libgcc_s import thunk: $GCC_EH"
  else
    mv -f "$IMPORT_LIBS/libgcc_s.a.orig" "$GCCS_ARCHIVE"
    echo "WARNING: libgcc_eh.a not found; libvips.dll may import libgcc_s_seh-1.dll" >&2
  fi
fi

# pkg-config wrapper that always asks for the static link line
cat > "$DEPS/pkg-config-static" <<'EOF'
#!/usr/bin/env bash
if command -v pkgconf >/dev/null 2>&1; then
  exec pkgconf --static "$@"
fi
exec pkg-config --static "$@"
EOF
chmod +x "$DEPS/pkg-config-static"
export PKG_CONFIG="$DEPS/pkg-config-static"
unset PKG_CONFIG_PATH
unset PKG_CONFIG_LIBDIR

# MSYS2's libspng ships its static archive as libspng_static.a, but libspng.pc asks
# for -lspng - the import library that was just moved aside above (and which UCRT64
# does not even provide as libspng.a). Without a fix a selected "spng" codec either
# fails to link with "cannot find -lspng" or is silently dropped back to libpng.
# Publish a pkg-config override that maps both names libvips tries - it looks for
# 'spng' first, then 'libspng' (see deps/vips/meson.build) - onto the static archive.
PKG_CONFIG_OVERRIDE="$DEPS/pkgconfig-override"
if codec_on spng; then
  if [ -f "${MINGW_PREFIX_DIR}/lib/libspng_static.a" ] &&
     [ -f "${MINGW_PREFIX_DIR}/lib/pkgconfig/libspng_static.pc" ]; then
    mkdir -p "$PKG_CONFIG_OVERRIDE"
    for pc_name in spng libspng; do
      sed -e "s/^Name:.*/Name: ${pc_name} (static)/" \
        -e "s/^Description:.*/Description: PNG decoding and encoding library (static build)/" \
        "${MINGW_PREFIX_DIR}/lib/pkgconfig/libspng_static.pc" > "$PKG_CONFIG_OVERRIDE/${pc_name}.pc"
    done
    export PKG_CONFIG_PATH="$PKG_CONFIG_OVERRIDE"
    echo "Linking PNG through static libspng: $(cat "$PKG_CONFIG_OVERRIDE/libspng.pc" | grep '^Libs:' | cut -d= -f2)"
  else
    echo "Warning: libspng static archive not found; PNG will fall back to libpng" >&2
  fi
fi

# Definitions needed to consume the static libraries on Windows. Defining a
# macro that a given library does not use is harmless.
# SPNG_STATIC matters: without it spng.h expands to __declspec(dllimport), so the
# PNG code emits __imp_spng_* references and the link against libspng_static.a
# fails with "undefined reference to `__imp_spng_ctx_free'".
CPPFLAGS_DEFS="-DGLIB_STATIC_COMPILATION -DGOBJECT_STATIC_COMPILATION -DGIO_STATIC_COMPILATION -DG_MODULE_STATIC_COMPILATION"
CPPFLAGS_DEFS="${CPPFLAGS_DEFS} -DLIBXML_STATIC -DXML_STATIC -DPCRE2_STATIC -DPNG_STATIC"
CPPFLAGS_DEFS="${CPPFLAGS_DEFS} -DJXL_STATIC_DEFINE -DOPENEXR_STATIC_DEFINE -DIMATH_STATIC_DEFINE"
CPPFLAGS_DEFS="${CPPFLAGS_DEFS} -DBROTLI_STATIC_DEFINE -DTIFF_STATIC -DLIBRAW_STATIC -DSPNG_STATIC"
CPPFLAGS_DEFS="${CPPFLAGS_DEFS} -DCAIRO_WIN32_STATIC_BUILD -DLIBARCHIVE_STATIC"
export CPPFLAGS="${CPPFLAGS_DEFS}"
# Every dependency built from source (and libvips itself) is compiled at -O3 for
# speed, but with one section per function and per data object so the final link
# can discard whatever is never referenced (-Wl,--gc-sections below). MSYS2's own
# archives are not section-split, so this only trims the code we compile here -
# it is free, though: no optimisation is given up.
SECTION_FLAGS="-ffunction-sections -fdata-sections"
export CFLAGS="-O3 ${SECTION_FLAGS}"
export CXXFLAGS="-O3 ${SECTION_FLAGS}"
DEP_CFLAGS="${SECTION_FLAGS}"
DEP_CXXFLAGS="${SECTION_FLAGS}"

# ---------------------------------------------------------------------------
# Download and build libvips from source
# ---------------------------------------------------------------------------
fetch_archive "https://github.com/libvips/libvips/releases/download/v${VERSION_VIPS}/vips-${VERSION_VIPS}.tar.xz" "$DEPS/vips"
cd "$DEPS/vips"
# Disable HBR support in heifsave.
#
# This patch used to be published per release tag by libvips/build-win64-mxe, but
# upstream deleted it (2026-06-06, "aom: enable HDR support, allows bit depths of
# 10 and 12") and libvips >= 8.18 has no HBR code left in libvips/foreign/heifsave.c
# at all. Fetch it with --fail into a file instead of piping $CURL straight into
# patch: without --fail a 404 page is fed to patch as input and the build dies with
#   patch: **** Only garbage was found in the patch input.
# A patch that is missing or does not apply is a warning, not a failure.
apply_vips_heifsave_hbr_patch() {
  local patch_url="https://raw.githubusercontent.com/libvips/build-win64-mxe/v${VERSION_VIPS}/build/patches/vips-8-heifsave-disable-hbr-support.patch"
  local patch_file="$DEPS/vips-heifsave-hbr.patch"
  if ! $CURL --fail -o "$patch_file" "$patch_url" 2>/dev/null; then
    echo "heifsave HBR patch is not published for vips ${VERSION_VIPS}; nothing to patch"
    return 0
  fi
  # -N: never prompt for the reversed-patch question, which would hang a
  # non-interactive build if the patch were already applied.
  if patch -N -p1 -i "$patch_file"; then
    echo "Applied heifsave HBR patch"
  else
    echo "Warning: heifsave HBR patch does not apply to vips ${VERSION_VIPS}; skipping" >&2
  fi
  rm -f "$patch_file"
}
apply_vips_heifsave_hbr_patch
# Link libvips statically into libvips-cpp so we get a single DLL
sed -i'.bak' "s/library('vips'/static_&/" libvips/meson.build
sed -i'.bak' "/version: library_version/{N;d;}" libvips/meson.build
# Disable building man pages
sed -i'.bak' "/subdir('man')/{N;N;N;N;d;}" meson.build

# ---------------------------------------------------------------------------
# Dependencies that MSYS2 only ships in a form we cannot link statically
# ---------------------------------------------------------------------------

# libhwy is packaged with -DHWY_SHARED_DEFINE, which makes consumers reference
# the DLL import stubs. Drop it so the static archive is used.
sed -i.bak 's/ -DHWY_SHARED_DEFINE//' "${MINGW_PREFIX_DIR}/lib/pkgconfig/libhwy.pc" || true

# cgif (GIF save): not packaged by MSYS2 at all, so build it statically.
fetch_archive "https://github.com/dloebl/cgif/archive/v${VERSION_CGIF}.tar.gz" "$DEPS/cgif"
cd "$DEPS/cgif"
CFLAGS="${CFLAGS} -O3" meson setup _build --default-library=static --buildtype=release --strip --prefix="$MINGW_PREFIX_DIR" \
  -Dexamples=false -Dtests=false
meson install -C _build

# libuhdr (JPEG Ultra HDR): MSYS2 has no package for it at all, so build it
# statically from source exactly like build-scripts/posix.sh does. Without this the
# "uhdr" codec the workflow advertises as always-included is silently missing
# from the Windows build. Skipped when LEAN trims UltraHDR support.
if [ "${HAVE_UHDR}" = 1 ]; then
  fetch_archive "https://github.com/google/libultrahdr/archive/${VERSION_UHDR}.tar.gz" "$DEPS/uhdr"
  cd "$DEPS/uhdr"
  # [PATCH] Remove platform and architecture detection logic
  $CURL "https://patch-diff.githubusercontent.com/raw/google/libultrahdr/pull/383.patch" | patch -p1
  CFLAGS="${CFLAGS} -O3" CXXFLAGS="${CXXFLAGS} -O3" cmake -G"Unix Makefiles" \
    -DCMAKE_INSTALL_PREFIX="$MINGW_PREFIX_DIR" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=FALSE -DUHDR_BUILD_EXAMPLES=FALSE -DUHDR_BUILD_TESTS=FALSE \
    -DUHDR_BUILD_DEPS=FALSE -DUHDR_MAX_DIMENSION=65500
  make install/strip
  cd "$DEPS/vips"
fi

# libarchive: MSYS2's static archive references the zlib DLL import stubs, so
# build a static copy from source (dzsave support).
if [ "${HAVE_DZSAVE}" = 1 ]; then
  fetch_archive "https://github.com/libarchive/libarchive/releases/download/v${VERSION_ARCHIVE}/libarchive-${VERSION_ARCHIVE}.tar.xz" "$DEPS/archive"
  cd "$DEPS/archive"
  ./configure $CONFIGURE_HOST --prefix="$MINGW_PREFIX_DIR" --enable-static --disable-shared --disable-dependency-tracking \
    --disable-bsdtar --disable-bsdcat --disable-bsdcpio --disable-bsdunzip \
    --disable-xattr --disable-acl --disable-posix-regex-lib \
    --without-bz2lib --without-libb2 --without-iconv --without-lz4 --without-zstd --without-lzma \
    --without-lzo2 --without-cng --without-openssl --without-xml2 --without-expat
  make install-strip
  cd "$DEPS/vips"
fi

# libheif: only shipped as a shared library; build it statically (AVIF via aom).
# Its AOM CMake config points at the import library we moved aside, so set it
# aside too and let CMake fall back to pkg-config (which links libaom.a).
if [ -d "${MINGW_PREFIX_DIR}/lib/cmake/AOM" ]; then
  mv -f "${MINGW_PREFIX_DIR}/lib/cmake/AOM" "$IMPORT_LIBS/AOM"
fi

# aom is what libheif uses for AVIF. MSYS2's libaom.a is 12 MB because it is
# built with VP8/VP9 I/O (CONFIG_WEBM_IO) and 10/12-bit AV1 support
# (CONFIG_AV1_HIGHBITDEPTH), neither of which an AVIF encoder/decoder needs.
# Rebuilding it with the same switches build-scripts/posix.sh uses (MinSizeRel,
# CONFIG_WEBM_IO=0, CONFIG_AV1_HIGHBITDEPTH=0) removes roughly a third of it.
# AOM_BUILD=auto (the default) only does this for LEAN builds, where the size
# matters; AOM_BUILD=on/off forces it either way. If the source build fails the
# packaged archive is used instead so the build still finishes.
AOM_BUILD="${AOM_BUILD:-auto}"
case "$AOM_BUILD" in
  auto)
    if [ "${LEAN:-0}" -ge 1 ]; then AOM_BUILD=1; else AOM_BUILD=0; fi
    ;;
  on|true|yes|1) AOM_BUILD=1 ;;
  off|false|no|0) AOM_BUILD=0 ;;
  *)
    echo "Warning: AOM_BUILD='$AOM_BUILD' is not understood (auto/on/off); using auto" >&2
    if [ "${LEAN:-0}" -ge 1 ]; then AOM_BUILD=1; else AOM_BUILD=0; fi
    ;;
esac

build_aom_minimal() {
  local jobs
  jobs="$(nproc 2>/dev/null || echo 4)"
  # aom's x86-64 assembly is what makes AV1 fast; without nasm CMake silently
  # falls back to the C implementation.
  command -v nasm >/dev/null 2>&1 || install_pkgs "${PKG}-nasm"
  if ! command -v nasm >/dev/null 2>&1; then
    echo "Warning: nasm not available; skipping the minimal aom build (AV1 would be slow)" >&2
    return 1
  fi
  fetch_archive "https://storage.googleapis.com/aom-releases/libaom-${VERSION_AOM}.tar.gz" "$DEPS/aom"
  mkdir -p "$DEPS/aom/aom_build"
  cd "$DEPS/aom/aom_build"
  cmake -G"Unix Makefiles" \
    -DCMAKE_INSTALL_PREFIX="$MINGW_PREFIX_DIR" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DBUILD_SHARED_LIBS=FALSE -DENABLE_DOCS=0 -DENABLE_TESTS=0 -DENABLE_TESTDATA=0 \
    -DENABLE_TOOLS=0 -DENABLE_EXAMPLES=0 \
    -DCONFIG_PIC=1 -DENABLE_NASM=1 -DENABLE_RVV=0 \
    -DCONFIG_AV1_HIGHBITDEPTH=0 -DCONFIG_WEBM_IO=0 .. || return 1
  make -j"$jobs" install/strip || return 1
  cd "$DEPS/vips"
  echo "Built a minimal aom (${VERSION_AOM}, MinSizeRel, no WebM I/O, 8-bit AV1 only)"
  return 0
}

if [ "$AOM_BUILD" = 1 ] && build_aom_minimal; then
  :
elif [ "$AOM_BUILD" = 1 ]; then
  echo "Warning: the minimal aom build failed; linking MSYS2's packaged libaom.a instead" >&2
  install_pkgs "${PKG}-aom"
fi

fetch_archive "https://github.com/strukturag/libheif/archive/${VERSION_HEIF}.tar.gz" "$DEPS/heif"
cd "$DEPS/heif"
# WITH_X265 is the HEVC *encoder* (heifsave). It is the single biggest archive
# in the DLL (~21 MB) and it is GPL, so every preset except "full" switches it
# off (FEATURES=heif_enc=on brings it back). WITH_LIBDE265 is the HEVC *decoder*
# and stays on, so .heic/.h265 files still load, and WITH_AOM_* keeps AVIF
# encode + decode.
HEIF_ENCODER_FLAG=OFF
if [ "${HAVE_HEIF_ENC}" = 1 ]; then
  HEIF_ENCODER_FLAG=ON
fi
HEIF_DECODER_FLAG=OFF
if [ "${HAVE_HEIF_DEC}" = 1 ]; then
  HEIF_DECODER_FLAG=ON
fi
CFLAGS="${CFLAGS} ${DEP_CFLAGS} -DLIBDE265_STATIC_BUILD" CXXFLAGS="${CXXFLAGS} ${DEP_CXXFLAGS} -DLIBDE265_STATIC_BUILD" cmake -G"Unix Makefiles" \
  -DCMAKE_INSTALL_PREFIX="$MINGW_PREFIX_DIR" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=FALSE -DBUILD_DOCUMENTATION=0 -DBUILD_TESTING=0 -DENABLE_PLUGIN_LOADING=0 -DWITH_EXAMPLES=0 \
  -DWITH_AOM_DECODER=ON -DWITH_AOM_ENCODER=ON \
  -DWITH_LIBDE265=${HEIF_DECODER_FLAG} -DWITH_X265=${HEIF_ENCODER_FLAG} -DWITH_X264=OFF -DWITH_OpenH264_DECODER=OFF \
  -DWITH_DAV1D=OFF -DWITH_SvtEnc=OFF -DWITH_RAV1E=OFF
make install/strip

# matio (Matlab): its MSYS2 package links against shared-only hdf5, so build a
# static matio without HDF5 instead.
if codec_on matio; then
  fetch_archive "https://github.com/tbeu/matio/releases/download/v${VERSION_MATIO}/matio-${VERSION_MATIO}.tar.gz" "$DEPS/matio"
  cd "$DEPS/matio"
  ./configure $CONFIGURE_HOST --prefix="$MINGW_PREFIX_DIR" --enable-static --disable-shared --disable-dependency-tracking \
    --without-hdf5 --disable-mat73
  make install-strip
fi

# cfitsio: MSYS2's static archive references the curl DLL import stubs; build a
# static copy without curl instead.
if codec_on cfitsio; then
  fetch_archive "https://heasarc.gsfc.nasa.gov/FTP/software/fitsio/c/cfitsio-${VERSION_CFITSIO}.tar.gz" "$DEPS/cfitsio"
  cd "$DEPS/cfitsio"
  CFLAGS="${CFLAGS} -std=gnu17" ./configure $CONFIGURE_HOST --prefix="$MINGW_PREFIX_DIR" --enable-static --disable-shared --disable-dependency-tracking --disable-curl
  # the utilities (e.g. smem) need SysV shared memory, so only build the library
  make libcfitsio.la
  make install-libLTLIBRARIES install-includeHEADERS install-pkgconfigDATA
fi

# libjxl: MSYS2's libjxl_cms.a references the hwy DLL import stubs; build libjxl
# statically from source against the static highway + brotli (libhwy.pc had
# -DHWY_SHARED_DEFINE removed above).
if codec_on jpeg-xl; then
  fetch_archive "https://github.com/libjxl/libjxl/archive/v${VERSION_JPEGXL}.tar.gz" "$DEPS/jpeg-xl" \
    --exclude='*/tools/benchmark/*'
  cd "$DEPS/jpeg-xl"
  CFLAGS="${CFLAGS} -O3" CXXFLAGS="${CXXFLAGS} -O3" cmake -G"Unix Makefiles" \
    -DCMAKE_INSTALL_PREFIX="$MINGW_PREFIX_DIR" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=FALSE -DBUILD_TESTING=OFF \
    -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_JNI=OFF \
    -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_SKCMS=OFF -DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_PLUGINS=OFF \
    -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_VIEWERS=OFF -DJPEGXL_ENABLE_TCMALLOC=OFF \
    -DJPEGXL_BUNDLE_LIBPNG=OFF -DJPEGXL_FORCE_SYSTEM_BROTLI=ON -DJPEGXL_FORCE_SYSTEM_HWY=ON
  make install/strip
fi

cd "$DEPS/vips"

# Export the symbols a host needs from the DLL (GLib's g_free/g_object_unref,
# etc.) exactly as the ELF/Mach-O builds do. --export-all-symbols alone would
# exceed the 16-bit PE export ordinal limit (65535) once every codec is enabled,
# so hide every archive except the GLib family; libvips's own API is exported
# via __declspec(dllexport) regardless.
# ld's --exclude-libs takes a COLON-separated list, and it must be attached to
# the flag with '='. Writing `-Wl,--exclude-libs,a,b,c` makes the gcc driver
# split on commas, so ld receives `--exclude-libs` with a single value and then
# treats every remaining name as an input file to open:
#   ld.exe: cannot find libz.a: No such file or directory
# which meson then reports as "ERROR: Compiler cc cannot compile programs".
EXCLUDE_LIBS_LIST="$(cd "${MINGW_PREFIX_DIR}/lib" && ls *.a 2>/dev/null \
  | grep -vE '^(libglib-2\.0|libgobject-2\.0|libgio-2\.0|libgmodule-2\.0)\.a$' \
  | paste -sd: -)"
echo "Hiding $(echo "$EXCLUDE_LIBS_LIST" | tr ':' '\n' | grep -c . ) non-GLib archives from the export table"

# --exclude-libs cannot reach the GLib family, because those are the archives we
# deliberately keep exportable. gio is the problem: its Win32 objects
# (gwin32packageparser.c, gwin32file-sync-stream.c) are compiled with INITGUID,
# so they define ~750 COM GUIDs (CLSID_DOMDocument, IID_IXMLDOMDocument,
# ALL_POWERSCHEMES_GUID, ...) as plain data. --export-all-symbols then publishes
# every one of them, and the regenerated import library hands consumers an
# __imp_CLSID_* thunk for each - which collides with the definitions in
# libuuid.a for anything that also links COM code.
#
# ld's --exclude-symbols drops them from the automatic export table without
# touching the archives, but the list is ~33 KB and cannot go on a command line
# ("Argument list too long"). It is written to a linker response file instead;
# -Wl,@path keeps the '@' out of the gcc driver's own response-file expansion
# and hands it to ld untouched.
EXPORT_RSP="$PACKAGE/.ld-exports.rsp"
EXCLUDED_EXPORTS="$(for archive in libglib-2.0 libgobject-2.0 libgio-2.0 libgmodule-2.0; do
    nm -g --defined-only "${MINGW_PREFIX_DIR}/lib/${archive}.a" 2>/dev/null
  done | awk '{ print $NF }' \
  | grep -E '^(GUID_|CLSID_|DIID_|IID_|LIBID_|CATID_|SID_|PROPID_|PID_|FMTID_|NID_|LUID_|MUID_|FDD_|MIDL_|ALL_)' \
  | sort -u)"
EXCLUDED_EXPORT_COUNT="$(printf '%s\n' "$EXCLUDED_EXPORTS" | grep -c .)"
if [ "$EXCLUDED_EXPORT_COUNT" -gt 0 ]; then
  printf -- '--exclude-symbols=%s\n' "$(printf '%s\n' "$EXCLUDED_EXPORTS" | paste -sd, -)" > "$EXPORT_RSP"
  EXPORT_RSP_WIN="$(cygpath -w "$EXPORT_RSP" 2>/dev/null | sed 's|\\|/|g')"
  if [ -z "$EXPORT_RSP_WIN" ]; then
    EXPORT_RSP_WIN="$EXPORT_RSP"
  fi
  EXPORT_RSP_FLAG="-Wl,@${EXPORT_RSP_WIN}"
  case "$EXPORT_RSP_WIN" in
    *' '*)
      # ld splits response-file paths on whitespace, so a prefix containing a
      # space cannot be passed this way.
      echo "Warning: build path contains a space; COM GUID symbols will stay in the export table" >&2
      EXPORT_RSP_FLAG=""
      ;;
  esac
  if [ -n "$EXPORT_RSP_FLAG" ]; then
    echo "Hiding $EXCLUDED_EXPORT_COUNT COM GUID symbols coming from the GLib archives"
  fi
else
  EXPORT_RSP_FLAG=""
fi

# MSYS2 ships OpenEXR only as a shared library (no static archive), so it
# cannot be folded into a single self-contained DLL.
# (libheif is also shared-only, but we rebuild it statically from source below.)
WIN_UNSUPPORTED_FLAGS="-Dopenexr=disabled"
if codec_on openexr; then
  echo "Warning: 'openexr' was requested but MSYS2 ships it shared-only; it cannot be linked into a single DLL and is being disabled." >&2
fi

# libvips has exactly one PNG backend. meson only looks for spng when libpng was
# not found ("only if libpng not found" in libvips meson.build), and libpng is
# always installed here, so asking for the "spng" codec did nothing at all: the
# DLL kept the libpng backend and neither HAVE_SPNG nor pngspngload was built.
# Honour the selection by switching libvips over to the spng backend.
PNG_BACKEND_FLAGS=""
PNG_WRAPPER_LINK_ARGS=""
if codec_on spng; then
  # -Dspng=enabled makes libspng a hard requirement: without it meson treats it as
  # optional and a missing libspng would leave the finished DLL with no PNG support
  # at all, because libpng was switched off.
  PNG_BACKEND_FLAGS="-Dpng=disabled -Dspng=enabled"
  # libvips has exactly one PNG backend. meson only looks for spng when libpng was
  # not found ("only if libpng not found" in libvips meson.build), and libpng is
  # always installed here, so asking for the "spng" codec did nothing at all: the
  # DLL kept the libpng backend and neither HAVE_SPNG nor the spng classes were
  # built. Honour the selection by switching libvips over to the spng backend.
  echo "PNG backend: libspng (libpng is disabled for this build - libvips links one PNG backend at a time)"
  # The vips_pngload()/vips_pngsave() convenience wrappers live in pngload.c and
  # pngsave.c *outside* their #ifdef HAVE_PNG blocks, so they are compiled even
  # though the libpng classes are not - but nothing else in the DLL references
  # them, so -Wl,--gc-sections discards them and a consumer that calls
  # vips_pngsave() gets "undefined reference to `vips_pngsave'". Naming them as
  # undefined symbols makes ld pull those objects out of the archive and keep
  # them, so the spng DLL exports the same C API as the libpng one.
  PNG_WRAPPER_LINK_ARGS=",'-Wl,--undefined=vips_pngload','-Wl,--undefined=vips_pngload_buffer','-Wl,--undefined=vips_pngload_source','-Wl,--undefined=vips_pngsave','-Wl,--undefined=vips_pngsave_buffer','-Wl,--undefined=vips_pngsave_target'"
  echo "PNG wrappers: forcing vips_pngload()/vips_pngsave() into the export table"
fi

# cgifsave.c is only compiled when the quantiser is available, and nothing else
# in the DLL calls vips_gifsave(), so the same gc-sections argument applies:
# name the gif writers explicitly so a trimmed-but-quantised build still exports
# them. HEVC/AVIF, JXL and JPEG 2000 wrappers are already pulled in by the
# heif/jxl/jp2k classes and need nothing extra.
WRAPPER_LINK_ARGS="${PNG_WRAPPER_LINK_ARGS}"
if [ "${HAVE_IMAGEQUANT}" = 1 ]; then
  WRAPPER_LINK_ARGS="${WRAPPER_LINK_ARGS},'-Wl,--undefined=vips_gifsave','-Wl,--undefined=vips_gifsave_buffer','-Wl,--undefined=vips_gifsave_target'"
fi


# Meson receives the link flags as one array; the response-file reference is only
# appended when there is something to hide, so an empty element never ends up in
# the link command.
#
# -liconv: GLib links MSYS2's static libintl.a, whose gettext helpers call
# libiconv_open()/libiconv(). A full build gets that archive from the pango /
# fontconfig / cairo link lines; a trimmed (LEAN) build has nothing left to drag
# it in, so it must be named explicitly - without it the link stops with
# "undefined reference to `libiconv_open'".
ICONV_LINK_ARG=""
if [ -f "${MINGW_PREFIX_DIR}/lib/libiconv.a" ]; then
  ICONV_LINK_ARG=",'-liconv'"
fi
VIPS_LINK_ARGS="'-Wl,--allow-multiple-definition','-static-libgcc','-Wl,--export-all-symbols','-Wl,--gc-sections'${ICONV_LINK_ARG}${WRAPPER_LINK_ARGS},'-Wl,--exclude-libs=$EXCLUDE_LIBS_LIST'"
if [ -n "$EXPORT_RSP_FLAG" ]; then
  VIPS_LINK_ARGS="$VIPS_LINK_ARGS,'$EXPORT_RSP_FLAG'"
fi

meson setup _build --default-library=shared --buildtype=release --strip --prefix="$TARGET" \
  -Ddeprecated=false -Dexamples=false -Dintrospection=disabled -Dmodules=disabled \
  "-Dc_link_args=[$VIPS_LINK_ARGS]" \
  "-Dcpp_link_args=[$VIPS_LINK_ARGS]" \
  ${VIPS_CODEC_FLAGS_AUTO} ${WIN_UNSUPPORTED_FLAGS} ${PNG_BACKEND_FLAGS}
meson install -C _build
# ---------------------------------------------------------------------------
# Collect the single DLL and its import library
# ---------------------------------------------------------------------------
cd "$TARGET"
VIPS_DLL="$(find bin lib -maxdepth 1 -name 'libvips-cpp-*.dll' 2>/dev/null | head -n1)"
if [ -z "$VIPS_DLL" ]; then
  VIPS_DLL="$(find bin lib -maxdepth 1 -name 'libvips-*.dll' 2>/dev/null | head -n1)"
fi
if [ -z "$VIPS_DLL" ]; then
  echo "ERROR: could not locate the built libvips DLL." >&2
  find bin lib -maxdepth 2 -type f | sort >&2
  exit 1
fi
VIPS_IMPLIB="$(find lib bin -maxdepth 1 -name 'libvips-cpp.dll.a' 2>/dev/null | head -n1)"
if [ -z "$VIPS_IMPLIB" ]; then
  VIPS_IMPLIB="$(find lib bin -maxdepth 1 -name 'libvips.dll.a' 2>/dev/null | head -n1)"
fi
[ -n "$VIPS_IMPLIB" ] && VIPS_IMPLIB="$TARGET/${VIPS_IMPLIB#./}"

mkdir -p "$TARGET/lib"
mv -f "$VIPS_DLL" "$TARGET/lib/libvips-42.dll"

# ld's import library names libvips-cpp-42.dll, which no longer exists after the
# rename above, so it has to be rebuilt against the shipped DLL. That library is
# also the only reliable record of which exports are DATA (vtables, typeinfo,
# exported globals) - getting that wrong makes consumers segfault the first time
# they touch a vips::VOption. See build-scripts/gen-implib.sh for the details.
if [ -n "$VIPS_IMPLIB" ] && [ -f "$VIPS_IMPLIB" ]; then
  echo "Regenerating the import library for libvips-42.dll..."
  REF_IMPLIB="$TARGET/.libvips-implib-reference.a"
  mv -f "$VIPS_IMPLIB" "$REF_IMPLIB"
  bash "$PACKAGE/build-scripts/gen-implib.sh" \
    "$TARGET/lib/libvips-42.dll" "$TARGET/lib/libvips.dll.a" \
    "libvips-42.dll" "$REF_IMPLIB"
  rm -f "$REF_IMPLIB"
else
  echo "Warning: no import library was produced by the build; consumers linking" \
    "against libvips with GCC will not get libvips.dll.a." >&2
fi

# The pkg-config files meson generated describe the build tree, not the
# package: vips-cpp.pc asks for -lvips-cpp (an import library that no longer
# exists) and both list every dependency as a public Requires, so a consumer
# that does not have all those development packages installed cannot even run
# `pkg-config --cflags vips`. Everything those dependencies provide is already
# inside libvips-42.dll and re-exported through libvips.dll.a, so the package
# only ever needs -lvips.
VIPS_PC_VERSION="$(sed -n 's/^Version:[[:space:]]*//p' "$TARGET/lib/pkgconfig/vips.pc" | head -n1)"
if [ -z "$VIPS_PC_VERSION" ]; then
  VIPS_PC_VERSION="0.0.0"
fi
# The prefix is derived from ${pcfiledir} rather than baked in as an absolute
# path: the tarball has to keep working after the user unpacks it somewhere
# else. pkgconf (>= 0.29) expands ${pcfiledir} to the directory holding the .pc
# file and normalises the '..' segments, and on Windows it emits forward-slash
# drive paths, which both pkgconf and GCC accept.
cat > "$TARGET/lib/pkgconfig/vips.pc" <<EOF
prefix=\${pcfiledir}/../..
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: vips
Description: Image processing library (self-contained build)
Version: $VIPS_PC_VERSION
Libs: -L\${libdir} -lvips
Libs.private: -lstdc++ -lm
Cflags: -I\${includedir} -I\${includedir}/glib-2.0 -I\${libdir}/glib-2.0/include
EOF
cat > "$TARGET/lib/pkgconfig/vips-cpp.pc" <<EOF
prefix=\${pcfiledir}/../..
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: vips-cpp
Description: C++ API for vips8 image processing library
Version: $VIPS_PC_VERSION
Requires: vips
EOF

# libvips.a is the intermediate static archive from the link step. It cannot be
# linked on its own (none of its dependencies are shipped) and sitting next to
# libvips.dll.a only invites mistakes, so it is not part of the package.
rm -f "$TARGET/lib/libvips.a"

# Bundle the GLib headers (libvips' public headers include glib) plus the
# generated glibconfig.h
rm -rf "$TARGET/include/glib-2.0" "$TARGET/lib/glib-2.0"
cp -r "${MINGW_PREFIX_DIR}/include/glib-2.0" "$TARGET/include/"
if [ -d "${MINGW_PREFIX_DIR}/lib/glib-2.0" ]; then
  cp -r "${MINGW_PREFIX_DIR}/lib/glib-2.0" "$TARGET/lib/"
fi

# ---------------------------------------------------------------------------
# versions.json
# ---------------------------------------------------------------------------
VERSIONS_JSON=""
VERSIONS_SEP=""
add_version() {
  VERSIONS_JSON="${VERSIONS_JSON}${VERSIONS_SEP}  \"$1\": \"$2\""
  VERSIONS_SEP=",
"
}
add_version vips "${VERSION_VIPS}"
add_pkg_version() {
  # add_pkg_version <reported name> <pacman package suffix>
  local ver
  ver="$(pacman -Q "${PKG}-$2" 2>/dev/null | awk '{print $2}')"
  ver="${ver%-*}"
  if [ -n "$ver" ]; then
    add_version "$1" "$ver"
  fi
}
# Core dependencies: always linked into the DLL.
for spec in \
  glib:glib2 expat:expat mozjpeg:libjpeg-turbo webp:libwebp heif:libheif \
  ffi:libffi highway:highway zlib:zlib
do
  add_pkg_version "${spec%%:*}" "${spec#*:}"
done
# The features the preset can trim are reported only when this build really
# linked them. pacman keeps answering for packages an earlier full build
# installed, so an ungated loop advertises rsvg/pango/tiff versions that are not
# in the DLL.
if [ "${HAVE_EXIF}" = 1 ]; then add_pkg_version exif libexif; fi
if [ "${HAVE_LCMS}" = 1 ]; then add_pkg_version lcms lcms2; fi
if [ "${HAVE_HEIF_DEC}" = 1 ]; then add_pkg_version de265 libde265; fi
if [ "${HAVE_HEIF_ENC}" = 1 ]; then add_pkg_version x265 x265; fi
if [ "${HAVE_TIFF}" = 1 ]; then add_pkg_version tiff libtiff; fi
if [ "${HAVE_SVG}" = 1 ]; then
  for spec in xml2:libxml2 freetype:freetype fontconfig:fontconfig \
    cairo:cairo rsvg:librsvg
  do
    add_pkg_version "${spec%%:*}" "${spec#*:}"
  done
fi
if [ "${HAVE_TEXT_STACK}" = 1 ]; then
  for spec in fribidi:fribidi harfbuzz:harfbuzz pango:pango
  do
    add_pkg_version "${spec%%:*}" "${spec#*:}"
  done
fi
if [ "${HAVE_IMAGEQUANT}" = 1 ]; then add_pkg_version imagequant libimagequant; fi
if [ "${HAVE_DZSAVE}" = 1 ]; then add_pkg_version archive libarchive; fi
# The feature set itself, so a consumer - and build-scripts/smoke-test.sh - can
# tell which formats are missing on purpose without re-running the build.
add_version preset "${PRESET:-full}"
add_version lean "${LEAN:-0}"
add_version features "${FEATURES:-}"
add_version cgif "${VERSION_CGIF}"
# PNG: libvips links a single PNG backend, so report whichever one was configured.
if codec_on spng; then
  add_pkg_version spng libspng
else
  add_pkg_version png libpng
fi
# Optional codecs: report only the ones this build actually enabled. Querying
# every package the script knows about advertises versions for libraries that are
# not in the DLL at all whenever an unrelated build installed them on this machine
# (openexr/fftw/cfitsio/matio/raw used to appear even when they were disabled).
# openexr is left out entirely because build-scripts/win.sh always disables it.
for spec in openjpeg:openjpeg2 jpeg-xl:libjxl fftw:fftw cfitsio:cfitsio matio:matio raw:libraw
do
  if codec_on "${spec%%:*}"; then
    add_pkg_version "${spec%%:*}" "${spec#*:}"
  fi
done
printf "{\n%s\n}\n" "$VERSIONS_JSON" > "$TARGET/versions.json"

# Add third-party notices (prefer the copy in this repo; --fail so a 404 cannot
# silently land up as a bogus THIRD-PARTY-NOTICES.md inside the artifact)
cd "$TARGET"
if [ -f "$PACKAGE/THIRD-PARTY-NOTICES.md" ]; then
  cp "$PACKAGE/THIRD-PARTY-NOTICES.md" THIRD-PARTY-NOTICES.md
else
  $CURL --fail -O https://raw.githubusercontent.com/CodeWithKyrian/libvips-binaries/main/THIRD-PARTY-NOTICES.md \
    || echo "Warning: could not fetch THIRD-PARTY-NOTICES.md" >&2
fi

# ---------------------------------------------------------------------------
# Smoke test the package that was just built.
#
# build-scripts/smoke-test.sh compiles build-scripts/smoke-test.c against
# target/lib/pkgconfig/vips.pc and runs it with target/lib on PATH, so this
# checks the shipped DLL rather than the one in deps/vips/_build. It also reads
# the "lean" entry from versions.json, so formats LEAN trimmed on purpose are
# reported as trimmed instead of failing the build. Set SMOKE_TEST=0 to skip it.
# ---------------------------------------------------------------------------
if [ "${SMOKE_TEST:-1}" != 0 ]; then
  echo "Smoke testing the package in $TARGET..."
  if ! bash "$PACKAGE/build-scripts/smoke-test.sh" ${CODECS}; then
    echo "ERROR: the smoke test failed - the library in $TARGET is not usable." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Create the tarball
# ---------------------------------------------------------------------------
echo "Single library: $(ls -l "$TARGET/lib/libvips-42.dll")"
tar czf "$PACKAGE/libvips-${PLATFORM}.tar.gz" \
  include \
  lib \
  versions.json \
  THIRD-PARTY-NOTICES.md
