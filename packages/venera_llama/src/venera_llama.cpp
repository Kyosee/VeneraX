// Implementation of the venera_llama shim (see venera_llama.h).
//
// Written against the llama.cpp C API as of the pinned submodule commit
// (packages/venera_llama/src/llama.cpp). The API here is the post-2024
// "llama_batch / llama_sampler" interface; if you bump the submodule and it
// stops compiling, this file — and only this file — is where you fix it.

#include "venera_llama.h"

#include "llama.h"

#include <string>
#include <vector>
#include <cstring>
#include <mutex>

namespace {

// Per-thread last-error string. The Dart worker is single-threaded, but keep
// it thread-local so a stray call elsewhere can't corrupt the message.
thread_local std::string g_last_error;

void set_error(const std::string& msg) { g_last_error = msg; }

std::once_flag g_backend_once;

// A loaded model + context + a reusable sampler chain.
struct venera_ctx {
  llama_model* model = nullptr;
  llama_context* ctx = nullptr;
  const llama_vocab* vocab = nullptr;
  int32_t n_ctx = 0;
};

}  // namespace

extern "C" {

void venera_llama_backend_init(void) {
  std::call_once(g_backend_once, []() {
    llama_backend_init();
  });
}

void* venera_llama_load(const char* model_path,
                        int32_t context_size,
                        int32_t gpu_layers) {
  if (model_path == nullptr) {
    set_error("model_path is null");
    return nullptr;
  }
  venera_llama_backend_init();

  llama_model_params mparams = llama_model_default_params();
  mparams.n_gpu_layers = gpu_layers;

  llama_model* model = llama_model_load_from_file(model_path, mparams);
  if (model == nullptr) {
    set_error(std::string("failed to load model: ") + model_path);
    return nullptr;
  }

  llama_context_params cparams = llama_context_default_params();
  cparams.n_ctx = context_size > 0 ? (uint32_t)context_size : 4096;
  // A single sequence, one page at a time. Keep batch >= n_ctx so a long
  // prompt can be decoded in one pass.
  cparams.n_batch = cparams.n_ctx;

  llama_context* ctx = llama_init_from_model(model, cparams);
  if (ctx == nullptr) {
    llama_model_free(model);
    set_error("failed to create llama context");
    return nullptr;
  }

  auto* vc = new venera_ctx();
  vc->model = model;
  vc->ctx = ctx;
  vc->vocab = llama_model_get_vocab(model);
  vc->n_ctx = (int32_t)cparams.n_ctx;
  return vc;
}

int32_t venera_llama_generate(void* handle,
                              const char* prompt,
                              int32_t max_tokens,
                              char* out_buf,
                              int32_t out_capacity) {
  if (handle == nullptr || prompt == nullptr || out_buf == nullptr ||
      out_capacity <= 0) {
    set_error("invalid arguments to generate");
    return -1;
  }
  auto* vc = static_cast<venera_ctx*>(handle);

  // --- Tokenize the prompt ---
  int n_prompt_max = (int)std::string(prompt).size() + 8;
  std::vector<llama_token> tokens(n_prompt_max);
  int n_prompt = llama_tokenize(vc->vocab, prompt, (int)std::string(prompt).size(),
                                tokens.data(), (int)tokens.size(),
                                /*add_special=*/true, /*parse_special=*/true);
  if (n_prompt < 0) {
    // Buffer was too small; llama returns -required.
    tokens.resize(-n_prompt);
    n_prompt = llama_tokenize(vc->vocab, prompt, (int)std::string(prompt).size(),
                              tokens.data(), (int)tokens.size(), true, true);
  }
  if (n_prompt <= 0) {
    set_error("tokenization failed");
    return -1;
  }
  tokens.resize(n_prompt);

  if (n_prompt >= vc->n_ctx) {
    set_error("prompt exceeds context window");
    return -1;
  }

  // Fresh generation each call: clear any KV state from a previous page.
  llama_memory_clear(llama_get_memory(vc->ctx), true);

  // --- Decode the prompt ---
  llama_batch batch = llama_batch_get_one(tokens.data(), (int32_t)tokens.size());
  if (llama_decode(vc->ctx, batch) != 0) {
    set_error("failed to decode prompt");
    return -1;
  }

  // --- Greedy sampler chain ---
  llama_sampler* smpl =
      llama_sampler_chain_init(llama_sampler_chain_default_params());
  llama_sampler_chain_add(smpl, llama_sampler_init_greedy());

  std::string result;
  int written = 0;
  int budget = max_tokens > 0 ? max_tokens : 1024;
  char piece[512];

  for (int i = 0; i < budget; ++i) {
    llama_token tok = llama_sampler_sample(smpl, vc->ctx, -1);
    if (llama_vocab_is_eog(vc->vocab, tok)) {
      break;
    }
    int np = llama_token_to_piece(vc->vocab, tok, piece, (int)sizeof(piece),
                                  0, /*special=*/false);
    if (np > 0) {
      result.append(piece, np);
    }
    // Feed the sampled token back in for the next step.
    llama_batch next = llama_batch_get_one(&tok, 1);
    if (llama_decode(vc->ctx, next) != 0) {
      set_error("failed to decode during generation");
      break;
    }
  }

  llama_sampler_free(smpl);

  // --- Copy out, truncating at a UTF-8 boundary if needed ---
  int n = (int)result.size();
  if (n >= out_capacity) {
    n = out_capacity - 1;
    // Back off to avoid splitting a multi-byte sequence.
    while (n > 0 && (static_cast<unsigned char>(result[n]) & 0xC0) == 0x80) {
      --n;
    }
  }
  memcpy(out_buf, result.data(), n);
  out_buf[n] = '\0';
  written = n;
  return written;
}

void venera_llama_free(void* handle) {
  if (handle == nullptr) return;
  auto* vc = static_cast<venera_ctx*>(handle);
  if (vc->ctx) llama_free(vc->ctx);
  if (vc->model) llama_model_free(vc->model);
  delete vc;
}

const char* venera_llama_last_error(void) {
  return g_last_error.c_str();
}

}  // extern "C"
