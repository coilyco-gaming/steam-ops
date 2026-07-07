#Requires -Version 7.0
<#
  sunshine-sync-steam.ps1
  ------------------------
  Client-side ops helper (NOT part of the steam-mcp service). Rebuilds the Sunshine
  app list on a streaming host from that machine's locally-installed Steam games, so
  Moonlight shows one launchable tile per game instead of only "Desktop".

  * Discovers installed games from Steam's appmanifest_*.acf files - no API key, and
    only games that are actually installed (hence launchable) are included.
  * Pushes them to Sunshine via its web API. Sunshine runs as LocalSystem, so the API
    writes the (admin-owned) config for us - no elevation / UAC needed.
  * Idempotent: deletes the previous game tiles (keeping the ones in -Keep) and rebuilds,
    so re-run it whenever you install or uninstall a game.

  BOX ART
    Sunshine only renders **PNG** box art in Moonlight - a .jpg image-path shows a blank
    tile. So per game we fetch a portrait cover (local Steam cache first, then the Steam
    CDN, then the landscape header as a last resort) and CONVERT it to PNG via
    System.Drawing before linking it. Conversions are cached in -ArtDir, so a re-run is
    fast. -NoArt skips all of this.

  CREDENTIALS (never hardcoded - AGENTS.md: no secrets in the repo)
    The Sunshine web-UI password resolves at runtime: env var first, then an interactive
    prompt. It is never written to disk or logged.
      $env:SUNSHINE_WEB_PASSWORD = '...'   # then run, or omit to be prompted

  USAGE
    pwsh ./scripts/sunshine-sync-steam.ps1            # sync for real
    pwsh ./scripts/sunshine-sync-steam.ps1 -DryRun    # preview only, change nothing
    pwsh ./scripts/sunshine-sync-steam.ps1 -NoArt     # skip box-art download
    pwsh ./scripts/sunshine-sync-steam.ps1 -ExcludeAppId 382310,236390   # skip specific appids
#>
[CmdletBinding()]
param(
  [string]   $SunshineHost = 'https://localhost:47990',
  [string]   $Username     = 'coilysiren@gmail.com',
  [string]   $Password     = $env:SUNSHINE_WEB_PASSWORD,
  [string[]] $Keep         = @('Desktop','Steam Big Picture'),
  [string[]] $ExcludeName  = @('^Proton','Steam Linux Runtime','Steamworks Common Redistributables'),
  [int[]]    $ExcludeAppId = @(228980,1070560,1391110,1628350,1493710,1826330,1887720),
  [string]   $ArtDir       = 'C:\Users\Public\sunshine-box-art',
  [switch]   $NoArt,
  [switch]   $DryRun
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Get-SteamPath {
  foreach ($k in 'HKCU:\Software\Valve\Steam','HKLM:\SOFTWARE\WOW6432Node\Valve\Steam','HKLM:\SOFTWARE\Valve\Steam') {
    $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
    $v = $p.SteamPath; if (-not $v) { $v = $p.InstallPath }
    if ($v) { return ($v -replace '/','\') }
  }
  throw 'Steam install not found in registry.'
}

function Get-LibraryFolders($steam) {
  $paths = @($steam)
  $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
  if (Test-Path $vdf) {
    $txt = Get-Content $vdf -Raw
    foreach ($m in [regex]::Matches($txt,'"path"\s+"([^"]+)"')) {
      $paths += ($m.Groups[1].Value -replace '\\\\','\')
    }
  }
  $paths | Sort-Object -Unique
}

function Get-InstalledGames($libs) {
  $g = @{}
  foreach ($lib in $libs) {
    $sa = Join-Path $lib 'steamapps'
    if (-not (Test-Path $sa)) { continue }
    Get-ChildItem $sa -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue | ForEach-Object {
      $t  = Get-Content $_.FullName -Raw
      $id = [regex]::Match($t,'"appid"\s+"(\d+)"').Groups[1].Value
      $nm = [regex]::Match($t,'"name"\s+"([^"]+)"').Groups[1].Value
      if ($id -and $nm) { $g[[int]$id] = $nm }
    }
  }
  $g
}

# Fetch a cover for $id and return a PNG path (Sunshine renders PNG only), or '' if none found.
# Order: cached PNG -> local Steam library_600x900.jpg -> CDN portrait -> CDN landscape header.
function Get-BoxArtPng($id, $steam, $artDir) {
  $png = Join-Path $artDir "$id.png"
  if (Test-Path $png) { return $png }                      # cached from a prior run

  $srcJpg = $null
  $local  = Join-Path $steam "appcache\librarycache\$id\library_600x900.jpg"
  if (Test-Path $local) {
    $srcJpg = $local
  } else {
    $tmp = Join-Path $artDir "$id.src"
    foreach ($u in @(
      "https://cdn.cloudflare.steamstatic.com/steam/apps/$id/library_600x900_2x.jpg",
      "https://steamcdn-a.akamaihd.net/steam/apps/$id/library_600x900.jpg",
      "https://cdn.cloudflare.steamstatic.com/steam/apps/$id/header.jpg"     # older games: flat /steam/apps path
    )) { try { Invoke-WebRequest $u -OutFile $tmp -TimeoutSec 15; $srcJpg = $tmp; break } catch {} }
    if (-not $srcJpg) {
      # Newer games (store_item_assets/<hash>/) 404 on the flat paths. Ask the Steam store
      # API for the real hashed header/capsule URL - works for any game, new or old.
      try {
        $d = Invoke-RestMethod "https://store.steampowered.com/api/appdetails?appids=$id&filters=basic" -TimeoutSec 15
        $u = $d.$id.data.header_image; if (-not $u) { $u = $d.$id.data.capsule_image }
        if ($u) { Invoke-WebRequest $u -OutFile $tmp -TimeoutSec 15; $srcJpg = $tmp }
      } catch {}
    }
  }
  if (-not $srcJpg) { return '' }

  # Convert to PNG. Read via a MemoryStream so the source file isn't locked.
  try {
    $bytes = [IO.File]::ReadAllBytes($srcJpg)
    $ms  = [IO.MemoryStream]::new($bytes)
    $img = [System.Drawing.Image]::FromStream($ms)
    $img.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
    $img.Dispose(); $ms.Dispose()
  } catch { return '' }
  finally { $t = Join-Path $artDir "$id.src"; if (Test-Path $t) { Remove-Item $t -Force -ErrorAction SilentlyContinue } }
  if (Test-Path $png) { return $png } else { return '' }
}

# ---- discover installed games ----
$steam = Get-SteamPath
$libs  = Get-LibraryFolders $steam
$all   = Get-InstalledGames $libs
Write-Host "Steam:      $steam"
Write-Host "Libraries:  $($libs -join ' ; ')"
Write-Host "Installed:  $($all.Count) app manifest(s)"

# ---- filter out tools / redistributables ----
$games = @{}
foreach ($id in $all.Keys) {
  $nm = $all[$id]
  if ($ExcludeAppId -contains $id) { continue }
  $skip = $false
  foreach ($rx in $ExcludeName) { if ($nm -match $rx) { $skip = $true; break } }
  if (-not $skip) { $games[$id] = $nm }
}
$games = @($games.GetEnumerator() | Sort-Object { $_.Value })
Write-Host "Games:      $($games.Count) after filtering`n"

if ($games.Count -eq 0) { throw 'No installed games found. Is Steam installed and are games downloaded?' }

# ---- Sunshine auth (password: env first, then prompt) ----
if (-not $Password) { $Password = (Get-Credential -UserName $Username -Message 'Sunshine web-UI password').GetNetworkCredential().Password }
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${Username}:${Password}"))
$api = @{ Headers = @{ Authorization = "Basic $b64" }; SkipCertificateCheck = $true; TimeoutSec = 25 }

# ---- current apps ----
$current = @((Invoke-RestMethod "$SunshineHost/api/apps" @api).apps)

if ($DryRun) {
  Write-Host '== DRY RUN (nothing will change) =='
  Write-Host "Keep:   $($Keep -join ', ')"
  Write-Host "Delete: $(@($current | Where-Object { $Keep -notcontains $_.name }).Count) existing tile(s)"
  Write-Host "Add:    $($games.Count) game(s):"
  $games | ForEach-Object { "   - {0,-45} steam://rungameid/{1}" -f $_.Value, $_.Key }
  return
}

# ---- delete existing non-kept tiles (high index -> low so indices stay valid) ----
for ($i = $current.Count - 1; $i -ge 0; $i--) {
  if ($Keep -notcontains $current[$i].name) {
    Invoke-WebRequest "$SunshineHost/api/apps/$i" -Method Delete @api | Out-Null
  }
}

# ---- add games (with PNG box art) ----
if (-not $NoArt) {
  New-Item -ItemType Directory -Force -Path $ArtDir | Out-Null
  Add-Type -AssemblyName System.Drawing
}
$added = 0; $withArt = 0
foreach ($g in $games) {
  $id = $g.Key; $nm = $g.Value
  $img = ''
  if (-not $NoArt) { $img = Get-BoxArtPng $id $steam $ArtDir; if ($img) { $withArt++ } }
  $app = @{ name = $nm; cmd = "steam://rungameid/$id"; index = -1; 'auto-detach' = $true; 'wait-all' = $true }
  if ($img) { $app['image-path'] = $img }
  Invoke-WebRequest "$SunshineHost/api/apps" -Method Post -Body ($app | ConvertTo-Json -Depth 4) -ContentType 'application/json' @api | Out-Null
  $added++
  Write-Host ("  {0} {1}" -f $(if ($img) { '+' } else { '-' }), $nm)
}

Write-Host "`nDone. Added $added tile(s), $withArt with PNG art. Reconnect Moonlight to see them."
