using namespace System.IO

param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -Path $_ })]
    [string]$SourceFolder,

    [Parameter(Mandatory = $true)]
    [string]$ReplicaFolder,

    [Parameter(Mandatory = $true)]
    [string]$LogPath
)

class Logger {
    [string]$LogPath

    Logger([string]$logPath) {
        $this.LogPath = $logPath
        if (-not (Test-Path $logPath)) {
            New-Item -Path $logPath -Force | Out-Null
        }
    }

    [void] Log([string]$message, [string]$action) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $entry = "[$timestamp] [$action] $message"
        Write-Host $entry
        Add-Content -Path $this.LogPath -Value $entry
    }
}

class CheckpointManager {
    [string]$CheckpointPath
    [hashtable]$CheckpointData = @{}

    CheckpointManager([string]$replicaPath) {
        $this.CheckpointPath = Join-Path $replicaPath ".synchashes"
        $this.LoadCheckpoint()
    }

    [void] LoadCheckpoint() {
        if (Test-Path $this.CheckpointPath) {
            $content = Get-Content $this.CheckpointPath -Raw
            $this.CheckpointData = ConvertFrom-Json $content -AsHashtable
        }
    }

    [void] SaveCheckpoint() {
        $this.CheckpointData | ConvertTo-Json -Depth 5 | Set-Content $this.CheckpointPath
    }

    [void] UpdateFileEntry([string]$relativePath, [string]$hash, [datetime]$lastModified, [string]$acl) {
        $this.CheckpointData[$relativePath] = @{
            SHA256       = $hash
            LastModified = $lastModified.ToString("o")
            ACL          = $acl
        }
    }

    [void] RemoveFileEntry([string]$relativePath) {
        $this.CheckpointData.Remove($relativePath)
    }
}

class FileValidator {
    [string]$SourceRoot
    [string]$ReplicaRoot
    [CheckpointManager]$CheckpointManager

    FileValidator([string]$sourceRoot, [string]$replicaRoot, [CheckpointManager]$checkpointManager) {
        $this.SourceRoot = $sourceRoot
        $this.ReplicaRoot = $replicaRoot
        $this.CheckpointManager = $checkpointManager
    }

    [bool] NeedsSync([FileInfo]$sourceFile) {
        $relativePath = [Path]::GetRelativePath($this.SourceRoot, $sourceFile.FullName)
        $replicaPath = Join-Path $this.ReplicaRoot $relativePath

        # Phase 1: Check ACL changes
        if (-not (Test-Path $replicaPath)) { return $true }
        $sourceAcl = (Get-Acl $sourceFile.FullName).AccessToString
        $replicaAcl = (Get-Acl $replicaPath).AccessToString
        if ($sourceAcl -ne $replicaAcl) { return $true }

        # Phase 2: Check timestamp
        $checkpointEntry = $this.CheckpointManager.CheckpointData[$relativePath]
        $sourceModified = $sourceFile.LastWriteTimeUtc
        if ([datetime]::Parse($checkpointEntry.LastModified) -ne $sourceModified) {
            return $true
        }

        # Phase 3: Check content hash
        $currentHash = (Get-FileHash $sourceFile.FullName -Algorithm SHA256).Hash
        return $currentHash -ne $checkpointEntry.SHA256
    }
}

class FileSynchronizer {
    [string]$SourceRoot
    [string]$ReplicaRoot
    [Logger]$Logger
    [CheckpointManager]$CheckpointManager
    [FileValidator]$Validator

    FileSynchronizer(
        [string]$sourceRoot,
        [string]$replicaRoot,
        [Logger]$logger,
        [CheckpointManager]$checkpointManager,
        [FileValidator]$validator
    ) {
        $this.SourceRoot = $sourceRoot
        $this.ReplicaRoot = $replicaRoot
        $this.Logger = $logger
        $this.CheckpointManager = $checkpointManager
        $this.Validator = $validator
    }

    [void] SyncFile([string]$sourcePath) {
        $retryCount = 0
        $maxRetries = 3
        $relativePath = [Path]::GetRelativePath($this.SourceRoot, $sourcePath)
        $replicaPath = Join-Path $this.ReplicaRoot $relativePath

        while ($retryCount -lt $maxRetries) {
            try {
                $fileInfo = Get-Item $sourcePath
                if (-not $this.Validator.NeedsSync($fileInfo)) { return }

                # Ensure directory structure exists
                $directory = Split-Path $replicaPath -Parent
                if (-not (Test-Path $directory)) {
                    New-Item -Path $directory -ItemType Directory -Force | Out-Null
                    $this.Logger.Log("Created directory: $directory", "DIRCREATE")
                }

                # Copy with verification
                Copy-Item $sourcePath $replicaPath -Force
                if (-not (Test-Path $replicaPath)) {
                    throw "File copy failed: $relativePath"
                }

                # Update checkpoint
                $hash = (Get-FileHash $sourcePath -Algorithm SHA256).Hash
                $acl = (Get-Acl $sourcePath).AccessToString
                $this.CheckpointManager.UpdateFileEntry($relativePath, $hash, $fileInfo.LastWriteTimeUtc, $acl)
                $this.Logger.Log("Synced file: $relativePath", "FILEUPDATE")
                return
            }
            catch {
                $retryCount++
                $this.Logger.Log("Retry $retryCount for $relativePath - $_", "WARNING")
                Start-Sleep -Seconds (2 * $retryCount)
            }
        }
        $this.Logger.Log("Failed to sync: $relativePath", "ERROR")
    }

    [void] DeleteOrphan([string]$replicaPath) {
        $relativePath = [Path]::GetRelativePath($this.ReplicaRoot, $replicaPath)
        Remove-Item $replicaPath -Force
        $this.CheckpointManager.RemoveFileEntry($relativePath)
        $this.Logger.Log("Removed orphan: $relativePath", "FILEDELETE")
    }
}

class FolderSynchronizer {
    [FileSystemWatcher]$Watcher
    [FileSynchronizer]$Synchronizer
    [System.Timers.Timer]$DebounceTimer = [System.Timers.Timer]::new(500)
    [System.Collections.Generic.List[string]]$PendingChanges = [System.Collections.Generic.List[string]]::new()

    FolderSynchronizer(
        [string]$sourcePath,
        [string]$replicaPath,
        [string]$logPath
    ) {
        $logger = [Logger]::new($logPath)
        $checkpointManager = [CheckpointManager]::new($replicaPath)
        $validator = [FileValidator]::new($sourcePath, $replicaPath, $checkpointManager)
        $this.Synchronizer = [FileSynchronizer]::new(
            $sourcePath,
            $replicaPath,
            $logger,
            $checkpointManager,
            $validator
        )
        
        $this.InitializeWatcher($sourcePath)
        $this.SetupDebounceTimer()
    }

    [void] InitializeWatcher([string]$sourcePath) {
        $this.Watcher = [FileSystemWatcher]::new($sourcePath)
        $this.Watcher.IncludeSubdirectories = $true
        $this.Watcher.NotifyFilter = 
        [NotifyFilters]::LastWrite, 
        [NotifyFilters]::FileName, 
        [NotifyFilters]::Security

        Register-ObjectEvent -InputObject $this.Watcher -EventName Created -Action { $this.AddChange($EventArgs.FullPath) }
        Register-ObjectEvent -InputObject $this.Watcher -EventName Changed -Action { $this.AddChange($EventArgs.FullPath) }
        Register-ObjectEvent -InputObject $this.Watcher -EventName Deleted -Action { $this.ProcessDeletion($EventArgs.FullPath) }
        Register-ObjectEvent -InputObject $this.Watcher -EventName Renamed -Action { $this.ProcessRename($EventArgs) }

        $this.Watcher.EnableRaisingEvents = $true
    }

    [void] SetupDebounceTimer() {
        $this.DebounceTimer.AutoReset = $false
        $this.DebounceTimer.Add_Elapsed({
                $uniquePaths = $this.PendingChanges | Sort-Object -Unique
                $this.PendingChanges.Clear()
                foreach ($path in $uniquePaths) {
                    $this.Synchronizer.SyncFile($path)
                }
                $this.Synchronizer.CheckpointManager.SaveCheckpoint()
            })
    }

    [void] AddChange([string]$fullPath) {
        $this.PendingChanges.Add($fullPath)
        $this.DebounceTimer.Stop()
        $this.DebounceTimer.Start()
    }

    [void] ProcessDeletion([string]$fullPath) {
        $relativePath = [Path]::GetRelativePath($this.Synchronizer.SourceRoot, $fullPath)
        $replicaPath = Join-Path $this.Synchronizer.ReplicaRoot $relativePath
        $this.Synchronizer.DeleteOrphan($replicaPath)
    }

    [void] ProcessRename([System.IO.RenamedEventArgs]$e) {
        $oldRelative = [Path]::GetRelativePath($this.Synchronizer.SourceRoot, $e.OldFullPath)
        $newRelative = [Path]::GetRelativePath($this.Synchronizer.SourceRoot, $e.FullPath)
        $this.ProcessDeletion($e.OldFullPath)
        $this.AddChange($e.FullPath)
    }


    [void] FullSync() {
        Get-ChildItem -Path $this.Synchronizer.SourceRoot -Recurse -File | ForEach-Object {
            $this.Synchronizer.SyncFile($_.FullName)
        }
        $this.Synchronizer.CheckpointManager.SaveCheckpoint()
    }

    [void] CleanupReplica() {
        Get-ChildItem -Path $this.Synchronizer.ReplicaRoot -Recurse -File | ForEach-Object {
            $relativePath = [Path]::GetRelativePath($this.Synchronizer.ReplicaRoot, $_.FullName)
            $sourcePath = Join-Path $this.Synchronizer.SourceRoot $relativePath
            if (-not (Test-Path $sourcePath)) {
                $this.Synchronizer.DeleteOrphan($_.FullName)
            }
        }
    }
}

$synchronizer = [FolderSynchronizer]::new($SourceFolder, $ReplicaFolder, $LogPath)
$synchronizer.FullSync()
$synchronizer.CleanupReplica()

try {
    while ($true) { Start-Sleep -Seconds 60 }
}
finally {
    $synchronizer.Synchronizer.CheckpointManager.SaveCheckpoint()
}
