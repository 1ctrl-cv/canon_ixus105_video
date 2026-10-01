@echo off
setlocal EnableExtensions
title Canon AVI + THM converter

REM ===========================================================================
REM  canon_convert.bat - convert any video into the format a Canon compact
REM  camera writes AND can play back:
REM      <name>.AVI   Motion JPEG 640x480 Y(2,1)/C(1,1) + 12 kHz mono PCM
REM      <name>.THM   160x120 JPEG thumbnail with Canon EXIF
REM
REM  USAGE
REM    canon_convert.bat                     convert every video in this folder
REM    canon_convert.bat "clip.mp4"          convert one file
REM    drag & drop files onto this .bat      convert those files
REM
REM  NEEDS  ffmpeg.exe, ffprobe.exe, exiftool.exe on PATH, plus Python with
REM         Pillow ("python -c "import PIL"" must work).
REM         Set full paths in the SETTINGS block if they are not on PATH.
REM
REM  NOTE   keep this file saved with Windows (CRLF) line endings - cmd.exe
REM         mis-reads batch files that use bare LF.
REM ===========================================================================


REM ------------------------------- SETTINGS ---------------------------------
REM  Output geometry / frame rate.  These match a Canon IXUS 105 movie.
set "WIDTH=640"
set "HEIGHT=480"
set "FPSNUM=30000"
set "FPSDEN=1001"
set "THMW=160"
set "THMH=120"

REM  JPEG quality for the frames and the thumbnail (1-95).  85 lands close to
REM  the bitrate the camera itself records at.
set "QUALITY=85"

REM  Write the Huffman tables into every frame.
REM    1 = yes (default).  Canon's own frames omit them and rely on tables
REM        built into the camera firmware, but those are not necessarily the
REM        tables an encoder produces, so omitting ours can make the camera
REM        decode the picture with the wrong tables.
REM    0 = omit, to look byte-for-byte like a camera frame.
set "DHT=1"

REM  How a non-4:3 source is fitted into 640x480:
REM    pad     = keep the whole picture, add black bars  (nothing is lost)
REM    crop    = fill the frame, cut off the sides
REM    stretch = squash the picture to fit (distorts)
set "FITMODE=pad"

REM  Audio: Canon cameras record mono 8-bit PCM at 12 kHz.
set "AUDIO_RATE=12000"
set "AUDIO_CH=1"

REM  EXIF donor - REQUIRED, do not leave empty and do not delete the file.
REM    A Canon .THM is not just a JPEG with EXIF: the camera checks the CANON
REM    MAKER NOTE inside it.  Measured on an IXUS 105, everything else identical:
REM         donor maker note + movie fields   172 tags  -> camera plays it
REM         explicit tag values only, no note  71 tags  -> camera refuses
REM    So the donor supplies the whole maker note, and the script only rewrites
REM    the few fields (date, FrameCount, FileNumber) that belong to this movie.
REM    Point it at any real camera .THM to borrow that camera's metadata.
set "REFTHM=%~dp0_canon_donor.thm"

REM  Recording date.  Leave empty to use the source video's own timestamp.
REM  Format: 2025-12-08 09:43:37
set "DATETIME="

REM  Tools (use full paths if they are not on PATH)
set "FFMPEG=ffmpeg"
set "FFPROBE=ffprobe"
set "EXIFTOOL=exiftool"
set "POWERSHELL=powershell"
set "PYTHON=python"
REM --------------------------------------------------------------------------


set "OK=0"
set "FAIL=0"

if "%~1"=="" goto :scan
:args
if "%~1"=="" goto :summary
call :convert "%~1"
shift
goto :args

:scan
echo Scanning "%~dp0" for videos ...
echo.
for %%E in (mp4 m4v mov mkv wmv avi flv webm mpg mpeg ts m2ts 3gp) do (
    for /f "delims=" %%F in ('dir /b /a-d "%~dp0*.%%E" 2^>nul') do call :convert "%~dp0%%F"
)
goto :summary


REM ===========================================================================
:convert
set "IN=%~f1"
set "BASE=%~n1"
set "DIR=%~dp1"
set "OUTAVI=%DIR%%BASE%.AVI"
set "OUTTHM=%DIR%%BASE%.THM"
set "TMPV=%DIR%_tmp_v.mjpeg"
set "TMPA=%DIR%_tmp_a.raw"
set "THMTMP=%DIR%_thm_tmp.jpg"
set "PROBEF=%DIR%_probe.tmp"

if not exist "%IN%"       ( echo [skip] not found : %IN% & goto :eof )
if /i "%~x1"==".thm"      ( echo [skip] thumbnail: %~nx1 & goto :eof )
if /i "%IN%"=="%OUTAVI%"  ( echo [skip] already AVI: %~nx1 & goto :eof )

echo ==========================================================
echo  %~nx1
echo ==========================================================

REM --- pick the scale/fit filter --------------------------------------------
set "FITV="
set "FITVT="
if /i "%FITMODE%"=="pad" set "FITV=scale=%WIDTH%:%HEIGHT%:force_original_aspect_ratio=decrease:flags=lanczos,pad=%WIDTH%:%HEIGHT%:(ow-iw)/2:(oh-ih)/2:color=black"
if /i "%FITMODE%"=="pad" set "FITVT=scale=%THMW%:%THMH%:force_original_aspect_ratio=decrease:flags=lanczos,pad=%THMW%:%THMH%:(ow-iw)/2:(oh-ih)/2:color=black"
if /i "%FITMODE%"=="crop" set "FITV=scale=%WIDTH%:%HEIGHT%:force_original_aspect_ratio=increase:flags=lanczos,crop=%WIDTH%:%HEIGHT%"
if /i "%FITMODE%"=="crop" set "FITVT=scale=%THMW%:%THMH%:force_original_aspect_ratio=increase:flags=lanczos,crop=%THMW%:%THMH%"
if /i "%FITMODE%"=="stretch" set "FITV=scale=%WIDTH%:%HEIGHT%:flags=lanczos"
if /i "%FITMODE%"=="stretch" set "FITVT=scale=%THMW%:%THMH%:flags=lanczos"
if not defined FITV set "FITV=scale=%WIDTH%:%HEIGHT%:force_original_aspect_ratio=decrease:flags=lanczos,pad=%WIDTH%:%HEIGHT%:(ow-iw)/2:(oh-ih)/2:color=black"
if not defined FITVT set "FITVT=scale=%THMW%:%THMH%:force_original_aspect_ratio=decrease:flags=lanczos,pad=%THMW%:%THMH%:(ow-iw)/2:(oh-ih)/2:color=black"
set "VF=%FITV%,setsar=1,fps=%FPSNUM%/%FPSDEN%"
set "VFT=%FITVT%,setsar=1"

REM --- ask the source what it contains --------------------------------------
REM  ffprobe writes into a temp file which SET /P then reads.  A FOR /F command
REM  string cannot be used here: cmd turns every '=' inside it into a space,
REM  which silently mangles ffprobe's -show_entries / -of arguments.
set "HASAUDIO="
"%FFPROBE%" -v error -select_streams a -show_entries stream=index -of csv=p=0 "%IN%" >"%PROBEF%" 2>nul
set "LINE="
set /p LINE=<"%PROBEF%" 2>nul
if defined LINE set "HASAUDIO=1"

set "SRCDATE="
"%FFPROBE%" -v error -show_entries format_tags=creation_time -of default=nw=1:nk=1 "%IN%" >"%PROBEF%" 2>nul
set /p SRCDATE=<"%PROBEF%" 2>nul
if not "%DATETIME%"=="" set "SRCDATE=%DATETIME%"

set "DURATION="
"%FFPROBE%" -v error -show_entries format=duration -of default=nw=1:nk=1 "%IN%" >"%PROBEF%" 2>nul
set /p DURATION=<"%PROBEF%" 2>nul
del /q "%PROBEF%" >nul 2>&1

set "AIN=-f lavfi -t %DURATION% -i anullsrc=r=%AUDIO_RATE%:cl=mono"
set "AMAPA=-map 1:a:0"
if "%DURATION%"=="" set "AIN=-f lavfi -i anullsrc=r=%AUDIO_RATE%:cl=mono"
if "%DURATION%"=="" set "AMAPA=-map 1:a:0 -shortest"
if defined HASAUDIO set "AIN="
if defined HASAUDIO set "AMAPA=-map 0:a:0"

if defined HASAUDIO (echo  audio : source audio, re-encoded to %AUDIO_RATE% Hz mono 8-bit) else (echo  audio : source has none, silent track added)
if "%SRCDATE%"=="" (echo  date  : none in the file, using its modified time) else (echo  date  : %SRCDATE%)
echo  video : %WIDTH%x%HEIGHT% Motion JPEG 4:2:2 Y(2,1)/C(1,1), fit=%FITMODE%, quality=%QUALITY%

REM --- 1. video -> raw RGB -> Canon-layout MJPEG -----------------------------
REM  ffmpeg's MJPEG encoder cannot emit Y(2,1)/C(1,1) - 4:2:2 with 16x8 MCUs -
REM  which is exactly what the camera's movie decoder is fixed to, so the
REM  frames are encoded by Pillow (libjpeg 4:2:2) from raw RGB instead.
"%FFMPEG%" -hide_banner -loglevel warning -y -i "%IN%" -map 0:v:0 -vf "%VF%" -f rawvideo -pix_fmt rgb24 - | "%PYTHON%" "%~dp0_canon_frames.py" - "%TMPV%" %WIDTH% %HEIGHT% %QUALITY%
if errorlevel 1 ( echo [FAIL] could not encode the video frames & set /a FAIL+=1 & goto :eof )
if not exist "%TMPV%" ( echo [FAIL] no frames were produced & set /a FAIL+=1 & goto :eof )

REM --- 2. thumbnail (the movie's first frame) --------------------------------
"%FFMPEG%" -hide_banner -loglevel error -y -i "%IN%" -vf "%VFT%" -frames:v 1 -f rawvideo -pix_fmt rgb24 - | "%PYTHON%" "%~dp0_canon_frames.py" - "%THMTMP%" %THMW% %THMH% %QUALITY%
if errorlevel 1 ( echo [FAIL] could not build the thumbnail & set /a FAIL+=1 & goto :eof )

REM --- 3. audio -> raw PCM ---------------------------------------------------
"%FFMPEG%" -hide_banner -loglevel error -y -i "%IN%" %AIN% %AMAPA% -c:a pcm_u8 -ar %AUDIO_RATE% -ac %AUDIO_CH% -f u8 "%TMPA%"
if errorlevel 1 ( echo [FAIL] ffmpeg could not produce the audio track & set /a FAIL+=1 & goto :eof )

REM --- 4. Canon container + IDIT + .THM EXIF ---------------------------------
REM  powershell.exe very occasionally fails to start at all (it exits with -1
REM  and prints nothing).  The finish step is idempotent, so simply try again.
REM  The retry uses the thumbnail's existence as "did it work", so a leftover
REM  .THM from an earlier run has to be removed first.
if exist "%OUTTHM%" del /q "%OUTTHM%" >nul 2>&1
for /L %%T in (1,1,4) do if not exist "%OUTTHM%" (
    "%POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0_canon_finish.ps1" -MjpegPath "%TMPV%" -AudioPath "%TMPA%" -OutAvi "%OUTAVI%" -ThmIn "%THMTMP%" -ThmOut "%OUTTHM%" -RefThm "%REFTHM%" -DateIso "%SRCDATE%" -BaseName "%BASE%" -ExifTool "%EXIFTOOL%" -Width %WIDTH% -Height %HEIGHT% -FpsNum %FPSNUM% -FpsDen %FPSDEN% -AudioRate %AUDIO_RATE% -Dht %DHT%
    if exist "%OUTTHM%" echo  note  : finished on attempt %%T
)
if not exist "%OUTTHM%" ( echo [FAIL] could not finish %~nx1 & set /a FAIL+=1 & goto :eof )

REM  the thumbnail must carry real camera metadata - without a working
REM  REFTHM donor it is still a valid JPEG, just missing the Canon EXIF, and
REM  that would otherwise pass unnoticed
set "THMMAKE="
"%EXIFTOOL%" -s3 -Make "%OUTTHM%" >"%PROBEF%" 2>nul
set /p THMMAKE=<"%PROBEF%" 2>nul
del /q "%PROBEF%" >nul 2>&1
if not "%THMMAKE%"=="Canon" ( echo [FAIL] thumbnail has no camera EXIF - is REFTHM there? & set /a FAIL+=1 & goto :eof )

if exist "%TMPV%" del /q "%TMPV%" >nul 2>&1
if exist "%TMPA%" del /q "%TMPA%" >nul 2>&1
if exist "%THMTMP%" del /q "%THMTMP%" >nul 2>&1

if not exist "%OUTAVI%" ( echo [FAIL] AVI was not produced & set /a FAIL+=1 & goto :eof )
for %%S in ("%OUTAVI%") do echo [ok]   %%~nxS  %%~zS bytes
for %%S in ("%OUTTHM%") do echo [ok]   %%~nxS  %%~zS bytes
set /a OK+=1
goto :eof


:summary
echo.
echo ==========================================================
echo  done: %OK% converted, %FAIL% failed
echo ==========================================================
if not "%FAIL%"=="0" exit /b 1
exit /b 0
