param([ValidateSet('Install','Verify','Uninstall','Control','Status','List','Watch','Recover','Switch')][string]$Action='Install', [switch]$NoUI, [string]$EndpointId, [switch]$NoPanel, [string]$ProgressFile, [string]$SessionToken)
$ErrorActionPreference='Stop'
if(-not $NoUI){. (Join-Path $PSScriptRoot 'SpectralAudio-Host.ps1');Hide-SpectralConsole}
function Write-SpectralProgress([string]$message) {
    Write-Host $message
    if($ProgressFile){[IO.File]::WriteAllText($ProgressFile,$message,(New-Object Text.UTF8Encoding($true)))}
}
if(-not [Environment]::Is64BitProcess){throw 'Spectral Audio requires 64-bit PowerShell.'}
. (Join-Path $PSScriptRoot 'Endpoint-Selection.ps1')
$endpoint=$null;$endpointGuid=$null;$endpointName=$null;$fx=$null
$efx='{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},7'
$modes='{d3993a3f-99c2-4402-b5ec-a92a0367664b},7'
$compositeEFX='{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},15'
$compositeMFX='{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},14'
$legacyMFX='{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},6'
$managedNames=@($efx,$modes,$compositeEFX,$compositeMFX,$legacyMFX)
$dsp='{b128a761-27bf-49df-a512-68d7e0921001}'
$unity='{b128a761-27bf-49df-a512-68d7e0921002}'
$state=Join-Path $env:ProgramData 'SpectralAudio'
$installRoot=Join-Path $env:ProgramFiles 'SpectralAudio'
$runtime=Join-Path $state 'runtime-v2.bin'
$record=Join-Path $state 'install.json'
$original=$null;$extendedOriginal=$null;$hookPath=$null
$script:strategy='EFX'
. (Join-Path $PSScriptRoot 'SpectralAudio-Session.ps1')
. (Join-Path $PSScriptRoot 'SpectralAudio-Devices.ps1')
if($Action -eq 'List'){ConvertTo-Json -InputObject @(Get-SpectralEndpoints $PSScriptRoot) -Depth 5;exit}
$isAdmin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if($Action -ne 'Status' -and -not $isAdmin) {
    $arguments=@('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"'),'-Action',$Action)
    if($NoUI){$arguments+='-NoUI'}
    if($NoPanel){$arguments+='-NoPanel'}
    if($ProgressFile){$arguments+=@('-ProgressFile',('"'+$ProgressFile+'"'))}
    if($SessionToken){if($SessionToken -notmatch '^[0-9a-f]{32}$'){throw 'Invalid session token.'};$arguments+=@('-SessionToken',$SessionToken)}
    if($EndpointId){$null=Get-SpectralEndpointGuid $EndpointId;$arguments+=@('-EndpointId',('"'+$EndpointId+'"'))}
    $p=Start-Process "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -WindowStyle Minimized -Wait -PassThru -ArgumentList $arguments
    exit $p.ExitCode
}
function Json-Write($object,[string]$path) { ConvertTo-Json -InputObject $object -Depth 20 | Set-Content -LiteralPath $path -Encoding UTF8 }
function Assert-SafeDirectory([string]$path) {
    if(Test-Path -LiteralPath $path){if((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Reparse point refused: $path"}}
    else{New-Item -ItemType Directory -Path $path -Force | Out-Null}
}
function Protect-Directory([string]$path) {
    Assert-SafeDirectory $path
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach($rule in @(@('S-1-5-18','FullControl'),@('S-1-5-32-544','FullControl'),@('S-1-5-32-545','ReadAndExecute'),@('S-1-5-19','ReadAndExecute'),@('S-1-5-12','ReadAndExecute'))){
        $sid=New-Object Security.Principal.SecurityIdentifier($rule[0])
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,$rule[1],'ContainerInherit,ObjectInherit','None','Allow')))
    }
    Set-Acl -LiteralPath $path -AclObject $acl
}
function Runtime-ACL {
    $acl=Get-Acl -LiteralPath $runtime
    foreach($sidText in @('S-1-5-19','S-1-5-12')){$sid=New-Object Security.Principal.SecurityIdentifier($sidText);$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'Modify','Allow')))}
    Set-Acl -LiteralPath $runtime -AclObject $acl
}
function Open-Fx {
    if(-not ('SpectralEndpointRegistry' -as [type])) {Add-Type -TypeDefinition (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'SpectralEndpointRegistry.cs'))}
    $k=$null
    try{$k=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($fx,$true)}catch{}
    if($null -eq $k){$k=[SpectralEndpointRegistry]::OpenEndpoint($endpointGuid,$true)}
    if($null -eq $k){throw 'Target endpoint FxProperties unavailable.'}; return $k
}
function Read-Fx {
    $k=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($fx)
    if($null -eq $k){
        $parent=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($fx.Substring(0,$fx.LastIndexOf('\')))
        if($null -eq $parent){throw 'Target endpoint missing.'};$parent.Close();return @()
    }
    try {return @(foreach($name in $k.GetValueNames()){[ordered]@{name=$name;present=$true;kind=$k.GetValueKind($name).ToString();value=$k.GetValue($name)}})}finally{$k.Close()}
}
function Set-FxValues($values) {
    $k=Open-Fx
    try {foreach($item in $values){
        if($item.present){
            $value=$item.value
            if($item.kind -eq 'MultiString'){$value=[string[]]$value}
            if($item.kind -eq 'Binary'){$value=[byte[]]$value}
            $k.SetValue($item.name,$value,[Enum]::Parse([Microsoft.Win32.RegistryValueKind],$item.kind))
        }else{$k.DeleteValue($item.name,$false)}
    };$k.Flush()}finally{$k.Close()}
}
function Set-Association([string]$mode) {
    $now=Read-Fx
    $owner=($now | Where-Object name -eq $efx).value
    if($mode -ne 'Restore' -and $script:strategy -eq 'EFX' -and $owner -and $owner -notin @($unity,$dsp)){throw "EFX belongs to another effect: $owner"}
    $backup=Get-Content -LiteralPath $original -Raw -Encoding UTF8 | ConvertFrom-Json
    if($backup.endpoint -ne $endpoint){throw 'Backup endpoint mismatch.'}
    Set-FxValues $backup.managed_values
    if($mode -eq 'Restore'){return}
    $clsid=if($mode -eq 'DSP'){$dsp}else{$unity}
    if($script:strategy -eq 'CompositeMFX'){
        $list=@(($backup.managed_values | Where-Object name -eq $compositeMFX).value)
        if(-not $list.Count -or -not $list[0]){$list=@(($backup.full_chain | Where-Object name -eq $legacyMFX).value)}
        $list=@($list | Where-Object {$_ -and $_ -notin @($dsp,$unity)})+$clsid
        Set-FxValues @(@{name=$compositeMFX;present=$true;kind='MultiString';value=$list},@{name=$legacyMFX;present=$false})
    }elseif($script:strategy -eq 'CompositeEFX'){
        $list=@(($backup.managed_values | Where-Object name -eq $compositeEFX).value) | Where-Object {$_}
        if(-not $list){$list=@(($backup.full_chain | Where-Object name -eq $efx).value) | Where-Object {$_}}
        $list=@($list | Where-Object {$_ -and $_ -notin @($dsp,$unity)})+$clsid
        Set-FxValues @(@{name=$compositeEFX;present=$true;kind='MultiString';value=$list},@{name=$modes;present=$true;kind='MultiString';value=@('{C18E2F7E-933D-4965-B7D1-1EEF228D2AF3}')})
    }else{
        Set-FxValues @(@{name=$modes;present=$true;kind='MultiString';value=@('{C18E2F7E-933D-4965-B7D1-1EEF228D2AF3}')},@{name=$efx;present=$true;kind='String';value=$clsid})
    }
}
function Rebuild-Graph([scriptblock]$work) {
    $dependents=@((Get-Service Audiosrv).DependentServices | Where-Object Status -eq Running | ForEach-Object Name)
    try {Stop-Service Audiosrv -Force;Stop-Service AudioEndpointBuilder -Force;& $work}
    finally {Start-Service AudioEndpointBuilder;Start-Service Audiosrv;foreach($name in $dependents){Start-Service $name}}
    Start-Sleep -Milliseconds 800
}
function Run-Exe([string]$exe,[string[]]$arguments) {
    & $exe @arguments
    if($LASTEXITCODE -ne 0){throw "Executable failed ($LASTEXITCODE): $exe"}
}
function Get-Installed {
    if(-not(Test-Path -LiteralPath $record)){throw 'Spectral Audio is not installed by this setup.'}
    return Read-SpectralJson $record
}
function Initialize-Target([string]$id,[string]$name) {
    $script:endpointGuid=Get-SpectralEndpointGuid $id
    $script:endpoint=$id;$script:endpointName=$name
    $script:fx='SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\'+$script:endpointGuid+'\FxProperties'
    $targets=Join-Path $state 'endpoints';Protect-Directory $targets
    $targetState=Join-Path $targets $script:endpointGuid;Protect-Directory $targetState
    $script:original=Join-Path $targetState 'original-effects.json'
    $script:extendedOriginal=Join-Path $targetState 'original-effects-v2.json'
    # Import only locally captured backups for this exact endpoint. No backup is shipped.
    foreach($fileName in @('original-effects.json','original-effects-v2.json')){
        $old=Join-Path $state $fileName;$target=Join-Path $targetState $fileName
        if((Test-Path -LiteralPath $record) -and (Test-Path -LiteralPath $old) -and -not(Test-Path -LiteralPath $target)){
            $backup=Get-Content -LiteralPath $old -Raw -Encoding UTF8 | ConvertFrom-Json
            if($backup.endpoint -eq $id){Copy-Item -LiteralPath $old -Destination $target}
        }
    }
    if(Test-Path -LiteralPath $script:extendedOriginal){$script:original=$script:extendedOriginal}
    $script:hookPath=Join-Path $targetState 'hook.json';$script:strategy='CompositeMFX'
    if(Test-Path $script:hookPath){$script:strategy=(Get-Content $script:hookPath -Raw | ConvertFrom-Json).strategy}
    if($script:strategy -notin @('EFX','CompositeEFX','CompositeMFX')){throw 'Invalid saved hook strategy.'}
}
function Archive-TargetBackups {
    $targetState=Split-Path $original
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    foreach($fileName in @('original-effects.json','original-effects-v2.json')){
        $backupPath=Join-Path $targetState $fileName
        if(Test-Path -LiteralPath $backupPath){Move-Item -LiteralPath $backupPath -Destination ($backupPath+'.archived-'+$stamp)}
    }
    $script:original=Join-Path $targetState 'original-effects.json'
}
function Remove-OwnedInstallFiles {
    if(-not(Test-Path -LiteralPath $installRoot)){return}
    $rootFull=[IO.Path]::GetFullPath($installRoot).TrimEnd('\')+'\'
    foreach($version in (Get-ChildItem -LiteralPath $installRoot -Directory)){
        if($version.Name -notmatch '^[0-9A-Fa-f]{16}$' -or ($version.Attributes -band [IO.FileAttributes]::ReparsePoint)){continue}
        $versionFull=[IO.Path]::GetFullPath($version.FullName)
        if(-not $versionFull.StartsWith($rootFull,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe uninstall directory.'}
        $manifestPath=Join-Path $versionFull 'payload-sha256.json'
        if(-not(Test-Path -LiteralPath $manifestPath)){continue}
        $manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        foreach($entry in $manifest.PSObject.Properties){
            if([IO.Path]::GetFileName($entry.Name) -ne $entry.Name){throw 'Unsafe manifest filename.'}
            $file=Join-Path $versionFull $entry.Name
            if(Test-Path -LiteralPath $file){
                if((Get-Item -LiteralPath $file).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse point refused during uninstall.'}
                if((Get-FileHash -LiteralPath $file).Hash -eq $entry.Value){Remove-Item -LiteralPath $file -Force}
                else{Write-Warning "Preserved modified file: $file"}
            }
        }
        $remaining=@(Get-ChildItem -LiteralPath $versionFull -Force | Where-Object Name -ne 'payload-sha256.json')
        if(-not $remaining.Count){Remove-Item -LiteralPath $manifestPath -Force;Remove-Item -LiteralPath $versionFull -Force}
    }
    if(-not @(Get-ChildItem -LiteralPath $installRoot -Force).Count){Remove-Item -LiteralPath $installRoot -Force}
}
function Set-Word([string]$dir,[uint32]$word) {Run-Exe (Join-Path $dir 'spectral_apo_runtime.exe') @('set',[string]$word) | Out-Null}
function Get-Runtime([string]$dir) {
    $text=& (Join-Path $dir 'spectral_apo_runtime.exe') status
    return $text | ConvertFrom-Json
}
function Save-Diagnostics([string]$dir) {
    Get-Runtime $dir | ConvertTo-Json -Depth 15 | Set-Content (Join-Path $state 'latest-runtime.json') -Encoding UTF8
    $start=(Get-Date).AddHours(-2)
    $events=@(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-CodeIntegrity/Operational';StartTime=$start} -ErrorAction SilentlyContinue | Where-Object Message -match 'SpectralAudio|audiodg' | Select-Object TimeCreated,Id,Message)
    Json-Write $events (Join-Path $state 'code-integrity.json')
    Json-Write (Read-Fx) (Join-Path $state 'current-effects.json')
}
function Invoke-SpectralMeasurement([string]$dir,[string]$label,[string]$mode,[uint32]$expectedWord) {
    Write-SpectralProgress ("正在验证音频处理：$label。请暂停其他音频并等待完成。")
    $out=Join-Path $script:session $label;New-Item -ItemType Directory -Path $out | Out-Null
    $p=Start-Process (Join-Path $dir 'spectral_apo_measure.exe') -ArgumentList @($mode,('"'+$endpoint+'"')) -WorkingDirectory $out -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $out 'probe.txt') -RedirectStandardError (Join-Path $out 'error.txt')
    $heldProcessHandle=$p.Handle
    try {
        Start-Sleep -Seconds 3;$a=Get-Runtime $dir
        Start-Sleep -Seconds 2;$b=Get-Runtime $dir
        Json-Write $a (Join-Path $out 'runtime-before.json');Json-Write $b (Join-Path $out 'runtime-after.json')
        $proof=@(foreach($current in $b.instances){
            $prior=$a.instances | Where-Object { $_.pid -eq $current.pid -and $_.instance -eq $current.instance } | Select-Object -First 1
            if($prior -and $current.process -eq 'audiodg.exe' -and $current.endpoint -eq $endpoint -and $current.module -eq (Join-Path $dir 'SpectralAudio.dll') -and $current.stage -eq 5 -and $current.locked -eq 1 -and $current.raw -eq 0 -and $current.discovery -eq 0 -and $current.faults -eq 0 -and $current.hresult -eq 0 -and $current.age_ms -lt 1500 -and $current.callbacks -gt $prior.callbacks -and $current.frames -gt $prior.frames -and $current.settings -eq $expectedWord){$current}
        })
        if(-not $p.WaitForExit(30000)){ $p.Kill();throw 'Measurement timed out.' }
        if($p.ExitCode -ne 0){throw "Measurement failed: $(Get-Content (Join-Path $out 'error.txt') -Raw)"}
        $r=Get-Content (Join-Path $out 'measurement.json') -Raw | ConvertFrom-Json
        $r | Add-Member NoteProperty callback_evidence $proof
        Json-Write $r (Join-Path $out 'measurement.json')
        return $r
    }finally{if(-not $p.HasExited){$p.Kill()}}
}
function Verify-Installed([string]$dir) {
    $script:session=Join-Path $state ('verification-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'));New-Item -ItemType Directory -Path $script:session | Out-Null
    $traceName='SpectralAudio-Audio-'+$PID
    $tracePath=Join-Path $script:session 'audio.etl'
    & logman.exe start $traceName -ets -o $tracePath -p '{AE4BD3BE-F36F-45B6-8D21-BDD6FB832853}' '0x0200000000000000' 4 | Out-Null
    $traceStarted=$LASTEXITCODE -eq 0
    $oldWord=(Get-Runtime $dir).settings
    $summary=[ordered]@{endpoint=$endpoint;complete=$false;audiodg_processing_verified=$false;loopback_covers_efx=$false;loopback_covers_spectral=$false;latency_verified=$false;latency_failure=$null;software_delta_ms=$null;physical_latency_measured=$false;failure=$null}
    try {
        $full=$null;$quarter=$null
        foreach($candidate in @('CompositeMFX','CompositeEFX','EFX')){
            $script:strategy=$candidate
            try {
                Rebuild-Graph {Set-Association DSP};Set-Word $dir 97554
                $attempt=Invoke-SpectralMeasurement $dir ('gain-full-'+$candidate) Bypass 97554
                if(@($attempt.callback_evidence | Where-Object unity -eq 0).Count -eq 0){continue}
                Set-Word $dir 73554
                $challenge=Invoke-SpectralMeasurement $dir ('gain-quarter-'+$candidate) Bypass 73554
                $candidateRatio=if($attempt.capture_rms -gt 0.000001){$challenge.capture_rms/$attempt.capture_rms}else{0}
                # Whole-capture energy proves gain independently of OEM waveform changes.
                # Correlation remains mandatory below for every latency conclusion.
                $quality=@(@($attempt,$challenge) | Where-Object {$_.timestamp_errors -eq 0 -and $_.discontinuities -eq 0 -and $_.mute_before -eq 0 -and $_.mute_after -eq 0 -and [Math]::Abs($_.volume_before-$_.volume_after) -lt 0.001})
                if(@($challenge.callback_evidence | Where-Object unity -eq 0).Count -eq 0 -or $quality.Count -ne 2 -or $candidateRatio -le 0.18 -or $candidateRatio -ge 0.32 -or [Math]::Abs($attempt.volume_before-$challenge.volume_before) -ge 0.001){Write-Warning "$candidate did not pass the gain challenge.";continue}
                $full=$attempt;$quarter=$challenge;break
            }catch{Write-Warning ("$candidate : "+$_.Exception.Message)}
        }
        $summary.hook_strategy=$script:strategy
        if($null -eq $full){throw 'No effect path passed target audiodg callbacks and loopback gain verification. Original effects will be restored.'}
        Json-Write @{strategy=$script:strategy} $hookPath
        $summary.audiodg_processing_verified=(@($full.callback_evidence | Where-Object unity -eq 0).Count -gt 0 -and @($quarter.callback_evidence | Where-Object unity -eq 0).Count -gt 0)
        if(-not $summary.audiodg_processing_verified){throw 'No growing fault-free DSP callbacks in audiodg. Inspect runtime and CodeIntegrity records.'}
        $ratio=if($full.capture_rms -gt 0.000001){$quarter.capture_rms/$full.capture_rms}else{0}
        $summary.gain_ratio=$ratio
        $summary.gain_evidence='Whole-capture RMS at 100% and 25% gain, target live callbacks, stable volume, no mute/timestamp/discontinuity faults; independent of chirp correlation.'
        $good=@(@($full,$quarter) | Where-Object {$_.timestamp_errors -eq 0 -and $_.discontinuities -eq 0 -and $_.mute_before -eq 0 -and $_.mute_after -eq 0 -and [Math]::Abs($_.volume_before-$_.volume_after) -lt 0.001})
        $summary.loopback_covers_spectral=($good.Count -eq 2 -and $ratio -gt 0.18 -and $ratio -lt 0.32 -and [Math]::Abs($full.volume_before-$quarter.volume_before) -lt 0.001)
        $summary.loopback_covers_efx=$summary.loopback_covers_spectral -and $script:strategy -ne 'CompositeMFX'
        if(-not $summary.loopback_covers_spectral){throw 'Spectral loopback coverage not established; no DSP latency delta will be reported.'}
        $summary.complete=$true
        try {
        Rebuild-Graph {Set-Association Unity};Set-Word $dir 97538
        $direct=Invoke-SpectralMeasurement $dir 'unity' Unity 97538
        Rebuild-Graph {Set-Association DSP};Set-Word $dir 97538
        $wet=Invoke-SpectralMeasurement $dir 'original-dsp' DSP 97538
        if(@($direct.callback_evidence | Where-Object unity -eq 1).Count -eq 0 -or @($wet.callback_evidence | Where-Object unity -eq 0).Count -eq 0){throw 'Missing Unity/DSP live callback evidence.'}
        foreach($r in @($direct,$wet)){if($r.min_correlation -lt .85 -or $r.timestamp_errors -ne 0 -or $r.discontinuities -ne 0 -or $r.mute_before -ne 0 -or $r.mute_after -ne 0 -or [Math]::Abs($r.volume_before-$r.volume_after) -ge .001){throw 'Latency capture quality check failed.'}}
        if([Math]::Abs($direct.volume_before-$wet.volume_before) -ge .001){throw 'Endpoint volume changed during A/B.'}
        $summary.unity_ms=$direct.median_ms;$summary.dsp_ms=$wet.median_ms
        $summary.raw_software_delta_ms=$wet.median_ms-$direct.median_ms
        if($null -eq $wet.median_queue_corrected_ms -or $null -eq $direct.median_queue_corrected_ms -or $wet.render_buffer_frames -ne $direct.render_buffer_frames){throw 'Missing source-queue timing or inconsistent render buffering.'}
        $summary.unity_queue_corrected_ms=$direct.median_queue_corrected_ms;$summary.dsp_queue_corrected_ms=$wet.median_queue_corrected_ms
        $summary.software_delta_ms=$wet.median_queue_corrected_ms-$direct.median_queue_corrected_ms
        $summary.unity_queue_corrected_range_ms=@($direct.queue_corrected_min_ms,$direct.queue_corrected_max_ms)
        $summary.dsp_queue_corrected_range_ms=@($wet.queue_corrected_min_ms,$wet.queue_corrected_max_ms)
        $summary.source_queue_correction='GetCurrentPadding plus marker offset, adjusted from padding-query QPC to ReleaseBuffer QPC. Estimated queued frames; not a physical measurement.' 
        $summary.boundary='Same test source ReleaseBuffer to endpoint loopback packet QPC. Source queue included in both; physical output is not measured.'
        $summary.latency_verified=$true
        }catch{$summary.latency_failure=$_.Exception.Message;Write-Warning ('Processing verified; latency unavailable: '+$summary.latency_failure)}
    }catch{$summary.failure=$_.Exception.Message;Write-Warning $summary.failure}
    finally {
        try{Set-Word $dir $oldWord;Rebuild-Graph {if($summary.audiodg_processing_verified -and $summary.loopback_covers_spectral){Set-Association DSP;$summary.active_association='DSP'}else{Set-Association Restore;$summary.active_association='Original'}};Save-Diagnostics $dir}catch{$summary.failure=[string]$summary.failure+'; restore: '+$_.Exception.Message;$summary.complete=$false}
        $modules=@(foreach($process in (Get-Process audiodg -ErrorAction SilentlyContinue)){try{[ordered]@{pid=$process.Id;modules=@($process.Modules | Select-Object ModuleName,FileName)}}catch{[ordered]@{pid=$process.Id;error=$_.Exception.Message}}})
        Json-Write $modules (Join-Path $script:session 'audiodg-modules.json')
        if($traceStarted){& logman.exe stop $traceName -ets | Out-Null;& tracerpt.exe $tracePath -o (Join-Path $script:session 'audio.xml') -of XML -y | Out-Null}
        Json-Write $summary (Join-Path $script:session 'summary.json');Json-Write $summary (Join-Path $state 'latest-verification.json')
    }
    return [pscustomobject]$summary
}
if($Action -eq 'Status') {Get-Runtime (Get-Installed).directory | ConvertTo-Json -Depth 15;exit}
Protect-Directory $state
$diagnostics=Join-Path $state 'diagnostics'
Protect-Directory $diagnostics
$diagAcl=Get-Acl -LiteralPath $diagnostics
foreach($sidText in @('S-1-5-19','S-1-5-12')){$diagSid=New-Object Security.Principal.SecurityIdentifier($sidText);$diagAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($diagSid,'Modify','ContainerInherit,ObjectInherit','None','Allow')))}
Set-Acl -LiteralPath $diagnostics -AclObject $diagAcl
$transcript=Join-Path $state ('setup-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.log')
Start-Transcript -LiteralPath $transcript | Out-Null
$exitCode=0
$setupMutex=$null;$ownsMutex=$false;$sessionMutex=$null;$ownsSession=$false
try {
    if($Action -eq 'Watch'){Invoke-SpectralWatch $SessionToken;exit 0}
    $liveSession=Get-SpectralSession
    $sessionVerification=$Action -eq 'Verify' -and $SessionToken -and $liveSession -and $liveSession.token -eq $SessionToken -and (Test-SpectralSessionOwner $liveSession)
    $sessionOperation=$Action -in @('Verify','Switch') -and $SessionToken -and $liveSession -and $liveSession.token -eq $SessionToken -and (Test-SpectralSessionOwner $liveSession)
    if($Action -ne 'Recover' -and -not $sessionOperation){
        $sessionMutex=New-Object Threading.Mutex($false,'Global\SpectralAudio.Session')
        try{$ownsSession=$sessionMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$ownsSession=$true}
        if(-not $ownsSession){throw 'Spectral 控制台或安装操作正在运行。请先关闭控制台并等待原链路恢复。'}
    }
    $setupMutex=Enter-SpectralSetup;$ownsMutex=$true
    if($Action -eq 'Install'){
        if([Environment]::OSVersion.Version.Build -lt 22000){throw '此安装包需要 Windows 11 x64。'}
        Write-SpectralProgress '正在读取本机音频输出（最多等待 15 秒）…'
        $devices=Get-SpectralEndpoints $PSScriptRoot
        $requested=$EndpointId
        if((Test-Path $record) -and -not $requested){$requested=(Get-Installed).endpoint;Write-SpectralProgress '检测到已安装配置，沿用原输出并重新安装、验证…'}else{Write-SpectralProgress '请选择弹出窗口中的音频输出，然后点击“安装并验证”。'}
        $selected=Select-SpectralEndpoint $devices $requested -NoUI:$NoUI
        if((Test-Path $record) -and (Get-Installed).endpoint -ne $selected.id){throw '当前已安装到另一个输出。请先从开始菜单 Spectral Audio 恢复/卸载，再重新安装到新输出。'}
        Initialize-Target $selected.id $selected.name
        if(-not(Test-Path $record)){
            # A fresh installation captures today's driver chain. Retain older backups.
            Archive-TargetBackups
        }
    }else{
        $installed=Get-Installed
        if($Action -ne 'Switch' -and $EndpointId -and $EndpointId -ne $installed.endpoint){throw 'Endpoint differs from the installed target.'}
        Initialize-Target $installed.endpoint $installed.endpoint_name
    }
    Recover-SpectralSession
    if($Action -eq 'Recover' -and -not(Test-SpectralSessionOwner (Get-SpectralSession)) -and (Test-SpectralLinked)){Restore-SpectralChain}
    if($Action -eq 'Install') {
        Write-SpectralProgress ("正在校验安装文件并备份原效果链。输出：$endpointName")
        $manifest=Get-Content (Join-Path $PSScriptRoot 'payload-sha256.json') -Raw | ConvertFrom-Json
        foreach($file in $manifest.PSObject.Properties){
            if([IO.Path]::GetFileName($file.Name) -ne $file.Name){throw 'Unsafe payload filename.'}
            if((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $file.Name) -Algorithm SHA256).Hash -ne $file.Value){throw "Payload hash mismatch: $($file.Name)"}
        }
        Protect-Directory $installRoot
        $build=(Get-FileHash (Join-Path $PSScriptRoot 'payload-sha256.json') -Algorithm SHA256).Hash.Substring(0,16)
        $dir=Join-Path $installRoot $build;Protect-Directory $dir
        foreach($file in $manifest.PSObject.Properties){$target=Join-Path $dir $file.Name;if(-not(Test-Path -LiteralPath $target) -or (Get-FileHash -LiteralPath $target).Hash -ne $file.Value){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file.Name) -Destination $dir -Force}}
        Copy-Item (Join-Path $PSScriptRoot 'payload-sha256.json') $dir -Force
        $savedWord=97538
        if(Test-Path $record){$savedWord=(Get-Runtime (Get-Installed).directory).settings}
        elseif(Test-Path $runtime){$savedRuntime=Get-Runtime $PSScriptRoot;if($savedRuntime.error -eq 0){$savedWord=$savedRuntime.settings}}
        $before=Read-Fx
        Ensure-SpectralBackup
        $registryKeys=@(foreach($id in @($dsp,$unity)){"SOFTWARE\Classes\CLSID\$id";"SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$id"})
        $rollback=Join-Path $state ('rollback-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'));New-Item -ItemType Directory -Path $rollback | Out-Null
        $existing=@();$n=0
        foreach($key in $registryKeys){
            if(Test-Path ('Registry::HKEY_LOCAL_MACHINE\'+$key)){
                $file=Join-Path $rollback ('key'+$n+'.reg');& reg.exe export ('HKLM\'+$key) $file /y | Out-Null;if($LASTEXITCODE){throw 'Registry backup failed.'};$existing+=,$file
            };$n++
        }
        foreach($id in @($dsp,$unity)) {
            $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\Classes\CLSID\$id\InprocServer32")
            if($key){try{$oldDll=[string]$key.GetValue('')}finally{$key.Close()}
                if(-not(Test-Path -LiteralPath $oldDll)){throw "Previous registered DLL missing: $oldDll"}
                $allowedStage=Join-Path $env:USERPROFILE 'Desktop\SpectralAudio-win11-x64-stageA\SpectralAudio-win11-x64-stageA\SpectralAudio.dll'
                if($oldDll -ne $allowedStage -and -not $oldDll.StartsWith($installRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw "Unrecognized Spectral registration path: $oldDll"}
                Copy-Item -LiteralPath $oldDll -Destination (Join-Path $rollback ($id+'.dll')) -Force
            }
        }
        Write-SpectralProgress '正在部署 Spectral Audio 并重建音频连接，声音会短暂中断…'
        $runtimeMoved=$false
        Rebuild-Graph {
            try {
                foreach($key in $registryKeys){[Microsoft.Win32.Registry]::LocalMachine.DeleteSubKeyTree($key,$false)}
                $p=Start-Process "$env:windir\System32\regsvr32.exe" -ArgumentList @('/s',('"'+(Join-Path $dir 'SpectralAudio.dll')+'"')) -WindowStyle Hidden -Wait -PassThru
                if($p.ExitCode){throw "DLL registration failed: $($p.ExitCode)"}
                if(Test-Path $runtime){Move-Item -LiteralPath $runtime -Destination (Join-Path $rollback 'previous-runtime.bin');$script:runtimeMoved=$true}
                Run-Exe (Join-Path $dir 'spectral_apo_runtime.exe') @('init') | Out-Null;Runtime-ACL;Set-Word $dir $savedWord
                $script:installTouchedChain=$true;Set-Association DSP
            }catch{
                $failure=$_
                foreach($key in $registryKeys){[Microsoft.Win32.Registry]::LocalMachine.DeleteSubKeyTree($key,$false)}
                if($script:runtimeMoved){if(Test-Path -LiteralPath $runtime){Remove-Item -LiteralPath $runtime};Move-Item -LiteralPath (Join-Path $rollback 'previous-runtime.bin') -Destination $runtime}
                foreach($file in $existing){& reg.exe import $file | Out-Null;if($LASTEXITCODE){Write-Warning "Rollback import failed: $file"}}
                Set-FxValues @($before | Where-Object name -in $managedNames)
                foreach($name in $managedNames){if(-not($before | Where-Object name -eq $name)){Set-FxValues @(@{name=$name;present=$false})}}
                throw $failure
            }
        }
        Json-Write @{directory=$dir;version='1.0.0';installed_at=(Get-Date -Format o);endpoint=$endpoint;endpoint_name=$endpointName;original_backup=$original;dll_sha256=(Get-FileHash (Join-Path $dir 'SpectralAudio.dll')).Hash} $record
        $uninstallKey='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\SpectralAudio'
        New-Item $uninstallKey -Force | Out-Null
        New-ItemProperty $uninstallKey DisplayName -Value 'Spectral Audio' -PropertyType String -Force | Out-Null
        New-ItemProperty $uninstallKey DisplayVersion -Value '1.0.0' -PropertyType String -Force | Out-Null
        $uninstallCommand='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $dir 'Open-SpectralAudio.ps1')+'" -Action Uninstall'
        New-ItemProperty $uninstallKey UninstallString -Value $uninstallCommand -PropertyType String -Force | Out-Null
        New-ItemProperty $uninstallKey NoModify -Value 1 -PropertyType DWord -Force | Out-Null
        $shell=New-Object -ComObject WScript.Shell
        $shortcut=$shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Spectral Audio.lnk'))
        $shortcut.TargetPath="$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe";$shortcut.Arguments='-NoProfile -STA -ExecutionPolicy Bypass -File "'+(Join-Path $dir 'Open-SpectralAudio.ps1')+'" -Action Control';$shortcut.WorkingDirectory=$dir;$shortcut.WindowStyle=7;$shortcut.Save()
        $desktopLink=Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Spectral Audio 控制台.lnk'
        $desktopShortcut=$shell.CreateShortcut($desktopLink);$desktopShortcut.TargetPath=$shortcut.TargetPath;$desktopShortcut.Arguments=$shortcut.Arguments;$desktopShortcut.WorkingDirectory=$dir;$desktopShortcut.WindowStyle=7;$desktopShortcut.Save()
        Register-SpectralRecovery $dir
        try{$verification=Verify-Installed $dir;Save-SpectralDeviceVerification $dir $verification}finally{Restore-SpectralChain;$script:installTouchedChain=$false}
        if(-not $verification.complete){
            $exitCode=2
            if(-not $NoUI){Add-Type -AssemblyName System.Windows.Forms;[Windows.Forms.MessageBox]::Show("安装文件已部署，但本机验证未通过。`r`n"+$verification.failure+"`r`n当前效果链："+$verification.active_association+"`r`n请查看控制台诊断记录；未验证通过不能视为可用。",'Spectral Audio 验证未通过') | Out-Null}
        }
    }elseif($Action -eq 'Verify'){
        $dir=(Get-Installed).directory
        try{$verification=Verify-Installed $dir;Save-SpectralDeviceVerification $dir $verification;if(-not $verification.complete){$exitCode=2}}
        finally{if(-not $sessionVerification -or -not(Test-SpectralSessionOwner (Get-SpectralSession))){Restore-SpectralChain}}
    }
    elseif($Action -eq 'Switch'){Invoke-SpectralSwitch $EndpointId $SessionToken}
    elseif($Action -eq 'Uninstall') {
        foreach($app in (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {$_.ProcessId -ne $PID -and $_.CommandLine -match 'Manage-SpectralAudio\.ps1' -and $_.CommandLine -match '-Action (Control|Install)(\s|$)' -and $_.CommandLine -notmatch '-NoUI' -and ($_.CommandLine.Contains($installRoot) -or $_.CommandLine.Contains($PSScriptRoot))})){
            try{(Get-Process -Id $app.ProcessId).CloseMainWindow()|Out-Null}catch{}
        }
        $dir=(Get-Installed).directory
        Rebuild-Graph {
            Set-Association Restore
            $p=Start-Process "$env:windir\System32\regsvr32.exe" -ArgumentList @('/s','/u',('"'+(Join-Path $dir 'SpectralAudio.dll')+'"')) -WindowStyle Hidden -Wait -PassThru
            if($p.ExitCode){throw "Unregister failed: $($p.ExitCode)"}
            Remove-OwnedInstallFiles
        }
        Remove-Item -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\SpectralAudio' -Recurse -ErrorAction SilentlyContinue
        $shortcut=Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Spectral Audio.lnk';if(Test-Path $shortcut){Remove-Item -LiteralPath $shortcut}
        Move-Item -LiteralPath $record -Destination (Join-Path $state ('uninstalled-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.json'))
        if(Get-ScheduledTask -TaskName 'SpectralAudio-Recover' -ErrorAction SilentlyContinue){Unregister-ScheduledTask -TaskName 'SpectralAudio-Recover' -Confirm:$false}
        $desktopLink=Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Spectral Audio 控制台.lnk'
        if(Test-Path -LiteralPath $desktopLink){$shell=New-Object -ComObject WScript.Shell;$link=$shell.CreateShortcut($desktopLink);if($link.Arguments.Contains($installRoot+'\')){Remove-Item -LiteralPath $desktopLink}}
        # Keep protected original-effect backups and measurements for recovery/audit.
    }
    if($ownsMutex){$setupMutex.ReleaseMutex();$ownsMutex=$false}
    if(($Action -in @('Control','Install','Verify')) -and -not $NoUI -and -not $NoPanel -and -not $sessionVerification){
        $dir=(Get-Installed).directory;Invoke-SpectralControl $dir
        if($script:spectralUninstallRequested){
            $sessionMutex.ReleaseMutex();$ownsSession=$false
            $p=Start-Process "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -WindowStyle Hidden -PassThru -Wait -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $dir 'Manage-SpectralAudio.ps1')+'"'),'-Action','Uninstall','-NoUI')
            if($p.ExitCode){throw '原链路已恢复，但卸载失败。请查看诊断日志。'}
        }
    }
}catch{
    $exitCode=1;$failureMessage=$_.Exception.Message;Write-Warning $failureMessage
    if($ProgressFile){Write-SpectralProgress $failureMessage}
    if(-not $NoUI){Add-Type -AssemblyName System.Windows.Forms;[System.Windows.Forms.MessageBox]::Show($_.Exception.Message+"`r`nLog: "+$transcript,'Spectral Audio') | Out-Null}
}finally{
    try{if($script:installTouchedChain){Restore-SpectralChain}}finally{
        if($ownsMutex){$setupMutex.ReleaseMutex()};if($setupMutex){$setupMutex.Dispose()}
        if($ownsSession){$sessionMutex.ReleaseMutex()};if($sessionMutex){$sessionMutex.Dispose()}
        Stop-Transcript | Out-Null
    }
}
exit $exitCode
