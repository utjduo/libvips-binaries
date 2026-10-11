#!/usr/bin/env bash
# Shared codec selection for the libvips builds.
# Sourced by build-scripts/posix.sh (macOS + Linux) and build-scripts/win.sh
# (Windows/MSYS2).
#
# Based on build/posix.sh from lovell/sharp-libvips (Apache 2.0)
# SPDX-License-Identifier: Apache-2.0

# ---------------------------------------------------------------------------
# Codec selection
# ---------------------------------------------------------------------------
# CODECS is a comma-separated list of optional codecs/features to build in
# addition to the always-on core set (jpeg, png, webp, tiff, heif/avif, uhdr,
# gif, svg, exif, lcms, imagequant, archive, highway, text rendering).
#
# Special values:
#   (unset) or "default" -> historical behaviour (nsgif + qoi only)
#   "all"                -> every optional codec supported by this script
#
# Optional codecs:
#   spng openjpeg openexr jpeg-xl fftw cfitsio matio raw   (extra dependencies)
#   ppm analyze radiance qoi nsgif                         (built-in, no deps)
#
# Not supported by this script (kept disabled): magick, nifti, openslide,
# orc, pdfium, poppler, quantizr.
# ---------------------------------------------------------------------------
# Catalogue of everything this script knows how to turn on. build-selectable.sh
# and build-selectable.ps1 read these two variables to build their menus, so
# keep them in sync with the flag loops at the bottom of this file.
CODEC_EXTRA="spng openjpeg openexr jpeg-xl fftw cfitsio matio raw"
CODEC_BUILTINS_ALL="ppm analyze radiance qoi nsgif"

CODECS_RAW="$(echo "${CODECS:-}" | tr '[:upper:]' '[:lower:]')"
if [ -z "${CODECS_RAW}" ] || [ "${CODECS_RAW}" = "default" ]; then
  CODECS_LIST="nsgif qoi"
elif [ "${CODECS_RAW}" = "all" ]; then
  CODECS_LIST="${CODEC_EXTRA} ${CODEC_BUILTINS_ALL}"
elif [ "${CODECS_RAW}" = "none" ] || [ "${CODECS_RAW}" = "off" ]; then
  # Core codecs are still built, but no optional format is enabled.
  CODECS_LIST=""
else
  CODECS_LIST="$(echo "${CODECS_RAW}" | tr ',' ' ')"
fi

# Accept a few friendly aliases
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
    *) echo "$1" ;;
  esac
}
CODECS=" "
for c in ${CODECS_LIST}; do
  CODECS="${CODECS}$(normalise_codec "$c") "
done

# codec_on NAME -> success if NAME was selected
codec_on() {
  case "${CODECS}" in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# feature_flag OPT [NAME] -> "-DOPT=enabled" / "-DOPT=disabled"
feature_flag() {
  local opt="$1"
  local name="${2:-$1}"
  if codec_on "${name}"; then
    echo "-D${opt}=enabled"
  else
    echo "-D${opt}=disabled"
  fi
}

# bool_flag OPT [NAME] -> "-DOPT=true" / "-DOPT=false"
bool_flag() {
  local opt="$1"
  local name="${2:-$1}"
  if codec_on "${name}"; then
    echo "-D${opt}=true"
  else
    echo "-D${opt}=false"
  fi
}

# Built-in formats available in this libvips version. `qoi` was only added in
# libvips 8.19.0, so passing -Dqoi on an older tree makes meson fail.
CODEC_BUILTINS="${CODEC_BUILTINS_ALL}"
if [ -n "${VERSION_VIPS:-}" ]; then
  VIPS_MAJOR="${VERSION_VIPS%%.*}"
  VIPS_MINOR_TMP="${VERSION_VIPS#*.}"
  VIPS_MINOR="${VIPS_MINOR_TMP%%.*}"
  if [ "${VIPS_MAJOR}" -lt 8 ] 2>/dev/null ||
     { [ "${VIPS_MAJOR}" -eq 8 ] && [ "${VIPS_MINOR}" -lt 19 ]; }; then
    CODEC_BUILTINS="ppm analyze radiance nsgif"
    if codec_on qoi; then
      echo "Warning: 'qoi' requires libvips >= 8.19.0 (building ${VERSION_VIPS}); ignoring it"
    fi
  fi
fi

# Build the libvips meson flags for every optional codec
VIPS_CODEC_FLAGS=""
for c in ${CODEC_EXTRA}; do
  VIPS_CODEC_FLAGS="${VIPS_CODEC_FLAGS} $(feature_flag "${c}" "${c}")"
done
# Dependencies we do not build from source; always keep them disabled
VIPS_CODEC_FLAGS="${VIPS_CODEC_FLAGS} -Dmagick=disabled -Dnifti=disabled -Dopenslide=disabled"
VIPS_CODEC_FLAGS="${VIPS_CODEC_FLAGS} -Dorc=disabled -Dpdfium=disabled -Dpoppler=disabled -Dquantizr=disabled"
# Built-in, dependency-free formats
for c in ${CODEC_BUILTINS}; do
  VIPS_CODEC_FLAGS="${VIPS_CODEC_FLAGS} $(bool_flag "${c}" "${c}")"
done

# Same as above, but expressed as an "auto" list: for codecs that were selected
# we don't pass an explicit flag, so meson only enables them if their
# dependency was actually found. Used by the Windows/MSYS2 build.
VIPS_CODEC_FLAGS_AUTO=""
for c in ${CODEC_EXTRA}; do
  if ! codec_on "${c}"; then
    VIPS_CODEC_FLAGS_AUTO="${VIPS_CODEC_FLAGS_AUTO} -D${c}=disabled"
  fi
done
VIPS_CODEC_FLAGS_AUTO="${VIPS_CODEC_FLAGS_AUTO} -Dmagick=disabled -Dnifti=disabled -Dopenslide=disabled"
VIPS_CODEC_FLAGS_AUTO="${VIPS_CODEC_FLAGS_AUTO} -Dorc=disabled -Dpdfium=disabled -Dpoppler=disabled -Dquantizr=disabled"
for c in ${CODEC_BUILTINS}; do
  VIPS_CODEC_FLAGS_AUTO="${VIPS_CODEC_FLAGS_AUTO} $(bool_flag "${c}" "${c}")"
done

echo "Enabled optional codecs:${CODECS}"