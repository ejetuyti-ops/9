param(
    [switch]$Run,
    [string]$ImageName = "ownos.img"
)

$ErrorActionPreference = "Stop"

$nasm = Get-Command nasm -ErrorAction SilentlyContinue
if (-not $nasm) {
    throw "NASM was not found. Install NASM for Windows, then run this script again."
}

$outputDirectory = Join-Path $PSScriptRoot "build"
$imagePath = Join-Path $outputDirectory $ImageName
$dataImagePath = Join-Path $outputDirectory "ownos-data.img"
$dataImageSize = 208000000
$kernelSectorCount = 768
$maxKernelSize = $kernelSectorCount * 512
$temporaryFiles = @(
    (Join-Path $env:TEMP "ownos-boot-$PID.asm"),
    (Join-Path $env:TEMP "ownos-kernel-$PID.asm"),
    (Join-Path $env:TEMP "ownos-boot-$PID.bin"),
    (Join-Path $env:TEMP "ownos-kernel-$PID.bin")
)

New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

try {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "boot.asm") -Destination $temporaryFiles[0] -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "kernel.asm") -Destination $temporaryFiles[1] -Force

    & $nasm.Source -f bin $temporaryFiles[0] -o $temporaryFiles[2]
    if ($LASTEXITCODE -ne 0) {
        throw "NASM failed to assemble the bootloader."
    }

    & $nasm.Source -f bin $temporaryFiles[1] -o $temporaryFiles[3]
    if ($LASTEXITCODE -ne 0) {
        throw "NASM failed to assemble the kernel."
    }

    $boot = [System.IO.File]::ReadAllBytes($temporaryFiles[2])
    $kernel = [System.IO.File]::ReadAllBytes($temporaryFiles[3])
    if ($boot.Length -ne 512) {
        throw "Bootloader must be exactly 512 bytes; got $($boot.Length)."
    }
    if ($boot[510] -ne 0x55 -or $boot[511] -ne 0xAA) {
        throw "Bootloader has an invalid BIOS boot signature."
    }
    if ($kernel.Length -eq 0 -or $kernel.Length -gt $maxKernelSize) {
        throw "Kernel must fit in the $kernelSectorCount sectors loaded by the bootloader (maximum $maxKernelSize bytes); got $($kernel.Length)."
    }

    $image = New-Object byte[] (512 + $maxKernelSize)
    [Array]::Copy($boot, 0, $image, 0, $boot.Length)
    [Array]::Copy($kernel, 0, $image, 512, $kernel.Length)
    [System.IO.File]::WriteAllBytes($imagePath, $image)
    if (-not (Test-Path -LiteralPath $dataImagePath)) {
        $dataDisk = [System.IO.File]::Create($dataImagePath)
        try {
            $dataDisk.SetLength($dataImageSize)
        }
        finally {
            $dataDisk.Dispose()
        }
    }
    elseif ((Get-Item -LiteralPath $dataImagePath).Length -lt $dataImageSize) {
        $dataDisk = [System.IO.File]::Open($dataImagePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $dataDisk.SetLength($dataImageSize)
        }
        finally {
            $dataDisk.Dispose()
        }
    }
}
finally {
    foreach ($file in $temporaryFiles) {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Built $imagePath"
Write-Host "Bootloader: $($boot.Length) bytes; kernel: $($kernel.Length) bytes; image: $($image.Length) bytes."
Write-Host "Persistent data disk: $dataImagePath ($([math]::Round((Get-Item -LiteralPath $dataImagePath).Length / 1000000, 0)) MB)"

if ($Run) {
    $qemuCommand = Get-Command qemu-system-i386 -ErrorAction SilentlyContinue
    $qemuPath = if ($qemuCommand) {
        $qemuCommand.Source
    } else {
        Join-Path $env:ProgramFiles "qemu\qemu-system-i386.exe"
    }

    if (-not (Test-Path -LiteralPath $qemuPath)) {
        throw "QEMU was not found. Install QEMU for Windows, then run: .\build.ps1 -Run"
    }

    & $qemuPath -m 32M -netdev user,id=net0 -device e1000,netdev=net0 -drive "format=raw,file=$imagePath" -drive "if=ide,index=1,format=raw,file=$dataImagePath" -boot order=c
    if ($LASTEXITCODE -ne 0) {
        throw "QEMU exited with an error."
    }
}
