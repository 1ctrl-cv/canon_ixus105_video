param(
    [Parameter(Mandatory=$true)][string]$MjpegPath,   # raw concatenated MJPEG stream from ffmpeg
    [Parameter(Mandatory=$true)][string]$AudioPath,   # raw PCM u8 mono from ffmpeg
    [Parameter(Mandatory=$true)][string]$OutAvi,
    [string]$ThmIn,
    [string]$ThmOut,
    [string]$RefThm,
    [string]$DateIso,                                 # ISO-8601 from the source video
    [string]$BaseName = "",
    [string]$ExifTool = "exiftool",
    [int]$Width = 640,
    [int]$Height = 480,
    [int]$FpsNum = 30000,
    [int]$FpsDen = 1001,
    [int]$AudioRate = 12000,
    [int]$Dht = 1                                     # 1 = keep the Huffman tables (safe), 0 = omit them Canon-style
)

<#
    _canon_finish.ps1 - companion helper for canon_convert.bat

    ffmpeg can produce the right codecs but neither the right *container* nor
    the right *JPEG marker layout*, and a Canon camera's firmware is strict
    about both.  This script rebuilds the file to match a genuine camera movie:

      * every MJPEG frame is rewritten into Canon's marker layout
        (APP0 "AVI1", DRI, two quantisation tables, SOF, no DHT - the default
        Annex K Huffman tables then apply, which is exactly what ffmpeg's
        -huffman 0 also writes)
      * the AVI container is rebuilt the way Canon writes it: 'movi' at offset
        2048, odml/dmlh, an OpenDML 'indx' super index in each stream,
        ix00/ix01 sub indexes, one one-second audio chunk before every 30 video
        frames, a two-entry idx1 and an IDIT recording date
      * the .THM gets the same marker treatment plus the donor camera's EXIF

    Everything is verified, and nothing is reported until it has been read back.
#>

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture
$script:problems = @()
function Note([string]$m) { Write-Host "    $m" }

# ============================================================ little helpers
function New-Buf { return New-Object System.Collections.Generic.List[byte] }
function Add-U32([System.Collections.Generic.List[byte]]$b, [uint32]$v) {
    $b.Add([byte]($v -band 0xFF)); $b.Add([byte](($v -shr 8) -band 0xFF))
    $b.Add([byte](($v -shr 16) -band 0xFF)); $b.Add([byte](($v -shr 24) -band 0xFF))
}
function Add-U16([System.Collections.Generic.List[byte]]$b, [uint16]$v) {
    $b.Add([byte]($v -band 0xFF)); $b.Add([byte](($v -shr 8) -band 0xFF))
}
# JPEG segment lengths are BIG endian; RIFF uses little endian above
function Add-U16BE([System.Collections.Generic.List[byte]]$b, [uint16]$v) {
    $b.Add([byte](($v -shr 8) -band 0xFF)); $b.Add([byte]($v -band 0xFF))
}
function Add-FourCC([System.Collections.Generic.List[byte]]$b, [string]$s) {
    foreach ($c in $s.ToCharArray()) { $b.Add([byte][char]$c) }
}
function Add-Zeros([System.Collections.Generic.List[byte]]$b, [int]$n) {
    for ($i = 0; $i -lt $n; $i++) { $b.Add(0) }
}
function Add-Bytes([System.Collections.Generic.List[byte]]$b, [byte[]]$a) { $b.AddRange($a) }
# native block copy - indexing a PowerShell array per element over megabytes of
# picture data is orders of magnitude slower than [Array]::Copy
function Copy-Range([byte[]]$src, [int]$start, [int]$len) {
    $d = New-Object byte[] $len
    [Array]::Copy($src, $start, $d, 0, $len)
    return ,$d
}
function Get-U32([byte[]]$a, [int]$o) {
    return [uint32]$a[$o] -bor ([uint32]$a[$o+1] -shl 8) -bor ([uint32]$a[$o+2] -shl 16) -bor ([uint32]$a[$o+3] -shl 24)
}
# JPEG segment lengths are BIG endian - RIFF (Get-U32 above) is little endian
function Get-U16BE([byte[]]$a, [int]$o) { return [uint16](([int]$a[$o] -shl 8) -bor [int]$a[$o+1]) }

# Marker list of a JPEG frame: code, start offset and declared segment length.
function Get-JpegMarkers([byte[]]$f) {
    $m = @()
    $i = 2
    while ($i -lt $f.Length - 1) {
        if ($f[$i] -ne 0xFF) { $i++; continue }
        $c = $f[$i+1]
        if ($c -eq 0x01 -or ($c -ge 0xD0 -and $c -le 0xD7)) { $i += 2; continue }
        if ($c -eq 0xDA) { $m += [pscustomobject]@{ Code = 0xDA; Start = $i; Len = (Get-U16BE $f ($i+2)) }; break }
        $ln = Get-U16BE $f ($i + 2)
        $m += [pscustomobject]@{ Code = $c; Start = $i; Len = $ln }
        $i += 2 + $ln
    }
    return ,$m
}

# Collect the quantisation tables of the whole frame, keyed by table id.
# Encoders differ in how they emit these: ffmpeg writes one DQT holding a single
# table shared by every component, Pillow/libjpeg writes one DQT per table.
function Get-QuantTables([byte[]]$f, $markers) {
    $byId = @{}
    foreach ($d in ($markers | Where-Object { $_.Code -eq 0xDB })) {
        $qp = $d.Start + 4
        $qEnd = $d.Start + 2 + $d.Len
        while ($qp -lt $qEnd) {
            if (($f[$qp] -shr 4) -ne 0) { throw "16-bit quantisation tables are not supported" }
            $byId[$f[$qp] -band 0x0F] = (Copy-Range $f ($qp + 1) 64)
            $qp += 65
        }
    }
    if (-not $byId.ContainsKey(0)) { throw "frame carries no quantisation table 0" }
    $chroma = if ($byId.ContainsKey(1)) { $byId[1] } else { $byId[0] }
    return @{ Luma = $byId[0]; Chroma = $chroma }
}

# All DHT segments concatenated into the payload of a single DHT segment, the
# way a Canon frame carries them.
function Get-MergedDht([byte[]]$f, $markers) {
    $payload = New-Object System.Collections.Generic.List[byte]
    foreach ($h in ($markers | Where-Object { $_.Code -eq 0xC4 })) {
        Add-Bytes $payload (Copy-Range $f ($h.Start + 4) ($h.Len - 2))
    }
    return ,$payload.ToArray()
}

function Write-Dqt([System.Collections.Generic.List[byte]]$b, $qt) {
    Add-Bytes $b ([byte[]]@(0xFF, 0xDB, 0x00, 0x84))
    $b.Add([byte]0); Add-Bytes $b $qt.Luma
    $b.Add([byte]1); Add-Bytes $b $qt.Chroma
}

function Write-Dht([System.Collections.Generic.List[byte]]$b, [byte[]]$payload) {
    Add-Bytes $b ([byte[]]@(0xFF, 0xC4))
    Add-U16BE $b ([uint16]($payload.Length + 2))   # segment length includes its own 2 bytes
    Add-Bytes $b $payload
}

function Get-SofBody([byte[]]$f, $sof) {
    # segment length covers its own two length bytes, hence -2
    $body = Copy-Range $f ($sof.Start + 4) ($sof.Len - 2)
    $n = $body[5]
    for ($c = 1; $c -lt $n; $c++) { $body[8 + $c * 3] = 1 }   # colour components -> table 1
    return ,$body
}

# ============================================== 1. rewrite one MJPEG frame
# ffmpeg:  SOI APP0(JFIF) DQT(1 table) DHT SOF SOS ... EOI
# Canon :  SOI APP0(AVI1) DRI DQT(2 tables) SOF SOS ... EOI     (no DHT)
function ConvertTo-CanonFrame([byte[]]$f) {
    if ($f.Length -lt 4 -or $f[0] -ne 0xFF -or $f[1] -ne 0xD8) { throw "not a JPEG frame" }
    $mk  = Get-JpegMarkers $f
    $sof = $mk | Where-Object { $_.Code -eq 0xC0 -or $_.Code -eq 0xC1 } | Select-Object -First 1
    $sos = $mk | Where-Object { $_.Code -eq 0xDA } | Select-Object -First 1
    if (-not $sof -or -not $sos) { throw "frame is missing SOF/SOS" }

    $qt  = Get-QuantTables $f $mk
    $dht = Get-MergedDht $f $mk

    # laid out by hand so every copy is a native block move - a per-element
    # loop over ~22 MB of pictures would take minutes
    $head = New-Buf
    Add-Bytes $head ([byte[]]@(0xFF, 0xD8))                     # SOI
    Add-Bytes $head ([byte[]]@(0xFF, 0xE0, 0x00, 0x10))         # APP0 "AVI1"
    Add-FourCC $head 'AVI1'
    Add-Zeros $head 10
    Add-Bytes $head ([byte[]]@(0xFF, 0xDD, 0x00, 0x04, 0x00, 0x00))  # DRI, no restarts
    Write-Dqt $head $qt
    Add-Bytes $head ([byte[]]@(0xFF, 0xC0))
    Add-U16BE $head ([uint16]$sof.Len)
    Add-Bytes $head (Get-SofBody $f $sof)
    # Canon's own frames carry no Huffman tables at all - its firmware uses a
    # built-in default set, the AVI1 convention.  Those built-in tables are NOT
    # necessarily the Annex K tables ffmpeg writes, so dropping ours makes a
    # camera decode our entropy data with the wrong tables (garbled picture).
    # Keeping them is unambiguous and is the safe default.
    if ($dht.Length -and (($Dht -ne 0) -or ($dht.Length -ne 416))) {
        Write-Dht $head $dht
    }
    $headBytes = $head.ToArray()

    $tailLen = $f.Length - $sos.Start
    $total = $headBytes.Length + $tailLen
    if ($total % 2) { $total++ }                                # Canon's pad byte
    $bytes = New-Object byte[] $total
    [Array]::Copy($headBytes, 0, $bytes, 0, $headBytes.Length)
    [Array]::Copy($f, $sos.Start, $bytes, $headBytes.Length, $tailLen)
    return ,$bytes
}

# Same treatment for a standalone .THM, but no AVI1 marker and the DHT is kept
# (a camera .THM carries explicit Huffman tables).  The Exif APP1 segment is
# spliced in right after SOI, which is exactly where a camera .THM has it.
function ConvertTo-CanonThmJpeg([byte[]]$f) {
    $mk  = Get-JpegMarkers $f
    $sof = $mk | Where-Object { $_.Code -eq 0xC0 -or $_.Code -eq 0xC1 } | Select-Object -First 1
    $sos = $mk | Where-Object { $_.Code -eq 0xDA } | Select-Object -First 1
    if (-not $sof -or -not $sos) { throw "thumbnail is missing SOF/SOS" }

    $qt  = Get-QuantTables $f $mk
    $dht = Get-MergedDht $f $mk

    $out = New-Buf
    Add-Bytes $out ([byte[]]@(0xFF, 0xD8))
    # no APP0 here: a camera .THM goes straight from SOI to the Exif APP1
    Write-Dqt $out $qt
    Add-Bytes $out ([byte[]]@(0xFF, 0xC0))
    Add-U16BE $out ([uint16]$sof.Len)
    Add-Bytes $out (Get-SofBody $f $sof)
    if ($dht.Length) { Write-Dht $out $dht }
    Add-Bytes $out (Copy-Range $f $sos.Start ($f.Length - $sos.Start))
    return ,$out.ToArray()
}

# ============================================== 2. split a raw MJPEG stream
# Scans with [Array]::IndexOf rather than a per-byte loop: the stream is tens of
# megabytes and a PowerShell-level loop over it takes minutes.
function Split-Mjpeg([byte[]]$all) {
    # search through a Latin-1 view: one byte maps to one char, so
    # String.IndexOf scans at native speed.  A PowerShell-level per-byte loop
    # over tens of megabytes takes minutes.
    $enc = [System.Text.Encoding]::GetEncoding(28591)          # ISO-8859-1, 1:1
    $s   = $enc.GetString($all)
    $soi = [string][char]0xFF + [char]0xD8
    $eoi = [string][char]0xFF + [char]0xD9
    $ord = [System.StringComparison]::Ordinal

    $frames = New-Object System.Collections.Generic.List[byte[]]
    $pos = 0
    while ($true) {
        $start = $s.IndexOf($soi, $pos, $ord)
        if ($start -lt 0) { break }
        $end = $s.IndexOf($eoi, $start + 2, $ord)
        if ($end -lt 0) { break }
        $frames.Add($enc.GetBytes($s.Substring($start, $end + 2 - $start)))
        $pos = $end + 2
    }
    return ,$frames
}

# ============================================== 3. build the AVI container
function New-CanonAvi {
    param([byte[][]]$Frames, [byte[]]$Audio, [string]$DateText, [string]$OutPath)

    $nFrames = $Frames.Count
    $nAudio  = $Audio.Length
    if ($nFrames -eq 0) { throw "no video frames to write" }

    $achunk = 12012      # Canon's audio chunk: 1.001 s at 12 kHz, 8-bit mono
    $aframes = 30        # ... written before every 30 video frames
    $audioLens = @()
    $left = $nAudio
    while ($left -gt 0) { $n = [Math]::Min($achunk, $left); $audioLens += $n; $left -= $n }
    if ($audioLens.Count -eq 0) { $audioLens = @(0) }

    $maxFrame = 0
    foreach ($f in $Frames) { if ($f.Length -gt $maxFrame) { $maxFrame = $f.Length } }
    $maxAudio = ($audioLens | Measure-Object -Maximum).Maximum

    $videoOff = New-Object 'int[]' $nFrames
    $videoLen = New-Object 'int[]' $nFrames
    $audioOff = New-Object 'int[]' $audioLens.Count
    $audioLen = New-Object 'int[]' $audioLens.Count

    # ---- movi payload. Canon's offset convention:
    #      ix00/ix01 entries are relative to movi+4, idx1 entries to movi+8
    $movi = New-Buf
    Add-FourCC $movi 'movi'
    $pos = 2048 + 8 + 4
    $a = 0; $k = 0; $cursor = 0
    while ($k -lt $nFrames -or $a -lt $audioLens.Count) {
        $takeAudio = ($a -lt $audioLens.Count -and $k -ge ($a * $aframes)) -or ($k -ge $nFrames)
        if ($takeAudio) {
            $n = $audioLens[$a]
            $audioOff[$a] = $pos; $audioLen[$a] = $n
            Add-FourCC $movi '01wb'; Add-U32 $movi ([uint32]$n)
            Add-Bytes $movi (Copy-Range $Audio $cursor $n)
            if ($n % 2) { $movi.Add(0) }
            $cursor += $n
            $pos += 8 + $n + ($n % 2)
            $a++
        } else {
            $fr = $Frames[$k]
            $videoOff[$k] = $pos; $videoLen[$k] = $fr.Length
            Add-FourCC $movi '00dc'; Add-U32 $movi ([uint32]$fr.Length)
            Add-Bytes $movi $fr
            if ($fr.Length % 2) { $movi.Add(0) }
            $pos += 8 + $fr.Length + ($fr.Length % 2)
            $k++
        }
    }

    # ---- ix00 / ix01 sub indexes, appended inside movi
    $ix00Pos = $pos
    $ix00 = New-Buf
    Add-U16 $ix00 2; $ix00.Add(0); $ix00.Add(1)
    Add-U32 $ix00 ([uint32]$nFrames); Add-FourCC $ix00 '00dc'
    Add-U32 $ix00 2060; Add-U32 $ix00 0; Add-U32 $ix00 0
    for ($i = 0; $i -lt $nFrames; $i++) {
        Add-U32 $ix00 ([uint32]($videoOff[$i] - 2052)); Add-U32 $ix00 ([uint32]$videoLen[$i])
    }
    Add-FourCC $movi 'ix00'; Add-U32 $movi ([uint32]$ix00.Count)
    Add-Bytes $movi $ix00.ToArray(); if ($ix00.Count % 2) { $movi.Add(0) }
    $pos += 8 + $ix00.Count + ($ix00.Count % 2)

    $ix01Pos = $pos
    $ix01 = New-Buf
    Add-U16 $ix01 2; $ix01.Add(0); $ix01.Add(1)
    Add-U32 $ix01 ([uint32]$audioLens.Count); Add-FourCC $ix01 '01wb'
    Add-U32 $ix01 2060; Add-U32 $ix01 0; Add-U32 $ix01 0
    for ($i = 0; $i -lt $audioLens.Count; $i++) {
        Add-U32 $ix01 ([uint32]($audioOff[$i] - 2052)); Add-U32 $ix01 ([uint32]$audioLen[$i])
    }
    Add-FourCC $movi 'ix01'; Add-U32 $movi ([uint32]$ix01.Count)
    Add-Bytes $movi $ix01.ToArray(); if ($ix01.Count % 2) { $movi.Add(0) }
    $moviBytes = $movi.ToArray()

    # ---- hdrl -------------------------------------------------------------
    $maxBytesPerSec = [uint32]([Math]::Floor($maxFrame * $FpsNum / $FpsDen) + $AudioRate)
    $hdrl = New-Buf
    Add-FourCC $hdrl 'hdrl'

    Add-FourCC $hdrl 'avih'; Add-U32 $hdrl 56
    Add-U32 $hdrl ([uint32][Math]::Floor([double]$FpsDen / [double]$FpsNum * 1000000))
    Add-U32 $hdrl $maxBytesPerSec
    Add-U32 $hdrl 0
    Add-U32 $hdrl 65552                                  # AVIF_HASINDEX | AVIF_WASCAPTUREFILE
    Add-U32 $hdrl ([uint32]$nFrames)
    Add-U32 $hdrl 0
    Add-U32 $hdrl 2
    Add-U32 $hdrl ([uint32]$maxFrame)
    Add-U32 $hdrl ([uint32]$Width); Add-U32 $hdrl ([uint32]$Height)
    Add-Zeros $hdrl 16                                   # dwReserved[4] - avih is 56 bytes

    # video strl
    Add-FourCC $hdrl 'LIST'; Add-U32 $hdrl 244
    Add-FourCC $hdrl 'strl'
    Add-FourCC $hdrl 'strh'; Add-U32 $hdrl 56
    Add-FourCC $hdrl 'vids'; Add-FourCC $hdrl 'mjpg'
    Add-U32 $hdrl 0; Add-U16 $hdrl 0; Add-U16 $hdrl 0; Add-U32 $hdrl 0
    Add-U32 $hdrl ([uint32]$FpsDen); Add-U32 $hdrl ([uint32]$FpsNum)
    Add-U32 $hdrl 0
    Add-U32 $hdrl ([uint32]$nFrames)
    Add-U32 $hdrl ([uint32]$maxFrame)
    Add-U32 $hdrl 10000
    Add-U32 $hdrl 0
    Add-U16 $hdrl 0; Add-U16 $hdrl 0; Add-U16 $hdrl ([uint16]$Width); Add-U16 $hdrl ([uint16]$Height)
    Add-FourCC $hdrl 'strf'; Add-U32 $hdrl 40
    Add-U32 $hdrl 40
    Add-U32 $hdrl ([uint32]$Width); Add-U32 $hdrl ([uint32]$Height)
    Add-U16 $hdrl 1; Add-U16 $hdrl 24
    Add-FourCC $hdrl 'MJPG'
    Add-U32 $hdrl ([uint32]($Width * $Height * 3))
    Add-U32 $hdrl 0; Add-U32 $hdrl 0; Add-U32 $hdrl 0; Add-U32 $hdrl 0
    Add-FourCC $hdrl 'indx'; Add-U32 $hdrl 120
    Add-U16 $hdrl 4; $hdrl.Add(0); $hdrl.Add(0)
    Add-U32 $hdrl 1; Add-FourCC $hdrl '00dc'
    Add-U32 $hdrl 0; Add-U32 $hdrl 0; Add-U32 $hdrl 0
    Add-U32 $hdrl ([uint32]$ix00Pos); Add-U32 $hdrl 0
    Add-U32 $hdrl ([uint32]($ix00.Count + 8)); Add-U32 $hdrl ([uint32]$nFrames)
    Add-Zeros $hdrl 80

    # audio strl
    Add-FourCC $hdrl 'LIST'; Add-U32 $hdrl 220
    Add-FourCC $hdrl 'strl'
    Add-FourCC $hdrl 'strh'; Add-U32 $hdrl 56
    Add-FourCC $hdrl 'auds'; Add-U32 $hdrl 0
    Add-U32 $hdrl 0; Add-U16 $hdrl 0; Add-U16 $hdrl 0; Add-U32 $hdrl 0
    Add-U32 $hdrl 1; Add-U32 $hdrl ([uint32]$AudioRate)
    Add-U32 $hdrl 0
    Add-U32 $hdrl ([uint32]$nAudio)
    Add-U32 $hdrl ([uint32]$maxAudio)
    Add-U32 $hdrl 10000
    Add-U32 $hdrl 1
    Add-U16 $hdrl 0; Add-U16 $hdrl 0; Add-U16 $hdrl 0; Add-U16 $hdrl 0
    Add-FourCC $hdrl 'strf'; Add-U32 $hdrl 16
    Add-U16 $hdrl 1; Add-U16 $hdrl 1
    Add-U32 $hdrl ([uint32]$AudioRate); Add-U32 $hdrl ([uint32]$AudioRate)
    Add-U16 $hdrl 1; Add-U16 $hdrl 8
    Add-FourCC $hdrl 'indx'; Add-U32 $hdrl 120
    Add-U16 $hdrl 4; $hdrl.Add(0); $hdrl.Add(0)
    Add-U32 $hdrl 1; Add-FourCC $hdrl '01wb'
    Add-U32 $hdrl 0; Add-U32 $hdrl 0; Add-U32 $hdrl 0
    Add-U32 $hdrl ([uint32]$ix01Pos); Add-U32 $hdrl 0
    Add-U32 $hdrl ([uint32]($ix01.Count + 8)); Add-U32 $hdrl ([uint32]$nAudio)
    Add-Zeros $hdrl 80

    # odml / dmlh
    Add-FourCC $hdrl 'LIST'; Add-U32 $hdrl 260
    Add-FourCC $hdrl 'odml'
    Add-FourCC $hdrl 'dmlh'; Add-U32 $hdrl 248
    Add-U32 $hdrl ([uint32]$nFrames)
    Add-Zeros $hdrl 244

    # IDIT - the recording date in C asctime() form
    $idit = [System.Text.Encoding]::ASCII.GetBytes($DateText + [char]10 + [char]0)
    Add-FourCC $hdrl 'IDIT'; Add-U32 $hdrl ([uint32]$idit.Length)
    Add-Bytes $hdrl $idit
    if ($idit.Length % 2) { $hdrl.Add(0) }
    $hdrlBytes = $hdrl.ToArray()

    $info = New-Buf
    $isft = [System.Text.Encoding]::ASCII.GetBytes("CanonMVI06" + [char]0 + [char]0)
    Add-FourCC $info 'INFO'
    Add-FourCC $info 'ISFT'; Add-U32 $info ([uint32]$isft.Length)
    Add-Bytes $info $isft
    $infoBytes = $info.ToArray()

    # ---- assemble, padding so that movi lands exactly on 2048 --------------
    $junkNeeded = 2048 - (12 + 8 + $hdrlBytes.Length + 8 + $infoBytes.Length + 8)
    if ($junkNeeded -lt 0) { throw "header no longer fits before offset 2048" }

    $file = New-Buf
    Add-FourCC $file 'RIFF'; Add-U32 $file 0; Add-FourCC $file 'AVI '
    Add-FourCC $file 'LIST'; Add-U32 $file ([uint32]$hdrlBytes.Length); Add-Bytes $file $hdrlBytes
    Add-FourCC $file 'LIST'; Add-U32 $file ([uint32]$infoBytes.Length); Add-Bytes $file $infoBytes
    Add-FourCC $file 'JUNK'; Add-U32 $file ([uint32]$junkNeeded); Add-Zeros $file $junkNeeded
    if ($file.Count -ne 2048) { throw "movi would start at $($file.Count), expected 2048" }
    Add-FourCC $file 'LIST'; Add-U32 $file ([uint32]$moviBytes.Length); Add-Bytes $file $moviBytes

    # ---- idx1: Canon keeps just the first chunk of each stream
    Add-FourCC $file 'idx1'; Add-U32 $file 32
    Add-FourCC $file '01wb'; Add-U32 $file 0
    Add-U32 $file ([uint32]($audioOff[0] - 2056)); Add-U32 $file ([uint32]$audioLen[0])
    Add-FourCC $file '00dc'; Add-U32 $file 16
    Add-U32 $file ([uint32]($videoOff[0] - 2056)); Add-U32 $file ([uint32]$videoLen[0])

    $bytes = $file.ToArray()
    $r = [uint32]($bytes.Length - 8)
    $bytes[4] = [byte]($r -band 0xFF); $bytes[5] = [byte](($r -shr 8) -band 0xFF)
    $bytes[6] = [byte](($r -shr 16) -band 0xFF); $bytes[7] = [byte](($r -shr 24) -band 0xFF)
    [System.IO.File]::WriteAllBytes($OutPath, $bytes)

    return @{ Size = $bytes.Length; Frames = $nFrames; Samples = $nAudio; AudioChunks = $audioLens.Count }
}

# ============================================================ main
$dt = $null
if (-not [string]::IsNullOrWhiteSpace($DateIso)) {
    $parsed = [datetime]::MinValue
    [void][datetime]::TryParse($DateIso, $inv,
        [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor
        [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)
    if ($parsed -ne [datetime]::MinValue) { $dt = $parsed.ToLocalTime() }
}
if (-not $dt) { $dt = (Get-Item $MjpegPath).LastWriteTime }
$exifDate = $dt.ToString("yyyy:MM:dd HH:mm:ss", $inv)
$dateText = $dt.ToString("ddd MMM", $inv) + " " + $dt.Day.ToString().PadLeft(2) + $dt.ToString(" HH:mm:ss yyyy", $inv)

Write-Host "  [finish] $(Split-Path -Leaf $OutAvi)"
Note ("date      : {0}   (IDIT: '{1}')" -f $exifDate, $dateText)

# --- rewrite every frame into Canon's marker layout
$rawFrames = Split-Mjpeg ([System.IO.File]::ReadAllBytes($MjpegPath))
Note ("frames    : {0}" -f $rawFrames.Count)
$canon = New-Object System.Collections.Generic.List[byte[]]
foreach ($fr in $rawFrames) { $canon.Add((ConvertTo-CanonFrame $fr)) }

# --- audio trimmed or padded so it matches the frame count exactly
$want = [int][Math]::Round($rawFrames.Count * $FpsDen / $FpsNum * $AudioRate)
$audioIn = [System.IO.File]::ReadAllBytes($AudioPath)
$audio = New-Object byte[] $want
$copy = [Math]::Min($want, $audioIn.Length)
[Array]::Copy($audioIn, 0, $audio, 0, $copy)
for ($i = $copy; $i -lt $want; $i++) { $audio[$i] = 128 }          # 8-bit PCM silence
Note ("audio     : {0} samples ({1:N3} s) from {2}" -f $want, ($want / $AudioRate), $audioIn.Length)

# --- container
$r = New-CanonAvi -Frames $canon.ToArray() -Audio $audio -DateText $dateText -OutPath $OutAvi
Note ("AVI       : {0:N0} bytes, movi @2048, ix00={1} ix01={2}" -f $r.Size, $r.Frames, $r.AudioChunks)

# The camera stores the recording time in a private .THM field that exiftool
# does not expose as a tag, so -TagsFromFile copies the donor's value verbatim -
# which is why the camera used to display the donor recording's date.
#
# Measured against a camera-native .THM: the value is a unix timestamp of the
# LOCAL wall-clock reading treated as UTC, and it sits immediately after the
# frame-rate pair written twice:  00 00 <num> <den> 00 00 <num> <den>
# The .AVI has no equivalent field; the time lives only here.
function Set-ThmPrivateTime([string]$Path, [int]$FpsNum, [int]$FpsDen, [datetime]$When) {
    $b = [System.IO.File]::ReadAllBytes($Path)

    $needle = New-Buf
    Add-Bytes $needle ([byte[]]@(0, 0))
    Add-U16 $needle ([uint16]$FpsNum)
    Add-U16 $needle ([uint16]$FpsDen)
    Add-Bytes $needle ([byte[]]@(0, 0))
    Add-U16 $needle ([uint16]$FpsNum)
    Add-U16 $needle ([uint16]$FpsDen)
    $n = $needle.ToArray()

    $at = -1
    for ($i = 0; $i -le $b.Length - $n.Length - 4; $i++) {
        $same = $true
        for ($k = 0; $k -lt $n.Length; $k++) {
            if ($b[$i + $k] -ne $n[$k]) { $same = $false; break }
        }
        if ($same) { $at = $i + $n.Length; break }
    }
    if ($at -lt 0) { return $false }

    # the camera writes the local wall clock as if it were UTC
    $asUtc  = [datetime]::SpecifyKind($When, [System.DateTimeKind]::Utc)
    $epoch0 = [datetime]::SpecifyKind([datetime]"1970-01-01", [System.DateTimeKind]::Utc)
    $secs   = [int64][math]::Round(($asUtc - $epoch0).TotalSeconds)
    $bytes  = [BitConverter]::GetBytes([uint32]$secs)
    if (-not [BitConverter]::IsLittleEndian) { [array]::Reverse($bytes) }
    [System.Array]::Copy($bytes, 0, $b, $at, 4)
    [System.IO.File]::WriteAllBytes($Path, $b)
    return $true
}

function Get-ThmPrivateTime([string]$Path, [int]$FpsNum, [int]$FpsDen) {
    $b = [System.IO.File]::ReadAllBytes($Path)
    $needle = New-Buf
    Add-Bytes $needle ([byte[]]@(0, 0))
    Add-U16 $needle ([uint16]$FpsNum)
    Add-U16 $needle ([uint16]$FpsDen)
    Add-Bytes $needle ([byte[]]@(0, 0))
    Add-U16 $needle ([uint16]$FpsNum)
    Add-U16 $needle ([uint16]$FpsDen)
    $n = $needle.ToArray()
    for ($i = 0; $i -le $b.Length - $n.Length - 4; $i++) {
        $same = $true
        for ($k = 0; $k -lt $n.Length; $k++) {
            if ($b[$i + $k] -ne $n[$k]) { $same = $false; break }
        }
        if ($same) {
            return [BitConverter]::ToUInt32($b, $i + $n.Length)
        }
    }
    return [uint32]0
}

# --- thumbnail ------------------------------------------------------------
function Get-ExifValue {
    param([string[]]$Arguments)
    $o = @(& $ExifTool @Arguments 2>$null)
    if ($o.Count) { return ([string]$o[0]).Trim() }
    return ""
}

# ---------------------------------------------------------------------------
# A Canon .THM is not just a JPEG with EXIF: the camera checks the CANON MAKER
# NOTE inside it.  Measured on an IXUS 105, with everything else identical:
#
#   donor maker note + the fields below   172 tags   9017 bytes   plays
#   explicit tag values only, no note      71 tags   9558 bytes   refused
#
# So -RefThm is required, not optional.  The donor supplies the whole maker
# note; the second pass only rewrites the fields that describe THIS movie.
# ---------------------------------------------------------------------------
if ($ThmIn -and $ThmOut -and (Test-Path -LiteralPath $ThmIn)) {
    [System.IO.File]::WriteAllBytes($ThmIn, (ConvertTo-CanonThmJpeg ([System.IO.File]::ReadAllBytes($ThmIn))))

    if ($RefThm -and (Test-Path -LiteralPath $RefThm)) {
        $num = ""
        $hits = [regex]::Matches($BaseName, '[0-9]{4}(?![0-9])')
        if ($hits.Count) { $num = $hits[$hits.Count - 1].Value }
        $refNum = Get-ExifValue @("-s3", "-FileNumber", $RefThm)
        $fileNumber = ""
        if ($refNum -match '^(\d+)-' -and $num) { $fileNumber = $Matches[1] + "-" + $num }

        # pass 1: whole EXIF block, maker note included, from the donor .THM
        $p1 = & $ExifTool -overwrite_original -TagsFromFile $RefThm -all:all -unsafe $ThmIn 2>&1
        if (-not (Test-Path -LiteralPath $ThmIn)) { throw "exiftool copy destroyed the thumbnail: $p1" }

        # pass 2: fields describing THIS movie - a separate pass, because
        # -TagsFromFile rewrites the maker note as one block
        $set = @("-overwrite_original",
                 "-ModifyDate=$exifDate", "-DateTimeOriginal=$exifDate", "-CreateDate=$exifDate",
                 "-FrameRate=$([double]$FpsNum / [double]$FpsDen)",
                 "-FrameCount=$($rawFrames.Count)")
        if ($fileNumber) { $set += "-FileNumber=$fileNumber" }
        $set += $ThmIn
        $p2 = & $ExifTool @set 2>&1
        if ($LASTEXITCODE -ne 0) { throw "exiftool could not set the movie fields: $p2" }

        # pass 3: read back - report what the file really holds
        $vDate = Get-ExifValue @("-s3", "-DateTimeOriginal", $ThmIn)
        $vFr   = Get-ExifValue @("-s3", "-FrameCount", $ThmIn)
        $vNum  = Get-ExifValue @("-s3", "-FileNumber", $ThmIn)
        $vMake = Get-ExifValue @("-s3", "-Make", $ThmIn)
        $vMod  = Get-ExifValue @("-s3", "-Model", $ThmIn)
        Note ("EXIF      : $vMake $vMod   (from $(Split-Path -Leaf $RefThm))")
        Note ("            DateTimeOriginal=$vDate  FrameCount=$vFr  FileNumber=$vNum")
        if ($vDate -ne $exifDate) { throw "date did not stick: asked '$exifDate', file says '$vDate'" }
        if ($vFr -ne "$($rawFrames.Count)") { throw "FrameCount did not stick: asked '$($rawFrames.Count)', file says '$vFr'" }
        if ($fileNumber -and $vNum -ne $fileNumber) { throw "FileNumber did not stick: asked '$fileNumber', file says '$vNum'" }
        if ($vMake -ne "Canon") { throw "thumbnail lost the camera maker note (Make='$vMake')" }

        # the private recording time the camera actually displays.  Must run
        # AFTER exiftool, which rewrites the file and moves every offset.
        if (Set-ThmPrivateTime $ThmIn $FpsNum $FpsDen $dt) {
            $priv = Get-ThmPrivateTime $ThmIn $FpsNum $FpsDen
            $seen = ([datetime]::SpecifyKind([datetime]"1970-01-01", [System.DateTimeKind]::Utc)).AddSeconds([double]$priv)
            Note ("            private time field = {0}  (camera shows this)" -f $seen.ToString("yyyy-MM-dd HH:mm:ss", $inv))
            if ($seen.ToString("yyyy-MM-dd HH:mm:ss") -ne $dt.ToString("yyyy-MM-dd HH:mm:ss")) {
                throw "private time field did not stick: asked '$($dt.ToString('yyyy-MM-dd HH:mm:ss'))', file says '$($seen.ToString('yyyy-MM-dd HH:mm:ss'))'"
            }
        } else {
            throw "could not find the private time field in the thumbnail - the donor .THM may not be a real camera file"
        }
    } else {
        # No donor: the script could still write a valid .THM, but the camera
        # refuses one without the maker note.  Fail loudly instead.
        Note "EXIF      : FAILED - donor .THM not found at '$RefThm'"
        Note "            the camera will not play a thumbnail without its maker note"
        throw "reference .THM not found: $RefThm"
    }

    $chk = & $ExifTool -s3 -ImageSize -FileType $ThmIn 2>&1
    if ($LASTEXITCODE -ne 0 -or ($chk -join ' ') -notmatch '\d+x\d+') { throw "thumbnail is not a readable JPEG: $chk" }
    Move-Item -LiteralPath $ThmIn -Destination $ThmOut -Force
    Note ("THM       : {0}  ({1})" -f [System.IO.Path]::GetFileName($ThmOut), (($chk | Where-Object { $_ -match 'x' }) -join ''))
}

Get-Item -LiteralPath $OutAvi | ForEach-Object { $_.LastWriteTime = $dt }
if ($ThmOut -and (Test-Path -LiteralPath $ThmOut)) { Get-Item -LiteralPath $ThmOut | ForEach-Object { $_.LastWriteTime = $dt } }
Note ("mtime     : set to $exifDate")

if ($script:problems.Count) { exit 2 }
exit 0
