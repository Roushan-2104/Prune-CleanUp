// DeclutterVision — reads text (OCR) and counts faces in images using the
// engines built into Windows 10/11. Fully offline; nothing leaves the laptop.
//
// Built with the C# compiler that ships with Windows (.NET Framework 4.x), so
// it runs on any Windows 10/11 PC without installing anything. See build.ps1.
//
// Usage:  DeclutterVision.exe <jobs> <list file>
//   <jobs>       any of "ocr", "faces", "gray", comma-separated (the default)
//   <list file>  UTF-8 text file, one image per line: "path", or
//                "jobs<TAB>path" to choose jobs for that image
// Output (stdout, one JSON object per line):
//   first line:  {"ready":true,"ocr":true,"ocrLanguage":"en-US","faces":true}
//   then, per image, in order:
//     {"path":"...","text":"line 1\nline 2","lines":2,"faces":1,"ok":true}
//     {"path":"...","ok":false,"error":"..."}
// `DeclutterVision.exe info` prints only the first line.
//
// Requests come in a file rather than on stdin because .NET Framework
// programs can't reliably read the stdin pipes some callers (Dart) create.
using System;
using System.IO;
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

        OcrEngine ocr = OcrEngine.TryCreateFromUserProfileLanguages();
        if (ocr == null) ocr = OcrEngine.TryCreateFromLanguage(new Language("en-US"));
        FaceDetector faces = FaceDetector.IsSupported ? Await(FaceDetector.CreateAsync()) : null;

        Console.Out.WriteLine("{\"ready\":true,\"ocr\":" + Bool(ocr != null) +
            ",\"ocrLanguage\":" + Json(ocr != null ? ocr.RecognizerLanguage.LanguageTag : "") +
            ",\"faces\":" + Bool(faces != null) + "}");
        Console.Out.Flush();
        if (args.Length == 1 && args[0] == "info") return 0;
        if (args.Length != 2)
        {
            Console.Error.WriteLine("usage: DeclutterVision.exe <ocr|faces|ocr,faces> <list file>");
            return 64;
        }

        foreach (string raw in File.ReadAllLines(args[1], new UTF8Encoding(false)))
        {
            string line = raw.Trim('﻿', '\r', ' ');
            if (line.Length == 0) continue;
            // A line may say which jobs it wants: "ocr,gray<TAB>path".
            int tab = line.IndexOf('\t');
            string[] jobs = (tab >= 0 ? line.Substring(0, tab) : args[0]).Split(',');
            string path = tab >= 0 ? line.Substring(tab + 1) : line;
            bool doOcr = Array.IndexOf(jobs, "ocr") >= 0, doFaces = Array.IndexOf(jobs, "faces") >= 0,
                doGray = Array.IndexOf(jobs, "gray") >= 0;
            Trace("image: " + path);
            string reply;
            try
            {
                StringBuilder sb = new StringBuilder("{\"path\":").Append(Json(path));
                if (doGray) sb.Append(SmallGray(path));
                if (doOcr) sb.Append(ReadText(ocr, path));
                if (doFaces) sb.Append(CountFaces(faces, path));
                reply = sb.Append(",\"ok\":true}").ToString();
            }
            catch (Exception e)
            {
                Exception inner = e is AggregateException && e.InnerException != null ? e.InnerException : e;
                reply = "{\"path\":" + Json(path) + ",\"ok\":false,\"error\":" + Json(inner.Message) + "}";
            }
            Console.Out.WriteLine(reply);
            Console.Out.Flush();
        }
        return 0;
    }

    /// A small grayscale copy (longest side 256 px) for blur and look-alike
    /// checks. Returns `,"gray":{"w":…,"h":…,"stride":…,"b64":"…"}`.
    static string SmallGray(string path)
    {
        // Decoders can't always output grayscale directly on every PC, so
        // decode as colour (always supported) and convert here.
        using (SoftwareBitmap bmp = Load(path, 256, BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore))
        {
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
    }

    /// Returns the JSON fields `,"text":…,"lines":n`.
    static string ReadText(OcrEngine ocr, string path)
    {
        if (ocr == null) throw new InvalidOperationException("Windows text recognition is not available");
        using (SoftwareBitmap bmp = Load(path, OcrEngine.MaxImageDimension, BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied))
        {
            OcrResult result = Await(ocr.RecognizeAsync(bmp));
            // Keep line breaks: the rules use them (e.g. "Paid to" on one line, name on the next).
            StringBuilder text = new StringBuilder();
            foreach (OcrLine l in result.Lines)
            {
                if (text.Length > 0) text.Append('\n');
                text.Append(l.Text);
            }
            return ",\"text\":" + Json(text.ToString()) + ",\"lines\":" + result.Lines.Count;
        }
    }

    /// Returns the JSON field `,"faces":n`.
    static string CountFaces(FaceDetector detector, string path)
    {
        if (detector == null) throw new InvalidOperationException("Windows face detection is not available");
        // Supported pixel formats differ between PCs, so ask instead of assuming.
        BitmapPixelFormat wanted = BitmapPixelFormat.Gray8;
        foreach (BitmapPixelFormat f in FaceDetector.GetSupportedBitmapPixelFormats())
        {
            wanted = f;
            if (f == BitmapPixelFormat.Gray8) break;
        }
        using (SoftwareBitmap bgra = Load(path, FaceMaxDimension, BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied))
        using (SoftwareBitmap bmp = SoftwareBitmap.Convert(bgra, wanted))
        {
            return ",\"faces\":" + Await(detector.DetectFacesAsync(bmp)).Count;
        }
    }

    /// Decodes an image (JPEG, PNG, HEIC if the codec is installed, …),
    /// turned upright per its EXIF orientation and shrunk to fit maxDim.
    static SoftwareBitmap Load(string path, uint maxDim, BitmapPixelFormat format, BitmapAlphaMode alpha)
    {
        StorageFile file = Await(StorageFile.GetFileFromPathAsync(Path.GetFullPath(path)));
        using (IRandomAccessStream stream = Await(file.OpenAsync(FileAccessMode.Read)))
        {
            BitmapDecoder dec = Await(BitmapDecoder.CreateAsync(stream));
            BitmapTransform t = new BitmapTransform();
            uint longest = Math.Max(dec.PixelWidth, dec.PixelHeight);
            if (longest > maxDim)
            {
                double scale = (double)maxDim / longest;
                t.ScaledWidth = Math.Max(1u, (uint)(dec.PixelWidth * scale));
                t.ScaledHeight = Math.Max(1u, (uint)(dec.PixelHeight * scale));
                t.InterpolationMode = BitmapInterpolationMode.Fant;
            }
            return Await(dec.GetSoftwareBitmapAsync(format, alpha, t,
                ExifOrientationMode.RespectExifOrientation, ColorManagementMode.DoNotColorManage));
        }
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
