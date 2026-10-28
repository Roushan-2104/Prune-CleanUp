// PruneVision — reads text (OCR) and counts faces in images using the
// engines built into Windows 10/11. Fully offline; nothing leaves the laptop.
//
// Built with the C# compiler that ships with Windows (.NET Framework 4.x), so
// it runs on any Windows 10/11 PC without installing anything. See build.ps1.
//
// Usage:  PruneVision.exe <jobs> <list file>
//   <jobs>       any of "ocr", "faces", "gray", "thumb", comma-separated (the default)
//   <list file>  UTF-8 text file, one image per line: "path", or
//                "jobs<TAB>path" to choose jobs for that image
// Output (stdout, one JSON object per line):
//   first line:  {"ready":true,"ocr":true,"ocrLanguage":"en-US","faces":true}
//   then, per image, in order:
//     {"path":"...","text":"line 1\nline 2","lines":2,"faces":1,"ok":true}
//     {"path":"...","ok":false,"error":"..."}
// `PruneVision.exe info` prints only the first line.
// `PruneVision.exe serve <folder> [parent pid]` keeps running and answers
// list after list (see Serve).
//
// Requests come in a file rather than on stdin because .NET Framework
// programs can't reliably read the stdin pipes some callers (Dart) create.
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Windows.Foundation;
using Windows.Globalization;
using Windows.Graphics.Imaging;
using Windows.Media.FaceAnalysis;
using Windows.Media.Ocr;
using Windows.Storage;
using Windows.Storage.Streams;

static class Program
{
    // Face detection doesn't need full resolution; this keeps it fast.
    const uint FaceMaxDimension = 1280;

    static int Main(string[] args)
    {
        Console.OutputEncoding = new UTF8Encoding(false);

        RunAtFullSpeed();
        OcrEngine ocr = OcrEngine.TryCreateFromUserProfileLanguages();
        if (ocr == null) ocr = OcrEngine.TryCreateFromLanguage(new Language("en-US"));
        FaceDetector faces = null; // created on first use: few photos need it

        Console.Out.WriteLine("{\"ready\":true,\"ocr\":" + Bool(ocr != null) +
            ",\"ocrLanguage\":" + Json(ocr != null ? ocr.RecognizerLanguage.LanguageTag : "") +
            ",\"faces\":" + Bool(FaceDetector.IsSupported) + "}");
        Console.Out.Flush();
        if (args.Length == 1 && args[0] == "info") return 0;
        if (args.Length >= 2 && args[0] == "serve") return Serve(ocr, args[1], args.Length > 2 ? args[2] : null);
        if (args.Length != 2)
        {
            Console.Error.WriteLine("usage: PruneVision.exe <ocr|faces|ocr,faces> <list file>");
            return 64;
        }

        foreach (string raw in File.ReadAllLines(args[1], new UTF8Encoding(false)))
        {
            string reply = Answer(ocr, ref faces, args[0], raw);
            if (reply == null) continue;
            Console.Out.WriteLine(reply);
            Console.Out.Flush();
        }
        return 0;
    }

    /// `PruneVision.exe serve <folder>`: stays running and answers list
    /// after list, so a long check doesn't start a new helper (and load the
    /// text reader again) every few images. The caller writes lists to the
    /// folder as 1.txt, 2.txt, … (each renamed into place once complete);
    /// after each list's replies comes `{"end":n}`. Stops when the folder is
    /// deleted, a file named "stop" appears in it, the process with id
    /// <parent pid> (if given) ends, or nobody reads the replies any more.
    static int Serve(OcrEngine ocr, string folder, string parentPid)
    {
        FaceDetector faces = null;
        folder = Path.GetFullPath(folder);
        System.Diagnostics.Process parent = null;
        int pid;
        if (parentPid != null && int.TryParse(parentPid, out pid))
        {
            try { parent = System.Diagnostics.Process.GetProcessById(pid); }
            catch (ArgumentException) { return 0; } // already gone
        }
        using (AutoResetEvent changed = new AutoResetEvent(false))
        using (FileSystemWatcher watcher = new FileSystemWatcher(folder))
        {
            watcher.Created += delegate { changed.Set(); };
            watcher.Renamed += delegate { changed.Set(); };
            watcher.EnableRaisingEvents = true;
            for (int n = 1; ; n++)
            {
                string list = Path.Combine(folder, n + ".txt");
                while (!File.Exists(list))
                {
                    if (!Directory.Exists(folder) || File.Exists(Path.Combine(folder, "stop"))) return 0;
                    if (parent != null && parent.HasExited) return 0;
                    changed.WaitOne(500); // the watcher wakes us at once; this is a safety net
                }
                string[] lines = ReadList(list);
                try
                {
                    if (lines == null)
                    {
                        // Say so, rather than answer nothing: an empty answer
                        // would look like every photo in the list had failed.
                        Console.Out.WriteLine("{\"end\":" + n + ",\"error\":\"list unreadable\"}");
                        Console.Out.Flush();
                        Retry(() => File.Delete(list));
                        continue;
                    }
                    foreach (string raw in lines)
                    {
                        string reply = Answer(ocr, ref faces, "ocr", raw);
                        if (reply != null) Console.Out.WriteLine(reply);
                    }
                    Console.Out.WriteLine("{\"end\":" + n + "}");
                    Console.Out.Flush();
                }
                catch (IOException)
                {
                    return 0; // the reader has gone
                }
                Retry(() => File.Delete(list));
            }
        }
    }

    /// A list file's lines. A file that has only just appeared may still be
    /// held for a moment (e.g. by an antivirus scan), so this retries; after
    /// two seconds it gives up and returns null, so the caller can report it.
    static string[] ReadList(string path)
    {
        string[] lines = null;
        if (!Retry(() => lines = File.ReadAllLines(path, new UTF8Encoding(false))))
        {
            Trace("list unreadable: " + path);
            return null;
        }
        return lines;
    }

    /// Runs a file action, retrying for up to two seconds while the file is
    /// in use. True if it worked.
    static bool Retry(Action action)
    {
        for (int attempt = 0; ; attempt++)
        {
            try
            {
                action();
                return true;
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            if (attempt >= 100) return false;
            Thread.Sleep(20);
        }
    }

    /// The reply to one line of a list, or null for a blank line.
    static string Answer(OcrEngine ocr, ref FaceDetector faces, string defaultJobs, string raw)
    {
        string line = raw.Trim('﻿', '\r', ' ');
        if (line.Length == 0) return null;
        // A line may say which jobs it wants: "ocr,gray<TAB>path".
        int tab = line.IndexOf('\t');
        string[] jobs = (tab >= 0 ? line.Substring(0, tab) : defaultJobs).Split(',');
        string path = tab >= 0 ? line.Substring(tab + 1) : line;
        // "ocr@1600" reads text with the image's longest side shrunk to 1600 px.
        uint ocrSize = OcrEngine.MaxImageDimension;
        bool doOcr = false;
        foreach (string j in jobs)
        {
            if (j == "ocr") doOcr = true;
            else if (j.StartsWith("ocr@") && uint.TryParse(j.Substring(4), out ocrSize)) doOcr = true;
        }
        ocrSize = Math.Max(320, Math.Min(ocrSize, OcrEngine.MaxImageDimension));
        bool doFaces = Array.IndexOf(jobs, "faces") >= 0,
            doGray = Array.IndexOf(jobs, "gray") >= 0, doThumb = Array.IndexOf(jobs, "thumb") >= 0;
        if (doFaces && faces == null && FaceDetector.IsSupported) faces = Await(FaceDetector.CreateAsync());
        Trace("image: " + path);
        try
        {
            StringBuilder sb = new StringBuilder("{\"path\":").Append(Json(path));
            if (doGray || doOcr || doFaces)
            {
                using (Picture picture = new Picture(path, decodeOnce: doGray && doOcr))
                {
                    if (doGray) sb.Append(SmallGray(picture));
                    if (doOcr) sb.Append(ReadText(ocr, picture, ocrSize));
                    if (doFaces) sb.Append(CountFaces(faces, picture));
                }
            }
            if (doThumb) sb.Append(Thumbnail(path));
            return sb.Append(",\"ok\":true}").ToString();
        }
        catch (Exception e)
        {
            Exception inner = e is AggregateException && e.InnerException != null ? e.InnerException : e;
            return "{\"path\":" + Json(path) + ",\"ok\":false,\"error\":" + Json(inner.Message) + "}";
        }
    }

    /// A small grayscale copy (longest side 256 px) for blur and look-alike
    /// checks. Returns `,"gray":{"w":…,"h":…,"stride":…,"b64":"…"}`.
    static string SmallGray(Picture picture)
    {
        // Decoders can't always output grayscale directly on every PC, so
        // decode as colour (always supported) and convert here.
        SoftwareBitmap bmp = picture.Decode(256, BitmapAlphaMode.Ignore);
        int w = bmp.PixelWidth, h = bmp.PixelHeight;
        Windows.Storage.Streams.Buffer buffer = new Windows.Storage.Streams.Buffer((uint)(w * h * 4 + 4096));
        bmp.CopyToBuffer(buffer);
        byte[] bgra = new byte[buffer.Length];
        using (DataReader reader = DataReader.FromBuffer(buffer)) reader.ReadBytes(bgra);
        int stride = h == 0 ? w * 4 : bgra.Length / h; // rows may be padded
        byte[] gray = new byte[w * h];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                int i = y * stride + x * 4;
                gray[y * w + x] = (byte)((114 * bgra[i] + 587 * bgra[i + 1] + 299 * bgra[i + 2]) / 1000);
            }
        }
        return ",\"gray\":{\"w\":" + w + ",\"h\":" + h + ",\"stride\":" + w +
            ",\"b64\":\"" + Convert.ToBase64String(gray) + "\"}";
    }

    /// Returns the JSON fields `,"text":…,"lines":n`.
    static string ReadText(OcrEngine ocr, Picture picture, uint maxSide)
    {
        if (ocr == null) throw new InvalidOperationException("Windows text recognition is not available");
        OcrResult result = Await(ocr.RecognizeAsync(picture.Decode(maxSide, BitmapAlphaMode.Premultiplied, screensFullSize: true)));
        // Keep line breaks: the rules use them (e.g. "Paid to" on one line, name on the next).
        StringBuilder text = new StringBuilder();
        foreach (OcrLine l in result.Lines)
        {
            if (text.Length > 0) text.Append('\n');
            text.Append(l.Text);
        }
        return ",\"text\":" + Json(text.ToString()) + ",\"lines\":" + result.Lines.Count;
    }

    /// Returns the JSON field `,"faces":n`.
    static string CountFaces(FaceDetector detector, Picture picture)
    {
        if (detector == null) throw new InvalidOperationException("Windows face detection is not available");
        // Supported pixel formats differ between PCs, so ask instead of assuming.
        BitmapPixelFormat wanted = BitmapPixelFormat.Gray8;
        foreach (BitmapPixelFormat f in FaceDetector.GetSupportedBitmapPixelFormats())
        {
            wanted = f;
            if (f == BitmapPixelFormat.Gray8) break;
        }
        using (SoftwareBitmap bmp = SoftwareBitmap.Convert(picture.Decode(FaceMaxDimension, BitmapAlphaMode.Premultiplied), wanted))
        {
            return ",\"faces\":" + Await(detector.DetectFacesAsync(bmp)).Count;
        }
    }

    /// A picture of what a non-photo file is, so it can be recognised at a
    /// glance: a PDF's first page, an app installer's own icon, or the
    /// thumbnail Windows shows for it in File Explorer (Word, Excel, …),
    /// else the icon of the app that opens it. Returns `,"thumb":"<PNG, base64>"`.
    static string Thumbnail(string path)
    {
        string ext = Path.GetExtension(path).ToLowerInvariant();
        byte[] png = null;
        if (ext == ".pdf") png = PdfFirstPage(path);
        else if (ext == ".apk") png = ApkIcon(path);
        else if (Array.IndexOf(ShellTypes, ext) >= 0) png = OnSta(() => ShellThumbnail(path));
        return png == null ? "" : ",\"thumb\":\"" + Convert.ToBase64String(png) + "\"";
    }

    /// The only types Windows' shell is asked to draw. Files come from a
    /// phone, so they may be crafted: for shortcut-like types (.lnk, .url,
    /// .library-ms, .searchConnector-ms…) just drawing the icon can make
    /// Windows contact a server named inside the file.
    static readonly string[] ShellTypes = {
        ".doc", ".docx", ".docm", ".dot", ".dotx", ".rtf", ".odt", ".txt", ".md", ".csv",
        ".xls", ".xlsx", ".xlsm", ".ods", ".ppt", ".pptx", ".pptm", ".pps", ".ppsx", ".odp",
    };

    /// Pictures bigger than this on either side are not decoded: a crafted
    /// file could otherwise ask for gigabytes of memory.
    const int MaxSide = 4096;

    /// The first page, rendered by Windows' own PDF engine; null if the PDF
    /// is locked or damaged.
    static byte[] PdfFirstPage(string path)
    {
        try
        {
            StorageFile file = Await(StorageFile.GetFileFromPathAsync(Path.GetFullPath(path)));
            Windows.Data.Pdf.PdfDocument doc = Await(Windows.Data.Pdf.PdfDocument.LoadFromFileAsync(file));
            if (doc.PageCount == 0) return null;
            using (Windows.Data.Pdf.PdfPage page = doc.GetPage(0))
            using (InMemoryRandomAccessStream s = new InMemoryRandomAccessStream())
            {
                Windows.Data.Pdf.PdfPageRenderOptions o = new Windows.Data.Pdf.PdfPageRenderOptions();
                o.DestinationWidth = 600; // PNG unless told otherwise
                // A very tall page: only its top (at most 4 widths high), so
                // the picture stays small whatever size the page claims.
                Windows.Foundation.Size size = page.Size;
                if (size.Width <= 0 || size.Height <= 0) return null;
                if (size.Height > 4 * size.Width) o.SourceRect = new Windows.Foundation.Rect(0, 0, size.Width, 4 * size.Width);
                AwaitAction(page.RenderToStreamAsync(s, o));
                return ReadAll(s);
            }
        }
        catch (Exception e)
        {
            Trace("pdf: " + e.Message);
            return null;
        }
    }

    /// The app's launcher icon from inside an .apk (a zip): the biggest
    /// res/…/ic_launcher*.png or .webp that isn't an adaptive-icon layer.
    /// Null when the app keeps its icon under an unreadable (shrunk) name.
    static byte[] ApkIcon(string path)
    {
        try
        {
            using (System.IO.Compression.ZipArchive zip = System.IO.Compression.ZipFile.OpenRead(path))
            {
                System.IO.Compression.ZipArchiveEntry best = null;
                int bestRank = 0;
                foreach (System.IO.Compression.ZipArchiveEntry e in zip.Entries)
                {
                    string n = e.FullName.ToLowerInvariant();
                    if (!n.StartsWith("res/") || !(n.EndsWith(".png") || n.EndsWith(".webp"))) continue;
                    if (e.Length > (2 << 20)) continue; // no icon is this big: never unpack it
                    string file = n.Substring(n.LastIndexOf('/') + 1);
                    if (!file.StartsWith("ic_launcher") && !file.StartsWith("app_icon") && !file.Contains("launcher")) continue;
                    int rank = file.Contains("foreground") || file.Contains("background") || file.Contains("monochrome") ? 1 : 2;
                    if (rank > bestRank || (rank == bestRank && e.Length > best.Length))
                    {
                        best = e;
                        bestRank = rank;
                    }
                }
                if (best == null) return null;
                // Never trust the size the zip claims: stop unpacking past 2 MB.
                using (Stream s = best.Open())
                using (MemoryStream m = new MemoryStream())
                {
                    byte[] buffer = new byte[81920];
                    int n;
                    while ((n = s.Read(buffer, 0, buffer.Length)) > 0)
                    {
                        m.Write(buffer, 0, n);
                        if (m.Length > (2 << 20)) return null;
                    }
                    return ToPng(m.ToArray());
                }
            }
        }
        catch (Exception e)
        {
            Trace("apk: " + e.Message);
            return null;
        }
    }

    /// Any image Windows can decode (PNG, WebP…) as PNG.
    static byte[] ToPng(byte[] image)
    {
        using (InMemoryRandomAccessStream input = new InMemoryRandomAccessStream())
        {
            using (DataWriter w = new DataWriter(input.GetOutputStreamAt(0)))
            {
                w.WriteBytes(image);
                Await(w.StoreAsync());
                Await(w.FlushAsync());
                w.DetachStream();
            }
            BitmapDecoder dec = Await(BitmapDecoder.CreateAsync(input));
            if (dec.PixelWidth > MaxSide || dec.PixelHeight > MaxSide) return null;
            using (SoftwareBitmap bmp = Await(dec.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied)))
            using (InMemoryRandomAccessStream output = new InMemoryRandomAccessStream())
            {
                BitmapEncoder enc = Await(BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, output));
                enc.SetSoftwareBitmap(bmp);
                AwaitAction(enc.FlushAsync());
                return ReadAll(output);
            }
        }
    }

    static byte[] ReadAll(IRandomAccessStream s)
    {
        byte[] bytes = new byte[s.Size];
        using (DataReader r = new DataReader(s.GetInputStreamAt(0)))
        {
            Await(r.LoadAsync((uint)s.Size));
            r.ReadBytes(bytes);
        }
        return bytes;
    }

    /// The thumbnail File Explorer shows (or the file type's icon), 256 px.
    static byte[] ShellThumbnail(string path)
    {
        IShellItemImageFactory factory;
        SHCreateItemFromParsingName(Path.GetFullPath(path), IntPtr.Zero, typeof(IShellItemImageFactory).GUID, out factory);
        IntPtr hbm;
        int hr = factory.GetImage(new NativeSize { cx = 256, cy = 256 }, 0, out hbm); // 0: thumbnail, else icon
        if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        try
        {
            NativeBitmap bm;
            GetObject(hbm, Marshal.SizeOf(typeof(NativeBitmap)), out bm);
            System.Drawing.Bitmap result;
            if (bm.bmBitsPixel == 32 && bm.bmBits != IntPtr.Zero)
            {
                // Keep transparency (Image.FromHbitmap would turn it black).
                using (System.Drawing.Bitmap view = new System.Drawing.Bitmap(bm.bmWidth, bm.bmHeight, bm.bmWidthBytes,
                    System.Drawing.Imaging.PixelFormat.Format32bppPArgb, bm.bmBits))
                {
                    result = new System.Drawing.Bitmap(view);
                }
            }
            else
            {
                result = System.Drawing.Image.FromHbitmap(hbm);
            }
            using (result)
            using (MemoryStream m = new MemoryStream())
            {
                result.Save(m, System.Drawing.Imaging.ImageFormat.Png);
                return m.ToArray();
            }
        }
        finally
        {
            DeleteObject(hbm);
        }
    }

    /// Windows 11 may move window-less helpers like this one onto its slow,
    /// power-saving cores ("EcoQoS"), most of all on battery, which made the
    /// photo check several times slower. The user is waiting on this work, so
    /// ask for normal speed. (Older Windows ignores the request.)
    static void RunAtFullSpeed()
    {
        // For measuring only: PRUNE_VISION_POWER=default leaves it to Windows,
        // =eco forces the slow cores.
        string mode = Environment.GetEnvironmentVariable("PRUNE_VISION_POWER");
        if (mode == "default") return;
        ProcessPowerThrottlingState s = new ProcessPowerThrottlingState
        {
            Version = 1, // PROCESS_POWER_THROTTLING_CURRENT_VERSION
            ControlMask = 1 | 4, // EXECUTION_SPEED | IGNORE_TIMER_RESOLUTION
            StateMask = mode == "eco" ? 1u | 4u : 0u, // 0: never throttled
        };
        SetProcessInformation(GetCurrentProcess(), 4 /* ProcessPowerThrottling */, ref s, Marshal.SizeOf(s));
    }

    [StructLayout(LayoutKind.Sequential)]
    struct ProcessPowerThrottlingState { public uint Version, ControlMask, StateMask; }

    [DllImport("kernel32.dll")]
    static extern bool SetProcessInformation(IntPtr process, int infoClass, ref ProcessPowerThrottlingState info, int size);

    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();

    /// Shell thumbnail providers expect a single-threaded apartment.
    static T OnSta<T>(Func<T> work)
    {
        T result = default(T);
        Exception error = null;
        Thread t = new Thread(() =>
        {
            try { result = work(); }
            catch (Exception e) { error = e; }
        });
        t.SetApartmentState(ApartmentState.STA);
        t.Start();
        t.Join();
        if (error != null) throw error;
        return result;
    }

    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItemImageFactory
    {
        [PreserveSig] int GetImage(NativeSize size, int flags, out IntPtr phbm);
    }

    [StructLayout(LayoutKind.Sequential)]
    struct NativeSize { public int cx, cy; }

    [StructLayout(LayoutKind.Sequential)]
    struct NativeBitmap
    {
        public int bmType, bmWidth, bmHeight, bmWidthBytes;
        public ushort bmPlanes, bmBitsPixel;
        public IntPtr bmBits;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName(string path, IntPtr bindCtx,
        [MarshalAs(UnmanagedType.LPStruct)] Guid riid, out IShellItemImageFactory item);

    [DllImport("gdi32.dll")]
    static extern int GetObject(IntPtr h, int size, out NativeBitmap bitmap);

    [DllImport("gdi32.dll")]
    static extern bool DeleteObject(IntPtr h);

    static void AwaitAction(IAsyncAction op)
    {
        using (ManualResetEventSlim done = new ManualResetEventSlim(false))
        {
            op.Completed = delegate { done.Set(); };
            done.Wait();
        }
        if (op.Status == AsyncStatus.Error) throw op.ErrorCode;
        if (op.Status == AsyncStatus.Canceled) throw new OperationCanceledException();
    }

    /// One image file, opened once for all the jobs asked of it.
    sealed class Picture : IDisposable
    {
        readonly IRandomAccessStream stream;
        readonly BitmapDecoder decoder;
        readonly int turn = -1; // how to stand it upright (WIC options); -1: don't decode once
        readonly System.Collections.Generic.List<SoftwareBitmap> made = new System.Collections.Generic.List<SoftwareBitmap>();
        SoftwareBitmap raw; // full size, as stored in the file; only when decoding once

        /// With decodeOnce (several sizes wanted), the file is decoded once
        /// at full size and the smaller copies are shrunk and turned from
        /// that, instead of decoding a 12-megapixel photo two times. The
        /// result is the same, pixel for pixel: it is the same filter, in the
        /// same order, that Windows uses while decoding. Only for opaque JPEG
        /// and PNG with a known orientation, where that was checked.
        public Picture(string path, bool decodeOnce)
        {
            StorageFile file = Await(StorageFile.GetFileFromPathAsync(Path.GetFullPath(path)));
            stream = Await(file.OpenAsync(FileAccessMode.Read));
            try
            {
                decoder = Await(BitmapDecoder.CreateAsync(stream));
            }
            catch
            {
                stream.Dispose();
                throw;
            }
            Guid codec = decoder.DecoderInformation.CodecId;
            if (decodeOnce && Wic.Available && decoder.BitmapAlphaMode == BitmapAlphaMode.Ignore &&
                (codec == BitmapDecoder.JpegDecoderId || codec == BitmapDecoder.PngDecoderId))
            {
                turn = Wic.TurnFor(Orientation());
                // Never guess: the turn must give the size Windows reports.
                bool sideways = turn == Wic.Rotate90 || turn == Wic.Rotate270 || turn == (Wic.Rotate90 | Wic.FlipVertical) || turn == (Wic.Rotate270 | Wic.FlipVertical);
                if (turn >= 0 && (sideways ? decoder.PixelHeight : decoder.PixelWidth) != decoder.OrientedPixelWidth) turn = -1;
            }
        }

        /// The EXIF orientation (1 to 8): 1 when the file has none, 0 when
        /// it can't be read.
        int Orientation()
        {
            try
            {
                var props = Await(decoder.BitmapProperties.GetPropertiesAsync(new[] { "System.Photo.Orientation" }));
                BitmapTypedValue v;
                if (!props.TryGetValue("System.Photo.Orientation", out v)) return 1;
                return Convert.ToInt32(v.Value);
            }
            catch (Exception e)
            {
                Trace("orientation: " + e.Message);
                return 0;
            }
        }

        /// The image turned upright per its EXIF orientation and shrunk to
        /// fit maxDim, as 32-bit colour. With screensFullSize, an image shaped
        /// like a phone screen (2:1 or taller, e.g. a long scrolling
        /// screenshot) is never shrunk: its text would become too small to
        /// read. The picture owns the result: don't dispose it.
        public SoftwareBitmap Decode(uint maxDim, BitmapAlphaMode alpha, bool screensFullSize = false)
        {
            BitmapTransform t = new BitmapTransform();
            uint longest = Math.Max(decoder.PixelWidth, decoder.PixelHeight);
            uint shortest = Math.Max(1u, Math.Min(decoder.PixelWidth, decoder.PixelHeight));
            if (screensFullSize && longest >= 1.9 * shortest) maxDim = Math.Max(maxDim, OcrEngine.MaxImageDimension);
            bool shrink = longest > maxDim;
            if (shrink)
            {
                double scale = (double)maxDim / longest;
                t.ScaledWidth = Math.Max(1u, (uint)(decoder.PixelWidth * scale));
                t.ScaledHeight = Math.Max(1u, (uint)(decoder.PixelHeight * scale));
                t.InterpolationMode = BitmapInterpolationMode.Fant;
            }
            if (turn >= 0)
            {
                if (raw == null)
                {
                    raw = Keep(Await(decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
                        new BitmapTransform(), ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage)));
                }
                if (!shrink && turn == 0) return raw;
                return Keep(Wic.ShrinkAndTurn(raw, shrink ? t.ScaledWidth : 0, shrink ? t.ScaledHeight : 0, turn, alpha));
            }
            return Keep(Await(decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, alpha, t,
                ExifOrientationMode.RespectExifOrientation, ColorManagementMode.DoNotColorManage)));
        }

        SoftwareBitmap Keep(SoftwareBitmap b)
        {
            made.Add(b);
            return b;
        }

        public void Dispose()
        {
            foreach (SoftwareBitmap b in made) b.Dispose();
            stream.Dispose();
        }
    }

    /// Windows Imaging Component, used directly to shrink and turn a decoded
    /// bitmap with the same steps the decoder uses. (WinRT can only do that
    /// while decoding a file.)
    static class Wic
    {
        public const int Rotate90 = 1, Rotate180 = 2, Rotate270 = 3, FlipHorizontal = 8, FlipVertical = 16;

        static IWICImagingFactory factory;
        static bool failed;

        public static bool Available
        {
            get
            {
                if (factory == null && !failed)
                {
                    try
                    {
                        factory = (IWICImagingFactory)Activator.CreateInstance(
                            Type.GetTypeFromCLSID(new Guid("cacaf262-9370-4615-a13b-9f5539da4c0a")));
                    }
                    catch (Exception e)
                    {
                        Trace("wic: " + e.Message);
                        failed = true;
                    }
                }
                return factory != null;
            }
        }

        /// WIC's turn for an EXIF orientation, or -1 if unknown.
        public static int TurnFor(int exifOrientation)
        {
            switch (exifOrientation)
            {
                case 1: return 0;
                case 2: return FlipHorizontal;
                case 3: return Rotate180;
                case 4: return FlipVertical;
                case 5: return Rotate90 | FlipVertical;
                case 6: return Rotate90;
                case 7: return Rotate270 | FlipVertical;
                case 8: return Rotate270;
                default: return -1;
            }
        }

        /// Shrinks (unless width is 0) with the Fant filter, then turns.
        public static SoftwareBitmap ShrinkAndTurn(SoftwareBitmap source, uint width, uint height, int turn, BitmapAlphaMode alpha)
        {
            Guid iid = typeof(IWICBitmapSource).GUID;
            System.Collections.Generic.List<object> chain = new System.Collections.Generic.List<object>();
            try
            {
                IWICBitmapSource step = (IWICBitmapSource)((ISoftwareBitmapNative)(object)source).GetData(ref iid);
                chain.Add(step);
                if (width > 0)
                {
                    IWICBitmapScaler scaler = factory.CreateBitmapScaler();
                    chain.Add(scaler);
                    scaler.Initialize(step, width, height, 3 /* WICBitmapInterpolationModeFant */);
                    step = (IWICBitmapSource)scaler;
                }
                if (turn != 0)
                {
                    IWICBitmapFlipRotator rotator = factory.CreateBitmapFlipRotator();
                    chain.Add(rotator);
                    rotator.Initialize(step, turn);
                    step = (IWICBitmapSource)rotator;
                }
                uint w, h;
                step.GetSize(out w, out h);
                uint size = w * h * 4;
                Windows.Storage.Streams.Buffer pixels = new Windows.Storage.Streams.Buffer(size);
                pixels.Length = size;
                step.CopyPixels(IntPtr.Zero, w * 4, size, ((IBufferByteAccess)(object)pixels).Buffer());
                return SoftwareBitmap.CreateCopyFromBuffer(pixels, BitmapPixelFormat.Bgra8, (int)w, (int)h, alpha);
            }
            finally
            {
                foreach (object o in chain) Marshal.ReleaseComObject(o);
            }
        }
    }

    [ComImport, Guid("5009834f-2d6a-41ce-9e1b-17c5aff7a782"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IWICBitmapFlipRotator
    {
        void GetSize(out uint width, out uint height);
        void GetPixelFormat(out Guid format);
        void GetResolution(out double dpiX, out double dpiY);
        void CopyPalette(IntPtr palette);
        void CopyPixels(IntPtr rect, uint stride, uint size, IntPtr buffer);
        void Initialize(IWICBitmapSource source, int options);
    }

    [ComImport, Guid("94BC8415-04EA-4B2E-AF13-4DE95AA898EB"), InterfaceType(ComInterfaceType.InterfaceIsIInspectable)]
    interface ISoftwareBitmapNative
    {
        [return: MarshalAs(UnmanagedType.IUnknown)] object GetData([In] ref Guid riid);
    }

    [ComImport, Guid("00000120-a8f2-4877-ba0a-fd2b6645fb94"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IWICBitmapSource
    {
        void GetSize(out uint width, out uint height);
        void GetPixelFormat(out Guid format);
        void GetResolution(out double dpiX, out double dpiY);
        void CopyPalette(IntPtr palette);
        void CopyPixels(IntPtr rect, uint stride, uint size, IntPtr buffer);
    }

    [ComImport, Guid("00000302-a8f2-4877-ba0a-fd2b6645fb94"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IWICBitmapScaler
    {
        void GetSize(out uint width, out uint height);
        void GetPixelFormat(out Guid format);
        void GetResolution(out double dpiX, out double dpiY);
        void CopyPalette(IntPtr palette);
        void CopyPixels(IntPtr rect, uint stride, uint size, IntPtr buffer);
        void Initialize(IWICBitmapSource source, uint width, uint height, int mode);
    }

    /// The memory behind a WinRT Buffer.
    [ComImport, Guid("905a0fef-bc53-11df-8c49-001e4fc686da"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IBufferByteAccess
    {
        IntPtr Buffer();
    }

    /// Only the methods up to CreateBitmapFlipRotator; the others hold their places.
    [ComImport, Guid("ec5ec8a9-c395-4314-9c77-54d7a935ff70"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IWICImagingFactory
    {
        void CreateDecoderFromFilename();
        void CreateDecoderFromStream();
        void CreateDecoderFromFileHandle();
        void CreateComponentInfo();
        void CreateDecoder();
        void CreateEncoder();
        void CreatePalette();
        void CreateFormatConverter();
        IWICBitmapScaler CreateBitmapScaler();
        void CreateBitmapClipper();
        IWICBitmapFlipRotator CreateBitmapFlipRotator();
    }

    /// Waits for a Windows async operation. (The usual .AsTask() helper needs
    /// the Windows SDK; this keeps the build dependent only on files every
    /// Windows install has.)
    static T Await<T>(IAsyncOperation<T> op)
    {
        using (ManualResetEventSlim done = new ManualResetEventSlim(false))
        {
            // Setting Completed on an already-finished operation fires it at once.
            op.Completed = delegate { done.Set(); };
            done.Wait();
        }
        if (op.Status == AsyncStatus.Error) throw op.ErrorCode;
        if (op.Status == AsyncStatus.Canceled) throw new OperationCanceledException();
        return op.GetResults();
    }

    static readonly bool Debug = Environment.GetEnvironmentVariable("DECLUTTER_VISION_DEBUG") == "1";

    /// Step-by-step messages on stderr, only when DECLUTTER_VISION_DEBUG=1.
    static void Trace(string message)
    {
        if (Debug) Console.Error.WriteLine("[" + DateTime.Now.ToString("HH:mm:ss.fff") + "] " + message);
    }

    static string Bool(bool b)
    {
        return b ? "true" : "false";
    }

    static string Json(string s)
    {
        StringBuilder sb = new StringBuilder("\"");
        foreach (char c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                    else sb.Append(c);
                    break;
            }
        }
        return sb.Append('"').ToString();
    }
}
