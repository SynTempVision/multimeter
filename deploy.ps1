# deploy.ps1 - deploys app.py/ohms_test.py/templates to MultimeterNode over SSH,
# handling the overlayroot (RAM-OS) toggle automatically. This Pi runs
# overlayroot=tmpfs in normal operation (writes go to RAM, discarded on
# reboot) - deploying anything that needs to survive a reboot requires
# disabling it first and re-enabling it after. Mirrors uPaceInterface's own
# deploy.ps1 for the same class of device (see project_upace memory).
#
# Usage: .\deploy.ps1 -PiHost 172.17.17.115
#        .\deploy.ps1 -PiHost 172.17.17.115 -SkipReenable   (leave overlay off for more edits)

param(
    [string]$PiHost = "172.17.17.115",
    [string]$PiUser = "multimeter",
    [switch]$SkipReenable
)

$ErrorActionPreference = "Stop"
$Target = "${PiUser}@${PiHost}"
$RemoteDir = "~/pi_multimeter"
$LocalDir = $PSScriptRoot

# This Pi's SSH host key apparently doesn't survive a reboot under RAM-OS
# (regenerated fresh each boot, not persisted) - every reboot in this
# script would otherwise hit "REMOTE HOST IDENTIFICATION HAS CHANGED" and
# block. Clear any stale entry before starting; this is a single known
# physical device on a controlled network, not a real trust boundary here.
try { ssh-keygen -R $PiHost 2>&1 | Out-Null } catch {}

$SshOpts = @("-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new")

function Invoke-RemoteCmd($cmd) {
    # Plain (no -t) for read-only commands - clean output, no pty noise.
    $result = ssh @SshOpts $Target $cmd
    if ($LASTEXITCODE -ne 0) { throw "Remote command failed: $cmd" }
    return $result
}

function Invoke-RemoteSudo($cmd) {
    # sudo needs a real terminal to prompt for its password - without -t
    # this fails with "sudo: a terminal is required" (hit this exact
    # error earlier in the session trying to automate it headlessly).
    # -t means this pauses here for you to type the sudo password.
    ssh -t @SshOpts $Target $cmd
    if ($LASTEXITCODE -ne 0) { throw "Remote sudo command failed: $cmd" }
}

function Invoke-RemoteReboot {
    # The connection dropping is the expected success case here, not a
    # failure - but PowerShell's strict mode throws on ANY stderr from a
    # native command regardless of exit code, so this needs try/catch,
    # not just skipping the $LASTEXITCODE check (that alone didn't work -
    # confirmed live, it still threw).
    try { ssh -t @SshOpts $Target "sudo reboot" 2>&1 | Out-Null } catch {}
}

function Wait-ForPi {
    Write-Host "Waiting for $PiHost to come back up..."
    $maxTries = 40
    for ($i = 0; $i -lt $maxTries; $i++) {
        Start-Sleep -Seconds 5
        $ok = Test-Connection -ComputerName $PiHost -Count 1 -Quiet -ErrorAction SilentlyContinue
        if ($ok) {
            # The reboot that got us here likely regenerated this Pi's SSH
            # host key (see note above) - clear it again now that it's
            # actually back, before the next SSH call in the script hits it.
            try { ssh-keygen -R $PiHost 2>&1 | Out-Null } catch {}
            # Ping success doesn't mean SSH is ready yet - check port 22 is
            # accepting connections. Was an `ssh -o BatchMode=yes` probe, but
            # that (a) never succeeds on a unit without our key installed
            # (password auth only) and (b) threw on its stderr under
            # $ErrorActionPreference=Stop, killing the script mid-wait
            # (2026-10-23). A raw TCP check avoids both.
            $client = New-Object Net.Sockets.TcpClient
            try {
                if ($client.ConnectAsync($PiHost, 22).Wait(3000)) {
                    # sshd can accept TCP slightly before it's ready for a banner
                    Start-Sleep -Seconds 3
                    Write-Host "Pi is back up."
                    return
                }
            } catch {} finally { $client.Close() }
        }
    }
    throw "Pi did not come back up within $($maxTries * 5) seconds."
}

Write-Host "=== [1/6] Checking current overlay state ==="
$cmdline = Invoke-RemoteCmd "cat /proc/cmdline"
$overlayActive = $cmdline -match "overlayroot=tmpfs"
Write-Host "Overlay active: $overlayActive"

if ($overlayActive) {
    Write-Host "=== [2/6] Disabling overlay and rebooting ==="
    Invoke-RemoteSudo "sudo sed -i 's/overlayroot=tmpfs:recurse=0 //' /boot/firmware/cmdline.txt"
    Invoke-RemoteReboot
    Wait-ForPi
} else {
    Write-Host "=== [2/6] Overlay already off, skipping reboot ==="
}

Write-Host "=== [3/6] Deploying files ==="
scp "$LocalDir\app.py" "${Target}:${RemoteDir}/app.py"
scp "$LocalDir\ohms_test.py" "${Target}:${RemoteDir}/ohms_test.py"
scp "$LocalDir\templates\index.html" "${Target}:${RemoteDir}/templates/index.html"
scp "$LocalDir\templates\ohms_test.html" "${Target}:${RemoteDir}/templates/ohms_test.html"

Write-Host "=== [4/6] Restarting mm-control.service ==="
Invoke-RemoteSudo "sudo systemctl restart mm-control.service"
Start-Sleep -Seconds 2
$status = Invoke-RemoteCmd "systemctl is-active mm-control.service"
if ($status -ne "active") { throw "Service did not come up active (status: $status)" }
Write-Host "Service active."

Write-Host "=== [5/6] Verifying pages respond ==="
$code1 = (Invoke-WebRequest -Uri "http://${PiHost}:5000/" -UseBasicParsing -TimeoutSec 10).StatusCode
$code2 = (Invoke-WebRequest -Uri "http://${PiHost}:5000/ohms-test" -UseBasicParsing -TimeoutSec 10).StatusCode
Write-Host "Main page: $code1, Ohms test page: $code2"
if ($code1 -ne 200 -or $code2 -ne 200) { throw "A page did not return 200" }

if ($SkipReenable) {
    Write-Host "=== [6/6] -SkipReenable set - leaving overlay OFF for further edits ==="
} else {
    Write-Host "=== [6/6] Re-enabling overlay and rebooting ==="
    Invoke-RemoteSudo "sudo sed -i 's/root=PARTUUID=dabafb25-02/overlayroot=tmpfs:recurse=0 root=PARTUUID=dabafb25-02/' /boot/firmware/cmdline.txt"
    Invoke-RemoteReboot
    Wait-ForPi
    $finalCmdline = Invoke-RemoteCmd "cat /proc/cmdline"
    if ($finalCmdline -notmatch "overlayroot=tmpfs") { throw "Overlay did not re-enable - check manually" }
    Write-Host "Overlay confirmed back on."
}

Write-Host "=== Deploy complete ==="
