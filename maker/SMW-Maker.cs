// SMW Maker: a Windows app that turns your own Super Mario Bros. Wonder 1.0.0 dump into the game data for /data/SMW
// and your own SMW package, with the tools in its tools/ folder (no WSL, nothing to install), and can upload both to
// your PS4 over FTP. It runs maker/smw_maker.py with its own Python and shows its steps, progress and log.
// Built with the C# compiler that comes with Windows (maker/build-exe.cmd); C# 5, .NET Framework 4.
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("SMW Maker")]
[assembly: System.Reflection.AssemblyProduct("SMW Maker")]

// The background work: the pipeline's output line by line, and the FTP upload. The window reads the queue every 100 ms.
class Worker {
    public ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();
    public volatile bool Running;
    public volatile int ExitCode;
    Process proc;
    volatile bool cancelled;

    public void Start(string file, string args, Dictionary<string, string> env) {
        var psi = new ProcessStartInfo(file, args);
        psi.UseShellExecute = false;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.CreateNoWindow = true;
        psi.EnvironmentVariables.Remove("PYTHONHOME");
        psi.EnvironmentVariables.Remove("PYTHONPATH");
        foreach (var kv in env) psi.EnvironmentVariables[kv.Key] = kv.Value;
        proc = new Process();
        proc.StartInfo = psi;
        proc.EnableRaisingEvents = true;
        proc.OutputDataReceived += (s, e) => { if (e.Data != null) Lines.Enqueue(e.Data); };
        proc.ErrorDataReceived += (s, e) => { if (e.Data != null) Lines.Enqueue(e.Data); };
        proc.Exited += (s, e) => { proc.WaitForExit(); ExitCode = proc.ExitCode; Running = false; };
        Running = true;
        cancelled = false;
        proc.Start();
        proc.BeginOutputReadLine();
        proc.BeginErrorReadLine();
    }

    // The pipeline and everything it started (the compiler, the importer...).
    public void Cancel() {
        cancelled = true;
        try {
            if (proc != null && !proc.HasExited) {
                var k = Process.Start(new ProcessStartInfo("taskkill", "/T /F /PID " + proc.Id) { CreateNoWindow = true, UseShellExecute = false });
                k.WaitForExit(5000);
            }
        } catch {}
    }

    // Every file under `folder` (or the one file `folder` names) to ftp://host:port/dest; a file already there with the
    // same size is skipped, so starting again resumes. Lines: "progress <done> <total>", then "upload done" or an error.
    public void Upload(string folder, string host, int port, string dest) {
        Running = true;
        cancelled = false;
        ExitCode = 0;
        var t = new Thread(() => {
            try {
                string[] files;
                if (File.Exists(folder)) {
                    files = new string[] { folder };
                    folder = Path.GetDirectoryName(folder);
                } else {
                    files = Directory.GetFiles(folder, "*", SearchOption.AllDirectories);
                }
                string root = "ftp://" + host + ":" + port + dest.TrimEnd('/');
                var made = new HashSet<string>();
                MakeDir(root, made);
                int n = 0;
                foreach (string f in files) {
                    if (cancelled) { ExitCode = 2; Lines.Enqueue("upload cancelled"); break; }
                    string rel = f.Substring(folder.TrimEnd('\\').Length + 1).Replace('\\', '/');
                    string dir = rel.Contains("/") ? rel.Substring(0, rel.LastIndexOf('/')) : "";
                    string at = root;
                    foreach (string part in dir.Split(new char[] { '/' }, StringSplitOptions.RemoveEmptyEntries)) {
                        at += "/" + part;
                        MakeDir(at, made);
                    }
                    string uri = root + "/" + rel;
                    long size = new FileInfo(f).Length;
                    if (RemoteSize(uri) != size) {
                        var req = Request(uri, WebRequestMethods.Ftp.UploadFile);
                        using (Stream o = req.GetRequestStream())
                        using (FileStream i = File.OpenRead(f)) i.CopyTo(o);
                        req.GetResponse().Close();
                    }
                    n++;
                    if (n % 50 == 0 || n == files.Length) Lines.Enqueue("progress " + n + " " + files.Length);
                }
                if (!cancelled) Lines.Enqueue("upload done");
            } catch (Exception e) {
                ExitCode = 1;
                Lines.Enqueue("upload failed: " + e.Message);
            }
            Running = false;
        });
        t.IsBackground = true;
        t.Start();
    }

    static FtpWebRequest Request(string uri, string method) {
        var r = (FtpWebRequest)WebRequest.Create(uri);
        r.Method = method;
        r.UseBinary = true;
        r.UsePassive = true;
        r.KeepAlive = true;
        r.Timeout = 30000;
        return r;
    }

    static void MakeDir(string uri, HashSet<string> made) {
        if (made.Contains(uri)) return;
        made.Add(uri);
        try { Request(uri, WebRequestMethods.Ftp.MakeDirectory).GetResponse().Close(); } catch (WebException) {}
    }

    static long RemoteSize(string uri) {
        try {
            using (var r = (FtpWebResponse)Request(uri, WebRequestMethods.Ftp.GetFileSize).GetResponse()) return r.ContentLength;
        } catch (WebException) { return -1; }
    }
}

class MakerForm : Form {
    readonly string maker = Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location);
    readonly string version;
    readonly Color grey = Color.FromArgb(120, 120, 130);
    readonly Dictionary<string, TextBox> rows = new Dictionary<string, TextBox>();
    readonly List<Button> browse = new List<Button>();
    TextBox ftp;
    CheckBox doData, doPkg;
    Button start, cancel, uploadOnly;
    Label status;
    ProgressBar bar;
    TextBox log;
    readonly Worker worker = new Worker();
    readonly Queue<string> queue = new Queue<string>();
    readonly List<string> done = new List<string>();
    string job, outDir, jobArgs, makerRun;

    public MakerForm() {
        version = ReadVersion();
        Text = "SMW Maker " + version;
        ClientSize = new Size(760, 742);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 10);
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        BackColor = Color.FromArgb(250, 250, 252);
        try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch {}

        AddLabel("SMW Maker", 20, 12, 400, 34, 16, Color.Empty, FontStyle.Bold);
        AddLabel("Makes the game data for /data/SMW and your own SMW package from your Super Mario Bros. Wonder 1.0.0 dump.\n" +
                 "All files come from your own Switch; nothing is sent anywhere except, if you ask, to your own PS4.",
                 22, 50, 720, 40, 9.5f, Color.FromArgb(80, 80, 90), FontStyle.Regular);
        AddRow("game", "Game dump", 100, "Super Mario Bros. Wonder 1.0.0, .nsp or .xci (base game, no update)");
        AddRow("prod", "prod.keys", 150, "");
        AddRow("title", "title.keys", 190, "Optional: leave it empty if you have none");
        AddRow("out", "Output folder", 240, "The SMW folder (about 5 GB) and your package go here");
        AddRow("work", "Work folder", 290, "SMW Maker's own files, about 40 GB for the package (no spaces in the path)");
        rows["work"].Text = DefaultWork();

        AddLabel("PS4 FTP address", 22, 344, 150, 24, 10, Color.Empty, FontStyle.Regular);
        ftp = new TextBox { Location = new Point(175, 340), Size = new Size(200, 26) };
        Controls.Add(ftp);
        AddLabel("Optional, for example 192.168.0.90:2121 (GoldHEN FTP): the results go to /data/SMW and /data/pkg",
                 175, 367, 560, 18, 8.5f, grey, FontStyle.Regular);
        doData = AddCheck("Make the game data (the SMW folder for /data/SMW)", 392, true);
        doPkg = AddCheck("Build my package (SMW-v" + version + ".pkg, from the same dump)", 416, true);
        AddLabel("An hour or two on most PCs (16 GB of memory recommended). It is your game: never share it",
                 193, 440, 545, 18, 8.5f, grey, FontStyle.Regular);

        start = AddButton("Start", 22, 140, true);
        cancel = AddButton("Cancel", 172, 100, false);
        cancel.Enabled = false;
        uploadOnly = AddButton("Upload only", 282, 120, false);
        start.Click += (s, e) => OnStart();
        cancel.Click += (s, e) => { queue.Clear(); worker.Cancel(); status.Text = "Cancelled."; };
        uploadOnly.Click += (s, e) => OnUploadOnly();

        status = AddLabel("Pick your files, then Start.", 22, 516, 718, 22, 10, Color.Empty, FontStyle.Regular);
        bar = new ProgressBar { Location = new Point(22, 540), Size = new Size(718, 18) };
        Controls.Add(bar);
        log = new TextBox {
            Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Font = new Font("Consolas", 9),
            Location = new Point(22, 566), Size = new Size(718, 160),
            BackColor = Color.FromArgb(24, 26, 34), ForeColor = Color.FromArgb(220, 224, 235)
        };
        Controls.Add(log);

        rows["game"].TextChanged += (s, e) => FillKeys();
        var timer = new System.Windows.Forms.Timer { Interval = 100 };
        timer.Tick += (s, e) => Tick();
        timer.Start();
        FormClosing += (s, e) => worker.Cancel();
    }

    string ReadVersion() {
        try { return File.ReadAllText(Path.Combine(maker, "smw", "VERSION")).Trim(); } catch { return "?"; }
    }

    static string DefaultWork() {
        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string w = Path.Combine(local, "SMW-Maker");
        if (!w.Contains(" ")) return w;
        return Path.Combine(Path.GetPathRoot(Environment.SystemDirectory), "SMW-Maker-work");
    }

    Label AddLabel(string text, int x, int y, int w, int h, float size, Color color, FontStyle style) {
        var l = new Label { Text = text, Location = new Point(x, y), Size = new Size(w, h), Font = new Font("Segoe UI", size, style) };
        if (color != Color.Empty) l.ForeColor = color;
        Controls.Add(l);
        return l;
    }

    void AddRow(string key, string label, int y, string hint) {
        AddLabel(label, 22, y + 4, 150, 24, 10, Color.Empty, FontStyle.Regular);
        var t = new TextBox { Location = new Point(175, y), Size = new Size(455, 26) };
        Controls.Add(t);
        var b = new Button { Text = "Browse...", Location = new Point(640, y - 1), Size = new Size(100, 28) };
        Controls.Add(b);
        browse.Add(b);
        if (hint != "") AddLabel(hint, 175, y + 27, 560, 18, 8.5f, grey, FontStyle.Regular);
        rows[key] = t;
        b.Click += (s, e) => Pick(key);
    }

    CheckBox AddCheck(string text, int y, bool on) {
        var c = new CheckBox { Text = text, Checked = on, Location = new Point(175, y), Size = new Size(560, 24) };
        Controls.Add(c);
        return c;
    }

    Button AddButton(string text, int x, int w, bool main) {
        var b = new Button { Text = text, Location = new Point(x, 468), Size = new Size(w, 36) };
        if (main) {
            b.Font = new Font("Segoe UI", 11, FontStyle.Bold);
            b.BackColor = Color.FromArgb(242, 193, 46);
            b.FlatStyle = FlatStyle.Flat;
        }
        Controls.Add(b);
        return b;
    }

    // ---- File Explorer pickers ----
    void Pick(string key) {
        if (key == "out" || key == "work") {
            using (var d = new FolderBrowserDialog()) {
                d.Description = key == "out" ? "Where the SMW folder and your package go" : "SMW Maker's work folder (~40 GB, no spaces in the path)";
                if (rows[key].Text != "" && Directory.Exists(rows[key].Text)) d.SelectedPath = rows[key].Text;
                if (d.ShowDialog(this) == DialogResult.OK) rows[key].Text = d.SelectedPath;
            }
            return;
        }
        using (var d = new OpenFileDialog()) {
            d.Title = key == "game" ? "Your Super Mario Bros. Wonder dump (1.0.0)" : key + ".keys";
            d.Filter = key == "game" ? "Switch game (*.nsp;*.xci)|*.nsp;*.xci|All files|*.*" : key + ".keys|" + key + ".keys;*.keys|All files|*.*";
            string near = rows[key].Text != "" ? rows[key].Text : rows["game"].Text;
            if (near != "" && File.Exists(near)) d.InitialDirectory = Path.GetDirectoryName(near);
            if (d.ShowDialog(this) == DialogResult.OK) rows[key].Text = d.FileName;
        }
    }

    // Keys next to the dump are filled in by themselves.
    void FillKeys() {
        string g = rows["game"].Text;
        if (g == "" || !File.Exists(g)) return;
        string dir = Path.GetDirectoryName(g);
        foreach (var k in new[] { "prod", "title" }) {
            string f = Path.Combine(dir, k + ".keys");
            if (rows[k].Text == "" && File.Exists(f)) rows[k].Text = f;
        }
    }

    void Log(string s) { log.AppendText(s + "\r\n"); }
    void Tell(string s, MessageBoxIcon icon) { MessageBox.Show(this, s, "SMW Maker", MessageBoxButtons.OK, icon); }

    void SetBusy(bool busy) {
        foreach (var t in rows.Values) t.Enabled = !busy;
        foreach (var b in browse) b.Enabled = !busy;
        ftp.Enabled = doData.Enabled = doPkg.Enabled = start.Enabled = uploadOnly.Enabled = !busy;
        cancel.Enabled = busy;
    }

    static string Q(string s) { return "\"" + s.Replace("\"", "\\\"") + "\""; }

    string PkgPath() { return Path.Combine(outDir, "SMW-v" + version + ".pkg"); }

    // The tools' paths go into the PS4 build's flags, which can't take spaces: from a folder with spaces in its path,
    // SMW Maker runs through a junction to itself in the work folder.
    string MakerForRun(string work) {
        if (!maker.Contains(" ")) return maker;
        string link = Path.Combine(work, "maker");
        if (!Directory.Exists(link)) {
            var p = Process.Start(new ProcessStartInfo("cmd.exe", "/c mklink /J " + Q(link) + " " + Q(maker)) { CreateNoWindow = true, UseShellExecute = false });
            p.WaitForExit();
        }
        return link;
    }

    void OnStart() {
        string game = rows["game"].Text.Trim(), prod = rows["prod"].Text.Trim(), title = rows["title"].Text.Trim();
        string outd = rows["out"].Text.Trim(), work = rows["work"].Text.Trim();
        if (!doData.Checked && !doPkg.Checked) { Tell("Tick the game data, the package, or both.", MessageBoxIcon.Warning); return; }
        if (game == "" || !File.Exists(game)) { Tell("Pick your game dump (.nsp or .xci).", MessageBoxIcon.Warning); return; }
        if (prod == "" || !File.Exists(prod)) { Tell("Pick your prod.keys.", MessageBoxIcon.Warning); return; }
        if (title != "" && !File.Exists(title)) { Tell("title.keys was not found (leave it empty if you have none).", MessageBoxIcon.Warning); return; }
        if (outd == "" || !Directory.Exists(outd)) { Tell("Pick an output folder.", MessageBoxIcon.Warning); return; }
        if (work == "" || work.Contains(" ")) { Tell("Pick a work folder whose path has no spaces (for example C:\\SMW-Maker-work).", MessageBoxIcon.Warning); return; }
        if (!File.Exists(Path.Combine(maker, "tools", "python", "python.exe"))) { Tell("SMW Maker's tools folder is missing: unzip the whole download again.", MessageBoxIcon.Error); return; }
        try { Directory.CreateDirectory(work); } catch (Exception e) { Tell("Cannot create the work folder: " + e.Message, MessageBoxIcon.Warning); return; }
        makerRun = MakerForRun(work);
        outDir = outd;
        jobArgs = " --game " + Q(game) + " --prod " + Q(prod) + " --out " + Q(outd) + " --work " + Q(work);
        if (title != "") jobArgs += " --title " + Q(title);
        queue.Clear(); done.Clear();
        if (doData.Checked) queue.Enqueue("data");
        if (doPkg.Checked) queue.Enqueue("pkg");
        if (ftp.Text.Trim() != "") {
            if (doData.Checked) queue.Enqueue("up-data");
            if (doPkg.Checked) queue.Enqueue("up-pkg");
        }
        log.Clear();
        SetBusy(true);
        RunNext();
    }

    void OnUploadOnly() {
        if (ftp.Text.Trim() == "") { Tell("Type your PS4 FTP address first (for example 192.168.0.90:2121).", MessageBoxIcon.Warning); return; }
        using (var d = new FolderBrowserDialog()) {
            d.Description = "The output folder (with the SMW folder and/or your package in it)";
            if (rows["out"].Text != "" && Directory.Exists(rows["out"].Text)) d.SelectedPath = rows["out"].Text;
            if (d.ShowDialog(this) != DialogResult.OK) return;
            string folder = d.SelectedPath;
            if (Path.GetFileName(folder) == "SMW" && File.Exists(Path.Combine(folder, "analysis", "main.bin"))) folder = Path.GetDirectoryName(folder);
            outDir = folder;
        }
        queue.Clear(); done.Clear();
        if (File.Exists(Path.Combine(outDir, "SMW", "analysis", "main.bin"))) queue.Enqueue("up-data");
        if (File.Exists(PkgPath())) queue.Enqueue("up-pkg");
        if (queue.Count == 0) { Tell("There is no SMW folder or SMW-v" + version + ".pkg in that folder.", MessageBoxIcon.Warning); return; }
        log.Clear();
        SetBusy(true);
        RunNext();
    }

    string[] FtpTarget() {
        var parts = ftp.Text.Trim().Split(new[] { ':' }, 2);
        return new[] { parts[0], parts.Length > 1 && parts[1] != "" ? parts[1] : "2121" };
    }

    void RunNext() {
        if (queue.Count == 0) {
            job = null;
            SetBusy(false);
            bar.Value = 100;
            status.Text = "Done.";
            Tell("Done.\n\n" + string.Join("\n\n", done), MessageBoxIcon.Information);
            return;
        }
        job = queue.Dequeue();
        bar.Value = 0;
        if (job == "data" || job == "pkg") {
            status.Text = job == "data" ? "Making the game data..." : "Building your package...";
            string py = Path.Combine(makerRun, "tools", "python", "python.exe");
            string script = Path.Combine(makerRun, "smw", "maker", "smw_maker.py");
            var env = new Dictionary<string, string> { { "PYTHONUTF8", "1" }, { "PYTHONUNBUFFERED", "1" } };
            worker.Start(py, "-u " + Q(script) + " " + job + jobArgs, env);
        } else {
            var t = FtpTarget();
            string dest = job == "up-data" ? "/data/SMW" : "/data/pkg";
            status.Text = "Uploading to " + t[0] + ":" + t[1] + " " + dest + " ...";
            Log("== upload to " + t[0] + ":" + t[1] + " " + dest + " (files already there are skipped)");
            worker.Upload(job == "up-data" ? Path.Combine(outDir, "SMW") : PkgPath(), t[0], int.Parse(t[1]), dest);
        }
    }

    // What a finished job leaves: a line for the final message ("" for none), or null when it failed.
    string Result(string j) {
        if (worker.ExitCode != 0) return null;
        bool up = ftp.Text.Trim() != "";
        switch (j) {
            case "data":
                string smw = Path.Combine(outDir, "SMW");
                if (!File.Exists(Path.Combine(smw, "analysis", "main.bin"))) return null;
                return up ? "" : "The game data: " + smw + "\nCopy the CONTENTS of that folder to /data/SMW on your PS4.";
            case "pkg":
                if (!File.Exists(PkgPath())) return null;
                return up ? "" : "Your package: " + PkgPath() + "\nPut it in /data/pkg on your PS4 and install it with GoldHEN's Package Installer. Never share it.";
            case "up-data": return "The game data is on your PS4 in /data/SMW.";
            case "up-pkg": return "The package is on your PS4 in /data/pkg: install it with GoldHEN's Package Installer.";
        }
        return null;
    }

    static readonly Dictionary<string, int> dataSteps = new Dictionary<string, int> { { "1", 2 }, { "2", 5 }, { "3", 40 }, { "4", 90 } };
    static readonly Dictionary<string, int> pkgSteps = new Dictionary<string, int> { { "1", 2 }, { "2", 4 }, { "3", 8 }, { "4", 30 }, { "5", 96 } };

    void Tick() {
        string line;
        int n = 0;
        while (n < 400 && worker.Lines.TryDequeue(out line)) {
            n++;
            Match m;
            if ((m = Regex.Match(line, @"^progress (\d+) (\d+)$")).Success) {
                bar.Value = (int)(100L * int.Parse(m.Groups[1].Value) / int.Parse(m.Groups[2].Value));
                status.Text = "Uploading: " + m.Groups[1].Value + " of " + m.Groups[2].Value + " files";
                continue;
            }
            if ((m = Regex.Match(line, @"romfs\s+([\d.]+)%")).Success) {  // the importer's meter: in the status line, not the log
                status.Text = "Decrypting the game: " + m.Groups[1].Value + "%";
                continue;
            }
            if ((m = Regex.Match(line, @"^build (\d+)%$")).Success) {
                status.Text = "Step 4/5: compiling, " + m.Groups[1].Value + "%";
                bar.Value = Math.Min(95, 30 + int.Parse(m.Groups[1].Value) * 65 / 100);
                continue;
            }
            if ((m = Regex.Match(line, @"^== (\d)/([45]) (.*)")).Success) {
                status.Text = "Step " + m.Groups[1].Value + "/" + m.Groups[2].Value + ": " + m.Groups[3].Value.Trim();
                var map = m.Groups[2].Value == "5" ? pkgSteps : dataSteps;
                if (map.ContainsKey(m.Groups[1].Value)) bar.Value = map[m.Groups[1].Value];
            }
            if (line.Trim() != "") Log(line);
        }
        if (worker.Running || job == null) return;
        string finished = job;
        job = null;
        string r = Result(finished);
        if (r == null) {
            queue.Clear();
            SetBusy(false);
            status.Text = finished.StartsWith("up-") ? "The upload stopped: press Upload only to resume it."
                                                     : "Stopped (exit code " + worker.ExitCode + "): see the log.";
            return;
        }
        if (r != "") done.Add(r);
        RunNext();
    }

    [STAThread]
    static void Main() {
        Application.EnableVisualStyles();
        Application.Run(new MakerForm());
    }
}
