Using namespace System.IO
Using module ./CheckpointManager.psm1
Using module ./Utils.psm1

class FileValidator {
    [string]$SourceRoot
    [string]$ReplicaRoot
    [CheckpointManager]$CheckpointManager
    [Logger]$Logger
    [hashtable]$FileHashCache

    FileValidator([string]$sourceRoot, [string]$replicaRoot, [CheckpointManager]$checkpointManager, [Logger]$logger) {
        $this.SourceRoot = $sourceRoot
        $this.ReplicaRoot = $replicaRoot
        $this.CheckpointManager = $checkpointManager
        $this.Logger = $logger
        $this.FileHashCache = @{}
    }

    [bool] NeedsSync([FileInfo]$sourceFile) {
        try {
            $relativePath = [Path]::GetRelativePath($this.SourceRoot, $sourceFile.FullName)
            $replicaPath = Join-Path $this.ReplicaRoot $relativePath
            $checkpointEntry = $this.CheckpointManager.CheckpointData[$relativePath]
            $this.FileHashCache[$sourceFile.FullName] = $this.CheckpointManager.CheckpointData[$relativePath].Hash

            #phase 1: Check if checkpoint entry exists
            if (-not $checkpointEntry) {
                $this.FileHashCache[$sourceFile.FullName] = (Get-FileHash -Path $sourceFile.FullName -Algorithm "md5").Hash
                $this.Logger.Log("Needs sync because checkpoint entry does not exist: $relativePath", "INFO")
                return $true
            }
            
            # Phase 2: Check file existence

            if (-not (Test-Path $replicaPath)) {
                $this.FileHashCache[$sourceFile.FullName] = (Get-FileHash -Path $sourceFile.FullName -Algorithm "md5").Hash
                $this.Logger.Log("Needs sync because replica does not exist: $relativePath", "INFO")
                return $true 
            }

            # Phase 3: Check file size 
            $replicaFileInfo = Get-Item $replicaPath -ErrorAction SilentlyContinue
            if ($sourceFile.Length -ne $replicaFileInfo.Length) {
                $this.Logger.Log("Needs sync because file size mismatch: $relativePath", "INFO")
                return $true
            } 

            # Phase 4: Check ACL changes
            $sourceAcl = (Get-Acl $sourceFile.FullName).AccessToString
            $replicaAcl = (Get-Acl $replicaPath).AccessToString
            if ($sourceAcl -ne $replicaAcl) { 
                $this.Logger.Log("Needs sync because ACL mismatch: $relativePath", "INFO")
                return $true 
            }
            
            # Phase 5: Check timestamp 
            $sourceModified = $sourceFile.LastWriteTimeUtc
            if ([datetime]$checkpointEntry.LastModified -ne [datetime]$sourceModified) {
                $this.Logger.Log("Needs sync because timestamp mismatch: $relativePath", "INFO")
                # return $true
            }

            # Phase 6: Check content hash 
            $this.FileHashCache[$sourceFile.FullName] = (Get-FileHash -Path $sourceFile.FullName -Algorithm "md5").Hash
            if ($this.FileHashCache[$sourceFile.FullName] -ne $checkpointEntry.Hash) {
                $this.Logger.Log("Needs sync because hash mismatch: $relativePath", "INFO")
                return $true
            }

            $this.Logger.Log("No sync needed: $relativePath", "INFO")
            return $false
        }
        catch {
            [Utilities]::HandleError("NeedsSync", $sourceFile.FullName, $_, $this.Logger, $false)
            return $false
        }
    }
}