; Open Vanilla player installer (Inno Setup 6). Built by .github/workflows/release.yml:
;   ISCC /DAppVersion=1.17.0 /DSourceDir=..\..\release\OpenVanilla_1.17.0_Win64 /DOutputDir=..\..\dist OpenVanilla.iss
; SourceDir is the folder packaging\build_repack.py makes (layout 2, docs/LAUNCHER.md):
;   OpenVanilla.exe (the launcher, the only thing players run; its identical twin OpenWoW.exe stays for
;   launchers from before the rename, whose updater only knows that name), app\ (its internals, shipped addons and
;   defaults), Game\Open Vanilla Game.exe (the engine), Server\ (the realm website for the dedicated
;   server), links.txt, README.txt, LICENSES\.
; Per-user install in %LOCALAPPDATA%\Programs\OpenVanilla (no admin prompt; an upgrade keeps the folder an
; older Open Vanilla install used, since the AppId is unchanged). Player data (AddOns, Realms,
; Screenshots, Logs, Backups, Settings) lives in %LOCALAPPDATA%\OpenVanilla (or an existing %LOCALAPPDATA%\OpenWoW), which the launcher makes on
; first run, so updates and reinstalls never touch it. The player's WoW 1.12.1 data stays theirs.
;
; Self-update: the launcher downloads the next OpenVanilla-Setup-<v>.exe in the background, checks it
; against the signed version.json, and on "Update ready" runs it with
;   /VERYSILENT /SUPPRESSMSGBOXES /CLOSEAPPLICATIONS /NORESTART /RELAUNCH
; /RELAUNCH (ours) starts OpenVanilla.exe again when the silent install is done.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\release\OpenVanilla_" + AppVersion + "_Win64"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif
#define LauncherExe "OpenVanilla.exe"

[Setup]
AppId={{7B1E4C2A-5D3F-4E8B-9A61-0F2C8D4E7A15}
AppName=Open Vanilla
AppVersion={#AppVersion}
AppVerName=Open Vanilla {#AppVersion}
AppPublisher=Open Vanilla
AppPublisherURL=https://openvanilla.app
AppSupportURL=https://openvanilla.app
AppUpdatesURL=https://openvanilla.app
DefaultDirName={localappdata}\Programs\OpenVanilla
DefaultGroupName=Open Vanilla
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=OpenVanilla-Setup-{#AppVersion}
#ifdef IconFile
SetupIconFile={#IconFile}
#endif
UninstallDisplayIcon={app}\{#LauncherExe}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
ChangesAssociations=yes

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"

[InstallDelete]
; Before layout 2 the launcher was "OpenWoW Launcher.exe" (+ _internal\) and OpenWoW.exe was the engine
; (later Game\OpenWoW Game.exe, now Game\Open Vanilla Game.exe). The launcher moves the
; player's own files (benilla-config, solo, host, settings) on its first run; only program files go here.
Type: files; Name: "{app}\OpenWoW Launcher.exe"
; shortcuts from before the Open Vanilla rename (the new ones are made below)
Type: files; Name: "{group}\OpenWoW.lnk"
Type: files; Name: "{group}\OpenWoW folder (addons, realms, screenshots).lnk"
Type: files; Name: "{group}\Uninstall OpenWoW.lnk"
Type: files; Name: "{autodesktop}\OpenWoW.lnk"
Type: filesandordirs; Name: "{app}\_internal"
Type: files; Name: "{app}\launcher\defaults.json"
Type: files; Name: "{app}\launcher\version.json"
Type: files; Name: "{app}\launcher\patch_notes.json"
Type: files; Name: "{app}\launcher\links.txt"
; app\ is replaced whole so no stale module from an older launcher lingers
Type: filesandordirs; Name: "{app}\app"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Excludes: "links.txt"; Flags: ignoreversion recursesubdirs createallsubdirs
; links.txt holds the player's own overrides: installed once, never overwritten
Source: "{#SourceDir}\links.txt"; DestDir: "{app}"; Flags: onlyifdoesntexist skipifsourcedoesntexist

[Icons]
Name: "{group}\Open Vanilla"; Filename: "{app}\{#LauncherExe}"
Name: "{group}\Open Vanilla folder (addons, realms, screenshots)"; Filename: "{code:DataDir}"
Name: "{group}\Uninstall Open Vanilla"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Open Vanilla"; Filename: "{app}\{#LauncherExe}"; Tasks: desktopicon

[Registry]
; openvanilla://join/... (friends' invites) and openvanilla://workshop/install/... (the site's Install buttons)
Root: HKCU; Subkey: "Software\Classes\openvanilla"; ValueType: string; ValueName: ""; ValueData: "URL:Open Vanilla"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\openvanilla"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\openvanilla\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\{#LauncherExe}"",0"
Root: HKCU; Subkey: "Software\Classes\openvanilla\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#LauncherExe}"" ""%1"""

[Run]
Filename: "{app}\{#LauncherExe}"; Description: "Start Open Vanilla"; Flags: nowait postinstall skipifsilent
; a silent self-update started by the launcher: start it again once the files are in place
Filename: "{app}\{#LauncherExe}"; Parameters: "--updated"; Flags: nowait; Check: ShouldRelaunch

[UninstallDelete]
Type: filesandordirs; Name: "{app}\app"
Type: dirifempty; Name: "{app}\Game"

[Code]
// The player-data folder: %LOCALAPPDATA%\OpenVanilla, or an existing %LOCALAPPDATA%\OpenWoW from before
// the rename (the launcher keeps using that one; launcher/layout.py installed_data_dir()).
function DataDir(Param: String): String;
begin
  Result := ExpandConstant('{localappdata}\OpenVanilla');
  if (not DirExists(Result)) and DirExists(ExpandConstant('{localappdata}\OpenWoW')) then
    Result := ExpandConstant('{localappdata}\OpenWoW');
end;

function ShouldRelaunch(): Boolean;
var
  I: Integer;
begin
  Result := False;
  if not WizardSilent() then
    Exit;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), '/RELAUNCH') = 0 then
      Result := True;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Data: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    Data := DataDir('');
    if DirExists(Data) and not UninstallSilent() then
      if MsgBox('Also remove your Open Vanilla data in ' + Data + '?' + #13#10 + #13#10 +
                'That is your addons, Play Solo and hosted realms (characters included), screenshots, ' +
                'logs, backups and settings.' + #13#10 + '(Choose No to keep them for a later reinstall.)',
                mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
        DelTree(Data, True, True, True);
    if DirExists(ExpandConstant('{app}')) and not UninstallSilent() then
      if MsgBox('Also remove the engine''s saved settings in ' + ExpandConstant('{app}\Game') + '?',
                mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
        DelTree(ExpandConstant('{app}'), True, True, True);
  end;
end;
