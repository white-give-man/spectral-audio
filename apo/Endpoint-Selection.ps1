# Shared by setup and tests. Only active render endpoints are offered.
function Get-SpectralEndpoints([string]$directory) {
    $temporary=Join-Path $env:TEMP ('spectral-endpoints-'+[guid]::NewGuid().ToString('N'))
    $process=$null
    try {
        $process=Start-Process (Join-Path $directory 'spectral_apo_measure.exe') -ArgumentList '--list' -WindowStyle Hidden -PassThru -RedirectStandardOutput ($temporary+'.json') -RedirectStandardError ($temporary+'.error')
        $heldHandle=$process.Handle
        if(-not $process.WaitForExit(15000)){$process.Kill();$process.WaitForExit();throw '读取音频输出超过 15 秒。请重新连接声卡，确认 Windows 音频服务正常后重试。'}
        if($process.ExitCode){throw ('无法枚举音频输出设备，请确认 Windows 音频服务已启动。'+[IO.File]::ReadAllText($temporary+'.error'))}
        $json=[IO.File]::ReadAllText($temporary+'.json')
        foreach($device in ($json | ConvertFrom-Json)){$device}
    }finally{
        if($process){$process.Dispose()}
        foreach($suffix in @('.json','.error')){if(Test-Path -LiteralPath ($temporary+$suffix)){Remove-Item -LiteralPath ($temporary+$suffix) -Force}}
    }
}
function Get-SpectralEndpointGuid([string]$id) {
    # Windows 11 MMDevices registry layout. Reject unknown layouts before writing.
    if($id -notmatch '^\{0\.0\.0\.00000000\}\.(\{[0-9a-fA-F-]{36}\})$'){throw '不支持此输出设备的端点 ID 格式，未修改音频设备。'}
    return ([guid]$Matches[1]).ToString('B')
}
function Assert-SpectralEndpoint($device) {
    if($device.rate -ne 48000 -or $device.channels -ne 2){throw '请先在 Windows 声音设置中将所选输出设置为 48000 Hz、双声道（立体声），然后重新安装。'}
    if($device.sysfx_disabled){throw '所选输出关闭了系统音频增强。请在 Windows 声音设置中启用“音频增强 / 设备默认效果”，然后重新安装。'}
    $null=Get-SpectralEndpointGuid $device.id
}
function Select-SpectralEndpoint($devices,[string]$requested,[switch]$NoUI,[string]$PreviewPath) {
    $list=@($devices)
    if($requested){
        $match=@($list | Where-Object id -eq $requested)
        if($match.Count -ne 1){throw '所选输出不存在或未连接。请连接设备后重新安装。'}
        Assert-SpectralEndpoint $match[0];return $match[0]
    }
    if($NoUI){throw '无人值守安装必须通过 -EndpointId 明确指定本机输出；可先使用 -Action List 列出设备。'}
    if(-not $list.Count){throw '未发现已连接的音频输出。请先连接耳机、音箱或声卡。'}
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    . (Join-Path $PSScriptRoot 'SpectralAudio-Theme.ps1')
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='Spectral Audio 安装 · 选择输出设备';$dialog.ClientSize=New-Object Drawing.Size(740,390)
    $dialog.StartPosition='CenterScreen';$dialog.FormBorderStyle='FixedDialog';$dialog.MaximizeBox=$false
    $dialog.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
    $intro=New-Object Windows.Forms.Label;$intro.Text="选择实际连接耳机或音箱的输出。安装后，游戏也需使用这个输出。`r`n验证会播放测试音并短暂重启系统音频，请先暂停其他音频。"
    $intro.SetBounds(48,126,644,55);$dialog.Controls.Add($intro)
    $combo=New-Object Windows.Forms.ComboBox;$combo.DropDownStyle='DropDownList';$combo.SetBounds(48,198,644,35)
    foreach($device in $list){$tag=if($device.is_default){' [默认]'}else{''};$null=$combo.Items.Add(('{0}{1} · {2} Hz / {3} 声道' -f $device.name,$tag,$device.rate,$device.channels))}
    $combo.SelectedIndex=0
    for($i=0;$i -lt $list.Count;$i++){if($list[$i].is_default){$combo.SelectedIndex=$i;break}}
    $dialog.Controls.Add($combo)
    $hint=New-Object Windows.Forms.Label;$hint.Text='需要 48 kHz、双声道，并启用 Windows 音频增强。每次只安装到一个输出。';$hint.SetBounds(48,250,644,45);$dialog.Controls.Add($hint)
    $ok=New-Object Windows.Forms.Button;$ok.Text='安装并验证';$ok.SetBounds(426,328,146,38);$dialog.Controls.Add($ok)
    $cancel=New-Object Windows.Forms.Button;$cancel.Text='取消';$cancel.DialogResult='Cancel';$cancel.SetBounds(588,328,128,38);$dialog.Controls.Add($cancel);$dialog.CancelButton=$cancel
    $null=New-SpectralCard $dialog 24 100 692 208
    $hint.Tag='muted'
    Set-SpectralTheme $dialog $ok
    Add-SpectralHeader $dialog '耳机增强  /  选择实际连接耳机或音箱的输出'
    $dialog.AcceptButton=$ok
    $ok.Add_Click({
        try{Assert-SpectralEndpoint $list[$combo.SelectedIndex];$dialog.DialogResult='OK';$dialog.Close()}
        catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Spectral Audio') | Out-Null}
    })
    if($PreviewPath){
        $dialog.StartPosition='Manual';$dialog.Location=New-Object Drawing.Point(-30000,-30000);$dialog.Show();[Windows.Forms.Application]::DoEvents()
        $bitmap=New-Object Drawing.Bitmap($dialog.Width,$dialog.Height);$dialog.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$dialog.Width,$dialog.Height)));$bitmap.Save($PreviewPath);$bitmap.Dispose();$dialog.Close();$dialog.Dispose();return
    }
    $result=$dialog.ShowDialog();$selected=$combo.SelectedIndex;$dialog.Dispose()
    if($result -ne 'OK'){throw '已取消安装，未修改音频设备。'}
    return $list[$selected]
}
