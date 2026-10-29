BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:Repo 'AgentDoneToast.psm1') -Force
    if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $script:InjectedSystemRoot = $true
        $env:SystemRoot = 'C:\Windows'
    }

    function script:New-Sandbox {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('agent-done-toast-' + [guid]::NewGuid().ToString('n'))
        $profile = Join-Path $root 'profile'
        $install = Join-Path $root 'install'
        $menu = Join-Path $root 'start'
        $null = New-Item -ItemType Directory -Path $profile -Force
        $null = New-Item -ItemType Directory -Path $install -Force
        $null = New-Item -ItemType Directory -Path $menu -Force
        return [pscustomobject]@{
            Root = $root
            Profile = $profile
            Install = $install
            Menu = $menu
        }
    }

    function script:Invoke-Sync {
        param($Sandbox, [SyncMode]$Mode)
        return Sync-AgentDoneToast -Mode $Mode -UserProfile $Sandbox.Profile -CodexHome (Join-Path $Sandbox.Profile '.codex') -InstallRoot $Sandbox.Install -StartMenuPrograms $Sandbox.Menu
    }

    function script:Remove-Sandbox {
        param($Sandbox)
        if ($Sandbox -and (Test-Path -LiteralPath $Sandbox.Root)) {
            Remove-Item -LiteralPath $Sandbox.Root -Recurse -Force
        }
    }

    function script:Get-Outcome {
        param($Report, [string]$Path)
        foreach ($change in $Report.Files) {
            if ($change.Path -eq $Path) { return $change }
        }
        throw "missing change for $Path"
    }

    function script:Test-SameByteArray {
        param([byte[]]$Left, [byte[]]$Right)
        if ($Left.Length -ne $Right.Length) { return $false }
        for ($i = 0; $i -lt $Left.Length; $i++) {
            if ($Left[$i] -ne $Right[$i]) { return $false }
        }
        return $true
    }

    function script:Invoke-ScriptFile {
        param([string]$ScriptName, $Sandbox)
        $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $script = Join-Path $script:Repo $ScriptName
        $local = Join-Path $Sandbox.Profile 'AppData\Local'
        $roaming = Join-Path $Sandbox.Profile 'AppData\Roaming'
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = "-NoProfile -NonInteractive -File `"$script`""
        $psi.WorkingDirectory = $script:Repo
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.EnvironmentVariables['USERPROFILE'] = $Sandbox.Profile
        $psi.EnvironmentVariables['HOME'] = $Sandbox.Profile
        $psi.EnvironmentVariables['LOCALAPPDATA'] = $local
        $psi.EnvironmentVariables['APPDATA'] = $roaming
        $psi.EnvironmentVariables['SystemRoot'] = 'C:\Windows'
        if ($psi.EnvironmentVariables.ContainsKey('CODEX_HOME')) {
            $psi.EnvironmentVariables.Remove('CODEX_HOME')
        }
        if ($psi.EnvironmentVariables.ContainsKey('CURSOR_PROJECT_DIR')) {
            $psi.EnvironmentVariables.Remove('CURSOR_PROJECT_DIR')
        }
        $process = [System.Diagnostics.Process]::Start($psi)
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $finished = $process.WaitForExit(30000)
        if (-not $finished) { $process.Kill() }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdoutTask.Result
            StdErr = $stderrTask.Result
            Finished = [bool]$finished
        }
    }
}

AfterAll {
    if ($script:InjectedSystemRoot) {
        Remove-Item Env:SystemRoot -ErrorAction SilentlyContinue
    }
}

Describe 'Sync-AgentDoneToast' {
    It 'applies once, leaves the second apply unchanged, and removes only owned commands' {
        $sandbox = New-Sandbox
        try {
            $settings = Join-Path $sandbox.Profile '.claude\settings.json'
            $cursor = Join-Path $sandbox.Profile '.cursor\hooks.json'
            $toml = Join-Path $sandbox.Profile '.codex\config.toml'
            $codexHooks = Join-Path $sandbox.Profile '.codex\hooks.json'
            $foreign = '{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"C:\\bin\\other.exe"}]}]}}'
            $parent = Split-Path -Parent $settings
            $null = New-Item -ItemType Directory -Path $parent -Force
            [System.IO.File]::WriteAllText($settings, $foreign)

            $first = Invoke-Sync $sandbox ([SyncMode]::Apply)
            $first -is [InstallReport] | Should -BeTrue
            @($first).Count | Should -Be 1
            (Get-Outcome $first $settings).Outcome | Should -Be ([FileOutcome]::Updated)
            (Get-Outcome $first $settings).BackupPath | Should -BeExactly ($settings + '.agent-done-toast.bak')
            (Get-Outcome $first (Join-Path $sandbox.Install 'invoke.ps1')).Outcome | Should -Be ([FileOutcome]::Created)
            (Get-Outcome $first $toml).Outcome | Should -Be ([FileOutcome]::Created)
            (Get-Outcome $first $toml).BackupPath | Should -BeExactly ''
            $shortcutPath = Join-Path $sandbox.Menu 'AgentDoneToast.lnk'
            $shortcutChange = $null
            foreach ($change in $first.Files) {
                if ($change.Path -eq $shortcutPath) { $shortcutChange = $change }
            }
            if ($null -eq $shortcutChange) {
                Test-Path -LiteralPath $shortcutPath | Should -BeFalse
            }
            else {
                $shortcutChange.Outcome | Should -Be ([FileOutcome]::Created)
                Test-Path -LiteralPath $shortcutPath | Should -BeTrue
            }

            $raw = [System.IO.File]::ReadAllText($settings)
            $raw | Should -Not -Match 'agent_done_toast_keep_array'
            $raw | Should -Match '"Stop"\s*:\s*\['
            $raw | Should -Match '"PermissionRequest"\s*:\s*\['
            $raw | Should -Match '"Notification"\s*:\s*\['
            $raw | Should -Match 'elicitation_dialog'
            $raw | Should -Match 'elicitation_url_dialog'
            $raw | Should -Match 'agent_needs_input'
            $doc = $raw | ConvertFrom-Json
            $doc.theme | Should -BeExactly 'dark'
            @($doc.hooks.Stop).Count | Should -Be 2
            @($doc.hooks.Notification).Count | Should -Be 3
            $commands = New-Object System.Collections.Generic.List[string]
            foreach ($group in @($doc.hooks.Stop)) {
                foreach ($hook in @($group.hooks)) { $commands.Add([string]$hook.command) }
            }
            $commands | Should -Contain 'C:\bin\other.exe'
            $owned = @($commands | Where-Object { $_ -like '*invoke.ps1*' })
            $owned.Count | Should -Be 1
            $hook = @($doc.hooks.Stop | Where-Object { $_.hooks.command -like '*claude-stop*' }).hooks
            if ($hook -is [System.Array]) { $hook = $hook[0] }
            $hook.type | Should -BeExactly 'command'
            $hook.async | Should -BeTrue
            $hook.shell | Should -BeExactly 'powershell'
            $hook.timeout | Should -Be 15
            @($hook.PSObject.Properties.Name) | Should -Not -Contain 'if'
            $command = [string]$hook.command
            $command | Should -Match '-File'
            $command | Should -Not -Match '-Command'
            $fileAt = $command.IndexOf('-File')
            $bindAt = $command.IndexOf('-BindingId')
            $fileAt | Should -BeGreaterThan 0
            $bindAt | Should -BeGreaterThan $fileAt
            $command.IndexOf((Join-Path $sandbox.Install 'invoke.ps1')) | Should -BeGreaterThan $fileAt
            $command | Should -Match 'claude-stop'
            $command | Should -Match 'powershell.exe'
            $command | Should -Match '-NoProfile'
            $command | Should -Match '-NonInteractive'
            $command | Should -Match '-WindowStyle'
            $command | Should -Match 'Hidden'

            $cursorRaw = [System.IO.File]::ReadAllText($cursor)
            $cursorRaw | Should -Match '"version"\s*:\s*1'
            $cursorRaw | Should -Match '"stop"\s*:\s*\['
            $cursorRaw | Should -Match '"matcher"\s*:\s*"Stop"'
            $cursorDoc = $cursorRaw | ConvertFrom-Json
            $cursorHook = $cursorDoc.hooks.stop
            if ($cursorHook -is [System.Array]) { $cursorHook = $cursorHook[0] }
            @($cursorHook.PSObject.Properties.Name) | Should -Not -Contain 'async'
            $cursorHook.command | Should -Match 'cursor-stop'

            $codexDoc = [System.IO.File]::ReadAllText($codexHooks) | ConvertFrom-Json
            $codexHook = $codexDoc.hooks.PermissionRequest[0].hooks[0]
            $codexHook.command | Should -BeExactly $codexHook.commandWindows
            $codexHook.command | Should -Match 'codex-permission-request'
            @($codexHook.PSObject.Properties.Name) | Should -Not -Contain 'shell'

            $tomlText = [System.IO.File]::ReadAllText($toml)
            $tomlText | Should -Match 'notify = \['
            $tomlText | Should -Match '"-File"'
            $tomlText | Should -Match '"-BindingId"'
            $tomlText | Should -Match '"codex-turn-complete"'

            $before = @{}
            foreach ($change in $first.Files) {
                if (Test-Path -LiteralPath $change.Path) {
                    $before[$change.Path] = [System.IO.File]::ReadAllBytes($change.Path)
                }
            }
            $backup = [System.IO.File]::ReadAllBytes((Get-Outcome $first $settings).BackupPath)
            [System.Text.Encoding]::UTF8.GetString($backup) | Should -BeExactly $foreign
            $stamp = Get-Date '2001-01-01Z'
            (Get-Item -LiteralPath ($settings + '.agent-done-toast.bak')).LastWriteTimeUtc = $stamp

            $second = Invoke-Sync $sandbox ([SyncMode]::Apply)
            foreach ($change in $second.Files) {
                $change.Outcome | Should -Be ([FileOutcome]::Unchanged)
                $change.Conflict | Should -Be ([ConflictKind]::None)
                $change.BackupPath | Should -BeExactly ''
            }
            foreach ($path in $before.Keys) {
                $now = [System.IO.File]::ReadAllBytes($path)
                (Test-SameByteArray $before[$path] $now) | Should -BeTrue
            }
            (Get-Item -LiteralPath ($settings + '.agent-done-toast.bak')).LastWriteTimeUtc | Should -Be $stamp
            Test-Path -LiteralPath ($toml + '.agent-done-toast.bak') | Should -BeFalse

            $removed = Invoke-Sync $sandbox ([SyncMode]::Remove)
            (Get-Outcome $removed $settings).Outcome | Should -Be ([FileOutcome]::Updated)
            Test-Path -LiteralPath $settings | Should -BeTrue
            Test-Path -LiteralPath $sandbox.Install | Should -BeFalse
            $after = [System.IO.File]::ReadAllText($settings) | ConvertFrom-Json
            $after.theme | Should -BeExactly 'dark'
            $left = New-Object System.Collections.Generic.List[string]
            foreach ($group in @($after.hooks.Stop)) {
                foreach ($hookLeft in @($group.hooks)) { $left.Add([string]$hookLeft.command) }
            }
            $left | Should -Contain 'C:\bin\other.exe'
            @($left | Where-Object { $_ -like '*invoke.ps1*' }).Count | Should -Be 0
            $after.hooks.PSObject.Properties.Name | Should -Not -Contain 'Notification'
            Test-Path -LiteralPath (Join-Path $sandbox.Menu 'AgentDoneToast.lnk') | Should -BeFalse
            Test-Path -LiteralPath $toml | Should -BeTrue
            [System.IO.File]::ReadAllText($toml) | Should -Not -Match 'notify ='

            $again = Invoke-Sync $sandbox ([SyncMode]::Remove)
            foreach ($change in $again.Files) {
                $change.Outcome | Should -Be ([FileOutcome]::Unchanged)
            }
        }
        finally {
            Remove-Sandbox $sandbox
        }
    }

    It 'leaves a foreign Codex notify in place and still wires the other files' {
        $sandbox = New-Sandbox
        try {
            $toml = Join-Path $sandbox.Profile '.codex\config.toml'
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $toml) -Force
            $original = "model = `"gpt`"`r`nnotify = [`"C:\\tools\\other.exe`"]`r`n"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($original)
            [System.IO.File]::WriteAllBytes($toml, $bytes)
            $report = Invoke-Sync $sandbox ([SyncMode]::Apply)
            $change = Get-Outcome $report $toml
            $change.Outcome | Should -Be ([FileOutcome]::Conflict)
            $change.Conflict | Should -Be ([ConflictKind]::ForeignCodexNotify)
            $change.BackupPath | Should -BeExactly ''
            (Test-SameByteArray $bytes ([System.IO.File]::ReadAllBytes($toml))) | Should -BeTrue
            Test-Path -LiteralPath ($toml + '.agent-done-toast.bak') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $sandbox.Profile '.claude\settings.json') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $sandbox.Profile '.cursor\hooks.json') | Should -BeTrue
        }
        finally {
            Remove-Sandbox $sandbox
        }
    }

    It 'splices a root notify without reformatting the rest of config.toml' {
        $sandbox = New-Sandbox
        try {
            $toml = Join-Path $sandbox.Profile '.codex\config.toml'
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $toml) -Force
            $original = "# keep me`r`nmodel = `"gpt`"`r`n`r`n[tui]`r`ntheme = `"dark`"`r`n"
            [System.IO.File]::WriteAllText($toml, $original)
            $report = Invoke-Sync $sandbox ([SyncMode]::Apply)
            (Get-Outcome $report $toml).Outcome | Should -Be ([FileOutcome]::Updated)
            $text = [System.IO.File]::ReadAllText($toml)
            $text.StartsWith("# keep me`r`nmodel = `"gpt`"`r`n") | Should -BeTrue
            $text.Contains("[tui]`r`ntheme = `"dark`"`r`n") | Should -BeTrue
            $text.IndexOf('notify = [') | Should -BeLessThan $text.IndexOf('[tui]')
            $nested = "bio = `"`"`"`r`nnotify = [`"not-root`"]`r`n`"`"`"`r`nmodel = `"a`"`r`n"
            [System.IO.File]::WriteAllText($toml, $nested)
            $second = Invoke-Sync $sandbox ([SyncMode]::Apply)
            (Get-Outcome $second $toml).Outcome | Should -Be ([FileOutcome]::Updated)
            $after = [System.IO.File]::ReadAllText($toml)
            $after.Contains('not-root') | Should -BeTrue
            ([regex]::Matches($after, 'notify = \[')).Count | Should -Be 2
        }
        finally {
            Remove-Sandbox $sandbox
        }
    }

    It 'does not refresh a notify whose parsed arguments already match' {
        $sandbox = New-Sandbox
        try {
            $first = Invoke-Sync $sandbox ([SyncMode]::Apply)
            $toml = Join-Path $sandbox.Profile '.codex\config.toml'
            (Get-Outcome $first $toml).Outcome | Should -Be ([FileOutcome]::Created)
            $text = [System.IO.File]::ReadAllText($toml)
            $spaced = $text.Replace('notify = [', 'notify =  [')
            [System.IO.File]::WriteAllText($toml, $spaced)
            $bytes = [System.IO.File]::ReadAllBytes($toml)
            $second = Invoke-Sync $sandbox ([SyncMode]::Apply)
            (Get-Outcome $second $toml).Outcome | Should -Be ([FileOutcome]::Unchanged)
            (Test-SameByteArray $bytes ([System.IO.File]::ReadAllBytes($toml))) | Should -BeTrue
        }
        finally {
            Remove-Sandbox $sandbox
        }
    }

    It 'reports unreadable JSON and an unsupported Cursor hooks version without writing' {
        $sandbox = New-Sandbox
        try {
            $settings = Join-Path $sandbox.Profile '.claude\settings.json'
            $cursor = Join-Path $sandbox.Profile '.cursor\hooks.json'
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $settings) -Force
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $cursor) -Force
            [System.IO.File]::WriteAllText($settings, '{')
            [System.IO.File]::WriteAllText($cursor, '{"version":2,"hooks":{}}')
            $settingsBytes = [System.IO.File]::ReadAllBytes($settings)
            $cursorBytes = [System.IO.File]::ReadAllBytes($cursor)
            $report = Invoke-Sync $sandbox ([SyncMode]::Apply)
            (Get-Outcome $report $settings).Conflict | Should -Be ([ConflictKind]::UnreadableConfig)
            (Get-Outcome $report $cursor).Conflict | Should -Be ([ConflictKind]::UnsupportedCursorHooksVersion)
            (Test-SameByteArray $settingsBytes ([System.IO.File]::ReadAllBytes($settings))) | Should -BeTrue
            (Test-SameByteArray $cursorBytes ([System.IO.File]::ReadAllBytes($cursor))) | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $sandbox.Profile '.codex\hooks.json') | Should -BeTrue
        }
        finally {
            Remove-Sandbox $sandbox
        }
    }

    It 'quotes a hook path that contains a space' {
        $sandbox = New-Sandbox
        try {
            $sandbox.Install = Join-Path $sandbox.Root 'Program Files\AgentDoneToast'
            $report = Invoke-Sync $sandbox ([SyncMode]::Apply)
            $report.Files.Count | Should -BeGreaterThan 0
            $settingsPath = Join-Path $sandbox.Profile '.claude\settings.json'
            $doc = [System.IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
            $hooks = @($(@($doc.hooks.Stop)[0].hooks))
            $command = [string]$hooks[0].command
            $invoke = Join-Path $sandbox.Install 'invoke.ps1'
            $command.Contains('-File "' + $invoke + '"') | Should -BeTrue
            $command | Should -Match 'claude-stop'
        }
        finally {
            Remove-Sandbox $sandbox
        }
    }
}

Describe 'install.ps1' {
    It 'exits 2 when Codex notify is foreign and exits 0 from uninstall' {
        $sandbox = New-Sandbox
        try {
            $toml = Join-Path $sandbox.Profile '.codex\config.toml'
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $toml) -Force
            $original = "notify = [`"C:\\tools\\other.exe`"]`n"
            [System.IO.File]::WriteAllText($toml, $original)
            $install = Invoke-ScriptFile -ScriptName 'install.ps1' -Sandbox $sandbox
            $install.ExitCode | Should -Be 2
            $install.StdOut | Should -Match 'Codex config.toml already has a notify command. Left that command in place.'
            $install.StdErr | Should -BeExactly ''
            Test-Path -LiteralPath (Join-Path $sandbox.Profile '.claude\settings.json') | Should -BeTrue
            [System.IO.File]::ReadAllText($toml) | Should -BeExactly $original
        }
        finally {
            Remove-Sandbox $sandbox
        }

        $clean = New-Sandbox
        try {
            $install = Invoke-ScriptFile -ScriptName 'install.ps1' -Sandbox $clean
            $install.ExitCode | Should -Be 0
            $install.StdErr | Should -BeExactly ''
            $install.StdOut | Should -Match 'Created'
            $remove = Invoke-ScriptFile -ScriptName 'uninstall.ps1' -Sandbox $clean
            $remove.ExitCode | Should -Be 0
            $remove.StdErr | Should -BeExactly ''
            Test-Path -LiteralPath (Join-Path $clean.Profile '.claude\settings.json') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $clean.Profile 'AppData\Local\AgentDoneToast') | Should -BeFalse
            $left = [System.IO.File]::ReadAllText((Join-Path $clean.Profile '.claude\settings.json'))
            $left | Should -Not -Match 'invoke.ps1'
        }
        finally {
            Remove-Sandbox $clean
        }
    }
}
