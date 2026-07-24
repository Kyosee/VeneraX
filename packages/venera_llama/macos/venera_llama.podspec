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

  s.source_files = [
    '../src/venera_llama.cpp',
    '../src/venera_llama.h',
    '../src/llama.cpp/src/**/*.{cpp,c}',
    '../src/llama.cpp/common/**/*.{cpp,c}',
    '../src/llama.cpp/ggml/src/**/*.{c,cpp,m,mm}',
  ]

  s.public_header_files = '../src/venera_llama.h'

  s.resources = ['../src/llama.cpp/ggml/src/ggml-metal/*.metal']

  s.platform     = :osx, '14.0'
  s.frameworks   = 'Foundation', 'Metal', 'MetalKit', 'Accelerate'

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
    'GCC_OPTIMIZATION_LEVEL' => '3',
  }

  s.requires_arc = false
end
