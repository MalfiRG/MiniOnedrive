<#
.SYNOPSIS
    Module containing the HashingService class for file hash computations.
.DESCRIPTION
    This module defines the HashingService class, which is responsible for computing
    file hashes using various algorithms.
#>

class HashingService {
    [string] $Algorithm
    
    HashingService([string] $algorithm = "MD5") {
        $this.Algorithm = $algorithm
    }
    
    [string] ComputeFileHash([string] $FilePath) {
        $hashAlgorithm = [System.Security.Cryptography.HashAlgorithm]::Create($this.Algorithm)
        if ($null -eq $hashAlgorithm) {
            throw "Invalid hash algorithm: $($this.Algorithm)"
        }

        try {
            $fileStream = [System.IO.File]::OpenRead($FilePath)
            $hashBytes = $hashAlgorithm.ComputeHash($fileStream)
            $fileStream.Close()
            return [BitConverter]::ToString($hashBytes) -replace '-'
        }
        catch {
            throw "Failed to compute hash for file $($FilePath): $_"
        }
    }
}
