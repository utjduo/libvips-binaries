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

| Platform | Architecture  | Build method                                      |
|----------|---------------|---------------------------------------------------|
| macOS    | arm64, x86_64 | Native (Clang + Homebrew deps)                    |
| Linux    | x86_64, arm64 | Rocky Linux 8 Docker (glibc 2.28)                 |
| Windows  | x64           | MSYS2 (UCRT64) native build, single static DLL    |

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

| Input | Type | Description |
|-------|------|-------------|
| `version` | string | libvips version, e.g. `8.18.2` |
| `mac_x64` | boolean | Build macOS x86_64 (`darwin-x64`) |
| `mac_arm` | boolean | Build macOS arm64 (`darwin-arm64`) |
| `linux_x64` | boolean | Build Linux x86_64 (`linux-x64`) |
| `linux_arm` | boolean | Build Linux arm64 (`linux-arm64`) |
| `win_x64` | boolean | Build Windows x86_64 (`win-x64`) |
| `codecs` | string | Optional codecs: comma-separated list, or `all` / `default` |
| `create_release` | boolean | Publish the built tarballs as a GitHub Release |

> GitHub allows a maximum of **10** `workflow_dispatch` inputs, which is why
> codecs are selected with a single comma-separated `codecs` string instead of
> one checkbox per codec.

### Codecs

**Core codecs are always included** (no option needed): JPEG, PNG, WebP, TIFF,
HEIF/AVIF, UHDR (gain maps), GIF, SVG, EXIF, LCMS, imagequant, archive, highway
and the Pango/Cairo/FontConfig/HarfBuzz text-rendering stack.

`codecs` adds *optional* codecs on top:

| Category | Values | Notes |
|----------|--------|-------|
| Extra codecs | `spng`, `openjpeg`, `openexr`, `jpeg-xl`, `fftw`, `cfitsio`, `matio`, `raw` | macOS/Linux build the dependency from source and statically link it (e.g. `openexr` also builds Imath, `jpeg-xl` also builds brotli + highway); Windows uses the matching MSYS2 package when one is available (`openexr` is not available there) |
| Built-in formats (no dependency) | `ppm`, `analyze`, `radiance`, `qoi`, `nsgif` | Compiled directly into libvips |
| Aliases | `jxl`/`jpegxl`, `exr`, `jp2`/`jpeg2000`, `libspng`, `libraw`, `fits`, `matlib`, `fft` | Convenience spellings |

Special values:

- `all` — every codec supported by this workflow (list above).
- `default` (or leaving the field blank when running `build.sh` directly) — the
  historical behaviour: only `qoi` + `nsgif` built-ins, no extra codecs.

Example: `codecs: jpeg-xl,openjpeg,exr,ppm` produces a build with JPEG-XL,
JPEG2000, OpenEXR and PPM support.

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

| you type | what it means |
|----------|---------------|
| `1-4,9` | the 1st through 4th entries plus the 9th |
| `all` / `none` | every optional codec / no extra codecs |
| `default` | `nsgif,qoi`, the same default the Action uses |
| `jxl`, `jp2`, `exr` | `jpeg-xl`, `openjpeg`, `openexr` |

`--list-codecs` prints the catalogue without building anything:

```text
spng        PNG via libspng
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

Options: `-p/--platforms`, `-c/--codecs`, `-v/--version`, `-i/--interactive`,
`-y/--yes` (ask nothing), `--clean` / `--no-clean`, `--dry-run`,
`--list-codecs`, `--list-platforms`, `-h/--help`.

The codec list is read from `build-scripts/codecs.sh`, which is also the file
`build.sh` and the Actions source, so the menu can never drift from what the
build actually supports. `--version 8.19.0` rewrites `VERSION_VIPS` in
`versions.properties`, exactly like the Action's `version` input does.




## Build scripts

| Script           | Platform      | Notes                                                        |
|------------------|---------------|--------------------------------------------------------------|
| `build.sh`       | All           | Dispatcher — macOS natively, Linux via Docker, Windows via MSYS2 |
| `build-selectable.sh` | All      | Terminal menu: pick platforms + codecs, then calls `build.sh` per platform |
| `build-selectable.ps1` | Windows   | PowerShell front end: asks in PowerShell, runs the build in MSYS2 |
| `build-selectable.bat` | Windows   | Starts `build-selectable.ps1` from cmd.exe / double-click |
| `build-scripts/codecs.sh` | All | Shared `CODECS` parsing + libvips meson feature flags        |
| `build-scripts/gen-implib.sh` | Windows | Rebuilds the `libvips.dll.a` import library against the shipped DLL |
| `build-scripts/posix.sh` | macOS + Linux | Full source build, statically links deps into one shared lib  |
| `build-scripts/win.sh`   | Windows   | MSYS2 (UCRT64) source build, statically links deps into one DLL |

`build-scripts/posix.sh` is derived from [lovell/sharp-libvips](https://github.com/lovell/sharp-libvips)
under the Apache 2.0 license; the Windows build (`build-scripts/win.sh`) is our
own MSYS2 implementation.
