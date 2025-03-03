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
    }
}

class Logger {
    [string]$LogPath

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
    static [string] CalculateFileHashParallel(
        [string]$filePath, 
        [string]$algorithm = "SHA256", 
        [int]$chunkSizeMB = 64, 
        [int]$maxThreads = 0) {
        
        $logger = [Logger]::new("C:\Users\malfi\PycharmProjects\MiniOnedrive\logs\FileHasherMgr.log")
        
        try {
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
                $maxThreads,
                $logger)
            
            $chunkHashes = [FileHasher]::CollectChunkResults($chunkResults, $fileInfo.TotalChunks)
            
            $finalHash = [FileHasher]::CombineChunkHashes($chunkHashes, $algorithm, $fileInfo.TotalChunks)
            $logger.Log("File hash $(algorithm): $finalHash", "INFO")
            return $finalHash
        }
        catch {
            [Utilities]::HandleError("CalculateFileHashParallel", $filePath, $_, $logger, $true)
            return $null
        }
    }
    
    static [void] ValidateInputs([string]$filePath, [ref]$algorithm, [ref]$maxThreads) {
        if ($maxThreads.Value -le 0) {
            $maxThreads.Value = [Environment]::ProcessorCount
        }
        
        if (-not (Test-Path -Path $filePath -PathType Leaf)) {
            throw "File not found: $filePath"
        }
        
        $validAlgorithms = @("MD5", "SHA1", "SHA256", "SHA384", "SHA512")
        if ($validAlgorithms -notcontains $algorithm.Value) {
            throw "Invalid hash algorithm. Supported algorithms: $($validAlgorithms -join ', ')"
        }
    }
    
    static [hashtable] PrepareFileInfo([string]$filePath, [int]$chunkSizeMB, [ref]$maxThreads) {
        $fileInfo = Get-Item $filePath
        $fileSize = $fileInfo.Length
        $chunkSize = $chunkSizeMB * 1MB
        $totalChunks = [math]::Ceiling($fileSize / $chunkSize)
        
        $maxThreads.Value = [Math]::Min($maxThreads.Value, $totalChunks)
        
        return @{
            FileSize    = $fileSize
            ChunkSize   = $chunkSize
            TotalChunks = $totalChunks
        }
    }
    
    static [array] CreateChunkDefinitions([long]$chunkSize, [int]$totalChunks, [long]$fileSize) {
        return (0..($totalChunks - 1)) | ForEach-Object {
            $i = $_
            $startPosition = $i * $chunkSize
            $remainingBytes = $fileSize - $startPosition
            $currentChunkSize = [Math]::Min($chunkSize, $remainingBytes)
            
            @{
                ChunkIndex    = $i
                StartPosition = $startPosition
                ChunkSize     = $currentChunkSize
            }
        }
    }
    
    static [array] ProcessChunksInParallel(
        [string]$filePath, 
        [string]$algorithm, 
        [array]$chunkDefinitions, 
        [int]$maxThreads,
        [Logger]$logger) {
        
        $cancellationSource = $null
        $logPath = Join-Path $PSScriptRoot -ChildPath "logs\ChunksProcessor.log"
        
        try {
            $logger.Log("Starting parallel processing with $maxThreads threads", "INFO")
            $cancellationSource = [System.Threading.CancellationTokenSource]::new()  
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
        $chunkHashes = @{}
        
        foreach ($result in $results) {
            $chunkHashes[$result.ChunkIndex] = $result.HashBytes
        }
        
        if ($chunkHashes.Count -ne $totalChunks) {
            throw "Some chunk hashes are missing. Expected $totalChunks, got $($chunkHashes.Count)"
        }
        
        return $chunkHashes
    }
    
    static [string] CombineChunkHashes([hashtable]$chunkHashes, [string]$algorithm, [int]$totalChunks) {
        $combinedBytes = [System.Collections.Generic.List[byte]]::new()
        
        for ($i = 0; $i -lt $totalChunks; $i++) {
            $combinedBytes.AddRange($chunkHashes[$i])
        }
        
        $finalHashAlgorithm = $null
        
        try {
            $finalHashAlgorithm = [System.Security.Cryptography.HashAlgorithm]::Create($algorithm)
            $finalHashBytes = $finalHashAlgorithm.ComputeHash($combinedBytes.ToArray())
            return [BitConverter]::ToString($finalHashBytes).Replace("-", "").ToLower()
        }
        finally {
            if ($null -ne $finalHashAlgorithm) { $finalHashAlgorithm.Dispose() }
        }
    }
}

Export-ModuleMember -Function ProcessFileChunk