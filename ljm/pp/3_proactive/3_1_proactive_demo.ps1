$baseUrl = "https://fiveline.store"
$results = @{ success = 0; blocked = 0 }

Write-Host "=== global-rate-limit Test (threshold: 2000 req/5min) ===" -ForegroundColor Cyan
Write-Host "URL: $baseUrl" -ForegroundColor Cyan
Write-Host ""

for ($i = 1; $i -le 3000; $i++) {
    $url = "$baseUrl/?bust=$i"
    try {
        $res = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5
        $results.success++
        if ($i % 200 -eq 0) {
            Write-Host "[$i] $($res.StatusCode) OK" -ForegroundColor Green
        }
        Start-Sleep -Milliseconds 50
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        $results.blocked++
        Write-Host "[$i] BLOCKED $code Too Many Requests" -ForegroundColor Red
        if ($results.blocked -ge 5) {
            Write-Host ""
            Write-Host "=== Rate limit triggered. Test complete. ===" -ForegroundColor Yellow
            break
        }
    }
}

Write-Host ""
Write-Host "=== Result ===" -ForegroundColor Cyan
Write-Host "Success : $($results.success)" -ForegroundColor Green
Write-Host "Blocked : $($results.blocked)" -ForegroundColor Red
