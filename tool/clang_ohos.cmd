@echo off
"%RHTTP_OHOS_NATIVE%\llvm\bin\clang.exe" --target=%RHTTP_OHOS_CLANG_TARGET% --sysroot="%RHTTP_OHOS_NATIVE%\sysroot" -D__MUSL__ %*
exit /b %errorlevel%
