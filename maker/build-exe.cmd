@echo off
rem Builds SMW-Maker.exe with the C# compiler that comes with Windows (.NET Framework 4).
rem   maker\build-exe.cmd <out folder>
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
"%CSC%" /nologo /target:winexe /optimize+ /out:"%~1\SMW-Maker.exe" /win32icon:"%~dp0smw-maker.ico" ^
    /r:System.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll "%~dp0SMW-Maker.cs"
