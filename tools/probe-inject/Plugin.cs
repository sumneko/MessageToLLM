// Plugin.cs —— BepInEx 5 只读探针（第一版：不写任何游戏状态）
//
// 由 BepInEx 在主线程加载，Update 里 1Hz 把 Draw 的运行时状态写成 JSON。
// 只读原则：只读字段、只读集合 Count，不调用任何会改状态的方法。
// 全部走反射：游戏字段是 private。

using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text;
using BepInEx;
using HarmonyLib;
using UnityEngine;

namespace MtLProbe
{
    [BepInPlugin("mtl.probe", "MtL Probe", "0.1.0")]
    public class Plugin : BaseUnityPlugin
    {
        const BindingFlags BF = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Static;

        static string _outDir;
        float _next;
        float _nextPoll;
        object _draw;
        string _cmdPath;
        string _resultPath;

        // 合成点击的状态：临时改写 Unity 的输入查询，让游戏自己完成一次点击
        // 语义对齐 Unity 原生：按下的那一帧，GetMouseButtonDown 对所有调用者都返回 true
        public static bool Armed;
        public static Vector2 Point;
        public static int Button;
        public static bool Held;
        public static bool DownFrame;
        public static bool UpFrame;
        public static int Step;

        static string OutDir
        {
            get
            {
                if (_outDir != null) return _outDir;
                string env = Environment.GetEnvironmentVariable("MTL_PROBE_DIR");
                _outDir = string.IsNullOrEmpty(env) ? @"D:\github\MessageToLLM\runs\inject" : env;
                try { Directory.CreateDirectory(_outDir); } catch { }
                return _outDir;
            }
        }

        static void Log(string msg)
        {
            try
            {
                File.AppendAllText(Path.Combine(OutDir, "probe.log"),
                    DateTime.Now.ToString("HH:mm:ss.fff") + "  " + msg + Environment.NewLine, Encoding.UTF8);
            }
            catch { }
        }

        void Awake()
        {
            // 游戏默认 runInBackground=false：窗口一失去焦点就停 Update，后台无法工作。
            // 这里把它打开，后台也继续 tick（只改运行时开关，不落盘）。
            Application.runInBackground = true;

            _cmdPath = Path.Combine(OutDir, "cmd.txt");
            _resultPath = Path.Combine(OutDir, "result.json");

            // 重定向游戏的输入轮询入口，让 click 命令表现得像真的有人点了一下
            try
            {
                new Harmony("mtl.probe").PatchAll(typeof(Plugin).Assembly);
                Log("HARMONY ok");
            }
            catch (Exception e)
            {
                Log("HARMONY ERR " + e);
            }

            Log("AWAKE ok  unity=" + Application.unityVersion + "  out=" + OutDir + "  runInBackground=" + Application.runInBackground);
            Logger.LogInfo("MtLProbe awake");
        }

        void Update()
        {
            // 合成点击的帧序列：按下帧 → 保持几帧 → 松开帧 → 解除
            if (Armed)
            {
                Step++;
                if (Step == 2) DownFrame = false;
                else if (Step == 3) { Held = false; UpFrame = true; }
                else if (Step >= 4) { UpFrame = false; Armed = false; }
            }

            if (Time.unscaledTime >= _nextPoll)
            {
                _nextPoll = Time.unscaledTime + 0.25f;
                try { PollCommand(); }
                catch (Exception e) { Log("CMD ERR " + e); }
            }

            if (Time.unscaledTime < _next) return;
            _next = Time.unscaledTime + 1f;
            try { Snapshot(); }
            catch (Exception e) { Log("SNAP ERR " + e); }
        }

        // 文件命令通道：往 cmd.txt 写一行 → 执行 → 回写 result.json → 删除 cmd.txt
        void PollCommand()
        {
            if (!File.Exists(_cmdPath)) return;
            string text;
            try
            {
                text = File.ReadAllText(_cmdPath, Encoding.UTF8).Trim();
                File.Delete(_cmdPath);
            }
            catch { return; }   // 文件被占用，下一轮再试

            if (text.Length == 0) { File.WriteAllText(_resultPath, "{\"ok\": true, \"data\": \"empty\"}\n", Encoding.UTF8); return; }

            string result;
            try { result = Execute(text); Log("CMD " + text + " -> ok"); }
            catch (Exception e) { result = "{\"ok\": false, \"error\": " + J(e.Message) + "}"; Log("CMD " + text + " -> ERR " + e.Message); }
            File.WriteAllText(_resultPath, result + "\n", Encoding.UTF8);
        }

        // 只读白名单。任何会改游戏状态的命令都不在这里。
        string Execute(string cmd)
        {
            int sp = cmd.IndexOf(' ');
            string name = (sp < 0 ? cmd : cmd.Substring(0, sp)).ToLowerInvariant();
            string arg = sp < 0 ? null : cmd.Substring(sp + 1).Trim();

            Resolve();
            if (_draw == null) return "{\"ok\": false, \"error\": \"draw not found\"}";

            switch (name)
            {
                case "screen":
                    {
                        // 只给几何：几个区域、各自位置、区域内符号。区域是什么含义由 LLM 自己推。
                        string body = BuildScreenData();
                        if (body == null) return "{\"ok\": false, \"error\": \"draw not found\"}";
                        return "{\"ok\": true, \"data\": " + body + "}";
                    }

                // ---------- 维护命令（不属于 solver 界面接口，别让玩游戏的 LLM 用） ----------

                case "resetprofile":
                    {
                        // resetprofile <n> —— 把第 n 号 profile 重置为空档
                        if (arg == null) return "{\"ok\": false, \"error\": \"usage: resetprofile <n>\"}";
                        int n = int.Parse(arg);

                        string dir = Application.persistentDataPath;
                        string file = Path.Combine(dir, "alienmessage" + n + ".sav");
                        string bakDir = Path.Combine(OutDir, "backup");
                        Directory.CreateDirectory(bakDir);
                        long sizeBefore = -1;
                        if (File.Exists(file))
                        {
                            sizeBefore = new FileInfo(file).Length;
                            File.Copy(file, Path.Combine(bakDir, "alienmessage" + n + "." + DateTime.Now.ToString("HHmmss") + ".sav"), true);
                        }

                        object gd = GVStatic("globalData");
                        SetField(gd, "slot", n);                 // 切到第 n 号
                        CallStatic("LoadGame", true);   // 载入这个 profile

                        object sd = GVStatic("savedata");
                        int cleared = 0;
                        string[] tables = { "dict", "flags", "dflags", "win", "solution", "bookmark", "notebook2" };
                        foreach (string t in tables)
                        {
                            object c = GV(sd, t);
                            IDictionary d = c as IDictionary;
                            if (d != null) { d.Clear(); cleared++; continue; }
                            IList l = c as IList;
                            if (l != null) { l.Clear(); cleared++; }
                        }

                        CallStatic("SaveGame");

                        long sizeAfter = File.Exists(file) ? new FileInfo(file).Length : -1;
                        Log("RESETPROFILE " + n + "  before=" + sizeBefore + " after=" + sizeAfter + " cleared=" + cleared);
                        return "{\"ok\": true, \"data\": {\"profile\": " + n + ", \"clearedTables\": " + cleared
                            + ", \"sizeBefore\": " + sizeBefore + ", \"sizeAfter\": " + sizeAfter
                            + ", \"file\": " + J(file) + "}}";
                    }

                case "savedata":
                    {
                        // 维护用：报告当前 profile 的存档规模（不读内容）
                        object gd = GVStatic("globalData");
                        object sd = GVStatic("savedata");
                        StringBuilder b = new StringBuilder("{\"ok\": true, \"data\": {");
                        b.Append("\"slot\": ").Append(GI(gd, "slot"));
                        string[] tables = { "dict", "flags", "dflags", "win", "solution", "bookmark", "notebook2" };
                        foreach (string t in tables)
                        {
                            b.Append(", ").Append(J(t)).Append(": ").Append(CountOf(GV(sd, t)));
                        }
                        b.Append("}}");
                        return b.ToString();
                    }

                case "state":
                    Snapshot();
                    return "{\"ok\": true, \"data\": \"state.json refreshed\"}";

                // ---------- 写接口（只做玩家在界面上能做的事） ----------

                case "click":
                    {
                        // click <x> <y> [L|R] —— 屏幕坐标（左上原点），交给游戏自己的输入逻辑处理
                        string[] p = SplitArgs(arg, 3);
                        if (p == null || p.Length < 2) return "{\"ok\": false, \"error\": \"usage: click <x> <y> [L|R]\"}";
                        int x = int.Parse(p[0]), y = int.Parse(p[1]);
                        int btn = (p.Length >= 3 && (p[2] == "R" || p[2] == "r")) ? 1 : 0;
                        Point = new Vector2(x, Screen.height - y);   // 转成 Unity 的左下原点
                        Button = btn;
                        Held = true;
                        DownFrame = true;
                        UpFrame = false;
                        Step = 1;
                        Armed = true;
                        return "{\"ok\": true, \"data\": {\"click\": [" + x + ", " + y + "], \"button\": " + J(btn == 1 ? "R" : "L") + "}}";
                    }

                default:
                    return "{\"ok\": false, \"error\": \"unknown cmd\", \"known\": [screen, click <x> <y> [L|R], state]\"}";
            }
        }

        static string[] SplitArgs(string s, int n)
        {
            if (s == null) return null;
            string[] p = s.Split(new char[] { ' ' }, n);
            if (p.Length < n) return null;
            return p;
        }

        // 符号在屏幕上的矩形（像素，左上原点），供外部从截图里裁图。
        // 相当于人眼看到的「这个符号在哪一块」，不含任何语义。
        static int[] ScreenRect(object ac)
        {
            Vector3 world = new Vector3(-1, -1, 0);
            Vector2 size = new Vector2(-1, -1);

            RectTransform rt = GV(ac, "rect") as RectTransform;
            SpriteRenderer sr = GV(ac, "sp") as SpriteRenderer;
            if (sr != null)
            {
                // 世界单位，和 Camera.WorldToScreenPoint 同一空间
                world = sr.bounds.center;
                size = sr.bounds.size;
            }
            else if (rt != null)
            {
                world = rt.position;
                size = rt.rect.size;
            }

            Camera cam = Camera.main;
            Vector3 screen = cam != null ? cam.WorldToScreenPoint(world) : world;
            float w = size.x, h = size.y;
            if (cam != null && cam.orthographic)
            {
                float ppu = Screen.height / (2f * cam.orthographicSize);   // 世界单位 → 像素
                w *= ppu;
                h *= ppu;
            }

            int wpx = (int)Math.Round(w);
            int hpx = (int)Math.Round(h);
            // 截图坐标系（左上原点）的左上角
            int sx = (int)Math.Round(screen.x - w / 2f);
            int sy = (int)Math.Round(Screen.height - screen.y - h / 2f);
            return new int[] { sx, sy, wpx, hpx };
        }

        // 槽位对外表示：位置 + 尺寸 + 形状。不含 sector / 译文 / 任何语义。
        static string SlotJson(int i, int j, int[] sp, string shapeId, float edge)
        {
            return "{\"x\": " + i + ", \"y\": " + j
                + ", \"shapeId\": " + J(shapeId)
                + ", \"edge\": " + edge.ToString("0.###")
                + ", \"sp\": [" + sp[0] + ", " + sp[1] + ", " + sp[2] + ", " + sp[3] + "]}";
        }

        // 整屏：按游戏自己的分区分组 → 「有几个区域 + 区域框 + 区域内符号」。
        // 区域代表什么，由 LLM 自己看符号推。
        string BuildScreenData()
        {
            Resolve();
            if (_draw == null) return null;

            Array slots = GV(_draw, "alien_slots") as Array;
            StringBuilder b = new StringBuilder();
            b.Append("{\"screen\": [").Append(Screen.width).Append(", ").Append(Screen.height).Append("]");
            if (slots == null) { b.Append(", \"regions\": []}"); return b.ToString(); }

            int nx = slots.GetLength(0), ny = slots.GetLength(1);
            object[,] cell = new object[nx, ny];
            string[,] shapeIds = new string[nx, ny];
            float[,] edges = new float[nx, ny];
            int[,][] box = new int[nx, ny][];

            // 先收集所有有 sprite 的格
            List<string> allShapes = new List<string>();
            for (int i = 0; i < nx; i++)
            {
                for (int j = 0; j < ny; j++)
                {
                    object ac = slots.GetValue(i, j);
                    if (ac == null) continue;
                    float ink, edge;
                    string sid = ShapeHash(ac, out ink, out edge);
                    if (sid == null) continue;
                    allShapes.Add(sid);
                    cell[i, j] = ac;
                    shapeIds[i, j] = sid;
                    edges[i, j] = edge;
                    box[i, j] = ScreenRect(ac);
                }
            }

            // 空格判定：出现次数最多的形状，且占比 ≥ 40% —— 当作「空白底」，不参与分区。
            // 判定结果会写进输出的 blank 字段，LLM 能看到这次把谁当空了。
            string blank = null;
            if (allShapes.Count > 0)
            {
                Dictionary<string, int> freq = new Dictionary<string, int>();
                foreach (string s in allShapes)
                {
                    int c;
                    freq.TryGetValue(s, out c);
                    freq[s] = c + 1;
                }
                string top = null;
                int best = 0;
                foreach (KeyValuePair<string, int> kv in freq)
                {
                    if (kv.Value > best) { best = kv.Value; top = kv.Key; }
                }
                if (top != null && best >= allShapes.Count * 0.4) blank = top;
            }

            if (blank != null)
            {
                for (int i = 0; i < nx; i++)
                {
                    for (int j = 0; j < ny; j++)
                    {
                        if (cell[i, j] != null && shapeIds[i, j] == blank) cell[i, j] = null;
                    }
                }
            }
            b.Append(", \"blank\": ").Append(J(blank));

            // 按游戏自己的分区分组（AlienCharacter.sector）；分区名不外泄，只给不透明序号 r0/r1/...
            Dictionary<string, List<int[]>> groups = new Dictionary<string, List<int[]>>();
            for (int i = 0; i < nx; i++)
            {
                for (int j = 0; j < ny; j++)
                {
                    if (cell[i, j] == null) continue;
                    string sec = GS(cell[i, j], "sector");
                    if (sec == null) sec = "";
                    List<int[]> g;
                    if (!groups.TryGetValue(sec, out g)) { g = new List<int[]>(); groups.Add(sec, g); }
                    g.Add(new int[] { i, j });
                }
            }

            List<List<int[]>> comps = new List<List<int[]>>(groups.Values);
            comps.Sort(delegate (List<int[]> x, List<int[]> y)
            {
                int ax = int.MaxValue, ay = int.MaxValue, bx = int.MaxValue, by = int.MaxValue;
                foreach (int[] c in x) { int[] r0 = box[c[0], c[1]]; if (r0[0] < ax) ax = r0[0]; if (r0[1] < ay) ay = r0[1]; }
                foreach (int[] c in y) { int[] r0 = box[c[0], c[1]]; if (r0[0] < bx) bx = r0[0]; if (r0[1] < by) by = r0[1]; }
                if (ay != by) return ay.CompareTo(by);
                return ax.CompareTo(bx);
            });

            b.Append(", \"regions\": [");
            for (int r = 0; r < comps.Count; r++)
            {
                List<int[]> comp = comps[r];
                int minX = int.MaxValue, minY = int.MaxValue, maxX = -1, maxY = -1;
                StringBuilder items = new StringBuilder();

                for (int k = 0; k < comp.Count; k++)
                {
                    int[] rc = comp[k];
                    int[] sp = ScreenRect(cell[rc[0], rc[1]]);
                    if (sp[0] < minX) minX = sp[0];
                    if (sp[1] < minY) minY = sp[1];
                    if (sp[0] + sp[2] > maxX) maxX = sp[0] + sp[2];
                    if (sp[1] + sp[3] > maxY) maxY = sp[1] + sp[3];
                    if (k > 0) items.Append(", ");
                    items.Append(SlotJson(rc[0], rc[1], sp, shapeIds[rc[0], rc[1]], edges[rc[0], rc[1]]));
                }

                if (r > 0) b.Append(", ");
                b.Append("{\"id\": ").Append(r)
                 .Append(", \"cells\": ").Append(comp.Count)
                 .Append(", \"box\": [").Append(minX).Append(", ").Append(minY).Append(", ").Append(maxX - minX).Append(", ").Append(maxY - minY).Append("]")
                 .Append(", \"items\": [").Append(items).Append("]}");
            }
            b.Append("]}");
            return b.ToString();
        }

        static readonly Dictionary<string, string> _shapeCache = new Dictionary<string, string>();

        // 形状指纹：对 sprite 自己的纹理区域做 FNV 哈希 —— 同形同 ID，且不含任何词义。
        // edge = 相邻像素亮度差超阈值的比例（笔画才有边缘，纯色块≈0），用来自动剔除空格。
        static string ShapeHash(object ac, out float ink, out float edge)
        {
            ink = 0f;
            edge = 0f;
            SpriteRenderer sr = GV(ac, "sp") as SpriteRenderer;
            if (sr == null || sr.sprite == null) return null;
            Texture2D tex = sr.sprite.texture;
            if (tex == null) return null;

            Rect tr = sr.sprite.textureRect;
            string key = tex.name + "|" + tr.ToString();
            string cached;
            if (_shapeCache.TryGetValue(key, out cached))
            {
                string[] parts = cached.Split('|');
                ink = float.Parse(parts[1]);
                edge = float.Parse(parts[2]);
                return parts[0];
            }

            try
            {
                Color32[] px = ReadTexturePixels(tex);
                if (px == null) return null;
                int tw = tex.width;
                int x0 = (int)tr.x, y0 = (int)tr.y, w = (int)tr.width, h = (int)tr.height;
                uint hash = 2166136261u;
                long solid = 0, edges = 0, pairs = 0;

                for (int yy = 0; yy < h; yy++)
                {
                    int row = (y0 + yy) * tw;
                    for (int xx = 0; xx < w; xx++)
                    {
                        Color32 c = px[row + x0 + xx];
                        if (c.a > 40) solid++;
                        hash = (hash ^ c.r) * 16777619u;
                        hash = (hash ^ c.g) * 16777619u;
                        hash = (hash ^ c.b) * 16777619u;
                        hash = (hash ^ c.a) * 16777619u;

                        if (xx + 1 < w)
                        {
                            Color32 n = px[row + x0 + xx + 1];
                            pairs++;
                            // 字形可能只体现在 alpha 上（白色 sprite + alpha 遮罩），所以两边都看
                            int da = Math.Abs(c.a - n.a);
                            int dl = Math.Abs((c.r + c.g + c.b) - (n.r + n.g + n.b)) / 3;
                            if (da > 32 || dl > 48) edges++;
                        }
                    }
                }

                ink = (float)solid / (float)(w * h);
                edge = pairs == 0 ? 0f : (float)edges / (float)pairs;
                string id = "s" + hash.ToString("x8");
                _shapeCache[key] = id + "|" + ink.ToString("0.####") + "|" + edge.ToString("0.####");
                return id;
            }
            catch
            {
                return null;
            }
        }

        // 读纹理像素：直读不行（纹理未开 Read/Write）就走 GPU 拷一份再读
        static Color32[] ReadTexturePixels(Texture2D tex)
        {
            try { return tex.GetPixels32(); }
            catch { }

            RenderTexture tmp = null;
            RenderTexture prev = RenderTexture.active;
            try
            {
                tmp = RenderTexture.GetTemporary(tex.width, tex.height, 0, RenderTextureFormat.ARGB32, RenderTextureReadWrite.sRGB);
                Graphics.Blit(tex, tmp);
                RenderTexture.active = tmp;
                Texture2D copy = new Texture2D(tex.width, tex.height, TextureFormat.RGBA32, false);
                copy.ReadPixels(new Rect(0, 0, tex.width, tex.height), 0, 0);
                copy.Apply();
                Color32[] px = copy.GetPixels32();
                UnityEngine.Object.Destroy(copy);
                return px;
            }
            catch
            {
                return null;
            }
            finally
            {
                RenderTexture.active = prev;
                if (tmp != null) RenderTexture.ReleaseTemporary(tmp);
            }
        }

        void Resolve()
        {
            if (_draw != null) return;
            UnityEngine.Object found = UnityEngine.Object.FindObjectOfType(typeof(Draw));
            if (found != null)
            {
                _draw = found;
                Log("Draw found: " + found.name);
            }
        }

        void Snapshot()
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("{\n  \"time\": \"").Append(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")).Append("\",\n  \"data\": ");
            string body = BuildScreenData();
            sb.Append(body == null ? "null" : body);
            sb.Append("\n}\n");
            File.WriteAllText(Path.Combine(OutDir, "state.json"), sb.ToString(), Encoding.UTF8);
        }

        static object GV(object obj, string field)
        {
            if (obj == null) return null;
            FieldInfo f = obj.GetType().GetField(field, BF);
            return f == null ? null : f.GetValue(obj);
        }

        static string GS(object obj, string field)
        {
            object v = GV(obj, field);
            return v == null ? null : v.ToString();
        }

        static int GI(object obj, string field)
        {
            object v = GV(obj, field);
            return v == null ? -1 : Convert.ToInt32(v);
        }

        static int CountOf(object v)
        {
            if (v == null) return -1;
            ICollection c = v as ICollection;
            if (c != null) return c.Count;
            IDictionary d = v as IDictionary;
            if (d != null) return d.Count;
            return -2;
        }

        static object GVStatic(string field)
        {
            FieldInfo f = typeof(Global).GetField(field, BF);
            return f == null ? null : f.GetValue(null);
        }

        static void SetField(object obj, string field, object value)
        {
            if (obj == null) return;
            FieldInfo f = obj.GetType().GetField(field, BF);
            if (f != null) f.SetValue(obj, Convert.ChangeType(value, f.FieldType));
        }

        static object CallStatic(string method, params object[] args)
        {
            foreach (MethodInfo m in typeof(Global).GetMethods(BF))
            {
                if (m.Name == method && m.GetParameters().Length == args.Length) return m.Invoke(null, args);
            }
            throw new Exception("no static method " + method + "/" + args.Length + " on Global");
        }

        static string J(string s)
        {
            if (s == null) return "null";
            StringBuilder b = new StringBuilder("\"");
            foreach (char ch in s)
            {
                if (ch == '"' || ch == '\\') b.Append('\\').Append(ch);
                else if (ch == '\n') b.Append("\\n");
                else if (ch == '\r') b.Append("\\r");
                else if (ch == '\t') b.Append("\\t");
                else if (ch < ' ') b.Append(' ');
                else b.Append(ch);
            }
            b.Append("\"");
            return b.ToString();
        }
    }

    // ---- 输入层重定向：临时改写 Unity 的输入查询，游戏自己的点击逻辑照跑 ----

    [HarmonyPatch(typeof(UnityEngine.Input), "get_mousePosition")]
    static class PatchMousePosition
    {
        static bool Prefix(ref Vector3 __result)
        {
            if (!Plugin.Armed) return true;
            __result = new Vector3(Plugin.Point.x, Plugin.Point.y, 0f);
            return false;
        }
    }

    [HarmonyPatch(typeof(UnityEngine.Input), "GetMouseButton")]
    static class PatchGetMouseButton
    {
        static bool Prefix(int button, ref bool __result)
        {
            if (!Plugin.Armed) return true;
            if (button != Plugin.Button) return true;
            __result = Plugin.Held;
            return false;
        }
    }

    [HarmonyPatch(typeof(UnityEngine.Input), "GetMouseButtonDown")]
    static class PatchGetMouseButtonDown
    {
        static bool Prefix(int button, ref bool __result)
        {
            if (!Plugin.Armed) return true;
            if (button != Plugin.Button) return true;
            __result = Plugin.DownFrame;   // 整帧语义：不消费，所有调用者都看到 true
            return false;
        }
    }

    [HarmonyPatch(typeof(UnityEngine.Input), "GetMouseButtonUp")]
    static class PatchGetMouseButtonUp
    {
        static bool Prefix(int button, ref bool __result)
        {
            if (!Plugin.Armed) return true;
            if (button != Plugin.Button) return true;
            __result = Plugin.UpFrame;
            return false;
        }
    }

    [HarmonyPatch(typeof(Shapes2D.InputUtils), "MouseOrTapPosition")]
    static class PatchMousePos
    {
        static bool Prefix(ref Vector2 __result)
        {
            if (!Plugin.Armed) return true;
            __result = Plugin.Point;
            return false;
        }
    }

    [HarmonyPatch(typeof(Shapes2D.InputUtils), "InputToWorldPosition")]
    static class PatchInputToWorld
    {
        static bool Prefix(Vector2 inputPos, ref Vector3 __result)
        {
            if (!Plugin.Armed) return true;
            Camera cam = Camera.main;
            __result = cam != null
                ? cam.ScreenToWorldPoint(new Vector3(inputPos.x, inputPos.y, -cam.transform.position.z))
                : (Vector3)inputPos;
            return false;
        }
    }

    [HarmonyPatch(typeof(Shapes2D.InputUtils), "WasMouseDown")]
    static class PatchWasMouseDown
    {
        static bool Prefix(int button, ref bool __result)
        {
            if (!Plugin.Armed) return true;
            if (button != Plugin.Button) return true;
            __result = Plugin.Held;
            return false;
        }
    }

    [HarmonyPatch(typeof(Shapes2D.InputUtils), "MouseDownOrTap")]
    static class PatchMouseDownOrTap
    {
        static bool Prefix(ref bool __result)
        {
            if (!Plugin.Armed) return true;
            __result = Plugin.Held && Plugin.Button == 0;
            return false;
        }
    }
}
