#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Rebuild a GNU import library (*.dll.a) for a DLL that was renamed after the
# link step.
#
#   usage: gen-implib.sh <dll> <out-implib> <dll-name> [reference-implib]
#
# Why this exists
# ---------------
# libvips is built as a static archive and linked into the C++ binding target,
# so meson produces libvips-cpp-42.dll plus libvips-cpp.dll.a, whose import
# descriptors name "libvips-cpp-42.dll". The package ships the DLL as
# libvips-42.dll, so that import library points at a file that no longer exists
# and has to be regenerated against the final DLL.
#
# The part that is easy to get wrong is that a PE import library must know which
# exports are DATA. Vtables (_ZTV*), typeinfo (_ZTI*), ptypeinfo (_ZTS*) and
# exported global variables are data: a reference to them has to be resolved
# through the __imp_ thunk. If dlltool treats them as functions it emits a plain
# text symbol, the linker then hands the caller the address of the import thunk
# (which points at the import *name string*), and the object ends up with a vptr
# aimed at garbage - the first virtual call segfaults. Concretely, every
# vips::VOption created through VImage::option() crashed on destruction.
#
# ld already worked all of this out when it built the original import library,
# so when that library is available it is used as the source of truth for both
# the symbol list and the DATA classification. Only if it is missing do we fall
# back to reading the DLL's export table with a name-based heuristic.

set -e

DLL="$1"
OUT_IMPLIB="$2"
DLL_NAME="$3"
REF_IMPLIB="${4:-}"

if [ -z "$DLL" ] || [ -z "$OUT_IMPLIB" ] || [ -z "$DLL_NAME" ]; then
  echo "usage: gen-implib.sh <dll> <out-implib> <dll-name> [reference-implib]" >&2
  exit 1
fi
if [ ! -f "$DLL" ]; then
  echo "ERROR: $DLL does not exist." >&2
  exit 1
fi

MACHINE=i386:x86-64
case "$(cc -dumpmachine 2>/dev/null)" in
  aarch64*|arm64*) MACHINE=arm64 ;;
  i386*|i686*) MACHINE=i386 ;;
esac

DEF="$(mktemp "${TMPDIR:-/tmp}/gen-implib.XXXXXX.def")"
BODY="$(mktemp "${TMPDIR:-/tmp}/gen-implib.XXXXXX.body")"
trap 'rm -f "$DEF" "$BODY"' EXIT

if [ -n "$REF_IMPLIB" ] && [ -f "$REF_IMPLIB" ]; then
  echo "  import library source: export table of $REF_IMPLIB"
  # ld marks a data import with a "__nm_<name>" record and never emits a plain
  # text symbol for it; functions get a plain "T" symbol plus "__imp_<name>".
  nm "$REF_IMPLIB" 2>/dev/null | awk '
    $2 == "T" && $3 !~ /^__imp_/ && $3 !~ /^__nm_/ { fn[$3] = 1; next }
    $2 == "I" && $3 ~ /^__nm_/ {
      s = substr($3, 6)
      if (s != "") data[s] = 1
      next
    }
    END {
      for (s in data) print "  " s " DATA"
      for (s in fn) if (!(s in data)) print "  " s
    }
  ' > "$BODY"
else
  echo "  import library source: objdump export table of $DLL"
  objdump -p "$DLL" 2>/dev/null | awk '
    /^[ \t]*\[[ 0-9]+\][ \t]+\+base\[[ 0-9]+\]/ {
      name = $NF
      if (name == "RVA" || name ~ /Export/) next
      if (name !~ /^[A-Za-z_]/) next
      if (name ~ /^_Z(TV|TI|TS)/) data[name] = 1
      else fn[name] = 1
    }
    END {
      for (s in data) print "  " s " DATA"
      for (s in fn) if (!(s in data)) print "  " s
    }
  ' > "$BODY"
fi

if [ ! -s "$BODY" ]; then
  echo "ERROR: could not extract any exports; import library not regenerated." >&2
  exit 1
fi

{
  echo "LIBRARY $DLL_NAME"
  echo "EXPORTS"
  sort "$BODY"
} > "$DEF"

dlltool --machine "$MACHINE" --dllname "$DLL_NAME" \
  --input-def "$DEF" \
  --output-lib "$OUT_IMPLIB"

# Sanity checks: the import library must name the DLL we actually ship, and no
# export that was classified as data may have leaked out as a plain text symbol.
implib_dlls="$(strings "$OUT_IMPLIB" | grep -oE '[A-Za-z0-9_.+-]*\.dll' | sort -u | tr '\n' ' ')"
if ! printf '%s' "$implib_dlls" | grep -q "$DLL_NAME"; then
  echo "ERROR: $OUT_IMPLIB does not reference $DLL_NAME (saw: $implib_dlls)." >&2
  exit 1
fi

data_leaks=0
if [ -s "$BODY" ]; then
  IMPLIB_SYMS="$(mktemp "${TMPDIR:-/tmp}/gen-implib.XXXXXX.syms")"
  DATA_SYMS="$(mktemp "${TMPDIR:-/tmp}/gen-implib.XXXXXX.data")"
  LEAKS="$(mktemp "${TMPDIR:-/tmp}/gen-implib.XXXXXX.leaks")"
  trap 'rm -f "$DEF" "$BODY" "$IMPLIB_SYMS" "$DATA_SYMS" "$LEAKS"' EXIT
  nm "$OUT_IMPLIB" 2>/dev/null | awk '$2 == "T" { print $3 }' | sort > "$IMPLIB_SYMS"
  grep ' DATA$' "$DEF" | awk '{ print $1 }' | sort > "$DATA_SYMS"
  comm -12 "$DATA_SYMS" "$IMPLIB_SYMS" > "$LEAKS"
  data_leaks="$(wc -l < "$LEAKS")"
  if [ "$data_leaks" -ne 0 ]; then
    echo "  WARNING: $data_leaks data export(s) emitted as function imports:" >&2
    head -10 "$LEAKS" >&2
  fi
fi

echo "  $(grep -c '^  ' "$DEF") exports regenerated into $OUT_IMPLIB (references: $implib_dlls)"
[ "$data_leaks" -eq 0 ] || exit 1
