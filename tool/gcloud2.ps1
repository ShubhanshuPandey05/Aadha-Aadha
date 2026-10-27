# Invoke with & (not dot-sourcing). Credentials/settings belong only to Two Tally.
# Nothing is written to the normal gcloud configuration or the PowerShell profile.
$personalConfig = Join-Path $env:LOCALAPPDATA 'TwoTally\gcloud-personal'
$isolatedVariables = @(
    'CLOUDSDK_CONFIG',
    'CLOUDSDK_ACTIVE_CONFIG_NAME',
    'CLOUDSDK_CORE_ACCOUNT',
    'CLOUDSDK_CORE_PROJECT',
    'CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE',
    'CLOUDSDK_AUTH_ACCESS_TOKEN',
    'CLOUDSDK_AUTH_ACCESS_TOKEN_FILE',
    'CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT',
    'CLOUDSDK_AUTH_LOGIN_CONFIG_FILE',
    'GOOGLE_APPLICATION_CREDENTIALS'
)
$previousValues = @{}
foreach ($name in $isolatedVariables) {
    $previousValues[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$commandExit = 1
try {
    foreach ($name in $isolatedVariables) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    [Environment]::SetEnvironmentVariable('CLOUDSDK_CONFIG', $personalConfig, 'Process')
    [Environment]::SetEnvironmentVariable('CLOUDSDK_ACTIVE_CONFIG_NAME', 'default', 'Process')
    & gcloud.cmd @args
    $commandExit = $LASTEXITCODE
} finally {
    foreach ($name in $isolatedVariables) {
        [Environment]::SetEnvironmentVariable($name, $previousValues[$name], 'Process')
    }
}
exit $commandExit
