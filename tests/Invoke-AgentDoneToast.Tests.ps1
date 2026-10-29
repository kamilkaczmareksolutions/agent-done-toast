BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures'
    Import-Module (Join-Path $script:Repo 'AgentDoneToast.psm1') -Force

    function script:Read-Fixture {
        param([string]$Name)
        return Get-Content -LiteralPath (Join-Path $script:Fixtures $Name) -Raw
    }

    function script:Invoke-Noted {
        param(
            [string]$BindingId,
            [string]$StdinText = '',
            [string]$ArgumentText = ''
        )
        $notes = New-Object System.Collections.Generic.List[ToastNote]
        $result = Invoke-AgentDoneToast -BindingId $BindingId -StdinText $StdinText -ArgumentText $ArgumentText -Notifier {
            param([ToastNote]$Note)
            $notes.Add($Note)
        }
        return [pscustomobject]@{ Result = $result; Notes = $notes }
    }
}

Describe 'Invoke-AgentDoneToast' {
    It 'exports only Sync-AgentDoneToast and Invoke-AgentDoneToast' {
        $names = @(Get-Command -Module AgentDoneToast | Select-Object -ExpandProperty Name | Sort-Object)
        $names | Should -BeExactly @('Invoke-AgentDoneToast', 'Sync-AgentDoneToast')
    }

    It 'toasts when Cursor stop status is completed' {
        $previous = $env:CURSOR_PROJECT_DIR
        try {
            $env:CURSOR_PROJECT_DIR = 'C:\src\widget'
            $payload = Read-Fixture 'cursor-stop-completed.json'
            $seen = Invoke-Noted -BindingId 'cursor-stop' -StdinText $payload
            @($seen.Result).Count | Should -Be 1
            $seen.Result -is [ShowToast] | Should -BeTrue
            $seen.Result.Request.Agent | Should -Be ([AgentKind]::Cursor)
            $seen.Result.Request.Reason | Should -Be ([ToastReason]::Done)
            $seen.Result.Request.ProjectDirectory | Should -BeExactly 'C:\src\widget'
            $seen.Notes.Count | Should -Be 1
            $seen.Notes[0].Title | Should -BeExactly 'Cursor finished'
            $seen.Notes[0].Body | Should -BeExactly 'C:\src\widget'
            $seen.Notes[0].AppId | Should -BeExactly 'AgentDoneToast'
            @($seen.Result.PSObject.Properties.Name) | Should -BeExactly @('Request')
        }
        finally {
            $env:CURSOR_PROJECT_DIR = $previous
        }
    }

    It 'stays quiet for aborted and error Cursor stops' {
        $previous = $env:CURSOR_PROJECT_DIR
        try {
            $env:CURSOR_PROJECT_DIR = 'C:\src\widget'
            foreach ($name in @('cursor-stop-aborted.json', 'cursor-stop-error.json')) {
                $seen = Invoke-Noted -BindingId 'cursor-stop' -StdinText (Read-Fixture $name)
                $seen.Result -is [StayQuiet] | Should -BeTrue
                $seen.Result.Reason | Should -Be ([QuietReason]::NotCompleted)
                $seen.Notes.Count | Should -Be 0
            }
        }
        finally {
            $env:CURSOR_PROJECT_DIR = $previous
        }
    }

    It 'stays quiet when Cursor status is missing or not the string completed' {
        $previous = $env:CURSOR_PROJECT_DIR
        try {
            $env:CURSOR_PROJECT_DIR = 'C:\src\widget'
            foreach ($payload in @(
                '{"hook_event_name":"stop","cwd":"C:\\src\\widget"}',
                '{"hook_event_name":"stop","status":"Completed","cwd":"C:\\src\\widget"}'
            )) {
                $seen = Invoke-Noted -BindingId 'cursor-stop' -StdinText $payload
                $seen.Result -is [StayQuiet] | Should -BeTrue
                $seen.Result.Reason | Should -Be ([QuietReason]::NotCompleted)
                $seen.Notes.Count | Should -Be 0
            }
        }
        finally {
            $env:CURSOR_PROJECT_DIR = $previous
        }
    }

    It 'uses CURSOR_PROJECT_DIR and ignores payload cwd' {
        $previous = $env:CURSOR_PROJECT_DIR
        try {
            Remove-Item Env:CURSOR_PROJECT_DIR -ErrorAction SilentlyContinue
            $seen = Invoke-Noted -BindingId 'cursor-stop' -StdinText (Read-Fixture 'cursor-stop-completed.json')
            $seen.Result -is [ShowToast] | Should -BeTrue
            $seen.Notes[0].Body | Should -BeExactly 'No project path'
        }
        finally {
            if ($null -eq $previous) { Remove-Item Env:CURSOR_PROJECT_DIR -ErrorAction SilentlyContinue }
            else { $env:CURSOR_PROJECT_DIR = $previous }
        }
    }

    It 'toasts when Claude Stop is not already inside a hook' {
        $seen = Invoke-Noted -BindingId 'claude-stop' -StdinText (Read-Fixture 'claude-stop.json')
        $seen.Result -is [ShowToast] | Should -BeTrue
        $seen.Result.Request.Agent | Should -Be ([AgentKind]::Claude)
        $seen.Result.Request.Reason | Should -Be ([ToastReason]::Done)
        $seen.Notes[0].Title | Should -BeExactly 'Claude Code finished'
        $seen.Notes[0].Body | Should -BeExactly 'C:\src\widget'
    }

    It 'stays quiet when Claude stop_hook_active is true' {
        $seen = Invoke-Noted -BindingId 'claude-stop' -StdinText (Read-Fixture 'claude-stop-active.json')
        $seen.Result -is [StayQuiet] | Should -BeTrue
        $seen.Result.Reason | Should -Be ([QuietReason]::StopHookActive)
        $seen.Notes.Count | Should -Be 0
    }

    It 'toasts Claude permission and notification needs-input rows' {
        $permission = Invoke-Noted -BindingId 'claude-permission-request' -StdinText (Read-Fixture 'claude-permission.json')
        $permission.Notes[0].Title | Should -BeExactly 'Claude Code needs you'
        $needs = Invoke-Noted -BindingId 'claude-agent-needs-input' -StdinText (Read-Fixture 'claude-notification-needs-input.json')
        $needs.Result -is [ShowToast] | Should -BeTrue
        $needs.Result.Request.Reason | Should -Be ([ToastReason]::NeedsInput)
        $needs.Notes[0].Title | Should -BeExactly 'Claude Code needs you'
        $needs.Notes[0].Body | Should -BeExactly 'C:\src\widget'
    }

    It 'stays quiet when notification_type differs and still toasts when it is absent' {
        $wrong = Invoke-Noted -BindingId 'claude-agent-needs-input' -StdinText '{"hook_event_name":"Notification","notification_type":"elicitation_dialog","cwd":"C:\\src\\widget"}'
        $wrong.Result.Reason | Should -Be ([QuietReason]::EventMismatch)
        $wrong.Notes.Count | Should -Be 0

        $absent = Invoke-Noted -BindingId 'claude-agent-needs-input' -StdinText '{"hook_event_name":"Notification","cwd":"C:\\src\\widget"}'
        $absent.Result -is [ShowToast] | Should -BeTrue
        $absent.Notes[0].Title | Should -BeExactly 'Claude Code needs you'

        $dialog = Invoke-Noted -BindingId 'claude-elicitation-dialog' -StdinText '{"hook_event_name":"Notification","notification_type":"elicitation_dialog","cwd":"C:\\src\\widget"}'
        $dialog.Notes[0].Title | Should -BeExactly 'Claude Code needs you'
        $url = Invoke-Noted -BindingId 'claude-elicitation-url-dialog' -StdinText '{"hook_event_name":"notification","notification_type":"elicitation_url_dialog","cwd":"C:\\src\\widget"}'
        $url.Result -is [ShowToast] | Should -BeTrue
    }

    It 'does not read a payload property named matcher' {
        $seen = Invoke-Noted -BindingId 'claude-stop' -StdinText '{"hook_event_name":"Stop","stop_hook_active":false,"cwd":"C:\\src\\widget","matcher":"nope"}'
        $seen.Result -is [ShowToast] | Should -BeTrue
        $needs = Invoke-Noted -BindingId 'claude-agent-needs-input' -StdinText '{"hook_event_name":"Notification","notification_type":"agent_needs_input","matcher":"wrong","cwd":"C:\\src\\widget"}'
        $needs.Result -is [ShowToast] | Should -BeTrue
    }

    It 'matches hook event names without case and uses No project path for a blank directory' {
        $seen = Invoke-Noted -BindingId 'claude-stop' -StdinText '{"hook_event_name":"STOP","stop_hook_active":false,"cwd":"   "}'
        $seen.Result -is [ShowToast] | Should -BeTrue
        $seen.Notes[0].Body | Should -BeExactly 'No project path'
        $missing = Invoke-Noted -BindingId 'claude-permission-request' -StdinText '{"hook_event_name":"PermissionRequest"}'
        $missing.Notes[0].Body | Should -BeExactly 'No project path'
    }

    It 'reads Codex notify from the argument and ignores stdin' {
        $turn = Invoke-Noted -BindingId 'codex-turn-complete' -StdinText '{"type":"other"}' -ArgumentText (Read-Fixture 'codex-turn-complete.json')
        $turn.Result -is [ShowToast] | Should -BeTrue
        $turn.Result.Request.Agent | Should -Be ([AgentKind]::Codex)
        $turn.Result.Request.Reason | Should -Be ([ToastReason]::Done)
        $turn.Notes[0].Title | Should -BeExactly 'Codex finished'
        $turn.Notes[0].Body | Should -BeExactly 'C:\src\widget'

        $cased = Invoke-Noted -BindingId 'codex-turn-complete' -ArgumentText '{"type":"Agent-Turn-Complete","cwd":"C:\\src\\widget"}'
        $cased.Result -is [ShowToast] | Should -BeTrue

        $ignored = Invoke-Noted -BindingId 'codex-turn-complete' -StdinText (Read-Fixture 'codex-turn-complete.json') -ArgumentText ''
        $ignored.Result.Reason | Should -Be ([QuietReason]::MalformedPayload)
        $ignored.Notes.Count | Should -Be 0

        $permission = Invoke-Noted -BindingId 'codex-permission-request' -StdinText (Read-Fixture 'codex-permission.json') -ArgumentText '{"type":"agent-turn-complete","cwd":"C:\\other"}'
        $permission.Notes[0].Title | Should -BeExactly 'Codex needs you'
        $permission.Notes[0].Body | Should -BeExactly 'C:\src\widget'
    }

    It 'stays quiet for a mismatched event, malformed payload, and unknown binding' {
        $mismatch = Invoke-Noted -BindingId 'claude-stop' -StdinText '{"hook_event_name":"PermissionRequest","cwd":"C:\\src\\widget"}'
        $mismatch.Result.Reason | Should -Be ([QuietReason]::EventMismatch)
        $mismatch.Notes.Count | Should -Be 0

        foreach ($text in @('not json {', '   ', '')) {
            $bad = Invoke-Noted -BindingId 'claude-stop' -StdinText $text
            $bad.Result.Reason | Should -Be ([QuietReason]::MalformedPayload)
            $bad.Notes.Count | Should -Be 0
        }

        $unknown = Invoke-Noted -BindingId 'not-a-row' -StdinText (Read-Fixture 'claude-stop.json')
        $unknown.Result.Reason | Should -Be ([QuietReason]::UnknownBinding)
        $unknown.Notes.Count | Should -Be 0
    }

    It 'returns WinRtFailed when the Windows toast API cannot show a toast' {
        $canToast = $false
        try {
            $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
            $canToast = $true
        }
        catch {
            $canToast = $false
        }
        $result = Invoke-AgentDoneToast -BindingId 'claude-stop' -StdinText (Read-Fixture 'claude-stop.json')
        if ($canToast) {
            $ok = ($result -is [ShowToast]) -or (($result -is [StayQuiet]) -and $result.Reason -eq ([QuietReason]::WinRtFailed))
            $ok | Should -BeTrue
        }
        else {
            $result -is [StayQuiet] | Should -BeTrue
            $result.Reason | Should -Be ([QuietReason]::WinRtFailed)
        }
    }

    It 'invoke.ps1 exits 0 with empty stdout and stderr' {
        $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $script = Join-Path $script:Repo 'invoke.ps1'
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = "-NoProfile -NonInteractive -File `"$script`" -BindingId claude-stop"
        $psi.WorkingDirectory = $script:Repo
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $process = [System.Diagnostics.Process]::Start($psi)
        $process.StandardInput.Write((Read-Fixture 'claude-stop.json'))
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $finished = $process.WaitForExit(20000)
        $finished | Should -BeTrue
        $process.ExitCode | Should -Be 0
        $stdoutTask.Result | Should -BeExactly ''
        $stderrTask.Result | Should -BeExactly ''
    }
}
