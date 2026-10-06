#  record_w-tv.ps1
## Requirements: ffmpeg
### Usage: .\record_w-tv.ps1 -Channels "nickname1,nickname2,nickname3"

param(
    [Parameter(Mandatory)]
    [string]$Channels
)

$CHECK_INTERVAL = 6
$SCRIPT_DIR = $PWD.Path

$channelNickname  = @{}
$channelRecording = @{}
$channelPid       = @{}
$channelLog       = @{}
$channelStreamId  = @{}
$channelFfmpegLog = @{}
$channelOutFile   = @{}
$channelStartTime = @{}

function Write-Log {
    param([string]$LogFile, [string]$Text)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH-mm-ss'
    $line = "$timestamp | $Text"

    $sw = [System.IO.StreamWriter]::new($LogFile, $true, [System.Text.Encoding]::UTF8)
    try { $sw.WriteLine($line) } finally { $sw.Close() }
}

function Get-UserId {
    param([string]$Nickname)
    try {
        $response = Invoke-RestMethod `
            -Uri "https://profiles-service.w.tv/api/v1/profiles/by-nickname/$Nickname" `
            -TimeoutSec 6 -ErrorAction Stop
        return $response.profile.userId
    } catch {
        return $null
    }
}

function Start-Ffmpeg {
    param([string]$UserId, [string]$Nickname, [string]$PlaybackUrl)

    $timestamp  = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $outFile    = Join-Path $SCRIPT_DIR "${Nickname}-w-tv-${timestamp}.ts"

    $logFile    = Join-Path $SCRIPT_DIR "${Nickname}-w-tv-${timestamp}_events.log"
    $ffmpegLog  = Join-Path $SCRIPT_DIR "${Nickname}-w-tv-${timestamp}_ffmpeg.log"

    $channelLog[$UserId]       = $logFile
    $channelRecording[$UserId] = $true

    Write-Log $logFile "START | $Nickname"
    Write-Log $logFile "URL   | $PlaybackUrl"
    Write-Log $logFile "FILE  | $outFile"

    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "$ts | START | $Nickname | recording to $outFile"

    $ffmpegArgs = @(
        '-hide_banner'
        '-loglevel', 'warning'
        '-fflags', '+genpts+discardcorrupt'
        '-err_detect', 'ignore_err'
        '-stats'
        '-stats_period', '1400'
        '-i', $PlaybackUrl
        '-c', 'copy'
        $outFile
    )

    $proc = Start-Process -FilePath 'ffmpeg' `
                          -ArgumentList $ffmpegArgs `
                          -RedirectStandardError $ffmpegLog `
                          -NoNewWindow `
                          -PassThru

    $null = $proc.Handle   # кэшируем handle, иначе ExitCode может быть $null

    $channelPid[$UserId]       = $proc
    $channelFfmpegLog[$UserId] = $ffmpegLog
    $channelOutFile[$UserId]   = $outFile
    $channelStartTime[$UserId] = Get-Date

    Write-Log $logFile "FFMPEG | started pid=$($proc.Id) ffmpeg_log=$ffmpegLog"
}

function Test-ProcessRunning {
    param([System.Diagnostics.Process]$Proc)
    if ($null -eq $Proc) { return $false }
    try { return -not $Proc.HasExited } catch { return $false }
}

function Write-CrashInfo {
    param([string]$UserId)

    $logFile   = $channelLog[$UserId]
    $proc      = $channelPid[$UserId]
    $ffmpegLog = $channelFfmpegLog[$UserId]
    $outFile   = $channelOutFile[$UserId]

    # Код выхода
    $code = $null
    if ($proc) {
        try { $proc.WaitForExit(2000) | Out-Null; $code = $proc.ExitCode } catch {}
    }
    if ($null -ne $code) {
        Write-Log $logFile ("RESTART | exit code={0} (0x{0:X8})" -f $code)
    } else {
        Write-Log $logFile "RESTART | exit code unavailable"
    }

    # Сколько проработал
    if ($channelStartTime[$UserId]) {
        $uptime = (Get-Date) - $channelStartTime[$UserId]
        Write-Log $logFile ("RESTART | ffmpeg ran {0:N1}s" -f $uptime.TotalSeconds)
    }

    # Размер выходного файла
    if ($outFile -and (Test-Path -LiteralPath $outFile)) {
        $size = (Get-Item -LiteralPath $outFile).Length
        Write-Log $logFile ("RESTART | output size={0:N0} bytes" -f $size)
    } else {
        Write-Log $logFile "RESTART | output file was not created"
    }

    # Хвост ffmpeg-лога
    if ($ffmpegLog -and (Test-Path -LiteralPath $ffmpegLog)) {
        try {
            $fs = [System.IO.File]::Open($ffmpegLog, 'Open', 'Read', 'ReadWrite')
            $sr = [System.IO.StreamReader]::new($fs)
            try { $text = $sr.ReadToEnd() } finally { $sr.Close() }

            # -stats пишет прогресс через \r, поэтому делим и по \r, и по \n
            $tail = $text -split "[\r\n]+" |
                    Where-Object { $_.Trim() } |
                    Select-Object -Last 15

            if ($tail) {
                Write-Log $logFile "RESTART | --- ffmpeg log tail ---"
                foreach ($l in $tail) { Write-Log $logFile "FFLOG | $l" }
            } else {
                Write-Log $logFile "RESTART | ffmpeg log is empty"
            }
        } catch {
            Write-Log $logFile "RESTART | failed to read ffmpeg log: $_"
        }
    } else {
        Write-Log $logFile "RESTART | ffmpeg log not found: $ffmpegLog"
    }
}

function Clear-ChannelState {
    param([string]$UserId)
    $channelRecording[$UserId] = $false
    $channelPid[$UserId]       = $null
    $channelStreamId[$UserId]  = $null
    $channelLog[$UserId]       = $null
    $channelFfmpegLog[$UserId] = $null
    $channelOutFile[$UserId]   = $null
    $channelStartTime[$UserId] = $null
}

# Resolve channels
$channelNicknames = $Channels -split ','

Write-Host "Resolving channels..."
foreach ($nick in $channelNicknames) {
    $nick = $nick.Trim()
    if (-not $nick) { continue }
    $userId = Get-UserId -Nickname $nick
    if ($userId) {
        $channelNickname[$userId] = $nick
        Clear-ChannelState -UserId $userId
        Write-Host "Channel $nick | userId=$userId"
    } else {
        Write-Host "Skipped channel $nick"
    }
}

Write-Host "Monitoring channels started..."
Write-Host "Press Ctrl+C to stop all recordings and exit."

function Stop-AllRecordings {
    Write-Host ""
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | SHUTDOWN | stopping all recordings..."
    foreach ($userId in @($channelNickname.Keys)) {
        $proc = $channelPid[$userId]
        if (Test-ProcessRunning $proc) {
            $nickname = $channelNickname[$userId]
            $logFile  = $channelLog[$userId]
            Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | STOP   | $nickname | killing ffmpeg pid=$($proc.Id)"
            if ($logFile) { Write-Log $logFile "SHUTDOWN | killed by user (Ctrl+C)" }
            $proc.Kill()
            $proc.WaitForExit(5000) | Out-Null
        }
    }
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | SHUTDOWN | done."
}

try {

while ($true) {
    foreach ($userId in @($channelNickname.Keys)) {
        $nickname = $channelNickname[$userId]
        $apiUrl   = "https://streams-search-service.w.tv/api/v1/channels/$userId"

        try {
            $response = Invoke-RestMethod -Uri $apiUrl -TimeoutSec 10 -ErrorAction Stop
        } catch {
            Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | WARN  | $nickname | API error: $_"
            continue
        }

        $live = $response.channel.live

        # STREAM START
        if ($live -eq $true -and $channelRecording[$userId] -eq $false) {
            Start-Sleep -Seconds 2
            try {
                $response = Invoke-RestMethod -Uri $apiUrl -TimeoutSec 10 -ErrorAction Stop
            } catch {
                Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | WARN  | $nickname | re-fetch failed: $_"
                continue
            }
            $playbackUrl = $response.channel.liveStream.playbackUrl
            if ([string]::IsNullOrWhiteSpace($playbackUrl)) {
                Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | WARN  | $nickname | playbackUrl empty, will retry"
                continue
            }
            $channelStreamId[$userId] = $response.channel.liveStream.streamId
            Start-Ffmpeg -UserId $userId -Nickname $nickname -PlaybackUrl $playbackUrl
        }

        # AUTO-RECONNECT (if ffmpeg crashed)
        elseif ($live -eq $true -and $channelRecording[$userId] -eq $true) {
            if (-not (Test-ProcessRunning $channelPid[$userId])) {
                $logFile = $channelLog[$userId]
                Write-Log $logFile "RESTART | ffmpeg crashed, restarting"
                Write-CrashInfo -UserId $userId
                Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | RESTART | $nickname | ffmpeg exited, see $logFile"

                $playbackUrl = $response.channel.liveStream.playbackUrl
                if ([string]::IsNullOrWhiteSpace($playbackUrl)) {
                    Write-Log $logFile "RESTART | playbackUrl empty, will retry next cycle"
                    Clear-ChannelState -UserId $userId
                    continue
                }
                Start-Ffmpeg -UserId $userId -Nickname $nickname -PlaybackUrl $playbackUrl
            }
        }

        # STREAM END
        elseif ($live -eq $false -and $channelRecording[$userId] -eq $true) {
            $logFile = $channelLog[$userId]
            $proc    = $channelPid[$userId]

            Write-Log $logFile "STOP | Stream ended"
            $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            Write-Host "$ts | STOP  | $nickname | recording ended"

            if (Test-ProcessRunning $proc) { $proc.Kill() }

            Clear-ChannelState -UserId $userId
        }
    }

    Start-Sleep -Seconds $CHECK_INTERVAL
}
} finally {
    Stop-AllRecordings
}
