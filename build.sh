#!/usr/bin/env bash
set -e

## Based on build.sh from lovell/sharp-libvips (Apache 2.0)
## Copyright 2017 Lovell Fuller and others.
## SPDX-License-Identifier: Apache-2.0

# Dependency version numbers
source ./versions.properties

if [ $# -lt 1 ]; then
  echo
  echo "Usage: $0 PLATFORM"
  echo "Build shared libraries for libvips and its dependencies"
  echo
  echo "Possible values for PLATFORM are:"
  echo "- win-x64"
  echo "- win-arm64"
  echo "- linux-x64"
  echo "- linux-arm64"
  echo "- darwin-x64"
  echo "- darwin-arm64"
  echo
  echo "Environment variables:"
  echo "- CODECS       comma-separated optional codecs to build (or 'all'/'default')"
  echo "               supported: spng, openjpeg, openexr, jpeg-xl, fftw, cfitsio,"
  echo "                          matio, raw, ppm, analyze, radiance, qoi, nsgif"
  echo "- PRESET       full (default), lean, aggressive or image: how much to trim"
  echo "               lean       = no svgload, no textload, no UltraHDR, no HEVC encode"
  echo "               aggressive = as lean, plus no tiff, no dzsave, no quantiser"
  echo "                          (and therefore no gifsave)"
  echo "               image      = aggressive but keeps the quantiser: the"
  echo "                          codec-only build, jpeg/png/webp/heic/avif/gif"
  echo "               LEAN=0/1/2 is the same knob spelled as a number and still works"
  echo "- FEATURES     override individual features of the preset, e.g."
  echo "               FEATURES=tiff=on,heif_enc=on"
  echo "               features: svg text uhdr tiff dzsave imagequant exif lcms"
  echo "                         heif_dec heif_enc"
  echo "- DL_CACHE       where the downloaded dependency sources are kept"
  echo "               (default: .dl-cache in the workspace).  Every archive is pinned"
  echo "               in versions.properties, so a warm directory means nothing has"
  echo "               to be downloaded again.  See build-scripts/fetch.sh."
  echo "- DOCKER_BUILD_CACHE"
  echo "               set to reuse the layers of the Linux toolchain image instead of"
  echo "               rebuilding them: the GitHub Actions cache backend when"
  echo "               GITHUB_ACTIONS=true, otherwise .docker-cache/<platform>."
  echo "               Requires docker buildx."
  echo
  echo "Note: Windows builds must be run from an MSYS2 shell (the build-scripts/win.sh"
  echo "script links every dependency statically into a single libvips DLL)."
  echo
  exit 1
fi
PLATFORM="$1"

# macOS
for flavour in darwin-x64 darwin-arm64; do
  if [ $PLATFORM = $flavour ] && [ "$(uname)" == "Darwin" ]; then
    echo "Building $flavour..."

    export CC="clang"
    export CXX="clang++"

    export PLATFORM

    export PKG_CONFIG="$(brew --prefix)/bin/pkg-config --static"

    if [ $PLATFORM = "darwin-arm64" ]; then
      export MACOSX_DEPLOYMENT_TARGET="11.0"
    else
      export MACOSX_DEPLOYMENT_TARGET="10.15"
    fi

    export FLAGS="-fno-stack-check"
    export FLAGS+=" -Werror=unguarded-availability-new"
    export MESON="--cross-file=$PWD/platforms/$PLATFORM/meson.ini"

    source $PWD/versions.properties
    source $PWD/build-scripts/posix.sh

    exit 0
  fi
done

# Windows (native MSYS2 build: statically links every codec into one DLL)
for flavour in win-x64 win-arm64; do
  if [ $PLATFORM = $flavour ]; then
    if [ -z "${MSYSTEM:-}" ]; then
      echo "Windows builds must be run from an MSYS2 shell (MSYSTEM is unset)." >&2
      exit 1
    fi
    echo "Building $flavour (MSYS2 $MSYSTEM)..."
    export PLATFORM
    source $PWD/build-scripts/win.sh
    exit 0
  fi
done

# Is docker available?
if ! [ -x "$(command -v docker)" ]; then
  echo "Please install docker"
  exit 1
fi

# Linux
for flavour in linux-x64 linux-arm64; do
  if [ $PLATFORM = $flavour ]; then
    echo "Building $flavour..."
    # The image is the whole toolchain (dnf packages, rustup + cargo-c, meson/ninja),
    # and rebuilding those layers costs several minutes on every run.  With
    # DOCKER_BUILD_CACHE set, BuildKit keeps them: the GitHub Actions cache backend
    # in CI, a directory in the workspace locally.  --pull is kept either way, so a
    # new rockylinux:8 digest still invalidates everything built on top of it.
    if [ -n "${DOCKER_BUILD_CACHE:-}" ]; then
      if [ "${GITHUB_ACTIONS:-}" = true ]; then
        CACHE_ARGS=(--cache-from type=gha --cache-to type=gha,mode=max)
      else
        mkdir -p "$PWD/.docker-cache/$flavour"
        CACHE_ARGS=(
          --cache-from "type=local,src=$PWD/.docker-cache/$flavour"
          --cache-to "type=local,dest=$PWD/.docker-cache/$flavour"
        )
      fi
      docker buildx build --pull --load "${CACHE_ARGS[@]}" \
        -t "vips-dev-$flavour" "platforms/$flavour"
    else
      docker build --pull -t "vips-dev-$flavour" "platforms/$flavour"
    fi
    # PRESET is only forwarded when it was actually set: codecs.sh reads PRESET
    # before LEAN, so passing a default PRESET would silently override a LEAN=2
    # request from the caller or the Actions workflow.
    BUILD_ENV=(-e "CODECS=${CODECS:-}" -e "LEAN=${LEAN:-}" -e "FEATURES=${FEATURES:-}")
    if [ -n "${PRESET:-}" ]; then
      BUILD_ENV+=(-e "PRESET=${PRESET}")
    fi
    docker run --rm "${BUILD_ENV[@]}" -v $PWD:/packaging "vips-dev-$flavour" sh -c "/packaging/build-scripts/posix.sh"
  fi
done
