@echo off
rem Compiles the loader's native library: %1 vcvars64.bat, %2 the JDK, %3 the source, %4 the output folder.
call "%~1" >nul
if errorlevel 1 exit /b %errorlevel%
cl.exe /nologo /LD /MT /O2 /std:c++17 /W4 /WX /EHsc /I "%~2\include" /I "%~2\include\win32" "%~3" /Fo"%~4\loader.obj" /link /OUT:"%~4\pzext-loader.dll" /IMPLIB:"%~4\pzext-loader.lib"
exit /b %errorlevel%
