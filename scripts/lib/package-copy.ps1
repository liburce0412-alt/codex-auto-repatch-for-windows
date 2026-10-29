function Copy-FileDataOnly {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination
  )
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
  $inputStream = [System.IO.File]::Open($Source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
  try {
    $outputStream = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
      $inputStream.CopyTo($outputStream)
    } finally {
      $outputStream.Dispose()
    }
  } finally {
    $inputStream.Dispose()
  }
  try {
    $sourceItem = Get-Item -LiteralPath $Source -Force
    [System.IO.File]::SetLastWriteTimeUtc($Destination, $sourceItem.LastWriteTimeUtc)
  } catch {
    Write-Log "warning: could not preserve timestamp for $Destination`: $($_.Exception.Message)"
  }
}

function Copy-DirectoryDataOnly {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination
  )
  if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    throw "source directory not found: $Source"
  }
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
    $target = Join-Path $Destination $item.Name
    if ($item.PSIsContainer -and (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)) {
      Copy-DirectoryDataOnly -Source $item.FullName -Destination $target
    } elseif ($item.PSIsContainer) {
      Write-Log "warning: copying reparse directory as an empty directory: $($item.FullName)"
      New-Item -ItemType Directory -Force -Path $target | Out-Null
    } else {
      Copy-FileDataOnly -Source $item.FullName -Destination $target
    }
  }
}
