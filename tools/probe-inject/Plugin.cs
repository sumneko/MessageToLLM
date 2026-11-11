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
                case "pages":
                    {
                        StringBuilder b = new StringBuilder();
                        b.Append("{\"ok\": true, \"data\": {");
                        b.Append("\"page\": ").Append(J(GS(_draw, "current_page")));
                        b.Append(", \"prevPage\": ").Append(J(GS(_draw, "prev_page")));
                        b.Append(", \"leftPage\": ").Append(ListToJson(GV(_draw, "currentleftpage")));
                        b.Append(", \"rightPageIndex\": ").Append(GI(_draw, "currentrightpage"));
                        b.Append(", \"isRiddle\": ").Append(CallBool(_draw, "CurrentPageIsRiddle") ? "true" : "false");
                        b.Append(", \"isMenu\": ").Append(CallBool(_draw, "CurrentPageIsMenu") ? "true" : "false");
                        b.Append(", \"isMessage\": ").Append(CallBool(_draw, "CurrentPageIsMessage") ? "true" : "false");
                        b.Append(", \"isBook\": ").Append(CallBool(_draw, "CurrentPageIsBook") ? "true" : "false");
                        b.Append(", \"isQuiz\": ").Append(GB(_draw, "isQuiz") ? "true" : "false");
                        b.Append("}}");
                        return b.ToString();
                    }

                case "slots":
                    {
                        // 全量导出：只有「在哪、多大、什么形状」，不含任何译文
                        StringBuilder b = new StringBuilder();
                        Array slots = GV(_draw, "alien_slots") as Array;
                        b.Append("{\"ok\": true, \"data\": {\"dim\": ");
                        if (slots == null) { b.Append("null, \"items\": []}}"); return b.ToString(); }
                        b.Append("[").Append(slots.GetLength(0)).Append(", ").Append(slots.GetLength(1)).Append("], \"items\": [");
                        bool first = true;
                        for (int i = 0; i < slots.GetLength(0); i++)
                        {
                            for (int j = 0; j < slots.GetLength(1); j++)
                            {
                                object ac = slots.GetValue(i, j);
                                if (ac == null) continue;
                                if (!first) b.Append(", ");
                                first = false;
                                b.Append(SlotJson(ac, i, j));
                            }
                        }
                        b.Append("]}}");
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
                    return "{\"ok\": false, \"error\": \"unknown cmd\", \"known\": [pages, slots, state, click <x> <y> [L|R]]\"}";
            }
        }

        static string[] SplitArgs(string s, int n)
        {
            if (s == null) return null;
            string[] p = s.Split(new char[] { ' ' }, n);
            if (p.Length < n) return null;
            return p;
        }

        static string ListToJson(object v)
        {
            IEnumerable e = v as IEnumerable;
            if (e == null || v is string) return J(v == null ? null : v.ToString());
            StringBuilder b = new StringBuilder("[");
            bool first = true;
            foreach (object o in e)
            {
                if (!first) b.Append(", ");
                first = false;
                b.Append(J(o == null ? null : o.ToString()));
            }
            b.Append("]");
            return b.ToString();
        }

        static bool CallBool(object obj, string method)
        {
            MethodInfo m = obj.GetType().GetMethod(method, BF);
            if (m == null) return false;
            object r = m.Invoke(obj, null);
            return r != null && Convert.ToBoolean(r);
        }

        // 符号在屏幕上的矩形（像素，左上原点），供外部从截图里裁图。
        // 相当于人眼看到的「这个符号在哪一块」，不含任何语义。
        static string ScreenRectJson(object ac)
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
            // 对外给左上角（截图坐标系，左上原点），方便直接裁图
            int sx = (int)Math.Round(screen.x - w / 2f);
            int sy = (int)Math.Round(Screen.height - screen.y - h / 2f);
            return "{\"sx\": " + sx + ", \"sy\": " + sy + ", \"w\": " + wpx + ", \"h\": " + hpx + "}";
        }

        // 槽位对外表示：位置 + 尺寸 + 形状哈希。不含 alien_txt / line_str 这类译文。
        string SlotJson(object ac, int i, int j)
        {
            StringBuilder b = new StringBuilder();
            b.Append("{\"x\": ").Append(i).Append(", \"y\": ").Append(j);
            b.Append(", \"slot\": ").Append(GI(ac, "slot_index"));
            b.Append(", \"sector\": ").Append(J(GS(ac, "sector")));
            b.Append(", \"showtxt\": ").Append(GB(ac, "showtxt") ? "true" : "false");
            b.Append(", \"shapeId\": ").Append(J(ShapeHash(ac)));
            b.Append(", \"sp\": ").Append(ScreenRectJson(ac));
            b.Append("}");
            return b.ToString();
        }

        static readonly Dictionary<string, string> _shapeCache = new Dictionary<string, string>();

        // 形状指纹：对 sprite 自己的纹理区域做 FNV 哈希 —— 同形同 ID，且不含任何词义。
        // 纹理不可读（未开 Read/Write）时返回 null，由外部按 sp 矩形从截图裁图。
        static string ShapeHash(object ac)
        {
            SpriteRenderer sr = GV(ac, "sp") as SpriteRenderer;
            if (sr == null || sr.sprite == null) return null;
            Texture2D tex = sr.sprite.texture;
            if (tex == null) return null;

            Rect tr = sr.sprite.textureRect;
            string key = tex.name + "|" + tr.ToString();
            string cached;
            if (_shapeCache.TryGetValue(key, out cached)) return cached;

            try
            {
                Color32[] px = ReadTexturePixels(tex);
                if (px == null) return null;
                int tw = tex.width;
                int x0 = (int)tr.x, y0 = (int)tr.y, w = (int)tr.width, h = (int)tr.height;
                uint hash = 2166136261u;
                for (int yy = 0; yy < h; yy++)
                {
                    int row = (y0 + yy) * tw;
                    for (int xx = 0; xx < w; xx++)
                    {
                        Color32 c = px[row + x0 + xx];
                        hash = (hash ^ c.r) * 16777619u;
                        hash = (hash ^ c.g) * 16777619u;
                        hash = (hash ^ c.b) * 16777619u;
                        hash = (hash ^ c.a) * 16777619u;
                    }
                }
                string id = "s" + hash.ToString("x8");
                _shapeCache[key] = id;
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
            Resolve();

            StringBuilder sb = new StringBuilder();
            sb.Append("{\n");
            sb.Append("  \"time\": \"").Append(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")).Append("\",\n");
            sb.Append("  \"unity\": \"").Append(Application.unityVersion).Append("\",\n");
            sb.Append("  \"drawFound\": ").Append(_draw != null ? "true" : "false");

            if (_draw != null)
            {
                sb.Append(",\n  \"page\": ").Append(J(GS(_draw, "current_page")));
                sb.Append(",\n  \"rightPage\": ").Append(GI(_draw, "currentrightpage"));
                sb.Append(",\n  \"category\": ").Append(J(GS(_draw, "current_categoryname")));
                sb.Append(",\n  \"isQuiz\": ").Append(GB(_draw, "isQuiz") ? "true" : "false");
                sb.Append(",\n  \"understandLv\": ").Append(GI(_draw, "understand_lv"));
                sb.Append(",\n  \"understandTest\": ").Append(GI(_draw, "understand_test"));
                sb.Append(",\n  \"selectedCount\": ").Append(CountOf(GV(_draw, "selected")));

                Array slots = GV(_draw, "alien_slots") as Array;
                if (slots == null)
                {
                    sb.Append(",\n  \"slots\": null");
                }
                else
                {
                    sb.Append(",\n  \"slotsDim\": [").Append(slots.GetLength(0)).Append(", ").Append(slots.GetLength(1)).Append("]");
                    sb.Append(",\n  \"slots\": [");
                    StringBuilder items = new StringBuilder();
                    int written = 0;
                    for (int i = 0; i < slots.GetLength(0) && written < 40; i++)
                    {
                        for (int j = 0; j < slots.GetLength(1) && written < 40; j++)
                        {
                            object ac = slots.GetValue(i, j);
                            if (ac == null) continue;
                            if (written > 0) items.Append(", ");
                            items.Append(SlotJson(ac, i, j));
                            written++;
                        }
                    }
                    sb.Append(items);
                    sb.Append("]");
                }
            }

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

        static bool GB(object obj, string field)
        {
            object v = GV(obj, field);
            return v != null && Convert.ToBoolean(v);
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
