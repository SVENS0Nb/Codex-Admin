[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$cli = (Resolve-Path (Join-Path $PSScriptRoot '..\mcp\homelab-admin\build\cli.js')).Path
$context = & node.exe $cli context
if ($LASTEXITCODE -ne 0) {
    throw 'Could not load the Homelab bootstrap context.'
}
$context
