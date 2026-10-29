enum AgentKind {
    Claude
    Codex
    Cursor
}

enum ToastReason {
    Done
    NeedsInput
}

enum QuietWhen {
    None
    StopHookActive
    StatusNotCompleted
}

enum HookFileKind {
    ClaudeSettings
    CodexConfigToml
    CodexHooks
    CursorHooks
}

enum SyncMode {
    Apply
    Remove
}

enum FileOutcome {
    Unchanged
    Created
    Updated
    Conflict
    Removed
}

enum ConflictKind {
    None
    ForeignCodexNotify
    UnreadableConfig
    UnsupportedCursorHooksVersion
}

enum QuietReason {
    MalformedPayload
    EventMismatch
    StopHookActive
    NotCompleted
    UnknownBinding
    WinRtFailed
}

class Binding {
    [string]$Id
    [AgentKind]$Agent
    [ToastReason]$Reason
    [HookFileKind]$FileKind
    [string]$EventName
    [string]$Matcher
    [QuietWhen]$QuietWhen
}

# Domain record. Agent and Reason come from the binding row, never from the payload.
class ToastRequest {
    [AgentKind]$Agent
    [ToastReason]$Reason
    [string]$ProjectDirectory
}

class ToastNote {
    [string]$Title
    [string]$Body
    [string]$AppId
}

class ShowToast {
    [ToastRequest]$Request
}

class StayQuiet {
    [QuietReason]$Reason
}

class FileChange {
    [string]$Path
    [FileOutcome]$Outcome
    [string]$BackupPath
    [ConflictKind]$Conflict
}

class InstallReport {
    [FileChange[]]$Files
}

$script:JsonArraySentinel = '__agent_done_toast_keep_array_7f3a__'

function Sync-AgentDoneToast {
    <#
    .SYNOPSIS
    Make the user-level tool files and hook configs match the binding table.
    .NOTES
    Emits exactly one InstallReport. Apply and Remove are safe to repeat.
    A second Apply that finds the desired commands writes nothing and does not refresh backups.
    #>
    [CmdletBinding()]
    [OutputType([InstallReport])]
    param(
        [Parameter(Mandatory = $true)]
        [SyncMode]$Mode,
        [string]$UserProfile = $env:USERPROFILE,
        [string]$CodexHome = $env:CODEX_HOME,
        [string]$InstallRoot = $(Join-Path $env:LOCALAPPDATA 'AgentDoneToast'),
        [string]$StartMenuPrograms = $(Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
    )

    if ([string]::IsNullOrWhiteSpace($CodexHome)) {
        $CodexHome = Join-Path $UserProfile '.codex'
    }

    $rows = Get-AgentDoneToastBindings
    $groups = Group-BindingRows -Rows $rows -UserProfile $UserProfile -CodexHome $CodexHome
    $changes = New-Object System.Collections.Generic.List[FileChange]
    $sourceRoot = $PSScriptRoot

    if ($Mode -eq [SyncMode]::Apply) {
        foreach ($name in @('invoke.ps1', 'AgentDoneToast.psm1')) {
            $changes.Add((Sync-ToolFile -Name $name -SourceRoot $sourceRoot -InstallRoot $InstallRoot -Mode $Mode))
        }
        $shortcut = Sync-StartMenuShortcut -StartMenuPrograms $StartMenuPrograms -InstallRoot $InstallRoot -Mode $Mode
        if ($null -ne $shortcut) { $changes.Add($shortcut) }
        foreach ($group in $groups) {
            $changes.Add((Update-UserConfig -Path $group.Path -Rows $group.Rows -Mode $Mode -InstallRoot $InstallRoot))
        }
    }
    elseif ($Mode -eq [SyncMode]::Remove) {
        foreach ($group in $groups) {
            $changes.Add((Update-UserConfig -Path $group.Path -Rows $group.Rows -Mode $Mode -InstallRoot $InstallRoot))
        }
        $changes.Add((Sync-StartMenuShortcut -StartMenuPrograms $StartMenuPrograms -InstallRoot $InstallRoot -Mode $Mode))
        foreach ($name in @('invoke.ps1', 'AgentDoneToast.psm1')) {
            $changes.Add((Sync-ToolFile -Name $name -SourceRoot $sourceRoot -InstallRoot $InstallRoot -Mode $Mode))
        }
        if (Test-Path -LiteralPath $InstallRoot) {
            Remove-Item -LiteralPath $InstallRoot -Recurse -Force
        }
    }
    else {
        throw "unknown sync mode $Mode"
    }

    $report = [InstallReport]::new()
    $report.Files = $changes.ToArray()
    return $report
}

function Invoke-AgentDoneToast {
    <#
    .SYNOPSIS
    Map one hook payload to a toast or to silence, then publish the toast.
    .NOTES
    Returns exactly one ShowToast or one StayQuiet.
    Writes nothing to the success, error, warning, information, or verbose streams.
    Does not include the payload in any returned object.
    Expected failures return StayQuiet. Thrown exceptions are reserved for broken invariants.
    #>
    [CmdletBinding()]
    [OutputType([ShowToast], [StayQuiet])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BindingId,
        [string]$StdinText = '',
        [string]$ArgumentText = '',
        [scriptblock]$Notifier
    )

    $row = $null
    foreach ($candidate in (Get-AgentDoneToastBindings)) {
        if ($candidate.Id -eq $BindingId) {
            $row = $candidate
            break
        }
    }
    if ($null -eq $row) {
        return New-StayQuiet -Reason ([QuietReason]::UnknownBinding)
    }

    $text = $StdinText
    if ($row.FileKind -eq [HookFileKind]::CodexConfigToml) {
        $text = $ArgumentText
    }
    $cursorDir = ''
    if ($null -ne $env:CURSOR_PROJECT_DIR) {
        $cursorDir = [string]$env:CURSOR_PROJECT_DIR
    }

    $intake = ConvertTo-IntakeResult -Binding $row -PayloadText $text -CursorProjectDir $cursorDir
    if ($intake -is [StayQuiet]) {
        return $intake
    }
    if ($intake -isnot [ShowToast]) {
        throw 'intake returned an unexpected result'
    }

    $note = New-ToastNote -Request $intake.Request
    if ($PSBoundParameters.ContainsKey('Notifier')) {
        $null = & $Notifier $note
    }
    else {
        try {
            Publish-WinRtToast -Note $note
        }
        catch {
            return New-StayQuiet -Reason ([QuietReason]::WinRtFailed)
        }
    }
    return $intake
}

function Get-ToastAppId {
    [OutputType([string])]
    param()
    return 'AgentDoneToast'
}

function Get-AgentDoneToastBindings {
    [OutputType([Binding[]])]
    param()

    $new = {
        param(
            [string]$Id,
            [AgentKind]$Agent,
            [ToastReason]$Reason,
            [HookFileKind]$FileKind,
            [string]$EventName,
            [string]$Matcher,
            [QuietWhen]$QuietWhen
        )
        $binding = [Binding]::new()
        $binding.Id = $Id
        $binding.Agent = $Agent
        $binding.Reason = $Reason
        $binding.FileKind = $FileKind
        $binding.EventName = $EventName
        $binding.Matcher = $Matcher
        $binding.QuietWhen = $QuietWhen
        return $binding
    }

    $rows = @(
        & $new 'claude-stop' ([AgentKind]::Claude) ([ToastReason]::Done) ([HookFileKind]::ClaudeSettings) 'Stop' '' ([QuietWhen]::StopHookActive)
        & $new 'claude-permission-request' ([AgentKind]::Claude) ([ToastReason]::NeedsInput) ([HookFileKind]::ClaudeSettings) 'PermissionRequest' '' ([QuietWhen]::None)
        & $new 'claude-elicitation-dialog' ([AgentKind]::Claude) ([ToastReason]::NeedsInput) ([HookFileKind]::ClaudeSettings) 'Notification' 'elicitation_dialog' ([QuietWhen]::None)
        & $new 'claude-elicitation-url-dialog' ([AgentKind]::Claude) ([ToastReason]::NeedsInput) ([HookFileKind]::ClaudeSettings) 'Notification' 'elicitation_url_dialog' ([QuietWhen]::None)
        & $new 'claude-agent-needs-input' ([AgentKind]::Claude) ([ToastReason]::NeedsInput) ([HookFileKind]::ClaudeSettings) 'Notification' 'agent_needs_input' ([QuietWhen]::None)
        & $new 'codex-turn-complete' ([AgentKind]::Codex) ([ToastReason]::Done) ([HookFileKind]::CodexConfigToml) 'agent-turn-complete' '' ([QuietWhen]::None)
        & $new 'codex-permission-request' ([AgentKind]::Codex) ([ToastReason]::NeedsInput) ([HookFileKind]::CodexHooks) 'PermissionRequest' '' ([QuietWhen]::None)
        & $new 'cursor-stop' ([AgentKind]::Cursor) ([ToastReason]::Done) ([HookFileKind]::CursorHooks) 'stop' 'Stop' ([QuietWhen]::StatusNotCompleted)
    )

    $seen = @{}
    foreach ($row in $rows) {
        if ($seen.ContainsKey($row.Id)) {
            throw "duplicate binding id $($row.Id)"
        }
        $seen[$row.Id] = $true
        if (-not $row.EventName) {
            throw "missing event name $($row.Id)"
        }
        if ($row.Agent -eq [AgentKind]::Cursor -and $row.Reason -eq [ToastReason]::NeedsInput) {
            throw "Cursor has no needs-input hook ($($row.Id))"
        }
        if ($row.FileKind -eq [HookFileKind]::CodexConfigToml -and $row.EventName -ne 'agent-turn-complete') {
            throw "Codex notify only documents agent-turn-complete ($($row.Id))"
        }
        if ($row.FileKind -eq [HookFileKind]::CodexConfigToml -and $row.Reason -ne [ToastReason]::Done) {
            throw "Codex notify is the done event ($($row.Id))"
        }
        if ($row.EventName -eq 'Notification' -and -not $row.Matcher) {
            throw "Notification bindings require a matcher ($($row.Id))"
        }
        if ($row.FileKind -eq [HookFileKind]::CursorHooks -and $row.Matcher -ne 'Stop') {
            throw "Cursor hooks require matcher Stop ($($row.Id))"
        }
        $cursorStop = $row.Agent -eq [AgentKind]::Cursor -and $row.EventName -eq 'stop'
        if ($cursorStop -and $row.QuietWhen -ne [QuietWhen]::StatusNotCompleted) {
            throw "Cursor stop stays quiet unless status is completed ($($row.Id))"
        }
        if (-not $cursorStop -and $row.QuietWhen -eq [QuietWhen]::StatusNotCompleted) {
            throw "StatusNotCompleted is only valid for cursor-stop ($($row.Id))"
        }
        $claudeStop = $row.Agent -eq [AgentKind]::Claude -and $row.EventName -eq 'Stop'
        if ($claudeStop -and $row.QuietWhen -ne [QuietWhen]::StopHookActive) {
            throw "Claude Stop stays quiet when stop_hook_active is true ($($row.Id))"
        }
        if (-not $claudeStop -and $row.QuietWhen -eq [QuietWhen]::StopHookActive) {
            throw "StopHookActive is only valid for claude-stop ($($row.Id))"
        }
    }

    Write-Output -NoEnumerate -InputObject $rows
}

function Get-ConfigPath {
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [Binding]$Binding,
        [Parameter(Mandatory = $true)]
        [string]$UserProfile,
        [Parameter(Mandatory = $true)]
        [string]$CodexHome
    )

    if ($Binding.FileKind -eq [HookFileKind]::ClaudeSettings) {
        return Join-Path $UserProfile '.claude\settings.json'
    }
    if ($Binding.FileKind -eq [HookFileKind]::CursorHooks) {
        return Join-Path $UserProfile '.cursor\hooks.json'
    }
    if ($Binding.FileKind -eq [HookFileKind]::CodexConfigToml) {
        return Join-Path $CodexHome 'config.toml'
    }
    if ($Binding.FileKind -eq [HookFileKind]::CodexHooks) {
        return Join-Path $CodexHome 'hooks.json'
    }
    throw "unknown file kind $($Binding.FileKind)"
}

function Get-WindowsPowerShellExe {
    # Join-Path treats C: as a drive. That drive is absent when a test host is not Windows, and the hook still stores this Windows path.
    if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        throw 'SystemRoot is required to build the hook command'
    }
    return '{0}\System32\WindowsPowerShell\v1.0\powershell.exe' -f $env:SystemRoot
}

function Get-HookArgumentList {
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [Binding]$Binding,
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot
    )

    # -File keeps a JSON argument that starts with { from being parsed as a script block.
    $argv = @(
        (Get-WindowsPowerShellExe),
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-File',
        (Join-Path $InstallRoot 'invoke.ps1'),
        '-BindingId',
        $Binding.Id
    )
    return ,$argv
}

function New-StayQuiet {
    param([Parameter(Mandatory = $true)][QuietReason]$Reason)
    $quiet = [StayQuiet]::new()
    $quiet.Reason = $Reason
    return $quiet
}

function New-ShowToast {
    param(
        [Parameter(Mandatory = $true)][Binding]$Binding,
        [string]$ProjectDirectory
    )
    $request = [ToastRequest]::new()
    $request.Agent = $Binding.Agent
    $request.Reason = $Binding.Reason
    if ($null -eq $ProjectDirectory) { $ProjectDirectory = '' }
    $request.ProjectDirectory = $ProjectDirectory
    $show = [ShowToast]::new()
    $show.Request = $request
    return $show
}

function Get-JsonString {
    param($Object, [string]$Name)
    if ($null -eq $Object -or $Object -isnot [pscustomobject]) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if (-not $prop -or $prop.Value -isnot [string]) { return $null }
    return [string]$prop.Value
}

function ConvertTo-IntakeResult {
    [OutputType([ShowToast], [StayQuiet])]
    param(
        [Parameter(Mandatory = $true)]
        [Binding]$Binding,
        [string]$PayloadText = '',
        [string]$CursorProjectDir = ''
    )

    if ([string]::IsNullOrWhiteSpace($PayloadText)) {
        return New-StayQuiet -Reason ([QuietReason]::MalformedPayload)
    }

    $payload = $null
    try {
        $payload = $PayloadText | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return New-StayQuiet -Reason ([QuietReason]::MalformedPayload)
    }
    if ($null -eq $payload -or $payload -isnot [pscustomobject]) {
        return New-StayQuiet -Reason ([QuietReason]::MalformedPayload)
    }

    $eventField = 'hook_event_name'
    if ($Binding.FileKind -eq [HookFileKind]::CodexConfigToml) {
        $eventField = 'type'
    }
    $eventValue = Get-JsonString $payload $eventField
    if ($null -eq $eventValue) {
        return New-StayQuiet -Reason ([QuietReason]::EventMismatch)
    }
    if ([string]::Compare($eventValue, $Binding.EventName, [StringComparison]::OrdinalIgnoreCase) -ne 0) {
        return New-StayQuiet -Reason ([QuietReason]::EventMismatch)
    }

    # Claude sends notification_type. The config matcher is not a payload field.
    if ($Binding.EventName -eq 'Notification') {
        $typeProp = $payload.PSObject.Properties['notification_type']
        if ($typeProp) {
            $actual = $typeProp.Value
            $actualText = ''
            if ($actual -is [string]) { $actualText = $actual }
            elseif ($null -ne $actual) { $actualText = [string]$actual }
            if ([string]::CompareOrdinal($actualText, $Binding.Matcher) -ne 0) {
                return New-StayQuiet -Reason ([QuietReason]::EventMismatch)
            }
        }
    }

    if ($Binding.QuietWhen -eq [QuietWhen]::StopHookActive) {
        $flag = $payload.PSObject.Properties['stop_hook_active']
        if ($flag -and ($flag.Value -is [bool]) -and $flag.Value) {
            return New-StayQuiet -Reason ([QuietReason]::StopHookActive)
        }
    }
    elseif ($Binding.QuietWhen -eq [QuietWhen]::StatusNotCompleted) {
        $status = $payload.PSObject.Properties['status']
        $completed = $status -and ($status.Value -is [string]) -and ($status.Value -ceq 'completed')
        if (-not $completed) {
            return New-StayQuiet -Reason ([QuietReason]::NotCompleted)
        }
    }
    elseif ($Binding.QuietWhen -ne [QuietWhen]::None) {
        throw "unknown quiet rule $($Binding.QuietWhen)"
    }

    $directory = ''
    if ($Binding.Agent -eq [AgentKind]::Cursor) {
        if ($CursorProjectDir -is [string]) { $directory = $CursorProjectDir }
    }
    else {
        $cwd = Get-JsonString $payload 'cwd'
        if ($null -ne $cwd) { $directory = $cwd }
    }

    return New-ShowToast -Binding $Binding -ProjectDirectory $directory
}

function New-ToastNote {
    [OutputType([ToastNote])]
    param(
        [Parameter(Mandatory = $true)]
        [ToastRequest]$Request
    )

    $name = ''
    if ($Request.Agent -eq [AgentKind]::Claude) { $name = 'Claude Code' }
    elseif ($Request.Agent -eq [AgentKind]::Codex) { $name = 'Codex' }
    elseif ($Request.Agent -eq [AgentKind]::Cursor) { $name = 'Cursor' }
    else { throw "unknown agent $($Request.Agent)" }

    $suffix = ''
    if ($Request.Reason -eq [ToastReason]::Done) { $suffix = ' finished' }
    elseif ($Request.Reason -eq [ToastReason]::NeedsInput) { $suffix = ' needs you' }
    else { throw "unknown reason $($Request.Reason)" }

    $body = $Request.ProjectDirectory
    if ([string]::IsNullOrWhiteSpace($body)) {
        $body = 'No project path'
    }

    $note = [ToastNote]::new()
    $note.Title = $name + $suffix
    $note.Body = $body
    $note.AppId = Get-ToastAppId
    return $note
}

function ConvertTo-XmlText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

function Publish-WinRtToast {
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ToastNote]$Note
    )

    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]

    $xmlText = '<toast activationType="background"><visual><binding template="ToastGeneric"><text>' +
        (ConvertTo-XmlText $Note.Title) + '</text><text>' + (ConvertTo-XmlText $Note.Body) +
        '</text></binding></visual></toast>'
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml($xmlText)
    $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
    $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier((Get-ToastAppId))
    $notifier.Show($toast)
}

function New-FileChange {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][FileOutcome]$Outcome,
        [string]$BackupPath = '',
        [ConflictKind]$Conflict = [ConflictKind]::None
    )
    if ($Outcome -eq [FileOutcome]::Conflict) {
        if ($Conflict -eq [ConflictKind]::None) { throw 'conflict outcome requires a conflict kind' }
        $BackupPath = ''
    }
    elseif ($Conflict -ne [ConflictKind]::None) {
        throw 'only a conflict outcome carries a conflict kind'
    }
    if ($null -eq $BackupPath) { $BackupPath = '' }
    $change = [FileChange]::new()
    $change.Path = $Path
    $change.Outcome = $Outcome
    $change.BackupPath = $BackupPath
    $change.Conflict = $Conflict
    return $change
}

function Test-SamePath {
    param([string]$Left, [string]$Right)
    $leftFull = [System.IO.Path]::GetFullPath($Left)
    $rightFull = [System.IO.Path]::GetFullPath($Right)
    $ignoreCase = $true
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $ignoreCase = [bool]$IsWindows
    }
    $comparison = [StringComparison]::Ordinal
    if ($ignoreCase) { $comparison = [StringComparison]::OrdinalIgnoreCase }
    return [string]::Compare($leftFull, $rightFull, $comparison) -eq 0
}

function Test-SameBytes {
    param([byte[]]$Left, [byte[]]$Right)
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($i = 0; $i -lt $Left.Length; $i++) {
        if ($Left[$i] -ne $Right[$i]) { return $false }
    }
    return $true
}

function Write-FileReplacing {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    $tempPath = $Path + '.agent-done-toast.tmp'
    [System.IO.File]::WriteAllBytes($tempPath, $Bytes)
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Backup-UserFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $backupPath = $Path + '.agent-done-toast.bak'
    [System.IO.File]::Copy($Path, $backupPath, $true)
    return $backupPath
}

function Read-Utf8Document {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $bom = $false
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
        $bom = $true
    }
    $encoding = New-Object System.Text.UTF8Encoding $false, $true
    try {
        $text = $encoding.GetString($bytes)
    }
    catch {
        return $null
    }
    if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xFEFF) {
        $text = $text.Substring(1)
    }
    return @{ Text = $text; Bom = [bool]$bom }
}

function Sync-ToolFile {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][SyncMode]$Mode
    )
    $source = Join-Path $SourceRoot $Name
    $destination = Join-Path $InstallRoot $Name
    if ($Mode -eq [SyncMode]::Remove) {
        if (Test-Path -LiteralPath $destination) {
            return New-FileChange -Path $destination -Outcome ([FileOutcome]::Removed)
        }
        return New-FileChange -Path $destination -Outcome ([FileOutcome]::Unchanged)
    }
    if (-not (Test-Path -LiteralPath $source)) {
        throw "missing tool file $source"
    }
    if ((Test-Path -LiteralPath $destination) -and (Test-SamePath $source $destination)) {
        return New-FileChange -Path $destination -Outcome ([FileOutcome]::Unchanged)
    }
    $sourceBytes = [System.IO.File]::ReadAllBytes($source)
    if (Test-Path -LiteralPath $destination) {
        $destBytes = [System.IO.File]::ReadAllBytes($destination)
        if (Test-SameBytes $sourceBytes $destBytes) {
            return New-FileChange -Path $destination -Outcome ([FileOutcome]::Unchanged)
        }
        Write-FileReplacing -Path $destination -Bytes $sourceBytes
        return New-FileChange -Path $destination -Outcome ([FileOutcome]::Updated)
    }
    Write-FileReplacing -Path $destination -Bytes $sourceBytes
    return New-FileChange -Path $destination -Outcome ([FileOutcome]::Created)
}

function Test-WScriptShell {
    try {
        $shell = New-Object -ComObject WScript.Shell
        $null = $shell
        return $true
    }
    catch {
        return $false
    }
}

function Initialize-ShortcutWriter {
    if ('AgentDoneToastShortcut.Writer' -as [type]) { return }
    $source = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace AgentDoneToastShortcut {
    [StructLayout(LayoutKind.Sequential)]
    public struct PropertyKey {
        public Guid fmtid;
        public uint pid;
        public PropertyKey(Guid fmtid, uint pid) {
            this.fmtid = fmtid;
            this.pid = pid;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PropVariant {
        public ushort vt;
        public ushort wReserved1;
        public ushort wReserved2;
        public ushort wReserved3;
        public IntPtr p;
        public int unused;

        public static PropVariant FromString(string value) {
            PropVariant pv = new PropVariant();
            pv.vt = 31;
            pv.p = Marshal.StringToCoTaskMemUni(value);
            return pv;
        }
    }

    [ComImport]
    [Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore {
        void GetCount(out uint cProps);
        void GetAt(uint iProp, out PropertyKey pkey);
        void GetValue(ref PropertyKey key, out PropVariant pv);
        void SetValue(ref PropertyKey key, ref PropVariant pv);
        void Commit();
    }

    [ComImport]
    [Guid("00021401-0000-0000-C000-000000000046")]
    public class CShellLink {
    }

    [ComImport]
    [Guid("000214F9-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IShellLinkW {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile, int cchMaxPath, IntPtr pfd, uint fFlags);
        void GetIDList(out IntPtr ppidl);
        void SetIDList(IntPtr pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszName, int cchMaxName);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir, int cchMaxPath);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs, int cchMaxPath);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
        void GetHotkey(out short pwHotkey);
        void SetHotkey(short wHotkey);
        void GetShowCmd(out int piShowCmd);
        void SetShowCmd(int iShowCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath, int cchIconPath, out int piIcon);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
        void Resolve(IntPtr hwnd, uint fFlags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
    }

    [ComImport]
    [Guid("0000010B-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPersistFile {
        void GetClassID(out Guid pClassID);
        [PreserveSig]
        int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, [MarshalAs(UnmanagedType.Bool)] bool fRemember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
    }

    public static class Native {
        [DllImport("ole32.dll")]
        public static extern int PropVariantClear(ref PropVariant pvar);
    }

    public static class Writer {
        static PropertyKey AppIdKey() {
            return new PropertyKey(new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), 5);
        }

        public static void Save(string path, string appId, string targetPath) {
            IShellLinkW link = (IShellLinkW)new CShellLink();
            link.SetPath(targetPath);
            link.SetShowCmd(0);
            IPropertyStore store = (IPropertyStore)link;
            PropertyKey key = AppIdKey();
            PropVariant pv = PropVariant.FromString(appId);
            store.SetValue(ref key, ref pv);
            store.Commit();
            Native.PropVariantClear(ref pv);
            IPersistFile file = (IPersistFile)link;
            file.Save(path, true);
        }

        public static string ReadAppId(string path) {
            IShellLinkW link = (IShellLinkW)new CShellLink();
            IPersistFile file = (IPersistFile)link;
            file.Load(path, 0);
            IPropertyStore store = (IPropertyStore)link;
            PropertyKey key = AppIdKey();
            PropVariant pv;
            store.GetValue(ref key, out pv);
            string value = null;
            if (pv.vt == 31 && pv.p != IntPtr.Zero) {
                value = Marshal.PtrToStringUni(pv.p);
            }
            Native.PropVariantClear(ref pv);
            return value;
        }
    }
}
'@
    Add-Type -TypeDefinition $source -Language CSharp
}

function Get-ShortcutAppIdOrNull {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        return [AgentDoneToastShortcut.Writer]::ReadAppId($Path)
    }
    catch {
        return $null
    }
}

function Sync-StartMenuShortcut {
    param(
        [Parameter(Mandatory = $true)][string]$StartMenuPrograms,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][SyncMode]$Mode
    )
    $shortcutPath = Join-Path $StartMenuPrograms 'AgentDoneToast.lnk'
    if ($Mode -eq [SyncMode]::Remove) {
        if (Test-Path -LiteralPath $shortcutPath) {
            Remove-Item -LiteralPath $shortcutPath -Force
            return New-FileChange -Path $shortcutPath -Outcome ([FileOutcome]::Removed)
        }
        return New-FileChange -Path $shortcutPath -Outcome ([FileOutcome]::Unchanged)
    }
    if (-not (Test-WScriptShell)) {
        return $null
    }
    Initialize-ShortcutWriter
    $appId = Get-ToastAppId
    $target = Get-WindowsPowerShellExe
    if (Test-Path -LiteralPath $shortcutPath) {
        if ((Get-ShortcutAppIdOrNull -Path $shortcutPath) -eq $appId) {
            return New-FileChange -Path $shortcutPath -Outcome ([FileOutcome]::Unchanged)
        }
        [AgentDoneToastShortcut.Writer]::Save($shortcutPath, $appId, $target)
        return New-FileChange -Path $shortcutPath -Outcome ([FileOutcome]::Updated)
    }
    $directory = Split-Path -Parent $shortcutPath
    if (-not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    [AgentDoneToastShortcut.Writer]::Save($shortcutPath, $appId, $target)
    return New-FileChange -Path $shortcutPath -Outcome ([FileOutcome]::Created)
}

function Group-BindingRows {
    param(
        [Parameter(Mandatory = $true)][Binding[]]$Rows,
        [Parameter(Mandatory = $true)][string]$UserProfile,
        [Parameter(Mandatory = $true)][string]$CodexHome
    )
    $order = New-Object System.Collections.Generic.List[string]
    $map = @{}
    foreach ($row in $Rows) {
        $path = Get-ConfigPath -Binding $row -UserProfile $UserProfile -CodexHome $CodexHome
        if (-not $map.ContainsKey($path)) {
            $map[$path] = New-Object System.Collections.Generic.List[Binding]
            $order.Add($path)
        }
        $map[$path].Add($row)
    }
    $groups = New-Object System.Collections.Generic.List[object]
    foreach ($path in $order) {
        $groups.Add([pscustomobject]@{
            Path = $path
            Rows = $map[$path].ToArray()
        })
    }
    return ,$groups.ToArray()
}

function Update-UserConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][Binding[]]$Rows,
        [Parameter(Mandatory = $true)][SyncMode]$Mode,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )
    $kind = $Rows[0].FileKind
    $exists = Test-Path -LiteralPath $Path
    if (-not $exists -and $Mode -eq [SyncMode]::Remove) {
        return New-FileChange -Path $Path -Outcome ([FileOutcome]::Unchanged)
    }
    if ($kind -eq [HookFileKind]::CodexConfigToml) {
        return Update-CodexToml -Path $Path -Row $Rows[0] -Mode $Mode -InstallRoot $InstallRoot -Exists $exists
    }
    return Update-JsonConfig -Path $Path -Rows $Rows -Mode $Mode -InstallRoot $InstallRoot -Exists $exists -Kind $kind
}

function ConvertTo-NoteObject {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [bool] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $obj = New-Object psobject
        foreach ($key in @($Value.Keys)) {
            $child = ConvertTo-NoteObject $Value[$key]
            Add-Member -InputObject $obj -NotePropertyName ([string]$key) -NotePropertyValue $child
        }
        return $obj
    }
    if ($Value -is [System.Collections.IList]) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Value) {
            $list.Add((ConvertTo-NoteObject $item))
        }
        return ,$list.ToArray()
    }
    return $Value
}

function ConvertFrom-HookJson {
    param([Parameter(Mandatory = $true)][string]$Text)
    # Windows PowerShell 5.1 ConvertFrom-Json turns a one-element array into one object.
    if ($PSVersionTable.PSVersion.Major -le 5) {
        Add-Type -AssemblyName System.Web.Extensions
        $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $serializer.MaxJsonLength = [int]::MaxValue
        $serializer.RecursionLimit = 64
        $raw = $serializer.DeserializeObject($Text)
        return ConvertTo-NoteObject $raw
    }
    return ($Text | ConvertFrom-Json -ErrorAction Stop)
}

function Copy-JsonNode {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [bool] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IList]) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Value) {
            $list.Add((Copy-JsonNode $item))
        }
        # Windows PowerShell 5.1 ConvertTo-Json writes a one-element array as a bare value.
        $list.Add($script:JsonArraySentinel)
        return ,$list.ToArray()
    }
    if ($Value -is [pscustomobject]) {
        $copy = New-Object psobject
        foreach ($prop in $Value.PSObject.Properties) {
            $child = Copy-JsonNode $prop.Value
            Add-Member -InputObject $copy -NotePropertyName $prop.Name -NotePropertyValue $child
        }
        return $copy
    }
    return $Value
}

function ConvertTo-JsonPreserveArrays {
    param($InputObject)
    $clone = Copy-JsonNode $InputObject
    $json = ConvertTo-Json -InputObject $clone -Depth 32
    $escaped = [regex]::Escape($script:JsonArraySentinel)
    $json = [regex]::Replace($json, '\[' + '\s*"' + $escaped + '"\s*\]', '[]')
    $json = [regex]::Replace($json, ',\s*"' + $escaped + '"', '')
    return $json
}

function Set-NoteProperty {
    param($Object, [string]$Name, $Value)
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { $prop.Value = $Value }
    else {
        Add-Member -InputObject $Object -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Test-HasProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Resolve-PropertyName {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $Name }
    foreach ($prop in $Object.PSObject.Properties) {
        if ([string]::Compare($prop.Name, $Name, [StringComparison]::OrdinalIgnoreCase) -eq 0) {
            return $prop.Name
        }
    }
    return $Name
}

function Get-ChildArray {
    param($Object, [string]$Name)
    $items = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Object) { return ,$items.ToArray() }
    $prop = $Object.PSObject.Properties[$Name]
    if (-not $prop -or $null -eq $prop.Value) { return ,$items.ToArray() }
    $value = $prop.Value
    if ($value -is [System.Array]) {
        foreach ($item in $value) { $items.Add($item) }
    }
    else {
        $items.Add($value)
    }
    return ,$items.ToArray()
}

function Set-ChildArray {
    param($Object, [string]$Name, [object[]]$Items)
    if ($null -eq $Items) { $Items = @() }
    $stored = New-Object object[] $Items.Count
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $stored[$i] = $Items[$i]
    }
    Set-NoteProperty $Object $Name $stored
}

function Test-CursorVersionOne {
    param($Version)
    if ($Version -is [string]) {
        return [string]::CompareOrdinal($Version, '1') -eq 0
    }
    $numeric = $Version -is [byte] -or $Version -is [int16] -or $Version -is [int32] -or $Version -is [int64] -or $Version -is [decimal] -or $Version -is [double] -or $Version -is [single]
    if ($numeric) { return ($Version -eq 1) }
    return $false
}

function Test-ItemsAreObjects {
    param($Object, [string]$Name)
    if (-not (Test-HasProperty $Object $Name)) { return $true }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop.Value) { return $true }
    $items = Get-ChildArray $Object $Name
    foreach ($item in $items) {
        if ($null -ne $item -and $item -isnot [pscustomobject]) { return $false }
    }
    return $true
}

function Format-CommandToken {
    param([string]$Token)
    if ($Token -notmatch '[\s"]') { return $Token }
    return '"' + $Token.Replace('"', '`"' ) + '"'
}

function Format-CommandLine {
    param([string[]]$ArgumentList)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($arg in $ArgumentList) {
        $parts.Add((Format-CommandToken ([string]$arg)))
    }
    return ($parts -join ' ')
}

function New-CommandHook {
    param(
        [Parameter(Mandatory = $true)][Binding]$Binding,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )
    $argv = Get-HookArgumentList -Binding $Binding -InstallRoot $InstallRoot
    $commandText = Format-CommandLine -ArgumentList $argv
    if ($Binding.FileKind -eq [HookFileKind]::CursorHooks) {
        return [pscustomobject]@{
            command = $commandText
            matcher = $Binding.Matcher
        }
    }
    if ($Binding.FileKind -eq [HookFileKind]::CodexHooks) {
        return [pscustomobject]@{
            type = 'command'
            command = $commandText
            commandWindows = $commandText
            async = [bool]$true
            timeout = [int]15
        }
    }
    if ($Binding.FileKind -eq [HookFileKind]::ClaudeSettings) {
        return [pscustomobject]@{
            type = 'command'
            command = $commandText
            async = [bool]$true
            shell = 'powershell'
            timeout = [int]15
        }
    }
    throw "no command object for $($Binding.FileKind)"
}

function Test-OwnedCommandText {
    param([string]$CommandText, [string]$InstallRoot, [string]$BindingId)
    if ([string]::IsNullOrEmpty($CommandText)) { return $false }
    $invokePath = Join-Path $InstallRoot 'invoke.ps1'
    if ($CommandText.IndexOf($invokePath, [StringComparison]::Ordinal) -lt 0) { return $false }
    $flag = '-BindingId'
    $search = 0
    while ($search -lt $CommandText.Length) {
        $at = $CommandText.IndexOf($flag, $search, [StringComparison]::Ordinal)
        if ($at -lt 0) { return $false }
        $beforeOk = $at -eq 0 -or [char]::IsWhiteSpace($CommandText[$at - 1])
        $after = $at + $flag.Length
        $afterOk = $after -ge $CommandText.Length -or [char]::IsWhiteSpace($CommandText[$after])
        if ($beforeOk -and $afterOk) {
            $cursor = $after
            while ($cursor -lt $CommandText.Length -and [char]::IsWhiteSpace($CommandText[$cursor])) { $cursor++ }
            $end = $cursor
            while ($end -lt $CommandText.Length -and -not [char]::IsWhiteSpace($CommandText[$end])) { $end++ }
            if ($end -gt $cursor) {
                $token = $CommandText.Substring($cursor, $end - $cursor).Trim([char]'"').Trim([char]"'")
                if ([string]::CompareOrdinal($token, $BindingId) -eq 0) { return $true }
            }
        }
        $search = $at + $flag.Length
    }
    return $false
}

function Test-OwnedHookObject {
    param($Hook, [string]$InstallRoot, [string]$BindingId)
    if ($Hook -isnot [pscustomobject]) { return $false }
    $command = Get-JsonString $Hook 'command'
    if ($null -ne $command -and (Test-OwnedCommandText $command $InstallRoot $BindingId)) { return $true }
    $commandWindows = Get-JsonString $Hook 'commandWindows'
    if ($null -ne $commandWindows -and (Test-OwnedCommandText $commandWindows $InstallRoot $BindingId)) { return $true }
    return $false
}

function Test-SameHook {
    param($Actual, $Desired)
    if ($Actual -isnot [pscustomobject] -or $Desired -isnot [pscustomobject]) { return $false }
    $actualNames = @($Actual.PSObject.Properties.Name)
    $desiredNames = @($Desired.PSObject.Properties.Name)
    if ($actualNames.Count -ne $desiredNames.Count) { return $false }
    foreach ($name in $desiredNames) {
        $prop = $Actual.PSObject.Properties[$name]
        if (-not $prop) { return $false }
        $left = $prop.Value
        $right = $Desired.$name
        if ($right -is [bool]) {
            if ($left -isnot [bool] -or ($left -ne $right)) { return $false }
        }
        elseif ($right -is [int] -or $right -is [long] -or $right -is [double]) {
            if ($left -is [string] -or ($left -ne $right)) { return $false }
        }
        else {
            if ($left -isnot [string]) { return $false }
            if ([string]::CompareOrdinal([string]$left, [string]$right) -ne 0) { return $false }
        }
    }
    return $true
}

function New-HookGroup {
    param([string]$Matcher, $Hook)
    $group = New-Object psobject
    if (-not [string]::IsNullOrEmpty($Matcher)) {
        Add-Member -InputObject $group -NotePropertyName 'matcher' -NotePropertyValue $Matcher
    }
    $hooks = New-Object object[] 1
    $hooks[0] = $Hook
    Add-Member -InputObject $group -NotePropertyName 'hooks' -NotePropertyValue $hooks
    return $group
}

function Get-GroupMatcher {
    param($Group)
    if ($Group -isnot [pscustomobject]) { return $null }
    $prop = $Group.PSObject.Properties['matcher']
    if (-not $prop -or $null -eq $prop.Value) { return '' }
    if ($prop.Value -isnot [string]) { return $null }
    return [string]$prop.Value
}

function Test-GroupOwnsBinding {
    param($Group, [string]$BindingId, [string]$InstallRoot)
    if ($Group -isnot [pscustomobject]) { return $false }
    foreach ($hook in (Get-ChildArray $Group 'hooks')) {
        if (Test-OwnedHookObject $hook $InstallRoot $BindingId) { return $true }
    }
    return $false
}

function Find-TargetGroup {
    param($Groups, [Binding]$Row, [string]$InstallRoot)
    if ($Row.Matcher) {
        foreach ($group in $Groups) {
            $matcher = Get-GroupMatcher $group
            if ($null -ne $matcher -and [string]::CompareOrdinal($matcher, $Row.Matcher) -eq 0) {
                return $group
            }
        }
        return $null
    }
    foreach ($group in $Groups) {
        $matcher = Get-GroupMatcher $group
        if ($matcher -ne '') { continue }
        if (Test-GroupOwnsBinding $group $Row.Id $InstallRoot) { return $group }
    }
    return $null
}

function Strip-BindingFromGroup {
    param($Group, [string]$BindingId, [string]$InstallRoot)
    if ($Group -isnot [pscustomobject]) { return $false }
    if (-not (Test-HasProperty $Group 'hooks')) { return $false }
    $hooks = Get-ChildArray $Group 'hooks'
    $kept = New-Object System.Collections.Generic.List[object]
    $changed = $false
    foreach ($hook in $hooks) {
        if (Test-OwnedHookObject $hook $InstallRoot $BindingId) {
            $changed = $true
            continue
        }
        $kept.Add($hook)
    }
    if ($changed) { Set-ChildArray $Group 'hooks' $kept.ToArray() }
    return $changed
}

function Sync-GroupCommand {
    param($Group, $Desired, [string]$BindingId, [string]$InstallRoot)
    $hooks = Get-ChildArray $Group 'hooks'
    $kept = New-Object System.Collections.Generic.List[object]
    $seen = $false
    $changed = $false
    foreach ($hook in $hooks) {
        if (Test-OwnedHookObject $hook $InstallRoot $BindingId) {
            if ($seen) { $changed = $true; continue }
            $seen = $true
            if (Test-SameHook $hook $Desired) { $kept.Add($hook) }
            else { $kept.Add($Desired); $changed = $true }
        }
        else {
            $kept.Add($hook)
        }
    }
    if (-not $seen) {
        $kept.Add($Desired)
        $changed = $true
    }
    if ($changed) { Set-ChildArray $Group 'hooks' $kept.ToArray() }
    return $changed
}

function Strip-BindingFromGroupedEvent {
    param($Hooks, [string]$EventName, [string]$BindingId, [string]$InstallRoot)
    if (-not (Test-ItemsAreObjects $Hooks $EventName)) { return $false }
    $groups = Get-ChildArray $Hooks $EventName
    if ($groups.Count -eq 0 -and -not (Test-HasProperty $Hooks $EventName)) { return $false }
    $kept = New-Object System.Collections.Generic.List[object]
    $changed = $false
    foreach ($group in $groups) {
        if ($group -isnot [pscustomobject]) {
            $kept.Add($group)
            continue
        }
        $stripped = Strip-BindingFromGroup $group $BindingId $InstallRoot
        if ($stripped) { $changed = $true }
        $remaining = (Get-ChildArray $group 'hooks').Count
        if (-not $stripped -or $remaining -gt 0) { $kept.Add($group) }
    }
    if (-not $changed) { return $false }
    if ($kept.Count -eq 0) { $Hooks.PSObject.Properties.Remove($EventName) }
    else { Set-ChildArray $Hooks $EventName $kept.ToArray() }
    return $true
}

function Ensure-GroupedRow {
    param($Hooks, [Binding]$Row, [string]$InstallRoot)
    $changed = $false
    $eventName = Resolve-PropertyName $Hooks $Row.EventName
    $desired = New-CommandHook -Binding $Row -InstallRoot $InstallRoot
    foreach ($name in @($Hooks.PSObject.Properties.Name)) {
        if ([string]::Compare($name, $eventName, [StringComparison]::OrdinalIgnoreCase) -eq 0) { continue }
        if (Strip-BindingFromGroupedEvent $Hooks $name $Row.Id $InstallRoot) { $changed = $true }
    }
    $groups = Get-ChildArray $Hooks $eventName
    $target = Find-TargetGroup $groups $Row $InstallRoot
    $kept = New-Object System.Collections.Generic.List[object]
    $placed = $false
    foreach ($group in $groups) {
        $isTarget = ($null -ne $target) -and [object]::ReferenceEquals($group, $target)
        if ($isTarget) {
            if (Sync-GroupCommand $group $desired $Row.Id $InstallRoot) { $changed = $true }
            $kept.Add($group)
            $placed = $true
            continue
        }
        if ($group -isnot [pscustomobject]) {
            $kept.Add($group)
            continue
        }
        $stripped = Strip-BindingFromGroup $group $Row.Id $InstallRoot
        if ($stripped) { $changed = $true }
        $remaining = (Get-ChildArray $group 'hooks').Count
        if (-not $stripped -or $remaining -gt 0) { $kept.Add($group) }
    }
    if (-not $placed) {
        $kept.Add((New-HookGroup -Matcher $Row.Matcher -Hook $desired))
        $changed = $true
    }
    if ($changed) { Set-ChildArray $Hooks $eventName $kept.ToArray() }
    return $changed
}

function Strip-CursorEvent {
    param($Hooks, [string]$EventName, [Binding[]]$Rows, [string]$InstallRoot)
    $items = Get-ChildArray $Hooks $EventName
    if ($items.Count -eq 0 -and -not (Test-HasProperty $Hooks $EventName)) { return $false }
    $kept = New-Object System.Collections.Generic.List[object]
    $changed = $false
    foreach ($item in $items) {
        $owned = $false
        if ($item -is [pscustomobject]) {
            foreach ($row in $Rows) {
                if (Test-OwnedHookObject $item $InstallRoot $row.Id) { $owned = $true; break }
            }
        }
        if ($owned) { $changed = $true; continue }
        $kept.Add($item)
    }
    if (-not $changed) { return $false }
    if ($kept.Count -eq 0) { $Hooks.PSObject.Properties.Remove($EventName) }
    else { Set-ChildArray $Hooks $EventName $kept.ToArray() }
    return $true
}

function Ensure-CursorRow {
    param($Hooks, [Binding]$Row, [string]$InstallRoot)
    $changed = $false
    $eventName = Resolve-PropertyName $Hooks $Row.EventName
    $desired = New-CommandHook -Binding $Row -InstallRoot $InstallRoot
    foreach ($name in @($Hooks.PSObject.Properties.Name)) {
        if ([string]::Compare($name, $eventName, [StringComparison]::OrdinalIgnoreCase) -eq 0) { continue }
        $only = New-Object Binding[] 1
        $only[0] = $Row
        if (Strip-CursorEvent $Hooks $name $only $InstallRoot) { $changed = $true }
    }
    $items = Get-ChildArray $Hooks $eventName
    $kept = New-Object System.Collections.Generic.List[object]
    $seen = $false
    foreach ($item in $items) {
        if ($item -is [pscustomobject] -and (Test-OwnedHookObject $item $InstallRoot $Row.Id)) {
            if ($seen) { $changed = $true; continue }
            $seen = $true
            if (Test-SameHook $item $desired) { $kept.Add($item) }
            else { $kept.Add($desired); $changed = $true }
        }
        else {
            $kept.Add($item)
        }
    }
    if (-not $seen) {
        $kept.Add($desired)
        $changed = $true
    }
    if ($changed) { Set-ChildArray $Hooks $eventName $kept.ToArray() }
    return $changed
}

function Update-GroupedDocument {
    param($Document, [Binding[]]$Rows, [SyncMode]$Mode, [string]$InstallRoot)
    $result = @{ Status = 'Ok'; Changed = $false }
    $hooksProp = $Document.PSObject.Properties['hooks']
    if ($hooksProp -and $null -ne $hooksProp.Value -and $hooksProp.Value -isnot [pscustomobject]) {
        $result.Status = 'Unreadable'
        return $result
    }
    if (-not $hooksProp -or $null -eq $hooksProp.Value) {
        if ($Mode -eq [SyncMode]::Remove) { return $result }
        $created = New-Object psobject
        Set-NoteProperty $Document 'hooks' $created
        $hooks = $created
        $result.Changed = $true
    }
    else {
        $hooks = $hooksProp.Value
    }

    if ($Mode -eq [SyncMode]::Remove) {
        foreach ($name in @($hooks.PSObject.Properties.Name)) {
            if (-not (Test-ItemsAreObjects $hooks $name)) { continue }
            if (Strip-BindingFromGroupedEventForRows $hooks $name $Rows $InstallRoot) {
                $result.Changed = $true
            }
        }
        return $result
    }

    foreach ($row in $Rows) {
        $eventName = Resolve-PropertyName $hooks $row.EventName
        if (-not (Test-ItemsAreObjects $hooks $eventName)) {
            $result.Status = 'Unreadable'
            return $result
        }
    }
    foreach ($row in $Rows) {
        if (Ensure-GroupedRow $hooks $row $InstallRoot) { $result.Changed = $true }
    }
    return $result
}

function Strip-BindingFromGroupedEventForRows {
    param($Hooks, [string]$EventName, [Binding[]]$Rows, [string]$InstallRoot)
    $changed = $false
    foreach ($row in $Rows) {
        if (Strip-BindingFromGroupedEvent $Hooks $EventName $row.Id $InstallRoot) { $changed = $true }
    }
    return $changed
}

function Update-CursorDocument {
    param($Document, [Binding[]]$Rows, [SyncMode]$Mode, [string]$InstallRoot)
    $result = @{ Status = 'Ok'; Changed = $false }
    $hooksProp = $Document.PSObject.Properties['hooks']
    if ($hooksProp -and $null -ne $hooksProp.Value -and $hooksProp.Value -isnot [pscustomobject]) {
        $result.Status = 'Unreadable'
        return $result
    }
    if (-not $hooksProp -or $null -eq $hooksProp.Value) {
        if ($Mode -eq [SyncMode]::Remove) { return $result }
        $created = New-Object psobject
        Set-NoteProperty $Document 'hooks' $created
        $hooks = $created
        $result.Changed = $true
    }
    else {
        $hooks = $hooksProp.Value
    }

    if ($Mode -eq [SyncMode]::Remove) {
        foreach ($name in @($hooks.PSObject.Properties.Name)) {
            if (-not (Test-ItemsAreObjects $hooks $name)) { continue }
            if (Strip-CursorEvent $hooks $name $Rows $InstallRoot) { $result.Changed = $true }
        }
        return $result
    }

    foreach ($row in $Rows) {
        $eventName = Resolve-PropertyName $hooks $row.EventName
        if (-not (Test-ItemsAreObjects $hooks $eventName)) {
            $result.Status = 'Unreadable'
            return $result
        }
        if (Ensure-CursorRow $hooks $row $InstallRoot) { $result.Changed = $true }
    }
    return $result
}

function Write-JsonDocument {
    param(
        [string]$Path,
        $Document,
        [bool]$Existed
    )
    $json = ConvertTo-JsonPreserveArrays $Document
    if (-not $json.EndsWith("`n")) { $json += "`n" }
    $encoding = New-Object System.Text.UTF8Encoding $false
    $bytes = $encoding.GetBytes($json)
    $backup = ''
    $outcome = [FileOutcome]::Created
    if ($Existed) {
        $backup = Backup-UserFile $Path
        $outcome = [FileOutcome]::Updated
    }
    Write-FileReplacing -Path $Path -Bytes $bytes
    return New-FileChange -Path $Path -Outcome $outcome -BackupPath $backup
}

function Update-JsonConfig {
    param(
        [string]$Path,
        [Binding[]]$Rows,
        [SyncMode]$Mode,
        [string]$InstallRoot,
        [bool]$Exists,
        [HookFileKind]$Kind
    )
    $document = $null
    if ($Exists) {
        $read = Read-Utf8Document $Path
        if ($null -eq $read) {
            return New-FileChange -Path $Path -Outcome ([FileOutcome]::Conflict) -Conflict ([ConflictKind]::UnreadableConfig)
        }
        try {
            $document = ConvertFrom-HookJson $read.Text
        }
        catch {
            return New-FileChange -Path $Path -Outcome ([FileOutcome]::Conflict) -Conflict ([ConflictKind]::UnreadableConfig)
        }
        if ($document -isnot [pscustomobject]) {
            return New-FileChange -Path $Path -Outcome ([FileOutcome]::Conflict) -Conflict ([ConflictKind]::UnreadableConfig)
        }
    }
    else {
        $document = New-Object psobject
    }

    if ($Kind -eq [HookFileKind]::CursorHooks -and (Test-HasProperty $document 'version')) {
        if (-not (Test-CursorVersionOne $document.version)) {
            return New-FileChange -Path $Path -Outcome ([FileOutcome]::Conflict) -Conflict ([ConflictKind]::UnsupportedCursorHooksVersion)
        }
    }

    $changed = $false
    if ($Kind -eq [HookFileKind]::CursorHooks -and $Mode -eq [SyncMode]::Apply -and -not (Test-HasProperty $document 'version')) {
        Set-NoteProperty $document 'version' ([int]1)
        $changed = $true
    }

    if ($Kind -eq [HookFileKind]::CursorHooks) {
        $edited = Update-CursorDocument -Document $document -Rows $Rows -Mode $Mode -InstallRoot $InstallRoot
    }
    else {
        $edited = Update-GroupedDocument -Document $document -Rows $Rows -Mode $Mode -InstallRoot $InstallRoot
    }
    if ($edited.Status -eq 'Unreadable') {
        return New-FileChange -Path $Path -Outcome ([FileOutcome]::Conflict) -Conflict ([ConflictKind]::UnreadableConfig)
    }
    if ($edited.Changed) { $changed = $true }
    if (-not $changed) {
        return New-FileChange -Path $Path -Outcome ([FileOutcome]::Unchanged)
    }
    return Write-JsonDocument -Path $Path -Document $document -Existed $Exists
}

function ConvertTo-TomlBasicString {
    param([string]$Value)
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    foreach ($char in $Value.ToCharArray()) {
        if ($char -eq '\') { [void]$builder.Append('\\') }
        elseif ($char -eq '"') { [void]$builder.Append('\"') }
        elseif ($char -eq "`n") { [void]$builder.Append('\n') }
        elseif ($char -eq "`r") { [void]$builder.Append('\r') }
        elseif ($char -eq "`t") { [void]$builder.Append('\t') }
        else { [void]$builder.Append($char) }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Format-TomlNotifyAssignment {
    param([string[]]$ArgumentList)
    $items = New-Object System.Collections.Generic.List[string]
    foreach ($arg in $ArgumentList) {
        $items.Add((ConvertTo-TomlBasicString ([string]$arg)))
    }
    return 'notify = [' + ($items -join ', ') + ']'
}

function Skip-LineEnd {
    param([string]$Text, [int]$Index)
    $length = $Text.Length
    if ($Index -ge $length) { return $length }
    if ($Text[$Index] -eq "`r") {
        $Index++
        if ($Index -lt $length -and $Text[$Index] -eq "`n") { $Index++ }
        return $Index
    }
    if ($Text[$Index] -eq "`n") { return $Index + 1 }
    return $Index
}

function Skip-ToNextLine {
    param([string]$Text, [int]$Index)
    $length = $Text.Length
    while ($Index -lt $length -and $Text[$Index] -ne "`n" -and $Text[$Index] -ne "`r") { $Index++ }
    return Skip-LineEnd $Text $Index
}

function Skip-TomlQuoted {
    param([string]$Text, [int]$Index)
    $quote = $Text[$Index]
    if (($Index + 2) -lt $Text.Length -and $Text[$Index + 1] -eq $quote -and $Text[$Index + 2] -eq $quote) {
        $marker = [string]$quote + [string]$quote + [string]$quote
        $close = $Text.IndexOf($marker, $Index + 3)
        if ($close -lt 0) { return $Text.Length }
        return $close + 3
    }
    $Index++
    while ($Index -lt $Text.Length) {
        $char = $Text[$Index]
        if ($quote -eq '"' -and $char -eq '\') {
            $Index += 2
            continue
        }
        if ($char -eq $quote) { return $Index + 1 }
        $Index++
    }
    return $Text.Length
}

function Skip-TomlBracket {
    param([string]$Text, [int]$Index, [char]$Open, [char]$Close)
    $depth = 0
    while ($Index -lt $Text.Length) {
        $char = $Text[$Index]
        if ($char -eq '"' -or $char -eq "'") {
            $Index = Skip-TomlQuoted $Text $Index
            continue
        }
        if ($char -eq '#') {
            $Index = Skip-ToNextLine $Text $Index
            continue
        }
        if ($char -eq $Open) { $depth++; $Index++; continue }
        if ($char -eq $Close) {
            $depth--
            $Index++
            if ($depth -eq 0) { return $Index }
            continue
        }
        $Index++
    }
    return $Text.Length
}

function Get-TomlValueEnd {
    param([string]$Text, [int]$Index)
    $length = $Text.Length
    while ($Index -lt $length -and ($Text[$Index] -eq ' ' -or $Text[$Index] -eq "`t" -or $Text[$Index] -eq "`r" -or $Text[$Index] -eq "`n")) {
        $Index++
    }
    if ($Index -ge $length) { return $Index }
    $char = $Text[$Index]
    if ($char -eq '[') { return Skip-TomlBracket $Text $Index '[' ']' }
    if ($char -eq '{') { return Skip-TomlBracket $Text $Index '{' '}' }
    if ($char -eq '"' -or $char -eq "'") { return Skip-TomlQuoted $Text $Index }
    while ($Index -lt $length -and $Text[$Index] -ne "`n" -and $Text[$Index] -ne "`r" -and $Text[$Index] -ne '#') { $Index++ }
    return $Index
}

function Skip-TomlLine {
    param([string]$Text, [int]$Index)
    while ($Index -lt $Text.Length) {
        $char = $Text[$Index]
        if ($char -eq "`n" -or $char -eq "`r") { return Skip-LineEnd $Text $Index }
        if ($char -eq '"' -or $char -eq "'") {
            $Index = Skip-TomlQuoted $Text $Index
            continue
        }
        if ($char -eq '#') { return Skip-ToNextLine $Text $Index }
        $Index++
    }
    return $Text.Length
}

function Test-NotifyKeyAt {
    param([string]$Text, [int]$Index)
    $length = $Text.Length
    $after = -1
    if (($Index + 6) -le $length -and $Text.Substring($Index, 6) -eq 'notify') { $after = $Index + 6 }
    elseif (($Index + 8) -le $length -and ($Text.Substring($Index, 8) -eq '"notify"' -or $Text.Substring($Index, 8) -eq "'notify'")) { $after = $Index + 8 }
    else { return -1 }
    while ($after -lt $length -and ($Text[$after] -eq ' ' -or $Text[$after] -eq "`t")) { $after++ }
    if ($after -ge $length -or $Text[$after] -ne '=') { return -1 }
    return $after + 1
}

function Find-RootNotifySpan {
    param([string]$Text)
    $length = $Text.Length
    $index = 0
    $inTable = $false
    while ($index -lt $length) {
        $cursor = $index
        while ($cursor -lt $length -and ($Text[$cursor] -eq ' ' -or $Text[$cursor] -eq "`t")) { $cursor++ }
        if ($cursor -ge $length) { break }
        if ($Text[$cursor] -eq '#') {
            $index = Skip-ToNextLine $Text $cursor
            continue
        }
        if ($Text[$cursor] -eq '[') {
            $inTable = $true
            $index = Skip-ToNextLine $Text $cursor
            continue
        }
        if (-not $inTable) {
            $valueAt = Test-NotifyKeyAt $Text $cursor
            if ($valueAt -ge 0) {
                $end = Get-TomlValueEnd $Text $valueAt
                return @{ Start = $index; ValueStart = $valueAt; End = $end }
            }
        }
        $index = Skip-TomlLine $Text $cursor
    }
    return $null
}

function Find-FirstTableIndex {
    param([string]$Text)
    $length = $Text.Length
    $index = 0
    while ($index -lt $length) {
        $cursor = $index
        while ($cursor -lt $length -and ($Text[$cursor] -eq ' ' -or $Text[$cursor] -eq "`t")) { $cursor++ }
        if ($cursor -ge $length) { return -1 }
        if ($Text[$cursor] -eq '#') {
            $index = Skip-ToNextLine $Text $cursor
            continue
        }
        if ($Text[$cursor] -eq '[') { return $index }
        $index = Skip-TomlLine $Text $cursor
    }
    return -1
}

function Read-TomlStringValue {
    param([string]$Text, [int]$Index)
    $quote = $Text[$Index]
    if ($quote -eq "'") {
        if (($Index + 2) -lt $Text.Length -and $Text[$Index + 1] -eq "'" -and $Text[$Index + 2] -eq "'") { return $null }
        $end = $Text.IndexOf("'", $Index + 1)
        if ($end -lt 0) { return $null }
        return @{ Value = $Text.Substring($Index + 1, $end - $Index - 1); Next = $end + 1 }
    }
    if (($Index + 2) -lt $Text.Length -and $Text[$Index + 1] -eq '"' -and $Text[$Index + 2] -eq '"') { return $null }
    $builder = New-Object System.Text.StringBuilder
    $cursor = $Index + 1
    while ($cursor -lt $Text.Length) {
        $char = $Text[$cursor]
        if ($char -eq '\') {
            if (($cursor + 1) -ge $Text.Length) { return $null }
            $escaped = $Text[$cursor + 1]
            if ($escaped -eq '\') { [void]$builder.Append('\') }
            elseif ($escaped -eq '"') { [void]$builder.Append('"') }
            elseif ($escaped -eq 'n') { [void]$builder.Append("`n") }
            elseif ($escaped -eq 'r') { [void]$builder.Append("`r") }
            elseif ($escaped -eq 't') { [void]$builder.Append("`t") }
            else { return $null }
            $cursor += 2
            continue
        }
        if ($char -eq '"') {
            return @{ Value = $builder.ToString(); Next = $cursor + 1 }
        }
        [void]$builder.Append($char)
        $cursor++
    }
    return $null
}

function ConvertFrom-TomlStringArray {
    param([string]$ValueText)
    $text = $ValueText.Trim()
    if (-not $text.StartsWith('[')) { return $null }
    $index = 1
    $items = New-Object System.Collections.Generic.List[string]
    while ($index -lt $text.Length) {
        while ($index -lt $text.Length -and ($text[$index] -eq ' ' -or $text[$index] -eq "`t" -or $text[$index] -eq "`r" -or $text[$index] -eq "`n" -or $text[$index] -eq ',')) {
            $index++
        }
        if ($index -ge $text.Length) { return $null }
        if ($text[$index] -eq ']') { return ,$items.ToArray() }
        if ($text[$index] -eq '#') {
            while ($index -lt $text.Length -and $text[$index] -ne "`n" -and $text[$index] -ne "`r") { $index++ }
            continue
        }
        if ($text[$index] -ne '"' -and $text[$index] -ne "'") { return $null }
        $parsed = Read-TomlStringValue $text $index
        if ($null -eq $parsed) { return $null }
        $items.Add([string]$parsed.Value)
        $index = [int]$parsed.Next
    }
    return $null
}

function Test-SameStringList {
    param($Left, $Right)
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    if ($Left.Count -ne $Right.Count) { return $false }
    for ($i = 0; $i -lt $Left.Count; $i++) {
        if ([string]::CompareOrdinal([string]$Left[$i], [string]$Right[$i]) -ne 0) { return $false }
    }
    return $true
}

function Test-OwnedArgumentList {
    param([string[]]$ArgumentList, [string]$InstallRoot, [string]$BindingId)
    $invokePath = Join-Path $InstallRoot 'invoke.ps1'
    $sawInvoke = $false
    $sawId = $false
    for ($i = 0; $i -lt $ArgumentList.Count; $i++) {
        if ([string]::CompareOrdinal([string]$ArgumentList[$i], $invokePath) -eq 0) { $sawInvoke = $true }
        if ([string]::CompareOrdinal([string]$ArgumentList[$i], '-BindingId') -eq 0 -and ($i + 1) -lt $ArgumentList.Count) {
            if ([string]::CompareOrdinal([string]$ArgumentList[$i + 1], $BindingId) -eq 0) { $sawId = $true }
        }
    }
    return ($sawInvoke -and $sawId)
}

function Get-TomlNewline {
    param([string]$Text)
    if ($Text.Contains("`r`n")) { return "`r`n" }
    return "`n"
}

function Insert-RootNotify {
    param([string]$Text, [string[]]$ArgumentList)
    $newline = Get-TomlNewline $Text
    $line = (Format-TomlNotifyAssignment $ArgumentList) + $newline
    $tableAt = Find-FirstTableIndex $Text
    if ($tableAt -ge 0) { return $Text.Insert($tableAt, $line) }
    if ($Text.Length -gt 0 -and -not ($Text.EndsWith("`n") -or $Text.EndsWith("`r"))) {
        return $Text + $newline + $line
    }
    return $Text + $line
}

function Write-TomlText {
    param($Path, $Read, [string]$Updated)
    if ([string]::CompareOrdinal($Updated, [string]$Read.Text) -eq 0) {
        return New-FileChange -Path $Path -Outcome ([FileOutcome]::Unchanged)
    }
    $backup = Backup-UserFile $Path
    $encoding = New-Object System.Text.UTF8Encoding ([bool]$Read.Bom)
    $bytes = $encoding.GetBytes($Updated)
    Write-FileReplacing -Path $Path -Bytes $bytes
    return New-FileChange -Path $Path -Outcome ([FileOutcome]::Updated) -BackupPath $backup
}

function Update-CodexToml {
    param(
        [string]$Path,
        [Binding]$Row,
        [SyncMode]$Mode,
        [string]$InstallRoot,
        [bool]$Exists
    )
    $argv = Get-HookArgumentList -Binding $Row -InstallRoot $InstallRoot
    if (-not $Exists) {
        if ($Mode -eq [SyncMode]::Remove) {
            return New-FileChange -Path $Path -Outcome ([FileOutcome]::Unchanged)
        }
        $text = (Format-TomlNotifyAssignment $argv) + "`n"
        $encoding = New-Object System.Text.UTF8Encoding $false
        Write-FileReplacing -Path $Path -Bytes ($encoding.GetBytes($text))
        return New-FileChange -Path $Path -Outcome ([FileOutcome]::Created)
    }

    $read = Read-Utf8Document $Path
    if ($null -eq $read) {
        return New-FileChange -Path $Path -Outcome ([FileOutcome]::Conflict) -Conflict ([ConflictKind]::UnreadableConfig)
    }
    $span = Find-RootNotifySpan $read.Text
    if ($null -eq $span) {
        if ($Mode -eq [SyncMode]::Remove) {
            return New-FileChange -Path $Path -Outcome ([FileOutcome]::Unchanged)
        }
        return Write-TomlText $Path $read (Insert-RootNotify $read.Text $argv)
    }

    $rawValue = $read.Text.Substring([int]$span.ValueStart, [int]$span.End - [int]$span.ValueStart)
    $parsed = ConvertFrom-TomlStringArray $rawValue
    $same = $false
    $owned = $false
    if ($null -ne $parsed) {
        $same = Test-SameStringList $parsed $argv
        $owned = Test-OwnedArgumentList -ArgumentList $parsed -InstallRoot $InstallRoot -BindingId $Row.Id
    }

    if ($Mode -eq [SyncMode]::Remove) {
        if (-not $owned -and -not $same) {
            return New-FileChange -Path $Path -Outcome ([FileOutcome]::Unchanged)
        }
        $updated = $read.Text.Remove([int]$span.Start, [int]$span.End - [int]$span.Start)
        return Write-TomlText $Path $read $updated
    }

    if ($same) {
        return New-FileChange -Path $Path -Outcome ([FileOutcome]::Unchanged)
    }
    return New-FileChange -Path $Path -Outcome ([FileOutcome]::Conflict) -Conflict ([ConflictKind]::ForeignCodexNotify)
}

function Register-AgentDoneToastType {
    param([string]$Name, [type]$Type)
    # Import-Module does not publish module classes. install.ps1 names FileOutcome after import.
    $accelerators = [psobject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
    if ($null -eq $accelerators) { return }
    $flags = [System.Reflection.BindingFlags]'Public,Static'
    $map = $accelerators.GetProperty('Get', $flags).GetValue($null)
    if ($map.ContainsKey($Name)) { return }
    $null = $accelerators.GetMethod('Add', $flags).Invoke($null, @($Name, $Type))
}

if ($MyInvocation.MyCommand.Name -like '*.psm1') {
    Register-AgentDoneToastType 'AgentKind' ([AgentKind])
    Register-AgentDoneToastType 'ToastReason' ([ToastReason])
    Register-AgentDoneToastType 'QuietWhen' ([QuietWhen])
    Register-AgentDoneToastType 'HookFileKind' ([HookFileKind])
    Register-AgentDoneToastType 'SyncMode' ([SyncMode])
    Register-AgentDoneToastType 'FileOutcome' ([FileOutcome])
    Register-AgentDoneToastType 'ConflictKind' ([ConflictKind])
    Register-AgentDoneToastType 'QuietReason' ([QuietReason])
    Register-AgentDoneToastType 'ToastRequest' ([ToastRequest])
    Register-AgentDoneToastType 'ToastNote' ([ToastNote])
    Register-AgentDoneToastType 'ShowToast' ([ShowToast])
    Register-AgentDoneToastType 'StayQuiet' ([StayQuiet])
    Register-AgentDoneToastType 'FileChange' ([FileChange])
    Register-AgentDoneToastType 'InstallReport' ([InstallReport])
    Export-ModuleMember -Function Sync-AgentDoneToast, Invoke-AgentDoneToast
}
