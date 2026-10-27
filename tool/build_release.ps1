param([switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
$workspace = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Push-Location -LiteralPath $workspace
try {
    if (-not $SkipBuild) {
        & flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64 --obfuscate --split-debug-info=build/symbols
        if ($LASTEXITCODE -ne 0) { throw 'Release build failed.' }
    }
    $reports = @()
    foreach ($abi in @('armeabi-v7a','arm64-v8a')) {
        $apk = Get-Item -LiteralPath "build/app/outputs/flutter-apk/app-$abi-release.apk"
        $reports += [pscustomobject]@{
            abi = $abi
            apk = $apk.FullName
            bytes = $apk.Length
            decimalMB = [Math]::Round($apk.Length / 1000000, 6)
            MiB = [Math]::Round($apk.Length / 1048576, 6)
            below20MB = $apk.Length -lt 20000000
            sha256 = (Get-FileHash -LiteralPath $apk.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        if ($apk.Length -ge 20000000) { throw "$abi APK failed strict < 20,000,000 byte limit." }
    }
    [System.IO.Directory]::CreateDirectory((Join-Path $workspace 'artifacts')) | Out-Null
    $reports | ConvertTo-Json | Set-Content -LiteralPath 'artifacts/apk-sizes.json' -Encoding UTF8
    $reports | Format-Table abi,bytes,decimalMB,MiB,below20MB
    Write-Output 'Measured installable APK files. Download and installed sizes are separate measurements.'
} finally { Pop-Location }
