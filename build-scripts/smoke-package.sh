#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# smoke-package.sh - run build-scripts/smoke-test.c against the archive this
# repository produced, the way a consumer would use it.
#
# win.sh and posix.sh already run smoke-test.sh, and that is the right place to
# fail fast, but on Linux and macOS it tests a library that is not the one that
# ships: posix.sh deletes target/lib/pkgconfig, copies the library with cp -L,
# rewrites its install name to @rpath/... and renames libvips-cpp.so.* to
# libvips.so.42 - all after the test has run.  This script unpacks the finished
# tarball into an empty directory and runs the same checks there, with nothing
# left over from the build: no build tree, no dependency prefix, and on posix no
# pkg-config file at all.
#
# Usage:
#   bash build-scripts/smoke-package.sh libvips-linux-x64.tar.gz
#   CODECS=spng,openjpeg bash build-scripts/smoke-package.sh libvips-win-x64.tar.gz
#
# CODECS is handed to smoke-test.sh when it is set, which is what the Actions
# workflows carry in their job env.  GITHUB_STEP_SUMMARY, when present, gets the
# check table so the verdict is on the run summary rather than buried in a build
# log.  A failure exits non-zero, which is what keeps a broken archive from being
# uploaded or released.
# ---------------------------------------------------------------------------

set -u

TARBALL="${1:-}"
if [ -z "$TARBALL" ]; then
  echo "smoke-package: usage: smoke-package.sh libvips-<platform>.tar.gz" >&2
  exit 2
fi
[ -f "$TARBALL" ] || { echo "smoke-package: no such archive: $TARBALL" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SMOKE="$SCRIPT_DIR/smoke-test.sh"
[ -f "$SMOKE" ] || { echo "smoke-package: missing $SMOKE" >&2; exit 2; }

WORK="$(mktemp -d 2>/dev/null)" || WORK="$PWD/smoke-package.$$"
[ -d "$WORK" ] || { echo "smoke-package: cannot create a work directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# Every archive in this repository is member relative - include/, lib/,
# versions.json, THIRD-PARTY-NOTICES.md - so the unpacked tree *is* the package
# and TARGET is simply the directory it landed in.
if ! tar xzf "$TARBALL" -C "$WORK"; then
  echo "smoke-package: cannot unpack $TARBALL" >&2
  exit 2
fi
if [ ! -d "$WORK/lib" ] || [ ! -d "$WORK/include" ]; then
  echo "smoke-package: $TARBALL contains no include/ and lib/ - not a libvips package" >&2
  exit 2
fi

SIZE="$(ls -l "$TARBALL" | awk '{print $5}')"
echo "smoke-package: $TARBALL ($SIZE bytes) unpacked to $WORK"

# --- which codecs to require ------------------------------------------------
# A codec list is only as good as the build it describes.  In the workflows
# CODECS is in the job env, so the package is held to exactly what was asked
# for.  When it is not set - a local run against an archive from an older or
# narrower build - the archive is asked instead: win.sh and posix.sh only write
# a dependency into versions.json when its codec was selected, so the keys that
# are present are the codecs that were built.  Guessing "all" there would report
# a codec that was never requested as a failure.
CODEC_NAMES="spng openjpeg openexr jpeg-xl fftw cfitsio matio raw ppm analyze radiance qoi nsgif cgif"
if [ -n "${CODECS:-}" ]; then
  SELECTION="$(printf '%s' "$CODECS" | tr ',;' '  ')"
  echo "smoke-package: requiring the codecs the build was asked for:$SELECTION"
elif [ -f "$WORK/versions.json" ]; then
  SELECTION=""
  for name in $(sed -n 's/^[[:space:]]*"\([a-z0-9.+-]*\)":.*/\1/p' "$WORK/versions.json"); do
    case " $CODEC_NAMES " in
      *" $name "*) SELECTION="$SELECTION $name" ;;
    esac
  done
  echo "smoke-package: CODECS is unset, requiring the codecs $TARBALL records:${SELECTION:- none}"
else
  SELECTION="all"
  echo "smoke-package: CODECS is unset and the archive records none, assuming every codec"
fi

# --- run --------------------------------------------------------------------
LOG="$WORK/result.txt"
if [ -n "$SELECTION" ]; then
  TARGET="$WORK" bash "$SMOKE" $SELECTION 2>&1 | tee "$LOG"
else
  TARGET="$WORK" bash "$SMOKE" none 2>&1 | tee "$LOG"
fi
status=${PIPESTATUS[0]}

# The Actions job summary is the only place a reader sees this table without
# opening a log that also contains a full dependency build.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '### Smoke test: %s\n\n' "$(basename "$TARBALL")"
    printf '```text\n'
    cat "$LOG"
    printf '```\n'
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$status" -eq 0 ]; then
  echo "smoke-package: $TARBALL is usable"
else
  echo "::error::$TARBALL failed its smoke test - do not publish it" >&2
fi

exit "$status"
