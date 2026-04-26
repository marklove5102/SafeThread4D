// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Eduardo P. Araujo
// https://github.com/eduardoparaujo/SafeThread4D

{*
  Unit   : SafeThread.FileOps.Demo.Main
  Purpose: File and folder copy demo for SafeThread4D, including single-thread
           copy flows and a fan-out folder copy example.

  Part of the SafeThread4D examples.

  Author        : Eduardo P. Araujo
  Created       : 2026-04-26
  Last modified : 2026-04-26
  Version       : 1.0.0

  Notes:
    - This unit is an example form, not part of the runtime library.
    - Shutdown draining uses CheckSynchronize as a bounded host-app close policy.
    - The fan-out example focuses on cooperative cancellation and progress
      aggregation across multiple workers.
*}

unit SafeThread.FileOps.Demo.Main;

interface

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  Winapi.ShlObj,
  Winapi.ActiveX,
  {$ENDIF}

  FMX.Controls,
  FMX.Controls.Presentation,
  FMX.Edit,
  FMX.Forms,
  FMX.Memo,
  FMX.Memo.Types,
  FMX.Objects,
  FMX.ScrollBox,
  FMX.StdCtrls,
  FMX.TabControl,
  FMX.Types,

  SafeThread4D,

  System.Classes,
  System.Generics.Collections,
  System.IOUtils,
  System.Math,
  System.SyncObjs,
  System.SysUtils,
  System.UITypes,
  System.Variants;

type
  TFormMain = class(TForm)
    btnCopyFile               : TButton;
    lblCopyStatus             : TLabel;
    pbarFolderCopy            : TProgressBar;
    btnCancelCopyFile         : TButton;
    edtSrcFile                : TEdit;
    edtDstFile                : TEdit;
    btnCopyFolder             : TButton;
    edtSrcDir                 : TEdit;
    edtDstDir                 : TEdit;
    btnCopyFolderCancel       : TButton;
    TabControl                : TTabControl;
    tabCopyFolderFile         : TTabItem;
    rctCopyFileLog            : TRectangle;
    MemoCopyFileLog           : TMemo;
    pbarFileCopy              : TProgressBar;
    rctCopyFolderLog          : TRectangle;
    MemoCopyFolderLog         : TMemo;
    CopyFolderFanOut          : TButton;
    btnCancelCopyFolderFanOut : TButton;
    btnSelectFolder           : TButton;
    btnSelectFile             : TButton;
    rctParallelLog            : TRectangle;
    MemoParallelLog           : TMemo;

    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure btnCopyFileClick(Sender: TObject);
    procedure btnCancelCopyFileClick(Sender: TObject);
    procedure btnCopyFolderClick(Sender: TObject);
    procedure btnCopyFolderCancelClick(Sender: TObject);
    procedure CopyFolderFanOutClick(Sender: TObject);
    procedure btnCancelCopyFolderFanOutClick(Sender: TObject);
    procedure btnSelectFolderClick(Sender: TObject);
    procedure btnSelectFileClick(Sender: TObject);

  private
    { Private declarations }

    // Copy Folder & File.
    FCopyFolderParams: ISafeThread4DParams;
    FCopyFileParams  : ISafeThread4DParams;

    // Copy Folder - Fan-out.
    FCopyFanParams    : TArray<ISafeThread4DParams>;
    FCopyFanRemaining : Integer;
    FCopyFanTotalBytes: Int64;
    FCopyFanCopied    : Int64;
    FCopyFanFiles     : TArray<string>;

    // Path helpers.
    function GetRelativePathSafe(const ARoot, AFullPath: string): string;
    function NormalizeRelPath(const AValue: string): string;
    procedure EnsureParentDirExists(const AFileName: string);

    // Copy Folder - Fan-out.
    procedure StartCopyFolderFanOut(const AWorkerCount: Integer);
    procedure CancelCopyFolderFanOut;

    {$IFDEF MSWINDOWS}
    function SelectFileOrFolder(const ATitle: string; const ASelectFolder: Boolean; out APath: string): Boolean;
    {$ENDIF}

    // Shutdown.
    procedure RequestCancelAll;
    function  AllReleased: Boolean;
    procedure DrainUntilReleased(const ATimeoutMs: Integer);

  public
    { Public declarations }

  end;

var
  FormMain: TFormMain;

implementation

{$R *.fmx}

const
  // Buffer size for chunked file I/O.
  BUF_SIZE = 1 shl 20; // 1 MiB.

  // Timeouts (ms).
  FILE_TIMEOUT_MS   = 60_000;       // 60 s for single file copy.
  FOLDER_TIMEOUT_MS = 10 * 60_000;  // 10 min for folder copy.

  // Shutdown drain policy.
  DRAIN_TIMEOUT_MS = 15_000; // 15 s to close elegantly.

{ TFormMain — Path helpers }

function TFormMain.GetRelativePathSafe(const ARoot, AFullPath: string): string;
var
  LRootNorm: string;
  LPathNorm: string;
begin
  LRootNorm := IncludeTrailingPathDelimiter(TPath.GetFullPath(ARoot));
  LPathNorm := TPath.GetFullPath(AFullPath);
  {$IFDEF MSWINDOWS}
  if SameText(Copy(LPathNorm, 1, Length(LRootNorm)), LRootNorm) then
  {$ELSE}
  if CompareStr(Copy(LPathNorm, 1, Length(LRootNorm)), LRootNorm) = 0 then
  {$ENDIF}
    Result := Copy(LPathNorm, Length(LRootNorm) + 1, MaxInt)
  else
    // Fallback: if not under the root, use only the file name.
    Result := TPath.GetFileName(LPathNorm);
end;

function TFormMain.NormalizeRelPath(const AValue: string): string;
var
  LResult: string;
begin
  // Normalize separators.
  LResult := AValue.Replace('/', PathDelim).Replace('\', PathDelim);

  // Remove root prefixes (avoids matching "root-relative" which ignores dstRoot).
  while (LResult <> '') and (LResult[Low(LResult)] = PathDelim) do
    LResult := LResult.Substring(1);

  // Block ".." escaping out of the root.
  if (LResult.Contains(PathDelim + '..' + PathDelim)) or
     (LResult.StartsWith('..' + PathDelim)) then
    raise Exception.CreateFmt('Invalid relative path: %s', [AValue]);

  if LResult = '.' then
    LResult := '';

  Result := LResult;
end;

procedure TFormMain.EnsureParentDirExists(const AFileName: string);
const
  MAX_TRIES = 8;
  SLEEP_MS  = 10;
var
  LDir: string;
  I   : Integer;
begin
  LDir := ExtractFileDir(AFileName);
  if LDir = '' then
    Exit;

  for I := 1 to MAX_TRIES do
  begin
    if TDirectory.Exists(LDir) then
      Exit;
    try
      TDirectory.CreateDirectory(LDir); // Force directory creation.
      Exit;
    except
      on E: Exception do
      begin
        if I = MAX_TRIES then
          raise; // Exhausted attempts.
        TThread.Sleep(SLEEP_MS);
      end;
    end;
  end;
end;

{$IFDEF MSWINDOWS}
function TFormMain.SelectFileOrFolder(const ATitle: string; const ASelectFolder: Boolean; out APath: string): Boolean;
var
  LFileDialog : IFileDialog;
  LShellItem  : IShellItem;
  LOpts       : DWORD;
  LHR         : HRESULT;
  LPW         : PWideChar;
begin
  Result := False;
  APath  := '';

  LHR := CoCreateInstance(CLSID_FileOpenDialog, nil, CLSCTX_INPROC_SERVER, IFileDialog, LFileDialog);
  if Failed(LHR) then
    Exit;

  LFileDialog.GetOptions(LOpts);
  if ASelectFolder then
    LFileDialog.SetOptions(LOpts or FOS_PICKFOLDERS or FOS_FORCEFILESYSTEM)
  else
    LFileDialog.SetOptions(LOpts or FOS_FORCEFILESYSTEM);

  if ATitle <> '' then
    LFileDialog.SetTitle(PWideChar(ATitle));

  LHR := LFileDialog.Show(0);
  if Failed(LHR) then
    Exit;

  if Succeeded(LFileDialog.GetResult(LShellItem)) and Succeeded(LShellItem.GetDisplayName(SIGDN_FILESYSPATH, LPW)) then
  try
    APath  := LPW;
    Result := True;
  finally
    CoTaskMemFree(LPW);
  end;
end;
{$ENDIF}

{ TFormMain — Copy Folder (single-thread) }

procedure TFormMain.btnSelectFolderClick(Sender: TObject);
var
  LPath: string;
begin
  {$IFDEF MSWINDOWS}
  if SelectFileOrFolder('Select a folder', True, LPath) then
    edtSrcDir.Text := LPath;
  {$ELSE}
  ShowMessage('Only implemented on Windows.');
  {$ENDIF}
end;

procedure TFormMain.btnCopyFolderClick(Sender: TObject);
(*
  FOLDER COPY (recursive, single-thread)
  - Copies all files from src root to dst root, preserving relative paths.
  - Shows global progress based on total bytes.
  - Supports cooperative cancel + timeout + heartbeat.
  - Uses ParamsRaw (weak pointer) to avoid capturing the interface
    in the closure and to keep ownership clear.

  Pattern
  - Re-entrancy guard via FCopyFolderParams.
  - Weak snapshot (LParamsRaw := Pointer(LParams)) + external strong ref
    (FCopyFolderParams := LParams) held by StartThreadWithWeakRef.
  - OnExecute rebuilds a scoped strong ref from LParamsRaw and performs:
      * snapshot of all files
      * total-size computation
      * chunked copy with CheckCancel/CheckTimeout + ReportProgress.
*)
var
  LParams   : ISafeThread4DParams;
  LParamsRaw: Pointer; // Weak pointer (no AddRef).
begin
  // Re-entry: if already running and not canceled, ignore the click.
  // Also avoid overlapping the single-thread and fan-out folder demos,
  // since they share the same UI surface.
  if Assigned(FCopyFolderParams) and not FCopyFolderParams.CancelRequested then
    Exit;
  if Length(FCopyFanParams) > 0 then
    Exit;

  LParams :=
    TSafeThread4DParams.New
      .SetThreadName('Folder-Copy')
      .SetFreeOnTerminate(True)
      .SetMeasureTime(True)
      .SetTimeoutMs(FOLDER_TIMEOUT_MS)
      .SetHeartbeatIntervalMs(400)
      .SetOnHeartbeat(
        procedure
        var
          LBlip: Char;
          LTs: string;
        begin
          if Odd(TThread.GetTickCount64 div 400) then
            LBlip := '●'
          else
            LBlip := '◦';
          LTs := FormatDateTime('hh:nn:ss', Now);
          {$IFDEF ANDROID}
          lblCopyStatus.Text := Format('[HB] ANR guard %s  %s', [LBlip, LTs]);
          {$ELSE}
          lblCopyStatus.Text := Format('[HB] UI ping %s  %s', [LBlip, LTs]);
          {$ENDIF}
        end)
      .SetOnInitialize(
        procedure(AContext: TThreadContext)
        begin
          pbarFolderCopy.Value := 0;
          lblCopyStatus.Text := '=== Preparing... ===';
          btnCopyFolder.Enabled := False;
          btnCopyFolderCancel.Enabled  := True;
          MemoCopyFolderLog.Lines.Clear;
        end)
      .SetOnProgress(
        procedure(APct: Single)
        begin
          pbarFolderCopy.Value := APct * 100;
          lblCopyStatus.Text := Format('Copying... %.0f%%', [APct * 100]);
        end)
      .SetProgressIntervalMs(120)
      .SetOnTimeout(
        procedure(AContext: TThreadContext)
        begin
          lblCopyStatus.Text := '=== Timeout - Copy aborted ===';
          MemoCopyFolderLog.Lines.Add('[Timeout]');
        end)
      .SetOnCancel(
        procedure(AContext: TThreadContext)
        begin
          lblCopyStatus.Text := '=== Canceled by user ===';
          MemoCopyFolderLog.Lines.Add('[Cancel]');
        end)
      .SetOnError(
        procedure(const AErrorMessage: string; const AContext: TThreadContext)
        begin
          lblCopyStatus.Text := '=== Error ===';
          MemoCopyFolderLog.Lines.Add('[Error] ' + AErrorMessage);
        end)
      .SetOnSuccess(
        procedure(AContext: TThreadContext)
        begin
          pbarFolderCopy.Value := 100;
          lblCopyStatus.Text := '=== Done ===';
          MemoCopyFolderLog.Lines.Add(
            Format('[Success] Copied in %.3f s', [AContext.ElapsedMilliseconds / 1000]));
        end)
      .SetOnTerminate(
        procedure(AContext: TThreadContext)
        begin
          btnCopyFolder.Enabled := True;
          btnCopyFolderCancel.Enabled := False;
          FCopyFolderParams := nil;
        end)
      .SetOnExecute(
        procedure(AContext: TThreadContext)
        var
          LSrcRoot, LDstRoot: string;
          LFiles: TArray<string>;
          LTotalBytes, LCopied: Int64;
          LFileName, LRelPath, LDstFile: string;
          LSrcStream, LDstStream: TFileStream;
          LBuffer: TBytes;
          LBytesRead: Integer;
          LLastReportBytes: Int64;
          LParams: ISafeThread4DParams; // Scoped strong ref.

          procedure ReportIfNeeded;
          begin
            if (LTotalBytes > 0) and
               ((LCopied - LLastReportBytes) >= (LTotalBytes div 100)) then
            begin
              LLastReportBytes := LCopied;
              TSafeThread4D.ReportProgress(LParams, LCopied / LTotalBytes);
            end;
          end;

        begin
          // Weak -> Strong.
          LParams := ISafeThread4DParams(IInterface(LParamsRaw));
          if LParams = nil then
            raise Exception.Create('Internal error: ParamsRaw not initialized.');

          LSrcRoot := Trim(edtSrcDir.Text);
          LDstRoot := Trim(edtDstDir.Text);

          if (LSrcRoot = '') or (LDstRoot = '') then
            raise Exception.Create('Source and destination folders are required.');
          if not TDirectory.Exists(LSrcRoot) then
            raise Exception.Create('Source folder not found.');

          // Snapshot of files.
          LFiles := TDirectory.GetFiles(LSrcRoot, '*', TSearchOption.soAllDirectories);
          if Length(LFiles) = 0 then
            Exit;

          // Total bytes.
          LTotalBytes := 0;
          for LFileName in LFiles do
            Inc(LTotalBytes, TFile.GetSize(LFileName));

          SetLength(LBuffer, BUF_SIZE);
          LCopied := 0;
          LLastReportBytes := 0;

          // Initial checkpoints.
          TSafeThread4D.CheckCancel(LParams, AContext);
          TSafeThread4D.CheckTimeout(LParams, AContext);

          for LFileName in LFiles do
          begin
            TSafeThread4D.CheckCancel(LParams, AContext);
            TSafeThread4D.CheckTimeout(LParams, AContext);

            // Relative path and destination.
            LRelPath := GetRelativePathSafe(LSrcRoot, LFileName);
            LDstFile := TPath.Combine(LDstRoot, LRelPath);
            TDirectory.CreateDirectory(ExtractFileDir(LDstFile));

            LSrcStream := TFileStream.Create(LFileName, fmOpenRead or fmShareDenyWrite);
            try
              LDstStream := TFileStream.Create(LDstFile, fmCreate);
              try
                while True do
                begin
                  // Checkpoints per chunk.
                  TSafeThread4D.CheckCancel(LParams, AContext);
                  TSafeThread4D.CheckTimeout(LParams, AContext);

                  LBytesRead := LSrcStream.Read(LBuffer, 0, Length(LBuffer));
                  if LBytesRead <= 0 then
                    Break;

                  LDstStream.WriteBuffer(LBuffer, LBytesRead);
                  Inc(LCopied, LBytesRead);
                  ReportIfNeeded;
                end;
              finally
                LDstStream.Free;
              end;
            finally
              LSrcStream.Free;
            end;
          end;
        end);

  TSafeThread4D.StartThreadWithWeakRef(LParams, LParamsRaw, FCopyFolderParams);
end;

procedure TFormMain.btnCopyFolderCancelClick(Sender: TObject);
begin
  if Assigned(FCopyFolderParams) then
  begin
    MemoCopyFolderLog.Lines.Add('[User] Cancel requested...');
    FCopyFolderParams.RequestCancel;
    btnCopyFolderCancel.Enabled := False;
  end;
end;

{ TFormMain — Copy Folder (fan-out, parallel workers) }

procedure TFormMain.StartCopyFolderFanOut(const AWorkerCount: Integer);
(*
  FOLDER COPY (fan-out, parallel workers)
  - Snapshots all files under SrcRoot and distributes them across N workers.
  - Each worker:
      * copies its slice of files with cooperative cancel/timeout
      * updates a shared byte counter via TInterlocked.Add
      * triggers ReportProgress, which computes global % based on the shared counter.
  - OnTerminate of each worker decrements FCopyFanRemaining; the last one
    finalizes UI and releases refs/buffers.

  Pattern
  - Single-thread pre-pass:
      * validate input
      * snapshot file list
      * pre-create directory tree
      * compute FCopyFanTotalBytes.
  - Multi-thread loop:
      * StartWorker(...) with weak snapshot (LParamsRaw := Pointer(LParams))
        + external strong ref (FCopyFanParams[W] := LParams).
*)
var
  LSrcRoot, LDstRoot: string;
  I, W, LChunk, LFromIdx, LToIdx: Integer;
  LStartedWorkers: Integer;

  procedure PrecreateAllDirs(const ASrcRoot, ADstRoot: string; const AFiles: TArray<string>);
  var
    LFileName, LRel, LDir: string;
    LSeen: TDictionary<string, Byte>;
  begin
    LSeen := TDictionary<string, Byte>.Create;
    try
      TDirectory.CreateDirectory(ADstRoot);
      for LFileName in AFiles do
      begin
        LRel := NormalizeRelPath(GetRelativePathSafe(ASrcRoot, LFileName));
        LDir := ExtractFileDir(TPath.Combine(ADstRoot, LRel));
        if (LDir <> '') and (not LSeen.ContainsKey(LDir)) then
        begin
          TDirectory.CreateDirectory(LDir);
          LSeen.Add(LDir, 0);
        end;
      end;
    finally
      LSeen.Free;
    end;
  end;

  function TotalOf(const AFiles: TArray<string>): Int64;
  var
    LFileName: string;
  begin
    Result := 0;
    for LFileName in AFiles do
      Inc(Result, TFile.GetSize(LFileName));
  end;

  procedure StartWorker(const AWorkerIndex, AFromIdx, AToIdx: Integer);
  var
    LParams: ISafeThread4DParams;
    LParamsRaw: Pointer;
  begin
    LParams :=
      TSafeThread4DParams.New
        .SetThreadName(Format('CopyFan-%d', [AWorkerIndex]))
        .SetFreeOnTerminate(True)
        .SetMeasureTime(True)
        .SetTimeoutMs(FOLDER_TIMEOUT_MS)
        // Each worker reports % based on the global shared counter.
        .SetOnProgress(
          procedure(APct: Single)
          var
            LPct: Double;
          begin
            if FCopyFanTotalBytes > 0 then
            begin
              LPct := (TInterlocked.Read(FCopyFanCopied) / FCopyFanTotalBytes) * 100.0;
              pbarFolderCopy.Value := LPct;
              lblCopyStatus.Text   := Format('Copying... %.0f%%', [LPct]);
            end;
          end)
        .SetProgressIntervalMs(120)
        .SetOnError(
          procedure(const AErrorMessage: string; const AContext: TThreadContext)
          begin
            MemoCopyFolderLog.Lines.Add(
              Format('[Worker %d][Error] %s', [AWorkerIndex, AErrorMessage]));
          end)
        .SetOnTerminate(
          procedure(AContext: TThreadContext)
          var
            K: Integer;
          begin
            // When the last worker finishes, finalize UI and release references.
            if TInterlocked.Decrement(FCopyFanRemaining) = 0 then
            begin
              if TInterlocked.Read(FCopyFanCopied) >= FCopyFanTotalBytes then
              begin
                pbarFolderCopy.Value := 100;
                lblCopyStatus.Text   := '=== Done (fan-out) ===';
                MemoCopyFolderLog.Lines.Add(
                  Format('[Success] Parallel folder copy in %.3f s',
                         [AContext.ElapsedMilliseconds / 1000]));
              end
              else
              begin
                lblCopyStatus.Text := '=== Finished (partial) ===';
              end;

              // Release refs.
              for K := Low(FCopyFanParams) to High(FCopyFanParams) do
                FCopyFanParams[K] := nil;

              SetLength(FCopyFanParams, 0);
              SetLength(FCopyFanFiles, 0);
              CopyFolderFanOut.Enabled := True;
              btnCancelCopyFolderFanOut.Enabled := False;
            end;
          end)
        .SetOnExecute(
          procedure(AContext: TThreadContext)
          var
            LIndex, LBytesRead: Integer;
            LSrcFile, LRel, LDstFile: string;
            LSrcStream, LDstStream: TFileStream;
            LBuffer: TBytes;
            LLastTick: UInt64;
            LParams: ISafeThread4DParams;
          begin
            // Weak -> Strong (allows CheckCancel/CheckTimeout).
            LParams := ISafeThread4DParams(IInterface(LParamsRaw));
            if LParams = nil then
              raise Exception.Create('Internal error: ParamsRaw not initialized.');

            SetLength(LBuffer, BUF_SIZE);
            LLastTick := 0;

            for LIndex := AFromIdx to AToIdx do
            begin
              TSafeThread4D.CheckCancel(LParams, AContext);
              TSafeThread4D.CheckTimeout(LParams, AContext);

              LSrcFile := FCopyFanFiles[LIndex];
              LRel := NormalizeRelPath(GetRelativePathSafe(LSrcRoot, LSrcFile));
              LDstFile := TPath.Combine(LDstRoot, LRel);

              EnsureParentDirExists(LDstFile);

              LSrcStream := TFileStream.Create(LSrcFile, fmOpenRead or fmShareDenyWrite);
              try
                LDstStream := TFileStream.Create(LDstFile, fmCreate);
                try
                  while True do
                  begin
                    // Checkpoints per chunk.
                    TSafeThread4D.CheckCancel(LParams, AContext);
                    TSafeThread4D.CheckTimeout(LParams, AContext);

                    LBytesRead := LSrcStream.Read(LBuffer, 0, Length(LBuffer));
                    if LBytesRead <= 0 then
                      Break;

                    LDstStream.WriteBuffer(LBuffer, LBytesRead);

                    // Global sum (bytes copied).
                    TInterlocked.Add(FCopyFanCopied, LBytesRead);

                    // Throttled progress trigger.
                    if (TThread.GetTickCount64 - LLastTick) >= 120 then
                    begin
                      LLastTick := TThread.GetTickCount64;
                      // Use OnProgress to refresh UI based on the global counter.
                      TSafeThread4D.ReportProgress(LParams, 0.0);
                    end;
                  end;
                finally
                  LDstStream.Free;
                end;
              finally
                LSrcStream.Free;
              end;
            end;
          end);

    // Weak + Strong.
    LParamsRaw := Pointer(LParams);
    FCopyFanParams[AWorkerIndex] := LParams;

    TSafeThread4D.StartThread(LParams);
  end;

begin
  // Re-entry guard: avoid overlapping the fan-out path with itself or with
  // the single-thread folder copy path.
  if Length(FCopyFanParams) > 0 then
    Exit;
  if Assigned(FCopyFolderParams) and not FCopyFolderParams.CancelRequested then
    Exit;

  // Input validation & snapshot.
  LSrcRoot := Trim(edtSrcDir.Text);
  LDstRoot := Trim(edtDstDir.Text);

  if (LSrcRoot = '') or (LDstRoot = '') then
    raise Exception.Create('Source and destination folders are required.');

  if not TDirectory.Exists(LSrcRoot) then
    raise Exception.Create('Source folder not found.');

  MemoCopyFolderLog.Lines.Clear;
  lblCopyStatus.Text := '=== Preparing (fan-out)... ===';
  pbarFolderCopy.Value := 0;
  CopyFolderFanOut.Enabled := False;
  btnCancelCopyFolderFanOut.Enabled := True;

  // File list snapshot (read-once).
  FCopyFanFiles := TDirectory.GetFiles(LSrcRoot, '*', TSearchOption.soAllDirectories);
  if Length(FCopyFanFiles) = 0 then
  begin
    lblCopyStatus.Text := 'Nothing to copy.';
    Exit;
  end;

  // Pre-create the entire destination directory tree (single-thread).
  PrecreateAllDirs(LSrcRoot, LDstRoot, FCopyFanFiles);

  FCopyFanTotalBytes := TotalOf(FCopyFanFiles);
  FCopyFanCopied     := 0;

  // Ensure destination root exists.
  TDirectory.CreateDirectory(LDstRoot);

  // Simple and balanced partitioning by number of files.
  SetLength(FCopyFanParams, AWorkerCount);
  FCopyFanRemaining := 0;
  LStartedWorkers   := 0;

  I := Length(FCopyFanFiles);
  LChunk := I div AWorkerCount;

  if LChunk = 0 then
    LChunk := 1;

  for W := 0 to AWorkerCount - 1 do
  begin
    LFromIdx := W * LChunk;
    if W = AWorkerCount - 1 then
      LToIdx := I - 1
    else
      LToIdx := Min(I - 1, LFromIdx + LChunk - 1);

    if LFromIdx <= LToIdx then
    begin
      Inc(LStartedWorkers);
      StartWorker(W, LFromIdx, LToIdx);
    end;
  end;

  FCopyFanRemaining := LStartedWorkers;
  if FCopyFanRemaining = 0 then
  begin
    CopyFolderFanOut.Enabled := True;
    btnCancelCopyFolderFanOut.Enabled := False;
    lblCopyStatus.Text := 'Nothing to copy.';
    SetLength(FCopyFanParams, 0);
    SetLength(FCopyFanFiles, 0);
    Exit;
  end;

  lblCopyStatus.Text := Format(
    'Copying... 0%%  (%d files, %.2f MB total)',
    [Length(FCopyFanFiles), FCopyFanTotalBytes / (1024 * 1024)]);
end;

procedure TFormMain.CopyFolderFanOutClick(Sender: TObject);
begin
  // Tune according to CPU/IO; 4 is a good starting point for SSD/RAM disk.
  StartCopyFolderFanOut(4);
end;

procedure TFormMain.CancelCopyFolderFanOut;
var
  I: Integer;
begin
  if Length(FCopyFanParams) = 0 then
    Exit;

  MemoCopyFolderLog.Lines.Add('[User] Cancel fan-out requested...');

  for I := Low(FCopyFanParams) to High(FCopyFanParams) do
    if Assigned(FCopyFanParams[I]) then
      FCopyFanParams[I].RequestCancel;
end;

procedure TFormMain.btnCancelCopyFolderFanOutClick(Sender: TObject);
begin
  btnCancelCopyFolderFanOut.Enabled := False;
  CancelCopyFolderFanOut;
end;

{ TFormMain — Copy File (single-thread) }

procedure TFormMain.btnSelectFileClick(Sender: TObject);
var
  LPath: string;
begin
  {$IFDEF MSWINDOWS}
  if SelectFileOrFolder('Select a file', False, LPath) then
    edtSrcFile.Text := LPath;
  {$ELSE}
  ShowMessage('Only implemented on Windows.');
  {$ENDIF}
end;

procedure TFormMain.btnCopyFileClick(Sender: TObject);
(*
  FILE COPY (background, single-thread)
  - Copies one file with progress + throughput (MB/s), cancel, timeout, heartbeat.
  - Uses ParamsRaw (weak pointer) to avoid capturing the interface in the closure.
  - No TThread.Queue inside the worker (avoids pending closures).
*)
var
  LParams   : ISafeThread4DParams;
  LParamsRaw: Pointer; // Weak pointer (no AddRef).
  LTotalSz  : Int64;   // Read-only in the UI; set once in the worker.
  LStartTick: UInt64;  // For approximate throughput in the UI.
begin
  // Re-entry: if there is already a copy in progress and it has not been canceled, ignore it.
  if Assigned(FCopyFileParams) and not FCopyFileParams.CancelRequested then
    Exit;

  MemoCopyFileLog.Lines.Clear;
  LTotalSz   := 0;
  LStartTick := 0;

  LParams :=
    TSafeThread4DParams.New
      .SetThreadName('File-Copy')
      .SetFreeOnTerminate(True)
      .SetMeasureTime(True)
      .SetTimeoutMs(FILE_TIMEOUT_MS)
      .SetHeartbeatIntervalMs(300)
      .SetOnHeartbeat(
        procedure
        var
          LBlip: Char;
          LTs: string;
        begin
          if Odd(TThread.GetTickCount64 div 300) then
            LBlip := '●'
          else
            LBlip := '◦';
          LTs := FormatDateTime('hh:nn:ss', Now);
          {$IFDEF ANDROID}
          lblCopyStatus.Text := Format('[HB] ANR guard %s  %s', [LBlip, LTs]);
          {$ELSE}
          lblCopyStatus.Text := Format('[HB] UI ping %s  %s', [LBlip, LTs]);
          {$ENDIF}
        end)
      .SetOnInitialize(
        procedure(AContext: TThreadContext)
        begin
          pbarFileCopy.Value := 0;
          lblCopyStatus.Text := '=== Preparing... ===';
          btnCopyFile.Enabled := False;
          btnCancelCopyFile.Enabled := True;
          LStartTick := TThread.GetTickCount64;
          MemoCopyFileLog.Lines.Clear;
        end)
      .SetOnProgress(
        procedure(APct: Single)
        var
          LPerc, LSecs, LMbps: Double;
        begin
          pbarFileCopy.Value := APct * 100;
          LPerc := APct * 100.0;

          // Approximate throughput (BytesCopied = APct * LTotalSz).
          if LTotalSz > 0 then
          begin
            LSecs := (TThread.GetTickCount64 - LStartTick) / 1000.0;
            if LSecs > 0 then
              LMbps := (APct * LTotalSz) / (1024.0 * 1024.0) / LSecs
            else
              LMbps := 0.0;
            lblCopyStatus.Text := Format('Copying... %.0f%%  ~%.2f MB/s', [LPerc, LMbps]);
          end
          else
            lblCopyStatus.Text := Format('Copying... %.0f%%', [LPerc]);
        end)
      .SetProgressIntervalMs(100)
      .SetOnTimeout(
        procedure(AContext: TThreadContext)
        begin
          lblCopyStatus.Text := '=== Timeout - Copy aborted ===';
          MemoCopyFileLog.Lines.Add('[Timeout] Elapsed: ' +
            FormatFloat('0.000', AContext.ElapsedMilliseconds / 1000) + ' s');
          // Optional: partial delete.
          try
            if TFile.Exists(edtDstFile.Text) then
              TFile.Delete(edtDstFile.Text);
          except
          end;
        end)
      .SetOnCancel(
        procedure(AContext: TThreadContext)
        begin
          lblCopyStatus.Text := '=== Canceled by user ===';
          MemoCopyFileLog.Lines.Add('[Cancel] Copy canceled.');
          // Optional: partial delete.
          try
            if TFile.Exists(edtDstFile.Text) then
              TFile.Delete(edtDstFile.Text);
          except
          end;
        end)
      .SetOnError(
        procedure(const AErrorMessage: string; const AContext: TThreadContext)
        begin
          lblCopyStatus.Text := '=== Error ===';
          MemoCopyFileLog.Lines.Add('[Error] ' + AErrorMessage);
          // Optional: partial delete.
          try
            if TFile.Exists(edtDstFile.Text) then
              TFile.Delete(edtDstFile.Text);
          except
          end;
        end)
      .SetOnSuccess(
        procedure(AContext: TThreadContext)
        begin
          lblCopyStatus.Text := '=== Done ===';
          MemoCopyFileLog.Lines.Add(Format('[Success] Copied in %.3f s',
            [AContext.ElapsedMilliseconds / 1000]));
        end)
      .SetOnTerminate(
        procedure(AContext: TThreadContext)
        begin
          btnCopyFile.Enabled := True;
          btnCancelCopyFile.Enabled := False;
          FCopyFileParams := nil; // Release external strong ref.
        end)
      .SetOnExecute(
        procedure(AContext: TThreadContext)
        var
          LSrcPath, LDstPath: string;
          LSrcStream, LDstStream: TFileStream;
          LBuffer: TBytes;
          LCopied: Int64;
          LBytesRead: Integer;
          LParams: ISafeThread4DParams; // Scoped strong ref.
        begin
          // Weak -> Strong.
          LParams := ISafeThread4DParams(IInterface(LParamsRaw));
          if LParams = nil then
            raise Exception.Create('Internal error: ParamsRaw not initialized.');

          LSrcPath := Trim(edtSrcFile.Text);
          LDstPath := Trim(edtDstFile.Text);

          if (LSrcPath = '') or (LDstPath = '') then
            raise Exception.Create('Source and destination paths are required.');
          if SameText(LSrcPath, LDstPath) then
            raise Exception.Create('Source and destination must differ.');
          if not TFile.Exists(LSrcPath) then
            raise Exception.Create('Source file not found.');

          TDirectory.CreateDirectory(ExtractFileDir(LDstPath));

          LSrcStream := TFileStream.Create(LSrcPath, fmOpenRead or fmShareDenyWrite);
          try
            LDstStream := TFileStream.Create(LDstPath, fmCreate);
            try
              SetLength(LBuffer, BUF_SIZE);
              LTotalSz := LSrcStream.Size; // Visible to OnProgress (UI).
              LCopied := 0;

              // Initial checkpoints.
              TSafeThread4D.CheckCancel(LParams, AContext);
              TSafeThread4D.CheckTimeout(LParams, AContext);

              while True do
              begin
                // Checkpoints per chunk.
                TSafeThread4D.CheckCancel(LParams, AContext);
                TSafeThread4D.CheckTimeout(LParams, AContext);

                LBytesRead := LSrcStream.Read(LBuffer, 0, Length(LBuffer));
                if LBytesRead <= 0 then
                  Break;

                LDstStream.WriteBuffer(LBuffer, LBytesRead);
                Inc(LCopied, LBytesRead);

                // Always reports; throttling is done by ProgressIntervalMs.
                if LTotalSz > 0 then
                  TSafeThread4D.ReportProgress(LParams, LCopied / LTotalSz);
              end;
            finally
              LDstStream.Free;
            end;
          finally
            LSrcStream.Free;
          end;
        end);

  TSafeThread4D.StartThreadWithWeakRef(LParams, LParamsRaw, FCopyFileParams);
end;

procedure TFormMain.btnCancelCopyFileClick(Sender: TObject);
begin
  if Assigned(FCopyFileParams) then
  begin
    MemoCopyFileLog.Lines.Add('[User] Cancellation request...');
    FCopyFileParams.RequestCancel;
  end;
end;

{ TFormMain — Shutdown }

procedure TFormMain.RequestCancelAll;
  procedure Cancel(var AParams: ISafeThread4DParams; const ATag: string);
  begin
    if Assigned(AParams) then
    begin
      MemoCopyFolderLog.Lines.Add('[Close] Cancel ' + ATag);
      AParams.RequestCancel;
    end;
  end;
var
  I: Integer;
begin
  Cancel(FCopyFolderParams, 'CopyFolder');
  Cancel(FCopyFileParams, 'CopyFile');

  if Length(FCopyFanParams) > 0 then
  begin
    MemoCopyFolderLog.Lines.Add('[Close] Cancel CopyFolderFanOut');
    for I := Low(FCopyFanParams) to High(FCopyFanParams) do
      if Assigned(FCopyFanParams[I]) then
        FCopyFanParams[I].RequestCancel;
  end;
end;

function TFormMain.AllReleased: Boolean;
var
  I: Integer;
begin
  Result :=
    (FCopyFolderParams = nil) and
    (FCopyFileParams = nil);

  if not Result then
    Exit;

  for I := Low(FCopyFanParams) to High(FCopyFanParams) do
    if Assigned(FCopyFanParams[I]) then
      Exit(False);

  Result := True;
end;

procedure TFormMain.DrainUntilReleased(const ATimeoutMs: Integer);
var
  LStartTick: UInt64;
begin
  LStartTick := TThread.GetTickCount64;
  while not AllReleased do
  begin
    // Drain the Synchronize/Queue queue explicitly.
    //
    // Why this is useful:
    // - During shutdown, a worker may already be finished logically but still
    //   be waiting for its marshalled OnTerminate / OnCancel / OnError /
    //   final UI callbacks to run on the main thread.
    // - If those callbacks do not run, params references stay published and
    //   the close sequence can appear to hang even though cancellation was
    //   already requested.
    //
    // Why CheckSynchronize is used here:
    // - It directly drains the RTL callback queue used by Synchronize / Queue.
    // - Application.ProcessMessages is intentionally not used here because
    //   it is not a reliable drain mechanism for that queue in FMX.
    //
    // This bounded drain gives the last queued lifecycle callbacks a small,
    // explicit window to finish before shutdown proceeds.
    CheckSynchronize(10);

    if (ATimeoutMs > 0) and
       (TThread.GetTickCount64 - LStartTick >= UInt64(ATimeoutMs)) then
    begin
      MemoCopyFolderLog.Lines.Add('[Close] Timeout waiting for workers to finish');
      Break;
    end;
  end;
end;

procedure TFormMain.FormClose(Sender: TObject; var Action: TCloseAction);
(*
  NOTE: Why this example uses a bounded shutdown drain.

  Context
  - We use a short, bounded drain loop at app shutdown to let pending
    UI-thread callbacks finish and release the final params references
    (F...Params := nil) before the process exits.

  Why this is useful
  - A worker may already be logically finished, but its final lifecycle
    callbacks can still be waiting in the Synchronize / Queue pipeline.
  - If the form closes before those callbacks run, the close sequence can
    appear to hang even though cancellation has already propagated.

  Why CheckSynchronize is used
  - It is the RTL API intended to drain pending Synchronize / Queue work.
  - It makes shutdown behavior much more predictable than relying on
    Application.ProcessMessages as a drain mechanism in FMX.

  Scope
  - This is host-app shutdown policy only.
  - It is not a recommendation for normal UI flow.
*)
begin
  MemoCopyFolderLog.Lines.Add('=== Application shutting down ===');

  // 1) General cancel.
  RequestCancelAll;

  // 2) Drain until all F...Params are NIL (via OnTerminate).
  DrainUntilReleased(DRAIN_TIMEOUT_MS);

  // 3) Final cleanup of auxiliary resources (if anything is left).
  SetLength(FCopyFanParams, 0);
  SetLength(FCopyFanFiles, 0);

  MemoCopyFolderLog.Lines.Add('=== Shutdown complete ===');
end;

end.
