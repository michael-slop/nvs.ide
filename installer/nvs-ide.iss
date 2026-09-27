; nvs.ide Windows installer (Inno Setup 6). Built by scripts\package.ps1, which stages
; dist\nvs.ide\ and runs:
;   ISCC /DAppVersion=x.y.z /DSourceDir=<staged folder> [/DBundled=1] /O<dist> installer\nvs-ide.iss
; Per-user, no admin: {userpf} is %LOCALAPPDATA%\Programs. The uninstaller removes what
; was installed, the Start-menu folder and the PATH entry, plus the whole {app}\runtime
; folder: the first start links Neovim's config folder to it, so LazyVim writes
; lazyvim.json (and lazy-lock.json, and the Settings screen lua\nvs\settings.lua) in
; there, and a plain uninstall would leave the folder behind with those files in it. It
; never touches the data folder (%LOCALAPPDATA%\nvs-ide-data: plugins, models,
; nvs-settings.json, which is the source the generated settings.lua is written from).

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\dist\nvs.ide"
#endif

[Setup]
AppId={{7F3B9A6E-2C41-4D8B-9E1F-5A6C0B2D8E47}
AppName=nvs.ide
AppVersion={#AppVersion}
AppVerName=nvs.ide {#AppVersion}
AppPublisher=nvs.ide
AppPublisherURL=https://github.com/michael-slop/nvs.ide
AppSupportURL=https://github.com/michael-slop/nvs.ide/issues
AppUpdatesURL=https://github.com/michael-slop/nvs.ide/releases
DefaultDirName={userpf}\nvs.ide
DefaultGroupName=nvs.ide
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputBaseFilename=nvs.ide-{#AppVersion}-setup
SetupIconFile=..\assets\nvs.ide.ico
UninstallDisplayIcon={app}\nvs-ide.exe
UninstallDisplayName=nvs.ide
LicenseFile={#SourceDir}\LICENSE
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
; The PATH task writes HKCU\Environment; this makes Explorer reload it so new terminals see nvs.
ChangesEnvironment=yes
WizardStyle=modern

[Tasks]
Name: "addtopath"; Description: "Add nvs to PATH (type ""nvs"" in any terminal to open the current folder)"; GroupDescription: "Command line:"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
; No IconFilename: the shortcut takes the exe's own icon (the necronomicon resource).
Name: "{group}\nvs.ide"; Filename: "{app}\nvs-ide.exe"; WorkingDir: "{%USERPROFILE}"; Comment: "LazyVim with training wheels"

[Run]
Filename: "{app}\nvs-ide.exe"; Description: "Start nvs.ide"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; The runtime folder is entirely the app's; see the header for what gets written into it
; after the install. Only this subfolder, never {app} itself or anything beside it.
Type: filesandordirs; Name: "{app}\runtime"
; Written by [Code] when this install put {app} on the user PATH (see PathMarker).
Type: files; Name: "{app}\added-to-path"

[Code]
var
  PrereqPage: TOutputMsgMemoWizardPage;
  MissingCount: Integer;

{ The first of the semicolon-separated exe names found on PATH, or '' when none is. }
function FirstOnPath(Names: String): String;
var
  Name: String;
  P: Integer;
begin
  Result := '';
  while (Names <> '') and (Result = '') do
  begin
    P := Pos(';', Names);
    if P = 0 then
    begin
      Name := Names;
      Names := '';
    end else
    begin
      Name := Copy(Names, 1, P - 1);
      Delete(Names, 1, P);
    end;
    Result := FileSearch(Name, GetEnv('PATH'));
  end;
end;

{ One line of the tools page; a missing tool is counted so the page can be skipped when all are there. }
function ToolLine(Names, Caption, Install: String): String;
var
  Found: String;
begin
  Found := FirstOnPath(Names);
  if Found <> '' then
    Result := '   found    ' + Caption + '   (' + Found + ')'
  else
  begin
    Result := '   MISSING  ' + Caption + '   ->  ' + Install;
    MissingCount := MissingCount + 1;
  end;
  Result := Result + #13#10;
end;

procedure InitializeWizard;
var
  Msg: String;
begin
  MissingCount := 0;
  Msg := 'nvs.ide runs Neovim with LazyVim, which needs a few tools of its own. On your PATH right now:' + #13#10#13#10;
  Msg := Msg + ToolLine('git.exe', 'git (plugins are cloned with it)', 'winget install Git.Git');
  Msg := Msg + ToolLine('gcc.exe;clang.exe;cl.exe;zig.exe', 'a C compiler (syntax parsers are compiled)', 'winget install BrechtSanders.WinLibs.POSIX.UCRT');
  Msg := Msg + ToolLine('tree-sitter.exe', 'tree-sitter CLI (syntax parsers)', 'winget install tree-sitter.tree-sitter-cli');
#ifndef Bundled
  Msg := Msg + ToolLine('nvim.exe', 'Neovim 0.11 or newer', 'winget install Neovim.Neovim');
  Msg := Msg + ToolLine('rg.exe', 'ripgrep (the Search view)', 'winget install BurntSushi.ripgrep.MSVC');
#endif
  Msg := Msg + #13#10 + 'Optional: fd (winget install sharkdp.fd) for faster file pickers, Node.js (winget install OpenJS.NodeJS.LTS) for VS Code extensions, llama.cpp (winget install ggml.llamacpp) for local AI.' + #13#10#13#10;
  Msg := Msg + 'Run the winget lines for the missing ones in a terminal, before or after this setup. Inside the editor, :checkhealth nvs shows the same list.';
  PrereqPage := CreateOutputMsgMemoPage(wpSelectTasks, 'Tools nvs.ide needs', 'Some of them are not on this computer yet', 'Nothing here stops the installation.', Msg);
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  { The tools page only earns its click when something is missing. }
  Result := (PageID = PrereqPage.ID) and (MissingCount = 0);
end;

{ Whole-entry, case-insensitive membership test on a PATH-shaped string. }
function PathHas(Path, Dir: String): Boolean;
begin
  Result := Pos(';' + Uppercase(Dir) + ';', ';' + Uppercase(Path) + ';') > 0;
end;

{ The file that says this install put the install folder on the user PATH. Without it
  the uninstaller leaves the PATH alone: an entry the person had before installing is
  theirs. (No braces in this comment: a closing brace would end it early.) }
function PathMarker(): String;
begin
  Result := ExpandConstant('{app}\added-to-path');
end;

procedure AddToUserPath(Dir: String);
var
  Path: String;
begin
  if not RegQueryStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', Path) then
    Path := '';
  if PathHas(Path, Dir) then
  begin
    Log(Dir + ' is already on the user PATH; left as it is');
    exit;
  end;
  { Add one entry and keep the person's own trailing separator when there is one, so that
    RemoveFromUserPath, which takes the entry and ONE separator, gives back the original
    byte for byte: 'A;B' -> 'A;B;Dir' -> 'A;B' and 'A;B;' -> 'A;B;Dir;' -> 'A;B;'.
    (Appending only Dir to 'A;B;' would come back as 'A;B', one separator short.) }
  if Path = '' then
    Path := Dir
  else if Path[Length(Path)] = ';' then
    Path := Path + Dir + ';'
  else
    Path := Path + ';' + Dir;
  { Written as REG_EXPAND_SZ, the type Windows itself uses for Path. Pascal Script cannot
    read a value's type, so a Path that was REG_SZ comes back REG_EXPAND_SZ; its text and
    its %VARS% are kept as they are (RegQueryStringValue does not expand them). }
  if RegWriteExpandStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', Path) then
  begin
    Log('added ' + Dir + ' to the user PATH');
    SaveStringToFile(PathMarker(), Dir, False);
  end
  else
    Log('could not write the user PATH');
end;

procedure RemoveFromUserPath(Dir: String);
var
  Path: String;
  P: Integer;
begin
  if not RegQueryStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', Path) then
    exit;
  P := Pos(';' + Uppercase(Dir) + ';', ';' + Uppercase(Path) + ';');
  if P = 0 then
    exit;
  { P counts from the padded string, so in Path the entry starts at P - 1, or at 1 when it
    is the first entry. Take the entry and one separator. }
  if P = 1 then
    Delete(Path, 1, Length(Dir) + 1)
  else
    Delete(Path, P - 1, Length(Dir) + 1);
  if RegWriteExpandStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', Path) then
    Log('removed ' + Dir + ' from the user PATH');
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and WizardIsTaskSelected('addtopath') then
    AddToUserPath(ExpandConstant('{app}'));
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Link: String;
  ResultCode: Integer;
begin
  { usUninstall comes before any file is deleted, so the marker is still there to read. }
  if CurUninstallStep = usUninstall then
  begin
    if FileExists(PathMarker()) then
      RemoveFromUserPath(ExpandConstant('{app}'))
    else
      Log('this install did not add itself to the user PATH; leaving it alone');
    exit;
  end;
  if CurUninstallStep <> usPostUninstall then
    exit;
  { The first start linked the app's config folder to runtime\ inside the install folder,
    which is gone now. rmdir without /s removes a junction or an empty folder and refuses a
    real folder with files in it, so a config of the person's own stays. The data folder is
    never touched. (No braces in this comment: a brace would end it early.) }
  Link := ExpandConstant('{localappdata}\nvs-ide');
  if DirExists(Link) and not FileExists(Link + '\init.lua') then
  begin
    if Exec(ExpandConstant('{cmd}'), '/C rmdir "' + Link + '"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
      Log('removed the config link ' + Link + ' (exit code ' + IntToStr(ResultCode) + ')');
  end;
end;
