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

# ---------------------------------------------------------------------------
# Feature trimming (PRESET, LEAN and the individual feature switches)
# ---------------------------------------------------------------------------
# The codecs above are formats you asked for. What follows are the *features*
# libvips turns on whenever it happens to find the library, and they are by far
# the largest contributors to the shipped DLL. Measured against this build's
# own linker map (bytes actually placed in libvips-42.dll):
#
#   x265, via libheif .............. HEVC *encoding* in heifsave .. 21.5 MB
#   rsvg + cairo + pixman
#     + gdk-pixbuf + libxml2 ....... svgload ....................... 15.5 MB
#   pangocairo + pango{,ft2,win32}
#     + harfbuzz + freetype
#     + fontconfig + graphite2
#     + fribidi + datrie + thai
#     + libiconv + libintl ......... textload ....................... 5.2 MB
#   libimagequant .................. png/webp quantiser, gifsave .... 1.1 MB
#   libuhdr ........................ UltraHDR gain maps ............. 0.4 MB
#   libarchive ..................... dzsave ......................... 0.3 MB
#
# PRESET picks a starting point; the individual switches further down then beat
# whatever the preset chose, so "lean but keep TIFF" and "aggressive but keep
# the quantiser" are both expressible.
#
#   full        0  nothing trimmed: svgload, textload, UltraHDR, TIFF, dzsave,
#                  the quantiser and HEVC encoding are all built.
#   lean        1  no svgload, no textload, no UltraHDR and no HEVC *encoding*.
#                  AVIF encode/decode and HEVC *decoding* (libde265) are kept.
#   aggressive  2  as lean, plus no TIFF, no dzsave and no quantiser. Dropping
#                  the quantiser takes GIF *saving* with it: libvips compiles
#                  cgifsave.c only when a quantiser is available, so aggressive
#                  keeps gifload but has no gifsave.
#   image       3  aggressive, but the quantiser stays, which is what GIF saving
#                  needs. This is the "codecs only" preset: jpeg, png, webp,
#                  heic/avif and gif (load and save), the optional codecs that
#                  were selected, and nothing else.
#
# LEAN is the same knob spelled as a number and is accepted wherever PRESET is
# (0=full, 1=lean, 2=aggressive, 3=image), so LEAN=2 keeps working unchanged.
# HEIF_HEVC_ENCODER=on is still accepted as an alias for heif_enc=on.
# ---------------------------------------------------------------------------
PRESET_NAMES="full lean aggressive image"
PRESET_RAW="${PRESET:-${LEAN:-}}"

normalise_preset() {
  case "$(printf '%s' "${1:-full}" | tr '[:upper:]' '[:lower:]')" in
    0|full|none|off|no|false)              echo full ;;
    1|lean|yes|true|on)                    echo lean ;;
    2|aggressive|tiny|tinyest|min|minimum) echo aggressive ;;
    3|image|images|codecs|formats)         echo image ;;
    *)                                     echo '' ;;
  esac
}

PRESET="$(normalise_preset "$PRESET_RAW")"
if [ -z "$PRESET" ]; then
  echo "Warning: PRESET/LEAN='${PRESET_RAW}' is not understood (full, lean, aggressive or image, or 0-3); using full" >&2
  PRESET=full
fi
# LEAN stays exported as the numeric form of PRESET: the platform scripts use it
# to decide whether rebuilding a dependency is worth it, and versions.json
# records it so consumers can tell a trimmed package from a broken one.
case "$PRESET" in
  full)       LEAN=0 ;;
  lean)       LEAN=1 ;;
  aggressive) LEAN=2 ;;
  image)      LEAN=3 ;;
esac

# ---------------------------------------------------------------------------
# Individual feature switches
# ---------------------------------------------------------------------------
# Every feature below accepts on/off and overrides the preset. Two spellings
# work: one variable per feature (SVG, TEXT, UHDR, TIFF, DZSAVE, IMAGEQUANT,
# EXIF, LCMS, HEIF_DEC, HEIF_ENC) or a single comma-separated list, e.g.
#
#   FEATURES=tiff=on,heif_enc=on ./build.sh win-x64
#
# FEATURES wins over the individual variables. FEATURE_NAMES and PRESET_NAMES
# are the catalogue that build-selectable.sh, build-selectable.ps1 and the
# Actions workflow read, so a new feature only has to be listed here.
# ---------------------------------------------------------------------------
FEATURE_NAMES="svg text uhdr tiff dzsave imagequant exif lcms heif_dec heif_enc"
FEATURES_RAW="$(printf '%s' "${FEATURES:-}" | tr '[:upper:]' '[:lower:]' | tr ',;' ' ')"

normalise_feature() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    svg|rsvg)                                       echo svg ;;
    text|textload|pango|pangocairo)                 echo text ;;
    uhdr|ultrahdr)                                  echo uhdr ;;
    tiff|tiffload|libtiff)                          echo tiff ;;
    dzsave|dz|archive|libarchive)                   echo dzsave ;;
    imagequant|quantise|quantiser|quantizer|gifsave|gif_save|gif-save) echo imagequant ;;
    exif|libexif)                                   echo exif ;;
    lcms|lcms2)                                     echo lcms ;;
    heif_dec|hevc_dec|hevc_decode|libde265|heic_decode|heic-decode) echo heif_dec ;;
    heif_enc|hevc_enc|hevc_encode|x265|heic_encode|heic-encode)     echo heif_enc ;;
    *) echo '' ;;
  esac
}

# feature_request NAME -> the value FEATURES asks for NAME, '' when it says nothing
feature_request() {
  local token
  for token in $FEATURES_RAW; do
    case "$token" in
      "$1="*) printf '%s' "${token#*=}" ;;
      "$1")   printf 'on' ;;
    esac
  done
}

# set_feature LOWER_NAME ENV_NAME DEFAULT -> sets HAVE_ENV_NAME to 1 or 0 and
# appends "lower_name=on|off" to FEATURE_RESOLVED, the record the platform
# scripts write into versions.json.
set_feature() {
  local lower="$1" env_name="$2" def="$3" val
  val="$(feature_request "$lower")"
  if [ -z "$val" ]; then
    val="$(printf '%s' "${!env_name:-}" | tr '[:upper:]' '[:lower:]')"
  fi
  case "$val" in
    on|true|yes|1|enabled)   val=1 ;;
    off|false|no|0|disabled) val=0 ;;
    '')                      val="$def" ;;
    *)
      echo "Warning: feature '${lower}=${val}' is not on/off; using the ${PRESET} default (${def})" >&2
      val="$def"
    ;;
  esac
  eval "HAVE_${env_name}=${val}"
  if [ "$val" = 1 ]; then
    FEATURE_RESOLVED="${FEATURE_RESOLVED}${lower}=on "
  else
    FEATURE_RESOLVED="${FEATURE_RESOLVED}${lower}=off "
  fi
}

case "$PRESET" in
  full)       d_svg=1 d_text=1 d_uhdr=1 d_tiff=1 d_dzsave=1 d_imagequant=1 ;;
  lean)       d_svg=0 d_text=0 d_uhdr=0 d_tiff=1 d_dzsave=1 d_imagequant=1 ;;
  aggressive) d_svg=0 d_text=0 d_uhdr=0 d_tiff=0 d_dzsave=0 d_imagequant=0 ;;
  image)      d_svg=0 d_text=0 d_uhdr=0 d_tiff=0 d_dzsave=0 d_imagequant=1 ;;
esac
# libexif and lcms2 are a few hundred KB and every codec here stores metadata,
# so they stay on in every preset unless something switches them off.
d_exif=1 d_lcms=1 d_heif_dec=1 d_heif_enc=1
if [ "$PRESET" != full ]; then d_heif_enc=0; fi
# x265 is GPL-2.0-or-later. Static linking it into an LGPL library is a licensing
# decision, not only a size one, so it is opt-in from LEAN=1 upwards.
if [ "${HEIF_HEVC_ENCODER:-}" = 'on' ] && [ -z "${HEIF_ENC:-}" ]; then
  HEIF_ENC=on
fi

# HAVE_* are the build switches the platform scripts use to decide whether a
# dependency is worth downloading, building and linking at all.
FEATURE_RESOLVED=""
set_feature svg         SVG           "$d_svg"
set_feature text        TEXT_STACK    "$d_text"
set_feature uhdr        UHDR          "$d_uhdr"
set_feature tiff        TIFF          "$d_tiff"
set_feature dzsave      DZSAVE        "$d_dzsave"
set_feature imagequant  IMAGEQUANT    "$d_imagequant"
set_feature exif        EXIF          "$d_exif"
set_feature lcms        LCMS          "$d_lcms"
set_feature heif_dec    HEIF_DEC      "$d_heif_dec"
set_feature heif_enc    HEIF_ENC      "$d_heif_enc"
# The older spelling, kept for the existing call sites and for anyone reading
# a versions.json written by an earlier script.
HAVE_HEVC_ENCODER="$HAVE_HEIF_ENC"

VIPS_LEAN_FLAGS=""
if [ "$HAVE_SVG" = 0 ];        then VIPS_LEAN_FLAGS="${VIPS_LEAN_FLAGS} -Drsvg=disabled"; fi
if [ "$HAVE_TEXT_STACK" = 0 ]; then VIPS_LEAN_FLAGS="${VIPS_LEAN_FLAGS} -Dpangocairo=disabled -Dfontconfig=disabled"; fi
if [ "$HAVE_UHDR" = 0 ];       then VIPS_LEAN_FLAGS="${VIPS_LEAN_FLAGS} -Duhdr=disabled"; fi
if [ "$HAVE_TIFF" = 0 ];       then VIPS_LEAN_FLAGS="${VIPS_LEAN_FLAGS} -Dtiff=disabled"; fi
if [ "$HAVE_DZSAVE" = 0 ];     then VIPS_LEAN_FLAGS="${VIPS_LEAN_FLAGS} -Darchive=disabled"; fi
if [ "$HAVE_IMAGEQUANT" = 0 ]; then VIPS_LEAN_FLAGS="${VIPS_LEAN_FLAGS} -Dimagequant=disabled"; fi
if [ "$HAVE_EXIF" = 0 ];       then VIPS_LEAN_FLAGS="${VIPS_LEAN_FLAGS} -Dexif=disabled"; fi
if [ "$HAVE_LCMS" = 0 ];       then VIPS_LEAN_FLAGS="${VIPS_LEAN_FLAGS} -Dlcms=disabled"; fi

# FEATURES is the resolved feature set as one machine-readable string, so a
# consumer - build-scripts/smoke-test.sh included - can tell a trimmed format
# from a broken one without knowing which preset was used.
FEATURES="${FEATURE_RESOLVED% }"
export PRESET LEAN FEATURES FEATURE_NAMES PRESET_NAMES VIPS_LEAN_FLAGS

# The dependency-free built-in loaders (ppm/analyze/radiance) are only a few
# tens of KB each, so no preset trims them; they follow CODECS.

# ---------------------------------------------------------------------------
# Build the libvips meson flags for every optional codec
# ---------------------------------------------------------------------------
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
VIPS_CODEC_FLAGS="${VIPS_CODEC_FLAGS} ${VIPS_LEAN_FLAGS}"

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
VIPS_CODEC_FLAGS_AUTO="${VIPS_CODEC_FLAGS_AUTO} ${VIPS_LEAN_FLAGS}"

echo "Enabled optional codecs:${CODECS}"
echo "Feature preset: ${PRESET} (LEAN=${LEAN})"
echo "  features: ${FEATURES}"
if [ "$HAVE_SVG" = 0 ];        then echo "  no svgload (rsvg+cairo+pixman+gdk-pixbuf+libxml2, 15.5 MB)"; fi
if [ "$HAVE_TEXT_STACK" = 0 ]; then echo "  no textload (pangocairo+harfbuzz+freetype+..., 5.2 MB)"; fi
if [ "$HAVE_UHDR" = 0 ];       then echo "  no UltraHDR gain maps"; fi
if [ "$HAVE_TIFF" = 0 ];       then echo "  no tiffload/tiffsave"; fi
if [ "$HAVE_DZSAVE" = 0 ];     then echo "  no dzsave (libarchive)"; fi
if [ "$HAVE_IMAGEQUANT" = 0 ]; then echo "  no quantiser: gifsave, pngsave Q=100 and webpsave Q=100 are gone"; fi
if [ "$HAVE_EXIF" = 0 ];       then echo "  no libexif: EXIF/ICC metadata reading is gone"; fi
if [ "$HAVE_LCMS" = 0 ];       then echo "  no lcms2: colour management is gone"; fi
if [ "$HAVE_HEIF_DEC" = 0 ];   then echo "  no libde265: .heic cannot be read (AVIF is unaffected)"; fi
if [ "$HAVE_HEIF_ENC" = 0 ];   then echo "  no x265: .heic/.h265 cannot be written (HEIC reading and AVIF are unaffected)"; else echo "  x265 built in (+21 MB, GPL): .heic/.h265 can be written"; fi