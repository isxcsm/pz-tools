<#
Dot-sourced by the request-*.ps1 scripts: sends one request to the elevated launcher (register-elevated-launcher.ps1)
and waits for its answer.
#>

# Writes the request with a new id, starts the task and prints its answer. Exits 0 when it succeeded, else 1.
# $answerPrefix: how the answer to this kind of request starts. A launcher registered before the kind existed takes the
# request for an app restart and answers something else.
function Invoke-ElevatedRequest([hashtable]$request, [int]$timeoutSeconds, [string]$answerPrefix = '') {
    $exchange = Join-Path $env:LOCALAPPDATA 'PzToolsDev'
    $resultPath = Join-Path $exchange 'result.json'
    New-Item -ItemType Directory -Force -Path $exchange | Out-Null
    $id = [guid]::NewGuid().ToString('N')
    $request.id = $id
    ($request | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $exchange 'request.json') -Encoding UTF8

    & schtasks.exe /Run /TN '\PzToolsDev\ElevatedLaunch' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not start the task \PzToolsDev\ElevatedLaunch. Is it registered?' }

    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $resultPath) {
            $result = $null
            try { $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json } catch { }
            if ($result -and $result.id -eq $id) {
                Write-Host $result.message
                if ($answerPrefix -and -not ([string]$result.message).StartsWith($answerPrefix)) {
                    Write-Host 'The registered launcher predates this request: run register-elevated-launcher.ps1 again from an administrator PowerShell.'
                    exit 1
                }
                if ($result.ok) { exit 0 }
                exit 1
            }
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Host "No answer from the launcher within $timeoutSeconds seconds."
    exit 1
}
