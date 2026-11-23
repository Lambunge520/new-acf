@echo off
chcp 65001 >nul 2>&1
setlocal EnableExtensions
title AMD Ryzen 4000/5000 稳定性修复工具 (Win10/Win11)
set "SELF=%~f0"
set "ARG1=%~1"

:: ---- 检查并提权至管理员 ----
fltmc >nul 2>&1
if errorlevel 1 goto :elevate
goto :run

:elevate
echo 正在请求管理员权限...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:SELF -replace '''',''''''; $a=$env:ARG1 -replace '''',''''''; if([string]::IsNullOrEmpty($a)){Start-Process -FilePath $p -Verb RunAs}else{Start-Process -FilePath $p -ArgumentList $a -Verb RunAs}"
exit /b

:run
:: ---- 提取内嵌 PowerShell 脚本并执行 ----
set "PSTMP=%TEMP%\AMD_Ryzen_Fix_CN_%RANDOM%.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:SELF,[Text.Encoding]::UTF8); $m='::PS1'+'_BEGIN'; $i=$t.IndexOf($m); if($i -lt 0){exit 9}; $body=$t.Substring($i+$m.Length); [IO.File]::WriteAllText($env:PSTMP,$body,[Text.UTF8Encoding]::new($true))"
if errorlevel 1 goto :extract_failed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PSTMP%" %ARG1%
set "RC=%errorlevel%"
del "%PSTMP%" >nul 2>&1
exit /b %RC%

:extract_failed
echo 错误：无法读取内嵌脚本，请确认文件完整或以 UTF-8 编码保存后重新运行。
pause
exit /b 1

::PS1_BEGIN
param([string]$Mode = '')

# =====================================================================
#  AMD Ryzen 4000 / 5000 稳定性修复工具 (Windows 10 / Windows 11)
#  用法：双击打开交互菜单，或命令行传入参数：
#        /apply   /max   /restore   /status
# =====================================================================

# ---------------- 可自定义参数 ----------------
$MinProcAC_Rec   = 80     # [推荐档] 接通电源时最小处理器状态 (%)
$MinProcDC_Rec   = 50     # [推荐档] 使用电池时最小处理器状态 (%)
$MinProcAC_Max   = 100    # [强力档] 接通电源时最小处理器状态 (%) - 缓解低频降压掉压黑屏
$MinProcDC_Max   = 100    # [强力档] 使用电池时最小处理器状态 (%)
$ApplyToAllPlans = $true  # $true = 应用到所有电源计划，$false = 仅当前激活的电源计划
# ----------------------------------------------

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch { }

$script:Done = 0
$script:Fail = 0

$DataDir    = Join-Path $env:ProgramData 'AMD_Ryzen_Fix'
$BackupFile = Join-Path $DataDir 'backup.json'
$LogFile    = Join-Path $DataDir 'log.txt'
$GpuClass   = 'SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
$PciKey     = 'SYSTEM\CurrentControlSet\Control\PnP\Pci'
$GuidRx     = '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'

if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

function Log([string]$msg, [string]$color = 'Gray') {
    Write-Host $msg -ForegroundColor $color
    try { Add-Content -Path $LogFile -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8 } catch { }
}

# ---------------- 管理员权限校验 ----------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Log '错误：请以管理员身份运行此工具。' 'Red'
    Read-Host '按回车键退出' | Out-Null
    exit 1
}

# ---------------- 系统与硬件检测 ----------------
$os          = Get-CimInstance Win32_OperatingSystem
$build       = [int]$os.BuildNumber
$cpu         = ([string](Get-CimInstance Win32_Processor | Select-Object -First 1).Name).Trim()
$winName     = if ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' }
$isRyzen     = $cpu -match 'Ryzen\s+\d\s+(PRO\s+)?[45]\d{3}'
$isLaptop    = $null -ne (Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
$interactive = [string]::IsNullOrEmpty($Mode)

if ($build -lt 10240) {
    Log '错误：仅支持 Windows 10 或 Windows 11。' 'Red'
    exit 1
}

# ---------------- 修复方案配置 ----------------
# 值对格式为 @(交流电源 AC, 电池 DC)
$PowerSettings = @(
    @{ Name = 'PCIe ASPM 链路电源管理'; Sub = 'SUB_PCIEXPRESS'; Id = 'ASPM' },
    @{ Name = '最小处理器状态';           Sub = 'SUB_PROCESSOR';  Id = 'PROCTHROTTLEMIN' },
    @{ Name = '禁用处理器空闲状态';       Sub = 'SUB_PROCESSOR';  Id = 'IDLEDISABLE' }
)

$Profiles = @{
    'Recommended' = @{
        ASPM            = @(0, 0)
        PROCTHROTTLEMIN = @($MinProcAC_Rec, $MinProcDC_Rec)
        IDLEDISABLE     = @(0, 0)
    }
    'Maximum'     = @{
        ASPM            = @(0, 0)
        PROCTHROTTLEMIN = @($MinProcAC_Max, $MinProcDC_Max)
        IDLEDISABLE     = @(1, 1)
    }
}

# ---------------- 注册表辅助函数 ----------------
function Get-RegDword([string]$path, [string]$name) {
    $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($path, $false)
    if ($null -eq $k) { return $null }
    try {
        $v = $k.GetValue($name, $null)
        if ($null -eq $v) { return $null }
        return [int]$v
    } finally { $k.Dispose() }
}

function Set-RegDword([string]$path, [string]$name, $data) {
    $k = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($path)
    if ($null -eq $k) { throw "无法打开注册表项 $path" }
    try {
        if ($null -eq $data) { $k.DeleteValue($name, $false) }
        else { $k.SetValue($name, [int]$data, [Microsoft.Win32.RegistryValueKind]::DWord) }
    } finally { $k.Dispose() }
}

function Test-RegValueExists([string]$path, [string]$name) {
    $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($path, $false)
    if ($null -eq $k) { return $false }
    try {
        return ($null -ne $k.GetValue($name, $null))
    } finally { $k.Dispose() }
}

function Get-AmdAdapters {
    $res = @()
    $base = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($GpuClass, $false)
    if ($null -eq $base) { return $res }
    try {
        foreach ($n in $base.GetSubKeyNames()) {
            if ($n -notmatch '^\d{4}$') { continue }
            $k = $base.OpenSubKey($n, $false)
            if ($null -eq $k) { continue }
            try {
                $dev  = [string]$k.GetValue('MatchingDeviceId', '')
                $prov = [string]$k.GetValue('ProviderName', '')
                $desc = [string]$k.GetValue('DriverDesc', '')
                if ($dev -match 'VEN_1002' -or $prov -match 'Advanced Micro Devices|AMD|ATI' -or $desc -match 'AMD|Radeon') {
                    $res += [pscustomobject]@{ Key = $n; Desc = $desc }
                }
            } finally { $k.Dispose() }
        }
    } finally { $base.Dispose() }
    return $res
}

# ---------------- 电源计划辅助函数 ----------------
function Get-AllSchemes {
    $res = @()
    foreach ($l in (cmd.exe /c 'powercfg.exe /list 2>nul')) {
        $m = [regex]::Match([string]$l, $GuidRx)
        if ($m.Success) {
            $n = [regex]::Match([string]$l, '\(([^)]*)\)')
            $label = $m.Value
            if ($n.Success) { $label = $n.Groups[1].Value }
            $res += [pscustomobject]@{ Guid = $m.Value; Name = $label }
        }
    }
    return $res
}

function Get-ActiveScheme {
    $t = (cmd.exe /c 'powercfg.exe /getactivescheme 2>nul' | Out-String)
    return [regex]::Match($t, $GuidRx).Value
}

# 返回 @(AC, DC) 或 $null（无法读取时）
function Get-PowerValue([string]$scheme, [string]$sub, [string]$setting) {
    $t = (cmd.exe /c "powercfg.exe /query $scheme $sub $setting 2>nul" | Out-String)
    if ($LASTEXITCODE -ne 0) { return $null }
    $m = [regex]::Matches($t, '0x[0-9a-fA-F]{8}')
    if ($m.Count -lt 2) { return $null }
    $ac = [Convert]::ToInt32($m[$m.Count - 2].Value.Substring(2), 16)
    $dc = [Convert]::ToInt32($m[$m.Count - 1].Value.Substring(2), 16)
    return @($ac, $dc)
}

function Set-PowerValue([string]$scheme, [string]$sub, [string]$setting, $ac, $dc) {
    cmd.exe /c "powercfg.exe /setacvalueindex $scheme $sub $setting $ac >nul 2>&1"
    if ($LASTEXITCODE -ne 0) { return $false }
    cmd.exe /c "powercfg.exe /setdcvalueindex $scheme $sub $setting $dc >nul 2>&1"
    return ($LASTEXITCODE -eq 0)
}

function Set-ActiveScheme([string]$scheme) {
    cmd.exe /c "powercfg.exe /setactive $scheme >nul 2>&1"
    return ($LASTEXITCODE -eq 0)
}

function Confirm-Yes([string]$question) {
    $a = Read-Host "$question (y/N)"
    return ($a.Trim().ToLower() -eq 'y')
}

# ---------------- 备份与还原 ----------------
function New-Backup {
    $gpu = @()
    foreach ($a in @(Get-AmdAdapters)) {
        $p = "$GpuClass\$($a.Key)"
        $gpu += @{
            Key                    = $a.Key
            Desc                   = $a.Desc
            EnableUlps             = (Get-RegDword $p 'EnableUlps')
            EnableUlps_NA          = (Get-RegDword $p 'EnableUlps_NA')
            PP_SclkDeepSleepDisable = (Get-RegDword $p 'PP_SclkDeepSleepDisable')
            PP_MclkDeepSleepDisable = (Get-RegDword $p 'PP_MclkDeepSleepDisable')
        }
    }
    $plans = @()
    foreach ($s in @(Get-AllSchemes)) {
        $e = @{ Guid = $s.Guid }
        foreach ($ps in $PowerSettings) {
            $v = Get-PowerValue $s.Guid $ps.Sub $ps.Id
            if ($null -eq $v -and $ps.Id -eq 'IDLEDISABLE') { $v = @(0, 0) }
            $e[$ps.Id] = $v
        }
        $plans += $e
    }
    $b = @{
        Created     = (Get-Date).ToString('s')
        Cpu         = $cpu
        Os          = $winName
        Build       = $build
        DisableASPM = (Get-RegDword $PciKey 'DisableASPM')
        Gpu         = $gpu
        Plans       = $plans
    }
    $b | ConvertTo-Json -Depth 6 | Set-Content -Path $BackupFile -Encoding UTF8
    Log "已保存原始设置备份：$BackupFile" 'Gray'
}

function Ensure-Backup {
    if (Test-Path $BackupFile) {
        Log '检测到已有原始设置备份，保留原备份不变。' 'Gray'
    } else {
        New-Backup
    }
}

function Invoke-Restore {
    if (-not (Test-Path $BackupFile)) {
        Log '未找到备份文件，无需还原。（请先执行一次修复）' 'Yellow'
        return 1
    }
    $b = Get-Content -Raw -Path $BackupFile -Encoding UTF8 | ConvertFrom-Json
    $fail = 0
    Log ''
    Log '== 正在还原原始设置 ==' 'Cyan'

    foreach ($g in @($b.Gpu)) {
        try {
            $p = "$GpuClass\$($g.Key)"
            Set-RegDword $p 'EnableUlps' $g.EnableUlps
            if ($null -ne $g.EnableUlps_NA -or (Test-RegValueExists $p 'EnableUlps_NA')) {
                Set-RegDword $p 'EnableUlps_NA' $g.EnableUlps_NA
            }
            Set-RegDword $p 'PP_SclkDeepSleepDisable' $g.PP_SclkDeepSleepDisable
            if ($null -ne $g.PP_MclkDeepSleepDisable -or (Test-RegValueExists $p 'PP_MclkDeepSleepDisable')) {
                Set-RegDword $p 'PP_MclkDeepSleepDisable' $g.PP_MclkDeepSleepDisable
            }
            Log "[成功] AMD 显卡 $($g.Key) ($($g.Desc))：ULPS 及时钟深度睡眠已还原" 'Green'
        } catch { Log "[失败] AMD 显卡 $($g.Key)：$($_.Exception.Message)" 'Red'; $fail++ }
    }

    try {
        Set-RegDword $PciKey 'DisableASPM' $b.DisableASPM
        Log '[成功] PCI ASPM 注册表项已还原' 'Green'
    } catch { Log "[失败] PCI ASPM 注册表项：$($_.Exception.Message)" 'Red'; $fail++ }

    $existing = @(Get-AllSchemes | ForEach-Object { $_.Guid })
    $active = Get-ActiveScheme
    foreach ($pl in @($b.Plans)) {
        if ($existing -notcontains $pl.Guid) { continue }
        foreach ($ps in $PowerSettings) {
            $v = $pl.($ps.Id)
            if ($null -eq $v) { continue }
            if (-not (Set-PowerValue $pl.Guid $ps.Sub $ps.Id $v[0] $v[1])) {
                Log "[警告] 无法还原电源计划 $($pl.Guid) 的 [$($ps.Name)]" 'Yellow'
            }
        }
    }
    if ($active) { [void](Set-ActiveScheme $active) }
    Log '[成功] 电源计划设置已还原' 'Green'

    Remove-Item -Path $BackupFile -Force -ErrorAction SilentlyContinue
    Log '还原完成。建议重启 Windows 使所有更改完全生效。' 'Cyan'
    if ($fail -gt 0) { return 1 }
    return 0
}

# ---------------- 执行修复 ----------------
function Invoke-Apply([string]$name) {
    $p = $Profiles[$name]

    if ($interactive) {
        if (-not $isRyzen) {
            Log "当前未检测到 Ryzen 4000/5000 系列处理器（检测结果：$cpu）。" 'Yellow'
            if (-not (Confirm-Yes '仍要继续应用修复吗？')) { return 3 }
        }
        if ($name -eq 'Maximum') {
            Log '【强力修复】将禁用处理器空闲状态并提高最小处理器状态：待机功耗、发热与风扇噪音会增加。' 'Yellow'
            if ($isLaptop) { Log '检测到当前为笔记本电脑，电池续航时间将明显缩短。' 'Yellow' }
            if (-not (Confirm-Yes '确认应用【强力修复】吗？')) { return 3 }
        }
    }

    $script:Done = 0
    $script:Fail = 0
    Log ''
    Log "== 正在应用方案：$name ==" 'Cyan'
    Ensure-Backup

    # [1/3] AMD 显卡：禁用 ULPS 与核心/显存时钟深度睡眠（降低低负载/降压黑屏风险）
    $amd = @(Get-AmdAdapters)
    if ($amd.Count -eq 0) {
        Log '[跳过] 未检测到 AMD 显卡驱动项（ULPS / 时钟深度睡眠）' 'Yellow'
    }
    foreach ($a in $amd) {
        $path = "$GpuClass\$($a.Key)"
        try {
            Set-RegDword $path 'EnableUlps' 0
            if (Test-RegValueExists $path 'EnableUlps_NA') {
                Set-RegDword $path 'EnableUlps_NA' 0
            }
            Set-RegDword $path 'PP_SclkDeepSleepDisable' 1
            if (Test-RegValueExists $path 'PP_MclkDeepSleepDisable') {
                Set-RegDword $path 'PP_MclkDeepSleepDisable' 1
            }

            $uNow = Get-RegDword $path 'EnableUlps'
            $sNow = Get-RegDword $path 'PP_SclkDeepSleepDisable'
            if ($uNow -ne 0 -or $sNow -ne 1) {
                throw "注册表校验失败 (EnableUlps=$uNow, PP_SclkDeepSleepDisable=$sNow)"
            }
            Log "[成功] $($a.Desc)：已禁用 ULPS 及显卡深度睡眠" 'Green'
            $script:Done++
        } catch {
            Log "[失败] $($a.Desc)：$($_.Exception.Message)" 'Red'
            $script:Fail++
        }
    }

    # [2/3] PCIe ASPM 注册表禁用标志
    try {
        Set-RegDword $PciKey 'DisableASPM' 1
        if ((Get-RegDword $PciKey 'DisableASPM') -ne 1) { throw '注册表校验失败' }
        Log '[成功] PCI ASPM 注册表禁用标志已写入' 'Green'
        $script:Done++
    } catch {
        Log "[失败] PCI ASPM 注册表标志：$($_.Exception.Message)" 'Red'
        $script:Fail++
    }

    # [3/3] 电源计划参数（包含 Windows 11 生效方案刷新）
    $schemes = @(Get-AllSchemes)
    $active  = Get-ActiveScheme
    $targets = $schemes
    if (-not $ApplyToAllPlans) {
        $targets = @($schemes | Where-Object { $_.Guid -eq $active })
    }

    foreach ($s in $targets) {
        $planOk = $true
        $bad = @()
        foreach ($ps in $PowerSettings) {
            $want   = $p[$ps.Id]
            $before = Get-PowerValue $s.Guid $ps.Sub $ps.Id
            $set    = Set-PowerValue $s.Guid $ps.Sub $ps.Id $want[0] $want[1]
            if (-not $set) {
                if ($null -ne $before) { $planOk = $false; $bad += $ps.Name }
                continue
            }
            $now = Get-PowerValue $s.Guid $ps.Sub $ps.Id
            if ($null -ne $now -and ($now[0] -ne $want[0] -or $now[1] -ne $want[1])) {
                $planOk = $false; $bad += $ps.Name
            }
        }
        if ($planOk) {
            Log "[成功] 电源计划 '$($s.Name)' 已更新" 'Green'
            $script:Done++
        } else {
            Log "[失败] 电源计划 '$($s.Name)'：$($bad -join '、')" 'Red'
            $script:Fail++
        }
    }

    if ($active) {
        if (-not (Set-ActiveScheme $active)) {
            Log '[警告] 刷新当前激活电源计划失败，请重启系统生效' 'Yellow'
        }
    }

    Log ''
    Log "执行完毕：成功 $($script:Done) 项，失败 $($script:Fail) 项。" 'Cyan'
    Log '请重启 Windows 以确保驱动与电源策略完全生效。' 'Cyan'
    if ($name -eq 'Recommended') {
        Log '若仍出现“硬件还在运行但黑屏/无显示”，建议改用【强力修复】，并检查 BIOS/Ryzen Master 降压设置、核显显存分配及 AMD 芯片组驱动。' 'Gray'
    }
    if ($script:Fail -gt 0) { return 1 }
    return 0
}

# ---------------- 查看当前状态 ----------------
function Show-Status {
    Log ''
    Log "处理器   ：$cpu" 'Cyan'
    Log "操作系统 ：$winName (内部版本号 $build)$(if ($isLaptop) { ' - 笔记本设备' })" 'Cyan'
    $amd = @(Get-AmdAdapters)
    if ($amd.Count -eq 0) { Log 'AMD 显卡 ：未检测到' 'Gray' }
    foreach ($a in $amd) {
        $path = "$GpuClass\$($a.Key)"
        $u = Get-RegDword $path 'EnableUlps'
        $s = Get-RegDword $path 'PP_SclkDeepSleepDisable'
        $m = Get-RegDword $path 'PP_MclkDeepSleepDisable'
        Log "显卡 [$($a.Key)] $($a.Desc)：EnableUlps=$u | SclkDeepSleepDisable=$s | MclkDeepSleepDisable=$m" 'Gray'
    }
    Log "PCI DisableASPM 标志：$(Get-RegDword $PciKey 'DisableASPM')" 'Gray'
    $active = Get-ActiveScheme
    Log '当前激活电源计划参数（交流 AC / 电池 DC）：' 'Gray'
    foreach ($ps in $PowerSettings) {
        $v = Get-PowerValue $active $ps.Sub $ps.Id
        if ($null -eq $v) { Log ('  {0,-20} 不可用/未显示' -f $ps.Name) 'Gray' }
        else { Log ('  {0,-20} {1}% / {2}%' -f $ps.Name, $v[0], $v[1]) 'Gray' }
    }
    $has = if (Test-Path $BackupFile) { '已存在' } else { '无' }
    Log "原始设置备份状态：$has" 'Gray'
}

# ---------------- 主入口 ----------------
if (-not $interactive) {
    $rc = 0
    switch -Regex ($Mode.Trim().TrimStart('/', '-').ToLower()) {
        '^(apply|recommended|rec)$' { $rc = Invoke-Apply 'Recommended' }
        '^(max|maximum)$'           { $rc = Invoke-Apply 'Maximum' }
        '^(restore|undo)$'          { $rc = Invoke-Restore }
        '^status$'                  { Show-Status }
        default { Log "未知参数 '$Mode'。可用参数：/apply  /max  /restore  /status" 'Red'; $rc = 2 }
    }
    exit $rc
}

while ($true) {
    Write-Host ''
    Write-Host '  AMD Ryzen 4000/5000 稳定性修复工具 (Windows 10 / 11)' -ForegroundColor Cyan
    Write-Host "  处理器 ：$cpu"
    Write-Host "  系统   ：$winName (Build $build)"
    if (-not $isRyzen) { Write-Host '  提示   ：当前未检测到 Ryzen 4000/5000 系列 CPU。' -ForegroundColor Yellow }
    Write-Host ''
    Write-Host '  [1] 应用【推荐修复】  (保留处理器空闲节能，兼顾稳定性与续航)'
    Write-Host '  [2] 应用【强力修复】  (禁用空闲状态 + 拉高最小处理器状态，缓解低频/降压黑屏)'
    Write-Host '  [3] 还原原始设置      (恢复备份并清理备份记录)'
    Write-Host '  [4] 查看当前状态'
    Write-Host '  [0] 退出'
    $choice = (Read-Host '请选择操作编号').Trim()
    switch ($choice) {
        '1' { [void](Invoke-Apply 'Recommended') }
        '2' { [void](Invoke-Apply 'Maximum') }
        '3' { [void](Invoke-Restore) }
        '4' { Show-Status }
        '0' { exit 0 }
        default { Write-Host '输入无效，请重新选择。' -ForegroundColor Yellow }
    }
}
