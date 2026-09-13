# Bootstrap wrapper: pins the interpreter so the caller's shell identity is
# irrelevant. Double-click, cmd, PowerShell, or an agent's tool call all run
# THIS file; it locates Git Bash, re-execs the real script with it, and fails
# with an install instruction if Git Bash is absent. WSL bash never enters
# the picture.
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sh = Join-Path $scriptDir 'pick-sessions.sh'

$gitBash = @(
  'C:\Program Files\Git\bin\bash.exe',
  'C:\Program Files (x86)\Git\bin\bash.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $gitBash) {
  $scoopShims = Join-Path $env:USERPROFILE 'scoop\shims\bash.exe'
  if (Test-Path $scoopShims) { $gitBash = $scoopShims }
}
if (-not $gitBash) {
  $cmd = Get-Command bash.exe -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source -notlike '*system32*') { $gitBash = $cmd.Source }
}
if (-not $gitBash) {
  Write-Error @'
Git Bash is required to run this skill on Windows (no usable bash found;
the bash in PATH may be WSL bash, which cannot run these scripts).
Install:  winget install Git.Git   (or https://git-scm.com/download/win)
'@
  exit 3
}

& $gitBash $sh @args
exit $LASTEXITCODE
