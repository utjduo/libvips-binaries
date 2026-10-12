#!/usr/bin/env bash
# Shared source-archive fetching for the builds.
# Sourced by build-scripts/posix.sh (macOS + Linux) and build-scripts/win.sh
# (Windows/MSYS2).
#
# ## Based on build/posix.sh from lovell/sharp-libvips (Apache 2.0)
# SPDX-License-Identifier: Apache-2.0
#
# Every archive fetched here is pinned by version in versions.properties, so the same
# URL always means the same bytes and a download can be reused verbatim on the next
# run.  fetch_archive keeps one file per URL in $DL_CACHE - by default
# $PACKAGE/.dl-cache, i.e. inside the workspace, which is the directory the CI
# workflows hand to actions/cache - and only reaches for the network when that file
# is missing.  Because the file name is derived from the URL, bumping a version in
# versions.properties asks for a different file: a cached archive can never be
# mistaken for another version of the same dependency.
#
# An archive is only promoted into the cache after it has unpacked cleanly, so a
# truncated download cannot poison it.
#
# Requires $CURL (the common curl options) and $PACKAGE (the repository root) to be
# set before sourcing.  Set DL_CACHE to move the cache somewhere else.

DL_CACHE="${DL_CACHE:-$PACKAGE/.dl-cache}"

# unpack_archive <archive file> <destination dir> [extra tar options]
#
# Returns non-zero when the archive did not produce a non-empty destination tree.
unpack_archive() {
  local archive="$1" dest="$2"
  shift 2
  [ -s "$archive" ] || return 1
  mkdir -p "$dest"
  # -a picks the compression from the file name; the lone-zero-block noise that
  # GitHub source archives produce is filtered, but anything else tar reports is
  # kept.  The pipeline's status is deliberately ignored: tar exits non-zero for
  # that harmless warning even though everything unpacked.
  tar -xaf "$archive" -C "$dest" --strip-components=1 "$@" 2>&1 |
    grep -v -e 'lone zero block' -e 'Ignoring bad extended header' >&2 || true
  [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]
}

# fetch_archive <url> <destination dir> [extra tar options]
#
# Piping $CURL straight into tar is fragile: curl without --fail writes the body of
# an error page into the pipe, tar then unpacks nothing, and the build only dies
# much later with something like
#   CMake Error: The source directory ".../deps/jpeg-xl" does not appear to contain
#   CMakeLists.txt.
# So the archive is kept in a file, unpacked from it, and the unpacked tree is
# verified before continuing.
fetch_archive() {
  local url="$1" dest="$2"
  shift 2
  local key cache part attempt
  # A flat, filesystem-safe name that keeps the ".tar.gz"/".tar.xz" suffix so that
  # tar -a can still pick the right decompressor.
  key=$(printf '%s' "$url" | tr -c 'A-Za-z0-9._-' '_')
  cache="$DL_CACHE/$key"
  mkdir -p "$DL_CACHE"

  if [ -s "$cache" ]; then
    if unpack_archive "$cache" "$dest" "$@"; then
      echo "From download cache: $(basename "$url")"
      return 0
    fi
    # Should not happen (only verified archives are cached), but a damaged cache
    # entry must not fail the build: drop it and fetch again.
    echo "Warning: cached copy of $(basename "$url") did not unpack, re-downloading" >&2
    rm -f "$cache"
  fi

  part="$DL_CACHE/.part-$key"
  for attempt in 1 2 3; do
    if $CURL --fail -o "$part" "$url"; then
      break
    fi
    echo "Warning: download failed (attempt $attempt/3): $url" >&2
    sleep 5
  done
  if unpack_archive "$part" "$dest" "$@"; then
    mv -f "$part" "$cache"
    return 0
  fi
  rm -f "$part"
  echo "ERROR: could not download and unpack $url into $dest" >&2
  exit 1
}
