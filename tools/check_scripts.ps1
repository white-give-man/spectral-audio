param([string]$Directory=(Join-Path (Split-Path $PSScriptRoot) 'apo'))
$ErrorActionPreference='Stop'
$checked=0
Get-ChildItem -LiteralPath $Directory -Filter *.ps1 | ForEach-Object {
    $tokens=$null;$errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors)
    if($errors){throw ($errors | Out-String)}
    $checked++
}
Write-Output "PASS PowerShell syntax: $checked files"
