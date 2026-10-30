# Lifecycle helpers. Callers serialize every graph mutation with SpectralAudio.Setup.
function Read-SpectralJson([string]$path,[switch]$AllowMissing) {
    # Readers allow atomic replacement while retaining their complete old snapshot.
    for($attempt=0;$attempt -lt 20;$attempt++){
        $stream=$null;$reader=$null
        try{
            $share=[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            $stream=New-Object IO.FileStream($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$share)
            $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
            return $reader.ReadToEnd() | ConvertFrom-Json
        }catch [IO.FileNotFoundException]{if($attempt -eq 19){if($AllowMissing){return};throw};Start-Sleep -Milliseconds 50}
        catch [IO.IOException]{if($attempt -eq 19){throw};Start-Sleep -Milliseconds 50}
        finally{if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}}
    }
}
function Write-SpectralAtomicJson($object,[string]$path) {
    $temporary=$path+'.'+$PID+'.tmp'
    try{
        [IO.File]::WriteAllText($temporary,($object | ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($true)))
        for($attempt=0;$attempt -lt 20;$attempt++){
            try{
                if(Test-Path -LiteralPath $path){[IO.File]::Replace($temporary,$path,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temporary,$path)}
                return
            }catch [IO.IOException]{if($attempt -eq 19){throw};Start-Sleep -Milliseconds 50}
        }
    }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
}
function Get-SpectralSession {
    $path=Join-Path $state 'session.json'
    return Read-SpectralJson $path -AllowMissing
}
function Save-SpectralSession($session) {Write-SpectralAtomicJson $session (Join-Path $state 'session.json')}
function Test-SpectralSessionOwner($session) {
    if(-not $session -or $session.phase -eq 'inactive'){return $false}
    $ownerProcess=$null
    try {
        $ownerProcess=Get-Process -Id $session.owner_pid -ErrorAction Stop
        return (-not $ownerProcess.HasExited -and $ownerProcess.StartTime.ToUniversalTime().Ticks -eq [long]$session.owner_started_ticks)
    }catch{return $false}finally{if($ownerProcess){$ownerProcess.Dispose()}}
}
function Enter-SpectralSetup([int]$milliseconds=60000) {
    $mutex=New-Object Threading.Mutex($false,'Global\SpectralAudio.Setup')
    try {
        try{$acquired=$mutex.WaitOne($milliseconds)}catch [Threading.AbandonedMutexException]{$acquired=$true}
        if(-not $acquired){throw '另一个 Spectral 操作尚未结束，请稍后重试。'}
        return $mutex
    }catch{$mutex.Dispose();throw}
}
function Assert-SpectralOriginalChain {
    $backup=Get-Content -LiteralPath $original -Raw -Encoding UTF8 | ConvertFrom-Json
    if($backup.endpoint -ne $endpoint){throw 'Backup endpoint mismatch.'}
    $actual=@(Read-Fx)
    foreach($expected in $backup.managed_values){
        $found=@($actual | Where-Object name -eq $expected.name)
        if(-not $expected.present){if($found.Count){throw ('原链路恢复校验失败：'+$expected.name)};continue}
        if($found.Count -ne 1 -or $found[0].kind -ne $expected.kind -or
            (ConvertTo-Json -InputObject $found[0].value -Compress) -cne (ConvertTo-Json -InputObject $expected.value -Compress)){
            throw ('原链路恢复校验失败：'+$expected.name)
        }
    }
    foreach($item in $actual){if(@($item.value | Where-Object {$_ -in @($dsp,$unity)}).Count){throw '恢复后仍存在 Spectral 音频关联。'}}
}
function Restore-SpectralChain {
    Rebuild-Graph {Set-Association Restore}
    Assert-SpectralOriginalChain
}
function Test-SpectralLinked {
    foreach($item in (Read-Fx)){if(@($item.value | Where-Object {$_ -in @($dsp,$unity)}).Count){return $true}}
    return $false
}
function Register-SpectralRecovery([string]$directory) {
    # A startup recovery also covers power loss or termination of both processes.
    $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $directory 'Manage-SpectralAudio.ps1')+'" -Action Recover -NoUI -NoPanel'
    $taskAction=New-ScheduledTaskAction -Execute "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $arguments
    $trigger=New-ScheduledTaskTrigger -AtStartup
    $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    $null=Register-ScheduledTask -TaskName 'SpectralAudio-Recover' -Action $taskAction -Trigger $trigger -Settings $settings -User 'SYSTEM' -RunLevel Highest -Force
}
function Stop-SpectralSession([string]$token) {
    $current=Get-SpectralSession
    # An old watcher must never detach a newer control session or installation.
    if(-not $current -or $current.token -ne $token -or $current.phase -eq 'inactive'){return}
    $installed=Get-Installed
    $targets=@($current.targets | Where-Object {$_ -and $_.endpoint})
    if($current.directory -ne $installed.directory -or
       ($targets.Count -eq 0 -and $current.endpoint -ne $endpoint) -or
       ($targets.Count -gt 0 -and $installed.endpoint -notin @($targets | ForEach-Object endpoint))){throw 'Session target differs from installed target; recovery refused.'}
    try {
        if($targets.Count){
            $failures=@()
            try{
                foreach($target in $targets){
                    try{Initialize-Target $target.endpoint $target.name;Restore-SpectralChain}
                    catch{$failures+=,$_.Exception.Message}
                }
            }finally{Initialize-Target $installed.endpoint $installed.endpoint_name}
            if($failures.Count){throw ($failures -join '; ')}
        }else{Restore-SpectralChain}
        $current.phase='inactive';$current.error=$null;$current.restored_at=(Get-Date -Format o)
        Save-SpectralSession $current
    }catch{
        $current.phase='recovery_failed';$current.error=$_.Exception.Message;Save-SpectralSession $current
        throw
    }
}
function Recover-SpectralSession {
    $current=Get-SpectralSession
    if($current -and $current.phase -ne 'inactive' -and -not(Test-SpectralSessionOwner $current)){Stop-SpectralSession $current.token}
}
function Start-SpectralWatch([string]$directory,[string]$token) {
    $ready=Join-Path $state ('watch-'+$token+'.ready')
    $watch=Start-Process "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $directory 'Manage-SpectralAudio.ps1')+'"'),'-Action','Watch','-SessionToken',$token,'-NoUI')
    $heldHandle=$watch.Handle
    try {
        $deadline=[DateTime]::UtcNow.AddSeconds(15)
        while(-not(Test-Path -LiteralPath $ready)){
            if($watch.HasExited -or [DateTime]::UtcNow -gt $deadline){throw '恢复监护进程未就绪，未启动增强。'}
            Start-Sleep -Milliseconds 100
        }
        Remove-Item -LiteralPath $ready -Force
    }finally{$watch.Dispose()}
}
function Invoke-SpectralWatch([string]$token) {
    if($token -notmatch '^[0-9a-f]{32}$'){throw 'Invalid session token.'}
    $current=Get-SpectralSession
    if(-not $current -or $current.token -ne $token -or $current.phase -eq 'inactive'){return}
    $ready=Join-Path $state ('watch-'+$token+'.ready')
    try {
        [IO.File]::WriteAllText($ready,[string]$PID)
        while($true){
            $current=Get-SpectralSession
            if(-not $current -or $current.token -ne $token -or $current.phase -eq 'inactive'){return}
            if(-not(Test-SpectralSessionOwner $current)){break}
            Start-Sleep -Milliseconds 500
        }
        # Retry transient service / setup contention. Keep failed state for next launch.
        for($attempt=0;$attempt -lt 3;$attempt++){
            $guard=$null
            try{
                $guard=Enter-SpectralSetup
                $installed=Get-Installed
                Initialize-Target $installed.endpoint $installed.endpoint_name
                Stop-SpectralSession $token
                return
            }catch{Write-Warning $_.Exception.Message;if($attempt -eq 2){throw}}
            finally{if($guard){$guard.ReleaseMutex();$guard.Dispose()}}
            Start-Sleep -Seconds 2
        }
    }finally{if(Test-Path -LiteralPath $ready){Remove-Item -LiteralPath $ready -Force}}
}
function Invoke-SpectralControl([string]$directory) {
    $token=[guid]::NewGuid().ToString('N');$created=$false
    try {
        $guard=Enter-SpectralSetup
        try {
            Recover-SpectralSession
            $verification=Get-Content -LiteralPath (Join-Path $state 'latest-verification.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            if(-not $verification.complete -or $verification.endpoint -ne $endpoint){throw '本输出尚未通过处理验证。请重新安装或运行自动验证。'}
            $devices=Get-SpectralEndpoints $directory
            $null=Select-SpectralEndpoint $devices $endpoint -NoUI
            $session=[pscustomobject]@{token=$token;owner_pid=$PID;owner_started_ticks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks;endpoint=$endpoint;directory=$directory;targets=@([pscustomobject]@{endpoint=$endpoint;name=$endpointName});phase='starting';error=$null;restored_at=$null}
            Save-SpectralSession $session;$created=$true
            # Arm recovery before the first association change.
            Start-SpectralWatch $directory $token
            Write-SpectralProgress '正在接入 Spectral，系统声音会短暂中断…'
            Rebuild-Graph {Set-Association DSP}
            $session.phase='active';Save-SpectralSession $session
        }finally{$guard.ReleaseMutex();$guard.Dispose()}
        $panelResult=@(& (Join-Path $directory 'SpectralAudio-Panel.ps1') -Directory $directory -SessionToken $token)
        $script:spectralUninstallRequested='Uninstall' -in $panelResult
    }finally{
        if($created){
            $guard=Enter-SpectralSetup
            try{Write-SpectralProgress '正在退出并恢复原效果链…';Stop-SpectralSession $token}
            finally{$guard.ReleaseMutex();$guard.Dispose()}
        }
    }
}
