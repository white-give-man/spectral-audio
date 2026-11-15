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
$form.Text='Spectral Audio 1.1.0';$form.ClientSize=New-Object Drawing.Size(820,644);$form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false;$form.AutoScaleMode='Dpi';$form.StartPosition='CenterScreen'
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
# UI positions are independent of the stable game IDs encoded in settings.
$script:gameOptions=@(
    @{Id=1;Name='PUBG / 绝地求生'},
    @{Id=2;Name='三角洲 / Delta Force'}
)
foreach($option in $script:gameOptions){$suffix=if(@($script:modelCatalog | Where-Object {$_.game -eq $option.Id -and $_.available}).Count){''}else{'（待接入）'};$null=$game.Items.Add($option.Name+$suffix)}
function Select-SpectralGame([int]$gameId) {
    $game.SelectedIndex=1 # Delta Force is the available default for removed/unknown IDs.
    for($i=0;$i -lt $script:gameOptions.Count;$i++){if($script:gameOptions[$i].Id -eq $gameId){$game.SelectedIndex=$i;break}}
}
$form.Controls.Add($game)
$null=Label '增益强度（%）' 314 275 170 28
$strength=New-Object Windows.Forms.NumericUpDown;$strength.Location=New-Object Drawing.Point(314,309);$strength.Size=New-Object Drawing.Size(150,32);$strength.Minimum=0;$strength.Maximum=200;$strength.DecimalPlaces=1;$strength.Increment=1;$strength.Value=100;$form.Controls.Add($strength)
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
$bypass=New-Object Windows.Forms.CheckBox;$bypass.Text='恢复原音';$bypass.Location=New-Object Drawing.Point(48,367);$bypass.Size=New-Object Drawing.Size(160,30);$form.Controls.Add($bypass)
$drcEnabled=New-Object Windows.Forms.CheckBox
$drcEnabled.Text='爆音抑制';$drcEnabled.SetBounds(220,367,130,30);$form.Controls.Add($drcEnabled)
$drcMode=New-Object Windows.Forms.ComboBox
$drcMode.DropDownStyle='DropDownList';$drcMode.SetBounds(360,367,190,30)
$drcMode.AccessibleName='爆音抑制 DRC 模式'
foreach($title in @('默认曲线','模式 1','模式 2','模式 3','模式 4')){$null=$drcMode.Items.Add($title)}
$drcMode.SelectedIndex=0;$drcMode.Enabled=$false;$form.Controls.Add($drcMode)
$drcEnabled.Add_CheckedChanged({$drcMode.Enabled=$drcEnabled.Checked})
$apply=New-Object Windows.Forms.Button;$apply.Text='应用设置';$apply.Location=New-Object Drawing.Point(582,363);$apply.Size=New-Object Drawing.Size(190,38);$form.Controls.Add($apply)
$message=Label '爆音抑制可压低突发大音量；修改后点击应用设置，恢复原音会绕过抑制。' 48 412 724 34
function Button([string]$text,[int]$x){$b=New-Object Windows.Forms.Button;$b.Text=$text;$b.Location=New-Object Drawing.Point($x,496);$b.Size=New-Object Drawing.Size(174,40);$form.Controls.Add($b);return $b}
$verify=Button '验证与 A/B 测量' 48
$stop=Button '退出并恢复原链路' 232
$restore=Button '卸载 Spectral Audio' 416
$logs=Button '打开诊断记录' 600
$details=New-Object Windows.Forms.TextBox;$details.Location=New-Object Drawing.Point(48,574);$details.Size=New-Object Drawing.Size(724,166);$details.Multiline=$true;$details.ReadOnly=$true;$details.ScrollBars='Vertical';$form.Controls.Add($details)
$diagnosticsMessage=Label '可播放测试信号，检查当前设备的 DSP 回调和回环增益。' 48 543 724 25
$diagnosticsMessage.Tag='muted'
$overviewPage=@($form.Controls | Where-Object {$_.Top -lt 472})
$diagnosticsPage=@($form.Controls | Where-Object {$_.Top -ge 472})
foreach($control in $overviewPage){$control.Top+=144}
foreach($control in $diagnosticsPage){$control.Top-=228}
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
$eqCard=New-SpectralCard $form 24 244 772 356
$eqTitle=Label '十段均衡器' 48 263 220 32
$eqTitle.Font=New-Object Drawing.Font('Microsoft YaHei UI',15,[Drawing.FontStyle]::Bold)
$eqHint=Label '点击频率可直接修改  ·  提升频段时可降低输出增益' 48 300 500 25
$eqHint.Tag='muted'
$eqEnabled=New-Object Windows.Forms.CheckBox
$eqEnabled.Text='启用 EQ';$eqEnabled.SetBounds(557,266,103,30);$form.Controls.Add($eqEnabled)
$eqReset=New-Object Windows.Forms.Button
$eqReset.Text='全部归零';$eqReset.SetBounds(670,262,102,36);$form.Controls.Add($eqReset)
$eqFaders=@();$eqValues=@()
foreach($axis in @(@('+6',345),@('0',413),@('−6',481))){
    $axisLabel=Label $axis[0] 48 $axis[1] 36 24
    $axisLabel.Tag='muted';$axisLabel.TextAlign='MiddleRight'
}
$dbLabel=Label 'dB' 48 512 36 28
$dbLabel.Tag='muted';$dbLabel.TextAlign='MiddleRight'
$defaultFrequencies=@(63,125,250,500,1000,2000,4000,6000,8000,16000)
$frequencyLinks=@()
$frequencyOverrides=[int[]]::new($defaultFrequencies.Count)
$frequencyTip=New-Object Windows.Forms.ToolTip
$frequencyMenu=New-Object Windows.Forms.ContextMenuStrip
$restoreFrequency=$frequencyMenu.Items.Add('恢复此段默认频率')
for($i=0;$i -lt $defaultFrequencies.Count;$i++){
    $x=93+68*$i
    $freq=New-Object Windows.Forms.LinkLabel
    $freq.SetBounds($x,326,68,21);$freq.TextAlign='MiddleCenter';$freq.Tag=$i
    $freq.LinkBehavior='HoverUnderline';$freq.ContextMenuStrip=$frequencyMenu
    $frequencyTip.SetToolTip($freq,'点击编辑频率（20–20000 Hz），右键恢复默认')
    $form.Controls.Add($freq);$frequencyLinks+=,$freq
    $fader=New-Object SpectralTheme.EqFader
    $fader.SetBounds($x,346,68,158);$fader.Tag=$i
    $form.Controls.Add($fader);$eqFaders+=,$fader
    $value=New-Object Windows.Forms.NumericUpDown
    $value.SetBounds(($x+3),513,62,28);$value.Minimum=-6;$value.Maximum=6
    $value.DecimalPlaces=2;$value.Increment=0.10;$value.TextAlign='Center'
    $value.Tag=$i
    $form.Controls.Add($value);$eqValues+=,$value
}
$eqMessage=Label '' 48 557 724 28
$eqMessage.Tag='muted'
$eqPage=@($form.Controls | Where-Object {$_ -eq $eqCard -or ($eqCard.Bounds.Contains($_.Bounds) -and $_ -notin $overviewPage -and $_ -notin $diagnosticsPage)})
$nav=@()
foreach($title in @('音频设置','均衡器','运行诊断')){
    $tab=New-Object Windows.Forms.Button
    $tab.Text=$title;$tab.Tag=$nav.Count;$tab.SetBounds((24+120*$nav.Count),202,110,34)
    $tab.AccessibleRole='PageTab';$form.Controls.Add($tab);$nav+=,$tab
}
function Select-SpectralPage([int]$page) {
    if($page -ne 1 -and $null -ne $frequencyEdit.Tag){Complete-SpectralFrequency}
    foreach($control in $overviewPage){$control.Visible=$page -eq 0}
    foreach($control in $eqPage){$control.Visible=$page -eq 1}
    foreach($control in $diagnosticsPage){$control.Visible=$page -eq 2}
    for($i=0;$i -lt $nav.Count;$i++){
        $nav[$i].BackColor=if($i -eq $page){$script:SpectralAccent}else{$script:SpectralField}
        $nav[$i].ForeColor=if($i -eq $page){$script:SpectralBackground}else{$script:SpectralInk}
        $nav[$i].FlatAppearance.MouseOverBackColor=if($i -eq $page){[Drawing.Color]::FromArgb(145,242,211)}else{[Drawing.Color]::FromArgb(42,71,64)}
    }
}
foreach($tab in $nav){$tab.Add_Click({param($sender,$e) Select-SpectralPage $sender.Tag})}
$intro.Tag='muted';$message.Tag='muted'
$parentCards=@{}
foreach($pageControls in @($overviewPage,$eqPage,$diagnosticsPage)){
    $cards=@($pageControls | Where-Object {$_ -is [SpectralTheme.Card]})
    foreach($control in $pageControls){
        if($control -isnot [SpectralTheme.Card]){
            foreach($card in $cards){if($card.Bounds.Contains($control.Bounds)){$parentCards[$control]=$card;break}}
        }
    }
}
Set-SpectralTheme $form $apply $parentCards
$frequencyEdit=New-Object SpectralTheme.EqFrequencyInput
$frequencyEdit.TextAlign='Center';$frequencyEdit.MaxLength=5
$frequencyEdit.BackColor=$script:SpectralField;$frequencyEdit.ForeColor=$script:SpectralInk
$frequencyEdit.BorderStyle='FixedSingle';$frequencyEdit.Visible=$false
$eqCard.Controls.Add($frequencyEdit)
function Set-SpectralFrequency([int]$band,[int]$hz) {
    $frequencyOverrides[$band]=if($hz -eq $defaultFrequencies[$band]){0}else{$hz}
    $center=if($hz){$hz}else{$defaultFrequencies[$band]}
    $label=if($center -ge 1000 -and $center%1000 -eq 0){'{0} kHz' -f ($center/1000)}else{'{0} Hz' -f $center}
    $link=$frequencyLinks[$band]
    $link.Text=$label;$link.AccessibleName='编辑 '+$label+' 的中心频率'
    $link.LinkColor=if($frequencyOverrides[$band]){$script:SpectralAccent}else{$script:SpectralMuted}
    $eqFaders[$band].AccessibleName=$label+' 增益滑块'
    $eqValues[$band].AccessibleName=$label+' 增益（dB）'
}
function Complete-SpectralFrequency([switch]$Cancel) {
    if($null -eq $frequencyEdit.Tag){return}
    $band=[int]$frequencyEdit.Tag
    $frequencyEdit.Tag=$null
    $frequencyLinks[$band].Visible=$true
    $frequencyEdit.Hide()
    if($Cancel){return}
    $hz=0
    if(-not [int]::TryParse($frequencyEdit.Text,[ref]$hz) -or $hz -lt 20 -or $hz -gt 20000){
        $eqMessage.Text='请输入 20–20000 Hz 之间的整数。'
        return
    }
    $previous=$frequencyOverrides[$band]
    Set-SpectralFrequency $band $hz
    if($frequencyOverrides[$band] -ne $previous){Queue-SpectralEqualizer}
}
foreach($link in $frequencyLinks){
    $link.ActiveLinkColor=$script:SpectralAccent
    $link.Add_LinkClicked({
        param($sender,$eventArgs)
        Complete-SpectralFrequency
        $band=[int]$sender.Tag
        $frequencyEdit.Tag=$band
        $frequencyEdit.Text=if($frequencyOverrides[$band]){[string]$frequencyOverrides[$band]}else{[string]$defaultFrequencies[$band]}
        $frequencyEdit.AccessibleName=$sender.Text+' 中心频率（Hz）'
        $frequencyEdit.SetBounds(($sender.Left+4),($sender.Top-2),($sender.Width-8),$sender.Height)
        $frequencyEdit.Show();$frequencyEdit.Focus() | Out-Null;$frequencyEdit.SelectAll()
        $sender.Visible=$false
    })
    Set-SpectralFrequency $link.Tag 0
}
$frequencyEdit.Add_Leave({Complete-SpectralFrequency})
$frequencyEdit.Add_KeyDown({
    param($sender,$e)
    if($e.KeyCode -eq [Windows.Forms.Keys]::Enter -or $e.KeyCode -eq [Windows.Forms.Keys]::Escape){
        $band=$sender.Tag
        Complete-SpectralFrequency -Cancel:($e.KeyCode -eq [Windows.Forms.Keys]::Escape)
        if($null -ne $band){$frequencyLinks[$band].Focus() | Out-Null}
        $e.SuppressKeyPress=$true
    }
})
$restoreFrequency.Add_Click({
    $band=[int]$frequencyMenu.SourceControl.Tag
    if($frequencyOverrides[$band]){Set-SpectralFrequency $band 0;Queue-SpectralEqualizer}
})
Select-SpectralPage 0
Add-SpectralHeader $form 'Spectral Audio  /  频谱音频增强 1.1.0'
$projectLink=New-Object Windows.Forms.LinkLabel
$projectLink.Name='ProjectLink';$projectLink.Text='查看更新 · 反馈问题 · 给作者点star'
$projectLink.SetBounds(396,609,400,26);$projectLink.Anchor='Bottom,Right';$projectLink.TextAlign='MiddleRight'
$projectLink.LinkColor=$script:SpectralAccent;$projectLink.ActiveLinkColor=$script:SpectralInk;$projectLink.VisitedLinkColor=$script:SpectralAccent
$projectLink.BackColor=$script:SpectralBackground
$projectLink.Add_LinkClicked({
    try{Start-Process 'https://github.com/white-give-man/spectral-audio'}catch{$message.Text='无法打开项目主页：'+$_.Exception.Message}
})
$form.Controls.Add($projectLink)
$script:modelLevel=4;$script:prior=@{};$script:wanted=$null
$settingsPath=Join-Path $state 'panel-settings.json'
$script:eqLoading=$false;$script:eqWanted=$null;$script:eqPending=$false;$script:eqBypassed=$false
$eqTimer=New-Object Windows.Forms.Timer
$eqTimer.Interval=100
function Update-SpectralEqualizer {
    $active=$eqEnabled.Checked -and -not $script:eqBypassed
    foreach($fader in $eqFaders){$fader.Active=$active;$fader.Invalidate()}
    if($script:eqPending){$eqMessage.Text='正在保存调整…'}
    elseif($script:eqBypassed){$eqMessage.Text='恢复原音已开启。EQ 调整会保存，恢复增强后生效。'}
    elseif($null -ne $script:eqWanted){$eqMessage.Text='调整已保存，播放声音后确认生效。'}
    elseif($eqEnabled.Checked){$eqMessage.Text='EQ 已开启'}
    else{$eqMessage.Text='EQ 已关闭，频段设置已保留。'}
}
function Publish-SpectralEqualizer {
    $eqTimer.Stop()
    if(-not $script:eqPending){return}
    $script:eqPending=$false
    try{
        $bands=@($eqValues | ForEach-Object {[int]($_.Value*100)})
        $result=& $cli eq ([int]$eqEnabled.Checked) @bands @frequencyOverrides
        if($LASTEXITCODE){throw 'EQ 设置保存失败。请调整任一频段后重试。'}
        $script:eqWanted=($result | ConvertFrom-Json).eq_revision
        Update-SpectralEqualizer
    }catch{$eqMessage.Text=$_.Exception.Message}
}
function Queue-SpectralEqualizer {
    if($script:eqLoading){return}
    $script:eqPending=$true
    Update-SpectralEqualizer
    if(-not $eqTimer.Enabled){$eqTimer.Start()}
}
$eqTimer.Add_Tick({Publish-SpectralEqualizer})
foreach($fader in $eqFaders){
    $fader.Add_ValueChanged({param($sender,$e) $eqValues[$sender.Tag].Value=[decimal]$sender.Value/100})
}
foreach($value in $eqValues){
    $value.Add_ValueChanged({param($sender,$e)
        $eqFaders[$sender.Tag].Value=[int]($sender.Value*100)
        Queue-SpectralEqualizer
    })
}
$eqEnabled.Add_CheckedChanged({Queue-SpectralEqualizer})
$eqReset.Add_Click({
    $script:eqLoading=$true
    try{foreach($value in $eqValues){$value.Value=0}}finally{$script:eqLoading=$false}
    Queue-SpectralEqualizer;Publish-SpectralEqualizer
})
try{
    $r=(& $cli status | ConvertFrom-Json);if($r.error -ne 0){throw '尚无运行状态文件。安装后再读取。'};$word=[uint32]$r.settings

    $drcCode=[int]([uint64]$word -shr 29)
    $drcEnabled.Checked=$drcCode -gt 0
    $drcMode.SelectedIndex=if($drcCode -ge 1 -and $drcCode -le 5){$drcCode-1}else{0}
    if($drcCode -eq 0 -and (Test-Path -LiteralPath $settingsPath)){
        try{
            $savedPanel=Read-SpectralJson $settingsPath
            if($null -ne $savedPanel.drc_mode -and $savedPanel.drc_mode -ge 0 -and $savedPanel.drc_mode -le 4){$drcMode.SelectedIndex=[int]$savedPanel.drc_mode}
        }catch{}
    }
    $selected=[int](($word -band 3) -bor (($word -shr 13) -band 4))
    $strength.Value=if($word -band (1 -shl 27)){[decimal]([Math]::Min(2000,((($word -shr 17) -band 1023) -bor (($word -shr 18) -band 1024)))/10.0)}else{100}
    Select-SpectralGame $selected;Set-SpectralGainMilli ([int](($word -shr 5) -band 1023));$bypass.Checked=($word -band 16) -ne 0
    $script:eqLoading=$true
    try{
        $script:eqBypassed=$bypass.Checked
        if($r.eq.bands.Count -eq $eqValues.Count){
            for($i=0;$i -lt $eqValues.Count;$i++){$eqValues[$i].Value=[decimal]$r.eq.bands[$i]/100}
            $eqEnabled.Checked=$r.eq.enabled
            if($r.eq.frequencies_hz.Count -eq $frequencyLinks.Count){
                for($i=0;$i -lt $frequencyLinks.Count;$i++){Set-SpectralFrequency $i $r.eq.frequencies_hz[$i]}
            }
        }
    }finally{$script:eqLoading=$false}
}catch{Select-SpectralGame 2;$strength.Value=100;Set-SpectralGainMilli 1000;$details.Text=$_.Exception.Message}
Update-SpectralEqualizer
$apply.Add_Click({
    try{
        $gameId=$script:gameOptions[$game.SelectedIndex].Id
        if(-not @($script:modelCatalog | Where-Object {$_.game -eq $gameId -and $_.level -eq $script:modelLevel -and $_.available}).Count){throw '此游戏暂未接入模型。当前版本支持三角洲 / Delta Force。'}
        $word=[uint32](($gameId -band 3) -bor (($gameId -band 4) -shl 13) -bor (($script:modelLevel -band 3) -shl 2) -bor (($script:modelLevel -band 4) -shl 14) -bor ([int]$bypass.Checked -shl 4) -bor ($(if($mute.Checked){0}else{$script:gainMilli}) -shl 5) -bor $(if($strength.Value -eq 100){0}else{(([int]($strength.Value*10) -band 1023) -shl 17) -bor (([int]($strength.Value*10) -band 1024) -shl 18) -bor (1 -shl 27)}))
        $drcCode=if($drcEnabled.Checked){$drcMode.SelectedIndex+1}else{0}
        $word=[uint32]([uint64]$word + [uint64]$drcCode*536870912)
        $result=& $cli set ([string]$word);if($LASTEXITCODE){throw "设置未发布：$result"}
        @{strength_milli=[int]($strength.Value*10);drc_enabled=$drcEnabled.Checked;drc_mode=$drcMode.SelectedIndex;settings=$word} | ConvertTo-Json | Set-Content $settingsPath -Encoding UTF8
        $script:wanted=$word;$message.Text='参数已发布，等待目标端点的 audiodg 处理回调确认。'
    }catch{$message.Text=$_.Exception.Message}
})
$timer=New-Object Windows.Forms.Timer;$timer.Interval=1000
$timer.Add_Tick({
    try{
        $activeInstall=Join-Path $state 'install.json'
        if(-not(Test-Path $activeInstall) -or (Read-SpectralJson $activeInstall).directory -ne $Directory){$form.Close();return}
        $r=& $cli status | ConvertFrom-Json
        $bypassed=($r.settings -band 16) -ne 0
        if($script:eqBypassed -ne $bypassed){$script:eqBypassed=$bypassed;Update-SpectralEqualizer}
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
            if($null -ne $script:eqWanted -and $s.eq_revision -eq $script:eqWanted){
                $script:eqWanted=$null
                Update-SpectralEqualizer
                if($eqEnabled.Checked -and -not $script:eqBypassed -and -not $script:eqPending){$eqMessage.Text='EQ 调整已由当前输出设备的 DSP 确认。'}
            }
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
    Publish-SpectralEqualizer
    $timer.Stop();$form.Enabled=$false
    try{
        [Windows.Forms.Application]::DoEvents()
        $diagnosticsMessage.Text='正在播放低音量测试信号并重建音频图，约 1 分钟。请暂停其他音频。'
        $p=Start-Process "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $Directory 'Manage-SpectralAudio.ps1')+'"'),'-Action','Verify','-SessionToken',$SessionToken,'-NoUI','-NoPanel') -WindowStyle Hidden -PassThru
        $heldHandle=$p.Handle
        while(-not $p.HasExited){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 100}
        $diagnosticsMessage.Text=if($p.ExitCode -eq 0){'验证完成，结果已记录。'}else{'验证未通过，请查看诊断记录。'}
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
        Publish-SpectralEqualizer
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
$form.Add_FormClosing({Complete-SpectralFrequency;Publish-SpectralEqualizer})
$form.Add_FormClosed({$frequencyTip.Dispose();$frequencyMenu.Dispose();$eqTimer.Stop();$eqTimer.Dispose();$timer.Stop();$timer.Dispose();$panelMutex.ReleaseMutex();$panelMutex.Dispose()})
if($SelfTest){try{Refresh-SpectralTargets}catch{$message.Text=$_.Exception.Message}}
if($SelfTest){
    $form.StartPosition='Manual';$form.Location=New-Object Drawing.Point(-30000,-30000);$form.Show()
    foreach($page in @(@(0,'panel-preview.png'),@(1,'panel-eq-preview.png'))){
        Select-SpectralPage $page[0];[Windows.Forms.Application]::DoEvents()
        $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
        try{
            $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
            $bitmap.Save((Join-Path $Directory $page[1]))
        }finally{$bitmap.Dispose()}
    }
    $form.Close();$form.Dispose();exit 0
}
try{Refresh-SpectralTargets}catch{$message.Text='设备列表读取失败，可点击刷新：'+$_.Exception.Message}
$script:uninstallRequested=$false
$timer.Start();[void]$form.ShowDialog();$form.Dispose()
if($script:uninstallRequested){Write-Output 'Uninstall'}


