"""_canon_frames.py - encode video frames as Canon-style MJPEG.

ffmpeg's MJPEG encoder can only emit Y(2,2)/C(1,2) (4:2:2 with 16x16 MCUs),
Y(2,2)/C(1,1) (4:2:0) or Y(1,1)/C(1,1) (4:4:4).  A Canon IXUS 105 accepts none
of those: its movie decoder is fixed to the layout its own encoder produces,
Y(2,1)/C(1,1) - 4:2:2 with 16x8 MCUs and 4 blocks per MCU.

libjpeg's standard 4:2:2 ("h2v1") is exactly that layout, and Pillow exposes it
as subsampling=1 (note: 0=4:4:4, 1=4:2:2, 2=4:2:0).  So the frames are encoded
here instead, from raw RGB produced by ffmpeg.

usage:  _canon_frames.py <rgb_in|-> <mjpeg_out> <width> <height> <quality>
prints the number of frames written.
"""

import io
import sys

from PIL import Image


def main():
    if len(sys.argv) != 6:
        sys.stderr.write(__doc__)
        return 2
    src, dst, w, h, q = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
    stride = w * h * 3

    fin = sys.stdin.buffer if src == '-' else open(src, 'rb')
    count = 0
    try:
        with open(dst, 'wb') as fout:
            while True:
                data = fin.read(stride)
                if len(data) < stride:
                    break
                im = Image.frombytes('RGB', (w, h), data)
                buf = io.BytesIO()
                # subsampling=1 -> libjpeg 4:2:2 -> SOF Y(2,1) C(1,1) C(1,1)
                im.save(buf, 'JPEG', subsampling=1, quality=q, optimize=False)
                fout.write(buf.getvalue())
                count += 1
    finally:
        if fin is not sys.stdin.buffer:
            fin.close()

    print(count)
    return 0


if __name__ == '__main__':
    sys.exit(main())
