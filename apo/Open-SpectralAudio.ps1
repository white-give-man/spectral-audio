param([ValidateSet('Install','Control','Uninstall')][string]$Action='Control')
$ErrorActionPreference='Stop'
# Hide only this host's console, without giving the WinForms process a hidden startup state.
. (Join-Path $PSScriptRoot 'SpectralAudio-Host.ps1')
Hide-SpectralConsole
try {
    $isAdmin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if(-not $isAdmin){
        $hostPath=Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process $hostPath -Verb RunAs -WindowStyle Minimized -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"'),'-Action',$Action)
        exit
    }
    if($Action -eq 'Install'){ & (Join-Path $PSScriptRoot 'Start-SpectralAudio.ps1') }
    else { & (Join-Path $PSScriptRoot 'Manage-SpectralAudio.ps1') -Action $Action }
    exit $LASTEXITCODE
} catch {
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.MessageBox]::Show($_.Exception.Message,'Spectral Audio 启动失败') | Out-Null
    exit 1
}
