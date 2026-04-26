// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Eduardo P. Araujo
// https://github.com/eduardoparaujo/SafeThread4D

{*
  Unit   : SafeThread.BulkData.Demo.Main
  Purpose: Bulk dataset operations demo for SafeThread4D 1.0.0.

  Part of the SafeThread4D examples.

  Author        : Eduardo P. Araujo
  Created       : 2026-04-26
  Last modified : 2026-04-26
  Version       : 1.0.0

  Notes:
    - This unit is a demo/validation surface, not part of the SafeThread4D
      runtime.

    - Highlights:
        * LiveBindings disconnect/reconnect helpers for large datasets.
        * Background bulk insert with progress, heartbeat, and cooperative
          cancel.
        * Pause/Resume variant using a worker-private TFDMemTable + snapshot
          handoff (the recommended pattern in this unit).
        * Background bulk update example.
        * Bounded shutdown drain on FormClose using CheckSynchronize for
          correct Synchronize queue draining across all FMX platforms (see
          docs/SynchronizeVsProcessMessages.md for the rationale).
        * Fast-cancel skipping of non-cancellable MergeChangeLog/SaveToStream
          tail work when cancel has been requested, keeping FormClose
          responsive even on large datasets.
        * Tight CheckCancel cadence (128 iterations) for prompt cancel
          observation.

    - Important:
        * The plain Bulk Insert and Bulk Update paths touch the UI-bound
          TFDMemTable from the worker thread after DisableControls.
          FireDAC does not guarantee thread-safety for that pattern.
        * The recommended example in this unit is the Pause/Resume variant,
          which uses a worker-private TFDMemTable and applies the final
          snapshot on the UI thread in OnSuccess.
*}

unit SafeThread.BulkData.Demo.Main;

interface

uses
  System.Bindings.Outputs,
  System.Classes,
  System.DateUtils,
  System.Math,
  System.Rtti,
  System.StrUtils,
  System.SyncObjs,
  System.SysUtils,
  System.UITypes,

  Data.Bind.Components,
  Data.Bind.DBScope,
  Data.Bind.EngExt,
  Data.Bind.Grid,
  Data.DB,

  FireDAC.Comp.Client,
  FireDAC.Comp.DataSet,
  FireDAC.Comp.UI,
  FireDAC.DApt.Intf,
  FireDAC.DatS,
  FireDAC.FMXUI.Wait,
  FireDAC.Phys.Intf,
  FireDAC.Stan.Error,
  FireDAC.Stan.Intf,
  FireDAC.Stan.Option,
  FireDAC.Stan.Param,
  FireDAC.Stan.StorageBin,
  FireDAC.UI.Intf,

  FMX.Bind.DBEngExt,
  Fmx.Bind.Editors,
  FMX.Bind.Grid,
  FMX.Controls,
  FMX.Controls.Presentation,
  FMX.Forms,
  FMX.Grid,
  FMX.Grid.Style,
  FMX.Memo,
  FMX.Memo.Types,
  FMX.Objects,
  FMX.ScrollBox,
  FMX.StdCtrls,
  FMX.Types,

  SafeThread4D;

type
  TFormMain = class(TForm)
rctMsg                          : TRectangle;
    MemoLog                     : TMemo;
    GridData                    : TGrid;
    FDMemTable                  : TFDMemTable;
    FDGUIxWaitCursor1           : TFDGUIxWaitCursor;
    btnCreateFields             : TButton;
    btnInsertRecords            : TButton;
    btnCancelInsertRecords      : TButton;
    pbarInsertRecords           : TProgressBar;
    lblPercentageInsertRecords  : TLabel;
    lblInsertRecordsStatus      : TLabel;
    AniIndicatorInsertRecords   : TAniIndicator;
    btnInsertRecordsPauseResume : TButton;
    btnPauseRecordsPauseResume  : TButton;
    btnCancelRecordsPauseResume : TButton;
    btnUpdateRecords            : TButton;
    btnCancelUpdateRecords      : TButton;
    pbarUpdateRecords           : TProgressBar;
    lblPercentageUpdateRecords  : TLabel;
    lblUpdateRecordsStatus      : TLabel;
    AniIndicatorUpdateRecords   : TAniIndicator;
    BindSourceDB1               : TBindSourceDB;

    procedure btnCreateFieldsClick(Sender: TObject);
    procedure btnInsertRecordsClick(Sender: TObject);
    procedure btnCancelInsertRecordsClick(Sender: TObject);
    procedure btnInsertRecordsPauseResumeClick(Sender: TObject);
    procedure btnPauseRecordsPauseResumeClick(Sender: TObject);
    procedure btnCancelRecordsPauseResumeClick(Sender: TObject);
    procedure btnUpdateRecordsClick(Sender: TObject);
    procedure btnCancelUpdateRecordsClick(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);

  private
    type
      TDemoFields = record
        ID       : TField;
        Name     : TField;
        BirthDate: TField;
        IsActive : TField;
        Balance  : TField;
        Notes    : TField;
        Created  : TField;
      end;

  private
    { Private declarations }

    // LiveBindings (UI grid <-> dataset).
    FBindingsList: TBindingsList;                 // LiveBindings runtime list.
    FBindSourceDB: TBindSourceDB;                 // Data source bridge for the grid.
    FLinkGridToDataSource: TLinkGridToDataSource; // Visual link between grid and source.

    // SafeThread4D task handles.
    FInsertRecordsParams: ISafeThread4DParams;  // Active insert task (nil when idle).
    FUpdateRecordsParams: ISafeThread4DParams;  // Active update task (nil when idle).

    // Pause/Resume coordination.
    FInsertPauseEvent: TEvent;      // Manual-reset gate; signaled = run, reset = paused.
    FInsertRecordsPaused: Boolean;  // UI-side flag mirroring the gate state.
    FInsertSnapshot: TMemoryStream; // Worker's serialized result, applied in OnSuccess.

    // Diagnostics and lifecycle.
    FElapsedMs: Double;   // Last task elapsed time, captured in OnTerminate.
    FIsClosing: Boolean;  // Set in FormClose to suppress UI updates during shutdown.

    // Logging.
    procedure LogLine(const AMessage: string); // Append a line to MemoLog (safe during shutdown).

    // LiveBindings setup/teardown.
    procedure LiveBindOff; // Disconnect grid from dataset before bulk operations.
    procedure LiveBindOn;  // Reconnect grid to dataset after bulk operations.

    // Generic UI helpers.
    procedure SetBusyIndicator(AIndicator: TAniIndicator; const AEnabled: Boolean);          // Show/hide a busy spinner.
    procedure SetProgressUi(AProgressBar: TProgressBar; ALabel: TLabel; const APct: Single); // Update a progress bar and its label.
    procedure ResetProgressUi(AProgressBar: TProgressBar; ALabel: TLabel);                   // Reset progress bar and label to 0%.
    procedure UpdateHeartbeatLabel(ALabel: TLabel; const AIsPaused: Boolean = False);        // Render a heartbeat blip on a status label.

    // Per-operation UI state transitions.
    procedure PrepareSimpleInsertUi;       // Set up UI before the simple bulk insert demo.
    procedure FinalizeSimpleInsertUi;      // Restore UI after the simple bulk insert demo.
    procedure PreparePauseResumeInsertUi;  // Set up UI before the pause/resume insert demo.
    procedure FinalizePauseResumeInsertUi; // Restore UI and release pause-gate resources.
    procedure PrepareUpdateUi;             // Set up UI before the bulk update demo.
    procedure FinalizeUpdateUi;            // Restore UI after the bulk update demo.

    // Pause/Resume gate management.
    procedure ResetInsertPauseEvent;   // Recreate the pause event in signaled (running) state.
    procedure ReleaseInsertPauseGate;  // Signal the pause event so the worker resumes (or exits).
    procedure ClearInsertSnapshot;     // Free the in-memory snapshot stream.
    procedure ApplyInsertSnapshotToUi; // Load the snapshot into the UI-bound TFDMemTable.

    // Field cache (avoids repeated FindField in tight loops).
    function CacheDemoFields(ADataSet: TFDMemTable): TDemoFields; // Capture TField references for fast access.
    procedure ValidateRequiredFields(const AFields: TDemoFields); // Ensure required fields exist before running.

    // Lifecycle hooks (TNotifyEvent-style) for the simple insert demo.
    procedure InsertRecordsInitialize(Sender: TObject); // OnInitializeEvent for the simple insert task.
    procedure InsertRecordsTerminate(Sender: TObject);  // OnTerminateEvent for the simple insert task.

    // Shutdown coordination.
    procedure RequestCancelAll;                              // Signal cancel on all running tasks.
    function AllReleased: Boolean;                           // True when all task handles have been cleared.
    procedure DrainUntilReleased(const ATimeoutMs: Integer); // Pump CheckSynchronize until tasks finish or timeout.

  public
    { Public declarations }

  end;

var
  FormMain: TFormMain;

implementation

{$R *.fmx}

const
  // Field name constants.
  FIELD_ID        = 'ID';
  FIELD_NAME      = 'Name';
  FIELD_BIRTHDATE = 'BirthDate';
  FIELD_ISACTIVE  = 'IsActive';
  FIELD_BALANCE   = 'Balance';
  FIELD_NOTES     = 'Notes';
  FIELD_CREATED   = 'Created';

  // Insert tuning.
  INSERT_HEARTBEAT_MS = 300;
  INSERT_PROGRESS_MS  = 50;
  INSERT_BATCH_SIZE   = 5_000;

  // Shutdown drain policy.
  DRAIN_TIMEOUT_MS = 15_000;

  // Total records to insert (platform-dependent).
  {$IFDEF ANDROID}
  INSERT_TOTAL_RECORDS = 100_000;
  {$ELSE}
  INSERT_TOTAL_RECORDS = 1_000_000;
  {$ENDIF}

{ TFormMain — Logging }

procedure TFormMain.LogLine(const AMessage: string);
begin
  if Assigned(MemoLog) and not (csDestroying in MemoLog.ComponentState) then
    MemoLog.Lines.Add(AMessage);
end;

{ TFormMain — LiveBindings setup/teardown }

procedure TFormMain.LiveBindOff;
begin
  if Assigned(FLinkGridToDataSource) then
  begin
    FLinkGridToDataSource.DataSource := nil;
    FLinkGridToDataSource.GridControl := nil;
    FreeAndNil(FLinkGridToDataSource);
  end;

  FreeAndNil(FBindingsList);
  FreeAndNil(FBindSourceDB);
end;

procedure TFormMain.LiveBindOn;
var
  I: Integer;
begin
  FBindSourceDB := TBindSourceDB.Create(Self);
  FBindingsList := TBindingsList.Create(Self);

  FBindSourceDB.DataSet := FDMemTable;

  FLinkGridToDataSource := TLinkGridToDataSource.Create(FBindingsList);
  FLinkGridToDataSource.DataSource := FBindSourceDB;
  FLinkGridToDataSource.GridControl := GridData;

  for I := 0 to GridData.ColumnCount - 1 do
    GridData.Columns[I].Width := 100;
end;

{ TFormMain — Generic UI helpers }

procedure TFormMain.SetBusyIndicator(AIndicator: TAniIndicator; const AEnabled: Boolean);
begin
  if not Assigned(AIndicator) then
    Exit;

  AIndicator.Visible := AEnabled;
  AIndicator.Enabled := AEnabled;
end;

procedure TFormMain.SetProgressUi(AProgressBar: TProgressBar; ALabel: TLabel; const APct: Single);
var
  LPct: Single;
begin
  LPct := EnsureRange(APct, 0.0, 1.0);

  if Assigned(AProgressBar) then
    AProgressBar.Value := LPct * 100;

  if Assigned(ALabel) then
    ALabel.Text := Format('%.0f%%', [LPct * 100]);
end;

procedure TFormMain.ResetProgressUi(AProgressBar: TProgressBar; ALabel: TLabel);
begin
  // Reset visual state between runs so a previous 100% does not linger.
  if Assigned(AProgressBar) then
    AProgressBar.Value := 0;

  if Assigned(ALabel) then
    ALabel.Text := '0%';
end;

procedure TFormMain.UpdateHeartbeatLabel(ALabel: TLabel; const AIsPaused: Boolean);
var
  LBlip: Char;
  LPrefix: string;
  LStateText: string;
begin
  if not Assigned(ALabel) then
    Exit;

  if Odd(TThread.GetTickCount64 div INSERT_HEARTBEAT_MS) then
    LBlip := '●'
  else
    LBlip := '◦';

  {$IFDEF ANDROID}
  LPrefix := '[HB] ANR guard';
  {$ELSE}
  LPrefix := '[HB] UI ping';
  {$ENDIF}

  LStateText := IfThen(AIsPaused, 'paused', 'running');
  ALabel.Text := Format('%s %s  %s  %s',
    [LPrefix, LBlip, FormatDateTime('hh:nn:ss', Now), LStateText]);
end;

{ TFormMain — Per-operation UI state transitions }

procedure TFormMain.PrepareSimpleInsertUi;
begin
  LiveBindOff;
  ResetProgressUi(pbarInsertRecords, lblPercentageInsertRecords);
  SetBusyIndicator(AniIndicatorInsertRecords, True);
  if Assigned(pbarInsertRecords) then
    pbarInsertRecords.Visible := True;

  btnInsertRecords.Enabled := False;
  btnCancelInsertRecords.Enabled := True;

  MemoLog.Lines.Clear;
  LogLine(Format('[Initialize] Preparing %s inserts...',
    [FormatFloat('#,##0', INSERT_TOTAL_RECORDS)]));
end;

procedure TFormMain.FinalizeSimpleInsertUi;
begin
  if not FIsClosing and not (csDestroying in ComponentState) then
  begin
    LiveBindOn;
    SetBusyIndicator(AniIndicatorInsertRecords, False);
    btnInsertRecords.Enabled := True;
    btnCancelInsertRecords.Enabled := False;
  end;
end;

procedure TFormMain.PreparePauseResumeInsertUi;
begin
  LiveBindOff;
  ResetInsertPauseEvent;
  ClearInsertSnapshot;
  ResetProgressUi(pbarInsertRecords, lblPercentageInsertRecords);

  SetBusyIndicator(AniIndicatorInsertRecords, True);
  if Assigned(pbarInsertRecords) then
    pbarInsertRecords.Visible := True;

  btnInsertRecordsPauseResume.Enabled := False;
  btnPauseRecordsPauseResume.Enabled  := True;
  btnCancelRecordsPauseResume.Enabled := True;
  btnPauseRecordsPauseResume.Text     := 'Pause';

  FInsertRecordsPaused := False;
  MemoLog.Lines.Clear;
  LogLine(Format('[Initialize] Preparing %s inserts...',
    [FormatFloat('#,##0', INSERT_TOTAL_RECORDS)]));
end;

procedure TFormMain.FinalizePauseResumeInsertUi;
begin
  if not FIsClosing and not (csDestroying in ComponentState) then
  begin
    LiveBindOn;
    SetBusyIndicator(AniIndicatorInsertRecords, False);

    btnInsertRecordsPauseResume.Enabled := True;
    btnPauseRecordsPauseResume.Enabled  := False;
    btnCancelRecordsPauseResume.Enabled := False;
    btnPauseRecordsPauseResume.Text := 'Pause';
  end;

  FInsertRecordsPaused := False;
  ReleaseInsertPauseGate;
  FreeAndNil(FInsertPauseEvent);
  ClearInsertSnapshot;
end;

procedure TFormMain.PrepareUpdateUi;
begin
  LiveBindOff;
  ResetProgressUi(pbarUpdateRecords, lblPercentageUpdateRecords);
  SetBusyIndicator(AniIndicatorUpdateRecords, True);
  if Assigned(pbarUpdateRecords) then
    pbarUpdateRecords.Visible := True;

  btnUpdateRecords.Enabled := False;
  btnCancelUpdateRecords.Enabled := True;

  MemoLog.Lines.Clear;
  LogLine('[Info] ' + FormatFloat('#,##0', FDMemTable.RecordCount) + ' records to update...');
end;

procedure TFormMain.FinalizeUpdateUi;
begin
  if not FIsClosing and not (csDestroying in ComponentState) then
  begin
    LiveBindOn;
    SetBusyIndicator(AniIndicatorUpdateRecords, False);
    btnUpdateRecords.Enabled := True;
    btnCancelUpdateRecords.Enabled := False;
  end;
end;

{ TFormMain — Pause/Resume gate management }

procedure TFormMain.ResetInsertPauseEvent;
begin
  FreeAndNil(FInsertPauseEvent);
  FInsertPauseEvent := TEvent.Create(nil, True, True, '');
end;

procedure TFormMain.ReleaseInsertPauseGate;
begin
  if Assigned(FInsertPauseEvent) then
    FInsertPauseEvent.SetEvent;
end;

procedure TFormMain.ClearInsertSnapshot;
begin
  FreeAndNil(FInsertSnapshot);
end;

procedure TFormMain.ApplyInsertSnapshotToUi;
begin
  if FIsClosing or (csDestroying in ComponentState) then
    Exit;

  FDMemTable.DisableControls;
  try
    FDMemTable.Close;
    if Assigned(FInsertSnapshot) then
    begin
      FInsertSnapshot.Position := 0;
      FDMemTable.LoadFromStream(FInsertSnapshot);
    end;
  finally
    FDMemTable.EnableControls;
  end;

  if FDMemTable.Active and (not FDMemTable.IsEmpty) then
    FDMemTable.Last;
end;

{ TFormMain — Field cache helpers }

function TFormMain.CacheDemoFields(ADataSet: TFDMemTable): TDemoFields;
begin
  Result.ID        := ADataSet.FindField(FIELD_ID);
  Result.Name      := ADataSet.FindField(FIELD_NAME);
  Result.BirthDate := ADataSet.FindField(FIELD_BIRTHDATE);
  Result.IsActive  := ADataSet.FindField(FIELD_ISACTIVE);
  Result.Balance   := ADataSet.FindField(FIELD_BALANCE);
  Result.Notes     := ADataSet.FindField(FIELD_NOTES);
  Result.Created   := ADataSet.FindField(FIELD_CREATED);
end;

procedure TFormMain.ValidateRequiredFields(const AFields: TDemoFields);
begin
  if not Assigned(AFields.ID) or not Assigned(AFields.Name) then
    raise Exception.Create('Missing required fields: "ID" and/or "Name"');
end;

{ TFormMain — Lifecycle hooks for the simple insert demo }

procedure TFormMain.InsertRecordsInitialize(Sender: TObject);
begin
  PrepareSimpleInsertUi;
end;

procedure TFormMain.InsertRecordsTerminate(Sender: TObject);
begin
  try
    FinalizeSimpleInsertUi;
    if not FIsClosing then
      LogLine(Format('[Terminate] Elapsed Time: %.3f s', [FElapsedMs / 1000]));
  finally
    FInsertRecordsParams := nil;
  end;
end;

{ TFormMain — Create fields }

procedure TFormMain.btnCreateFieldsClick(Sender: TObject);
begin
  MemoLog.Lines.Clear;

  FDMemTable.DisableControls;
  try
    if FDMemTable.Active then
      FDMemTable.Close;

    FDMemTable.FieldDefs.BeginUpdate;
    try
      FDMemTable.FieldDefs.Clear;
      FDMemTable.FieldDefs.Add(FIELD_ID,        ftGuid);
      FDMemTable.FieldDefs.Add(FIELD_NAME,      ftWideString, 100);
      FDMemTable.FieldDefs.Add(FIELD_BIRTHDATE, ftDate);
      FDMemTable.FieldDefs.Add(FIELD_ISACTIVE,  ftBoolean);
      FDMemTable.FieldDefs.Add(FIELD_BALANCE,   ftCurrency);
      FDMemTable.FieldDefs.Add(FIELD_NOTES,     ftWideMemo);
      FDMemTable.FieldDefs.Add(FIELD_CREATED,   ftDateTime);
    finally
      FDMemTable.FieldDefs.EndUpdate;
    end;

    FDMemTable.CreateDataSet;
    FDMemTable.FieldByName(FIELD_ID).Required := True;
    FDMemTable.FieldByName(FIELD_NAME).Required := True;

    LogLine('Create Fields: Operation finished');
  except
    on E: Exception do
      LogLine('Create Fields: Error detected: ' + E.Message);
  end;
  FDMemTable.EnableControls;
end;

{ TFormMain — Simple Bulk Insert }

procedure TFormMain.btnInsertRecordsClick(Sender: TObject);
var
  LParams   : ISafeThread4DParams;
  LParamsRaw: Pointer;
begin
  if Assigned(FInsertRecordsParams) then
    Exit;

  // NOTE:
  // This example keeps direct worker writes into the UI-bound TFDMemTable as a
  // demo/contrast path. FireDAC does not guarantee thread-safety for this.
  // The recommended pattern in this unit is btnInsertRecordsPauseResumeClick.
  LParams :=
    TSafeThread4DParams.New
      .SetThreadName('Insert-Records')
      .SetMeasureTime(True)
      .SetFreeOnTerminate(True)
      .SetHeartbeatIntervalMs(INSERT_HEARTBEAT_MS)
      .SetOnHeartbeat(
        procedure
        begin
          UpdateHeartbeatLabel(lblInsertRecordsStatus, False);
        end)
      .SetOnInitializeEvent(InsertRecordsInitialize)
      .SetOnProgress(
        procedure(APct: Single)
        begin
          SetProgressUi(pbarInsertRecords, lblPercentageInsertRecords, APct);
        end)
      .SetProgressIntervalMs(INSERT_PROGRESS_MS)
      .SetOnTerminate(
        procedure(AContext: TThreadContext)
        begin
          FElapsedMs := AContext.ElapsedMilliseconds;
        end)
      .SetOnTerminateEvent(InsertRecordsTerminate)
      .SetOnSuccess(
        procedure(AContext: TThreadContext)
        begin
          SetProgressUi(pbarInsertRecords, lblPercentageInsertRecords, 1.0);
          LogLine('[Success] Insertion completed');
        end)
      .SetOnError(
        procedure(const AErrorMessage: string; const AContext: TThreadContext)
        begin
          LogLine('[Error] ' + AErrorMessage);
        end)
      .SetOnCancel(
        procedure(AContext: TThreadContext)
        begin
          LogLine('[Cancel] Insert operation canceled by user');
        end)
      .SetCompleteWithError(True)
      {$IFDEF MSWINDOWS}
      .SetThreadPriority(PriorityHigher)
      {$ENDIF}
      .SetOnExecute(
        procedure(AContext: TThreadContext)
        var
          I: Integer;
          LTotalRecords: Integer;
          LStep: Integer;
          LHadIndexes: Boolean;
          LParams: ISafeThread4DParams;
          LFields: TDemoFields;
        begin
          LParams := ISafeThread4DParams(IInterface(LParamsRaw));
          if LParams = nil then
            raise Exception.Create('Internal error: ParamsRaw not initialized.');

          LTotalRecords := INSERT_TOTAL_RECORDS;
          LStep := Max(1, LTotalRecords div 10);

          TSafeThread4D.CheckCancel(LParams, AContext);

          LFields := CacheDemoFields(FDMemTable);
          ValidateRequiredFields(LFields);

          LHadIndexes := FDMemTable.IndexesActive;
          if LHadIndexes then
            FDMemTable.IndexesActive := False;
          FDMemTable.DisableControls;
          try
            FDMemTable.EmptyDataSet;

            for I := 1 to LTotalRecords do
            begin
              // Tighter cancel cadence (every 128 iterations) so cancel is
              // observed quickly during form close.
              if (I and $7F) = 0 then
                TSafeThread4D.CheckCancel(LParams, AContext);

              FDMemTable.Append;
              try
                LFields.ID.AsGuid := TGUID.NewGuid;
                LFields.Name.AsString := 'Taro ' + IntToStr(I);

                if Assigned(LFields.BirthDate) then
                  LFields.BirthDate.AsDateTime := EncodeDate(2024, 1, 1) + I;
                if Assigned(LFields.IsActive) then
                  LFields.IsActive.AsBoolean := (I mod 2 = 0);
                if Assigned(LFields.Balance) then
                  LFields.Balance.AsCurrency := Random * 1000;
                if Assigned(LFields.Notes) then
                  LFields.Notes.AsString := 'This is a memo field for record ' + IntToStr(I);
                if Assigned(LFields.Created) then
                  LFields.Created.AsDateTime := Now - (I mod 365);

                FDMemTable.Post;
              except
                FDMemTable.Cancel;
                raise;
              end;

              if ((I mod LStep) = 0) or (I = LTotalRecords) then
                TSafeThread4D.ReportProgress(LParams, I / LTotalRecords);
            end;
          finally
            FDMemTable.EnableControls;
            if LHadIndexes then
              FDMemTable.IndexesActive := True;
            if FDMemTable.Active and (not FDMemTable.IsEmpty) then
              FDMemTable.Last;
          end;
        end);

  TSafeThread4D.StartThreadWithWeakRef(LParams, LParamsRaw, FInsertRecordsParams);
end;

procedure TFormMain.btnCancelInsertRecordsClick(Sender: TObject);
begin
  if not Assigned(FInsertRecordsParams) then
    Exit;

  LogLine('[User] Cancellation request...');
  FInsertRecordsParams.RequestCancel;
end;

{ TFormMain — Pause/Resume Bulk Insert (recommended pattern) }

procedure TFormMain.btnInsertRecordsPauseResumeClick(Sender: TObject);
var
  LParams   : ISafeThread4DParams;
  LParamsRaw: Pointer;
begin
  if Assigned(FInsertRecordsParams) then
    Exit;

  ClearInsertSnapshot;

  LParams :=
    TSafeThread4DParams.New
      .SetThreadName('Insert-Records-PauseResume')
      .SetMeasureTime(True)
      .SetFreeOnTerminate(True)
      .SetHeartbeatIntervalMs(INSERT_HEARTBEAT_MS)
      .SetOnHeartbeat(
        procedure
        begin
          UpdateHeartbeatLabel(lblInsertRecordsStatus, FInsertRecordsPaused);
        end)
      .SetOnInitialize(
        procedure(AContext: TThreadContext)
        begin
          PreparePauseResumeInsertUi;
        end)
      .SetOnProgress(
        procedure(APct: Single)
        begin
          SetProgressUi(pbarInsertRecords, lblPercentageInsertRecords, APct);
        end)
      .SetProgressIntervalMs(INSERT_PROGRESS_MS)
      .SetTimeoutMs(0)
      .SetOnExecute(
        procedure(AContext: TThreadContext)
        var
          I: Integer;
          LTotalRecords: Integer;
          LStep: Integer;
          LBatchSize: Integer;
          LCurrentBatch: Integer;
          LMem: TFDMemTable;
          LStartTime: TDateTime;
          LRecordsPerSecond: Double;
          LWaitResult: TWaitResult;
          LParams: ISafeThread4DParams;
          LFields: TDemoFields;
        begin
          LParams := ISafeThread4DParams(IInterface(LParamsRaw));
          if LParams = nil then
            raise Exception.Create('Internal error: ParamsRaw not initialized.');

          LMem := TFDMemTable.Create(nil);
          try
            LMem.FieldDefs.Assign(FDMemTable.FieldDefs);
            LMem.CreateDataSet;

            LFields := CacheDemoFields(LMem);
            ValidateRequiredFields(LFields);

            LTotalRecords := INSERT_TOTAL_RECORDS;
            LStep := Max(1, LTotalRecords div 20);
            LBatchSize := INSERT_BATCH_SIZE;
            LCurrentBatch := 0;
            LStartTime := Now;

            TSafeThread4D.CheckCancel(LParams, AContext);

            for I := 1 to LTotalRecords do
            begin
              // Early cancel check — avoids even entering the pause gate if
              // cancel has been requested. Runs every 128 iterations.
              if (I and $7F) = 0 then
                TSafeThread4D.CheckCancel(LParams, AContext);

              // Pause gate — only blocks the worker while paused. When not
              // paused the event is signaled and WaitFor returns immediately.
              repeat
                LWaitResult := FInsertPauseEvent.WaitFor(200);
                if LWaitResult = wrSignaled then
                  Break;
                TSafeThread4D.CheckCancel(LParams, AContext);
              until False;

              LMem.Append;
              try
                LFields.ID.AsGuid := TGUID.NewGuid;
                LFields.Name.AsString := 'Taro ' + IntToStr(I);

                if Assigned(LFields.BirthDate) then
                  LFields.BirthDate.AsDateTime := EncodeDate(2024, 1, 1) + I;
                if Assigned(LFields.IsActive) then
                  LFields.IsActive.AsBoolean := (I mod 2 = 0);
                if Assigned(LFields.Balance) then
                  LFields.Balance.AsCurrency := Random * 1000;
                if Assigned(LFields.Notes) then
                  LFields.Notes.AsString := 'This is a memo field for record ' + IntToStr(I);
                if Assigned(LFields.Created) then
                  LFields.Created.AsDateTime := Now - (I mod 365);

                LMem.Post;
              except
                LMem.Cancel;
                raise;
              end;

              Inc(LCurrentBatch);
              if LCurrentBatch >= LBatchSize then
              begin
                try
                  LMem.MergeChangeLog;
                except
                  LMem.CommitUpdates;
                end;
                LCurrentBatch := 0;
              end;

              if ((I mod LStep) = 0) or (I = LTotalRecords) then
              begin
                TSafeThread4D.ReportProgress(LParams, I / LTotalRecords);
                LRecordsPerSecond := I / ((Now - LStartTime) * SecsPerDay);
                TThread.Queue(nil,
                  TThreadProcedure(
                    procedure
                    begin
                      if Assigned(lblInsertRecordsStatus) then
                        lblInsertRecordsStatus.Text :=
                          Format('Processing: %.0f records/sec', [LRecordsPerSecond]);
                    end));
              end;
            end;

            // Fast-cancel: skip the non-cancellable tail (MergeChangeLog and
            // SaveToStream) when cancel has been requested. These FireDAC
            // operations are opaque and can take seconds on large datasets
            // with memo fields. Since OnSuccess does not run on cancel, the
            // snapshot would be discarded anyway.
            if LParams.CancelRequested then
              Exit;

            if LCurrentBatch > 0 then
            begin
              try
                LMem.MergeChangeLog;
              except
                LMem.CommitUpdates;
              end;
            end;

            FInsertSnapshot := TMemoryStream.Create;
            LMem.SaveToStream(FInsertSnapshot, sfBinary);
            FInsertSnapshot.Position := 0;
          finally
            LMem.Free;
          end;
        end)
      .SetOnSuccess(
        procedure(AContext: TThreadContext)
        begin
          if not FIsClosing then
          begin
            ApplyInsertSnapshotToUi;
            SetProgressUi(pbarInsertRecords, lblPercentageInsertRecords, 1.0);
            LogLine('[Success] Insertion completed successfully');
          end;
          ClearInsertSnapshot;
        end)
      .SetOnError(
        procedure(const AErrorMessage: string; const AContext: TThreadContext)
        begin
          LogLine('[Error] ' + AErrorMessage);
        end)
      .SetOnCancel(
        procedure(AContext: TThreadContext)
        begin
          LogLine('[Cancel] Insert operation canceled by user');
        end)
      .SetOnTimeout(
        procedure(AContext: TThreadContext)
        begin
          LogLine('[Timeout] Operation timed out');
        end)
      .SetOnTerminate(
        procedure(AContext: TThreadContext)
        begin
          try
            FinalizePauseResumeInsertUi;
            if not FIsClosing then
              LogLine(Format('[Terminate] Elapsed Time: %.3f s', [AContext.ElapsedMilliseconds / 1000]));
          finally
            FInsertRecordsParams := nil;
          end;
        end)
      {$IFDEF MSWINDOWS}
      .SetThreadPriority(PriorityHigher)
      {$ENDIF}
      .SetCompleteWithError(True);

  TSafeThread4D.StartThreadWithWeakRef(LParams, LParamsRaw, FInsertRecordsParams);
end;

procedure TFormMain.btnCancelRecordsPauseResumeClick(Sender: TObject);
begin
  if not Assigned(FInsertRecordsParams) then
    Exit;

  btnPauseRecordsPauseResume.Text := 'Pause';
  LogLine('[User] Cancellation requested...');
  FInsertRecordsParams.RequestCancel;
  ReleaseInsertPauseGate;
end;

procedure TFormMain.btnPauseRecordsPauseResumeClick(Sender: TObject);
begin
  if not Assigned(FInsertRecordsParams) then
    Exit;

  FInsertRecordsPaused := not FInsertRecordsPaused;

  if FInsertRecordsPaused then
  begin
    if Assigned(FInsertPauseEvent) then
      FInsertPauseEvent.ResetEvent;
    btnPauseRecordsPauseResume.Text := 'Resume';
    LogLine('[User] Operation paused');
  end
  else
  begin
    ReleaseInsertPauseGate;
    btnPauseRecordsPauseResume.Text := 'Pause';
    LogLine('[User] Operation resumed');
  end;
end;

{ TFormMain — Bulk Update }

procedure TFormMain.btnUpdateRecordsClick(Sender: TObject);
var
  LParams   : ISafeThread4DParams;
  LParamsRaw: Pointer;
begin
  if Assigned(FUpdateRecordsParams) then
    Exit;

  // NOTE:
  // Like the plain Bulk Insert path, this update example touches the
  // UI-bound TFDMemTable from the worker thread. Keep it as a demo/contrast
  // example, not as the recommended production pattern.
  LParams :=
    TSafeThread4DParams.New
      .SetThreadName('Update-Records')
      .SetMeasureTime(True)
      .SetFreeOnTerminate(True)
      .SetHeartbeatIntervalMs(INSERT_HEARTBEAT_MS)
      .SetOnHeartbeat(
        procedure
        begin
          UpdateHeartbeatLabel(lblUpdateRecordsStatus, False);
        end)
      .SetOnInitialize(
        procedure(AContext: TThreadContext)
        begin
          PrepareUpdateUi;
        end)
      .SetOnProgress(
        procedure(APct: Single)
        begin
          SetProgressUi(pbarUpdateRecords, lblPercentageUpdateRecords, APct);
        end)
      .SetProgressIntervalMs(INSERT_PROGRESS_MS)
      .SetOnExecute(
        procedure(AContext: TThreadContext)
        var
          LHadIndexes: Boolean;
          LRecCount: Integer;
          LDone: Integer;
          LStep: Integer;
          LParams: ISafeThread4DParams;
          LFields: TDemoFields;
        begin
          LParams := ISafeThread4DParams(IInterface(LParamsRaw));
          if LParams = nil then
            raise Exception.Create('Internal error: ParamsRaw not initialized.');

          if not FDMemTable.Active then
            raise Exception.Create('Dataset is not active.');

          LRecCount := FDMemTable.RecordCount;
          if LRecCount = 0 then
          begin
            TSafeThread4D.ReportProgress(LParams, 1.0, True);
            Exit;
          end;

          TSafeThread4D.ReportProgress(LParams, 0.0, True);
          LStep := Max(1, LRecCount div 10);
          TSafeThread4D.CheckCancel(LParams, AContext);

          LHadIndexes := FDMemTable.IndexesActive;
          if LHadIndexes then
            FDMemTable.IndexesActive := False;
          FDMemTable.DisableControls;
          try
            LFields := CacheDemoFields(FDMemTable);

            LDone := 0;
            FDMemTable.First;
            while not FDMemTable.Eof do
            begin
              // Tighter cancel cadence (every 128 iterations) so cancel is
              // observed quickly during form close.
              if (LDone and $7F) = 0 then
                TSafeThread4D.CheckCancel(LParams, AContext);

              FDMemTable.Edit;
              if Assigned(LFields.Name) then
                LFields.Name.AsString := LFields.Name.AsString + ' (upd)';
              if Assigned(LFields.IsActive) then
                LFields.IsActive.AsBoolean := not LFields.IsActive.AsBoolean;
              if Assigned(LFields.BirthDate) and (not LFields.BirthDate.IsNull) then
                LFields.BirthDate.AsDateTime := LFields.BirthDate.AsDateTime + 1;
              if Assigned(LFields.Balance) then
                LFields.Balance.AsCurrency := LFields.Balance.AsCurrency + 1.25;
              if Assigned(LFields.Notes) then
                LFields.Notes.AsString := LFields.Notes.AsString + ' | updated';
              if Assigned(LFields.Created) and (not LFields.Created.IsNull) then
                LFields.Created.AsDateTime := Now;
              FDMemTable.Post;

              Inc(LDone);
              if ((LDone mod LStep) = 0) or (LDone = LRecCount) then
                TSafeThread4D.ReportProgress(LParams, LDone / LRecCount);

              FDMemTable.Next;
            end;
          finally
            FDMemTable.EnableControls;
            if LHadIndexes then
              FDMemTable.IndexesActive := True;
          end;
        end)
      .SetOnSuccess(
        procedure(AContext: TThreadContext)
        begin
          SetProgressUi(pbarUpdateRecords, lblPercentageUpdateRecords, 1.0);
          LogLine('[Success] Update completed');
        end)
      .SetOnTerminate(
        procedure(AContext: TThreadContext)
        begin
          try
            FinalizeUpdateUi;
            if not FIsClosing then
              LogLine(Format('[Terminate] Elapsed Time: %.3f s', [AContext.ElapsedMilliseconds / 1000]));
          finally
            FUpdateRecordsParams := nil;
          end;
        end)
      .SetOnError(
        procedure(const AErrorMessage: string; const AContext: TThreadContext)
        begin
          LogLine('[Error] ' + AErrorMessage);
        end)
      .SetOnCancel(
        procedure(AContext: TThreadContext)
        begin
          LogLine('[Cancel] Update canceled');
        end)
      .SetCompleteWithError(False)
      {$IFDEF MSWINDOWS}
      .SetThreadPriority(PriorityHigher)
      {$ENDIF};

  TSafeThread4D.StartThreadWithWeakRef(LParams, LParamsRaw, FUpdateRecordsParams);
end;

procedure TFormMain.btnCancelUpdateRecordsClick(Sender: TObject);
begin
  if not Assigned(FUpdateRecordsParams) then
    Exit;

  LogLine('[User] Cancellation request...');
  FUpdateRecordsParams.RequestCancel;
end;

{ TFormMain — Shutdown }

procedure TFormMain.RequestCancelAll;
  procedure Cancel(var AParams: ISafeThread4DParams; const ATag: string);
  begin
    if not Assigned(AParams) then
      Exit;

    LogLine('[Close] Cancel ' + ATag);
    AParams.RequestCancel;
  end;
begin
  ReleaseInsertPauseGate;
  Cancel(FInsertRecordsParams, 'InsertRecords');
  Cancel(FUpdateRecordsParams, 'UpdateRecords');
end;

function TFormMain.AllReleased: Boolean;
begin
  Result :=
    (FInsertRecordsParams = nil) and
    (FUpdateRecordsParams = nil);
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
    // - During shutdown, workers may already be finished logically but still
    //   be waiting for their marshalled OnTerminate / OnCancel / OnError /
    //   final UI callbacks to run on the main thread.
    // - If the form closes before those callbacks are accepted, params
    //   references may stay alive longer than expected and shutdown appears
    //   to "hang" even though cancellation was already requested.
    //
    // Why CheckSynchronize is used here:
    // - It directly drains the Synchronize queue that TThread uses for
    //   main-thread callback delivery.
    // - Application.ProcessMessages is intentionally NOT used here because
    //   in FMX it does not reliably drain that queue on all platforms
    //   (Android is the most problematic case).
    //
    // This bounded drain makes FormClose much more predictable: it gives the
    // last queued lifecycle callbacks a small, explicit window to finish,
    // then shutdown proceeds.
    CheckSynchronize(10);

    if (TThread.GetTickCount64 - LStartTick >= UInt64(ATimeoutMs)) and (ATimeoutMs > 0) then
    begin
      LogLine('[Close] Timeout waiting for workers to finish');
      Break;
    end;
  end;
end;

procedure TFormMain.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  FIsClosing := True;
  LogLine('=== Application shutting down ===');

  // Surface intentional shutdown progress in the heartbeat labels so the
  // form does not look frozen while the last workers are finishing.
  if Assigned(lblInsertRecordsStatus) then
    lblInsertRecordsStatus.Text := 'Finishing up...';
  if Assigned(lblUpdateRecordsStatus) then
    lblUpdateRecordsStatus.Text := 'Finishing up...';

  // Pragmatic bounded drain during shutdown only.
  // This is extremely useful here because the example relies on marshalled
  // lifecycle callbacks to release its params references deterministically.
  RequestCancelAll;
  DrainUntilReleased(DRAIN_TIMEOUT_MS);

  FreeAndNil(FInsertPauseEvent);
  ClearInsertSnapshot;

  LogLine('=== Shutdown complete ===');
end;

end.
