<#
.SYNOPSIS
    Module containing the FileGenerationService class for generating random files.
.DESCRIPTION
    This module defines the FileGenerationService class, which is responsible for generating
    random files and managing file operations.
#>

using module .\HashingService.psm1

class FileGenerationService {
    [HashingService] $HashingService
    [bool] $Quiet
    
    FileGenerationService([HashingService] $hashingService, [bool] $quiet = $false) {
        $this.HashingService = $hashingService
        $this.Quiet = $quiet
    }
    
    [void] CleanupLastFiles([string] $Path) {
        $total1 = (Get-ChildItem -Path $Path -File | Measure-Object).Count
        Get-ChildItem -Path $Path | Sort-Object name | Select-Object -Last 10 | Remove-Item -Force
        $total2 = (Get-ChildItem -Path $Path -File | Measure-Object).Count
        Write-Host -ForegroundColor Gray "was: $total1 files; now: $total2 files"
        Write-Host -ForegroundColor Green "last 10 files by name have been removed"
    }
    
    [void] GenerateRandomFile([string] $Path, [long] $Size) {
        $random = [System.Random]::new()
        $FullGigs = [Math]::Floor($Size / 1GB)
        
        for ($i = 0; $i -le $FullGigs; $i++) {
            if ($i -eq $FullGigs) { 
                $Array = New-Object Byte[] ($Size - $FullGigs * 1GB) 
            }
            else { 
                $Array = New-Object Byte[] 1GB 
            }
            
            $FileStream = New-Object IO.FileStream($Path, 'Append')
            $random.NextBytes($Array)
            $FileStream.Write($Array, 0, $Array.Length)
            $FileStream.Dispose()
        }
    }
    
    [void] GenerateRandomFiles([string] $FinalPath, [int] $FileSizeMB, [int] $Amount, [bool] $RemoveLast10Files) {
        if ($RemoveLast10Files) {
            $this.CleanupLastFiles($FinalPath)
        }

        $FileSize = $FileSizeMB * 1048576

        foreach ($i in 1..$Amount) {
            $tempFilePath = Join-Path -Path $FinalPath -ChildPath "rnd"
            $this.GenerateRandomFile($tempFilePath, $FileSize)
            $hash = $this.HashingService.ComputeFileHash($tempFilePath)
            $destinationPath = Join-Path -Path $FinalPath -ChildPath $hash
            Move-Item -Path $tempFilePath -Destination $destinationPath
            
            if (-not $this.Quiet) {
                Write-Host -NoNewline -ForegroundColor Gray "generation progress: $i/$Amount files`r"
            }
        }

        Write-Host -ForegroundColor Green "Random data generation complete!"
    }
}
