param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$repoRoot = $PSScriptRoot
# Reuse the tool installation from Kisskhdownloader to avoid duplicating GBs of Python/UV files
$toolRoot = "D:\Repos\Kisskhdownloader\.tools\code-review-graph"
$stateRoot = Join-Path $repoRoot ".tools\code-review-graph\state"
$gitConfig = Join-Path $stateRoot "gitconfig"
$repoForGit = $repoRoot -replace "\\", "/"

New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

$env:UV_INSTALL_DIR = Join-Path $toolRoot "uv-bin"
$env:UV_NO_MODIFY_PATH = "1"
$env:UV_CACHE_DIR = Join-Path $toolRoot "cache"
$env:UV_TOOL_DIR = Join-Path $toolRoot "tools"
$env:UV_TOOL_BIN_DIR = Join-Path $toolRoot "bin"
$env:UV_PYTHON_INSTALL_DIR = Join-Path $toolRoot "python"
$env:UV_PYTHON_BIN_DIR = Join-Path $toolRoot "python-bin"
$env:UV_PYTHON_INSTALL_REGISTRY = "0"
$env:GIT_CONFIG_GLOBAL = $gitConfig

if (-not (Test-Path $gitConfig)) {
    New-Item -ItemType File -Path $gitConfig | Out-Null
}

& git config --global --replace-all safe.directory $repoForGit | Out-Null

$exe = Join-Path $toolRoot "bin\code-review-graph.exe"
if (-not (Test-Path $exe)) {
    Write-Error "code-review-graph is not installed at $exe"
    exit 1
}

& $exe @Arguments
exit $LASTEXITCODE
