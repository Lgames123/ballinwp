$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$nodePath = 'C:\Program Files\nodejs\node.exe'
if (-not (Test-Path $nodePath)) {
  $nodePath = 'node'
}

Start-Process powershell -ArgumentList @(
  '-NoExit',
  '-Command',
  "Set-Location '$root'; & '$nodePath' server.js"
) | Out-Null

Start-Sleep -Seconds 2

$url = 'http://localhost:3000'
$edgeCandidates = @(
  'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
  'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
)
$chromeCandidates = @(
  'C:\Program Files\Google\Chrome\Application\chrome.exe',
  'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe'
)

$browser = $edgeCandidates + $chromeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($browser) {
  Start-Process $browser -ArgumentList @('--autoplay-policy=no-user-gesture-required', $url)
} else {
  Start-Process $url
}