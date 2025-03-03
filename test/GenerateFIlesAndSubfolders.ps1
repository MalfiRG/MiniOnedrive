<#
.SYNOPSIS
    Generate Files and Subfolders.
.DESCRIPTION
    This script generates a specified number of files in nested directories.
    Each directory level is created using the Create-DeepDirectoryTree function.
    The generated files have a specified size and are stored in directories based on their hash value.
.PARAMETER BasePath
    The base path where the nested directories will be created.
.PARAMETER MaxDepth
    The maximum depth of the nested directories.
.PARAMETER FileSizeMB
    The size of each generated file in megabytes.
.PARAMETER Amount
    The number of files to generate in each directory.
.PARAMETER RemoveLast10Files
    Specifies whether to remove the last 10 files in each directory before generating new files.
.PARAMETER Quiet
    Specifies whether to suppress the progress output.
.PARAMETER HashingAlgorithm
    The hashing algorithm to use for generating the directory names based on the file content.
.EXAMPLE
    GenerateFilesSubfolders.ps1 -BasePath "G:\" -MaxDepth 5 -FileSizeMB 1 -Amount 1000 -RemoveLast10Files $false -Quiet $false -HashingAlgorithm "SHA256"
#>

$basePath = "D:\"
$maxDepth = 2
$fileSizeMB = 64
$amount = 100
$removeLast10Files = $false
$quiet = $false
$hashingAlgorithm = "MD5"
$FolderName = "Files"

$jobs = @()

1..$maxDepth | ForEach-Object {
    $depth = $_
    $jobs += Start-Job -ScriptBlock {
        param (
            $basePath,
            $depth,
            $fileSizeMB,
            $amount,
            $removeLast10Files,
            $quiet,
            $hashingAlgorithm,
			$FolderName
        )

        function Create-DeepDirectoryTree {
            param(
                [Parameter(Mandatory)]
                [string] $BasePath,
				[string] $FolderName,

                [Parameter(Mandatory)]
                [int] $Depth
            )
            $currentPath = $BasePath
            for ($i = 1; $i -le $Depth; $i++) {
                $currentPath = Join-Path -Path $currentPath -ChildPath "$FolderName$i"
                if (-not (Test-Path -Path $currentPath)) {
                    New-Item -Path $currentPath -ItemType Directory | Out-Null
                }
            }
            return $currentPath
        }

        function Compute-FileHash {
            param (
                [string] $FilePath,
                [string] $Algorithm = "MD5"
            )

            $hashAlgorithm = [System.Security.Cryptography.HashAlgorithm]::Create($Algorithm)
            if ($null -eq $hashAlgorithm) {
                throw "Invalid hash algorithm: $Algorithm"
            }

            try {
                $fileStream = [System.IO.File]::OpenRead($FilePath)
                $hashBytes = $hashAlgorithm.ComputeHash($fileStream)
                $fileStream.Close()
                return [BitConverter]::ToString($hashBytes) -replace '-'
            } catch {
                throw "Failed to compute hash for file $($FilePath): $_"
            }
        }

        function grd {
            param(
                [Parameter(Mandatory)]
                [string] $FinalPath,

                [Parameter(Mandatory)]
                [int] $FileSizeMB,

                [Parameter(Mandatory)]
                [int] $Amount,

                [switch] $Removelast10files,
                [switch] $Quiet,

                [Parameter()]
                [ValidateSet("MD5","SHA256", "SHA1")]
                [String] $HashingAlgorithm = "MD5"
            )

            if ($Removelast10files) {
                $total1 = (Get-ChildItem -Path $FinalPath -File | Measure-Object).Count
                Get-ChildItem -Path $FinalPath | Sort-Object name | Select-Object -Last 10 | Remove-Item -Force
                $total2 = (Get-ChildItem -Path $FinalPath -File | Measure-Object).Count
                Write-Host -ForegroundColor Gray "was: $total1 files; now: $total2 files"
                Write-Host -ForegroundColor Green "last 10 files by name have been removed"
            }

            $FileSize = $FileSizeMB * 1048576
            $random = [System.Random]::new()

            1..$Amount | ForEach-Object {
                $tempFilePath = Join-Path -Path $FinalPath -ChildPath "rnd"
                $FullGigs = [Math]::Floor($FileSize / 1GB)
                for ($i = 0; $i -le $FullGigs; $i++) {
                    if ($i -eq $FullGigs) { $Array = New-Object Byte[] ($FileSize - $FullGigs * 1GB) }
                    else { $Array = New-Object Byte[] 1GB }
                    $FileStream = New-Object IO.FileStream($tempFilePath , 'Append')
                    $random.NextBytes($Array)
                    $FileStream.Write($Array, 0, $Array.Length)
                    $FileStream.Dispose()
                }
                $hash = Compute-FileHash -FilePath $tempFilePath -Algorithm $HashingAlgorithm
                $destinationPath = Join-Path -Path $FinalPath -ChildPath $hash
                Move-Item -Path $tempFilePath -Destination $destinationPath
                if (-not $Quiet) {
                    Write-Host -NoNewline -ForegroundColor Gray "generation progress: $_/$Amount files`r"
                }
            }

            Write-Host -ForegroundColor Green "Random data generation complete!"
        }

        $finalPath = Create-DeepDirectoryTree -BasePath $basePath -FolderName $FolderName -Depth $depth
        grd -FinalPath $finalPath -FileSizeMB $fileSizeMB -Amount $amount -Removelast10files:$removeLast10Files -Quiet:$quiet -HashingAlgorithm $hashingAlgorithm
    } -ArgumentList $basePath, $depth, $fileSizeMB, $amount, $removeLast10Files, $quiet, $hashingAlgorithm, $FolderName
}

try {
    $jobs | ForEach-Object { 
        $_ | Wait-Job
        Receive-Job -Job $_
        Remove-Job -Job $_
    }
} catch {
    Write-Verbose "Failed to wait for job: $($_.Exception)"
}

Write-Host "All jobs completed."