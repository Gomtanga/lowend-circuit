@echo off
rem Build and verify the Windows CLI.
rem
rem Usage:  scripts\build-windows-cli.bat [Debug|Release]
rem
rem Requires Visual Studio 2022 (or newer) with the C++ workload and a Windows
rem SDK. The script locates vcvars64.bat through vswhere, configures CMake, then
rem runs the offline checks. It performs no device setup and changes no audio
rem settings.
setlocal enabledelayedexpansion

set "CONFIG=%~1"
if "%CONFIG%"=="" set "CONFIG=Release"

set "ROOT=%~dp0.."
set "BUILD_DIR=%ROOT%\build\win-cli"

rem Locate Visual Studio through vswhere, which every VS 2017+ install ships.
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
    echo Visual Studio was not found. Install VS 2022 with the "Desktop development with C++" workload.
    exit /b 1
)

set "VSPATH="
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"
if "%VSPATH%"=="" (
    echo Visual Studio with the MSVC toolset was not found.
    exit /b 1
)

call "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b 1

cmake -S "%ROOT%\Windows" -B "%BUILD_DIR%" -DLOWEND_WINDOWS_BUILD_TESTING=ON
if errorlevel 1 exit /b 1

rem --config selects the configuration; the default Visual Studio generator is
rem multi-config, so CMAKE_BUILD_TYPE would be ignored and only warn.
cmake --build "%BUILD_DIR%" --config %CONFIG% --parallel
if errorlevel 1 exit /b 1

ctest --test-dir "%BUILD_DIR%" -C %CONFIG% --output-on-failure
if errorlevel 1 exit /b 1

python "%ROOT%\scripts\check-windows-cli.py" "%BUILD_DIR%\%CONFIG%\lowend_windows.exe"
if errorlevel 1 exit /b 1

rem The engine and DSP must stay independent of the UI. This is a source and
rem link-line check, so it runs before the build result is trusted.
python "%ROOT%\scripts\check-windows-ui-independence.py"
if errorlevel 1 exit /b 1

echo.
echo Build and offline checks succeeded: %BUILD_DIR%\%CONFIG%\lowend_windows.exe
