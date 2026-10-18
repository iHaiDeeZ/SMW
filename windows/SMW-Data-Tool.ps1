# SMW data tool for Windows: your Super Mario Bros. Wonder 1.0.0 dump and keys in, the folder for /data/SMW on your
# PS4 out (scripts/make-data.sh, run in WSL), and, if you like, uploaded to the console over FTP.
# Start it with SMW-Data-Tool.cmd (double-click). Nothing leaves your PC except the optional upload to your own PS4.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()

function Say($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }
function Fail($text) {
    Say ''
    Say $text 'Red'
    [System.Windows.Forms.MessageBox]::Show($text, 'SMW data tool', 'OK', 'Error') | Out-Null
    exit 1
}

Say ''
Say '  SMW data tool' 'Yellow'
Say '  Your own Super Mario Bros. Wonder 1.0.0 dump -> the game data for /data/SMW on your PS4'
Say ''

# ---- WSL ------------------------------------------------------------------------------------------------------------
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Fail "WSL is not installed. Open PowerShell as administrator, run:`n`n    wsl --install -d Ubuntu`n`nrestart the PC, open Ubuntu once to make your user, then start this tool again."
}
$distros = @((& wsl.exe -l -q) -replace "`0", '' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$distro = $distros | Where-Object { $_ -like 'Ubuntu*' } | Select-Object -First 1
if (-not $distro) { $distro = $distros | Select-Object -First 1 }
if (-not $distro) {
    Fail "WSL has no Linux installed. Run:`n`n    wsl --install -d Ubuntu`n`nopen Ubuntu once to make your user, then start this tool again."
}
Say "  WSL: $distro"

function ToWsl($path) {
    $p = (& wsl.exe -d $distro -- wslpath -a ($path -replace '\\', '/')) 2>$null
    if (-not $p) { Fail "WSL could not reach $path" }
    return $p.Trim()
}

# ---- your files -----------------------------------------------------------------------------------------------------
function PickFile($title, $filter, $optional) {
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Title = $title
    $d.Filter = $filter
    if ($d.ShowDialog() -eq 'OK') { return $d.FileName }
    if ($optional) { return $null }
    Fail 'Cancelled.'
}
[System.Windows.Forms.MessageBox]::Show(
    "You will pick, in turn:`n`n 1. your Super Mario Bros. Wonder dump (.nsp or .xci, version 1.0.0)`n 2. prod.keys`n 3. title.keys (Cancel if you have none)`n 4. the folder where the SMW folder goes (about 5 GB)`n`nAll from your own Switch. The tool needs 20-40 minutes and about 12 GB free on the drive WSL lives on.",
    'SMW data tool', 'OK', 'Information') | Out-Null
$game = PickFile '1. Your Super Mario Bros. Wonder dump (1.0.0)' 'Switch game (*.nsp;*.xci)|*.nsp;*.xci' $false
$prod = PickFile '2. prod.keys' 'prod.keys|prod.keys;*.keys|All files|*.*' $false
$title = PickFile '3. title.keys (Cancel if you have none)' 'title.keys|title.keys;*.keys|All files|*.*' $true
$f = New-Object System.Windows.Forms.FolderBrowserDialog
$f.Description = '4. Where the SMW folder goes (about 5 GB)'
if ($f.ShowDialog() -ne 'OK') { Fail 'Cancelled.' }
$out = $f.SelectedPath

Say "  game:   $game"
Say "  keys:   $prod$(if ($title) { ", $title" })"
Say "  output: $out\SMW"

# ---- make the data (WSL) --------------------------------------------------------------------------------------------
$root = ToWsl (Split-Path -Parent $PSScriptRoot)
$wslArgs = @('-d', $distro, '--', 'bash', "$root/scripts/make-data.sh",
          '--game', (ToWsl $game), '--prod', (ToWsl $prod), '--out', (ToWsl $out))
if ($title) { $wslArgs += @('--title', (ToWsl $title)) }
Say ''
Say '  Working in WSL (it may ask for your Ubuntu password once, to install tools)...' 'Yellow'
& wsl.exe @wslArgs
if ($LASTEXITCODE -ne 0) { Fail "The data could not be made (see the messages above). Exit code $LASTEXITCODE." }
$smw = Join-Path $out 'SMW'
if (-not (Test-Path (Join-Path $smw 'analysis\main.bin'))) { Fail "No game data in $smw." }
Say ''
Say "  Done: $smw" 'Green'

# ---- optional upload to the PS4 -------------------------------------------------------------------------------------
Add-Type -AssemblyName Microsoft.VisualBasic
$ps4 = [Microsoft.VisualBasic.Interaction]::InputBox(
    "Upload the data to your PS4 now?`n`nType its FTP address (for example 192.168.0.90:2121, as GoldHEN's FTP shows it), or leave it empty to copy the CONTENTS of the SMW folder to /data/SMW yourself (FileZilla).",
    'SMW data tool', '')
if (-not $ps4) {
    Say "  Copy the contents of $smw to /data/SMW on the PS4 over FTP." 'Yellow'
    exit 0
}
$ftpHost, $ftpPort = $ps4 -split ':', 2
if (-not $ftpPort) { $ftpPort = '2121' }

$py = Get-Command py.exe -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python.exe -ErrorAction SilentlyContinue }
$uploader = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\upload-data.py'
if ($py) {
    & $py.Source $uploader $smw --host $ftpHost --port $ftpPort --dest /data/SMW
    if ($LASTEXITCODE -ne 0) { Fail 'The upload stopped. Start the tool again to resume it, or copy the files with FileZilla.' }
} else {
    # No Python: plain FTP from PowerShell (slower). A file already there with the same size is skipped.
    Say '  Uploading (no Python found: the slower built-in way)...' 'Yellow'
    $base = "ftp://$($ftpHost):$ftpPort/data/SMW"
    function FtpRequest($uri, $method) {
        $r = [System.Net.FtpWebRequest]::Create($uri)
        $r.Method = $method
        $r.UseBinary = $true
        $r.KeepAlive = $true
        $r.UsePassive = $true
        return $r
    }
    $made = @{}
    function MakeDir($rel) {
        if (-not $rel -or $made.ContainsKey($rel)) { return }
        MakeDir (Split-Path -Parent $rel)
        try { (FtpRequest "$base/$($rel -replace '\\', '/')" ([System.Net.WebRequestMethods+Ftp]::MakeDirectory)).GetResponse().Close() } catch {}
        $made[$rel] = $true
    }
    MakeDir '.'
    $files = Get-ChildItem -Path $smw -Recurse -File
    $n = 0
    foreach ($file in $files) {
        $n++
        $rel = $file.FullName.Substring($smw.Length + 1)
        $uri = "$base/$($rel -replace '\\', '/')"
        MakeDir (Split-Path -Parent $rel)
        try {
            $s = (FtpRequest $uri ([System.Net.WebRequestMethods+Ftp]::GetFileSize)).GetResponse()
            $size = $s.ContentLength
            $s.Close()
            if ($size -eq $file.Length) { continue }
        } catch {}
        $req = FtpRequest $uri ([System.Net.WebRequestMethods+Ftp]::UploadFile)
        $stream = $req.GetRequestStream()
        $in = [System.IO.File]::OpenRead($file.FullName)
        $in.CopyTo($stream)
        $in.Close()
        $stream.Close()
        $req.GetResponse().Close()
        if ($n % 200 -eq 0) { Write-Progress -Activity 'Uploading to /data/SMW' -Status "$n of $($files.Count)" -PercentComplete (100 * $n / $files.Count) }
    }
}
Say ''
Say '  Uploaded to /data/SMW. Install the SMW package on the PS4 and start it.' 'Green'
[System.Windows.Forms.MessageBox]::Show('The game data is on your PS4 in /data/SMW.', 'SMW data tool', 'OK', 'Information') | Out-Null
