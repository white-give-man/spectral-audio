param([Parameter(Mandatory=$true)][string]$Directory,[switch]$SelfTest,[string]$SessionToken)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'SpectralAudio-Theme.ps1')
$panelMutex=New-Object Threading.Mutex($false,'Local\SpectralAudio.Panel')
if(-not $panelMutex.WaitOne(0)){[Windows.Forms.MessageBox]::Show('Spectral Audio 控制台已经打开。','Spectral Audio')|Out-Null;$panelMutex.Dispose();exit}
$state=Join-Path $env:ProgramData 'SpectralAudio'
. (Join-Path $Directory 'SpectralAudio-Session.ps1')
$cli=Join-Path $Directory 'spectral_apo_runtime.exe'
$installed=Read-SpectralJson (Join-Path $state 'install.json')
if(-not $SelfTest){
    $session=Get-SpectralSession
    if(-not $SessionToken -or $session.token -ne $SessionToken -or $session.phase -ne 'active' -or $session.owner_pid -ne $PID){throw '请从开始菜单 Spectral Audio 启动，以确保关闭时恢复原链路。'}
}
. (Join-Path $Directory 'Endpoint-Selection.ps1')
$endpoint=$installed.endpoint;$endpointGuid=Get-SpectralEndpointGuid $endpoint
$endpointName=if($installed.endpoint_name){$installed.endpoint_name}else{$endpoint}
$dsp='{b128a761-27bf-49df-a512-68d7e0921001}'
$fx='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\'+$endpointGuid+'\FxProperties'
$efx='{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},7'
$form=New-Object Windows.Forms.Form
$form.Text='Spectral Audio · 模型 1.0.0';$form.ClientSize=New-Object Drawing.Size(820,890);$form.MinimumSize=New-Object Drawing.Size(836,929);$form.StartPosition='CenterScreen'
$form.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
$form.BackColor=[Drawing.Color]::FromArgb(244,246,250)
function Label([string]$text,[int]$x,[int]$y,[int]$width,[int]$height){
    $c=New-Object Windows.Forms.Label;$c.Text=$text;$c.Location=New-Object Drawing.Point($x,$y);$c.Size=New-Object Drawing.Size($width,$height);$form.Controls.Add($c);return $c
}
$null=New-SpectralCard $form 24 100 772 135
$null=New-SpectralCard $form 24 251 772 205
$null=New-SpectralCard $form 24 472 772 292
$intro=Label ("输出：$endpointName · 48 kHz / 双声道。关闭窗口恢复原链路。") 48 116 724 30
$intro.AutoEllipsis=$true
$status=Label '正在读取系统运行证据…' 48 150 724 72
$status.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)
$null=Label '游戏模型' 48 275 160 28
$game=New-Object Windows.Forms.ComboBox;$game.DropDownStyle='DropDownList';$game.Location=New-Object Drawing.Point(48,309);$game.Size=New-Object Drawing.Size(240,32)
$script:modelCatalog=(& $cli models | ConvertFrom-Json)
if($LASTEXITCODE -ne 0 -or $script:modelCatalog.Count -ne 25){throw '模型目录读取失败。'}
$gameNames=@('CS2 / Counter-Strike 2','PUBG / 绝地求生','三角洲 / Delta Force','瓦罗兰特 / VALORANT','APEX / Apex Legends')
for($i=0;$i -lt 5;$i++){$suffix=if(@($script:modelCatalog | Where-Object {$_.game -eq $i -and $_.available}).Count){''}else{'（待接入）'};$null=$game.Items.Add($gameNames[$i]+$suffix)}
$form.Controls.Add($game)
$null=Label '增益强度（%）' 314 275 170 28
$strength=New-Object Windows.Forms.NumericUpDown;$strength.Location=New-Object Drawing.Point(314,309);$strength.Size=New-Object Drawing.Size(150,32);$strength.Minimum=0;$strength.Maximum=100;$strength.DecimalPlaces=1;$strength.Increment=1;$strength.Value=100;$form.Controls.Add($strength)
$null=Label '输出增益（dB）' 494 275 278 28
$gain=New-Object Windows.Forms.NumericUpDown;$gain.Location=New-Object Drawing.Point(494,309);$gain.Size=New-Object Drawing.Size(120,32);$gain.Minimum=-60;$gain.Maximum=0;$gain.DecimalPlaces=1;$gain.Increment=0.5;$form.Controls.Add($gain)
$gainPercent=Label '100.0%' 626 309 146 32
$gainPercent.TextAlign='MiddleLeft'
$mute=New-Object Windows.Forms.CheckBox;$mute.Text='静音（0%）';$mute.SetBounds(494,344,278,24);$form.Controls.Add($mute)
# Retain the exact legacy 0..1000 amplitude value until the user edits dB.
# Rounding its dB display must not change gain when applying a model/strength.
$script:gainMilli=1000
function Update-SpectralGainDisplay {
    $gain.Enabled=-not $mute.Checked
    $gainPercent.Text=if($mute.Checked){'0.0%（−∞ dB）'}else{('{0:F1}%' -f ($script:gainMilli/10.0))}
}
function Set-SpectralGainMilli([int]$milli) {
    $script:loadingGain=$true
    try {
        $script:gainMilli=[Math]::Max(0,[Math]::Min(1000,$milli))
        $gain.Value=if($script:gainMilli -eq 0){-60}else{[decimal][Math]::Round(20*[Math]::Log10($script:gainMilli/1000.0),1)}
        $mute.Checked=$script:gainMilli -eq 0
        Update-SpectralGainDisplay
    }finally{$script:loadingGain=$false}
}
$gain.Add_ValueChanged({
    if(-not $script:loadingGain){
        $script:gainMilli=[int][Math]::Round(1000*[Math]::Pow(10,[double]$gain.Value/20),0,[MidpointRounding]::AwayFromZero)
        Update-SpectralGainDisplay
    }
})
$mute.Add_CheckedChanged({
    if(-not $script:loadingGain){
        if(-not $mute.Checked -and $script:gainMilli -eq 0){$script:gainMilli=[int][Math]::Round(1000*[Math]::Pow(10,[double]$gain.Value/20),0,[MidpointRounding]::AwayFromZero)}
        Update-SpectralGainDisplay
    }
})
$bypass=New-Object Windows.Forms.CheckBox;$bypass.Text='旁路增强（仍保留 1024 帧延迟）';$bypass.Location=New-Object Drawing.Point(48,367);$bypass.Size=New-Object Drawing.Size(390,30);$form.Controls.Add($bypass)
$apply=New-Object Windows.Forms.Button;$apply.Text='应用设置';$apply.Location=New-Object Drawing.Point(582,363);$apply.Size=New-Object Drawing.Size(190,38);$form.Controls.Add($apply)
$message=Label '设置在音频帧边界应用；窗口显示回调确认后才认为已应用。' 48 412 724 34
function Button([string]$text,[int]$x){$b=New-Object Windows.Forms.Button;$b.Text=$text;$b.Location=New-Object Drawing.Point($x,496);$b.Size=New-Object Drawing.Size(174,40);$form.Controls.Add($b);return $b}
$verify=Button '验证与 A/B 测量' 48
$stop=Button '退出并恢复原链路' 232
$restore=Button '卸载 Spectral Audio' 416
$logs=Button '打开诊断记录' 600
$details=New-Object Windows.Forms.TextBox;$details.Location=New-Object Drawing.Point(48,560);$details.Size=New-Object Drawing.Size(724,180);$details.Multiline=$true;$details.ReadOnly=$true;$details.ScrollBars='Vertical';$form.Controls.Add($details)
foreach($control in $form.Controls){if($control.Top -ge 100){$control.Top+=100}}
$null=New-SpectralCard $form 24 100 772 88
$null=Label '增强目标（不更改 Windows 默认播放设备）' 48 110 724 28
$outputCombo=New-Object Windows.Forms.ComboBox;$outputCombo.DropDownStyle='DropDownList';$outputCombo.SetBounds(48,146,520,30);$outputCombo.DropDownWidth=724;$form.Controls.Add($outputCombo)
$refreshOutput=New-Object Windows.Forms.Button;$refreshOutput.Text='刷新';$refreshOutput.SetBounds(582,142,82,36);$form.Controls.Add($refreshOutput)
$switchOutput=New-Object Windows.Forms.Button;$switchOutput.Text='切换增强';$switchOutput.SetBounds(680,142,92,36);$form.Controls.Add($switchOutput)
$outputCombo.Name='EnhancementTarget';$switchOutput.Name='SwitchEnhancement'
function Refresh-SpectralTargets {
    $script:outputDevices=@(Get-SpectralEndpoints $Directory)
    $outputCombo.Items.Clear()
    foreach($device in $script:outputDevices){
        $tag=if($device.is_default){' [系统默认]'}else{''}
        $null=$outputCombo.Items.Add(('{0}{1} · {2} Hz / {3} 声道' -f $device.name,$tag,$device.rate,$device.channels))
    }
    $outputCombo.SelectedIndex=-1
    for($i=0;$i -lt $script:outputDevices.Count;$i++){if($script:outputDevices[$i].id -eq $script:endpoint){$outputCombo.SelectedIndex=$i;break}}
}
function Read-SpectralPanelTarget {
    $active=Read-SpectralJson (Join-Path $state 'install.json')
    $script:endpoint=$active.endpoint;$script:endpointGuid=Get-SpectralEndpointGuid $active.endpoint
    $script:endpointName=$active.endpoint_name
    $script:fx='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\'+$script:endpointGuid+'\FxProperties'
    $intro.Text='当前增强：'+$script:endpointName+'。关闭窗口恢复原链路。'
    $script:prior=@{};$script:wanted=$null
}
$intro.Tag='muted';$message.Tag='muted'
Set-SpectralTheme $form $apply
Add-SpectralHeader $form 'Spectral Audio  /  频谱音频增强 1.0.0'
$script:modelLevel=4;$script:prior=@{};$script:wanted=$null
$settingsPath=Join-Path $state 'panel-settings.json'
try{
    $r=(& $cli status | ConvertFrom-Json);if($r.error -ne 0){throw '尚无运行状态文件。安装后再读取。'};$word=[uint32]$r.settings

    $selected=[int](($word -band 3) -bor (($word -shr 13) -band 4));if($selected -gt 4){$selected=0}
    $strength.Value=if($word -band (1 -shl 27)){[decimal]([Math]::Min(1000,(($word -shr 17) -band 1023))/10.0)}else{100}
    $game.SelectedIndex=$selected;Set-SpectralGainMilli ([int](($word -shr 5) -band 1023));$bypass.Checked=($word -band 16) -ne 0
}catch{$game.SelectedIndex=2;$strength.Value=100;Set-SpectralGainMilli 1000;$details.Text=$_.Exception.Message}
$apply.Add_Click({
    try{
        if(-not @($script:modelCatalog | Where-Object {$_.game -eq $game.SelectedIndex -and $_.level -eq $script:modelLevel -and $_.available}).Count){throw '此游戏暂未接入模型。当前版本支持三角洲 / Delta Force。'}
        $word=[uint32](($game.SelectedIndex -band 3) -bor (($game.SelectedIndex -band 4) -shl 13) -bor (($script:modelLevel -band 3) -shl 2) -bor (($script:modelLevel -band 4) -shl 14) -bor ([int]$bypass.Checked -shl 4) -bor ($(if($mute.Checked){0}else{$script:gainMilli}) -shl 5) -bor $(if($strength.Value -eq 100){0}else{([int]($strength.Value*10) -shl 17) -bor (1 -shl 27)}))
        $result=& $cli set ([string]$word);if($LASTEXITCODE){throw "设置未发布：$result"}
        @{strength_milli=[int]($strength.Value*10);settings=$word} | ConvertTo-Json | Set-Content $settingsPath -Encoding UTF8
        $script:wanted=$word;$message.Text='参数已发布，等待目标端点的 audiodg 处理回调确认。'
    }catch{$message.Text=$_.Exception.Message}
})
$timer=New-Object Windows.Forms.Timer;$timer.Interval=1000
$timer.Add_Tick({
    try{
        $activeInstall=Join-Path $state 'install.json'
        if(-not(Test-Path $activeInstall) -or (Read-SpectralJson $activeInstall).directory -ne $Directory){$form.Close();return}
        $r=& $cli status | ConvertFrom-Json
        $configured=(Get-ItemProperty -LiteralPath $fx -ErrorAction SilentlyContinue).$efx
        $properties=Get-ItemProperty -LiteralPath $fx -ErrorAction SilentlyContinue
        $inComposite=($dsp -in @($properties.'{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},14') -or $dsp -in @($properties.'{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},15'))
        $configText=if($configured -eq $dsp -or $inComposite){'原 DSP'}elseif(-not $configured){'原效果链'}else{'其他 / Unity'}
        $live=@();$next=@{}
        foreach($s in $r.instances){
            $key="$($s.pid):$($s.instance)";$next[$key]=$s.callbacks
            if($s.process -eq 'audiodg.exe' -and $s.module -eq (Join-Path $Directory 'SpectralAudio.dll') -and $s.endpoint -eq $endpoint -and $s.stage -eq 5 -and $s.locked -eq 1 -and $s.unity -eq 0 -and $s.raw -eq 0 -and $s.discovery -eq 0 -and $s.faults -eq 0 -and $s.hresult -eq 0 -and $s.age_ms -lt 1500 -and $script:prior.ContainsKey($key) -and $s.callbacks -gt $script:prior[$key]){$live+=,$s}
        }
        $script:prior=$next
        if($live.Count){
            $s=$live[-1];$status.Text="关联配置：$configText`r`n实际处理：已确认 audiodg DSP 回调持续增长；PID $($s.pid)，累计 $($s.frames) 帧。`r`n故障：$($s.faults)；最大回调耗时：$($s.max_callback_us) μs。"
            if($null -ne $script:wanted -and $s.settings -eq $script:wanted){$message.Text='当前设置已由目标端点的 DSP 回调确认。';$script:wanted=$null}
        }else{$status.Text="关联配置：$configText`r`n实际处理：当前没有足够运行证据（可能空闲、未挂载、格式不支持或故障）。`r`n播放声音后观察；自动验证可采集完整诊断。"}
        $fault=@($r.instances | Where-Object {$_.process -eq 'audiodg.exe' -and $_.module -eq (Join-Path $Directory 'SpectralAudio.dll') -and $_.endpoint -eq $endpoint -and $_.age_ms -lt 10000 -and ($_.faults -gt 0 -or $_.hresult -ne 0)})
        if($fault.Count){$s=$fault[-1];$status.Text=('处理故障：阶段 {0}，HRESULT 0x{1:X8}，故障计数 {2}。请打开诊断记录。' -f $s.stage,[uint32]$s.hresult,$s.faults)}
        $text=($r.instances | Select-Object -Last 8 | Select-Object pid,process,endpoint,stage,hresult,unity,locked,frames,faults,rate,channels,settings,age_ms | Format-List | Out-String)
        $last=Join-Path $state 'latest-verification.json'
        if(Test-Path $last){$v=Get-Content $last -Raw | ConvertFrom-Json;if($v.endpoint -eq $endpoint){$latencyText=if($v.latency_verified){[string]$v.software_delta_ms+' ms（队列修正估计）'}else{'未可靠测得：'+$v.latency_failure};$text="最近验证：处理=$($v.audiodg_processing_verified)，回环包含 Spectral=$($v.loopback_covers_spectral)，挂载=$($v.hook_strategy)`r`n失败原因：$($v.failure)`r`nSpectral 额外软件延迟：$latencyText；物理总延迟未测。`r`n`r`n"+$text}}
        $details.Text=$text
    }catch{$status.Text='运行状态不可用：'+$_.Exception.Message}
})
$verify.Add_Click({
    $timer.Stop();$form.Enabled=$false
    try{
        [Windows.Forms.Application]::DoEvents()
        $message.Text='正在播放低音量测试信号并重建音频图，约 1 分钟。请暂停其他音频。'
        $p=Start-Process "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $Directory 'Manage-SpectralAudio.ps1')+'"'),'-Action','Verify','-SessionToken',$SessionToken,'-NoUI','-NoPanel') -WindowStyle Hidden -PassThru
        $heldHandle=$p.Handle
        while(-not $p.HasExited){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 100}
        $message.Text=if($p.ExitCode -eq 0){'验证完成，结果已记录。'}else{'验证未通过，请查看下方状态与诊断记录。'}
    }finally{$form.Enabled=$true;$timer.Start()}
})
$restore.Add_Click({
$script:uninstallRequested=$true;$form.Close()
})
$stop.Add_Click({$form.Close()})
$refreshOutput.Add_Click({try{Refresh-SpectralTargets}catch{$message.Text=$_.Exception.Message}})
$switchOutput.Add_Click({
    $worker=$null;$progress=$null
    try {
        if($outputCombo.SelectedIndex -lt 0){throw '请先选择增强目标。'}
        $chosen=$script:outputDevices[$outputCombo.SelectedIndex];Assert-SpectralEndpoint $chosen
        if($chosen.id -eq $script:endpoint){$message.Text='当前已在增强此设备。';return}
        $timer.Stop();$form.Enabled=$false
        $message.Text='正在切换增强目标，首次使用会播放测试音并验证；Windows 默认输出不变。'
        $status.Text='正在恢复旧设备并准备新设备，请等待完成…'
        [Windows.Forms.Application]::DoEvents()
        $progress=Join-Path $env:TEMP ('SpectralAudio-Switch-'+[guid]::NewGuid().ToString('N')+'.txt')
        $worker=Start-Process "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $Directory 'Manage-SpectralAudio.ps1')+'"'),'-Action','Switch','-EndpointId',('"'+$chosen.id+'"'),'-SessionToken',$SessionToken,'-NoUI','-NoPanel','-ProgressFile',('"'+$progress+'"'))
        $heldHandle=$worker.Handle
        while(-not $worker.HasExited){
            if(Test-Path -LiteralPath $progress){try{$status.Text=[IO.File]::ReadAllText($progress,[Text.Encoding]::UTF8)}catch{}}
            [Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 100
        }
        $worker.WaitForExit()
        Read-SpectralPanelTarget;Refresh-SpectralTargets
        $result=if(Test-Path -LiteralPath $progress){[IO.File]::ReadAllText($progress,[Text.Encoding]::UTF8)}else{'切换失败，请查看诊断记录。'}
        $message.Text=$result
        $activeSession=Get-SpectralSession
        if($activeSession.phase -ne 'active'){
            [Windows.Forms.MessageBox]::Show($result+' 控制台将退出并继续恢复原链路。','Spectral Audio')|Out-Null
            $form.Close()
        }
    }catch{$message.Text=$_.Exception.Message}
    finally{
        if($worker){$worker.Dispose()}
        if($progress -and (Test-Path -LiteralPath $progress)){Remove-Item -LiteralPath $progress -Force}
        if(-not $form.IsDisposed -and $form.Visible){$form.Enabled=$true;$timer.Start()}
    }
})
$logs.Add_Click({Start-Process explorer.exe -ArgumentList ('"'+$state+'"')})
$form.Add_FormClosed({$timer.Stop();$timer.Dispose();$panelMutex.ReleaseMutex();$panelMutex.Dispose()})
if($SelfTest){try{Refresh-SpectralTargets}catch{$message.Text=$_.Exception.Message}}
if($SelfTest){$form.StartPosition='Manual';$form.Location=New-Object Drawing.Point(-30000,-30000);$form.Show();[Windows.Forms.Application]::DoEvents();$bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height);$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save((Join-Path $Directory 'panel-preview.png'));$bitmap.Dispose();$form.Close();$form.Dispose();exit 0}
try{Refresh-SpectralTargets}catch{$message.Text='设备列表读取失败，可点击刷新：'+$_.Exception.Message}
$script:uninstallRequested=$false
$timer.Start();[void]$form.ShowDialog();$form.Dispose()
if($script:uninstallRequested){Write-Output 'Uninstall'}


