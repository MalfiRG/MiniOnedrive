function vrd {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter()]
        [ValidateSet("MD5", "SHA256", "SHA1")]
        [string] $HashingAlgorithm = "MD5"
    )

    $foldersToCheck = @(Get-ChildItem -Path $Path -Recurse -Directory | Where-Object { $_.Name -match '.*Files.*' })

    $passed = $true

    foreach ($folder in $foldersToCheck) {
        Write-Host "Checking folder: $($folder.FullName)" -ForegroundColor Cyan
        # Iterate over files in each folder
        foreach ($file in Get-ChildItem -Path $folder.FullName -File) {
            $hash = ($file | Get-FileHash -Algorithm $HashingAlgorithm).Hash
            if ($hash -eq $file.Name) {
                Write-Host -ForegroundColor Gray "File $($file.Name) - Hash matched"
            } else {
                Write-Host -ForegroundColor Red "File $($file.Name) - Hash mismatch! Calculated hash: $hash"
                $passed = $false
            }
        }
    }

    if ($passed) {
        Write-Host -ForegroundColor Green "All tests passed. Your data is consistent"
    } else {
        Write-Host -ForegroundColor Red "Data is inconsistent. Time to file a bug?"
    }
}

vrd
```