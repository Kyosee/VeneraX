// Thin C shim over llama.cpp — the ONLY surface the Dart FFI binding
// (lib/foundation/image_translation/local_llm/llama_ffi.dart) talks to.
//
// The whole point of this file is stability: llama.cpp's own C API is large
// and changes often, so instead of binding it directly from Dart we expose a
// handful of functions here and keep the volatile parts (tokenize / decode /
// sample loop) on this side of the boundary, pinned to a specific llama.cpp
// commit. If llama.cpp's API drifts, only this file needs fixing — the Dart
// side never moves.
//
// All calls are synchronous and blocking; they are only ever invoked from a
// dedicated worker isolate on the Dart side, so blocking is fine.

#ifndef VENERA_LLAMA_H
#define VENERA_LLAMA_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define VENERA_LLAMA_API __declspec(dllexport)
#else
#define VENERA_LLAMA_API __attribute__((visibility("default"))) __attribute__((used))
#endif

// Initializes the llama.cpp backend. Safe to call more than once; only the
// first call does work. Call before any load.
VENERA_LLAMA_API void venera_llama_backend_init(void);

// Loads a GGUF model and creates an inference context.
//   model_path   UTF-8 path to the .gguf file.
//   context_size token window (n_ctx).
//   gpu_layers   layers to offload to the GPU: -1 = all (Metal on Apple),
//                0 = CPU only.
// Returns an opaque handle, or NULL on failure (see venera_llama_last_error).
VENERA_LLAMA_API void* venera_llama_load(const char* model_path,
                                         int32_t context_size,
                                         int32_t gpu_layers);

// Runs one full generation from an already chat-templated prompt.
//   handle       from venera_llama_load.
//   prompt       UTF-8, fully formatted (the Dart side applied the template).
//   max_tokens   generation cap.
//   out_buf      caller-owned buffer for the UTF-8 result (NUL-terminated).
//   out_capacity size of out_buf in bytes.
// Returns the number of bytes written (excluding the NUL), or -1 on error.
// If the output would exceed out_capacity it is truncated at a UTF-8 boundary.
VENERA_LLAMA_API int32_t venera_llama_generate(void* handle,
                                               const char* prompt,
                                               int32_t max_tokens,
                                               char* out_buf,
                                               int32_t out_capacity);

// Frees a handle from venera_llama_load. NULL is ignored.
VENERA_LLAMA_API void venera_llama_free(void* handle);

// Returns a pointer to a static, thread-local-ish message describing the last
// failure on this thread. Valid until the next call on the same thread.
VENERA_LLAMA_API const char* venera_llama_last_error(void);

#ifdef __cplusplus
}
#endif

#endif  // VENERA_LLAMA_H
