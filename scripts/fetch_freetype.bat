@echo off
setlocal
rem Fetch the FreeType import library + DLL for the Windows (MSVC) build.
rem
rem Source: ubawurinna/freetype-windows-binaries @ v2.14.3 (official-style
rem VS-built x64 binaries kept in that repo's "release dll" tree — note
rem the space, URL-encoded below). The import library goes to
rem lib\freetype.lib (on the /LIBPATH the examples link with), the DLL to
rem bin\freetype.dll (next to the exes Crystal builds). Both directories
rem are gitignored; reruns are no-ops, and the SHA256 hashes are pinned
rem to the release notes.

set "TAG=v2.14.3"
set "BASE=https://raw.githubusercontent.com/ubawurinna/freetype-windows-binaries/%TAG%/release%%20dll/x64"
set "LIB_SHA256=DDECFF9875700CEC354CD8F53C4DC021817D8F6DBE65ACD7E55A49AFBCFB0D4D"
set "DLL_SHA256=53CED2814011C4A128DA5E6F84FA2B3677207C1709AC3647059E0C0D0B09191B"

rem project root = parent of this script's directory
cd /d "%~dp0.."

if exist "lib\freetype.lib" if exist "bin\freetype.dll" (
  echo freetype %TAG% already present, nothing to do
  exit /b 0
)

where curl >nul 2>nul
if errorlevel 1 (
  echo error: curl not found ??? needs Windows 10+ 1>&2
  exit /b 1
)

if not exist lib mkdir lib
if not exist bin mkdir bin

echo fetching freetype %TAG% x64 binaries ...
curl -fsSL -o "lib\freetype.lib.tmp" "%BASE%/freetype.lib" || goto :fail
curl -fsSL -o "bin\freetype.dll.tmp" "%BASE%/freetype.dll" || goto :fail

call :check "lib\freetype.lib.tmp"  %LIB_SHA256% || goto :fail
call :check "bin\freetype.dll.tmp"  %DLL_SHA256% || goto :fail

move /y "lib\freetype.lib.tmp" "lib\freetype.lib" >nul
move /y "bin\freetype.dll.tmp" "bin\freetype.dll" >nul
echo freetype %TAG%: lib\freetype.lib + bin\freetype.dll ready
exit /b 0

:check
rem %1 = file, %2 = expected sha256 (certutil ships with Windows)
set "GOT="
for /f "skip=1 tokens=1" %%h in ('certutil -hashfile "%~1" SHA256') do (
  if not defined GOT set "GOT=%%h"
)
if /i not "%GOT%"=="%~2" (
  echo error: sha256 mismatch for %~1 1>&2
  exit /b 1
)
exit /b 0

:fail
echo error: download failed 1>&2
exit /b 1
