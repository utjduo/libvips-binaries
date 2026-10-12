#!/usr/bin/env bash
set -e

## Based on posix.sh from lovell/sharp-libvips (Apache 2.0)
## Copyright 2017 Lovell Fuller and others.
## SPDX-License-Identifier: Apache-2.0

# Dependency version numbers
if [ -f /packaging/versions.properties ]; then
  source /packaging/versions.properties
fi

# Remove patch version component
without_patch() {
  echo "${1%.[[:digit:]]*}"
}
# Remove prerelease suffix
without_prerelease() {
  echo "${1%-[[:alnum:]]*}"
}

# Environment / working directories
case ${PLATFORM} in
  linux*)
    LINUX=true
    DEPS=/deps
    TARGET=/target
    PACKAGE=/packaging
    ROOT=/root
    VIPS_CPP_DEP=libvips-cpp.so.$(without_prerelease $VERSION_VIPS)
    ;;
  darwin*)
    DARWIN=true
    DEPS=$PWD/deps
    TARGET=$PWD/target
    PACKAGE=$PWD
    ROOT=$PWD/platforms/$PLATFORM
    VIPS_CPP_DEP=libvips-cpp.$(without_prerelease $VERSION_VIPS).dylib
    ;;
esac

mkdir ${DEPS}
mkdir ${TARGET}

# Default optimisation level is for binary size (-Os)
# Overridden to performance (-O3) for select dependencies that benefit
export FLAGS+=" -Os -fPIC"

# Remove async exception unwind/backtrace tables
# Allow linker to remove unused sections
if [ "$LINUX" = true ]; then
  export FLAGS+=" -fno-asynchronous-unwind-tables -ffunction-sections -fdata-sections"
fi

# Common build paths and flags
export PKG_CONFIG_LIBDIR="${TARGET}/lib/pkgconfig"
export PATH="${PATH}:${TARGET}/bin"
export LD_LIBRARY_PATH="${TARGET}/lib"
export CFLAGS="${FLAGS}"
export CXXFLAGS="${FLAGS}"
export OBJCFLAGS="${FLAGS}"
export OBJCXXFLAGS="${FLAGS}"
export CPPFLAGS="-I${TARGET}/include"
export LDFLAGS="-L${TARGET}/lib"

# On Linux, we need to create a relocatable library
# Note: this is handled for macOS using the `install_name_tool` (see below)
if [ "$LINUX" = true ]; then
  export LDFLAGS+=" -Wl,--gc-sections -Wl,-rpath=\$ORIGIN/"
fi

if [ "$DARWIN" = true ]; then
  # Let macOS linker remove unused code
  export LDFLAGS+=" -Wl,-dead_strip"
  # Local rust installation
  export CARGO_HOME="${DEPS}/cargo"
  export RUSTUP_HOME="${DEPS}/rustup"
  mkdir -p $CARGO_HOME
  mkdir -p $RUSTUP_HOME
  export PATH="${CARGO_HOME}/bin:${PATH}"
fi

# Run as many parallel jobs as there are available CPU cores
if [ "$LINUX" = true ]; then
  export MAKEFLAGS="-j$(nproc)"
elif [ "$DARWIN" = true ]; then
  export MAKEFLAGS="-j$(sysctl -n hw.logicalcpu)"
fi

# Expose target sysroot to CMake
export TARGET_SYSROOT="${TARGET}"

# Optimise Rust code for binary size
export CARGO_PROFILE_RELEASE_DEBUG=false
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
export CARGO_PROFILE_RELEASE_INCREMENTAL=false
export CARGO_PROFILE_RELEASE_LTO=true
export CARGO_PROFILE_RELEASE_OPT_LEVEL=z
export CARGO_PROFILE_RELEASE_PANIC=abort

# Ensure Cargo build path prefixes are removed from the resulting binaries
# https://reproducible-builds.org/docs/build-path/
export RUSTFLAGS+=" --remap-path-prefix=$CARGO_HOME/registry/="

# We don't want to use any native libraries, so unset PKG_CONFIG_PATH
unset PKG_CONFIG_PATH

# Common options for curl
CURL="curl --silent --location --retry 3 --retry-max-time 30"

# Codec selection (shared with the Windows build)
source "${PACKAGE}/build-scripts/codecs.sh"
echo "libvips codec flags:${VIPS_CODEC_FLAGS}"

# PRESET (and its numeric alias LEAN) trims the heavyweight optional features
# (svgload, textload, UltraHDR, dzsave, the quantiser, TIFF, the HEVC encoder).
# HAVE_* / NEED_VECTOR_TEXT tell the dependency builders below whether a library
# is worth downloading and building at all - libvips would not link it either
# way, but building it costs several minutes.
NEED_VECTOR_TEXT=0
if [ "${HAVE_SVG}" = 1 ] || [ "${HAVE_TEXT_STACK}" = 1 ]; then
  NEED_VECTOR_TEXT=1
fi

# Download and build dependencies from source

if [ "$DARWIN" = true ] && [ "${HAVE_SVG}" = 1 ]; then
  # Rust + cargo-c are only here to build librsvg; a trimmed build does not need them.
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path --profile minimal --default-toolchain nightly
  export RUSTFLAGS+=" -Zlocation-detail=none -Zfmt-debug=none"
  CFLAGS= cargo install cargo-c --locked
fi

if [ "${PLATFORM%-*}" == "linuxmusl" ] || [ "$DARWIN" = true ]; then
  # musl and macOS requires the standalone intl support library of gettext, since it's not provided by libc (like GNU).
  # We use a stub version of gettext instead, since we don't need any of the i18n features.
  mkdir ${DEPS}/proxy-libintl
  $CURL https://github.com/frida/proxy-libintl/archive/${VERSION_PROXY_LIBINTL}.tar.gz | tar xzC ${DEPS}/proxy-libintl --strip-components=1
  cd ${DEPS}/proxy-libintl
  meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON}
  meson install -C _build --tag devel
fi

mkdir ${DEPS}/zlib-ng
$CURL https://github.com/zlib-ng/zlib-ng/archive/${VERSION_ZLIB_NG}.tar.gz | tar xzC ${DEPS}/zlib-ng --strip-components=1
cd ${DEPS}/zlib-ng
CFLAGS="${CFLAGS} -O3" cmake -G"Unix Makefiles" \
  -DCMAKE_TOOLCHAIN_FILE=${ROOT}/Toolchain.cmake -DCMAKE_INSTALL_PREFIX=${TARGET} -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=FALSE -DBUILD_TESTING=FALSE -DZLIB_COMPAT=TRUE -DWITH_ARMV6=FALSE
make install/strip

mkdir ${DEPS}/ffi
$CURL https://github.com/libffi/libffi/releases/download/v${VERSION_FFI}/libffi-${VERSION_FFI}.tar.gz | tar xzC ${DEPS}/ffi --strip-components=1
cd ${DEPS}/ffi
./configure --host=${CHOST} --prefix=${TARGET} --enable-static --disable-shared --disable-dependency-tracking \
  --disable-builddir --disable-multi-os-directory --disable-raw-api --disable-structs --disable-docs
make install-strip

mkdir ${DEPS}/glib
$CURL https://download.gnome.org/sources/glib/$(without_patch $VERSION_GLIB)/glib-${VERSION_GLIB}.tar.xz | tar xJC ${DEPS}/glib --strip-components=1
cd ${DEPS}/glib
$CURL https://gist.github.com/kleisauke/284d685efa00908da99ea6afbaaf39ae/raw/bdad5489a61c217850631571caf57f5db6ea8b2c/glib-without-gregex.patch | patch -p1
meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} --datadir=${TARGET}/share ${MESON} \
  --force-fallback-for=gvdb -Dintrospection=disabled -Dnls=disabled -Dlibmount=disabled -Dsysprof=disabled -Dlibelf=disabled \
  -Dtests=false -Dglib_assert=false -Dglib_checks=false -Dglib_debug=disabled ${DARWIN:+-Dbsymbolic_functions=false}
# bin-devel is needed for glib-mkenums
meson install -C _build --tag bin-devel,devel

mkdir ${DEPS}/xml2
$CURL https://download.gnome.org/sources/libxml2/$(without_patch $VERSION_XML2)/libxml2-${VERSION_XML2}.tar.xz | tar xJC ${DEPS}/xml2 --strip-components=1
cd ${DEPS}/xml2
meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON} \
  -Dminimum=true
meson install -C _build --tag devel

if [ "${HAVE_EXIF}" = 1 ]; then
  mkdir ${DEPS}/exif
  $CURL https://github.com/libexif/libexif/releases/download/v${VERSION_EXIF}/libexif-${VERSION_EXIF}.tar.xz | tar xJC ${DEPS}/exif --strip-components=1
  cd ${DEPS}/exif
  ./configure --host=${CHOST} --prefix=${TARGET} --enable-static --disable-shared --disable-dependency-tracking \
    --disable-nls --disable-docs --without-libiconv-prefix --without-libintl-prefix \
    CPPFLAGS="${CPPFLAGS} -DNO_VERBOSE_TAG_DATA"
  make install-strip doc_DATA=
fi

if [ "${HAVE_LCMS}" = 1 ]; then
  mkdir ${DEPS}/lcms
  $CURL https://github.com/mm2/Little-CMS/releases/download/lcms${VERSION_LCMS}/lcms2-${VERSION_LCMS}.tar.gz | tar xzC ${DEPS}/lcms --strip-components=1
  cd ${DEPS}/lcms
  CFLAGS="${CFLAGS} -O3" meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON} \
    -Dtests=disabled
  meson install -C _build --tag devel
fi

mkdir ${DEPS}/aom
$CURL https://storage.googleapis.com/aom-releases/libaom-${VERSION_AOM}.tar.gz | tar xzC ${DEPS}/aom --strip-components=1
cd ${DEPS}/aom
mkdir aom_build
cd aom_build
AOM_AS_FLAGS="${FLAGS}" cmake -G"Unix Makefiles" \
  -DCMAKE_TOOLCHAIN_FILE=${ROOT}/Toolchain.cmake -DCMAKE_INSTALL_PREFIX=${TARGET} -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=MinSizeRel \
  -DBUILD_SHARED_LIBS=FALSE -DENABLE_DOCS=0 -DENABLE_TESTS=0 -DENABLE_TESTDATA=0 -DENABLE_TOOLS=0 -DENABLE_EXAMPLES=0 \
  -DCONFIG_PIC=1 -DENABLE_NASM=1 ${WITHOUT_NEON:+-DENABLE_NEON=0} -DENABLE_RVV=0 \
  -DCONFIG_AV1_HIGHBITDEPTH=0 -DCONFIG_WEBM_IO=0 \
  ..
make install/strip

# HEVC needs two plugins in libheif: libde265 decodes, x265 encodes. Without
# libde265 libheif still registers heifload, so AVIF works, but reading a real
# .heic fails with "Unsupported compression" - indistinguishable from a broken
# build - so the decoder stays on in every preset. x265 is ~21 MB and GPL, so
# only the "full" preset builds it (FEATURES=heif_enc=on brings it back).
HEIF_DECODER=0
if [ "${HAVE_HEIF_DEC}" = 1 ]; then
  mkdir ${DEPS}/de265
  $CURL https://github.com/strukturag/libde265/releases/download/v${VERSION_DE265}/libde265-${VERSION_DE265}.tar.gz | tar xzC ${DEPS}/de265 --strip-components=1
  if ( cd ${DEPS}/de265 && cmake -G"Unix Makefiles" \
      -DCMAKE_TOOLCHAIN_FILE=${ROOT}/Toolchain.cmake -DCMAKE_INSTALL_PREFIX=${TARGET} -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=MinSizeRel \
      -DBUILD_SHARED_LIBS=FALSE -DENABLE_DECODER=0 -DENABLE_ENCODER=0 -DENABLE_SHERLOCK265=0 -DENABLE_INTERNAL_DEVELOPMENT_TOOLS=0 \
      -DENABLE_SDL=0 -DWITH_FUZZERS=0 ${WITHOUT_NEON:+-DENABLE_SIMD=0} . && \
      make install/strip ); then
    HEIF_DECODER=1
  else
    echo "Warning: libde265 ${VERSION_DE265} failed to build; .heic/.h265 files will not load" >&2
    FEATURES="$(printf '%s' "${FEATURES}" | sed 's/heif_dec=on/heif_dec=off/')"
  fi
fi
HEIF_ENCODER=0
if [ "${HAVE_HEIF_ENC}" = 1 ]; then
  # x265 is never built from source here: it is a large GPL-2.0-or-later C++
  # library and only the untrimmed "full" preset asks for it. Use the one the
  # image already provides when there is one, and say so when there is not,
  # rather than letting libheif's configure step fail on a missing dependency.
  if $PKG_CONFIG --exists x265 2>/dev/null; then
    HEIF_ENCODER=1
  else
    echo "Warning: x265 is not available on this build host; .heic/.h265 cannot be written" >&2
    FEATURES="$(printf '%s' "${FEATURES}" | sed 's/heif_enc=on/heif_enc=off/')"
  fi
fi

mkdir ${DEPS}/heif
$CURL https://github.com/strukturag/libheif/archive/${VERSION_HEIF}.tar.gz | tar xzC ${DEPS}/heif --strip-components=1
cd ${DEPS}/heif
CFLAGS="${CFLAGS} -O3" CXXFLAGS="${CXXFLAGS} -O3" cmake -G"Unix Makefiles" \
  -DCMAKE_TOOLCHAIN_FILE=${ROOT}/Toolchain.cmake -DCMAKE_INSTALL_PREFIX=${TARGET} -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=FALSE -DBUILD_DOCUMENTATION=0 -DBUILD_TESTING=0 -DENABLE_PLUGIN_LOADING=0 -DWITH_EXAMPLES=0 -DWITH_LIBDE265=${HEIF_DECODER} -DWITH_X265=${HEIF_ENCODER}
make install/strip

mkdir ${DEPS}/jpeg
$CURL https://github.com/mozilla/mozjpeg/archive/${VERSION_MOZJPEG}.tar.gz | tar xzC ${DEPS}/jpeg --strip-components=1
cd ${DEPS}/jpeg
# [PATCH] fix: use saturating arithmetic in SIMD FDCT to prevent overflow
$CURL https://github.com/mozilla/mozjpeg/commit/f90668e0e4fb79c81e1f24a0ccc0e2090af761bf.patch | patch -p1
# Use libjpeg-turbo behaviour by default
sed -i'.bak' 's/JCP_MAX_COMPRESSION/JCP_FASTEST/' jcapimin.c
cmake -G"Unix Makefiles" \
  -DCMAKE_TOOLCHAIN_FILE=${ROOT}/Toolchain.cmake -DCMAKE_INSTALL_PREFIX=${TARGET} -DCMAKE_INSTALL_LIBDIR:PATH=lib -DCMAKE_BUILD_TYPE=MinSizeRel \
  -DBUILD_SHARED_LIBS=FALSE -DWITH_JPEG8=1 -DWITH_TURBOJPEG=FALSE -DPNG_SUPPORTED=FALSE
make install/strip

mkdir ${DEPS}/png
$CURL https://github.com/pnggroup/libpng/archive/v${VERSION_PNG}.tar.gz | tar xzC ${DEPS}/png --strip-components=1
cd ${DEPS}/png
./configure --host=${CHOST} --prefix=${TARGET} --enable-static --disable-shared --disable-dependency-tracking \
  --disable-tools --without-binconfigs --disable-unversioned-libpng-config
make install-strip dist_man_MANS=

if [ "${HAVE_IMAGEQUANT}" = 1 ]; then
  mkdir ${DEPS}/imagequant
  $CURL https://github.com/lovell/libimagequant/archive/v${VERSION_IMAGEQUANT}.tar.gz | tar xzC ${DEPS}/imagequant --strip-components=1
  cd ${DEPS}/imagequant
  CFLAGS="${CFLAGS} -O3" meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON}
  meson install -C _build --tag devel
fi

mkdir ${DEPS}/webp
$CURL https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${VERSION_WEBP}.tar.gz | tar xzC ${DEPS}/webp --strip-components=1
cd ${DEPS}/webp
./configure --host=${CHOST} --prefix=${TARGET} --enable-static --disable-shared --disable-dependency-tracking \
  --enable-libwebpmux --enable-libwebpdemux ${WITHOUT_NEON:+--disable-neon}
make install-strip bin_PROGRAMS= noinst_PROGRAMS= man_MANS=

if [ "${HAVE_TIFF}" = 1 ]; then
  mkdir ${DEPS}/tiff
  $CURL https://gitlab.com/libtiff/libtiff/-/archive/${VERSION_TIFF}/libtiff-${VERSION_TIFF}.tar.gz | tar xzC ${DEPS}/tiff --strip-components=1
  cd ${DEPS}/tiff
  cmake -G"Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE=${ROOT}/Toolchain.cmake -DCMAKE_INSTALL_PREFIX=${TARGET} -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DBUILD_SHARED_LIBS=FALSE -DCMath_HAVE_LIBC_POW=1 \
    -Dtiff-contrib=OFF -Dtiff-cxx=OFF -Dtiff-docs=OFF -Dtiff-tests=OFF -Dtiff-tools=OFF -Dmdi=OFF \
    -Djbig=OFF -Dlerc=OFF -Dlibdeflate=OFF -Dlzma=OFF -Dold-jpeg=OFF -Dpixarlog=OFF -Dtiff-opengl=OFF -Dzstd=OFF
  make install/strip
fi

if [ -z "$WITHOUT_HIGHWAY" ] || codec_on jpeg-xl; then
  mkdir ${DEPS}/highway
  $CURL https://github.com/google/highway/archive/${VERSION_HIGHWAY}.tar.gz | tar xzC ${DEPS}/highway --strip-components=1
  cd ${DEPS}/highway
  CFLAGS="${CFLAGS} -O3" CXXFLAGS="${CXXFLAGS} -O3" cmake -G"Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE=${ROOT}/Toolchain.cmake -DCMAKE_INSTALL_PREFIX=${TARGET} -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=FALSE -DBUILD_TESTING=0 -DHWY_ENABLE_CONTRIB=0 -DHWY_ENABLE_EXAMPLES=0 -DHWY_ENABLE_TESTS=0
  make install/strip
fi

build_freetype() {
  rm -rf ${DEPS}/freetype
  mkdir ${DEPS}/freetype
  $CURL https://github.com/freetype/freetype/archive/VER-${VERSION_FREETYPE//./-}.tar.gz | tar xzC ${DEPS}/freetype --strip-components=1
  cd ${DEPS}/freetype
  meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON} \
    -Dzlib=enabled -Dpng=enabled -Dbrotli=disabled -Dbzip2=disabled "$@"
  meson install -C _build --tag devel
}
# expat is *not* part of the vector/text stack: libvips has required it since
# 8.18 (dependency('expat') in the top-level meson.build, used by libvips/vips.c
# to parse XML metadata). posix builds resolve every dependency out of
# ${TARGET}/lib/pkgconfig (PKG_CONFIG_LIBDIR above, with PKG_CONFIG_PATH unset),
# so a system expat is invisible here and a trimmed build used to fail at
#   Run-time dependency expat found: NO (tried pkgconfig)
# It must therefore be built even when svgload and textload are trimmed.
mkdir ${DEPS}/expat
$CURL https://github.com/libexpat/libexpat/releases/download/R_${VERSION_EXPAT//./_}/expat-${VERSION_EXPAT}.tar.xz | tar xJC ${DEPS}/expat --strip-components=1
cd ${DEPS}/expat
./configure --host=${CHOST} --prefix=${TARGET} --enable-static --disable-shared \
  --disable-dependency-tracking --without-xmlwf --without-docbook --without-getrandom --without-sys-getrandom \
  --without-libbsd --without-examples --without-tests
make install-strip dist_cmake_DATA= nodist_cmake_DATA=
if [ ! -f "${TARGET}/lib/pkgconfig/expat.pc" ]; then
  echo "ERROR: expat.pc was not installed into ${TARGET}/lib/pkgconfig; libvips needs dependency('expat')." >&2
  exit 1
fi

# freetype, fontconfig, harfbuzz, graphite2, pixman and cairo exist only to serve
# svgload and textload; skip them when both are trimmed.
if [ "${NEED_VECTOR_TEXT}" = 1 ]; then
  build_freetype -Dharfbuzz=disabled
fi

if [ "${HAVE_DZSAVE}" = 1 ]; then
  mkdir ${DEPS}/archive
  $CURL https://github.com/libarchive/libarchive/releases/download/v${VERSION_ARCHIVE}/libarchive-${VERSION_ARCHIVE}.tar.xz | tar xJC ${DEPS}/archive --strip-components=1
  cd ${DEPS}/archive
  ./configure --host=${CHOST} --prefix=${TARGET} --enable-static --disable-shared --disable-dependency-tracking \
    --disable-bsdtar --disable-bsdcat --disable-bsdcpio --disable-bsdunzip --disable-posix-regex-lib --disable-xattr --disable-acl \
    --without-bz2lib --without-libb2 --without-iconv --without-lz4 --without-zstd --without-lzma \
    --without-lzo2 --without-cng --without-openssl --without-xml2 --without-expat
  make install-strip libarchive_man_MANS=
fi

if [ "${NEED_VECTOR_TEXT}" = 1 ]; then
  mkdir ${DEPS}/fontconfig
  $CURL https://gitlab.freedesktop.org/fontconfig/fontconfig/-/archive/${VERSION_FONTCONFIG}/fontconfig-${VERSION_FONTCONFIG}.tar.gz | tar xzC ${DEPS}/fontconfig --strip-components=1
  cd ${DEPS}/fontconfig
  # Disable install of gettext files
  sed -i'.bak' "/subdir('its')/d" meson.build
  # Silence FcInit warnings
  sed -i'.bak' "/using without calling FcInit/d" src/fcobjs.c
  meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON} \
    -Dcache-build=disabled -Ddoc=disabled -Dnls=disabled -Dtests=disabled -Dtools=disabled
  meson install -C _build --tag devel

  mkdir ${DEPS}/harfbuzz
  $CURL https://github.com/harfbuzz/harfbuzz/archive/${VERSION_HARFBUZZ}.tar.gz | tar xzC ${DEPS}/harfbuzz --strip-components=1
  cd ${DEPS}/harfbuzz
  meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON} \
    -Dgobject=disabled -Dicu=disabled -Dtests=disabled -Dintrospection=disabled -Ddocs=disabled -Dbenchmark=disabled -Dutilities=disabled \
    -Draster=disabled -Dvector=disabled -Dsubset=disabled -Dgpu=disabled -Dgpu_demo=disabled \
    ${DARWIN:+-Dcoretext=enabled}
  meson install -C _build --tag devel

  build_freetype -Dharfbuzz=enabled

  mkdir ${DEPS}/pixman
  $CURL https://cairographics.org/releases/pixman-${VERSION_PIXMAN}.tar.gz | tar xzC ${DEPS}/pixman --strip-components=1
  cd ${DEPS}/pixman
  meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON} \
    -Dlibpng=disabled -Dgtk=disabled -Dopenmp=disabled -Dtests=disabled -Ddemos=disabled \
    ${WITHOUT_NEON:+-Da64-neon=disabled}
  meson install -C _build --tag devel

  mkdir ${DEPS}/cairo
  $CURL https://cairographics.org/releases/cairo-${VERSION_CAIRO}.tar.xz | tar xJC ${DEPS}/cairo --strip-components=1
  cd ${DEPS}/cairo
  meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON} \
    ${LINUX:+-Dquartz=disabled} ${DARWIN:+-Dquartz=enabled} -Dfreetype=enabled -Dfontconfig=enabled -Dtee=disabled -Dxcb=disabled -Dxlib=disabled -Dzlib=disabled \
    -Dtests=disabled -Dspectre=disabled -Dsymbol-lookup=disabled
  meson install -C _build --tag devel
fi

if [ "${HAVE_TEXT_STACK}" = 1 ]; then
  mkdir ${DEPS}/fribidi
  $CURL https://github.com/fribidi/fribidi/releases/download/v${VERSION_FRIBIDI}/fribidi-${VERSION_FRIBIDI}.tar.xz | tar xJC ${DEPS}/fribidi --strip-components=1
  cd ${DEPS}/fribidi
  meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON} \
    -Ddocs=false -Dbin=false -Dtests=false
  meson install -C _build --tag devel

  mkdir ${DEPS}/pango
  $CURL https://download.gnome.org/sources/pango/$(without_patch $VERSION_PANGO)/pango-${VERSION_PANGO}.tar.xz | tar xJC ${DEPS}/pango --strip-components=1
  cd ${DEPS}/pango
  # Disable utils and tools
  sed -i'.bak' "/subdir('utils')/{N;d;}" meson.build
  meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON} \
    -Ddocumentation=false -Dbuild-testsuite=false -Dbuild-examples=false -Dintrospection=disabled -Dfontconfig=enabled
  meson install -C _build --tag devel
fi

if [ "${HAVE_SVG}" = 1 ]; then
  mkdir ${DEPS}/rsvg
  $CURL https://download.gnome.org/sources/librsvg/$(without_patch $VERSION_RSVG)/librsvg-${VERSION_RSVG}.tar.xz | tar xJC ${DEPS}/rsvg --strip-components=1
  cd ${DEPS}/rsvg
  # Disallow GIF and WebP embedded in SVG images
  sed -i'.bak' "/image = /s/, \"gif\", \"webp\"//" rsvg/Cargo.toml
  # We build Cairo with `-Dzlib=disabled`, which implicitly disables the PDF/PostScript surface backends
  sed -i'.bak' "/cairo-rs = /s/, \"pdf\", \"ps\"//" {librsvg-c,rsvg}/Cargo.toml
  # https://gitlab.gnome.org/GNOME/librsvg/-/merge_requests/1066#note_2356762
  sed -i'.bak' "/^if host_system in \['windows'/s/, 'linux'//" meson.build
  # Regenerate the lockfile after making the above changes
  cargo update --workspace
  # Remove the --static flag from the PKG_CONFIG env since Rust does not
  # parse that correctly.
  PKG_CONFIG=${PKG_CONFIG/ --static/} meson setup _build --default-library=static --buildtype=plain --strip --prefix=${TARGET} ${MESON} \
    -Dintrospection=disabled -Dpixbuf{,-loader}=disabled -Drsvg-convert=disabled -Ddocs=disabled -Dvala=disabled -Dtests=false \
    ${RUST_TARGET:+-Dtriplet=$RUST_TARGET}
  meson install -C _build --tag devel
fi

mkdir ${DEPS}/cgif
$CURL https://github.com/dloebl/cgif/archive/v${VERSION_CGIF}.tar.gz | tar xzC ${DEPS}/cgif --strip-components=1
cd ${DEPS}/cgif
CFLAGS="${CFLAGS} -O3" meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON} \
  -Dexamples=false -Dtests=false
meson install -C _build --tag devel

if [ "${HAVE_UHDR}" = 1 ]; then
  mkdir ${DEPS}/uhdr
  $CURL https://github.com/google/libultrahdr/archive/${VERSION_UHDR}.tar.gz | tar xzC ${DEPS}/uhdr --strip-components=1
  cd ${DEPS}/uhdr
  # [PATCH] Remove platform and architecture detection logic
  $CURL https://patch-diff.githubusercontent.com/raw/google/libultrahdr/pull/383.patch | patch -p1
  # Ensure install targets are enabled when cross-compiling
  sed -i'.bak' 's/CMAKE_CROSSCOMPILING AND UHDR_ENABLE_INSTALL/FALSE/' CMakeLists.txt
  CFLAGS="${CFLAGS} -O3" CXXFLAGS="${CXXFLAGS} -O3" cmake -G"Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE=${ROOT}/Toolchain.cmake -DCMAKE_INSTALL_PREFIX=${TARGET} -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=FALSE -DUHDR_BUILD_EXAMPLES=FALSE -DUHDR_MAX_DIMENSION=65500 ${WITHOUT_NEON:+-DUHDR_ENABLE_INTRINSICS=FALSE}
  make install/strip
fi

# ---------------------------------------------------------------------------
# Optional codec dependencies (only built when selected via CODECS)
# ---------------------------------------------------------------------------

if codec_on spng; then
  mkdir ${DEPS}/spng
  $CURL https://github.com/randy408/libspng/archive/v${VERSION_SPNG}.tar.gz | tar xzC ${DEPS}/spng --strip-components=1
  cd ${DEPS}/spng
  meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON} \
    -Dbuild_examples=false
  meson install -C _build --tag devel
fi

if codec_on openjpeg; then
  mkdir ${DEPS}/openjpeg
  $CURL https://github.com/uclouvain/openjpeg/archive/v${VERSION_OPENJPEG}.tar.gz | tar xzC ${DEPS}/openjpeg --strip-components=1
  cd ${DEPS}/openjpeg
  mkdir build
  cd build
  cmake -G"Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE=${ROOT}/Toolchain.cmake -DCMAKE_INSTALL_PREFIX=${TARGET} -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=FALSE -DBUILD_CODEC=OFF -DBUILD_TESTING=OFF -DBUILD_DOC=OFF \
    ..
  make install/strip
fi

if codec_on openexr; then
  mkdir ${DEPS}/imath
  $CURL https://github.com/AcademySoftwareFoundation/Imath/archive/v${VERSION_IMATH}.tar.gz | tar xzC ${DEPS}/imath --strip-components=1
  cd ${DEPS}/imath
  mkdir build
  cd build
  cmake -G"Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE=${ROOT}/Toolchain.cmake -DCMAKE_INSTALL_PREFIX=${TARGET} -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=FALSE -DBUILD_TESTING=OFF -DIMATH_INSTALL_PKG_CONFIG=ON -DIMATH_INSTALL_SYM_LINK=OFF \
    ..
  make install/strip

  mkdir ${DEPS}/openexr
  $CURL https://github.com/AcademySoftwareFoundation/openexr/archive/v${VERSION_OPENEXR}.tar.gz | tar xzC ${DEPS}/openexr --strip-components=1
  cd ${DEPS}/openexr
  mkdir build
  cd build
  cmake -G"Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE=${ROOT}/Toolchain.cmake -DCMAKE_INSTALL_PREFIX=${TARGET} -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=FALSE -DBUILD_TESTING=OFF -DOPENEXR_BUILD_TOOLS=OFF -DOPENEXR_BUILD_EXAMPLES=OFF -DOPENEXR_BUILD_PYTHON=OFF -DOPENEXR_INSTALL_PKG_CONFIG=ON \
    ..
  make install/strip
fi

if codec_on jpeg-xl; then
  mkdir ${DEPS}/brotli
  $CURL https://github.com/google/brotli/archive/v${VERSION_BROTLI}.tar.gz | tar xzC ${DEPS}/brotli --strip-components=1
  cd ${DEPS}/brotli
  mkdir build
  cd build
  cmake -G"Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE=${ROOT}/Toolchain.cmake -DCMAKE_INSTALL_PREFIX=${TARGET} -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=FALSE -DBROTLI_DISABLE_TESTS=ON \
    ..
  make install/strip

  mkdir ${DEPS}/jpeg-xl
  $CURL https://github.com/libjxl/libjxl/archive/v${VERSION_JPEGXL}.tar.gz | tar xzC ${DEPS}/jpeg-xl --strip-components=1
  cd ${DEPS}/jpeg-xl
  mkdir build
  cd build
  cmake -G"Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE=${ROOT}/Toolchain.cmake -DCMAKE_INSTALL_PREFIX=${TARGET} -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=FALSE -DBUILD_TESTING=OFF \
    -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_JNI=OFF \
    -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_SKCMS=OFF -DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_PLUGINS=OFF \
    -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_VIEWERS=OFF -DJPEGXL_BUNDLE_LIBPNG=OFF \
    -DJPEGXL_FORCE_SYSTEM_BROTLI=ON -DJPEGXL_FORCE_SYSTEM_HWY=ON \
    ..
  make install/strip
fi

if codec_on fftw; then
  mkdir ${DEPS}/fftw
  $CURL https://www.fftw.org/fftw-${VERSION_FFTW}.tar.gz | tar xzC ${DEPS}/fftw --strip-components=1
  cd ${DEPS}/fftw
  ./configure --host=${CHOST} --prefix=${TARGET} --enable-static --disable-shared --disable-dependency-tracking \
    --disable-fortran --enable-threads
  make install-strip
fi

if codec_on cfitsio; then
  mkdir ${DEPS}/cfitsio
  $CURL https://heasarc.gsfc.nasa.gov/FTP/software/fitsio/c/cfitsio-${VERSION_CFITSIO}.tar.gz | tar xzC ${DEPS}/cfitsio --strip-components=1
  cd ${DEPS}/cfitsio
  ./configure --host=${CHOST} --prefix=${TARGET} --enable-static --disable-shared --disable-dependency-tracking \
    --disable-curl
  make
  make install
fi

if codec_on matio; then
  mkdir ${DEPS}/matio
  $CURL https://github.com/tbeu/matio/releases/download/v${VERSION_MATIO}/matio-${VERSION_MATIO}.tar.gz | tar xzC ${DEPS}/matio --strip-components=1
  cd ${DEPS}/matio
  ./configure --host=${CHOST} --prefix=${TARGET} --enable-static --disable-shared --disable-dependency-tracking \
    --without-hdf5 --disable-mat73
  make install-strip
fi

if codec_on raw; then
  mkdir ${DEPS}/raw
  $CURL https://www.libraw.org/data/LibRaw-${VERSION_RAW}.tar.gz | tar xzC ${DEPS}/raw --strip-components=1
  cd ${DEPS}/raw
  ./configure --host=${CHOST} --prefix=${TARGET} --enable-static --disable-shared --disable-dependency-tracking \
    --disable-examples --disable-demos --disable-jasper
  make install-strip
fi

mkdir ${DEPS}/vips
$CURL https://github.com/libvips/libvips/releases/download/v${VERSION_VIPS}/vips-${VERSION_VIPS}.tar.xz | tar xJC ${DEPS}/vips --strip-components=1
cd ${DEPS}/vips
# Use version number in SONAME
$CURL https://gist.githubusercontent.com/lovell/313a6901e9db1bf285f2a1f1180499e4/raw/3988223c7dfa4d22745d9392034b0117abef1446/libvips-cpp-soversion.patch | patch -p1
# Disable HBR support in heifsave.
#
# Same story as build-scripts/win.sh: libvips/build-win64-mxe removed this patch from
# its release tags (2026-06-06, "aom: enable HDR support") and libvips >= 8.18 has no
# HBR code left in heifsave.c. Fetch with --fail so a 404 page cannot be piped into
# patch as garbage input, and treat a patch that cannot be applied as a warning.
apply_vips_heifsave_hbr_patch() {
  local patch_url="https://raw.githubusercontent.com/libvips/build-win64-mxe/v${VERSION_VIPS}/build/patches/vips-8-heifsave-disable-hbr-support.patch"
  local patch_file="${DEPS}/vips-heifsave-hbr.patch"
  if ! $CURL --fail -o "$patch_file" "$patch_url" 2>/dev/null; then
    echo "heifsave HBR patch is not published for vips ${VERSION_VIPS}; nothing to patch"
    return 0
  fi
  if patch -N -p1 -i "$patch_file"; then
    echo "Applied heifsave HBR patch"
  else
    echo "Warning: heifsave HBR patch does not apply to vips ${VERSION_VIPS}; skipping" >&2
  fi
  rm -f "$patch_file"
}
apply_vips_heifsave_hbr_patch
# Link libvips.so statically into libvips-cpp.so
sed -i'.bak' "s/library('vips'/static_&/" libvips/meson.build
sed -i'.bak' "/version: library_version/{N;d;}" libvips/meson.build
if [ "$LINUX" = true ]; then
  # Ensure libvips-cpp.so is linked with -z nodelete
  sed -i'.bak' "/gnu_symbol_visibility: 'hidden',/a link_args: nodelete_link_args," cplusplus/meson.build
  # Ensure symbols from external libs (except for libglib-2.0.a and libgobject-2.0.a) are not exposed
  EXCLUDE_LIBS=$(find ${TARGET}/lib -maxdepth 1 -name '*.a' ! -name 'libglib-2.0.a' ! -name 'libgobject-2.0.a' -printf "-Wl,--exclude-libs=%f ")
  EXCLUDE_LIBS=${EXCLUDE_LIBS%?}
  printf "{local:g_param_spec_types;};" > vips.map
fi
# Disable building man pages, gettext po files, tools, and (fuzz-)tests
sed -i'.bak' "/subdir('man')/{N;N;N;N;d;}" meson.build
# libvips links a single PNG backend: meson only looks for spng when libpng was not
# found, and libpng is always built here, so selecting the "spng" codec has to
# switch libvips over to it explicitly or the selection is silently ignored.
PNG_BACKEND_FLAGS=""
if codec_on spng; then
  # -Dspng=enabled already comes from build-scripts/codecs.sh for the posix build,
  # so only the libpng side has to be switched off here.
  PNG_BACKEND_FLAGS="-Dpng=disabled"
  echo "PNG backend: libspng (libpng is disabled for this build - libvips links one PNG backend at a time)"
  echo "Note: with the libspng backend libvips does not export the convenience wrappers" \
    "vips_pngload()/vips_pngsave(); the \"pngload\"/\"pngsave\" operations and the C++" \
    "vips::VImage::pngsave() still work, as do vips_image_new_from_file() and" \
    "vips_image_write_to_file(). See build-scripts/smoke-test.sh." >&2
fi
CFLAGS="${CFLAGS} -O3" CXXFLAGS="${CXXFLAGS} -O3" meson setup _build --default-library=shared --buildtype=release --strip --prefix=${TARGET} ${MESON} \
  -Ddeprecated=false -Dexamples=false -Dauto_features=enabled -Dintrospection=disabled -Dmodules=disabled \
  ${WITHOUT_HIGHWAY:+-Dhighway=disabled} \
  ${VIPS_CODEC_FLAGS} ${PNG_BACKEND_FLAGS} \
  ${LINUX:+-Dcpp_link_args="$LDFLAGS -Wl,-Bsymbolic-functions -Wl,--version-script=$DEPS/vips/vips.map $EXCLUDE_LIBS"}
meson install -C _build --tag runtime,devel

# ---------------------------------------------------------------------------
# Smoke test: compile and run build-scripts/smoke-test.c against the library that
# was just installed into $TARGET, so a broken link, a missing dependency or an
# unexpected trim is caught here rather than by whoever downloads the artifact.
# It runs before the cleanup below because that deletes $TARGET/lib/pkgconfig, the
# only place vips.pc is guaranteed to exist; the filtering step after it only moves
# and renames the libraries that have already been linked and run here. TARGET is
# passed explicitly because posix builds keep it outside the package tree. Formats
# LEAN removed on purpose are reported as trimmed instead of failing the build.
# Set SMOKE_TEST=0 to skip the test.
# ---------------------------------------------------------------------------
if [ "${SMOKE_TEST:-1}" != 0 ]; then
  echo "Smoke testing the library installed in $TARGET..."
  if ! TARGET="$TARGET" VERSION_VIPS="${VERSION_VIPS:-}" bash "${PACKAGE}/build-scripts/smoke-test.sh" ${CODECS}; then
    echo "ERROR: the smoke test failed - the library in $TARGET is not usable." >&2
    exit 1
  fi
fi

# Cleanup
rm -rf ${TARGET}/lib/{pkgconfig,.libs,*.la,cmake}

mkdir ${TARGET}/lib-filtered
mv ${TARGET}/lib/glib-2.0 ${TARGET}/lib-filtered

# Pack only the relevant libraries
# Note: we can't use ldd on Linux, since that can only be executed on the target machine
# Note 2: we modify all dylib dependencies to use relative paths on macOS
function copydeps {
  local base=$1
  local dest_dir=$2

  cp -L $base $dest_dir/$base
  chmod 644 $dest_dir/$base

  if [ "$LINUX" = true ]; then
    local dependencies=$(readelf -d $base | grep NEEDED | awk '{ print $5 }' | tr -d '[]')
  elif [ "$DARWIN" = true ]; then
    local dependencies=$(otool -LX $base | awk '{print $1}' | grep $TARGET)

    install_name_tool -id @rpath/$base $dest_dir/$base
  fi

  for dep in $dependencies; do
    base_dep=$(basename $dep)

    [ ! -f "$PWD/$base_dep" ] && echo "$base_dep does not exist in $PWD" && continue
    echo "$base depends on $base_dep"

    if [ ! -f "$dest_dir/$base_dep" ]; then
      if [ "$DARWIN" = true ]; then
        install_name_tool -change $dep @rpath/$base_dep $dest_dir/$base
      fi

      # Call this function (recursive) on each dependency of this library
      copydeps $base_dep $dest_dir
    fi
  done;
}

cd ${TARGET}/lib
if [ "$LINUX" = true ]; then
  # Check that we really linked with -z nodelete
  readelf -Wd ${VIPS_CPP_DEP} | grep -qF NODELETE || (echo "$VIPS_CPP_DEP was not linked with -z nodelete" && exit 1)
  # Check that we really use the "new" C++11 ABI
  readelf -Ws ${VIPS_CPP_DEP} | c++filt | grep -qF "::__cxx11::" || (echo "$VIPS_CPP_DEP mistakenly uses the C++03 ABI" && exit 1)
fi
copydeps ${VIPS_CPP_DEP} ${TARGET}/lib-filtered

cd ${TARGET}/lib-filtered
if [ "$DARWIN" = true ]; then
  mv libvips-cpp.*.dylib libvips.42.dylib
  install_name_tool -id "@rpath/libvips.42.dylib" libvips.42.dylib
elif [ "$LINUX" = true ]; then
  mv libvips-cpp.so.* libvips.so.42
fi

# Create JSON file of version numbers
cd ${TARGET}
VERSIONS_JSON=""
VERSIONS_SEP=""
add_version() {
  VERSIONS_JSON="${VERSIONS_JSON}${VERSIONS_SEP}  \"$1\": \"$2\""
  VERSIONS_SEP=",
"
}
# "preset"/"lean"/"features" record how this package was trimmed, so a consumer -
# and build-scripts/smoke-test.sh - can tell which formats are missing on purpose.
# See the feature-trimming block in build-scripts/codecs.sh.
add_version preset "${PRESET}"
add_version lean "${LEAN}"
add_version features "${FEATURES}"
add_version aom "${VERSION_AOM}"
if [ "${HAVE_DZSAVE}" = 1 ]; then add_version archive "${VERSION_ARCHIVE}"; fi
if [ "${NEED_VECTOR_TEXT}" = 1 ]; then add_version cairo "${VERSION_CAIRO}"; fi
add_version cgif "${VERSION_CGIF}"
if [ "${HAVE_EXIF}" = 1 ]; then add_version exif "${VERSION_EXIF}"; fi
add_version expat "${VERSION_EXPAT}"
add_version ffi "${VERSION_FFI}"
if [ "${NEED_VECTOR_TEXT}" = 1 ]; then add_version fontconfig "${VERSION_FONTCONFIG}"; fi
if [ "${NEED_VECTOR_TEXT}" = 1 ]; then add_version freetype "${VERSION_FREETYPE}"; fi
if [ "${HAVE_TEXT_STACK}" = 1 ]; then add_version fribidi "${VERSION_FRIBIDI}"; fi
add_version glib "${VERSION_GLIB}"
if [ "${NEED_VECTOR_TEXT}" = 1 ]; then add_version harfbuzz "${VERSION_HARFBUZZ}"; fi
add_version heif "${VERSION_HEIF}"
if [ "${HEIF_DECODER}" = 1 ]; then add_version de265 "${VERSION_DE265}"; fi
if [ "${HEIF_ENCODER}" = 1 ]; then add_version x265 "system"; fi
add_version highway "${VERSION_HIGHWAY}"
if [ "${HAVE_IMAGEQUANT}" = 1 ]; then add_version imagequant "${VERSION_IMAGEQUANT}"; fi
if [ "${HAVE_LCMS}" = 1 ]; then add_version lcms "${VERSION_LCMS}"; fi
add_version mozjpeg "${VERSION_MOZJPEG}"
if [ "${HAVE_TEXT_STACK}" = 1 ]; then add_version pango "${VERSION_PANGO}"; fi
if [ "${NEED_VECTOR_TEXT}" = 1 ]; then add_version pixman "${VERSION_PIXMAN}"; fi
add_version png "${VERSION_PNG}"
add_version proxy-libintl "${VERSION_PROXY_LIBINTL}"
if [ "${HAVE_SVG}" = 1 ]; then add_version rsvg "${VERSION_RSVG}"; fi
if [ "${HAVE_TIFF}" = 1 ]; then add_version tiff "${VERSION_TIFF}"; fi
if [ "${HAVE_UHDR}" = 1 ]; then add_version uhdr "${VERSION_UHDR}"; fi
add_version vips "${VERSION_VIPS}"
add_version webp "${VERSION_WEBP}"
add_version xml2 "${VERSION_XML2}"
add_version zlib-ng "${VERSION_ZLIB_NG}"
# Optional codec dependencies
if codec_on jpeg-xl; then
  add_version brotli "${VERSION_BROTLI}"
  add_version jpeg-xl "${VERSION_JPEGXL}"
fi
if codec_on cfitsio; then
  add_version cfitsio "${VERSION_CFITSIO}"
fi
if codec_on fftw; then
  add_version fftw "${VERSION_FFTW}"
fi
if codec_on matio; then
  add_version matio "${VERSION_MATIO}"
fi
if codec_on openexr; then
  add_version imath "${VERSION_IMATH}"
  add_version openexr "${VERSION_OPENEXR}"
fi
if codec_on openjpeg; then
  add_version openjpeg "${VERSION_OPENJPEG}"
fi
if codec_on raw; then
  add_version raw "${VERSION_RAW}"
fi
if codec_on spng; then
  add_version spng "${VERSION_SPNG}"
fi
printf "{\n%s\n}" "${VERSIONS_JSON}" >versions.json

# Add third-party notices
$CURL -O https://raw.githubusercontent.com/CodeWithKyrian/libvips-binaries/main/THIRD-PARTY-NOTICES.md

# Create the tarball
ls -al lib
rm -rf lib
mv lib-filtered lib

tar chzf ${PACKAGE}/libvips-${PLATFORM}.tar.gz \
  include \
  lib \
  *.json \
  THIRD-PARTY-NOTICES.md

# Allow tarballs to be read outside container
chmod 644 ${PACKAGE}/libvips-${PLATFORM}.tar.*
