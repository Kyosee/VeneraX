// Run the shipped decoder in the same QuickJS engine on macOS and iOS.
#include "quickjs.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern const char avif_decoder_source[];
extern const size_t avif_decoder_source_len;
extern const unsigned char avif_fixture[];
extern const size_t avif_fixture_len;

int main(void) {
    const char *check =
        "globalThis.verified = false;"
        "decodeAvifPage(sample, 128).then(({width, height, pixels}) => {"
        "  const p = new Uint8Array(pixels);"
        "  const blue = 13 * 4;"
        "  verified = width === 16 && height === 8 && p.length === 512 &&"
        "    p[0] > 230 && p[2] < 30 && Math.abs(p[3] - 128) <= 2 &&"
        "    p[blue] < 30 && p[blue + 2] > 230 && p[blue + 3] === 255;"
        "});";
    JSRuntime *rt = JS_NewRuntime();
    JS_SetMaxStackSize(rt, 2 * 1024 * 1024);
    JSContext *ctx = JS_NewContext(rt);
    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "sample", JS_NewArrayBufferCopy(ctx, avif_fixture, avif_fixture_len));
    JSValue script = JS_Eval(ctx, avif_decoder_source, avif_decoder_source_len,
                             "decode.js", JS_EVAL_TYPE_GLOBAL);
    JSValue check_result = JS_Eval(ctx, check, strlen(check), "check.js", JS_EVAL_TYPE_GLOBAL);
    JSContext *active = ctx;
    int jobs;
    while ((jobs = JS_ExecutePendingJob(rt, &active)) > 0) {}
    JSValue verified = JS_GetPropertyStr(ctx, global, "verified");
    int passed = !JS_IsException(script) && !JS_IsException(check_result) &&
                 jobs == 0 && JS_ToBool(ctx, verified) == 1;
    JS_FreeValue(ctx, verified);
    JS_FreeValue(ctx, check_result);
    JS_FreeValue(ctx, script);
    JS_FreeValue(ctx, global);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    if (!passed) {
        fputs("AVIF decode or pixel comparison failed\n", stderr);
        return EXIT_FAILURE;
    }
    puts("AVIF 16x8: translucent red and opaque blue pixels verified");
    return EXIT_SUCCESS;
}
