# SMW data tool for Windows: a window where you pick your own Super Mario Bros. Wonder 1.0.0 dump and keys with File
# Explorer; it makes the folder for /data/SMW on your PS4 (scripts/make-data.sh, run in WSL) and can upload it over
# FTP. Start it with SMW-Data-Tool.cmd (double-click). Nothing leaves your PC except the optional upload to your PS4.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---- the background work: WSL's output line by line, and the FTP upload ------------------------------------------------
# WinForms may only be touched from its own thread: these run elsewhere and leave their lines in a queue the window
# reads every 100 ms.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Threading;

public class SmwWorker {
    public ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();
    public volatile bool Running;
    public volatile int ExitCode;
    Process proc;
    volatile bool cancelled;

    // A program (wsl.exe) with its output and errors as lines; \r counts as a line end (progress meters).
    public void Start(string file, string args) {
        ProcessStartInfo psi = new ProcessStartInfo(file, args);
        psi.UseShellExecute = false;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.RedirectStandardInput = true;
        psi.CreateNoWindow = true;
        proc = new Process();
        proc.StartInfo = psi;
        proc.EnableRaisingEvents = true;
        proc.OutputDataReceived += (s, e) => { if (e.Data != null) Lines.Enqueue(e.Data); };
        proc.ErrorDataReceived += (s, e) => { if (e.Data != null) Lines.Enqueue(e.Data); };
        proc.Exited += (s, e) => { proc.WaitForExit(); ExitCode = proc.ExitCode; Running = false; };
        Running = true;
        cancelled = false;
        proc.Start();
        proc.StandardInput.Close();
        proc.BeginOutputReadLine();
        proc.BeginErrorReadLine();
    }

    public void Cancel() {
        cancelled = true;
        try { if (proc != null && !proc.HasExited) proc.Kill(); } catch {}
    }

    // Every file under `folder` (or the one file `folder` names) to ftp://host:port/dest, folders made as needed; a
    // file already there with the same size is skipped, so starting again resumes. Lines: "progress <done> <total>",
    // then "upload done" or an error.
    public void Upload(string folder, string host, int port, string dest) {
        Running = true;
        cancelled = false;
        ExitCode = 0;
        Thread t = new Thread(() => {
            try {
                string[] files;
                if (File.Exists(folder)) {
                    files = new string[] { folder };
                    folder = Path.GetDirectoryName(folder);
                } else {
                    files = Directory.GetFiles(folder, "*", SearchOption.AllDirectories);
                }
                string root = "ftp://" + host + ":" + port + dest.TrimEnd('/');
                HashSet<string> made = new HashSet<string>();
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
                        FtpWebRequest req = Request(uri, WebRequestMethods.Ftp.UploadFile);
                        using (Stream outStream = req.GetRequestStream())
                        using (FileStream inStream = File.OpenRead(f)) inStream.CopyTo(outStream);
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
        FtpWebRequest r = (FtpWebRequest)WebRequest.Create(uri);
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
            using (FtpWebResponse r = (FtpWebResponse)Request(uri, WebRequestMethods.Ftp.GetFileSize).GetResponse()) return r.ContentLength;
        } catch (WebException) { return -1; }
    }
}
'@

# ---- WSL ------------------------------------------------------------------------------------------------------------
function Find-Distro {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $null }
    $list = @((& wsl.exe -l -q 2>$null) -replace "`0", '' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $d = $list | Where-Object { $_ -like 'Ubuntu*' } | Select-Object -First 1
    if (-not $d) { $d = $list | Select-Object -First 1 }
    return $d
}
function To-Wsl($distro, $path) {
    $p = (& wsl.exe -d $distro -- wslpath -a ($path -replace '\\', '/')) 2>$null
    if ($p) { return $p.Trim() }
    return $null
}
function Quote($s) { return "'" + ($s -replace "'", "'\''") + "'" }

# ---- the window -----------------------------------------------------------------------------------------------------
$grey = [System.Drawing.Color]::FromArgb(120, 120, 130)
$form = New-Object System.Windows.Forms.Form
$form.Text = 'SMW data tool'
$form.ClientSize = New-Object System.Drawing.Size(760, 696)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 252)

function New-Label($text, $x, $y, $w, $h, $size = 10, $color = $null, $style = 'Regular') {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, $h)
    $l.Font = New-Object System.Drawing.Font('Segoe UI', $size, [System.Drawing.FontStyle]$style)
    if ($color) { $l.ForeColor = $color }
    $form.Controls.Add($l)
    return $l
}
[void](New-Label 'SMW data tool' 20 12 400 34 16 $null 'Bold')
[void](New-Label "Turns your own Super Mario Bros. Wonder 1.0.0 dump into the game data for /data/SMW and your own SMW package.`nAll files come from your own Switch; nothing is sent anywhere except, if you ask, to your own PS4." 22 50 720 40 9.5 ([System.Drawing.Color]::FromArgb(80, 80, 90)))

$rows = @{}
function Add-Row($key, $label, $y, $hint) {
    [void](New-Label $label 22 ($y + 4) 150 24)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point(175, $y)
    $t.Size = New-Object System.Drawing.Size(455, 26)
    $form.Controls.Add($t)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = 'Browse...'
    $b.Location = New-Object System.Drawing.Point(640, ($y - 1))
    $b.Size = New-Object System.Drawing.Size(100, 28)
    $form.Controls.Add($b)
    if ($hint) { [void](New-Label $hint 175 ($y + 27) 560 18 8.5 $grey) }
    $rows[$key] = @{ Text = $t; Button = $b }
}
Add-Row 'game' 'Game dump' 100 'Super Mario Bros. Wonder 1.0.0, .nsp or .xci (base game, no update)'
Add-Row 'prod' 'prod.keys' 150 ''
Add-Row 'title' 'title.keys' 190 'Optional: leave it empty if you have none'
Add-Row 'out' 'Output folder' 240 'The SMW folder (about 5 GB) and your package go here'

[void](New-Label 'PS4 FTP address' 22 294 150 24)
$ftp = New-Object System.Windows.Forms.TextBox
$ftp.Location = New-Object System.Drawing.Point(175, 290)
$ftp.Size = New-Object System.Drawing.Size(200, 26)
$form.Controls.Add($ftp)
[void](New-Label 'Optional, for example 192.168.0.90:2121 (GoldHEN FTP): the results go to /data/SMW and /data/pkg' 175 317 560 18 8.5 $grey)

function New-Check($text, $y, $checked) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $text
    $c.Checked = $checked
    $c.Location = New-Object System.Drawing.Point(175, $y)
    $c.Size = New-Object System.Drawing.Size(560, 24)
    $form.Controls.Add($c)
    return $c
}
$doData = New-Check 'Make the game data (the SMW folder for /data/SMW)' 342 $true
$doPkg = New-Check 'Build my package (SMW-vXX.XX.pkg, from the same dump)' 366 $false
[void](New-Label 'The package takes an hour or two more and ~40 GB free on the WSL drive; it is your game: never share it' 193 390 545 18 8.5 $grey)

function New-Button($text, $x, $w, $bold = $false) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, 418)
    $b.Size = New-Object System.Drawing.Size($w, 36)
    if ($bold) {
        $b.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
        $b.BackColor = [System.Drawing.Color]::FromArgb(242, 193, 46)
        $b.FlatStyle = 'Flat'
    }
    $form.Controls.Add($b)
    return $b
}
$start = New-Button 'Start' 22 140 $true
$cancel = New-Button 'Cancel' 172 100
$cancel.Enabled = $false
$uploadOnly = New-Button 'Upload only' 282 120

$status = New-Label 'Pick your files, then Start. The game data takes 20-40 minutes.' 22 466 718 22
$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Location = New-Object System.Drawing.Point(22, 490)
$bar.Size = New-Object System.Drawing.Size(718, 18)
$form.Controls.Add($bar)
$log = New-Object System.Windows.Forms.TextBox
$log.Multiline = $true
$log.ReadOnly = $true
$log.ScrollBars = 'Vertical'
$log.Font = New-Object System.Drawing.Font('Consolas', 9)
$log.Location = New-Object System.Drawing.Point(22, 516)
$log.Size = New-Object System.Drawing.Size(718, 176)
$log.BackColor = [System.Drawing.Color]::FromArgb(24, 26, 34)
$log.ForeColor = [System.Drawing.Color]::FromArgb(220, 224, 235)
$form.Controls.Add($log)

function Log($text) { $log.AppendText($text + "`r`n") }
function Tell($text, $icon = 'Information') { [void][System.Windows.Forms.MessageBox]::Show($form, $text, 'SMW data tool', 'OK', $icon) }

# ---- File Explorer pickers --------------------------------------------------------------------------------------------
function Pick-File($key, $title, $filter) {
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Title = $title
    $d.Filter = $filter
    $near = $rows[$key].Text.Text
    if (-not $near) { $near = $rows['game'].Text.Text }
    if ($near -and (Test-Path -LiteralPath $near)) { $d.InitialDirectory = Split-Path -Parent $near }
    if ($d.ShowDialog($form) -eq 'OK') { $rows[$key].Text.Text = $d.FileName }
}
$rows['game'].Button.Add_Click({ Pick-File 'game' 'Your Super Mario Bros. Wonder dump (1.0.0)' 'Switch game (*.nsp;*.xci)|*.nsp;*.xci|All files|*.*' })
$rows['prod'].Button.Add_Click({ Pick-File 'prod' 'prod.keys' 'prod.keys|prod.keys;*.keys|All files|*.*' })
$rows['title'].Button.Add_Click({ Pick-File 'title' 'title.keys' 'title.keys|title.keys;*.keys|All files|*.*' })
$rows['out'].Button.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'Where the SMW folder goes (about 5 GB)'
    if ($d.ShowDialog($form) -eq 'OK') { $rows['out'].Text.Text = $d.SelectedPath }
})
# Keys next to the dump are filled in by themselves.
$rows['game'].Text.Add_TextChanged({
    $g = $rows['game'].Text.Text
    if (-not $g -or -not (Test-Path -LiteralPath $g)) { return }
    $dir = Split-Path -Parent $g
    foreach ($k in 'prod', 'title') {
        $f = Join-Path $dir "$k.keys"
        if (-not $rows[$k].Text.Text -and (Test-Path -LiteralPath $f)) { $rows[$k].Text.Text = $f }
    }
})

# ---- running ----------------------------------------------------------------------------------------------------------
# A run is a queue of jobs, one at a time: tools (as WSL's root user), data, pkg, then the uploads.
$worker = New-Object SmwWorker
$script:queue = New-Object System.Collections.Queue
$script:job = $null
$script:distro = $null
$script:root = $null
$script:out = $null
$script:jobArgs = ''
$version = (Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'VERSION') -TotalCount 1).Trim()
$dataSteps = @{ '1' = 5; '2' = 10; '3' = 40; '4' = 85 }
$pkgSteps = @{ '1' = 2; '2' = 4; '3' = 8; '4' = 30; '5' = 96 }
$done = New-Object System.Collections.ArrayList

function Set-Busy($busy) {
    foreach ($r in $rows.Values) { $r.Text.Enabled = -not $busy; $r.Button.Enabled = -not $busy }
    foreach ($c in $ftp, $doData, $doPkg, $start, $uploadOnly) { $c.Enabled = -not $busy }
    $cancel.Enabled = $busy
}
function Ftp-Target {
    $parts = $ftp.Text.Trim() -split ':', 2
    $port = 2121
    if ($parts.Count -gt 1 -and $parts[1]) { $port = [int]$parts[1] }
    return @($parts[0], $port)
}
function Pkg-Path { return (Join-Path $script:out "SMW-v$version.pkg") }
function Start-Wsl($asRoot, $cmd) {
    $user = ''; if ($asRoot) { $user = '-u root ' }
    $worker.Start('wsl.exe', "-d `"$($script:distro)`" $user-- bash -lc `"$($cmd -replace '"', '\"')`"")
}

function Run-Next {
    if ($script:queue.Count -eq 0) {
        $script:job = $null
        Set-Busy $false
        $bar.Value = 100
        $status.Text = 'Done.'
        Tell ("Done.`n`n" + ($done -join "`n`n"))
        return
    }
    $script:job = $script:queue.Dequeue()
    $bar.Value = 0
    switch ($script:job) {
        'tools' {
            $status.Text = 'Checking the Linux tools...'
            if ($script:queue.Contains('pkg')) {
                # clang 21, PacBrew's PS4 toolchain and the rest, once (the first time downloads ~350 MB)
                Start-Wsl $true ('bash ' + (Quote "$($script:root)/scripts/install-build-deps.sh"))
            } else {
                Start-Wsl $true 'export DEBIAN_FRONTEND=noninteractive; missing=0; for c in git cmake ninja c++ curl python3; do command -v $c >/dev/null || missing=1; done; python3 -c "import venv, ensurepip" 2>/dev/null || missing=1; if [ $missing = 1 ]; then echo "installing the Linux tools..."; apt-get update -qq && apt-get install -y -qq git cmake ninja-build g++ curl python3 python3-venv ca-certificates; else echo "Linux tools: ready"; fi'
            }
        }
        'data' {
            $status.Text = 'Making the game data...'
            Start-Wsl $false ('bash ' + (Quote "$($script:root)/scripts/make-data.sh") + $script:jobArgs)
        }
        'pkg' {
            $status.Text = 'Building your package...'
            Start-Wsl $false ('bash ' + (Quote "$($script:root)/scripts/make-pkg-from-dump.sh") + $script:jobArgs)
        }
        'up-data' {
            $t = Ftp-Target
            $status.Text = "Uploading the game data to $($t[0]):$($t[1]) /data/SMW ..."
            Log "== upload to $($t[0]):$($t[1]) /data/SMW (files already there are skipped)"
            $worker.Upload((Join-Path $script:out 'SMW'), $t[0], $t[1], '/data/SMW')
        }
        'up-pkg' {
            $t = Ftp-Target
            $status.Text = "Uploading the package to $($t[0]):$($t[1]) /data/pkg ..."
            Log "== upload to $($t[0]):$($t[1]) /data/pkg"
            $worker.Upload((Pkg-Path), $t[0], $t[1], '/data/pkg')
        }
    }
}

# What a finished job leaves behind: a line for the final message ('' for none), or $null when it failed.
function Job-Result($job) {
    if ($worker.ExitCode -ne 0) { return $null }
    switch ($job) {
        'tools' { return '' }
        'data' {
            $smw = Join-Path $script:out 'SMW'
            if (-not (Test-Path -LiteralPath (Join-Path $smw 'analysis\main.bin'))) { return $null }
            if ($ftp.Text.Trim()) { return '' }
            return "The game data: $smw`nCopy the CONTENTS of that folder to /data/SMW on your PS4."
        }
        'pkg' {
            if (-not (Test-Path -LiteralPath (Pkg-Path))) { return $null }
            if ($ftp.Text.Trim()) { return '' }
            return "Your package: $(Pkg-Path)`nPut it in /data/pkg on your PS4 and install it with GoldHEN's Package Installer. Never share it."
        }
        'up-data' { return 'The game data is on your PS4 in /data/SMW.' }
        'up-pkg' { return "The package is on your PS4 in /data/pkg: install it with GoldHEN's Package Installer." }
    }
}

$start.Add_Click({
    $game = $rows['game'].Text.Text.Trim(); $prod = $rows['prod'].Text.Text.Trim()
    $titleKeys = $rows['title'].Text.Text.Trim(); $out = $rows['out'].Text.Text.Trim()
    if (-not $doData.Checked -and -not $doPkg.Checked) { Tell 'Tick the game data, the package, or both.' 'Warning'; return }
    if (-not $game -or -not (Test-Path -LiteralPath $game)) { Tell 'Pick your game dump (.nsp or .xci).' 'Warning'; return }
    if (-not $prod -or -not (Test-Path -LiteralPath $prod)) { Tell 'Pick your prod.keys.' 'Warning'; return }
    if ($titleKeys -and -not (Test-Path -LiteralPath $titleKeys)) { Tell 'title.keys was not found (leave it empty if you have none).' 'Warning'; return }
    if (-not $out -or -not (Test-Path -LiteralPath $out)) { Tell 'Pick an output folder.' 'Warning'; return }
    $script:distro = Find-Distro
    if (-not $script:distro) {
        Tell "WSL with Ubuntu is needed. Open PowerShell as administrator and run:`n`n    wsl --install -d Ubuntu`n`nRestart the PC, open Ubuntu once to create your user, then start this tool again." 'Warning'
        return
    }
    $script:root = To-Wsl $script:distro (Split-Path -Parent $PSScriptRoot)
    $wGame = To-Wsl $script:distro $game; $wProd = To-Wsl $script:distro $prod; $wOut = To-Wsl $script:distro $out
    $wTitle = $null; if ($titleKeys) { $wTitle = To-Wsl $script:distro $titleKeys }
    if (-not ($script:root -and $wGame -and $wProd -and $wOut)) { Tell 'WSL cannot reach one of the files or folders.' 'Warning'; return }
    $script:out = $out
    $script:jobArgs = ' --game ' + (Quote $wGame) + ' --prod ' + (Quote $wProd) + ' --out ' + (Quote $wOut)
    if ($wTitle) { $script:jobArgs += ' --title ' + (Quote $wTitle) }
    $script:queue.Clear(); $done.Clear()
    $script:queue.Enqueue('tools')
    if ($doData.Checked) { $script:queue.Enqueue('data') }
    if ($doPkg.Checked) { $script:queue.Enqueue('pkg') }
    if ($ftp.Text.Trim()) {
        if ($doData.Checked) { $script:queue.Enqueue('up-data') }
        if ($doPkg.Checked) { $script:queue.Enqueue('up-pkg') }
    }
    $log.Clear()
    Log "WSL: $($script:distro)"
    Set-Busy $true
    Run-Next
})

$uploadOnly.Add_Click({
    if (-not $ftp.Text.Trim()) { Tell 'Type your PS4 FTP address first (for example 192.168.0.90:2121).' 'Warning'; return }
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'The output folder of this tool (with the SMW folder and/or your package in it)'
    if ($rows['out'].Text.Text) { $d.SelectedPath = $rows['out'].Text.Text }
    if ($d.ShowDialog($form) -ne 'OK') { return }
    $folder = $d.SelectedPath
    if ((Split-Path -Leaf $folder) -eq 'SMW' -and (Test-Path -LiteralPath (Join-Path $folder 'analysis\main.bin'))) { $folder = Split-Path -Parent $folder }
    $script:out = $folder
    $script:queue.Clear(); $done.Clear()
    if (Test-Path -LiteralPath (Join-Path $folder 'SMW\analysis\main.bin')) { $script:queue.Enqueue('up-data') }
    if (Test-Path -LiteralPath (Pkg-Path)) { $script:queue.Enqueue('up-pkg') }
    if ($script:queue.Count -eq 0) { Tell "There is no SMW folder or SMW-v$version.pkg in that folder." 'Warning'; return }
    $log.Clear()
    Set-Busy $true
    Run-Next
})

$cancel.Add_Click({
    $script:queue.Clear()
    $worker.Cancel()
    $status.Text = 'Cancelled.'
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 100
$timer.Add_Tick({
    $line = $null
    $n = 0
    while ($n -lt 400 -and $worker.Lines.TryDequeue([ref]$line)) {
        $n++
        $clean = $line -replace "$([char]27)\[[0-9;]*m", ''
        if ($clean -match '^progress (\d+) (\d+)$') {
            $bar.Value = [int](100 * [int]$Matches[1] / [int]$Matches[2])
            $status.Text = "Uploading: $($Matches[1]) of $($Matches[2]) files"
            continue
        }
        if ($clean -match 'romfs\s+([\d.]+)%') {  # the importer's meter: in the status line, not the log
            $status.Text = "Decrypting the game: $($Matches[1])%"
            if ($script:job -eq 'data') { $bar.Value = [Math]::Min(39, 10 + [int]([double]$Matches[1] * 0.29)) }
            continue
        }
        if ($clean -match '^build (\d+)%$') {  # make-pkg-from-dump.sh's compile meter
            $status.Text = "Step 4/5: compiling, $($Matches[1])%"
            $bar.Value = [Math]::Min(95, 30 + [int]([int]$Matches[1] * 0.65))
            continue
        }
        if ($clean -match '== (\d)/([45]) (.*)') {
            $status.Text = "Step $($Matches[1])/$($Matches[2]): $($Matches[3].Trim())"
            $map = $dataSteps; if ($Matches[2] -eq '5') { $map = $pkgSteps }
            if ($map.ContainsKey($Matches[1])) { $bar.Value = $map[$Matches[1]] }
        }
        if ($clean.Trim()) { Log $clean }
    }
    if ($worker.Running -or -not $script:job) { return }
    $finished = $script:job
    $script:job = $null
    $result = Job-Result $finished
    if ($null -eq $result) {
        $script:queue.Clear()
        Set-Busy $false
        if ($finished -like 'up-*') { $status.Text = 'The upload stopped: press Upload only to resume it.' }
        elseif ($finished -eq 'tools') { $status.Text = 'The Linux tools could not be installed (see the log).' }
        else { $status.Text = "Stopped (exit code $($worker.ExitCode)): see the log." }
        return
    }
    if ($result) { [void]$done.Add($result) }
    Run-Next
})
$timer.Start()
$form.Add_FormClosing({ $worker.Cancel() })
[void]$form.ShowDialog()
