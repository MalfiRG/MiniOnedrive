Using namespace System.IO
Using module ./Utils.psm1
Using module ./FileValidator.psm1
Using module ./CheckpointManager.psm1


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
        $relativePath = [Path]::GetRelativePath($this.SourceRoot, $sourcePath)
        $replicaPath = Join-Path $this.ReplicaRoot $relativePath
        
        $syncOperation = {
            if (-not (Test-Path $sourcePath -ErrorAction Stop)) {
                throw "Source file not found: $sourcePath"
            }
    
            $fileInfo = Get-Item $sourcePath -ErrorAction Stop
            if (-not $this.Validator.NeedsSync($fileInfo)) { return }
    
            $directory = Split-Path $replicaPath -Parent
            if (-not (Test-Path $directory)) {
                New-Item -Path $directory -ItemType Directory -Force | Out-Null
                $this.Logger.Log("Created directory: $directory", "DIRCREATE")
            }
    
            Copy-Item $sourcePath $replicaPath -Force -ErrorAction Stop
            
            $hash = $this.Validator.FileHashCache[$sourcePath]
            $SourceACL = Get-Acl $sourcePath
            $replicaACL = Set-Acl -Path $replicaPath -AclObject $SourceACL -Passthru
            $this.CheckpointManager.UpdateFileEntry($relativePath, $hash, $fileInfo.LastWriteTimeUtc, $replicaACL.AccessToString)
            $this.CheckpointManager.SaveCheckpoint()
            $this.Logger.Log("Synced file: $relativePath", "FILEUPDATE")
        }
        
        try {
            [Utilities]::InvokeWithRetry($syncOperation, 3, 1, 2, "SyncFile: $relativePath", $this.Logger)
        }
        catch {
            [Utilities]::HandleError("SyncFile", $relativePath, $_, $this.Logger, $false)
        }
    }

    [void] DeleteOrphan([string]$replicaPath) {
        $relativePath = [Path]::GetRelativePath($this.ReplicaRoot, $replicaPath)
        Remove-Item $replicaPath -Force
        $this.CheckpointManager.RemoveFileEntry($relativePath)
        $this.Logger.Log("Removed orphan: $relativePath", "FILEDELETE")
    }
}