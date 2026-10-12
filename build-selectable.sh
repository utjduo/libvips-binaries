#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-selectable.sh - interactive terminal front-end for build.sh
#
# The terminal equivalent of the "Build (selectable OS + codecs)" GitHub
# Action: it asks which platforms and which optional codecs you want, then
# runs build.sh for every selected platform.
#
#   macOS    native build (clang + Homebrew dependencies)
#   Linux    Docker build (Rocky Linux 8 image, glibc 2.28)
#   Windows  MSYS2 UCRT64 native build. Run this from an "MSYS2 UCRT64" shell,
#            or run build-selectable.ps1 from PowerShell - it starts the MSYS2
#            shell for you.
#
# Examples
#   ./build-selectable.sh                            # ask for everything
#   ./build-selectable.sh -c all                     # all codecs, host platforms
#   ./build-selectable.sh -c jpeg-xl,openjpeg,ppm    # explicit codec list
#   ./build-selectable.sh -c none                    # core codecs only
#   ./build-selectable.sh -p linux-x64 --preset image --yes
#   ./build-selectable.sh --preset aggressive --features heif_enc=on,imagequant=on
#   ./build-selectable.sh --dry-run                  # show commands, build nothing
#
# build.sh / build-scripts/posix.sh are derived from the build scripts of
# lovell/sharp-libvips (Apache 2.0); this menu front-end is original.
# SPDX-License-Identifier: Apache-2.0
# ---------------------------------------------------------------------------
set -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR" || exit 1

# --- colours ---------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m'); RESET=$(printf '\033[0m')
  RED=$(printf '\033[31m'); GREEN=$(printf '\033[32m')
  YELLOW=$(printf '\033[33m'); CYAN=$(printf '\033[36m')
else
  BOLD=''; DIM=''; RESET=''; RED=''; GREEN=''; YELLOW=''; CYAN=''
fi

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "${YELLOW}warning:${RESET} $*"; }
die()  { printf '%s\n' "${RED}error:${RESET} $*" >&2; exit 1; }
rule() { printf '%s\n' '------------------------------------------------------------'; }

# ask PROMPT [DEFAULT]  ->  REPLY
ask() {
  local prompt="$1" def="${2:-}" answer
  if [ -n "$def" ]; then
    printf '%s %s[%s]%s ' "$prompt" "$DIM" "$def" "$RESET"
  else
    printf '%s ' "$prompt"
  fi
  IFS= read -r answer || answer=''
  answer="${answer#"${answer%%[![:space:]]*}"}"
  answer="${answer%"${answer##*[![:space:]]}"}"
  REPLY="${answer:-$def}"
}

# confirm PROMPT [DEFAULT]  ->  0 when the answer is yes
confirm() {
  ask "$1" "${2:-y}"
  case "$(printf '%s' "$REPLY" | tr '[:upper:]' '[:lower:]')" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

# read_var NAME FILE  ->  value of the NAME="value" line (CRLF tolerant)
read_var() {
  tr -d '\r' < "$2" 2>/dev/null | sed -n "s/^${1}=\"\(.*\)\"$/\1/p" | head -n 1
}

# --- codec catalogue -------------------------------------------------------
# The names come from build-scripts/codecs.sh so the menu can never drift from
# what the build actually understands.
CODEC_EXTRA="$(read_var CODEC_EXTRA "$ROOT_DIR/build-scripts/codecs.sh")"
CODEC_BUILTIN_ALL="$(read_var CODEC_BUILTINS_ALL "$ROOT_DIR/build-scripts/codecs.sh")"
[ -n "$CODEC_EXTRA" ] || die "Could not read CODEC_EXTRA from build-scripts/codecs.sh"
[ -n "$CODEC_BUILTIN_ALL" ] || die "Could not read CODEC_BUILTINS_ALL from build-scripts/codecs.sh"

ALL_CODECS="$CODEC_EXTRA $CODEC_BUILTIN_ALL"
DEFAULT_CODECS="nsgif qoi"

codec_desc() {
  case "$1" in
    spng)     echo 'PNG via libspng (replaces the libpng backend)' ;;
    openjpeg) echo 'JPEG 2000 (jp2)' ;;
    openexr)  echo 'OpenEXR (exr), also builds Imath' ;;
    jpeg-xl)  echo 'JPEG XL (jxl), also builds brotli + highway' ;;
    fftw)     echo 'FFTW, used by FFT-based operations' ;;
    cfitsio)  echo 'FITS astronomical images' ;;
    matio)    echo 'MATLAB .mat files' ;;
    raw)      echo 'Camera RAW via libraw' ;;
    ppm)      echo 'PPM/PNM (built in, no dependency)' ;;
    analyze)  echo 'Analyze/.img (built in, no dependency)' ;;
    radiance) echo 'Radiance .hdr (built in, no dependency)' ;;
    qoi)      echo 'QOI (built in, needs libvips >= 8.19)' ;;
    nsgif)    echo 'GIF loading (built in, no dependency)' ;;
    *)        echo '' ;;
  esac
}

codec_alias() {
  case "$1" in
    jxl|jpegxl|libjxl) echo 'jpeg-xl' ;;
    exr|open-exr) echo 'openexr' ;;
    jp2|jpeg2000|openjpeg2|open-jpeg) echo 'openjpeg' ;;
    libspng|png-spng) echo 'spng' ;;
    libraw) echo 'raw' ;;
    fits|libcfitsio) echo 'cfitsio' ;;
    mat|matlab) echo 'matio' ;;
    fft|libfftw) echo 'fftw' ;;
    *) echo "$1" ;;
  esac
}

ALL_PLATFORMS='win-x64 win-arm64 linux-x64 linux-arm64 darwin-x64 darwin-arm64'

platform_desc() {
  case "$1" in
    darwin-arm64) echo 'macOS Apple Silicon (native clang + Homebrew)' ;;
    darwin-x64)   echo 'macOS Intel (native clang + Homebrew)' ;;
    linux-x64)    echo 'Linux x86_64 (Docker, glibc 2.28)' ;;
    linux-arm64)  echo 'Linux arm64 (Docker)' ;;
    win-x64)      echo 'Windows x64 (MSYS2 UCRT64, one self-contained DLL)' ;;
    win-arm64)    echo 'Windows arm64 (MSYS2 CLANGARM64)' ;;
    *)            echo '' ;;
  esac
}

platform_alias() {
  case "$1" in
    win|windows|win64) echo 'win-x64' ;;
    mac|macos|osx|darwin)
      if [ "$(uname -m)" = 'arm64' ]; then echo 'darwin-arm64'; else echo 'darwin-x64'; fi ;;
    linux)
      if [ "$(uname -m)" = 'arm64' ] || [ "$(uname -m)" = 'aarch64' ]; then
        echo 'linux-arm64'
      else
        echo 'linux-x64'
      fi ;;
    *) echo "$1" ;;
  esac
}

# --- selection helpers -----------------------------------------------------
# resolve_tokens ITEMS DEFAULT ANSWER KIND
#   Echoes the resolved item list (space separated). Returns 2 when the answer
#   contains something unrecognised (the bad tokens go to stderr).
#   Accepted answers: empty (= default), "all", "none", "default", item names,
#   aliases, menu numbers ("1,3") and ranges ("1-4").
resolve_tokens() {
  local items="$1" def="$2" answer="$3" kind="${4:-codec}"
  local chosen='' bad='' token item mapped n lo hi hit
  answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]' | tr -s ',;' ' ')"
  answer="${answer#"${answer%%[![:space:]]*}"}"
  answer="${answer%"${answer##*[![:space:]]}"}"
  [ -z "$answer" ] && answer="$def"
  for token in $answer; do
    case "$token" in
      all) chosen="$items"; break ;;
      none|off|no) chosen='' ;;
      default) chosen="$def" ;;
      *)
        case "$token" in
          [0-9]*-[0-9]*)
            lo="${token%%-*}"; hi="${token##*-}"
            n=0; hit=0
            for item in $items; do
              n=$((n + 1))
              if [ "$n" -ge "$lo" ] && [ "$n" -le "$hi" ]; then
                chosen="$chosen $item"
                hit=1
              fi
            done
            if [ "$hit" != 1 ]; then bad="$bad $token"; fi
            ;;
          [0-9]*)
            mapped=''
            n=0
            for item in $items; do
              n=$((n + 1))
              if [ "$n" -eq "$token" ]; then mapped="$item"; fi
            done
            if [ -z "$mapped" ]; then bad="$bad $token"; else chosen="$chosen $mapped"; fi
            ;;
          *)
            mapped=''
            for item in $items; do
              if [ "$item" = "$token" ]; then mapped="$item"; fi
            done
            if [ -z "$mapped" ]; then
              if [ "$kind" = 'codec' ]; then
                mapped="$(codec_alias "$token")"
              else
                mapped="$(platform_alias "$token")"
              fi
              if [ "$mapped" = "$token" ]; then
                mapped=''
              else
                for item in $items; do
                  if [ "$item" = "$mapped" ]; then mapped="$item"; fi
                done
              fi
            fi
            if [ -z "$mapped" ]; then bad="$bad $token"; else chosen="$chosen $mapped"; fi
            ;;
        esac
        ;;
    esac
  done
  if [ -n "$bad" ]; then
    printf '%s\n' "$bad" >&2
    return 2
  fi
  # collapse duplicates, keep the catalogue order irrelevant
  printf '%s\n' "$chosen" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' '
}

# select_items KIND TITLE ITEMS DEFAULT NOTE  ->  echoes the chosen items
# The menu itself goes to stderr so that the selection is the only thing the
# caller captures from the command substitution.
select_items() {
  local kind="$1" title="$2" items="$3" def="$4" note="$5"
  local answer resolved item n d
  while : ; do
    printf '\n%s\n' "${BOLD}${title}${RESET}" >&2
    n=0
    for item in $items; do
      n=$((n + 1))
      if [ "$kind" = 'codec' ]; then
        d="$(codec_desc "$item")"
      else
        d="$(platform_desc "$item")"
      fi
      printf '  %s%2d)%s %-11s %s%s%s\n' "$DIM" "$n" "$RESET" "$item" "$DIM" "$d" "$RESET" >&2
    done
    if [ -n "$note" ]; then
      printf '      %s\n' "${DIM}${note}${RESET}" >&2
    fi
    printf '%s> %s %s(numbers / ranges like 1-4, names, all, none, default)%s ' \
      "$CYAN" "Choose [${def}]:" "$DIM" "$RESET" >&2
    IFS= read -r answer || answer=''
    resolved="$(resolve_tokens "$items" "$def" "$answer" "$kind")"
    if [ $? -ne 0 ]; then
      printf '%s\n' "${RED}Unrecognised:${RESET} $answer - nothing selected yet, try again." >&2
      continue
    fi
    printf '%s\n' "$resolved"
    return 0
  done
}

# --- host detection --------------------------------------------------------
UNAME_S="$(uname -s)"
UNAME_M="$(uname -m)"
case "$UNAME_S" in
  Darwin)              OS_LABEL='macos' ;;
  Linux)               OS_LABEL='linux' ;;
  MINGW*|MSYS*|CYGWIN*) OS_LABEL='windows' ;;
  *) die "Unsupported operating system: $UNAME_S" ;;
esac

case "$OS_LABEL" in
  macos)   HOST_PLATFORMS='darwin-arm64 darwin-x64' ;;
  linux)   HOST_PLATFORMS='linux-x64 linux-arm64' ;;
  windows)
    if [ "${MSYSTEM:-}" = 'CLANGARM64' ]; then
      HOST_PLATFORMS='win-arm64'
    else
      HOST_PLATFORMS='win-x64'
    fi ;;
esac

# --- usage / options -------------------------------------------------------
usage() {
  cat <<'USAGE'
Usage: ./build-selectable.sh [OPTIONS]

Anything that is not given as an option is asked for interactively.

  -p, --platforms LIST    Platforms to build. Default: what this machine can
                          build (macOS: darwin-arm64 darwin-x64,
                          Linux: linux-x64 linux-arm64, Windows: win-x64)
  -c, --codecs LIST       Optional codecs: comma separated, or 'all',
                          'default' (nsgif,qoi) or 'none'
      --preset NAME       How much of libvips to build:
                          full        everything (largest output)
                          lean        no svgload, no textload, no UltraHDR and no
                                      HEVC encode (x265); AVIF encode/decode and
                                      HEIC decode are kept (the default when run
                                      interactively)
                          aggressive  as lean, plus no TIFF and no dzsave
                          image       as aggressive, but keeps the quantiser so
                                      GIF saving works: the preset for image-only
                                      pipelines
                          'full', 'lean' and 'aggressive' are also accepted as
                          0, 1 and 2, and --lean LEVEL still works as an alias.
                          Without either option the PRESET (or LEAN) environment
                          variable is used, defaulting to 'lean' when asked
                          interactively and 'full' when run unattended.
      --features LIST     Switch single features on top of the preset, as
                          name=on|off pairs: svgload, textload, uhdr, tiffload,
                          dzsave, imagequant, exif, lcms, heif_dec, heif_enc.
                          Example: --preset aggressive --features heif_enc=on
  -v, --version VERSION   libvips version to build. Default: VERSION_VIPS in
                          versions.properties (it is rewritten when changed)
  -y, --yes               Unattended: ask nothing, use defaults for anything
                          not given as an option, and skip the confirmation
  -n, --dry-run           Print the build commands without running them
      --clean             Delete deps/, target/ and old tarballs first
      --no-clean          Keep deps/ and target/ as they are
  -i, --interactive       Ask every question even when options were given
      --list-codecs       Print the codec catalogue and exit
      --list-platforms    Print the platforms buildable here and exit
  -h, --help              Show this help

jpeg, png, webp, gif loading, magick load (for svg), heif/avif and lcms are
always built. tiff, dzsave, svgload, textload, UltraHDR, the GIF quantiser,
exif and the HEVC encoder follow the preset and can be switched individually
with --features.
USAGE
}

CODECS_OPT=''
PRESET_OPT=''
FEATURES_OPT=''
LEAN_OPT=''
PLATFORMS_OPT=''
VERSION_OPT=''
OPT_YES=0
OPT_DRY=0
OPT_CLEAN=''
OPT_PROMPT=0
LIST_CODECS=0
LIST_PLATFORMS=0

need_value() { [ -n "${2:-}" ] || die "Option $1 requires a value (see --help)"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -p|--platforms)    need_value "$1" "${2:-}"; PLATFORMS_OPT="$2"; shift 2 ;;
    -c|--codecs)       need_value "$1" "${2:-}"; CODECS_OPT="$2"; shift 2 ;;
    --preset)          need_value "$1" "${2:-}"; PRESET_OPT="$2"; shift 2 ;;
    --features)        need_value "$1" "${2:-}"; FEATURES_OPT="$2"; shift 2 ;;
    --lean)            need_value "$1" "${2:-}"; LEAN_OPT="$2"; shift 2 ;;
    -v|--version)      need_value "$1" "${2:-}"; VERSION_OPT="$2"; shift 2 ;;
    -y|--yes)          OPT_YES=1; shift ;;
    -n|--dry-run)      OPT_DRY=1; shift ;;
    --clean)           OPT_CLEAN='yes'; shift ;;
    --no-clean)        OPT_CLEAN='no'; shift ;;
    -i|--interactive)  OPT_PROMPT=1; shift ;;
    --list-codecs)     LIST_CODECS=1; shift ;;
    --list-platforms)  LIST_PLATFORMS=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    -*)                die "Unknown option: $1 (see --help)" ;;
    *)                 die "Unexpected argument: $1 (see --help)" ;;
  esac
done

CURRENT_VERSION="$(read_var VERSION_VIPS "$ROOT_DIR/versions.properties")"
[ -n "$CURRENT_VERSION" ] || CURRENT_VERSION='8.18.7'

print_catalog() {
  local n=0 item
  if [ "$1" = 'codecs' ]; then
    say 'Optional codecs (core codecs are always built):'
    n=0
    for item in $ALL_CODECS; do
      n=$((n + 1))
      printf '  %2d) %-11s %s\n' "$n" "$item" "$(codec_desc "$item")"
    done
    printf '      %-11s %s\n' 'all' 'every codec above'
    printf '      %-11s %s\n' 'default' "$DEFAULT_CODECS (what the workflow builds by default)"
    printf '      %-11s %s\n' 'none' 'core codecs only'
    say 'Aliases: jxl/jpegxl/libjxl, exr, jp2/jpeg2000, libspng, libraw, fits, mat/matlab, fft'
  else
    say "Platforms buildable on this machine ($OS_LABEL / $UNAME_M):"
    for item in $HOST_PLATFORMS; do
      printf '  %-13s %s\n' "$item" "$(platform_desc "$item")"
    done
    say "All known platforms: $ALL_PLATFORMS"
  fi
}

if [ "$LIST_CODECS" = 1 ]; then print_catalog codecs; exit 0; fi
if [ "$LIST_PLATFORMS" = 1 ]; then print_catalog platforms; exit 0; fi

# Should this question be asked, or taken from the command line?
# -y makes the whole run unattended, so nothing is asked.
want_prompt() {
  if [ "$OPT_PROMPT" = 1 ]; then return 0; fi
  if [ "$OPT_YES" = 1 ]; then return 1; fi
  if [ ! -t 0 ]; then return 1; fi
  case "$1" in
    codecs)    [ -z "$CODECS_OPT" ] ;;
    preset)    [ -z "$PRESET_OPT" ] && [ -z "$LEAN_OPT" ] ;;
    platforms) [ -z "$PLATFORMS_OPT" ] ;;
    version)   [ -z "$VERSION_OPT" ] ;;
    *) return 1 ;;
  esac
}

# --- sanity checks ---------------------------------------------------------
preflight() {
  local tool
  case "$OS_LABEL" in
    macos)
      command -v brew >/dev/null 2>&1 \
        || die "Homebrew is required: build.sh uses 'brew --prefix' for the macOS build."
      for tool in meson ninja pkg-config nasm automake libtool; do
        command -v "$tool" >/dev/null 2>&1 \
          || warn "$tool not found (install: pipx install meson; brew install automake nasm pkg-config libtool)"
      done
      ;;
    linux)
      command -v docker >/dev/null 2>&1 \
        || die "docker is required: build.sh builds the Linux targets inside a Rocky Linux container."
      docker info >/dev/null 2>&1 \
        || warn "'docker info' failed - is the daemon running and is this user allowed to use it?"
      ;;
    windows)
      [ -n "${MSYSTEM:-}" ] || die "Windows builds must run inside an MSYS2 shell. Start 'MSYS2 UCRT64' and run ./build-selectable.sh, or run build-selectable.ps1 from PowerShell."
      command -v pacman >/dev/null 2>&1 || die "pacman not found - this does not look like an MSYS2 shell."
      if [ "${MSYSTEM:-}" != 'UCRT64' ] && [ "${MSYSTEM:-}" != 'CLANGARM64' ]; then
        warn "MSYSTEM is '${MSYSTEM}'; the tested configuration is UCRT64 (win-arm64 needs CLANGARM64)."
      fi
      ;;
  esac
}

arch_warnings() {
  local p
  for p in $PLATFORMS; do
    case "$p" in
      darwin-x64)
        if [ "$OS_LABEL" = macos ] && [ "$UNAME_M" = arm64 ]; then
          warn 'darwin-x64 on Apple Silicon: Homebrew supplies arm64 libraries, so the cross-compiled build will not link correctly. Build darwin-x64 on an Intel host or in CI.'
        fi
        ;;
      darwin-arm64)
        if [ "$OS_LABEL" = macos ] && [ "$UNAME_M" != arm64 ]; then
          warn 'darwin-arm64 on an Intel Mac: Homebrew supplies x86_64 libraries, so the result will not be an arm64 build.'
        fi
        ;;
      linux-arm64)
        if [ "$OS_LABEL" = linux ] && [ "$UNAME_M" != aarch64 ] && [ "$UNAME_M" != arm64 ]; then
          warn 'linux-arm64 on an x86_64 host needs QEMU binfmt in Docker: docker run --privileged --rm tonistiigi/binfmt --install arm64'
        fi
        ;;
      linux-x64)
        if [ "$OS_LABEL" = linux ] && { [ "$UNAME_M" = aarch64 ] || [ "$UNAME_M" = arm64 ]; }; then
          warn 'linux-x64 on an arm64 host needs QEMU binfmt in Docker: docker run --privileged --rm tonistiigi/binfmt --install amd64'
        fi
        ;;
    esac
  done
  if [ "$OS_LABEL" = windows ] && printf '%s' " $CODEC_SEL " | grep -q ' openexr '; then
    warn 'openexr is not available on Windows (MSYS2 ships it shared-only); it will be left out of the build.'
  fi
}

# --- questions -------------------------------------------------------------
say ''
say "${BOLD}libvips-binaries - selectable build${RESET}   ${DIM}host: $OS_LABEL ($UNAME_M)${RESET}"
say "${DIM}     always built: jpeg, png, webp, gif load, heif/avif, lcms, magick${RESET}"
say "${DIM}     preset adds/removes: tiff, dzsave, svgload, textload, UltraHDR,${RESET}"
say "${DIM}     GIF quantiser, exif and the HEVC encoder (see --help)${RESET}"
say "${RESET}"

# 1. libvips version
if want_prompt version; then
  ask 'libvips version' "$CURRENT_VERSION"
  VERSION="$REPLY"
else
  VERSION="${VERSION_OPT:-$CURRENT_VERSION}"
fi
case "$VERSION" in
  [0-9]*) ;;
  *) die "Version must look like 8.18.7 (got '$VERSION')" ;;
esac
if [ "$VERSION" != "$CURRENT_VERSION" ]; then
  sed -i.bak "s/^VERSION_VIPS=.*/VERSION_VIPS=${VERSION}/" "$ROOT_DIR/versions.properties" \
    || die "Could not rewrite VERSION_VIPS in versions.properties"
  say "  ${GREEN}versions.properties:${RESET} VERSION_VIPS ${CURRENT_VERSION} -> ${VERSION}"
fi

# 2. platforms
if want_prompt platforms; then
  PLATFORMS="$(select_items platform 'Platforms to build' "$HOST_PLATFORMS" "$HOST_PLATFORMS" \
    'only platforms this machine can build are listed; build the rest in CI')"
else
  PLATFORMS="$(resolve_tokens "$ALL_PLATFORMS" "$HOST_PLATFORMS" "${PLATFORMS_OPT:-default}" platform)"
  if [ $? -ne 0 ]; then die "Unknown platform in --platforms: ${PLATFORMS_OPT}"; fi
fi
[ -n "$PLATFORMS" ] || die 'Select at least one platform.'
for p in $PLATFORMS; do
  case " $HOST_PLATFORMS " in
    *" $p "*) ;;
    *) die "$p cannot be built on this machine ($OS_LABEL). Build it on a $p host, or with the GitHub Action." ;;
  esac
done

# 3. codecs
CODEC_NOTE=''
if want_prompt codecs; then
  CODEC_NOTE='extra codecs build an extra dependency, built-in formats cost nothing'
  if [ "$OS_LABEL" = windows ]; then
    CODEC_NOTE="$CODEC_NOTE; openexr is unavailable on Windows"
  fi
  CODEC_SEL="$(select_items codec 'Optional codecs to build' "$ALL_CODECS" "$DEFAULT_CODECS" "$CODEC_NOTE")"
else
  CODEC_SEL="$(resolve_tokens "$ALL_CODECS" "$DEFAULT_CODECS" "${CODECS_OPT:-default}" codec)"
  if [ $? -ne 0 ]; then die "Unknown codec in --codecs: ${CODECS_OPT}"; fi
fi
if [ -n "$CODEC_SEL" ]; then
  CODECS="$(printf '%s\n' $CODEC_SEL | tr '\n' ',')"
  CODECS="${CODECS%,}"
else
  CODECS='none'
fi

# 4. build preset + per-feature switches --------------------------------------
# A preset is the starting point; FEATURES then switches single formats on top of
# it. Both are also read from the environment, so the CI workflow, the GitHub
# Action and a hand-written command line all mean the same thing. The old numeric
# levels are still accepted, and --lean still works as an alias for --preset.
normalise_preset() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    ''|full|0)                             echo full ;;
    lean|1)                                echo lean ;;
    2|aggressive|tiny|tinyest|min|minimum) echo aggressive ;;
    image|imageonly|images|img)            echo image ;;
    *)                                     echo '' ;;
  esac
}
if want_prompt preset; then
  say ''
  say "${DIM}svgload, textload, UltraHDR and the HEVC encoder are ~43 MB of a Windows DLL${RESET}"
  say "${DIM}and none of them are needed for jpeg, png, webp, heic/avif or gif${RESET}"
  ask 'Build preset (1 lean, 2 aggressive, 3 image-only, 4 full)' "${PRESET:-lean}"
  case "$(printf '%s' "$REPLY" | tr '[:upper:]' '[:lower:]')" in
    1) REPLY='lean' ;;
    2) REPLY='aggressive' ;;
    3) REPLY='image' ;;
    4) REPLY='full' ;;
  esac
  PRESET="$(normalise_preset "$REPLY")"
  if [ -z "$PRESET" ]; then
    warn "'$REPLY' is not a preset (full, lean, aggressive or image); using lean"
    PRESET='lean'
  fi
  if confirm 'Switch individual features on top of the preset?' n; then
    ask 'Overrides as name=on|off pairs (svgload, textload, uhdr, tiffload, dzsave, imagequant, exif, lcms, heif_dec, heif_enc)' ''
    FEATURES="$REPLY"
  fi
else
  PRESET="$(normalise_preset "${PRESET_OPT:-${LEAN_OPT:-${PRESET:-${LEAN:-}}}}")"
  [ -n "$PRESET" ] || die "Unknown --preset value: ${PRESET_OPT:-${LEAN_OPT:-${PRESET:-${LEAN}}}} (use full, lean, aggressive or image)"
  FEATURES="${FEATURES_OPT:-${FEATURES:-}}"
fi

arch_warnings

# --- summary ---------------------------------------------------------------
rule
say "${BOLD}About to build${RESET}"
say "  ${BOLD}version${RESET}  : $VERSION"
say "  ${BOLD}platforms${RESET} : $(printf '%s\n' $PLATFORMS | tr '\n' ',' | sed 's/,$//')"
say "  ${BOLD}codecs${RESET}   : $CODECS"
say "  ${BOLD}preset${RESET}   : $PRESET"
case "$PRESET" in
  full) say "  ${BOLD}trimmed${RESET}  : nothing (jpeg, png, webp, tiff, heif/avif, uhdr, gif, svg, exif, lcms, imagequant, archive, highway, text)" ;;
  lean) say "  ${BOLD}trimmed${RESET}  : svgload, textload, UltraHDR, HEVC encode (x265)" ;;
  aggressive) say "  ${BOLD}trimmed${RESET}  : as lean, plus tiffload/tiffsave, dzsave (libarchive) and the quantiser (libimagequant, so GIF save is gone)" ;;
  image) say "  ${BOLD}trimmed${RESET}  : as aggressive, but the quantiser is kept so GIF saving works" ;;
esac
[ -n "$FEATURES" ] && say "  ${BOLD}features${RESET} : $FEATURES"
rule
say "${DIM}resolved build flags:${RESET}"
( CODECS="$CODECS" PRESET="$PRESET" FEATURES="$FEATURES" VERSION_VIPS="$VERSION" \
  . "$ROOT_DIR/build-scripts/codecs.sh" 2>&1 | sed 's/^/  /' )
say ''

preflight

if [ "$OPT_YES" != 1 ] && [ -t 0 ]; then
  confirm 'Start the build?' y || { say 'Aborted.'; exit 0; }
fi

# Previous build directories can make a fresh run fail (build-scripts/posix.sh
# creates them with plain mkdir), so offer to clear them.
if [ -z "$OPT_CLEAN" ] && { [ -d "$ROOT_DIR/deps" ] || [ -d "$ROOT_DIR/target" ]; }; then
  if [ "$OPT_YES" = 1 ] || [ ! -t 0 ]; then
    OPT_CLEAN='no'
  elif confirm 'Delete the existing deps/ and target/ directories first?' y; then
    OPT_CLEAN='yes'
  else
    OPT_CLEAN='no'
  fi
fi
if [ "$OPT_CLEAN" = 'yes' ]; then
  rm -rf "$ROOT_DIR/deps" "$ROOT_DIR/target"
  rm -f "$ROOT_DIR"/libvips-*.tar.gz
  say "  ${GREEN}cleaned:${RESET} deps/, target/, libvips-*.tar.gz"
fi

# --- build -----------------------------------------------------------------
FAILED=''
for p in $PLATFORMS; do
  say ''
  rule
  say "${BOLD}${GREEN}==> $p${RESET}  ${DIM}$(platform_desc "$p")${RESET}"
  rule
  if [ "$OPT_DRY" = 1 ]; then
    say "  dry run: PRESET=\"$PRESET\" CODECS=\"$CODECS\"${FEATURES:+ FEATURES=\"$FEATURES\"} bash build.sh $p"
    continue
  fi
  if PRESET="$PRESET" CODECS="$CODECS" FEATURES="$FEATURES" bash "$ROOT_DIR/build.sh" "$p"; then
    say "${GREEN}==> $p finished${RESET}"
  else
    warn "build.sh $p failed"
    FAILED="$FAILED $p"
  fi
done

# --- results ---------------------------------------------------------------
say ''
rule
if [ "$OPT_DRY" = 1 ]; then
  say "${BOLD}Dry run complete.${RESET} Drop --dry-run to build."
  exit 0
fi
if [ -d "$ROOT_DIR" ] && ls "$ROOT_DIR"/libvips-*.tar.gz >/dev/null 2>&1; then
  say "${BOLD}Artifacts:${RESET}"
  ls -1 "$ROOT_DIR"/libvips-*.tar.gz | while IFS= read -r f; do
    printf '  %-10s %s\n' "$(ls -lh "$f" | awk '{print $5}')" "${f##*/}"
  done
else
  say "${YELLOW}No libvips-*.tar.gz produced.${RESET}"
fi
rule
if [ -n "$FAILED" ]; then
  die "Failed platform(s):${FAILED}"
fi
say "${GREEN}Done.${RESET}"





