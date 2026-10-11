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
    docker build --pull -t "vips-dev-$flavour" "platforms/$flavour"
    docker run --rm -e "CODECS=${CODECS:-}" -v $PWD:/packaging "vips-dev-$flavour" sh -c "/packaging/build-scripts/posix.sh"
  fi
done
