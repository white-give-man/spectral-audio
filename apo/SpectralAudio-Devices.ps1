# Per-output preparation and switching. The manager holds SpectralAudio.Setup throughout.
function Save-SpectralInstall($installed) {
    Write-SpectralAtomicJson $installed $record
}
function Ensure-SpectralBackup {
    $before=@(Read-Fx)
    if(-not(Test-Path -LiteralPath $original)){
        if(Test-SpectralLinked){throw '此输出有 Spectral 关联但缺少本机原始备份。请先用旧版卸载器恢复。'}
        $managed=@(foreach($name in $managedNames){$v=$before | Where-Object name -eq $name;if($v){$v}else{@{name=$name;present=$false;kind=$null;value=$null}}})
        Json-Write @{endpoint=$endpoint;captured_at=(Get-Date -Format o);full_chain=$before;managed_values=$managed} $original
    }
    $baseline=Get-Content -LiteralPath $original -Raw -Encoding UTF8 | ConvertFrom-Json
    if($baseline.endpoint -ne $endpoint){throw 'Original backup endpoint mismatch.'}
    if(@($baseline.managed_values).Count -lt $managedNames.Count){
        $extended=@($baseline.managed_values)
        foreach($name in $managedNames){
            if($name -notin @($extended | ForEach-Object name)){
                $value=$baseline.full_chain | Where-Object name -eq $name
                if($value){$extended+=,$value}else{$extended+=,@{name=$name;present=$false;kind=$null;value=$null}}
            }
        }
        Json-Write @{endpoint=$endpoint;captured_at=$baseline.captured_at;full_chain=$baseline.full_chain;managed_values=$extended} $extendedOriginal
        $script:original=$extendedOriginal
    }
}
function Save-SpectralDeviceVerification([string]$directory,$verification) {
    Json-Write @{dll_sha256=(Get-FileHash -LiteralPath (Join-Path $directory 'SpectralAudio.dll')).Hash;verification=$verification} (Join-Path (Split-Path $hookPath) 'verification.json')
}
function Get-SpectralDeviceVerification([string]$directory) {
    $path=Join-Path (Split-Path $hookPath) 'verification.json'
    if(-not(Test-Path -LiteralPath $path)){return}
    $cached=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if($cached.dll_sha256 -eq (Get-FileHash -LiteralPath (Join-Path $directory 'SpectralAudio.dll')).Hash -and
       $cached.verification.complete -and $cached.verification.endpoint -eq $endpoint -and $cached.verification.hook_strategy -eq $script:strategy){return $cached.verification}
}
function Invoke-SpectralSwitch([string]$id,[string]$token) {
    $installed=Get-Installed;$current=Get-SpectralSession
    if(-not $current -or $current.token -ne $token -or $current.phase -ne 'active' -or -not(Test-SpectralSessionOwner $current)){
        throw '增强会话已结束或正在切换，未更改设备。'
    }
    if($current.directory -ne $installed.directory -or $current.endpoint -ne $installed.endpoint){throw 'Session and installation target mismatch.'}
    $selected=Select-SpectralEndpoint (Get-SpectralEndpoints $installed.directory) $id -NoUI
    if($selected.id -eq $installed.endpoint){return}
    $old=$installed.PSObject.Copy();$newReady=$false;$switchStarted=$false
    try {
        # Preflight the new output before touching the currently working one.
        Initialize-Target $selected.id $selected.name
        Ensure-SpectralBackup
        Assert-SpectralOriginalChain
        $newReady=$true
        $targets=@($current.targets | Where-Object {$_ -and $_.endpoint})
        if(-not $targets.Count){$targets=@([pscustomobject]@{endpoint=$old.endpoint;name=$old.endpoint_name})}
        if($selected.id -notin @($targets | ForEach-Object endpoint)){$targets+=,[pscustomobject]@{endpoint=$selected.id;name=$selected.name}}
        $current | Add-Member NoteProperty targets $targets -Force
        $current.phase='switching';Save-SpectralSession $current;$switchStarted=$true
        Initialize-Target $old.endpoint $old.endpoint_name
        Write-SpectralProgress '正在恢复旧设备的原效果链，声音会短暂中断…'
        Restore-SpectralChain
        Initialize-Target $selected.id $selected.name
        $verification=Get-SpectralDeviceVerification $installed.directory
        if(-not $verification){
            Write-SpectralProgress '首次使用此输出，正在验证处理路径，可能需要 1–3 分钟…'
            $verification=Verify-Installed $installed.directory
            Save-SpectralDeviceVerification $installed.directory $verification
            if(-not $verification.complete){throw ('新设备处理验证未通过：'+$verification.failure)}
        }
        # A dead owner must not leave the newly validated graph attached.
        if(-not(Test-SpectralSessionOwner (Get-SpectralSession))){throw '切换期间控制台已退出，正在恢复原链路。'}
        Write-SpectralProgress '正在接入新的增强目标…'
        Rebuild-Graph {Set-Association DSP}
        $installed.endpoint=$selected.id;$installed.endpoint_name=$selected.name;$installed.original_backup=$original
        Save-SpectralInstall $installed
        $current.endpoint=$selected.id;$current.phase='active';$current.error=$null;$current.targets=@([pscustomobject]@{endpoint=$selected.id;name=$selected.name})
        Save-SpectralSession $current
        Json-Write $verification (Join-Path $state 'latest-verification.json')
        Write-SpectralProgress ('已切换增强目标：'+$selected.name+'。Windows 默认播放设备未更改。')
    }catch{
        $failure=$_.Exception.Message
        if($switchStarted){
            try {
                # Re-arm both targets before rollback, including failures after commit.
                $current=Get-SpectralSession
                $current.targets=@([pscustomobject]@{endpoint=$old.endpoint;name=$old.endpoint_name},[pscustomobject]@{endpoint=$selected.id;name=$selected.name})
                $current.phase='switching';Save-SpectralSession $current
                if($newReady){Initialize-Target $selected.id $selected.name;Restore-SpectralChain}
                Initialize-Target $old.endpoint $old.endpoint_name;Restore-SpectralChain
                Save-SpectralInstall $old
                if(Test-SpectralSessionOwner (Get-SpectralSession)){
                    $null=Select-SpectralEndpoint (Get-SpectralEndpoints $old.directory) $old.endpoint -NoUI
                    Rebuild-Graph {Set-Association DSP}
                    $current.endpoint=$old.endpoint;$current.phase='active';$current.error=$null;$current.targets=@([pscustomobject]@{endpoint=$old.endpoint;name=$old.endpoint_name});Save-SpectralSession $current
                    $prior=Get-SpectralDeviceVerification $old.directory
                    if($prior){Json-Write $prior (Join-Path $state 'latest-verification.json')}
                }else{Stop-SpectralSession $token}
            }catch{
                $current.phase='recovery_failed';$current.error=$failure+'; '+$_.Exception.Message;Save-SpectralSession $current
                throw ('切换失败，自动恢复尚未完成，请退出控制台重试恢复。'+$current.error)
            }
            throw ('切换失败，已恢复原增强设备或退出链路。'+$failure)
        }
        throw $failure
    }finally{
        $active=Get-Installed;Initialize-Target $active.endpoint $active.endpoint_name
    }
}
