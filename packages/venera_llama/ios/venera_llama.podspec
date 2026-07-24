#
# Builds the venera_llama shim together with the pinned llama.cpp submodule,
# with Metal GPU offload enabled. See packages/venera_llama/README.md for the
# submodule checkout step that must run before `pod install`.
#
Pod::Spec.new do |s|
  s.name             = 'venera_llama'
  s.version          = '0.0.1'
  s.summary          = 'Thin FFI shim over llama.cpp for on-device translation.'
  s.description      = 'Self-controlled llama.cpp wrapper; tiny stable C surface.'
  s.homepage         = 'https://github.com/Kyosee/VeneraX'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'VeneraX' => 'noreply@example.com' }
  s.source           = { :path => '.' }

  # Our shim plus the whole llama.cpp source tree from the submodule. Globbing
  # llama.cpp's src keeps us from having to list every file; ggml's C sources
  # are pulled in explicitly below because they need C (not C++) compilation.
  s.source_files = [
    '../src/venera_llama.cpp',
    '../src/venera_llama.h',
    '../src/llama.cpp/src/**/*.{cpp,c}',
    '../src/llama.cpp/common/**/*.{cpp,c}',
    '../src/llama.cpp/ggml/src/**/*.{c,cpp,m,mm}',
  ]

  s.public_header_files = '../src/venera_llama.h'

  # Metal shaders ship as a resource so ggml-metal can load them at runtime.
  s.resources = ['../src/llama.cpp/ggml/src/ggml-metal/*.metal']

  s.platform     = :ios, '16.0'
  s.frameworks   = 'Foundation', 'Metal', 'MetalKit', 'Accelerate'

  # GGML_USE_METAL / _ACCELERATE turn on the GPU + BLAS backends; the include
  # paths expose llama.cpp's own headers to both the shim and its sources.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'GCC_PREPROCESSOR_DEFINITIONS' => 'GGML_USE_METAL=1 GGML_USE_ACCELERATE=1 GGML_METAL_NDEBUG=1',
    'HEADER_SEARCH_PATHS' => [
      '"${PODS_TARGET_SRCROOT}/../src"',
      '"${PODS_TARGET_SRCROOT}/../src/llama.cpp/include"',
      '"${PODS_TARGET_SRCROOT}/../src/llama.cpp/common"',
      '"${PODS_TARGET_SRCROOT}/../src/llama.cpp/ggml/include"',
      '"${PODS_TARGET_SRCROOT}/../src/llama.cpp/ggml/src"',
    ].join(' '),
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'GCC_C_LANGUAGE_STANDARD' => 'gnu11',
    # llama.cpp is large; keep optimizations on even in Debug so inference is
    # not unusably slow to test.
    'GCC_OPTIMIZATION_LEVEL' => '3',
  }

  s.requires_arc = false
end
