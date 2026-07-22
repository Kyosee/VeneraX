# ONNX Runtime is accessed via JNI; stripping it breaks flutter_onnxruntime.
-keep class ai.onnxruntime.** { *; }
