// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Eduardo P. Araujo
// https://github.com/eduardoparaujo/SafeThread4D

{*
  Unit   : SafeThread.RestSync.Demo.Main
  Purpose: Showcase demo for SafeThread4D 1.0.0 with paged REST
           synchronization, bounded parallel concurrency, and incremental
           TFDMemTable updates on the main thread.

  Part of the SafeThread4D examples.

  Author        : Eduardo P. Araujo
  Created       : 2026-04-26
  Last modified : 2026-04-26
  Version       : 1.0.0

  Notes:
    - Runtime-built UI example by design; no .fmx resource is used.
    - This is intentional: the demo showcases a self-contained visual flow
      built entirely in code.
    - Uses a bootstrap task to fetch total-row metadata before page planning.
    - Uses bounded parallel page jobs with weak + strong startup.
    - Applies rows incrementally to TFDMemTable on the main thread.
    - Uses CheckSynchronize as a bounded host-app shutdown drain during form close.
*}

unit SafeThread.RestSync.Demo.Main;

interface

uses
  Data.Bind.Components,
  Data.Bind.DBScope,
  Data.Bind.EngExt,
  Data.Bind.Grid,
  Data.DB,

  FireDAC.Comp.Client,
  FireDAC.Comp.DataSet,

  FMX.Bind.DBEngExt,
  FMX.Bind.Editors,
  FMX.Bind.Grid,
  FMX.Controls,
  FMX.Controls.Presentation,
  FMX.Forms,
  FMX.Grid,
  FMX.Grid.Style,
  FMX.Layouts,
  FMX.Memo,
  FMX.Memo.Types,
  FMX.Objects,
  FMX.ScrollBox,
  FMX.StdCtrls,
  FMX.Types,

  SafeThread4D,

  System.Bindings.Outputs,
  System.Classes,
  System.Generics.Collections,
  System.JSON,
  System.Math,
  System.Net.HttpClient,
  System.Net.HttpClientComponent,
  System.Net.URLClient,
  System.SysUtils,
  System.Types,
  System.UITypes;

type
  TFormMain = class;
  TRestPageJob = class;

  // Lightweight row DTO for one user record.
  TRestUserRow = class
  public
    ID         : Integer;
    FirstName  : string;
    LastName   : string;
    Email      : string;
    Phone      : string;
    Username   : string;
    CompanyName: string;
  end;

  // Receive-data proxy used to support cooperative cancellation during HTTP
  // transfer and to map network transfer progress into SafeThread4D progress.
  TRestReceiveDataProxy = class
  private
    FParams    : ISafeThread4DParams;
    FRangeStart: Single;
    FRangeEnd  : Single;
  public
    constructor Create(const AParams: ISafeThread4DParams;
      const ARangeStart, ARangeEnd: Single);
    procedure HandleReceiveData(const ASender: TObject;
      AContentLength, AReadCount: Int64; var AAbort: Boolean);
  end;

  // Bridges SafeThread4D's TNotifyEvent termination to PageJobTerminated.
  // Owned by TRestPageJob and released by it in the destructor.
  TPageTerminateProxy = class
  private
    FOwner: TFormMain;
    FJob  : TRestPageJob;
  public
    constructor Create(AOwner: TFormMain; AJob: TRestPageJob);
    procedure HandleTerminate(Sender: TObject);
  end;

  // Per-job state for one page of the REST response.
  TRestPageJob = class
  public
    PageIndex : Integer;
    Skip      : Integer;
    Limit     : Integer;
    Params    : ISafeThread4DParams;
    Proxy     : TPageTerminateProxy;
    Rows      : TObjectList<TRestUserRow>;
    Progress  : Single;
    ElapsedMs : Double;
    Started   : Boolean;
    Finished  : Boolean;
    Succeeded : Boolean;
    Failed    : Boolean;
    Cancelled : Boolean;
    ErrorText : string;

    constructor Create(AOwner: TFormMain; const APageIndex, ASkip, ALimit: Integer);
    destructor Destroy; override;
  end;

  TFormMain = class(TForm)
  private
    { Private declarations }

    // Runtime UI.
    FTopBar      : TLayout;
    FBottomPanel : TLayout;
    btnStartSync : TButton;
    btnCancelSync: TButton;
    lblSyncStatus: TLabel;
    AniIndicator : TAniIndicator;
    pbarSync     : TProgressBar;
    Grid         : TGrid;
    MemoLog      : TMemo;

    // LiveBindings.
    FBindingsList        : TBindingsList;
    FBindSourceDB        : TBindSourceDB;
    FLinkGridToDataSource: TLinkGridToDataSource;

    // Dataset.
    FDMemTable: TFDMemTable;

    // Sync orchestration.
    FBootstrapParams   : ISafeThread4DParams;
    FBootstrapTotal    : Integer;
    FBootstrapProgress : Single;

    FPageJobs          : TObjectList<TRestPageJob>;
    FNextJobIndex      : Integer;
    FActivePages       : Integer;
    FRowsApplied       : Integer;
    FGlobalCancel      : Boolean;
    FIsClosing         : Boolean;

    // Runtime UI helpers.
    procedure BuildRuntimeUI;
    procedure BuildDataset;
    procedure BindGrid;
    procedure ClearGridBindings;
    procedure Log(const AMsg: string);

    // Sync orchestration.
    procedure ResetSyncState;
    procedure BuildPageJobs(const ATotalRows: Integer);
    procedure StartPendingJobs;
    procedure StartPageJob(AJob: TRestPageJob);
    procedure PageJobTerminated(AJob: TRestPageJob);
    procedure ApplyJobRowsToDataset(AJob: TRestPageJob);
    procedure UpdateSyncStatus;

    // HTTP workers.
    procedure FetchUsersMetadata(const AParams: ISafeThread4DParams;
      var AContext: TThreadContext; out ATotal: Integer);
    procedure FetchUsersPage(const AParams: ISafeThread4DParams;
      var AContext: TThreadContext; const ASkip, ALimit: Integer;
      ARows: TObjectList<TRestUserRow>);

    // Lifecycle handlers.
    procedure BootstrapTerminate(Sender: TObject);
    procedure btnStartSyncClick(Sender: TObject);
    procedure btnCancelSyncClick(Sender: TObject);
    procedure FormCloseHandler(Sender: TObject; var Action: TCloseAction);

    // Shutdown.
    procedure RequestCancelAll;
    function  AllReleased: Boolean;
    procedure DrainUntilReleased(const ATimeoutMs: Integer);

  public
    { Public declarations }

    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  Form1: TFormMain;

implementation

const
  // REST endpoint and page tuning.
  USERS_URL          = 'https://dummyjson.com/users';
  PAGE_SIZE          = 10;
  MAX_PARALLEL_PAGES = 3;

  // Shutdown drain policy.
  DRAIN_TIMEOUT_MS = 15_000; // 15 s to close elegantly.

{ JSON helpers }

function JSONStr(AObj: TJSONObject; const AName: string): string;
var
  LValue: TJSONValue;
begin
  Result := '';
  if not Assigned(AObj) then
    Exit;

  LValue := AObj.Values[AName];
  if Assigned(LValue) then
    Result := LValue.Value;
end;

function JSONInt(AObj: TJSONObject; const AName: string;
  const ADefault: Integer = 0): Integer;
var
  LValue: TJSONValue;
begin
  Result := ADefault;
  if not Assigned(AObj) then
    Exit;

  LValue := AObj.Values[AName];
  if Assigned(LValue) then
    Result := StrToIntDef(LValue.Value, ADefault);
end;

{ TRestReceiveDataProxy }

constructor TRestReceiveDataProxy.Create(const AParams: ISafeThread4DParams;
  const ARangeStart, ARangeEnd: Single);
begin
  inherited Create;
  FParams := AParams;
  FRangeStart := ARangeStart;
  FRangeEnd := ARangeEnd;
end;

procedure TRestReceiveDataProxy.HandleReceiveData(const ASender: TObject;
  AContentLength, AReadCount: Int64; var AAbort: Boolean);
var
  LFrac: Double;
  LPct : Single;
begin
  AAbort := Assigned(FParams) and FParams.GetCancelRequested;
  if AAbort then
    Exit;

  if (not Assigned(FParams)) or (AContentLength <= 0) then
    Exit;

  LFrac := AReadCount / AContentLength;
  if LFrac < 0 then
    LFrac := 0
  else if LFrac > 1 then
    LFrac := 1;

  LPct := FRangeStart + Single(LFrac) * (FRangeEnd - FRangeStart);
  TSafeThread4D.ReportProgress(FParams, LPct);
end;

{ TPageTerminateProxy }

constructor TPageTerminateProxy.Create(AOwner: TFormMain; AJob: TRestPageJob);
begin
  inherited Create;
  FOwner := AOwner;
  FJob   := AJob;
end;

procedure TPageTerminateProxy.HandleTerminate(Sender: TObject);
begin
  if Assigned(FOwner) and Assigned(FJob) then
    FOwner.PageJobTerminated(FJob);
end;

{ TRestPageJob }

constructor TRestPageJob.Create(AOwner: TFormMain;
  const APageIndex, ASkip, ALimit: Integer);
begin
  inherited Create;
  PageIndex := APageIndex;
  Skip      := ASkip;
  Limit     := ALimit;
  Progress  := 0;
  Rows      := TObjectList<TRestUserRow>.Create(True);
end;

destructor TRestPageJob.Destroy;
begin
  Params := nil;
  FreeAndNil(Proxy);
  FreeAndNil(Rows);
  inherited;
end;

{ TFormMain — Construction }

constructor TFormMain.Create(AOwner: TComponent);
begin
  // This demo intentionally uses CreateNew and builds the full UI at runtime.
  // The absence of a .fmx file is part of the example design.
  inherited CreateNew(AOwner);
  BuildRuntimeUI;
  BuildDataset;
  BindGrid;
  FPageJobs := TObjectList<TRestPageJob>.Create(True);
  OnClose   := FormCloseHandler;
end;

destructor TFormMain.Destroy;
begin
  ClearGridBindings;
  FreeAndNil(FDMemTable);
  FreeAndNil(FPageJobs);
  inherited;
end;

{ TFormMain — Runtime UI helpers }

procedure TFormMain.BuildRuntimeUI;
var
  LActionRow: TLayout;
begin
  // Runtime-built UI by design:
  // this showcase demonstrates a self-contained visual flow built entirely
  // in code without relying on a .fmx resource.
  Caption  := 'SafeThread4D — REST Sync Showcase';
  Width    := 1060;
  Height   := 760;
  Position := TFormPosition.ScreenCenter;

  FTopBar := TLayout.Create(Self);
  FTopBar.Parent := Self;
  FTopBar.Align := TAlignLayout.Top;
  FTopBar.Height := 160;
  FTopBar.Padding.Rect := RectF(10, 10, 10, 10);

  lblSyncStatus := TLabel.Create(Self);
  lblSyncStatus.Parent := FTopBar;
  lblSyncStatus.Align := TAlignLayout.Top;
  lblSyncStatus.Height := 56;
  lblSyncStatus.TextSettings.WordWrap := True;
  lblSyncStatus.Text := 'Ready';

  pbarSync := TProgressBar.Create(Self);
  pbarSync.Parent := FTopBar;
  pbarSync.Align := TAlignLayout.Bottom;
  pbarSync.Height := 20;
  pbarSync.Margins.Top := 8;
  pbarSync.Min := 0;
  pbarSync.Max := 100;
  pbarSync.Value := 0;

  LActionRow := TLayout.Create(Self);
  LActionRow.Parent := FTopBar;
  LActionRow.Align := TAlignLayout.Client;
  LActionRow.Margins.Top := 8;

  btnStartSync := TButton.Create(Self);
  btnStartSync.Parent := LActionRow;
  btnStartSync.Align := TAlignLayout.Left;
  btnStartSync.Width := 170;
  btnStartSync.Text := 'Start sync';
  btnStartSync.OnClick := btnStartSyncClick;

  btnCancelSync := TButton.Create(Self);
  btnCancelSync.Parent := LActionRow;
  btnCancelSync.Align := TAlignLayout.Left;
  btnCancelSync.Width := 160;
  btnCancelSync.Margins.Left := 8;
  btnCancelSync.Text := 'Cancel sync';
  btnCancelSync.Enabled := False;
  btnCancelSync.OnClick := btnCancelSyncClick;

  AniIndicator := TAniIndicator.Create(Self);
  AniIndicator.Parent := LActionRow;
  AniIndicator.Align := TAlignLayout.Right;
  AniIndicator.Width := 36;
  AniIndicator.Visible := False;
  AniIndicator.Enabled := False;

  FBottomPanel := TLayout.Create(Self);
  FBottomPanel.Parent := Self;
  FBottomPanel.Align := TAlignLayout.Bottom;
  FBottomPanel.Height := 170;
  FBottomPanel.Padding.Rect := RectF(10, 4, 10, 10);

  MemoLog := TMemo.Create(Self);
  MemoLog.Parent := FBottomPanel;
  MemoLog.Align := TAlignLayout.Client;
  MemoLog.Lines.Add('Paged REST synchronization with bounded parallel concurrency.');
  MemoLog.Lines.Add('Each job fetches one page and applies rows to TFDMemTable on the main thread.');
  MemoLog.Lines.Add(Format('Page size = %d   Max parallel pages = %d.',
    [PAGE_SIZE, MAX_PARALLEL_PAGES]));

  Grid := TGrid.Create(Self);
  Grid.Parent := Self;
  Grid.Align := TAlignLayout.Client;
  Grid.Margins.Rect := RectF(10, 0, 10, 0);
  Grid.ReadOnly := True;
  Grid.Stored := False;
end;

procedure TFormMain.BuildDataset;
begin
  FDMemTable := TFDMemTable.Create(Self);
  FDMemTable.FieldDefs.Add('ID',          ftInteger);
  FDMemTable.FieldDefs.Add('FirstName',   ftWideString, 60);
  FDMemTable.FieldDefs.Add('LastName',    ftWideString, 60);
  FDMemTable.FieldDefs.Add('Email',       ftWideString, 120);
  FDMemTable.FieldDefs.Add('Phone',       ftWideString, 40);
  FDMemTable.FieldDefs.Add('Username',    ftWideString, 60);
  FDMemTable.FieldDefs.Add('CompanyName', ftWideString, 120);
  FDMemTable.CreateDataSet;
  FDMemTable.LogChanges := False;
  FDMemTable.IndexFieldNames := 'ID';
end;

procedure TFormMain.ClearGridBindings;
begin
  if Assigned(FLinkGridToDataSource) then
  begin
    FLinkGridToDataSource.GridControl := nil;
    FLinkGridToDataSource.DataSource := nil;
    FreeAndNil(FLinkGridToDataSource);
  end;

  FreeAndNil(FBindingsList);

  if Assigned(FBindSourceDB) then
  begin
    FBindSourceDB.DataSet := nil;
    FreeAndNil(FBindSourceDB);
  end;
end;

procedure TFormMain.BindGrid;
var
  I: Integer;
begin
  ClearGridBindings;

  FBindSourceDB := TBindSourceDB.Create(Self);
  FBindSourceDB.DataSet := FDMemTable;

  FBindingsList := TBindingsList.Create(Self);

  FLinkGridToDataSource := TLinkGridToDataSource.Create(FBindingsList);
  FLinkGridToDataSource.DataSource := FBindSourceDB;
  FLinkGridToDataSource.GridControl := Grid;

  for I := 0 to Grid.ColumnCount - 1 do
    Grid.Columns[I].Width := 130;
end;

procedure TFormMain.Log(const AMsg: string);
begin
  if not Assigned(MemoLog) or (csDestroying in MemoLog.ComponentState) then
    Exit;
  MemoLog.Lines.Add(AMsg);
end;

{ TFormMain — Sync orchestration }

procedure TFormMain.ResetSyncState;
begin
  FGlobalCancel      := False;
  FBootstrapTotal    := 0;
  FBootstrapProgress := 0;
  FRowsApplied       := 0;
  FNextJobIndex      := 0;
  FActivePages       := 0;
  FPageJobs.Clear;

  if FDMemTable.Active then
    FDMemTable.EmptyDataSet;

  pbarSync.Value := 0;
  UpdateSyncStatus;
end;

procedure TFormMain.BuildPageJobs(const ATotalRows: Integer);
var
  LSkip, LPageIndex, LRemaining, LLimit: Integer;
begin
  FPageJobs.Clear;
  FNextJobIndex := 0;
  LSkip := 0;
  LPageIndex := 1;

  while LSkip < ATotalRows do
  begin
    LRemaining := ATotalRows - LSkip;
    LLimit := Min(LRemaining, PAGE_SIZE);
    FPageJobs.Add(TRestPageJob.Create(Self, LPageIndex, LSkip, LLimit));
    Inc(LSkip, PAGE_SIZE);
    Inc(LPageIndex);
  end;
end;

procedure TFormMain.FetchUsersMetadata(const AParams: ISafeThread4DParams;
  var AContext: TThreadContext; out ATotal: Integer);
var
  LClient   : TNetHTTPClient;
  LResponse : IHTTPResponse;
  LJSON     : TJSONValue;
  LProxy    : TRestReceiveDataProxy;
begin
  ATotal  := 0;
  LClient := TNetHTTPClient.Create(nil);
  LProxy  := TRestReceiveDataProxy.Create(AParams, 0.10, 0.85);
  try
    LClient.ConnectionTimeout := 10_000;
    LClient.ResponseTimeout   := 25_000;
    LClient.OnReceiveData     := LProxy.HandleReceiveData;

    TSafeThread4D.CheckCancel(AParams, AContext);
    LResponse := LClient.Get(Format('%s?limit=1&skip=0', [USERS_URL]));
    TSafeThread4D.CheckCancel(AParams, AContext);

    if LResponse.StatusCode <> 200 then
      raise Exception.CreateFmt('Metadata fetch failed (HTTP %d — %s)',
        [LResponse.StatusCode, LResponse.StatusText]);

    LJSON := TJSONObject.ParseJSONValue(
      LResponse.ContentAsString(TEncoding.UTF8));
    try
      if not (LJSON is TJSONObject) then
        raise Exception.Create('Invalid metadata JSON payload.');

      ATotal := JSONInt(TJSONObject(LJSON), 'total', 0);
      if ATotal <= 0 then
        raise Exception.Create('Metadata did not return a valid total.');
    finally
      LJSON.Free;
    end;
  finally
    LProxy.Free;
    LClient.Free;
  end;
end;

procedure TFormMain.FetchUsersPage(const AParams: ISafeThread4DParams;
  var AContext: TThreadContext; const ASkip, ALimit: Integer;
  ARows: TObjectList<TRestUserRow>);
var
  LClient  : TNetHTTPClient;
  LResponse: IHTTPResponse;
  LJSON    : TJSONValue;
  LRoot    : TJSONObject;
  LUsers   : TJSONArray;
  I        : Integer;
  LUser    : TJSONObject;
  LCompany : TJSONObject;
  LRow     : TRestUserRow;
  LProxy   : TRestReceiveDataProxy;
begin
  LClient := TNetHTTPClient.Create(nil);
  LProxy  := TRestReceiveDataProxy.Create(AParams, 0.10, 0.85);
  try
    LClient.ConnectionTimeout := 10_000;
    LClient.ResponseTimeout   := 25_000;
    LClient.OnReceiveData     := LProxy.HandleReceiveData;

    TSafeThread4D.CheckCancel(AParams, AContext);
    LResponse := LClient.Get(
      Format('%s?limit=%d&skip=%d', [USERS_URL, ALimit, ASkip]));
    TSafeThread4D.CheckCancel(AParams, AContext);

    if LResponse.StatusCode <> 200 then
      raise Exception.CreateFmt('Page fetch failed (HTTP %d — %s)',
        [LResponse.StatusCode, LResponse.StatusText]);

    LJSON := TJSONObject.ParseJSONValue(
      LResponse.ContentAsString(TEncoding.UTF8));
    try
      if not (LJSON is TJSONObject) then
        raise Exception.Create('Invalid page JSON payload.');

      LRoot := TJSONObject(LJSON);
      if not (LRoot.Values['users'] is TJSONArray) then
        raise Exception.Create('Users array not found in response.');

      LUsers := TJSONArray(LRoot.Values['users']);
      for I := 0 to LUsers.Count - 1 do
      begin
        if not (LUsers.Items[I] is TJSONObject) then
          Continue;

        LUser := TJSONObject(LUsers.Items[I]);
        LRow := TRestUserRow.Create;
        LRow.ID        := JSONInt(LUser, 'id', 0);
        LRow.FirstName := JSONStr(LUser, 'firstName');
        LRow.LastName  := JSONStr(LUser, 'lastName');
        LRow.Email     := JSONStr(LUser, 'email');
        LRow.Phone     := JSONStr(LUser, 'phone');
        LRow.Username  := JSONStr(LUser, 'username');

        LCompany := nil;
        if LUser.Values['company'] is TJSONObject then
          LCompany := TJSONObject(LUser.Values['company']);

        LRow.CompanyName := JSONStr(LCompany, 'name');
        ARows.Add(LRow);
      end;
    finally
      LJSON.Free;
    end;
  finally
    LProxy.Free;
    LClient.Free;
  end;
end;

procedure TFormMain.StartPendingJobs;
var
  LJob: TRestPageJob;
begin
  while (FActivePages < MAX_PARALLEL_PAGES) and
        (FNextJobIndex < FPageJobs.Count) and
        not FGlobalCancel and not FIsClosing do
  begin
    LJob := FPageJobs[FNextJobIndex];
    Inc(FNextJobIndex);
    StartPageJob(LJob);
  end;

  UpdateSyncStatus;
end;

procedure TFormMain.StartPageJob(AJob: TRestPageJob);
var
  LParams   : ISafeThread4DParams;
  LParamsRaw: Pointer;
begin
  AJob.Proxy := TPageTerminateProxy.Create(Self, AJob);

  LParams :=
    TSafeThread4DParams.New
      .SetThreadName(Format('Sync-Page-%0.2d', [AJob.PageIndex]))
      .SetThreadId(AJob.PageIndex)
      .SetMeasureTime(True)
      .SetFreeOnTerminate(True)
      .SetCompleteWithError(False)
      {$IFDEF MSWINDOWS}
      .SetThreadPriority(PriorityIdle)
      {$ENDIF}
      .SetProgressIntervalMs(60)
      .SetOnInitialize(
        procedure(AContext: TThreadContext)
        begin
          if FIsClosing then
            Exit;

          AJob.Started := True;
          AJob.Progress := 0.02;

          Log(Format('[Init] Page %d (skip=%d, limit=%d)',
            [AJob.PageIndex, AJob.Skip, AJob.Limit]));
          UpdateSyncStatus;
        end)
      .SetOnProgress(
        procedure(APct: Single)
        begin
          if FIsClosing then
            Exit;

          AJob.Progress := APct;
          UpdateSyncStatus;
        end)
      .SetOnSuccess(
        procedure(AContext: TThreadContext)
        begin
          if FIsClosing then
            Exit;

          AJob.Succeeded := True;
          AJob.Progress := 1.0;
          ApplyJobRowsToDataset(AJob);
          Log(Format('[Success] Page %d applied (%d row(s)).',
            [AJob.PageIndex, AJob.Rows.Count]));
        end)
      .SetOnError(
        procedure(const AErrorMessage: string; const AContext: TThreadContext)
        begin
          if FIsClosing then
            Exit;

          AJob.Failed := True;
          AJob.Progress := 1.0;
          AJob.ErrorText := AErrorMessage;
          Log(Format('[Error] Page %d — %s', [AJob.PageIndex, AErrorMessage]));
        end)
      .SetOnCancel(
        procedure(AContext: TThreadContext)
        begin
          if FIsClosing then
            Exit;

          AJob.Cancelled := True;
          AJob.Progress := 1.0;
          Log(Format('[Cancel] Page %d cancelled.', [AJob.PageIndex]));
        end)
      .SetOnTerminate(
        procedure(AContext: TThreadContext)
        begin
          AJob.ElapsedMs := AContext.ElapsedMilliseconds;
        end)
      .SetOnTerminateEvent(AJob.Proxy.HandleTerminate)
      .SetOnExecute(
        procedure(AContext: TThreadContext)
        var
          LParams: ISafeThread4DParams;
        begin
          LParams := ISafeThread4DParams(IInterface(LParamsRaw));
          if LParams = nil then
            raise Exception.Create('Internal error: ParamsRaw not initialized.');

          TSafeThread4D.CheckCancel(LParams, AContext);
          TSafeThread4D.ReportProgress(LParams, 0.05, True);

          TThread.Synchronize(nil,
            procedure
            begin
              if FIsClosing then
                Exit;
              Log(Format('[Page %d] Opening request...', [AJob.PageIndex]));
            end);

          FetchUsersPage(LParams, AContext, AJob.Skip, AJob.Limit, AJob.Rows);

          TSafeThread4D.CheckCancel(LParams, AContext);
          TSafeThread4D.ReportProgress(LParams, 0.90);

          TThread.Synchronize(nil,
            procedure
            begin
              if FIsClosing then
                Exit;
              Log(Format('[Page %d] Downloaded %d row(s).',
                [AJob.PageIndex, AJob.Rows.Count]));
            end);

          TSafeThread4D.CheckCancel(LParams, AContext);
          TSafeThread4D.ReportProgress(LParams, 1.0, True);
        end);

  try
    TSafeThread4D.StartThreadWithWeakRef(LParams, LParamsRaw, AJob.Params);
    Inc(FActivePages);
    UpdateSyncStatus;
  except
    on E: Exception do
    begin
      AJob.Params := nil;
      FreeAndNil(AJob.Proxy);
      raise;
    end;
  end;
end;

procedure TFormMain.ApplyJobRowsToDataset(AJob: TRestPageJob);
var
  LRow: TRestUserRow;
begin
  FDMemTable.DisableControls;
  try
    for LRow in AJob.Rows do
    begin
      FDMemTable.Append;
      try
        FDMemTable.FieldByName('ID').AsInteger := LRow.ID;
        FDMemTable.FieldByName('FirstName').AsString := LRow.FirstName;
        FDMemTable.FieldByName('LastName').AsString := LRow.LastName;
        FDMemTable.FieldByName('Email').AsString := LRow.Email;
        FDMemTable.FieldByName('Phone').AsString := LRow.Phone;
        FDMemTable.FieldByName('Username').AsString := LRow.Username;
        FDMemTable.FieldByName('CompanyName').AsString := LRow.CompanyName;
        FDMemTable.Post;
      except
        FDMemTable.Cancel;
        raise;
      end;

      Inc(FRowsApplied);
    end;
  finally
    FDMemTable.EnableControls;
  end;
end;

procedure TFormMain.PageJobTerminated(AJob: TRestPageJob);
begin
  if AJob.Finished then
    Exit;

  AJob.Finished := True;
  AJob.Params   := nil;
  AJob.Progress := 1.0;

  if FActivePages > 0 then
    Dec(FActivePages);

  if not FIsClosing then
    Log(Format('[Terminate] Page %d — %.3f s',
      [AJob.PageIndex, AJob.ElapsedMs / 1000]));

  if not FGlobalCancel and not FIsClosing then
    StartPendingJobs
  else
    UpdateSyncStatus;
end;

procedure TFormMain.UpdateSyncStatus;
var
  LQueued, LRunning, LDone, LError, LCancelled: Integer;
  LJob: TRestPageJob;
  LProgressSum: Double;
  LPct: Double;
begin
  if FIsClosing then
    Exit;

  LQueued := 0;
  LRunning := 0;
  LDone := 0;
  LError := 0;
  LCancelled := 0;
  LProgressSum := 0;

  if Assigned(FBootstrapParams) and (FPageJobs.Count = 0) then
  begin
    pbarSync.Value := FBootstrapProgress * 100;
    lblSyncStatus.Text := Format(
      'Loading metadata... %.0f%%',
      [FBootstrapProgress * 100]);

    btnCancelSync.Enabled := True;
    btnStartSync.Enabled  := False;
    AniIndicator.Visible  := True;
    AniIndicator.Enabled  := True;
    Exit;
  end;

  for LJob in FPageJobs do
  begin
    if Assigned(LJob.Params) then
      Inc(LRunning)
    else if LJob.Succeeded then
      Inc(LDone)
    else if LJob.Failed then
      Inc(LError)
    else if LJob.Cancelled then
      Inc(LCancelled)
    else
      Inc(LQueued);

    LProgressSum := LProgressSum + LJob.Progress;
  end;

  LPct := 0;
  if FPageJobs.Count > 0 then
    LPct := LProgressSum / FPageJobs.Count;

  pbarSync.Value := LPct * 100;
  lblSyncStatus.Text := Format(
    'Pages — queued: %d   running: %d   done: %d   error: %d   cancelled: %d' +
    '   rows applied: %d   total rows: %d',
    [LQueued, LRunning, LDone, LError, LCancelled,
     FRowsApplied, FBootstrapTotal]);

  btnCancelSync.Enabled := (LRunning > 0) or Assigned(FBootstrapParams);
  btnStartSync.Enabled := (LRunning = 0) and (not Assigned(FBootstrapParams)) and not FIsClosing;
  AniIndicator.Visible := btnCancelSync.Enabled;
  AniIndicator.Enabled := btnCancelSync.Enabled;
end;

{ TFormMain — Bootstrap }

procedure TFormMain.BootstrapTerminate(Sender: TObject);
begin
  FBootstrapParams := nil;
  FBootstrapProgress := 0;

  if not FIsClosing then
    UpdateSyncStatus;
end;

procedure TFormMain.btnStartSyncClick(Sender: TObject);
var
  LParams   : ISafeThread4DParams;
  LParamsRaw: Pointer;
begin
  if FIsClosing then
    Exit;

  if Assigned(FBootstrapParams) or (FActivePages > 0) then
  begin
    Log('[Info] A sync batch is already running.');
    Exit;
  end;

  ResetSyncState;
  Log('[Start] Requesting metadata to determine total rows...');

  LParams :=
    TSafeThread4DParams.New
      .SetThreadName('Sync-Bootstrap')
      .SetThreadId(1)
      .SetMeasureTime(True)
      .SetFreeOnTerminate(True)
      .SetCompleteWithError(False)
      {$IFDEF MSWINDOWS}
      .SetThreadPriority(PriorityIdle)
      {$ENDIF}
      .SetProgressIntervalMs(50)
      .SetOnInitialize(
        procedure(AContext: TThreadContext)
        begin
          if FIsClosing then
            Exit;

          FBootstrapProgress := 0.02;
          lblSyncStatus.Text := 'Loading metadata...';
          UpdateSyncStatus;
        end)
      .SetOnProgress(
        procedure(APct: Single)
        begin
          if FIsClosing then
            Exit;

          FBootstrapProgress := APct;
          UpdateSyncStatus;
        end)
      .SetOnSuccess(
        procedure(AContext: TThreadContext)
        begin
          if FIsClosing then
            Exit;

          BuildPageJobs(FBootstrapTotal);
          Log(Format('[Metadata] Total rows = %d. Pages planned = %d.',
            [FBootstrapTotal, FPageJobs.Count]));
          StartPendingJobs;
        end)
      .SetOnError(
        procedure(const AErrorMessage: string; const AContext: TThreadContext)
        begin
          if FIsClosing then
            Exit;

          Log('[Error] Bootstrap failed — ' + AErrorMessage);
        end)
      .SetOnCancel(
        procedure(AContext: TThreadContext)
        begin
          if FIsClosing then
            Exit;

          Log('[Cancel] Bootstrap cancelled.');
        end)
      .SetOnTerminateEvent(BootstrapTerminate)
      .SetOnExecute(
        procedure(AContext: TThreadContext)
        var
          LParams: ISafeThread4DParams;
          LTotal : Integer;
        begin
          LParams := ISafeThread4DParams(IInterface(LParamsRaw));
          if LParams = nil then
            raise Exception.Create('Internal error: ParamsRaw not initialized.');

          TSafeThread4D.CheckCancel(LParams, AContext);
          TSafeThread4D.ReportProgress(LParams, 0.05, True);
          FetchUsersMetadata(LParams, AContext, LTotal);
          TSafeThread4D.CheckCancel(LParams, AContext);

          FBootstrapTotal := LTotal;
          TSafeThread4D.ReportProgress(LParams, 1.0, True);
        end);

  TSafeThread4D.StartThreadWithWeakRef(LParams, LParamsRaw, FBootstrapParams);
  UpdateSyncStatus;
end;

procedure TFormMain.btnCancelSyncClick(Sender: TObject);
begin
  RequestCancelAll;
end;

{ TFormMain — Shutdown }

procedure TFormMain.RequestCancelAll;
var
  LJob: TRestPageJob;
begin
  FGlobalCancel := True;

  if Assigned(FBootstrapParams) then
    FBootstrapParams.RequestCancel;

  for LJob in FPageJobs do
  begin
    if Assigned(LJob.Params) then
      LJob.Params.RequestCancel
    else if not LJob.Started and not LJob.Finished then
    begin
      LJob.Cancelled := True;
      LJob.Finished := True;
      LJob.Progress := 1.0;
    end;
  end;

  if not FIsClosing then
    Log('[Cancel] Global cancel requested.');

  UpdateSyncStatus;
end;

function TFormMain.AllReleased: Boolean;
var
  LJob: TRestPageJob;
begin
  if Assigned(FBootstrapParams) then
    Exit(False);

  for LJob in FPageJobs do
    if Assigned(LJob.Params) then
      Exit(False);

  Result := True;
end;

procedure TFormMain.DrainUntilReleased(const ATimeoutMs: Integer);
(*
  Bounded UI-thread drain used only during form shutdown.

  Why this is useful
  - During shutdown, the bootstrap task or page jobs may already be finished
    logically but still be waiting for their marshalled OnTerminate / OnCancel /
    OnError / final UI callbacks to run on the main thread.
  - If those callbacks do not run, params references remain published and the
    close sequence can appear to hang even though cancellation has already
    propagated.

  Why CheckSynchronize is used
  - It is the RTL API intended to drain pending Synchronize / Queue work.
  - This example intentionally does not rely on Application.ProcessMessages
    as a drain mechanism in FMX.

  Scope
  - This is host-app shutdown policy only.
  - It is not a recommendation for normal UI flow.
*)
var
  LStart: UInt64;
begin
  LStart := TThread.GetTickCount64;
  while not AllReleased do
  begin
    CheckSynchronize(10);

    if (ATimeoutMs > 0) and
       (TThread.GetTickCount64 - LStart >= UInt64(ATimeoutMs)) then
    begin
      Log('[Close] Drain timeout — proceeding with shutdown.');
      Break;
    end;
  end;
end;

procedure TFormMain.FormCloseHandler(Sender: TObject; var Action: TCloseAction);
(*
  Close-time drain policy.

  This example intentionally uses a bounded shutdown drain so the last queued
  lifecycle callbacks can finish before the runtime-built form disappears.

  Why this is especially useful here
  - The demo has one bootstrap task followed by bounded parallel page jobs.
  - Those tasks publish state back to the UI and release their params
    references through marshalled termination callbacks.
  - A short shutdown drain makes the final publication phase much more
    predictable and avoids leaving the form looking frozen during close.

  This is host-app shutdown policy only, not a recommendation for normal UI flow.
*)
begin
  FIsClosing := True;
  Log('=== Shutting down ===');
  RequestCancelAll;
  DrainUntilReleased(DRAIN_TIMEOUT_MS);
  Log('=== Shutdown complete ===');
end;

end.
