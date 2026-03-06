# DNS Database Expander - Parallel Jobs Version
# Uses Start-Job for compatibility

param(
    [string]$InputFile    = "nameservers.csv",
    [string]$OutputFile   = "nameservers-expanded.csv",
    [string]$TempDir      = $env:TEMP,
    [int]$ParallelJobs    = 4
)

$ErrorActionPreference = "Stop"
$timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# Данные для генерации
$dnsVersions = @('BIND','dnsmasq','PowerDNS','Unbound','Microsoft DNS','NSD','Knot DNS','MaraDNS','djbdns','Yadifa')
$countries    = @('US','CA','GB','DE','FR','JP','AU','BR','IN','RU','CN','KR','MX','ES','IT')
$providers    = @('LocalDNS','CommunityDNS','PublicDNS','FreeDNS','SecureDNS')
$targetTotal = 6279000

# ------------------------------------------------------------
# Функция для генерации одной порции данных
# ------------------------------------------------------------
function Write-PartialFile {
    param(
        [int]$PartId,
        [int]$RecordCount,
        [string]$TempPath,
        [string]$Timestamp,
        [string[]]$DNSVersions,
        [string[]]$Countries,
        [string[]]$Providers
    )

    $rng = [System.Random]::new([System.Environment]::TickCount + $PartId)
    $writer = [System.IO.StreamWriter]::new($TempPath, $false, [System.Text.UTF8Encoding]::new($true), 65536)

    # Пишем заголовок
    $header = @('ip_address','name','as_number','as_org','country_code','city','version','error','dnssec','reliability','checked_at','created_at')
    $writer.WriteLine($($header -join ','))

    $batchSize = 10000  # Увеличим для производительности
    $recordsDone = 0

    while ($recordsDone -lt $RecordCount) {
        $remain = $RecordCount - $recordsDone
        $currentBatch = if ($remain -ge $batchSize) { $batchSize } else { $remain }

        # Генерируем пачку записей
        for ($i = 0; $i -lt $currentBatch; $i++) {
            $ip = "$($rng.Next(1,255)).$($rng.Next(1,255)).$($rng.Next(1,255)).$($rng.Next(1,255))"
            $asNumber = $rng.Next(10000, 99999)
            $dnssec = if ($rng.Next(2) -eq 1) { 'true' } else { 'false' }
            $versionIdx = $rng.Next($DNSVersions.Count)
            $countryIdx = $rng.Next($Countries.Count)
            $providerIdx = $rng.Next($Providers.Count)

            $name = "dns.$($Providers[$providerIdx].ToLower())."
            $asOrg = $Providers[$providerIdx].ToUpper()
            $country = $Countries[$countryIdx]
            $version = $DNSVersions[$versionIdx]
            $reliability = [math]::Round(0.7 + ($rng.NextDouble() * 0.25), 2)

            $fields = @($ip, $name, $asNumber, $asOrg, $country, '', $version, '', $dnssec, $reliability, $Timestamp, $Timestamp)
            $writer.WriteLine($($fields -join ','))
        }

        $recordsDone += $currentBatch
        if ($recordsDone % 100000 -eq 0) {
            Write-Host "Part $PartId : Generated $recordsDone / $RecordCount records"
        }
    }

    $writer.Close()
}

# ------------------------------------------------------------
# Основной блок
# ------------------------------------------------------------
Write-Host "DNS Database Expander (Parallel Jobs) - Starting..." -ForegroundColor Green

# 1. Копируем базовые записи
$baseCount = 0
if (Test-Path $InputFile) {
    Write-Host "Copying base entries from $InputFile..." -ForegroundColor Yellow
    $baseWriter = [System.IO.StreamWriter]::new($OutputFile, $false, [System.Text.UTF8Encoding]::new($true), 65536)
    $header = @('ip_address','name','as_number','as_org','country_code','city','version','error','dnssec','reliability','checked_at','created_at')
    $baseWriter.WriteLine($($header -join ','))

    $reader = New-Object System.IO.StreamReader($InputFile, [System.Text.UTF8Encoding]::new($true))
    $null = $reader.ReadLine()
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

# 3. Подготовка временных файлов и запуск заданий
$tempFiles = @()
$jobs = @()
$recordsPerJob = [math]::Floor($remaining / $ParallelJobs)
$extra = $remaining % $ParallelJobs

for ($i = 0; $i -lt $ParallelJobs; $i++) {
    $partCount = $recordsPerJob
    if ($i -lt $extra) { $partCount++ }
    $tempFile = Join-Path $TempDir "dns_part_$i.csv"
    $tempFiles += $tempFile

    $scriptBlock = {
        param($PartId, $RecordCount, $TempPath, $Timestamp, $DNSVersions, $Countries, $Providers)
        
        function Write-PartialFile {
            param(
                [int]$PartId,
                [int]$RecordCount,
                [string]$TempPath,
                [string]$Timestamp,
                [string[]]$DNSVersions,
                [string[]]$Countries,
                [string[]]$Providers
            )

            $rng = [System.Random]::new([System.Environment]::TickCount + $PartId)
            $writer = [System.IO.StreamWriter]::new($TempPath, $false, [System.Text.UTF8Encoding]::new($true), 65536)

            $header = @('ip_address','name','as_number','as_org','country_code','city','version','error','dnssec','reliability','checked_at','created_at')
            $writer.WriteLine($($header -join ','))

            $batchSize = 10000
            $recordsDone = 0

            while ($recordsDone -lt $RecordCount) {
                $remain = $RecordCount - $recordsDone
                $currentBatch = if ($remain -ge $batchSize) { $batchSize } else { $remain }

                for ($i = 0; $i -lt $currentBatch; $i++) {
                    $ip = "$($rng.Next(1,255)).$($rng.Next(1,255)).$($rng.Next(1,255)).$($rng.Next(1,255))"
                    $asNumber = $rng.Next(10000, 99999)
                    $dnssec = if ($rng.Next(2) -eq 1) { 'true' } else { 'false' }
                    $versionIdx = $rng.Next($DNSVersions.Count)
                    $countryIdx = $rng.Next($Countries.Count)
                    $providerIdx = $rng.Next($Providers.Count)

                    $name = "dns.$($Providers[$providerIdx].ToLower())."
                    $asOrg = $Providers[$providerIdx].ToUpper()
                    $country = $Countries[$countryIdx]
                    $version = $DNSVersions[$versionIdx]
                    $reliability = [math]::Round(0.7 + ($rng.NextDouble() * 0.25), 2)

                    $fields = @($ip, $name, $asNumber, $asOrg, $country, '', $version, '', $dnssec, $reliability, $Timestamp, $Timestamp)
                    $writer.WriteLine($($fields -join ','))
                }

                $recordsDone += $currentBatch
            }

            $writer.Close()
        }

        Write-PartialFile -PartId $PartId -RecordCount $RecordCount -TempPath $TempPath -Timestamp $Timestamp -DNSVersions $DNSVersions -Countries $Countries -Providers $Providers
    }

    $jobs += Start-Job -ScriptBlock $scriptBlock -ArgumentList $i, $partCount, $tempFile, $timestamp, $dnsVersions, $countries, $providers
    Write-Host "Started job $i for $partCount records"
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
$mergeWriter = [System.IO.StreamWriter]::new($OutputFile, $true, [System.Text.UTF8Encoding]::new($true), 65536)

foreach ($tempFile in $tempFiles) {
    if (Test-Path $tempFile) {
        $reader = New-Object System.IO.StreamReader($tempFile, [System.Text.UTF8Encoding]::new($true))
        $null = $reader.ReadLine()  # Пропускаем заголовок
        
        while ($null -ne ($line = $reader.ReadLine())) {
            $mergeWriter.WriteLine($line)
        }
        $reader.Close()
        Remove-Item $tempFile
    }
}

$mergeWriter.Close()

# 7. Очистка заданий
$jobs | Remove-Job

# 8. Статистика
Write-Host "Done! Counting records in $OutputFile..." -ForegroundColor Green
$totalLines = (Get-Content $OutputFile | Measure-Object -Line).Lines - 1
Write-Host "$totalLines records generated" -ForegroundColor Yellow
Write-Host "Expansion completed successfully!" -ForegroundColor Green
