/* ---------------------------------------------------------------------------
 * smoke-test.c - does the libvips package this repository just built actually
 * work?  It is compiled and run by build-scripts/smoke-test.sh, which works out
 * which of the checks below are required from the codec selection and the build
 * preset and passes them in as --require / --skip.
 *
 * Two rules keep this file usable against every package the build produces:
 *
 *   1. Every encode and decode goes through the generic
 *      vips_image_write_to_file() and vips_image_new_from_file().  A trimmed
 *      build does not export the format-specific wrappers at all
 *      (vips_dzsave(), vips_svgload(), vips_text(), ...), so a test that called
 *      them would fail to link against a package that is perfectly fine for the
 *      use it was built for.  Operations that can only be probed, never called
 *      (openexrload, dcrawload, qoiload), are probed with vips_operation_new().
 *   2. No GLib function is called.  On Linux the shipped libvips.so has GLib
 *      folded into it with --exclude-libs,ALL, so g_free() or g_object_unref()
 *      would be undefined symbols here even though the package works.  Only
 *      vips_* entry points are used, and objects are left to the process exit
 *      to release.
 *
 * Usage:
 *   smoke-test [--require id,id,...] [--skip id,id,...] [--workdir DIR]
 * Exit status:
 *   0  every required check passed
 *   1  a required check failed
 *   2  bad command line, or libvips would not start at all
 * ------------------------------------------------------------------------ */

#include <vips/vips.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define TEST_W 64
#define TEST_H 48

enum status { ST_PASS, ST_FAIL, ST_TRIMMED, ST_INFO, ST_WARN };

static const char *status_name[] = {
	"ok", "FAILED", "trimmed", "note", "warning"
};

static char workdir[1024] = ".";
static const char *require_list = "";
static const char *skip_list = "";

static int n_run = 0;
static int n_failed = 0;
static int n_trimmed = 0;

/* Is id one of the comma-separated names in list? */
static int
in_list(const char *list, const char *id)
{
	int len = (int) strlen(id);
	const char *p = list;

	while (*p) {
		const char *comma = strchr(p, ',');
		int n = comma ? (int) (comma - p) : (int) strlen(p);

		if (n == len && strncmp(p, id, (size_t) n) == 0)
			return 1;
		if (!comma)
			break;
		p = comma + 1;
	}

	return 0;
}

/* A check could not run because the operation is not in the library.  Whether
 * that is a failure depends on what the build was asked to produce: required
 * codecs fail, features the preset trimmed away are reported as trimmed, and
 * anything else is just information. */
static enum status
status_for_absent(const char *id)
{
	if (in_list(skip_list, id))
		return ST_TRIMMED;
	if (in_list(require_list, id))
		return ST_FAIL;
	return ST_INFO;
}

static char errline[512];

/* The first line of the libvips error buffer, cleared as a side effect. */
static const char *
vips_error_one_line(void)
{
	const char *e = vips_error_buffer();
	int i;

	for (i = 0; i < (int) sizeof errline - 1 && e && e[i] != 0 && e[i] != '\n'; i++)
		errline[i] = e[i];
	errline[i] = 0;
	vips_error_clear();

	return errline;
}

static void
report(const char *id, enum status st, const char *detail)
{
	/* A check the preset trimmed away may still fail at run time rather than
	 * at registration - libheif, for instance, registers a .heic writer even
	 * when the build has no x265.  That is a trim, not a fault. */
	if (st == ST_FAIL && in_list(skip_list, id))
		st = ST_TRIMMED;

	if (st == ST_PASS || st == ST_FAIL)
		n_run++;
	if (st == ST_FAIL)
		n_failed++;
	if (st == ST_TRIMMED)
		n_trimmed++;

	printf("  %-11s %-8s %s\n", id, status_name[st],
		detail && *detail ? detail : "");
	fflush(stdout);
}

static int
file_exists(const char *path)
{
	struct stat st;

	return stat(path, &st) == 0;
}

/* dzsave reached through vips_image_write_to_file() is handed a VipsTarget, and
 * the target entry point in dzsave.c forces
 * VIPS_FOREIGN_DZ_CONTAINER_ZIP, so the pyramid normally arrives as one zip
 * file rather than as smoke-dz.dzi + smoke-dz_files/.  Both shapes are fine -
 * what matters is that a .dzi descriptor was written.  Zip entry names are
 * stored uncompressed in the local file headers, so the name is visible in the
 * first kilobytes without needing an unzip. */
static int
file_holds_dzi(const char *path)
{
	FILE *f;
	unsigned char buf[8192];
	size_t n, i;

	if (!(f = fopen(path, "rb")))
		return 0;
	n = fread(buf, 1, sizeof buf, f);
	fclose(f);

	for (i = 0; i + 4 <= n; i++)
		if (memcmp(buf + i, ".dzi", 4) == 0)
			return 1;

	return 0;
}

static void
work_path(char *buf, size_t sz, const char *id, const char *ext)
{
	snprintf(buf, sz, "%s/smoke-%s%s", workdir, id, ext);
}

/* A small RGB gradient to encode.  libvips copies the buffer, so it can be
 * freed straight after the image is made. */
static VipsImage *
source_image(void)
{
	unsigned char *pixels, *p;
	VipsImage *im;
	int x, y;

	if (!(pixels = malloc((size_t) TEST_W * TEST_H * 3)))
		return NULL;
	for (y = 0; y < TEST_H; y++) {
		for (x = 0; x < TEST_W; x++) {
			p = pixels + ((size_t) y * TEST_W + x) * 3;
			p[0] = (unsigned char) (x * 4);
			p[1] = (unsigned char) (y * 5);
			p[2] = (unsigned char) ((x * 3 + y * 2) & 0xff);
		}
	}

	im = vips_image_new_from_memory_copy(pixels, (size_t) TEST_W * TEST_H * 3,
		TEST_W, TEST_H, 3, VIPS_FORMAT_UCHAR);
	free(pixels);

	return im;
}

/* Encode the test image to a file, read it back and check what came out.
 * "save_opts" is libvips' [name=value,...] syntax appended to the filename, so
 * the format can be steered without a format-specific function. */
static void
check_roundtrip(const char *id, const char *ext, const char *save_opts)
{
	char path[1200], target[1300], detail[400];
	const char *saver;
	VipsImage *src, *back;
	size_t size = 0, i, nonzero = 0;
	void *mem;
	const char *loader = NULL;

	work_path(path, sizeof path, id, ext);
	if (save_opts && *save_opts)
		snprintf(target, sizeof target, "%s%s", path, save_opts);
	else
		snprintf(target, sizeof target, "%s", path);

	/* No writer registered for this extension: the format was left out. */
	if (!(saver = vips_foreign_find_save(target))) {
		report(id, status_for_absent(id), "no writer registered for this format");
		return;
	}

	if (!(src = source_image())) {
		report(id, ST_FAIL, vips_error_one_line());
		return;
	}
	if (vips_image_write_to_file(src, target, NULL)) {
		snprintf(detail, sizeof detail, "write failed: %s", vips_error_one_line());
		report(id, ST_FAIL, detail);
		return;
	}
	if (!(back = vips_image_new_from_file(path, NULL))) {
		snprintf(detail, sizeof detail, "wrote %s but could not read it back: %s",
			ext, vips_error_one_line());
		report(id, ST_FAIL, detail);
		return;
	}

	if (vips_image_get_width(back) != TEST_W || vips_image_get_height(back) != TEST_H) {
		snprintf(detail, sizeof detail, "expected %dx%d, read %dx%d",
			TEST_W, TEST_H, vips_image_get_width(back), vips_image_get_height(back));
		report(id, ST_FAIL, detail);
		return;
	}

	if (!(mem = vips_image_write_to_memory(back, &size)) || size == 0) {
		snprintf(detail, sizeof detail, "decoded pixel memory missing: %s",
			vips_error_one_line());
		report(id, ST_FAIL, detail);
		return;
	}
	for (i = 0; i < size; i++) {
		if (((unsigned char *) mem)[i]) {
			nonzero++;
			break;
		}
	}
	if (!nonzero) {
		report(id, ST_FAIL, "the decoded image is all zeroes");
		return;
	}

	if (vips_image_get_string(back, "vips-loader", &loader) != 0)
		loader = NULL;
	snprintf(detail, sizeof detail, "%s -> %s, %dx%d, %d bands",
		ext, loader ? loader : "unknown loader",
		vips_image_get_width(back), vips_image_get_height(back),
		vips_image_get_bands(back));
	report(id, ST_PASS, detail);
}

/* dzsave writes a directory tree rather than a file, so it needs its own
 * check of what landed on disk. */
static void
check_dz(void)
{
	char path[1200], dzi[1300], detail[400];
	VipsImage *src;

	work_path(path, sizeof path, "dz", ".dz");
	work_path(dzi, sizeof dzi, "dz", ".dzi");

	if (!vips_foreign_find_save(path)) {
		report("dz", status_for_absent("dz"), "no dzsave writer");
		return;
	}
	if (!(src = source_image())) {
		report("dz", ST_FAIL, vips_error_one_line());
		return;
	}
	if (vips_image_write_to_file(src, path, NULL)) {
		snprintf(detail, sizeof detail, "dzsave failed: %s", vips_error_one_line());
		report("dz", ST_FAIL, detail);
		return;
	}
	if (file_exists(dzi)) {
		report("dz", ST_PASS, "smoke-dz.dzi plus the smoke-dz_files/ tile tree");
		return;
	}
	if (file_exists(path) && file_holds_dzi(path)) {
		report("dz", ST_PASS, "pyramid written as a zip holding smoke-dz.dzi");
		return;
	}

	report("dz", ST_FAIL, "wrote smoke-dz.dz but there is no .dzi in or beside it");
}

/* A 1x1 GIF, so GIF loading is checked even in a preset that trimmed the GIF
 * writer away. */
static const unsigned char tiny_gif[] = {
	0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80,
	0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0x21, 0xf9, 0x04,
	0x01, 0x00, 0x00, 0x00, 0x00, 0x2c, 0x00, 0x00, 0x00, 0x00, 0x01,
	0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3b
};

static const char tiny_svg[] =
	"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\">"
	"<rect width=\"32\" height=\"32\" fill=\"#336699\"/></svg>";

/* Load bytes that are already in memory, the way a consumer embedding an image
 * from a buffer would. */
static void
check_load_buffer(const char *id, const void *bytes, size_t n, int expect_w)
{
	VipsImage *im;
	char detail[400];

	if (!(im = vips_image_new_from_buffer(bytes, n, "", NULL))) {
		report(id, status_for_absent(id), vips_error_one_line());
		return;
	}
	if (expect_w && vips_image_get_width(im) != expect_w) {
		snprintf(detail, sizeof detail, "expected %d px wide, got %d",
			expect_w, vips_image_get_width(im));
		report(id, ST_FAIL, detail);
		return;
	}

	snprintf(detail, sizeof detail, "%dx%d, %d bands",
		vips_image_get_width(im), vips_image_get_height(im),
		vips_image_get_bands(im));
	report(id, ST_PASS, detail);
}

/* --- core API ------------------------------------------------------------- */

static void
check_thumbnail(void)
{
	VipsImage *src, *out = NULL;
	char detail[400];

	if (!(src = source_image())) {
		report("thumbnail", ST_FAIL, vips_error_one_line());
		return;
	}
	if (vips_thumbnail_image(src, &out, 32, NULL)) {
		snprintf(detail, sizeof detail, "vips_thumbnail_image: %s", vips_error_one_line());
		report("thumbnail", ST_FAIL, detail);
		return;
	}

	snprintf(detail, sizeof detail, "%dx%d from %dx%d",
		vips_image_get_width(out), vips_image_get_height(out), TEST_W, TEST_H);
	report("thumbnail", ST_PASS, detail);
}

static void
check_buffer(void)
{
	VipsImage *src, *back = NULL;
	void *buf = NULL;
	size_t len = 0;
	char detail[400];

	if (!(src = source_image())) {
		report("buffer", ST_FAIL, vips_error_one_line());
		return;
	}
	if (vips_image_write_to_buffer(src, ".png", &buf, &len, NULL) || !buf || len == 0) {
		snprintf(detail, sizeof detail, "write_to_buffer: %s", vips_error_one_line());
		report("buffer", ST_FAIL, detail);
		return;
	}
	if (!(back = vips_image_new_from_buffer(buf, len, "", NULL))) {
		snprintf(detail, sizeof detail, "new_from_buffer: %s", vips_error_one_line());
		report("buffer", ST_FAIL, detail);
		return;
	}

	snprintf(detail, sizeof detail, "%llu bytes of PNG -> %dx%d",
		(unsigned long long) len,
		vips_image_get_width(back), vips_image_get_height(back));
	report("buffer", ST_PASS, detail);
}

static void
check_memory(void)
{
	VipsImage *src;
	void *mem;
	size_t size = 0;
	char detail[400];

	if (!(src = source_image())) {
		report("memory", ST_FAIL, vips_error_one_line());
		return;
	}
	if (!(mem = vips_image_write_to_memory(src, &size))) {
		snprintf(detail, sizeof detail, "write_to_memory: %s", vips_error_one_line());
		report("memory", ST_FAIL, detail);
		return;
	}
	if (size != (size_t) TEST_W * TEST_H * 3) {
		snprintf(detail, sizeof detail, "expected %d bytes, got %llu",
			TEST_W * TEST_H * 3, (unsigned long long) size);
		report("memory", ST_FAIL, detail);
		return;
	}

	(void) mem;
	snprintf(detail, sizeof detail, "%llu bytes of RGB pixels",
		(unsigned long long) size);
	report("memory", ST_PASS, detail);
}

static void
check_metadata(void)
{
	VipsImage *src;
	int width = 0;
	char detail[400];

	if (!(src = source_image())) {
		report("metadata", ST_FAIL, vips_error_one_line());
		return;
	}
	if (vips_image_get_int(src, "width", &width) || width != TEST_W) {
		snprintf(detail, sizeof detail, "vips_image_get_int(\"width\"): %s",
			vips_error_one_line());
		report("metadata", ST_FAIL, detail);
		return;
	}
	if (vips_image_get_typeof(src, "height") == 0) {
		report("metadata", ST_FAIL, "no metadata type for \"height\"");
		return;
	}

	snprintf(detail, sizeof detail, "width/height readable through the C API");
	report("metadata", ST_PASS, detail);
}

static void
check_colourspace(void)
{
	VipsImage *src, *out = NULL;
	char detail[400];

	if (!(src = source_image())) {
		report("colourspace", ST_FAIL, vips_error_one_line());
		return;
	}
	if (vips_colourspace(src, &out, VIPS_INTERPRETATION_B_W, NULL)) {
		snprintf(detail, sizeof detail, "vips_colourspace: %s", vips_error_one_line());
		report("colourspace", ST_FAIL, detail);
		return;
	}
	if (vips_image_get_bands(out) != 1) {
		snprintf(detail, sizeof detail, "greyscale has %d bands",
			vips_image_get_bands(out));
		report("colourspace", ST_FAIL, detail);
		return;
	}

	report("colourspace", ST_PASS, "sRGB -> greyscale");
}

/* vips_sharpen() is always exported; without FFTW linked in it fails at run
 * time, which is exactly what this check is for. */
static void
check_sharpen(void)
{
	VipsImage *src, *out = NULL;
	char detail[400];

	if (!(src = source_image())) {
		report("sharpen", ST_FAIL, vips_error_one_line());
		return;
	}
	if (vips_sharpen(src, &out, NULL)) {
		snprintf(detail, sizeof detail, "vips_sharpen: %s", vips_error_one_line());
		report("sharpen", ST_FAIL, detail);
		return;
	}

	report("sharpen", ST_PASS, "FFT convolution ran");
}

/* --- operations that can only be probed ----------------------------------- */

/* Calling vips_openexrload() or vips_dcrawload() directly would need a
 * wrapper a trimmed build does not export, so these are looked up by name
 * instead.  The instance is left to the process exit to release: GLib symbols
 * are hidden in the shipped library on Linux. */
static int
operation_present(const char *op)
{
	return vips_operation_new(op) != NULL;
}

static void
check_any_operation(const char *id, const char *const *ops)
{
	int i;

	for (i = 0; ops[i]; i++) {
		if (operation_present(ops[i])) {
			report(id, ST_PASS, ops[i]);
			return;
		}
	}

	report(id, status_for_absent(id), ops[0]);
}

/* Formats this build is meant to leave out.  Finding one is a warning about
 * the build scripts disagreeing with the library, not a broken package. */
static void
check_expected_absent(const char *op)
{
	if (operation_present(op))
		report(op, ST_WARN, "compiled in, but this build disables it");
	else
		report(op, ST_INFO, "absent, as expected");
}

/* -------------------------------------------------------------------------- */

int
main(int argc, char **argv)
{
	static const char *const analyze_ops[] = { "analyzeload", NULL };
	static const char *const openexr_ops[] = { "openexrload", "exrload", NULL };
	static const char *const raw_ops[] = { "dcrawload", "rawload", NULL };
	static const char *const uhdr_ops[] = { "uhdrload", "ultrahdrload", NULL };
	/* libvips 8.19 renamed the Pango text renderer to textload. */
	static const char *const text_ops[] = { "textload", "text", NULL };
	static const char *const qoi_ops[] = { "qoiload", NULL };
	int i;

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--require") == 0 && i + 1 < argc)
			require_list = argv[++i];
		else if (strcmp(argv[i], "--skip") == 0 && i + 1 < argc)
			skip_list = argv[++i];
		else if (strcmp(argv[i], "--workdir") == 0 && i + 1 < argc)
			snprintf(workdir, sizeof workdir, "%s", argv[++i]);
		else {
			fprintf(stderr, "usage: smoke-test [--require id,id,...] "
				"[--skip id,id,...] [--workdir DIR]\n");
			return 2;
		}
	}

	if (vips_init(argv[0])) {
		fprintf(stderr, "smoke-test: libvips would not start: %s\n",
			vips_error_one_line());
		return 2;
	}

	printf("libvips %s smoke test, work dir %s\n", vips_version_string(), workdir);
	printf("  %-11s %-8s %s\n", "check", "status", "detail");

	printf("  formats that encode and decode\n");
	check_roundtrip("png", ".png", NULL);
	check_roundtrip("jpeg", ".jpg", "[Q=90]");
	check_roundtrip("webp", ".webp", "[lossless=1]");
	check_roundtrip("avif", ".avif", NULL);
	check_roundtrip("heic", ".heic", NULL);
	check_roundtrip("tiff", ".tif", NULL);
	check_roundtrip("gif", ".gif", NULL);
	check_roundtrip("jp2", ".jp2", NULL);
	check_roundtrip("jxl", ".jxl", NULL);
	check_roundtrip("fits", ".fits", NULL);
	check_roundtrip("mat", ".mat", NULL);
	check_roundtrip("ppm", ".ppm", NULL);
	check_roundtrip("rad", ".hdr", NULL);

	printf("  formats without a writer in libvips\n");
	check_load_buffer("gifload", tiny_gif, sizeof tiny_gif, 1);
	check_load_buffer("svgload", tiny_svg, strlen(tiny_svg), 32);
	check_any_operation("analyze", analyze_ops);
	check_any_operation("openexr", openexr_ops);
	check_any_operation("raw", raw_ops);
	check_any_operation("uhdr", uhdr_ops);
	check_any_operation("text", text_ops);
	check_any_operation("qoi", qoi_ops);

	printf("  core API\n");
	check_thumbnail();
	check_buffer();
	check_memory();
	check_metadata();
	check_colourspace();
	check_sharpen();
	check_dz();

	printf("  must not be in this package\n");
	check_expected_absent("magickload");
	check_expected_absent("openslideload");
	check_expected_absent("niftiload");
	check_expected_absent("popplerload");

	vips_shutdown();

	printf("%d checks, %d trimmed, %d failures: %s\n", n_run, n_trimmed, n_failed,
		n_failed ? "FAILED" : "all required checks passed");

	return n_failed ? 1 : 0;
}



