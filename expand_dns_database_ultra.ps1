# DNS Database Expander - Parallel + Temp Directory + Batch Random
# Modified to use temp directory instead of RAM disk

param(
    [string]$InputFile    = "nameservers.csv",
    [string]$OutputFile   = "nameservers-expanded.csv",
    [string]$TempDir      = $env:TEMP,           # временная директория
    [int]$ParallelJobs    = 4                    # число параллельных задач
)

$ErrorActionPreference = "Stop"

# Фиксированная временная метка
$timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# Данные для генерации
$providerPatterns = @{
    'Google' = @{ BaseIPs = @('8.8.8','8.8.4'); ASOrg='GOOGLE'; Country='US'; Reliability=1.0 }
    'Cloudflare' = @{ BaseIPs = @('1.1.1','1.0.0'); ASOrg='CLOUDFLARE'; Country='US'; Reliability=1.0 }
    'Quad9' = @{ BaseIPs = @('9.9.9','149.112.112'); ASOrg='QUAD9'; Country='CH'; Reliability=0.99 }
    'OpenDNS' = @{ BaseIPs = @('208.67.222','208.67.220'); ASOrg='OPENDNS'; Country='US'; Reliability=0.99 }
    'Yandex' = @{ BaseIPs = @('77.88.8'); ASOrg='YANDEX'; Country='RU'; Reliability=0.98 }
    'AdGuard' = @{ BaseIPs = @('94.140.14','94.140.15'); ASOrg='ADGUARD'; Country='CY'; Reliability=0.99 }
}
$ispPatterns = @{
    'Verizon' = @{ ASOrg='VERIZON'; Country='US'; Reliability=0.97 }
    'AT&T'    = @{ ASOrg='ATT'; Country='US'; Reliability=0.97 }
    'Comcast' = @{ ASOrg='COMCAST'; Country='US'; Reliability=0.96 }
    'Deutsche Telekom' = @{ ASOrg='DEUTSCHE-TELEKOM'; Country='DE'; Reliability=0.97 }
    'Orange'  = @{ ASOrg='ORANGE'; Country='FR'; Reliability=0.96 }
    'BT'      = @{ ASOrg='BT'; Country='GB'; Reliability=0.96 }
    'China Telecom' = @{ ASOrg='CHINA-TELECOM'; Country='CN'; Reliability=0.95 }
    'NTT'     = @{ ASOrg='NTT-LTD-2914'; Country='JP'; Reliability=0.97 }
    'Telstra' = @{ ASOrg='TELSTRA'; Country='AU'; Reliability=0.97 }
    'Rogers'  = @{ ASOrg='ROGERS-COMMUNICATIONS'; Country='CA'; Reliability=0.96 }
}
$dnsVersions = @('BIND','dnsmasq','PowerDNS','Unbound','Microsoft DNS','NSD','Knot DNS','MaraDNS','djbdns','Yadifa')
$countries    = @('US','CA','GB','DE','FR','JP','AU','BR','IN','RU','CN','KR','MX','ES','IT')
$providers    = @('LocalDNS','CommunityDNS','PublicDNS','FreeDNS','SecureDNS')

# Общее число записей (цель)
$targetTotal = 6279000

# ------------------------------------------------------------
# Функция для генерации одной порции данных
# ------------------------------------------------------------
function Write-PartialFile {
    param(
        [int]$PartId,
        [int]$StartIndex,
        [int]$RecordCount,
        [string]$TempPath
    )

    $rng = [System.Random]::new([System.Environment]::TickCount + $PartId)
    $writer = [System.IO.StreamWriter]::new($TempPath, $false, [System.Text.UTF8Encoding]::new($true), 65536)

    # Пишем заголовок
    $header = @('ip_address','name','as_number','as_org','country_code','city','version','error','dnssec','reliability','checked_at','created_at')
    $writer.WriteLine($($header -join ','))

    $batchSize = 1000
    $recordsDone = 0

    while ($recordsDone -lt $RecordCount) {
        $remain = $RecordCount - $recordsDone
        $currentBatch = if ($remain -ge $batchSize) { $batchSize } else { $remain }

        # Создаём массив байт для IP-адресов
        $ipBytes = [byte[]]::new(4 * $currentBatch)
        $rng.NextBytes($ipBytes)

        for ($i = 0; $i -lt $currentBatch; $i++) {
            $idx = $i * 4
            $oct1 = if ($ipBytes[$idx] -in 0,255) { $rng.Next(1,255) } else { $ipBytes[$idx] }
            $oct2 = if ($ipBytes[$idx+1] -in 0,255) { $rng.Next(1,255) } else { $ipBytes[$idx+1] }
            $oct3 = if ($ipBytes[$idx+2] -in 0,255) { $rng.Next(1,255) } else { $ipBytes[$idx+2] }
            $oct4 = if ($ipBytes[$idx+3] -in 0,255) { $rng.Next(1,255) } else { $ipBytes[$idx+3] }
            $ip = "$oct1.$oct2.$oct3.$oct4"

            $asNumber    = $rng.Next(10000, 99999)
            $dnssec      = if ($rng.Next(2) -eq 1) { 'true' } else { 'false' }
            $versionIdx  = $rng.Next($dnsVersions.Count)
            $countryIdx  = $rng.Next($countries.Count)
            $providerIdx = $rng.Next($providers.Count)

            $name = "dns.$($providers[$providerIdx].ToLower())."
            $asOrg = $providers[$providerIdx].ToUpper()
            $country = $countries[$countryIdx]
            $version = $dnsVersions[$versionIdx]
            $reliability = [math]::Round(0.7 + ($rng.NextDouble() * 0.25), 2)

            $fields = @($ip, $name, $asNumber, $asOrg, $country, '', $version, '', $dnssec, $reliability, $timestamp, $timestamp)
            $writer.WriteLine($($fields -join ','))
        }

        $recordsDone += $currentBatch
    }

    $writer.Close()
}

# ------------------------------------------------------------
# Основной блок
# ------------------------------------------------------------
Write-Host "DNS Database Expander (Ultra) - Starting..." -ForegroundColor Green

# 1. Копируем базовые записи
$baseCount = 0
if (Test-Path $InputFile) {
    Write-Host "Copying base entries from $InputFile..." -ForegroundColor Yellow
    $baseWriter = [System.IO.StreamWriter]::new($OutputFile, $false, [System.Text.UTF8Encoding]::new($true), 65536)
    $header = @('ip_address','name','as_number','as_org','country_code','city','version','error','dnssec','reliability','checked_at','created_at')
    $baseWriter.WriteLine($($header -join ','))

    $reader = New-Object System.IO.StreamReader($InputFile, [System.Text.UTF8Encoding]::new($true))
    $null = $reader.ReadLine()  # Пропускаем заголовок
    while ($null -ne ($line = $reader.ReadLine())) {
        $baseWriter.WriteLine($line)
        $baseCount++
    }
    $reader.Close()
    $baseWriter.Close()
    Write-Host "Copied $baseCount base entries."
} else {
    $baseWriter = [System.IO.StreamWriter]::new($OutputFile, $false, [System.Text.UTF8Encoding]::new($true), 65536)
    $header = @('ip_address','name','as_number','as_org','country_code','city','version','error','dnssec','reliability','checked_at','created_at')
    $baseWriter.WriteLine($($header -join ','))
    $baseWriter.Close()
}

# 2. Сколько ещё нужно сгенерировать?
$remaining = $targetTotal - $baseCount
if ($remaining -le 0) {
    Write-Host "Base file already contains $baseCount records, no generation needed." -ForegroundColor Green
    exit
}

Write-Host "Need to generate $remaining additional records. Splitting into $ParallelJobs parallel jobs..." -ForegroundColor Cyan

# 3. Подготовка временных файлов
$tempFiles = @()
$jobs = @()
$recordsPerJob = [math]::Floor($remaining / $ParallelJobs)
$extra = $remaining % $ParallelJobs

for ($i = 0; $i -lt $ParallelJobs; $i++) {
    $partCount = $recordsPerJob
    if ($i -lt $extra) { $partCount++ }
    $tempFile = Join-Path $TempDir "dns_part_$i.csv"
    $tempFiles += $tempFile

    $jobs += Start-ThreadJob -ScriptBlock ${function:Write-PartialFile} -ArgumentList $i, 0, $partCount, $tempFile
}

# 4. Ожидание завершения
Write-Host "Waiting for parallel jobs to complete..." -ForegroundColor Yellow
$jobs | Wait-Job | Out-Null

# 5. Проверка результатов
$failed = $false
foreach ($job in $jobs) {
    if ($job.State -ne 'Completed') {
        Write-Host "Job $($job.Id) failed:" -ForegroundColor Red
        Receive-Job $job
        $failed = $true
    }
}
if ($failed) {
    throw "Some parallel jobs failed. Aborting."
}

Write-Host "All parallel jobs completed. Merging files..." -ForegroundColor Green

# 6. Объединение временных файлов
$mergeWriter = [System.IO.StreamWriter]::new($OutputFile, $true, [System.Text.UTF8Encoding]::new($true), 65536)  # append mode

foreach ($tempFile in $tempFiles) {
    $reader = New-Object System.IO.StreamReader($tempFile, [System.Text.UTF8Encoding]::new($true))
    $null = $reader.ReadLine()  # Пропускаем заголовок
    
    while ($null -ne ($line = $reader.ReadLine())) {
        $mergeWriter.WriteLine($line)
    }
    $reader.Close()
    Remove-Item $tempFile
}

$mergeWriter.Close()

# 7. Статистика
Write-Host "Done! Counting records in $OutputFile..." -ForegroundColor Green
$totalLines = (Get-Content $OutputFile | Measure-Object -Line).Lines - 1
Write-Host "$totalLines records generated" -ForegroundColor Yellow
Write-Host "Expansion completed successfully!" -ForegroundColor Green
