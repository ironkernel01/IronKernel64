@echo off
REM Build script for menu test harness (Windows / GCC); menu.c and menu.h live in the parent folder.

if "%1"=="clean" goto clean
if "%1"=="demo"  goto demo
if "%1"=="run"   goto run

:build
echo Compiling main.c...
gcc -std=c11 -Wall -Wextra -Werror -pedantic -O2 -I.. -c main.c
if errorlevel 1 goto fail
echo Compiling menu.c...
gcc -std=c11 -Wall -Wextra -Werror -pedantic -O2 -I.. -c ../menu.c
if errorlevel 1 goto fail
echo Compiling menu_callback_Test.c...
gcc -std=c11 -Wall -Wextra -Werror -pedantic -O2 -I.. -c menu_callback_Test.c
if errorlevel 1 goto fail
echo Linking menu.exe...
gcc -std=c11 -Wall -Wextra -Werror -pedantic -O2 -o menu.exe main.o menu.o menu_callback_Test.o
if errorlevel 1 goto fail
echo Build succeeded.
goto end

:clean
del /q main.o menu.o menu_callback_Test.o menu.exe 2>nul
echo Clean done.
goto end

:demo
if not exist menu.exe goto build
menu.exe --demo
goto end

:run
if not exist menu.exe goto build
menu.exe
goto end

:fail
echo Build FAILED.
exit /b 1

:end
