class Logger {
    [string]$LogPath
    static [hashtable]$LoggerInstances = @{}

    static [Logger] GetInstance([string]$logPath) {
        if (-not [Logger]::LoggerInstances.ContainsKey($logPath)) {
            [Logger]::LoggerInstances[$logPath] = [Logger]::new($logPath)
        }
        return [Logger]::LoggerInstances[$logPath]
    }

    Logger([string]$logPath) {
        $this.LogPath = $logPath
        if (-not (Test-Path $logPath)) {
            New-Item -Path $logPath -Force | Out-Null
        }
        $this.Log("Logger initialized. Log file: $logPath", "INFO")
    }

    [void] Log([string]$message, [string]$action) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $entry = "[$timestamp] [$action] $message"
        Write-Host $entry
        Add-Content -Path $this.LogPath -Value $entry
    }
}

class Utilities {
    static [void] HandleError(
        [string]$operation, 
        [string]$context, 
        [System.Management.Automation.ErrorRecord]$errorRecord,
        [Logger]$logger,
        [bool]$rethrow = $false
    ) {
        
        $errorMessage = "[$operation] Error in $context - $($errorRecord.Exception.Message)"
        $logger.Log($errorMessage, "ERROR")
        
        $errorDetails = @{
            ErrorCategory    = $errorRecord.CategoryInfo.Category
            ErrorID          = $errorRecord.FullyQualifiedErrorId
            ScriptLineNumber = $errorRecord.InvocationInfo.ScriptLineNumber
            ScriptName       = $errorRecord.InvocationInfo.ScriptName
            Position         = $errorRecord.InvocationInfo.PositionMessage
            StackTrace       = $errorRecord.ScriptStackTrace
        }
        
        $logger.Log("Detailed error information:`n$($errorDetails | ConvertTo-Json)", "DEBUG")
        
        switch ($errorRecord.Exception.GetType().Name) {
            'IOException' {
                if ($errorRecord.Exception.Message -match 'used by another process') {
                    $logger.Log("File locked in $operation - will retry later: $context", "WARNING")
                }
            }
            'UnauthorizedAccessException' {
                $logger.Log("Permission error in $operation - $context. Verify access rights.", "ERROR")
            }
        }
        
        if ($rethrow) {
            throw $errorRecord
        }
    }
    static [void] InvokeWithRetry(
        [scriptblock]$ScriptBlock,
        [int]$MaxRetries = 3,
        [int]$InitialDelaySeconds = 1,
        [double]$BackoffMultiplier = 2,
        [string]$Operation = "Operation",
        [Logger]$Logger) {
        
        $attempt = 1
        $succeeded = $false
        
        do {
            try {
                & $ScriptBlock
                $succeeded = $true
                return
            }
            catch [System.IO.IOException] {
                $delay = $InitialDelaySeconds * [Math]::Pow($BackoffMultiplier, ($attempt - 1))
                $Logger.Log("$Operation failed (Attempt $attempt/$MaxRetries) - Retrying in $delay seconds: $_", "WARNING")
                Start-Sleep -Seconds $delay
                $attempt++
            }
            catch {
                [Utilities]::HandleError($Operation, "InvokeWithRetry", $_, $Logger, $true)
                throw
            }
        } while ((-not $succeeded) -and ($attempt -le $MaxRetries))
        
        if (-not $succeeded) {
            [Utilities]::HandleError($Operation, "InvokeWithRetry", "Maximum retry attempts ($MaxRetries) exceeded", $Logger, $true)
            throw "Maximum retry attempts ($MaxRetries) exceeded for $Operation"
        }
    }
}