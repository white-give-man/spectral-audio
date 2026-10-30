param([switch]$SelfTest)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'SpectralAudio-Host.ps1')
Hide-SpectralConsole
$process=$null;$form=$null;$finished=$false
$logDirectory=Join-Path $env:LOCALAPPDATA ('SpectralAudio\Setup\'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N'))
try {
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    . (Join-Path $PSScriptRoot 'SpectralAudio-Theme.ps1')
    $isAdmin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if(-not $SelfTest -and -not $isAdmin){
        $elevated=Start-Process $powershell -Verb RunAs -WindowStyle Minimized -PassThru -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"'))
        $heldHandle=$elevated.Handle
        while(-not $elevated.HasExited){Start-Sleep -Milliseconds 250}
        exit $elevated.ExitCode
    }
    $null=New-Item -ItemType Directory -Path $logDirectory -Force
    $progressFile=Join-Path $logDirectory 'progress.txt'
    $stdout=Join-Path $logDirectory 'output.txt';$stderr=Join-Path $logDirectory 'error.txt'
    $form=New-Object Windows.Forms.Form
    $form.Text='Spectral Audio 1.0.0 · 安装';$form.ClientSize=New-Object Drawing.Size(740,370)
    $form.StartPosition='CenterScreen';$form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false
    $form.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
    $label=New-Object Windows.Forms.Label;$label.SetBounds(48,145,644,60)
    $label.Text='正在启动安装程序，读取本机音频输出…';$form.Controls.Add($label)
    $bar=New-Object SpectralTheme.Progress;$bar.SetBounds(48,220,644,8);$form.Controls.Add($bar)
    $hint=New-Object Windows.Forms.Label;$hint.SetBounds(48,258,644,88)
    $hint.Text="请选择弹出窗口中的输出设备。已安装时会沿用原输出。`r`n验证期间会播放测试音并短暂重启音频，可能需要 1–3 分钟。`r`n请等待完成，避免中断正在写入的安装。";$form.Controls.Add($hint)
    $null=New-SpectralCard $form 24 100 692 144
    $phase=New-Object Windows.Forms.Label;$phase.Text='01   安装与验证';$phase.SetBounds(48,116,400,25);$form.Controls.Add($phase)
    $elapsed=New-Object Windows.Forms.Label;$elapsed.Text='已用时间  00:00';$elapsed.SetBounds(510,116,180,25);$elapsed.TextAlign='MiddleRight';$form.Controls.Add($elapsed)
    $hint.Tag='header'
    Set-SpectralTheme $form $null
    Add-SpectralHeader $form '耳机增强  /  安装向导 · 1.0.0'
    $form.Add_FormClosing({param($sender,$eventArgs) if(-not $script:finished){$eventArgs.Cancel=$true}})
    $form.Show();[Windows.Forms.Application]::DoEvents()
    if($SelfTest){
        $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
        $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
        $bitmap.Save((Join-Path $logDirectory 'startup-preview.png'));$bitmap.Dispose()
        Write-Output $logDirectory
        $finished=$true;$form.Close();exit 0
    }
    $process=Start-Process $powershell -WindowStyle Minimized -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $PSScriptRoot 'Manage-SpectralAudio.ps1')+'"'),'-Action','Install','-NoPanel','-ProgressFile',('"'+$progressFile+'"'))
    $heldHandle=$process.Handle
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while(-not $process.HasExited){
        if(Test-Path -LiteralPath $progressFile){try{$label.Text=[IO.File]::ReadAllText($progressFile,[Text.Encoding]::UTF8)}catch{}}
        $elapsed.Text='已用时间  '+$clock.Elapsed.ToString('mm\:ss')
        $form.Text='Spectral Audio 1.0.0 · 安装 · '+[int]$clock.Elapsed.TotalSeconds+' 秒'
        [Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 100
    }
    $process.WaitForExit();$exitCode=$process.ExitCode
    $finished=$true;$form.Close()
    if($exitCode -eq 0 -or $exitCode -eq 2){
        Start-Process $powershell -WindowStyle Minimized -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $PSScriptRoot 'Open-SpectralAudio.ps1')+'"'),'-Action','Control')
    }else{
        $detail=if(Test-Path -LiteralPath $stderr){[IO.File]::ReadAllText($stderr)}else{''}
        [Windows.Forms.MessageBox]::Show("安装未完成（退出码 $exitCode）。`r`n$detail`r`n启动日志：$logDirectory`r`n安装日志：$env:ProgramData\SpectralAudio",'Spectral Audio 安装失败')|Out-Null
    }
    exit $exitCode
}catch{
    $finished=$true
    if($form){$form.Close()}
    $message=$_.Exception.Message+"`r`n请将整个 ZIP 解压到本地文件夹后再运行。`r`n启动日志："+$logDirectory
    if('Windows.Forms.MessageBox' -as [type]){[Windows.Forms.MessageBox]::Show($message,'Spectral Audio 启动失败')|Out-Null}else{Write-Error $message}
    exit 1
}finally{if($form){$form.Dispose()};if($process){$process.Dispose()}}
