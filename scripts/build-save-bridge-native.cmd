@echo off
call "%~1" >nul
if errorlevel 1 exit /b %errorlevel%
cl.exe /nologo /LD /MT /O2 /std:c++17 /W4 /WX /EHsc /I "%~2\include" /I "%~2\include\win32" "%~3" /Fo"%~4\bootstrap.obj" /link /OUT:"%~4\pztools-attach-bootstrap.dll" /IMPLIB:"%~4\pztools-attach-bootstrap.lib"
exit /b %errorlevel%
