param(
    [string] $SavesRoot = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Zomboid\Saves'),
    [string] $Output = 'artifacts/app',
    [string] $DotNetPath = 'C:\Program Files\dotnet\dotnet.exe',
    [switch] $SkipPublish,
    [switch] $SkipApp
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$outputPath = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot $Output))
$testProject = Join-Path $repositoryRoot 'tests/PzTools.Backup.Tests/PzTools.Backup.Tests.csproj'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'A15 USN 실장 검증은 관리자 권한 PowerShell에서 실행해야 합니다.'
}

if (-not (Test-Path -LiteralPath $DotNetPath -PathType Leaf)) {
    $command = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw 'dotnet 실행 파일을 찾을 수 없습니다. -DotNetPath로 경로를 지정하십시오.'
    }
    $DotNetPath = $command.Source
}
$dotnet = [System.IO.Path]::GetFullPath($DotNetPath)

if (-not (Test-Path -LiteralPath $SavesRoot -PathType Container)) {
    throw "실제 세이브 루트를 찾을 수 없습니다: $SavesRoot"
}
$resolvedSavesRoot = (Resolve-Path -LiteralPath $SavesRoot).Path

if (-not $SkipPublish) {
    & (Join-Path $PSScriptRoot 'publish-app.ps1') `
        -Configuration Release -Output $Output -DotNetPath $dotnet
    if ($LASTEXITCODE -ne 0) {
        throw 'Release 앱 게시에 실패했습니다.'
    }
}

$appPath = Join-Path $outputPath 'PzTools.App.exe'
if (-not (Test-Path -LiteralPath $appPath -PathType Leaf)) {
    throw "게시 앱을 찾을 수 없습니다: $appPath"
}

$priorToolsDir = $env:PZTOOLS_TOOLS_DIR
$priorRealSavesRoot = $env:PZTOOLS_REAL_SAVES_ROOT
$priorUsn = $env:PZTOOLS_TEST_USN
try {
    $env:PZTOOLS_TOOLS_DIR = $outputPath
    $env:PZTOOLS_REAL_SAVES_ROOT = $resolvedSavesRoot
    $env:PZTOOLS_TEST_USN = '1'

    Write-Host 'Release 전체 테스트와 실제 USN/세이브/게시 프로세스 검증을 시작합니다.'
    & $dotnet test $testProject -c Release --logger 'console;verbosity=minimal'
    if ($LASTEXITCODE -ne 0) {
        throw 'A15 Release 종단 테스트에 실패했습니다.'
    }
}
finally {
    $env:PZTOOLS_TOOLS_DIR = $priorToolsDir
    $env:PZTOOLS_REAL_SAVES_ROOT = $priorRealSavesRoot
    $env:PZTOOLS_TEST_USN = $priorUsn
}

if (-not $SkipApp) {
    Write-Host ''
    Write-Host '게시 앱을 실행합니다. 앱을 닫기 전에 아래 항목을 확인하십시오.'
    Write-Host '  1. 한국어/영어 전환과 시스템/밝음/어두움 테마'
    Write-Host '  2. 넓은 3단 화면과 좁은 목록/상세 전환, 키보드 focus와 잘림'
    Write-Host '  3. 플레이 시작 시 활성 overlay, 진행 카드와 다음 백업 countdown'
    Write-Host '  4. 플레이 종료 후 final backup 1회 및 대상 해제'
    Write-Host '  5. 수동 백업, 복구 modal, archive 가져오기/내보내기'
    Write-Host '확인을 마치면 앱 창을 닫으십시오. 이후 잔류 프로세스를 검사합니다.'

    $app = Start-Process -FilePath $appPath -PassThru
    Wait-Process -Id $app.Id
    Start-Sleep -Seconds 2

    $remaining = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -like 'PzTools*' }
    if ($remaining) {
        $names = ($remaining | ForEach-Object { "$($_.ProcessName)($($_.Id))" }) -join ', '
        throw "앱 종료 후 PzTools 프로세스가 남아 있습니다: $names"
    }
    Write-Host '앱 종료 후 잔류 PzTools 프로세스가 없습니다.'
}

Write-Host 'A15 자동 검증이 통과했습니다. 표시된 UI 체크리스트 결과를 검증 보고서에 기록하십시오.'
