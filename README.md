# libvips-binaries

Pre-built libvips shared libraries for all major platforms.

Used by [phpmlkit/opal](https://github.com/phpmlkit/opal) (and potentially other projects)
to avoid requiring users to have libvips installed system-wide.

## License

Apache 2.0. See [LICENSE](LICENSE).

This repository is **heavily based on** [lovell/sharp-libvips](https://github.com/lovell/sharp-libvips),
the binary build system that powers [sharp](https://sharp.pixelplumbing.com/).
We adapted their build scripts for our own release pipeline — huge thanks to Lovell Fuller
and the sharp team for their excellent work.

## Platforms

| Platform | Architecture  | Build method                                   |
| -------- | ------------- | ---------------------------------------------- |
| macOS    | arm64, x86_64 | Native (Clang + Homebrew deps)                 |
| Linux    | x86_64, arm64 | Rocky Linux 8 Docker (glibc 2.28)              |
| Windows  | x64           | MSYS2 (UCRT64) native build, single static DLL |

## Usage

Trigger the workflow manually with a version number. The matrix builds for all
platforms in parallel, or you can select specific platforms. When `create_release`
is enabled, a GitHub Release is created with `.tar.gz` assets:

```
libvips-darwin-arm64.tar.gz
libvips-darwin-x64.tar.gz
libvips-linux-x64.tar.gz
libvips-linux-arm64.tar.gz
libvips-win-x64.tar.gz
```

## Selectable builds (workflow `Build (selectable OS + codecs)`)

`build-selectable.yml` is an alternative to `build.yml` that lets you choose, per
run, **which operating systems** and **which optional codecs** to compile. Unlike
`build.yml` (which always starts a runner for every platform), the `prepare` job
computes the matrix from your toggles, so unselected platforms never run. Every
built platform is uploaded as a downloadable workflow artifact (and optionally
attached to a GitHub Release).

### Inputs

| Input            | Type    | Description                                                 |
| ---------------- | ------- | ----------------------------------------------------------- |
| `version`        | string  | libvips version, e.g. `8.18.7`                              |
| `mac_x64`        | boolean | Build macOS x86_64 (`darwin-x64`)                           |
| `mac_arm`        | boolean | Build macOS arm64 (`darwin-arm64`)                          |
| `linux_x64`      | boolean | Build Linux x86_64 (`linux-x64`)                            |
| `linux_arm`      | boolean | Build Linux arm64 (`linux-arm64`)                           |
| `win_x64`        | boolean | Build Windows x86_64 (`win-x64`)                            |
| `codecs`         | string  | Optional codecs: comma-separated list, or `all` / `default` |
| `preset`         | choice  | Build preset: `full`, `lean`, `aggressive`, `image`         |
| `features`       | string  | Single features on top of the preset, `name=on\|off` pairs  |
| `create_release` | boolean | Publish the built tarballs as a GitHub Release              |

> GitHub allows a maximum of **10** `workflow_dispatch` inputs, which is why
> codecs are selected with a single comma-separated `codecs` string instead of
> one checkbox per codec.

### Codecs

**Always included** (no option needed): JPEG, PNG, WebP, GIF loading, HEIF/AVIF,
EXIF, LCMS and the magick loader that `svgload` uses. TIFF, `dzsave`, `svgload`,
`textload`, UltraHDR, the GIF quantiser (and with it GIF **saving**) and the HEVC
encoder depend on the build preset - see [Build presets](#build-presets-preset-and-single-features-features).

`codecs` adds *optional* codecs on top:

| Category                         | Values                                                                                | Notes                                                                                                                                                                                                                                            |
| -------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Extra codecs                     | `spng`, `openjpeg`, `openexr`, `jpeg-xl`, `fftw`, `cfitsio`, `matio`, `raw`           | macOS/Linux build the dependency from source and statically link it (e.g. `openexr` also builds Imath, `jpeg-xl` also builds brotli + highway); Windows uses the matching MSYS2 package when one is available (`openexr` is not available there) |
| Built-in formats (no dependency) | `ppm`, `analyze`, `radiance`, `qoi`, `nsgif`                                          | Compiled directly into libvips                                                                                                                                                                                                                   |
| Aliases                          | `jxl`/`jpegxl`, `exr`, `jp2`/`jpeg2000`, `libspng`, `libraw`, `fits`, `matlib`, `fft` | Convenience spellings                                                                                                                                                                                                                            |

Special values:

- `all` — every codec supported by this workflow (list above).
- `default` (or leaving the field blank when running `build.sh` directly) — the
  historical behaviour: only `qoi` + `nsgif` built-ins, no extra codecs.

Example: `codecs: jpeg-xl,openjpeg,exr,ppm` produces a build with JPEG-XL,
JPEG2000, OpenEXR and PPM support.

#### PNG backend: libpng or libspng

libvips links **one** PNG backend, so `spng` is not a codec that sits next to PNG —
selecting it swaps libvips over to libspng (`-Dpng=disabled -Dspng=enabled`) and
libpng is left out of the library.

* The `pngload` / `pngsave` operations, `vips_image_new_from_file()`,
  `vips_image_write_to_file()` and the C++ `vips::VImage::pngsave()` all keep
  working whichever backend was chosen.
* The C convenience wrappers `vips_pngload()`, `vips_pngload_buffer()` and
  `vips_pngsave()` live in `libvips/foreign/pngload.c` / `pngsave.c` *outside* their
  `#ifdef HAVE_PNG` block, so they are compiled even when spng is selected. Nothing
  else in the library references them, so `-Wl,--gc-sections` would drop them from
  the Windows DLL; `build-scripts/win.sh` names them with `-Wl,--undefined=` to keep
  them exported. The spng build therefore exports the same C API as the libpng one.
* `versions.json` reports `spng` instead of `png` so the manifest matches what was
  actually linked.

### Build presets (`PRESET`) and single features (`FEATURES`)

`PRESET` trades formats for size. It disables whole dependency chains that are heavy
to link and rarely used by an image pipeline, and it applies to every build script
(`build.sh`, `build-selectable.sh`, `build-selectable.ps1`, and the workflows'
`preset` input) because `build-scripts/codecs.sh` translates it into libvips meson
flags *and* the dependency install/build steps.

| `PRESET` | what stays | what is dropped |
| -------- | ---------- | --------------- |
| `full` (or `0`) | everything | nothing |
| `lean` (or `1`) | JPEG, PNG/libspng, WebP, TIFF, AVIF, HEIC decode, GIF load **and save**, `dzsave`, imagequant, EXIF, LCMS, highway | librsvg (+ fontconfig, harfbuzz, pixman, cairo, freetype, expat) → `svgload`; pango + fribidi → `textload`; libuhdr (UltraHDR gain maps); x265 (HEVC **encode**) |
| `aggressive` (or `2`) | as above minus TIFF, `dzsave` and GIF saving | the `lean` list **plus** libtiff → `tiffload` / `tiffsave`, libarchive → `dzsave`, libimagequant → quantisation and `gifsave` (`gifload` stays) |
| `image` | as `aggressive`, plus GIF saving and the quantiser | the `aggressive` list, **except** libimagequant is kept: `gifsave` and the quantised PNG/WebP saving paths remain |

`FEATURES` then flips single formats on top of whatever preset was chosen, as
comma-separated `name=on|off` pairs:

| Feature | Turns on/off |
| ------- | ------------ |
| `svgload` | `svgload` (librsvg + the cairo/pixman/fontconfig/harfbuzz stack) |
| `textload` | `textload` (pango + fribidi) |
| `uhdr` | UltraHDR gain maps (libuhdr) |
| `tiffload` | `tiffload` / `tiffsave` (libtiff) |
| `dzsave` | `dzsave` (libarchive) |
| `imagequant` | the quantiser (libimagequant): **`gifsave`** plus the quantised PNG/WebP saving paths |
| `exif` | EXIF read/write through libexif instead of GExiv2 |
| `lcms` | colour management (little cms) |
| `heif_dec` | HEIC/HEVC **decode** through libde265 |
| `heif_enc` | HEVC/HEIC **encode** through x265 (GPL-2.0-or-later, ~21 MB) |

Example - the smallest build that still writes HEIC and GIF files:

```bash
PRESET=aggressive FEATURES=heif_enc=on,imagequant=on bash build.sh win-x64
```

`PRESET` defaults to `full` for `build.sh` and for an unattended
`build-selectable.sh`. An inherited `PRESET` (or the old `LEAN`) environment
variable is what `build-selectable.sh` falls back to when `--preset` is not given —
that is how the workflows pass their input down — and an explicit `--preset` always
wins over the environment. The interactive prompts in `build-selectable.sh` and
`build-selectable.ps1`, and the `Build (selectable OS + codecs)` workflow, offer
`lean` as their default. `LEAN=0/1/2`, `--lean` and `HEIF_HEVC_ENCODER` still work
as aliases for the equivalent preset/feature.

Details worth knowing:

- `svgload` / `svgload_buffer` are the only users of librsvg, and libvips has no
  `svgsave`, so trimming librsvg removes loading only.
- `thumbnail` keeps working at every level: it goes through `VipsForeignLoad` and,
  for HEIF/AVIF, through libheif's own thumbnail loader — it never needs librsvg or
  pango.
- `dzsave` is libvips' only use of libarchive, so it disappears with the
  `aggressive` and `image` presets.
- UltraHDR (`vips_heifsave(..., "uhdr", ...)`) needs libuhdr; AVIF and HEIF still
  work without it.
- HEIF/HEIC **decode** comes from libde265, which `build-scripts/posix.sh` builds
  from source (`VERSION_DE265` in `versions.properties`) and which Windows installs
  as an MSYS2 package - whenever `heif_dec` is on, i.e. in every preset unless it is
  explicitly switched off with `FEATURES=heif_dec=off`. HEVC **encode** needs x265
  (`heif_enc`), which is GPL-2.0-or-later and about 21 MB, so only `full` builds it
  without an explicit `FEATURES=heif_enc=on`.
- Without libimagequant (`imagequant=off`) the `vips__quantise_*` helpers are gone, and
  with them the quantised PNG/WebP saving paths - libvips 8.18 has no separate
  `quantise` or `dbsat` operation any more, the quantiser is internal to the savers.
  GIF **saving** goes too: libvips compiles `cgifsave.c` only when a
  quantiser is available (`HAVE_CGIF && HAVE_QUANTIZATION`), so such a build still
  reads GIFs (`gifload`) but cannot write them. Use the `image` preset or
  `FEATURES=imagequant=on` if the package must save GIFs.
- Trimming is visible in the binary. Measured on the Windows x64 DLL (libvips
  8.18.7, `CODECS=spng,openjpeg,jpeg-xl,nsgif`, before libde265 was added): `full`
  is 73.10 MiB with 1601
  `vips_*` exports, `lean` is 29.61 MiB with 1569 — the 32 that go are
  `vips_svgload*`, `vips_text`, `vips_uhdrload*`, `vips_uhdrsave*`, their
  `VipsForeignLoad*` / `VipsForeignSave*` types and the `vips__uhdr_*` helpers —
  and `aggressive` is 25.72 MiB with 1512, so 89 exports in total, adding
  `vips_tiff*`, `vips_dzsave*`, `vips_gifsave*`, `vips__quantise_*` and
  `vips__archive_*`. The import table shrinks as well: `lean` loses
  `DWrite.dll`, `GDI32.dll`, `gdiplus.dll`, `MSIMG32.dll`, `bcrypt.dll`,
  `RPCRT4.dll` and `USP10.dll`.
- Measured with the current dependency set, `image` is 26.8 MiB, and
  `image` plus `FEATURES=heif_enc=on` is 48.2 MiB with 1636 exports: HEIC encode
  adds no exports at all — `vips_heifsave` was already there — it only makes that
  one entry point able to write `.heic`, because x265 (~21 MB) is linked in.
- Code that calls a trimmed C entry point directly does not link against a trimmed
  package at all — the linker reports `undefined reference to 'vips_svgload'` — so
  such code needs a full build.
- The C++ API is unaffected either way: `vips::VImage::svgload()` and friends are
  generated as operation-name dispatches rather than direct calls to
  `vips_svgload()`, so a program that uses them still compiles and links against a
  trimmed DLL, and the call fails at runtime with
  `VipsOperation: class "svgload" not found`, thrown as a `vips::VError`. That is
  why `cplusplus/vips8` carries no per-format `#ifdef`: one header serves every
  trim level.
- The preset is recorded as `"preset"` and the resolved feature list as `"features"`
  in the artifact's `versions.json`, and `build-scripts/smoke-test.sh` reads them so
  a trimmed build is not failed for the formats it deliberately left out.

### Not built from source

`magick` (ImageMagick), `poppler`, `pdfium`, `openslide`, `nifti`, `orc` and
`quantizr` are intentionally **not** compiled by these scripts — they need large
or awkward dependency chains. They are always passed to libvips as
`-D<feature>=disabled`.

### Windows: one self-contained DLL

Windows is no longer a downloaded prebuilt bundle. It is built **from source,
natively, on a `windows-2025` runner inside MSYS2 (UCRT64)**, and everything is
linked into a **single `lib/libvips-42.dll`** that imports only Windows system
DLLs:

- `build-scripts/win.sh` installs most dependencies as MSYS2 packages (unlike most
  distributions, MSYS2 ships both shared and static libraries). The `*.dll.a`
  import libraries are moved aside so the MinGW linker picks the static archives
  (`*.a`), a `pkg-config --static` wrapper is used, and the needed
  `*_STATIC`/`*_STATIC_DEFINE` macros are defined (e.g.
  `CAIRO_WIN32_STATIC_BUILD`) so nothing references the DLL import stubs.
- `-static-libgcc` removes the last non-system dependency (`libgcc_s_*.dll`);
  `-Wl,--allow-multiple-definition` is needed because MSYS2's `librsvg` static
  archive also bundles cairo.
- `-Wl,--export-all-symbols` makes the DLL export everything it links in, which
  matters for **GLib** (`g_free`, `g_object_unref`, …). ELF/Mach-O shared
  libraries export all symbols by default, but MinGW only exports symbols marked
  `dllexport`, so without this a host that resolves GLib through the DLL (for
  example a LuaJIT FFI binding) fails with "cannot resolve symbol 'g_free'".
- libvips itself is compiled as a static library and folded into the C++
  library (the same trick `build-scripts/posix.sh` uses), so exactly one DLL is produced.
- Three dependencies are rebuilt from source because MSYS2 does not package them
  or ships them shared-only: **cgif** (GIF save — not packaged at all),
  **libarchive** (dzsave — its static archive references the zlib DLL import
  stubs) and **libheif** (AVIF — built against the static `aom`).
- `codecs` maps to MSYS2 packages (`libjxl`, `openjpeg2`, `fftw`, `cfitsio`,
  `matio`, `libraw`). If a codec's package is unavailable it is silently left
  out, so `all` still succeeds.

Known differences from the POSIX builds:

- **OpenEXR** is unavailable — MSYS2 ships it shared-only and it is not rebuilt
  from source.
- **HEIC** decode is unavailable (AVIF only), because libheif is built without
  libde265/x265 — the same as the POSIX build.

The tarball contains `include/` (libvips + GLib headers), the single
`lib/libvips-42.dll`, its import library `lib/libvips.dll.a`, `versions.json`
and the third-party notices.

> The Windows target requires a `windows-2025` runner. Running
> `bash build.sh win-x64` outside an MSYS2 shell exits with an error.

### Artifacts

Each platform uploads `libvips-<platform>.tar.gz` as a workflow artifact named
`build-<platform>` (`build-darwin-arm64`, `build-darwin-x64`, `build-linux-x64`,
`build-linux-arm64`, `build-win-x64`). Download them from the run's *Artifacts*
section, or enable `create_release` to also publish them as a Release.

### Verifying a build

`build-scripts/smoke-test.sh` compiles `build-scripts/smoke-test.c` against the
package in `target/` and runs it. It checks that the operations belonging to the
requested codecs were compiled in, then encodes and decodes PNG, JPEG, TIFF, WebP
and AVIF — plus JPEG 2000, JPEG XL and GIF when those codecs were selected — and
writes a deep-zoom tree. `build-scripts/win.sh` runs it against the finished package
just before the tarball is made; `build-scripts/posix.sh` runs it straight after
`meson install`, since that script deletes `target/lib/pkgconfig` - the only place
`vips.pc` is guaranteed to exist - and then filters and renames `target/lib` before
packaging. Either way, a library that cannot actually load and save images fails the
build instead of failing whoever downloads it; set `SMOKE_TEST=0` to skip that step.

It reads the trim level from `LEAN`, or from the `"lean"` entry the build wrote to
`target/versions.json`, and reports the formats trimming removed as trimmed rather
than counting them as failures.

```sh
bash build.sh win-x64
bash build-scripts/smoke-test.sh spng openjpeg jpeg-xl nsgif
```

It exits non-zero when a requested codec is missing, which makes it the quickest way
to confirm a selection really made it into the library. Saving goes through
`vips_image_write_to_file()` rather than the format-specific wrappers, because a
trimmed build does not export those at all — calling `vips_dzsave()` or
`vips_svgload()` directly against a trimmed package fails at link time.

## Building from a terminal, with a menu

The same thing the selectable Action does, but locally:

```bash
./build-selectable.sh                    # asks for version, platforms and codecs
./build-selectable.sh --dry-run          # show the plan, build nothing
./build-selectable.sh -c all -v 8.19.0   # everything, no questions asked
```

On Windows, start it with `build-selectable.bat` (or `.\build-selectable.ps1`):
it asks the questions in PowerShell and then runs the build inside MSYS2, so you
do not have to open an "MSYS2 UCRT64" shell first. It finds MSYS2 at
`C:\msys64`, `C:\msys32`, `$env:MSYS2_INSTALL` or from a `bash.exe` on your PATH.

Anything not given as an option is asked for. Codecs and platforms can be picked
by number, range, name or shortcut:

| you type            | what it means                                 |
| ------------------- | --------------------------------------------- |
| `1-4,9`             | the 1st through 4th entries plus the 9th      |
| `all` / `none`      | every optional codec / no extra codecs        |
| `default`           | `nsgif,qoi`, the same default the Action uses |
| `jxl`, `jp2`, `exr` | `jpeg-xl`, `openjpeg`, `openexr`              |

`--list-codecs` prints the catalogue without building anything:

```text
spng        PNG via libspng (replaces the libpng backend)
openjpeg    JPEG 2000 (jp2)
openexr     OpenEXR (exr), also builds Imath
jpeg-xl     JPEG XL (jxl), also builds brotli + highway
fftw        FFTW, used by FFT-based operations
cfitsio     FITS astronomical images
matio       MATLAB .mat files
raw         Camera RAW via libraw
ppm         PPM/PNM (built in, no dependency)
analyze     Analyze/.img (built in, no dependency)
radiance    Radiance .hdr (built in, no dependency)
qoi         QOI (built in, needs libvips >= 8.19)
nsgif       GIF loading (built in, no dependency)
```

Options: `-p/--platforms`, `-c/--codecs`, `--lean` (`full`/`lean`/`aggressive` or
`0`/`1`/`2`), `-v/--version`, `-i/--interactive`,
`-y/--yes` (ask nothing), `--clean` / `--no-clean`, `--dry-run`,
`--list-codecs`, `--list-platforms`, `-h/--help`.

The codec list is read from `build-scripts/codecs.sh`, which is also the file
`build.sh` and the Actions source, so the menu can never drift from what the
build actually supports. `--version 8.19.0` rewrites `VERSION_VIPS` in
`versions.properties`, exactly like the Action's `version` input does.




## Build scripts

| Script                        | Platform      | Notes                                                                      |
| ----------------------------- | ------------- | -------------------------------------------------------------------------- |
| `build.sh`                    | All           | Dispatcher — macOS natively, Linux via Docker, Windows via MSYS2           |
| `build-selectable.sh`         | All           | Terminal menu: pick platforms + codecs, then calls `build.sh` per platform |
| `build-selectable.ps1`        | Windows       | PowerShell front end: asks in PowerShell, runs the build in MSYS2          |
| `build-selectable.bat`        | Windows       | Starts `build-selectable.ps1` from cmd.exe / double-click                  |
| `build-scripts/codecs.sh`     | All           | Shared `CODECS` parsing + libvips meson feature flags                      |
| `build-scripts/gen-implib.sh` | Windows       | Rebuilds the `libvips.dll.a` import library against the shipped DLL        |
| `build-scripts/smoke-test.sh` | All           | Builds `smoke-test.c` against `target/` and round-trips the selected codecs; `win.sh` / `posix.sh` run it before packaging |
| `build-scripts/posix.sh`      | macOS + Linux | Full source build, statically links deps into one shared lib               |
| `build-scripts/win.sh`        | Windows       | MSYS2 (UCRT64) source build, statically links deps into one DLL            |

`build-scripts/posix.sh` is derived from [lovell/sharp-libvips](https://github.com/lovell/sharp-libvips)
under the Apache 2.0 license; the Windows build (`build-scripts/win.sh`) is our
own MSYS2 implementation.
