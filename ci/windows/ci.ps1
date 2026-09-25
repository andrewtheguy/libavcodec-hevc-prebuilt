# The Windows row of .github/workflows/build.yml, run natively on the CI box by
# ci/windows/remote.ps1 (`remote.ps1 ci`): build.sh in an MSYS2 shell (make, nasm) inside a Visual
# Studio developer environment, then the Windows bindings regenerated against this machine's
# SDK, then link, test and run the consumer binary. When this file and the workflow disagree, the
# workflow is right and this is stale — it exists to say what CI will say before CI is asked.
#
# PowerShell 7. Installs nothing; the machine is provisioned by remotex's ci/windows/provision.ps1.
$ErrorActionPreference = 'Stop'
Set-Location (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$repo = (Get-Location).Path

# The developer environment: cl, link, msbuild, nmake, LIB and INCLUDE for the SDK.
Import-Module 'C:\BuildTools\Common7\Tools\Microsoft.VisualStudio.DevShell.dll'
Enter-VsDevShell -VsInstallPath 'C:\BuildTools' -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null
Set-Location $repo
$env:LIBCLANG_PATH = 'C:\Program Files\LLVM\bin'
# The MSYS2 shell inherits that environment: `inherit` keeps the Windows PATH in a login shell.
$env:MSYSTEM = 'MSYS'
$env:MSYS2_PATH_TYPE = 'inherit'
$env:CHERE_INVOKE = '1'

function Invoke-Step([string] $Name, [scriptblock] $Body) {
    Write-Host ''
    Write-Host "== $Name =="
    & $Body
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        Write-Host "FAILED: $Name (exit $LASTEXITCODE)"
        exit $LASTEXITCODE
    }
}
function Invoke-Bash([string] $Script) {
    # A native path handed to cygpath inside the shell, so no path is spelled twice.
    & 'C:\msys64\usr\bin\bash.exe' -lc ('cd "$(cygpath -u ''' + $repo + ''')" && ' + $Script)
}

Write-Host '== toolchain =='
& cl 2>&1 | Select-Object -First 1
& rustc --version
& cargo --version
if ($env:CARGO_TARGET_DIR) { Write-Host "   CARGO_TARGET_DIR=$env:CARGO_TARGET_DIR" }
Invoke-Bash 'nasm -v; make --version | head -1; llvm-nm --version | sed -n 2p'

Invoke-Step 'build.sh windows-x86_64-msvc' { Invoke-Bash './build.sh windows-x86_64-msvc' }
# Before the cargo build rather than after it: the crate compiles `bindings_windows.rs` on this
# target, so the file has to exist — and regenerated rather than `--check`ed, because the box is
# where the Windows file is *made*; the diff against the committed one is read back on the
# driving machine (`remote.ps1 fetch crates\libavcodec-hevc-prebuilt-sys\src <dest>`).
Invoke-Step 'bindings_windows.rs from this SDK' {
    # cargo install from PowerShell, not from the MSYS shell: there `/usr/bin/link` (coreutils)
    # shadows MSVC's link.exe and every build script fails to link.
    & cargo install bindgen-cli --version 0.72.1 --locked
    if ($LASTEXITCODE -ne 0) { return }
    Invoke-Bash 'cd crates/libavcodec-hevc-prebuilt-sys && ./gen-bindings.sh'
}
Invoke-Step 'sync-prebuilt.sh' { Invoke-Bash './sync-prebuilt.sh' }
Invoke-Step 'cargo build' { & cargo build --release --workspace }
Invoke-Step 'clippy' { & cargo clippy --release --all-targets -- -D warnings }
$target = if ($env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR } else { Join-Path $repo 'target' }
Invoke-Step 'end to end' {
    & "$target\release\libavcodec-hevc-e2e.exe"
    if ($LASTEXITCODE -eq 0) { Invoke-Bash ('./check-static.sh "$(cygpath -u ''' + "$target\release\libavcodec-hevc-e2e.exe" + ''')"') }
}
Invoke-Step 'committed headers' { Invoke-Bash './sync-prebuilt.sh --check' }

Write-Host ''
Write-Host 'all steps passed'
