# canon-video

English | [中文](README-zh.md)

Convert **any video** into an `.AVI` + `.THM` pair that a Canon compact camera will
**actually play back in-camera**.

Powered by DeepSeek V4.1 Flash—other than this sentence, the repository author hasn't written anything else 👍

> **⚠️ Scope of verification: every measurement here comes from a single Canon IXUS 105.**
>
> `PowerShot SD1300 IS` and `IXY 200F` are **regional names for that same camera** (the camera's own
> `CanonModelID` lists all three) — they are **not two additional samples**.
>
> **No other Canon model has been tested at all.** The tables below describe this one camera;
> other models are likely to differ. Read [Scope of verification](#scope-of-verification)
> before trying another camera.

An ordinary transcoder cannot do this. It is not a matter of getting the parameters right:
the camera's firmware only accepts the exact format it records itself, and it compares
field by field. This repository documents how that was worked out.

---

## Showcase

### Playing on the camera

The real proof — a Canon IXUS 105 playing the converted file. The timeline sits at
**0'12" of 20.15 s**, and the picture on screen is the tower shot from that exact moment:

![the camera playing the converted file](images/04-on-camera-playback.jpg)

And the opening frame, on the camera's own screen:

![the opening frame on the camera](images/05-on-camera-opening.jpg)

### Source vs converted output

**Left: the source clip ｜ Right: a real frame decoded back out of the converted `.AVI`**
(same moment). The picture is preserved in full; everything outside 4:3 becomes black bars:

![source vs converted output](images/01-source-vs-output.png)

### Choose how it is framed

The source is 13:6 widescreen, so fitting it into a 4:3 640×480 frame always involves a
trade-off. The three `FITMODE` options (left → right):

![the three fit modes](images/02-fit-modes.png)

| Mode | Result |
|---|---|
| `pad` (default) | whole picture + black bars, image scaled to **27%** |
| `crop` | zooms to fill, no bars, image at **44%**, roughly 19% cut from each side |
| `stretch` | fills the frame, but the picture is distorted |

### The thumbnail is the movie's first frame

Left: the generated `.THM`, enlarged 4× so it is visible ｜ Right: frame 0 of the converted
movie. They match:

![thumbnail vs first frame](images/03-thumbnail-vs-frame.png)

---

## Why a normal converter fails

Letting ffmpeg write an AVI directly gives a stream that is correct on paper
(640×480 MJPEG + 12 kHz mono PCM) and the camera still reports **"Cannot recognize image"**.
Comparing against a genuine recording, the differences are:

| Item | The camera's own file | ffmpeg output |
|---|---|---|
| `movi` data chunk offset | **2048** | 10002 |
| `odml`/`dmlh` chunk | present | missing |
| `indx` + `ix00`/`ix01` indexes | present | missing |
| In-frame `APP0` | `AVI1` | `JFIF` |
| In-frame quantisation tables | 2 | 1 |
| Audio chunking | one 12012-byte chunk per 30 frames | tiny fragments |
| **Chroma sampling** | **`Y(2,1)` `C(1,1)`, MCU 16×8** | cannot be produced |

That last row is the crux: **ffmpeg's MJPEG encoder cannot emit `Y(2,1)/C(1,1)`**. And Canon's
decoder **does not read the sampling factors in `SOF` at all** — it hardcodes its own encoder's
layout. Get the number of blocks per MCU wrong and it loses sync, which shows up as
"plays, but the picture is full of garbage".

Fortunately libjpeg's standard 4:2:2 (h2v1) is exactly that layout, and Pillow exposes it
through `subsampling=1`.

## Measured compatibility (IXUS 105, one sample)

This camera compares **field by field** rather than within a tolerance — even 30/1 fps is
rejected, and it differs from 29.97 by only 0.1%:

| Parameter | Accepted | Rejected in testing |
|---|---|---|
| Resolution | **640×480** | 1280×720, 2340×1080 |
| Frame rate | **30000/1001 (29.97)** | 30/1, 25/1, 15/1, 60/1 |
| Chroma sampling | **`Y(2,1)/C(1,1)`** | 4:2:0, 4:4:4 (reports E10 and powers off) |
| Thumbnail maker note | **required** | standard EXIF only → refused |

**The only thing you are free to change is the framing** (`FITMODE=pad / crop / stretch`).

## Quick start

```bat
:: double-click = convert every video in this folder
canon_convert.bat

:: drag videos onto the .bat = convert just those
:: command line
canon_convert.bat "D:\some\other\folder\clip.mp4"
```

Output is written **next to the source video**, same name with a `.AVI` and a `.THM` extension.

**Copying to the camera card**: both files must be copied, into the camera's own folder under
`DCIM\` (for example `DCIM\136CANON\`). They will **not** be seen if placed in the card root —
the camera does not scan the root.

### Requirements

| Dependency | Used for |
|---|---|
| `ffmpeg` / `ffprobe` | decoding and scaling the source, emitting raw RGB |
| **Python 3 + Pillow** | encoding frames with Canon's `Y(2,1)/C(1,1)` sampling (ffmpeg cannot) |
| `exiftool` | writing the thumbnail's EXIF |
| Windows + PowerShell | rebuilding the AVI container |

If they are not on `PATH`, edit `FFMPEG` / `FFPROBE` / `EXIFTOOL` / `PYTHON` in the SETTINGS
block at the top of `canon_convert.bat`.

## How it works

```
source video ──ffmpeg──> raw RGB frames ──Pillow/libjpeg──> MJPEG in Canon's layout
                                                                   │
                                             _canon_finish.ps1     │ rebuild container,
                                             rewrites JPEG markers │
                                                                   ▼
                                                          MVI_xxxx.AVI + .THM
```

1. **Frames are encoded by Pillow** — only libjpeg produces a consistent `Y(2,1)/C(1,1)`
2. **The container is rebuilt from scratch** — `movi` lands at 2048, `odml/dmlh`, two `strl`
   chunks each with an `indx`, `ix00`/`ix01` sub-indexes, a 12012-byte audio chunk every
   30 frames, a two-entry `idx1`, and an `IDIT` recording date
3. **The thumbnail** borrows a real camera `.THM`'s maker note, rewriting only the fields
   that describe this particular movie

### The recording time the camera displays

The time in the corner of the camera's playback screen does **not** come from the standard EXIF.
It lives in a **private field inside the `.THM`** that exiftool neither exposes nor knows about.

That field is a trap for anyone reusing a donor thumbnail: `-TagsFromFile` copies the whole maker
note, so the **donor recording's time comes along with it** and the camera happily displays the
wrong date. (Ours did exactly that — it showed the donor's `10:08` instead of the source's
`09:43`.) The script locates the field and rewrites it, then reads it back to confirm.

Two details worth knowing, both established by diffing against a `.THM` the camera wrote itself:

- it sits immediately after a **repeated frame-rate pair** (`00 00 <num> <den>` twice)
- the value is a unix timestamp of the **local wall clock treated as UTC** — not true UTC
- the `.AVI` has no equivalent field; the time exists only in the `.THM`

The time itself is taken from the **source video's embedded `creation_time`**, *not* from the
filesystem timestamp — the two often differ (a re-encoded file keeps its recording date but not
its download date). If the source carries no such field the script falls back to the file's
timestamp, and you can always pin it by hand with `DATETIME`.

### The builder is verified byte for byte

Feeding the builder a genuine recording's own frames and audio reproduces the camera's
original file **exactly, byte for byte** (11,977,496 bytes, 0 differences). That is the
strongest evidence obtainable without physical hardware.

## Repository layout

| File | Purpose |
|---|---|
| `canon_convert.bat` | the one-click converter; every tunable lives in its SETTINGS block |
| `_canon_frames.py` | ffmpeg's MJPEG encoder cannot do `Y(2,1)/C(1,1)`, so this step is unavoidable |
| `_canon_finish.ps1` | rebuilds the AVI container, rewrites JPEG markers, writes `IDIT` and thumbnail EXIF |
| `_canon_donor.thm` | **required** EXIF donor; supplies the Canon maker note the camera checks — do not delete |
| `使用说明.md` | **full documentation (Chinese)**: the whole investigation, parameter table, FAQ |

> `canon_convert.bat` **must keep CRLF line endings**. Saving it as Unix/LF from a text editor
> makes cmd.exe misread the script.

## Troubleshooting

**Camera will not open the file?** Check resolution 640×480, frame rate 29.97, sampling
`Y(2,1)/C(1,1)`, and that `_canon_donor.thm` is present. See sections 5 and 6 of the
[Chinese guide](使用说明.md).

**The script suddenly becomes "access denied" and cannot even be deleted?** Antivirus has
locked it — add this folder to its trusted list. **The usual trigger is a script containing
`base64` + decompression + raw binary writes**, which is exactly what a dropper looks like.

More answers are in the [Chinese guide](使用说明.md).

## Scope of verification

**Every "measured" result in this document comes from a single Canon IXUS 105 (a 2010 compact).
Sample size: 1.**

| | |
|---|---|
| Tested | one Canon IXUS 105 — **one unit** |
| Not tested | **every other Canon model**, other firmware revisions, other regional variants |
| `SD1300 IS` / `IXY 200F` | regional names for the same camera, **not extra samples** |

**Why this matters**: these conclusions were obtained by trying things on real hardware, and Canon's
models do not share one recording format. Some shoot 1280×720 or higher, some are 25 fps (PAL
regions), and the container layout and JPEG marker order can differ too.

So **nothing here transfers to another model without re-checking**, at minimum:

1. **Resolution and frame rate** — record a clip with that camera and see what it actually emits
2. **In-frame sampling factors** — compare `SOF` field by field; this was the hardest problem here
3. **Container structure** — `movi` offset, `odml`, `indx`, interleave pattern
4. **Thumbnail maker note** — point `REFTHM` at a `.THM` that camera recorded itself

Items 1–3 each have a matching consistency check inside [`_canon_finish.ps1`](_canon_finish.ps1);
item 4 is a one-line setting.

## Disclaimer

This project is not affiliated with Canon in any way and uses none of Canon's code or
documentation.

All format information was obtained by **analysing files this camera recorded**: Canon's
AVI/THM are ordinary RIFF/JPEG structures and MJPEG is an open standard. The project involves
no circumvention of encryption or DRM.

## Authorship

**All code in this project was written by AI: DeepSeek V4.1 Flash.**

Requirements, design trade-offs and every on-camera verification were the project owner's work —
whether the camera really plays a file can only be established by trying it on real hardware,
and that part cannot be delegated to an AI.

> Disclosing the extent of AI involvement is the responsible thing to do: it lets users judge
> where the code came from and how it should be maintained.

## License

[MIT](LICENSE)
