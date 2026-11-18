// Smacker (SMK2/SMK4) decoder for the co-op guest's window: it turns one of the game's videos (TNOVA\MOVIE\*.SMK, read
// from the guest's own game files) into a plain file Godot reads (scripts/coop_movie.gd), since Godot only plays Theora.
// Built on the guest's PC by build.bat or by Uplink itself with the C# compiler that comes with Windows (.NET Framework 4).
//   smkdec.exe IN.SMK OUT.tnv          (OUT.tnv written as OUT.tnv.part, then renamed when complete)
// OUT.tnv, little endian: a 64-byte header
//   "TNV1", width, height, frames, frame period in microseconds, audio rate, channels, bits (8: signed 8-bit,
//   16: signed 16-bit), audio bytes, audio offset, frame offset, frame record size, (4 x 0)
// then each frame: its palette (256 x RGB, 8-bit) and its pixels (width x height palette indices), then the sound
// (track 0, interleaved, ready for an AudioStreamWAV).
// The format as RAD's Smacker 2/4 writes it: Huffman trees (8-bit trees, then "big" 16-bit trees with three recent-value
// escapes) for the 4x4 blocks (mono, full, skip, fill), a delta palette, DPCM sound in Huffman codes.
using System;
using System.IO;

static class SmkDec
{
    sealed class Bits
    {
        readonly byte[] d; long pos; readonly long end;
        public Bits(byte[] data, int off, int len) { d = data; pos = (long)off * 8; end = (long)(off + len) * 8; }
        public int Bit()
        {
            if (pos >= end) { pos++; return 0; }
            int b = (d[pos >> 3] >> (int)(pos & 7)) & 1; pos++; return b;
        }
        public int Get(int n) { int v = 0; for (int i = 0; i < n; i++) v |= Bit() << i; return v; }
        public bool Over { get { return pos > end + 64; } }
    }

    // an 8-bit Huffman tree (a leaf: bit 0 then the 8-bit value; a node: bit 1, its 0 branch, its 1 branch)
    sealed class Small
    {
        readonly int[] l = new int[1024], r = new int[1024], v = new int[1024];
        int n, leaves; public int Root = -1;
        public void Read(Bits b) { n = 0; leaves = 0; Root = Build(b, 0); }
        int Build(Bits b, int depth)
        {
            if (depth > 32 || n >= 1024) throw new InvalidDataException("8-bit tree too deep");
            int k = n++;
            if (b.Bit() == 0)
            {
                if (++leaves > 256) throw new InvalidDataException("8-bit tree too big");
                l[k] = -1; v[k] = b.Get(8); return k;
            }
            l[k] = Build(b, depth + 1); r[k] = Build(b, depth + 1); return k;
        }
        public int Decode(Bits b)
        {
            int k = Root; if (k < 0) return 0;
            while (l[k] >= 0) k = b.Bit() == 0 ? l[k] : r[k];
            return v[k];
        }
    }

    // a 16-bit tree, flat in pre-order: a node holds NODE | the size of its 0 branch; three slots hold the last values
    sealed class Big
    {
        const int NODE = 1 << 30;
        int[] t = new int[1]; int cur; readonly int[] last = new int[3]; readonly int[] esc = new int[3];
        bool present; Small lo, hi;
        public void Read(Bits b, int size)
        {
            present = b.Bit() == 1;
            if (!present) return;
            lo = new Small(); hi = new Small();
            if (b.Bit() == 1) { lo.Read(b); b.Bit(); }
            if (b.Bit() == 1) { hi.Read(b); b.Bit(); }
            for (int i = 0; i < 3; i++) esc[i] = b.Get(16);
            last[0] = last[1] = last[2] = -1;
            t = new int[((size + 3) >> 2) + 4]; cur = 0;
            Build(b, 0);
            b.Bit();
            for (int i = 0; i < 3; i++) if (last[i] == -1) { if (cur >= t.Length) Array.Resize(ref t, cur + 1); last[i] = cur++; }
        }
        int Build(Bits b, int depth)
        {
            if (depth > 64) throw new InvalidDataException("16-bit tree too deep");
            if (cur >= t.Length) throw new InvalidDataException("16-bit tree too big");
            if (b.Bit() == 0)
            {
                int val = lo.Decode(b) | (hi.Decode(b) << 8);
                if (val == esc[0]) { last[0] = cur; val = 0; }
                else if (val == esc[1]) { last[1] = cur; val = 0; }
                else if (val == esc[2]) { last[2] = cur; val = 0; }
                t[cur++] = val; return 1;
            }
            int k = cur++;
            int left = Build(b, depth + 1);
            t[k] = NODE | left;
            int right = Build(b, depth + 1);
            return left + 1 + right;
        }
        public void Reset() { if (present) t[last[0]] = t[last[1]] = t[last[2]] = 0; }
        public int Get(Bits b)
        {
            if (!present) return 0;
            int i = 0;
            while ((t[i] & NODE) != 0)
            {
                if (b.Bit() == 1) i += t[i] & ~NODE;
                i++;
                if (i >= t.Length) throw new InvalidDataException("bad code");
            }
            int v = t[i];
            if (v != t[last[0]]) { t[last[2]] = t[last[1]]; t[last[1]] = t[last[0]]; t[last[0]] = v; }
            return v;
        }
    }

    static readonly int[] RUNS = {
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30,
        31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58,
        59, 128, 256, 512, 1024, 2048 };

    static int U32(byte[] d, int o) { return d[o] | d[o + 1] << 8 | d[o + 2] << 16 | d[o + 3] << 24; }
    static void W32(Stream s, long v) { s.WriteByte((byte)v); s.WriteByte((byte)(v >> 8)); s.WriteByte((byte)(v >> 16)); s.WriteByte((byte)(v >> 24)); }
    // the 6-bit palette values as the game's screen shows them (DOSBox's DAC: v x 255 / 63, rounded; measured on the
    // game's own picture of BRIEF30A: 11 -> 45, 49 -> 198)
    static byte Six(int v) { v &= 63; return (byte)((v * 255 + 31) / 63); }

    static int Main(string[] args)
    {
        if (args.Length < 2) { Console.Error.WriteLine("usage: smkdec IN.SMK OUT.tnv"); return 2; }
        string part = args[1] + ".part";
        try
        {
            Decode(File.ReadAllBytes(args[0]), part);
            if (File.Exists(args[1])) File.Delete(args[1]);
            File.Move(part, args[1]);
            return 0;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine("smkdec: " + e.Message);
            try { File.Delete(part); } catch { }
            return 1;
        }
    }

    static void Decode(byte[] f, string outPath)
    {
        if (f.Length < 104 || f[0] != 'S' || f[1] != 'M' || f[2] != 'K' || (f[3] != '2' && f[3] != '4'))
            throw new InvalidDataException("not a Smacker file");
        bool v4 = f[3] == '4';
        int w = U32(f, 4), h = U32(f, 8), frames = U32(f, 12), rate = U32(f, 16), flags = U32(f, 20);
        if (w <= 0 || h <= 0 || w > 1280 || h > 1024 || frames <= 0 || frames > 100000) throw new InvalidDataException("bad size");
        if ((flags & 1) != 0) frames++;                          // the ring frame (a copy of the first, for loops)
        int treesSize = U32(f, 52), mmapSize = U32(f, 56), mclrSize = U32(f, 60), fullSize = U32(f, 64), typeSize = U32(f, 68);
        uint arate = (uint)U32(f, 72);
        long period = rate > 0 ? rate * 1000L : rate < 0 ? -rate * 10L : 100000L;   // microseconds
        int pos = 104;
        int[] fsize = new int[frames]; byte[] ftype = new byte[frames];
        for (int i = 0; i < frames; i++) { fsize[i] = U32(f, pos) & ~3; pos += 4; }
        for (int i = 0; i < frames; i++) ftype[i] = f[pos++];
        var tb = new Bits(f, pos, treesSize);
        Big mmap = new Big(), mclr = new Big(), full = new Big(), type = new Big();
        mmap.Read(tb, mmapSize); mclr.Read(tb, mclrSize); full.Read(tb, fullSize); type.Read(tb, typeSize);
        pos += treesSize;

        bool hasAudio = (arate & 0x40000000) != 0, comp = (arate & 0x80000000) != 0;
        int achan = (arate & 0x10000000) != 0 ? 2 : 1, abits = (arate & 0x20000000) != 0 ? 16 : 8, ahz = (int)(arate & 0xFFFFFF);
        if (v4 && (arate & 0x0C000000) != 0) hasAudio = false;   // (Bink audio in a Smacker 4: never in this game)
        var audio = new MemoryStream();

        byte[] pal = new byte[768], pix = new byte[w * h];
        int recSize = 768 + w * h, bad = 0;
        using (var o = new FileStream(outPath, FileMode.Create, FileAccess.Write, FileShare.Read, 1 << 20))
        {
            o.Write(new byte[64], 0, 64);
            for (int fi = 0; fi < frames; fi++)
            {
                int p = pos, end = pos + fsize[fi];
                if (end > f.Length) end = f.Length;
                if ((ftype[fi] & 1) != 0 && p < end)
                {
                    int len = f[p] * 4;
                    ReadPalette(f, p + 1, p + len, pal);
                    p += len;
                }
                try                                               // (a damaged frame: the picture before it kept)
                {
                    for (int k = 0; k < 7; k++)
                    {
                        if ((ftype[fi] & (2 << k)) == 0) continue;
                        if (p + 4 > end) break;
                        int len = U32(f, p);
                        if (len < 4 || p + len > end) throw new InvalidDataException("bad sound chunk");
                        if (k == 0 && hasAudio) Sound(f, p + 4, len - 4, comp, achan, abits, audio);
                        p += len;
                    }
                    if (p < end) Video(new Bits(f, p, end - p), w, h, pix, mmap, mclr, full, type, v4);
                }
                catch (Exception e) { if (bad++ == 0) Console.Error.WriteLine("smkdec: frame " + fi + ": " + e.Message); }
                o.Write(pal, 0, 768); o.Write(pix, 0, pix.Length);
                pos += fsize[fi];
            }
            long aoff = o.Position;
            audio.Position = 0; audio.CopyTo(o);
            o.Position = 0;
            o.Write(new byte[] { (byte)'T', (byte)'N', (byte)'V', (byte)'1' }, 0, 4);
            W32(o, w); W32(o, h); W32(o, frames); W32(o, period);
            W32(o, hasAudio ? ahz : 0); W32(o, achan); W32(o, abits); W32(o, audio.Length); W32(o, aoff); W32(o, 64); W32(o, recSize);
        }
    }

    static readonly byte[] oldpal = new byte[768];
    static void ReadPalette(byte[] f, int p, int end, byte[] pal)
    {
        Buffer.BlockCopy(pal, 0, oldpal, 0, 768);
        int sz = 0, q = 0;
        while (sz < 256 && p < end)
        {
            int t = f[p++];
            if ((t & 0x80) != 0)                                  // keep the next entries
            {
                int n = (t & 0x7F) + 1; sz += n; q += n * 3;
            }
            else if ((t & 0x40) != 0)                             // copy entries of the previous palette
            {
                int n = (t & 0x3F) + 1, off = f[p++];
                if (off + n > 256) throw new InvalidDataException("bad palette");
                off *= 3;
                while (n-- > 0 && sz < 256)
                {
                    pal[q++] = oldpal[off++]; pal[q++] = oldpal[off++]; pal[q++] = oldpal[off++]; sz++;
                }
            }
            else                                                  // a new entry
            {
                pal[q++] = Six(t); pal[q++] = Six(f[p++]); pal[q++] = Six(f[p++]); sz++;
            }
        }
    }

    static void Video(Bits b, int w, int h, byte[] pix, Big mmap, Big mclr, Big full, Big type, bool v4)
    {
        mmap.Reset(); mclr.Reset(); full.Reset(); type.Reset();
        int bw = w >> 2, blocks = bw * (h >> 2), blk = 0;
        while (blk < blocks)
        {
            if (b.Over) throw new InvalidDataException("video data ran out");
            int tcode = type.Get(b), run = RUNS[(tcode >> 2) & 0x3F];
            switch (tcode & 3)
            {
                case 0:                                           // two colours, a 16-bit map
                    while (run-- > 0 && blk < blocks)
                    {
                        int clr = mclr.Get(b), map = mmap.Get(b);
                        byte hi = (byte)(clr >> 8), lo = (byte)clr;
                        int o = (blk / bw) * 4 * w + (blk % bw) * 4;
                        for (int i = 0; i < 4; i++, o += w, map >>= 4)
                        {
                            pix[o] = (map & 1) != 0 ? hi : lo; pix[o + 1] = (map & 2) != 0 ? hi : lo;
                            pix[o + 2] = (map & 4) != 0 ? hi : lo; pix[o + 3] = (map & 8) != 0 ? hi : lo;
                        }
                        blk++;
                    }
                    break;
                case 1:                                           // every pixel
                    {
                        int mode = 0;
                        if (v4) { if (b.Bit() == 1) mode = 1; else if (b.Bit() == 1) mode = 2; }
                        while (run-- > 0 && blk < blocks)
                        {
                            int o = (blk / bw) * 4 * w + (blk % bw) * 4;
                            if (mode == 0)
                            {
                                for (int i = 0; i < 4; i++, o += w)
                                {
                                    int c = full.Get(b); pix[o + 2] = (byte)c; pix[o + 3] = (byte)(c >> 8);
                                    c = full.Get(b); pix[o] = (byte)c; pix[o + 1] = (byte)(c >> 8);
                                }
                            }
                            else if (mode == 1)                   // 2x2 pixels
                            {
                                for (int i = 0; i < 2; i++, o += 2 * w)
                                {
                                    int c = full.Get(b);
                                    pix[o] = pix[o + 1] = pix[o + w] = pix[o + w + 1] = (byte)c;
                                    pix[o + 2] = pix[o + 3] = pix[o + w + 2] = pix[o + w + 3] = (byte)(c >> 8);
                                }
                            }
                            else                                  // two lines repeated
                            {
                                for (int i = 0; i < 2; i++, o += 2 * w)
                                {
                                    int c1 = full.Get(b), c2 = full.Get(b);
                                    for (int j = 0; j < 2; j++)
                                    {
                                        int r = o + j * w;
                                        pix[r] = (byte)c2; pix[r + 1] = (byte)(c2 >> 8); pix[r + 2] = (byte)c1; pix[r + 3] = (byte)(c1 >> 8);
                                    }
                                }
                            }
                            blk++;
                        }
                    }
                    break;
                case 2:                                           // unchanged
                    blk += Math.Min(run, blocks - blk);
                    break;
                default:                                          // one colour
                    {
                        byte c = (byte)(tcode >> 8);
                        while (run-- > 0 && blk < blocks)
                        {
                            int o = (blk / bw) * 4 * w + (blk % bw) * 4;
                            for (int i = 0; i < 4; i++, o += w) { pix[o] = pix[o + 1] = pix[o + 2] = pix[o + 3] = c; }
                            blk++;
                        }
                    }
                    break;
            }
        }
    }

    // one frame's sound: packed (DPCM, Huffman codes) or plain; written as signed samples
    static void Sound(byte[] f, int p, int len, bool comp, int chans, int bits, MemoryStream outp)
    {
        if (!comp)
        {
            for (int i = 0; i < len; i++) outp.WriteByte(bits == 8 ? (byte)(f[p + i] ^ 0x80) : f[p + i]);
            return;
        }
        if (len < 4) return;
        int unp = U32(f, p);
        var b = new Bits(f, p + 4, len - 4);
        if (b.Bit() == 0) return;                                 // no sound in this frame
        int stereo = b.Bit(), sixteen = b.Bit();
        int ntrees = 1 << (sixteen + stereo);
        var trees = new Small[4];
        for (int i = 0; i < ntrees; i++)
        {
            trees[i] = new Small();
            b.Bit(); trees[i].Read(b); b.Bit();
        }
        if (sixteen == 0)
        {
            int[] pred = new int[2];
            for (int i = stereo; i >= 0; i--) pred[i] = b.Get(8);
            int n = 0;
            for (int i = 0; i <= stereo; i++, n++) outp.WriteByte((byte)(pred[i] ^ 0x80));
            for (; n < unp; n++)
            {
                int c = (n & stereo) != 0 ? 1 : 0;
                pred[c] = (pred[c] + trees[c].Decode(b)) & 0xFF;
                outp.WriteByte((byte)(pred[c] ^ 0x80));
            }
        }
        else
        {
            int[] pred = new int[2];
            for (int i = stereo; i >= 0; i--) { int v = b.Get(16); pred[i] = (short)((v >> 8) | ((v & 0xFF) << 8)); }
            int n = 0;
            for (int i = 0; i <= stereo; i++, n += 2) { outp.WriteByte((byte)pred[i]); outp.WriteByte((byte)(pred[i] >> 8)); }
            for (; n < unp; n += 2)
            {
                int c = ((n >> 1) & stereo) != 0 ? 1 : 0;
                int lo = trees[c * 2].Decode(b), hi = trees[c * 2 + 1].Decode(b);
                pred[c] = (short)(pred[c] + (short)(lo | hi << 8));
                outp.WriteByte((byte)pred[c]); outp.WriteByte((byte)(pred[c] >> 8));
            }
        }
    }
}
