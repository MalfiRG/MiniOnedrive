function ProcessFileChunk {
    param($chunkDef, $filePath, $algorithm, $logPath)
    
    $logger = [Logger]::new($logPath)
    $chunkId = "Chunk-$($chunkDef.ChunkIndex)"
    $logger.Log("Starting processing $chunkId ID", "DEBUG")

    $ErrorActionPreference = 'Stop'
    $fileStream = $null
    $hashAlgorithm = $null
    
    try {
        $logger.Log("Opening file stream for `'$chunkId`' at position $($chunkDef.StartPosition), $chunkId ID", "DEBUG")
        $fileStream = [System.IO.File]::OpenRead($filePath)
        $fileStream.Position = $chunkDef.StartPosition
        
        $buffer = New-Object byte[] $chunkDef.ChunkSize
        $bytesRead = $fileStream.Read($buffer, 0, $chunkDef.ChunkSize)
        $logger.Log("Read $bytesRead bytes from $chunkId ID", "DEBUG")
        
        if ($bytesRead -lt $chunkDef.ChunkSize) {
            $logger.Log("Resizing buffer to actual read size: $bytesRead bytes, $chunkId ID", "DEBUG")
            $actualBuffer = New-Object byte[] $bytesRead
            [Array]::Copy($buffer, $actualBuffer, $bytesRead)
            $buffer = $actualBuffer
            $logger.Log("Resized buffer to $($buffer.Length) bytes, $chunkId ID", "DEBUG")
        }
        
        $logger.Log("Creating hash algorithm instance: $algorithm, $chunkId ID", "DEBUG")
        $hashAlgorithm = [System.Security.Cryptography.HashAlgorithm]::Create($algorithm)
        $logger.Log("Computing hash for $chunkId ID", "DEBUG")
        $hashBytes = $hashAlgorithm.ComputeHash($buffer)
        $logger.Log("Hash computed for $chunkId ID", "DEBUG")
        
        $logger.Log("Processing chunk completed successfully: $chunkId ID", "INFO")
        
        return [PSCustomObject]@{
            ChunkIndex = $chunkDef.ChunkIndex
            HashBytes  = $hashBytes
        }
    }
    catch {
        [Utilities]::HandleError("ProcessFileChunk", "Chunk $chunkId", $_, $logger, $true)
    }
    finally {
        if ($null -ne $hashAlgorithm) { 
            $logger.Log("Disposing hash algorithm instance: $algorithm, $chunkId ID", "DEBUG")
            $hashAlgorithm.Dispose() 
        }
        if ($null -ne $fileStream) {
            $logger.Log("Closing file stream for $chunkId ID", "DEBUG")
            $fileStream.Dispose() 
        }
        $logger.Log("Processing $chunkId ID completed", "DEBUG")
        if ($null -ne $logger) {
            $logger.Log("Disposing logger instance for $chunkId ID", "DEBUG")
            $logger.Dispose()
        }
    }
}

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


class FileHasher {
    static [Logger] $LoggerFileHasherMgr

    static FileHasher() {
        $logPath = Join-Path $PSScriptRoot -ChildPath "logs\FileHasherMgr.log"
        [FileHasher]::LoggerFileHasherMgr = [Logger]::GetInstance($logPath)
    }

    static [string] CalculateFileHashParallel(
        [string]$filePath, 
        [string]$algorithm = "SHA256", 
        [int]$chunkSizeMB = 64, 
        [int]$maxThreads = 0) {

        try {
            $logger = [FileHasher]::LoggerFileHasherMgr

            [FileHasher]::ValidateInputs($filePath, [ref]$algorithm, [ref]$maxThreads)

            $fileInfo = [FileHasher]::PrepareFileInfo($filePath, $chunkSizeMB, [ref]$maxThreads)

            $chunkDefinitions = [FileHasher]::CreateChunkDefinitions(
                $fileInfo.ChunkSize, 
                $fileInfo.TotalChunks, 
                $fileInfo.FileSize)

            $chunkResults = [FileHasher]::ProcessChunksInParallel(
                $filePath, 
                $algorithm, 
                $chunkDefinitions, 
                $maxThreads)

            $chunkHashes = [FileHasher]::CollectChunkResults($chunkResults, $fileInfo.TotalChunks)

            $finalHash = [FileHasher]::CombineChunkHashes($chunkHashes, $algorithm, $fileInfo.TotalChunks)
            $logger.Log("File hash $($algorithm): $finalHash", "INFO")
            return $finalHash
        }
        catch {
            [Utilities]::HandleError("CalculateFileHashParallel", $filePath, $_, [FileHasher]::LoggerFileHasherMgr, $true)
            return $null
        }
    }

    static [void] ValidateInputs([string]$filePath, [ref]$algorithm, [ref]$maxThreads) {
        $logger = [FileHasher]::LoggerFileHasherMgr

        if ($maxThreads.Value -le 0) {
            $logger.Log("Invalid maximum number of threads. Setting to number of processor cores: $($maxThreads.Value)", "WARNING")
            $maxThreads.Value = [Environment]::ProcessorCount
        }

        if (-not (Test-Path -Path $filePath -PathType Leaf)) {
            [Utilities]::HandleError("ValidateInputs", "File not found", "File not found: $filePath", $logger, $true)
            throw "File not found: $filePath"
        }

        $validAlgorithms = @("MD5", "SHA1", "SHA256", "SHA384", "SHA512")
        if ($validAlgorithms -notcontains $algorithm.Value) {
            [Utilities]::HandleError("ValidateInputs", "Invalid hash algorithm", "Invalid hash algorithm: $($algorithm.Value)", $logger, $true)
            throw "Invalid hash algorithm. Supported algorithms: $($validAlgorithms -join ', ')"
        }
        $logger.Log("Validated inputs: $filePath, $algorithm, $($maxThreads.Value)", "INFO")
    }

    static [hashtable] PrepareFileInfo([string]$filePath, [int]$chunkSizeMB, [ref]$maxThreads) {
        $fileInfo = Get-Item $filePath
        $fileSize = $fileInfo.Length
        $chunkSize = $chunkSizeMB * 1MB
        $totalChunks = [math]::Ceiling($fileSize / $chunkSize)
        $logger = [FileHasher]::LoggerFileHasherMgr

        $maxThreads.Value = [Math]::Min($maxThreads.Value, $totalChunks)
        $logger.Log("File info: $filePath, $fileSize bytes, $chunkSizeMB MB chunk size, $totalChunks chunks", "INFO")

        return @{
            FileSize    = $fileSize
            ChunkSize   = $chunkSize
            TotalChunks = $totalChunks
        }
    }

    static [array] CreateChunkDefinitions([long]$chunkSize, [int]$totalChunks, [long]$fileSize) {
        $logger = [FileHasher]::LoggerFileHasherMgr

        return (0..($totalChunks - 1)) | ForEach-Object {
            $logger.Log("Creating chunk definition $_", "DEBUG")

            $i = $_
            $startPosition = $i * $chunkSize
            $remainingBytes = $fileSize - $startPosition
            $currentChunkSize = [Math]::Min($chunkSize, $remainingBytes)

            @{
                ChunkIndex    = $i
                StartPosition = $startPosition
                ChunkSize     = $currentChunkSize
            }
            $logger.Log("Chunk definition Index $_ created. Details: Start Index: $startPosition, Size: $currentChunkSize", "DEBUG")
        }
        $logger.Log("All chunk definitions created", "INFO")
    }

    static [array] ProcessChunksInParallel(
        [string]$filePath, 
        [string]$algorithm, 
        [array]$chunkDefinitions, 
        [int]$maxThreads) {
        
        $logger = [FileHasher]::LoggerFileHasherMgr
        $cancellationSource = $null
        $logPath = Join-Path $PSScriptRoot -ChildPath "logs\ChunksProcessor.log"

        try {
            $logger.Log("Starting parallel processing with $maxThreads threads", "INFO")
            $cancellationSource = [System.Threading.CancellationTokenSource]::new()  
            $logger.Log("Cancellation source created, value: $($cancellationSource.IsCancellationRequested)", "DEBUG")

            return $chunkDefinitions | ForEach-Object -ThrottleLimit $maxThreads -Parallel {
                if ($using:cancellationSource.Token.IsCancellationRequested) {
                    return
                }
                Import-Module -Name .\FileHasherHelper.psm1 -Force

                ProcessFileChunk -chunkDef $_ -filePath $using:filePath -algorithm $using:algorithm -logPath $using:logPath
            } 
        } catch {
            $logger.Log("Error in parallel processing: $_", "ERROR")
            [Utilities]::HandleError("ProcessChunksInParallel", "Parallel processing", $_, $logger, $true)
            return @()
        }
        finally {
            if ($null -ne $cancellationSource) { 
                $logger.Log("Disposing cancellation source", "INFO")
                $cancellationSource.Dispose() 
            }
        }
    }

    static [hashtable] CollectChunkResults([array]$results, [int]$totalChunks) {
        $logger = [FileHasher]::LoggerFileHasherMgr
        $chunkHashes = @{}

        foreach ($result in $results) {
            $chunkHashes[$result.ChunkIndex] = $result.HashBytes
            $logger.Log("Collected chunk hash: Chunk Index: $($result.ChunkIndex), Bytes: $($result.HashBytes.Length)", "DEBUG")
        }

        if ($chunkHashes.Count -ne $totalChunks) {
            [Utilities]::HandleError("CollectChunkResults", "Chunk hashes", "Some chunk hashes are missing. Expected $totalChunks, got $($chunkHashes.Count)", $logger, $true)
            throw "Some chunk hashes are missing. Expected $totalChunks, got $($chunkHashes.Count)"
        }

        ForEach-Object -InputObject $chunkHashes.Keys -Process {
            $logger.Log("Collected chunk hash: Index: $_, Chunk length: $($chunkHashes[$_].Length), Chunk bytes: $($chunkHashes[$_])", "DEBUG")
        }
        $logger.Log("All chunk hashes collected", "INFO")

        return $chunkHashes
    }

    static [string] CombineChunkHashes([hashtable]$chunkHashes, [string]$algorithm, [int]$totalChunks) {
        $logger = [FileHasher]::LoggerFileHasherMgr

        $combinedBytes = [System.Collections.Generic.List[byte]]::new()

        for ($i = 0; $i -lt $totalChunks; $i++) {
            $logger.Log("Combining chunk hash $i", "DEBUG")
            $combinedBytes.AddRange($chunkHashes[$i])
            $logger.Log("Combined chunk hash $i, $($combinedBytes.Count) bytes", "DEBUG")
        }

        $finalHashAlgorithm = $null

        try {
            $logger.Log("Creating final hash algorithm instance: $algorithm", "DEBUG")
            $finalHashAlgorithm = [System.Security.Cryptography.HashAlgorithm]::Create($algorithm)
            $logger.Log("Final hash algorithm instance created. ${algorithm}: Hash size: $($finalHashAlgorithm.HashSize)", "DEBUG")
            $finalHashBytes = $finalHashAlgorithm.ComputeHash($combinedBytes.ToArray())
            $logger.Log("Final hash computed, algorithm: $algorithm, bytes: $($finalHashBytes.Length)", "INFO")
            return [BitConverter]::ToString($finalHashBytes).Replace("-", "").ToLower()
        }
        finally {
            if ($null -ne $finalHashAlgorithm) { 
                $logger.Log("Disposing final hash algorithm instance", "INFO")
                $finalHashAlgorithm.Dispose() 
                $logger.Log("Final hash algorithm instance disposed", "INFO")
            }
        }
    }
}

Export-ModuleMember -Function ProcessFileChunk