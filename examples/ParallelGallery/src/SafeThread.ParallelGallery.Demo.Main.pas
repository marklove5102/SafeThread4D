// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Eduardo P. Araujo
// https://github.com/eduardoparaujo/SafeThread4D

{*
  Unit   : SafeThread.ParallelGallery.Demo.Main
  Purpose: Showcase demo for SafeThread4D 1.0.0 with bounded parallel image
           downloads, real HTTP transfer progress, and adaptive runtime UI.

  Part of the SafeThread4D examples.

  Author        : Eduardo P. Araujo
  Created       : 2026-04-26
  Last modified : 2026-04-26
  Version       : 1.0.0

  Notes:
    - Runtime-built UI example by design; no .fmx resource is used.
    - This is intentional: the demo showcases adaptive layout logic,
      dynamic card creation, and a self-contained visual flow built entirely
      in code.
    - Bounded parallel downloads with visible queued/running/done counts.
    - Real progress during HTTP transfer via TNetHTTPClient.OnReceiveData.
    - Uses the weak + strong startup pattern to avoid retain cycles.
    - Uses CheckSynchronize as a bounded host-app shutdown drain during form
      close.
*}

unit SafeThread.ParallelGallery.Demo.Main;

interface

uses
  FMX.Controls,
  FMX.Controls.Presentation,
  FMX.Forms,
  FMX.Graphics,
  FMX.Layouts,
  FMX.Memo,
  FMX.Memo.Types,
  FMX.Objects,
  FMX.ScrollBox,
  FMX.StdCtrls,
  FMX.Types,

  SafeThread4D,

  System.Classes,
  System.Generics.Collections,
  System.Net.HttpClient,
  System.Net.HttpClientComponent,
  System.Net.URLClient,
  System.SysUtils,
  System.Types,
  System.UITypes;

type
  TFormParallelGallery = class;
  TImageDownloadJob = class;

  TResponsiveMode = (rmMobile, rmTablet, rmDesktop);

  TJobTerminateProxy = class
  private
    FOwner: TFormParallelGallery;
    FJob  : TImageDownloadJob;
  public
    constructor Create(AOwner: TFormParallelGallery; AJob: TImageDownloadJob);
    procedure HandleTerminate(Sender: TObject);
  end;

  TDownloadProgressProxy = class
  private
    FParams    : ISafeThread4DParams;
    FRangeStart: Single;
    FRangeEnd  : Single;
  public
    constructor Create(const AParams: ISafeThread4DParams; const ARangeStart,
      ARangeEnd: Single);
    procedure HandleReceiveData(const ASender: TObject; AContentLength,
      AReadCount: Int64; var AAbort: Boolean);
  end;

  TImageDownloadJob = class
  public
    Index          : Integer;
    ObjectKey      : string;
    Url            : string;
    Params         : ISafeThread4DParams;
    Proxy          : TJobTerminateProxy;
    Bitmap         : TBitmap;
    PhaseMs        : Double;
    ElapsedMs      : Double;
    BytesDownloaded: Int64;
    Started        : Boolean;
    Finished       : Boolean;
    Cancelled      : Boolean;
    Failed         : Boolean;
    Succeeded      : Boolean;

    Card       : TRectangle;
    Thumbnail  : TImage;
    RightPanel : TLayout;
    TitleLabel : TLabel;
    StatusLabel: TLabel;
    ProgressBar: TProgressBar;

    constructor Create(AOwner: TFormParallelGallery; AParent: TFmxObject;
      const AIndex: Integer; const AObjectKey, AUrl: string);
    destructor Destroy; override;

    procedure SetStatus(const AText: string; const AProgress: Single = -1);
  end;

  TFormParallelGallery = class(TForm)
  private
    { Private declarations }

    // Runtime UI.
    FTopBar         : TLayout;
    FBottomPanel    : TLayout;
    btnStartGallery : TButton;
    btnCancelGallery: TButton;
    lblGalleryStatus: TLabel;
    AniIndicator    : TAniIndicator;
    ScrollBox       : TVertScrollBox;
    MemoLog         : TMemo;

    // Job orchestration.
    FJobs           : TObjectList<TImageDownloadJob>;
    FNextJobIndex   : Integer;
    FActiveDownloads: Integer;
    FGlobalCancel   : Boolean;
    FIsClosing      : Boolean;

    // Runtime UI helpers.
    procedure BuildRuntimeUI;
    procedure BuildDemoObjectList;
    procedure ClearJobs;
    procedure Log(const AMsg: string);

    // Responsive layout.
    function  GetResponsiveMode: TResponsiveMode;
    procedure ApplyResponsiveLayout;
    procedure ApplyJobLayout(AJob: TImageDownloadJob; const AMode: TResponsiveMode);

    // Job lifecycle.
    procedure StartPendingJobs;
    procedure StartJob(AJob: TImageDownloadJob);
    procedure JobTerminated(AJob: TImageDownloadJob);
    procedure UpdateGalleryStatus;

    // HTTP worker.
    procedure FetchImageToBitmap(const AUrl: string;
      const AParams: ISafeThread4DParams;
      var AContext: TThreadContext;
      out ABitmap: TBitmap;
      out ABytesDownloaded: Int64;
      out AElapsedMs: Double);

    // Lifecycle handlers.
    procedure btnStartGalleryClick(Sender: TObject);
    procedure btnCancelGalleryClick(Sender: TObject);
    procedure FormCloseHandler(Sender: TObject; var Action: TCloseAction);
    procedure FormResizeHandler(Sender: TObject);

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
  FormParallelGallery: TFormParallelGallery;

implementation

const
  // Bounded parallel download policy.
  MAX_PARALLEL_DOWNLOADS = 10;
  TOTAL_DEMO_IMAGES      = 50;

  // Responsive breakpoints.
  BP_MOBILE_MAX = 480;
  BP_TABLET_MAX = 900;

  // Shutdown drain policy.
  DRAIN_TIMEOUT_MS = 15_000; // 15 s to close elegantly.

{ TJobTerminateProxy }

constructor TJobTerminateProxy.Create(AOwner: TFormParallelGallery;
  AJob: TImageDownloadJob);
begin
  inherited Create;
  FOwner := AOwner;
  FJob   := AJob;
end;

procedure TJobTerminateProxy.HandleTerminate(Sender: TObject);
begin
  if Assigned(FOwner) and Assigned(FJob) then
    FOwner.JobTerminated(FJob);
end;

{ TDownloadProgressProxy }

constructor TDownloadProgressProxy.Create(const AParams: ISafeThread4DParams;
  const ARangeStart, ARangeEnd: Single);
begin
  inherited Create;
  FParams     := AParams;
  FRangeStart := ARangeStart;
  FRangeEnd   := ARangeEnd;
end;

procedure TDownloadProgressProxy.HandleReceiveData(const ASender: TObject;
  AContentLength, AReadCount: Int64; var AAbort: Boolean);
var
  LFrac: Double;
  LPct : Single;
begin
  AAbort := Assigned(FParams) and FParams.GetCancelRequested;

  if (not Assigned(FParams)) or (AContentLength <= 0) then
    Exit;

  LFrac := AReadCount / AContentLength;
  if LFrac < 0 then LFrac := 0;
  if LFrac > 1 then LFrac := 1;

  LPct := FRangeStart + Single(LFrac) * (FRangeEnd - FRangeStart);
  TSafeThread4D.ReportProgress(FParams, LPct);
end;

{ TImageDownloadJob }

constructor TImageDownloadJob.Create(AOwner: TFormParallelGallery;
  AParent: TFmxObject; const AIndex: Integer; const AObjectKey, AUrl: string);
begin
  inherited Create;
  Index     := AIndex;
  ObjectKey := AObjectKey;
  Url       := AUrl;

  Card := TRectangle.Create(AOwner);
  Card.Parent  := AParent;
  Card.Align   := TAlignLayout.Top;
  Card.Height  := 210;
  Card.Margins.Rect := RectF(8, 8, 8, 0);
  Card.XRadius := 10;
  Card.YRadius := 10;
  Card.Fill.Color   := $FFF7F7F7;
  Card.Stroke.Color := $FFD0D0D0;

  Thumbnail := TImage.Create(Card);
  Thumbnail.Parent   := Card;
  Thumbnail.Align    := TAlignLayout.Left;
  Thumbnail.Width    := 260;
  Thumbnail.Margins.Rect := RectF(10, 10, 10, 10);
  Thumbnail.WrapMode := TImageWrapMode.Fit;
  Thumbnail.Bitmap.Clear(TAlphaColors.Null);

  RightPanel := TLayout.Create(Card);
  RightPanel.Parent := Card;
  RightPanel.Align  := TAlignLayout.Client;
  RightPanel.Margins.Rect := RectF(0, 10, 10, 10);

  TitleLabel := TLabel.Create(Card);
  TitleLabel.Parent := RightPanel;
  TitleLabel.Align  := TAlignLayout.Top;
  TitleLabel.Height := 48;
  TitleLabel.TextSettings.WordWrap := True;
  TitleLabel.TextSettings.Font.Size := 14;
  TitleLabel.Text := Format('%d. %s', [Index, ObjectKey]);

  StatusLabel := TLabel.Create(Card);
  StatusLabel.Parent := RightPanel;
  StatusLabel.Align  := TAlignLayout.Top;
  StatusLabel.Height := 66;
  StatusLabel.Margins.Top := 6;
  StatusLabel.TextSettings.WordWrap := True;
  StatusLabel.Text := 'Queued';

  ProgressBar := TProgressBar.Create(Card);
  ProgressBar.Parent := RightPanel;
  ProgressBar.Align  := TAlignLayout.Top;
  ProgressBar.Height := 24;
  ProgressBar.Margins.Top := 8;
  ProgressBar.Min   := 0;
  ProgressBar.Max   := 100;
  ProgressBar.Value := 0;
end;

destructor TImageDownloadJob.Destroy;
begin
  Params := nil;
  FreeAndNil(Bitmap);
  FreeAndNil(Proxy);
  FreeAndNil(Card);
  inherited;
end;

procedure TImageDownloadJob.SetStatus(const AText: string;
  const AProgress: Single);
begin
  if Assigned(StatusLabel) then
    StatusLabel.Text := AText;
  if Assigned(ProgressBar) and (AProgress >= 0) then
    ProgressBar.Value := AProgress * 100;
end;

{ TFormParallelGallery — Construction }

constructor TFormParallelGallery.Create(AOwner: TComponent);
begin
  // This demo intentionally uses CreateNew and builds the full UI at runtime.
  // The absence of a .fmx file is part of the example design.
  inherited CreateNew(AOwner);
  BuildRuntimeUI;
  FJobs    := TObjectList<TImageDownloadJob>.Create(True);
  OnClose  := FormCloseHandler;
  OnResize := FormResizeHandler;
  ApplyResponsiveLayout;
end;

destructor TFormParallelGallery.Destroy;
begin
  ClearJobs;
  FreeAndNil(FJobs);
  inherited;
end;

{ TFormParallelGallery — Runtime UI helpers }

procedure TFormParallelGallery.BuildRuntimeUI;
begin
  // Runtime-built UI by design:
  // this showcase demonstrates responsive layout and dynamic card creation
  // without relying on a .fmx resource.
  Caption  := 'SafeThread4D — Parallel Gallery Showcase';
  Width    := 980;
  Height   := 760;
  Position := TFormPosition.ScreenCenter;

  FTopBar        := TLayout.Create(Self);
  FTopBar.Parent := Self;
  FTopBar.Align  := TAlignLayout.Top;
  FTopBar.Height := 64;
  FTopBar.Padding.Rect := RectF(10, 10, 10, 6);

  btnCancelGallery := TButton.Create(Self);
  btnCancelGallery.Parent   := FTopBar;
  btnCancelGallery.Align    := TAlignLayout.Left;
  btnCancelGallery.Width    := 160;
  btnCancelGallery.Margins.Left := 8;
  btnCancelGallery.Text     := 'Cancel all';
  btnCancelGallery.Enabled  := False;
  btnCancelGallery.OnClick  := btnCancelGalleryClick;

  btnStartGallery := TButton.Create(Self);
  btnStartGallery.Parent   := FTopBar;
  btnStartGallery.Align    := TAlignLayout.Left;
  btnStartGallery.Width    := 170;
  btnStartGallery.Text     := 'Start gallery demo';
  btnStartGallery.OnClick  := btnStartGalleryClick;

  AniIndicator := TAniIndicator.Create(Self);
  AniIndicator.Parent  := FTopBar;
  AniIndicator.Align   := TAlignLayout.Right;
  AniIndicator.Width   := 36;
  AniIndicator.Visible := False;
  AniIndicator.Enabled := False;

  lblGalleryStatus := TLabel.Create(Self);
  lblGalleryStatus.Parent := FTopBar;
  lblGalleryStatus.Align  := TAlignLayout.Client;
  lblGalleryStatus.Margins.Left := 12;
  lblGalleryStatus.TextSettings.WordWrap := True;
  lblGalleryStatus.Text := 'Ready';

  FBottomPanel := TLayout.Create(Self);
  FBottomPanel.Parent := Self;
  FBottomPanel.Align  := TAlignLayout.Bottom;
  FBottomPanel.Height := 180;
  FBottomPanel.Padding.Rect := RectF(10, 4, 10, 10);

  MemoLog := TMemo.Create(Self);
  MemoLog.Parent := FBottomPanel;
  MemoLog.Align  := TAlignLayout.Client;
  MemoLog.Lines.Add('Parallel gallery download — bounded concurrency via SafeThread4D.');
  MemoLog.Lines.Add('Each card represents one remote image. The scroll box stays interactive throughout.');
  MemoLog.Lines.Add('Try scrolling while downloads are running — the UI remains responsive.');
  MemoLog.Lines.Add(Format('Max parallel downloads: %d   Total images: %d.',
    [MAX_PARALLEL_DOWNLOADS, TOTAL_DEMO_IMAGES]));

  ScrollBox := TVertScrollBox.Create(Self);
  ScrollBox.Parent := Self;
  ScrollBox.Align  := TAlignLayout.Client;
  ScrollBox.Padding.Rect := RectF(6, 0, 6, 6);
end;

procedure TFormParallelGallery.BuildDemoObjectList;
var
  I: Integer;
begin
  ClearJobs;
  for I := 1 to TOTAL_DEMO_IMAGES do
    FJobs.Add(TImageDownloadJob.Create(
      Self, ScrollBox.Content, I,
      Format('workorder/demo/photos/img_%0.3d.jpg', [I]),
      Format('https://picsum.photos/seed/st4d_%d/1024/768', [I])));
  FNextJobIndex := 0;
  ApplyResponsiveLayout;
  UpdateGalleryStatus;
end;

procedure TFormParallelGallery.ClearJobs;
begin
  if Assigned(FJobs) then
    FJobs.Clear;

  FNextJobIndex    := 0;
  FActiveDownloads := 0;
  FGlobalCancel    := False;

  if Assigned(ScrollBox) then
    ScrollBox.ViewportPosition := PointF(0, 0);

  if Assigned(lblGalleryStatus) then
    lblGalleryStatus.Text := 'Ready';

  if Assigned(btnCancelGallery) then
  begin
    btnCancelGallery.Enabled := False;
    btnCancelGallery.Text := 'Cancel all';
  end;

  if Assigned(btnStartGallery) then
    btnStartGallery.Enabled := not FIsClosing;

  if Assigned(AniIndicator) then
  begin
    AniIndicator.Visible := False;
    AniIndicator.Enabled := False;
  end;
end;

procedure TFormParallelGallery.Log(const AMsg: string);
begin
  if not Assigned(MemoLog) or (csDestroying in MemoLog.ComponentState) then
    Exit;
  MemoLog.Lines.Add(AMsg);
end;

{ TFormParallelGallery — Responsive layout }

function TFormParallelGallery.GetResponsiveMode: TResponsiveMode;
begin
  if ClientWidth <= BP_MOBILE_MAX then Result := rmMobile
  else if ClientWidth <= BP_TABLET_MAX then Result := rmTablet
  else Result := rmDesktop;
end;

procedure TFormParallelGallery.ApplyJobLayout(AJob: TImageDownloadJob;
  const AMode: TResponsiveMode);
begin
  if not Assigned(AJob) then Exit;

  case AMode of
    rmMobile:
      begin
        AJob.Card.Height := 360;
        AJob.Card.Margins.Rect := RectF(6, 6, 6, 0);
        AJob.Thumbnail.Align   := TAlignLayout.Top;
        AJob.Thumbnail.Height  := 180;
        AJob.Thumbnail.Width   := 0;
        AJob.Thumbnail.Margins.Rect := RectF(10, 10, 10, 6);
        AJob.RightPanel.Align  := TAlignLayout.Client;
        AJob.RightPanel.Margins.Rect := RectF(10, 0, 10, 10);
        AJob.TitleLabel.Height := 52;
        AJob.TitleLabel.TextSettings.Font.Size := 13;
        AJob.StatusLabel.Height := 78;
        AJob.StatusLabel.TextSettings.Font.Size := 12;
        AJob.ProgressBar.Height := 26;
      end;
    rmTablet:
      begin
        AJob.Card.Height := 190;
        AJob.Card.Margins.Rect := RectF(8, 8, 8, 0);
        AJob.Thumbnail.Align   := TAlignLayout.Left;
        AJob.Thumbnail.Width   := 210;
        AJob.Thumbnail.Height  := 0;
        AJob.Thumbnail.Margins.Rect := RectF(10, 10, 10, 10);
        AJob.RightPanel.Align  := TAlignLayout.Client;
        AJob.RightPanel.Margins.Rect := RectF(0, 10, 10, 10);
        AJob.TitleLabel.Height := 44;
        AJob.TitleLabel.TextSettings.Font.Size := 13;
        AJob.StatusLabel.Height := 60;
        AJob.StatusLabel.TextSettings.Font.Size := 12;
        AJob.ProgressBar.Height := 22;
      end;
    rmDesktop:
      begin
        AJob.Card.Height := 210;
        AJob.Card.Margins.Rect := RectF(8, 8, 8, 0);
        AJob.Thumbnail.Align   := TAlignLayout.Left;
        AJob.Thumbnail.Width   := 260;
        AJob.Thumbnail.Height  := 0;
        AJob.Thumbnail.Margins.Rect := RectF(10, 10, 10, 10);
        AJob.RightPanel.Align  := TAlignLayout.Client;
        AJob.RightPanel.Margins.Rect := RectF(0, 10, 10, 10);
        AJob.TitleLabel.Height := 48;
        AJob.TitleLabel.TextSettings.Font.Size := 14;
        AJob.StatusLabel.Height := 66;
        AJob.StatusLabel.TextSettings.Font.Size := 12;
        AJob.ProgressBar.Height := 24;
      end;
  end;
end;

procedure TFormParallelGallery.ApplyResponsiveLayout;
var
  LMode: TResponsiveMode;
  LJob : TImageDownloadJob;
begin
  LMode := GetResponsiveMode;

  case LMode of
    rmMobile:
      begin
        FTopBar.Height  := 156;
        FTopBar.Padding.Rect := RectF(8, 8, 8, 6);
        btnStartGallery.Align  := TAlignLayout.Top;
        btnStartGallery.Height := 40;
        btnStartGallery.Width  := 0;
        btnStartGallery.Margins.Rect := RectF(0, 0, 0, 6);
        btnCancelGallery.Align  := TAlignLayout.Top;
        btnCancelGallery.Height := 40;
        btnCancelGallery.Width  := 0;
        btnCancelGallery.Margins.Rect := RectF(0, 0, 0, 6);
        AniIndicator.Align  := TAlignLayout.Right;
        AniIndicator.Width  := 34;
        lblGalleryStatus.Align := TAlignLayout.Client;
        lblGalleryStatus.Margins.Rect := RectF(0, 6, 40, 0);
        lblGalleryStatus.TextSettings.Font.Size := 12;
        FBottomPanel.Height := 120;
        FBottomPanel.Padding.Rect := RectF(8, 4, 8, 8);
        ScrollBox.Padding.Rect := RectF(4, 0, 4, 4);
      end;
    rmTablet:
      begin
        FTopBar.Height  := 72;
        FTopBar.Padding.Rect := RectF(10, 10, 10, 6);
        btnStartGallery.Align  := TAlignLayout.Left;
        btnStartGallery.Width  := 160;
        btnStartGallery.Height := 0;
        btnStartGallery.Margins.Rect := RectF(0, 0, 0, 0);
        btnCancelGallery.Align  := TAlignLayout.Left;
        btnCancelGallery.Width  := 150;
        btnCancelGallery.Height := 0;
        btnCancelGallery.Margins.Rect := RectF(8, 0, 0, 0);
        AniIndicator.Align  := TAlignLayout.Right;
        AniIndicator.Width  := 36;
        lblGalleryStatus.Align := TAlignLayout.Client;
        lblGalleryStatus.Margins.Rect := RectF(12, 0, 8, 0);
        lblGalleryStatus.TextSettings.Font.Size := 12;
        FBottomPanel.Height := 150;
        FBottomPanel.Padding.Rect := RectF(10, 4, 10, 8);
        ScrollBox.Padding.Rect := RectF(6, 0, 6, 6);
      end;
    rmDesktop:
      begin
        FTopBar.Height  := 64;
        FTopBar.Padding.Rect := RectF(10, 10, 10, 6);
        btnStartGallery.Align  := TAlignLayout.Left;
        btnStartGallery.Width  := 170;
        btnStartGallery.Height := 0;
        btnStartGallery.Margins.Rect := RectF(0, 0, 0, 0);
        btnCancelGallery.Align  := TAlignLayout.Left;
        btnCancelGallery.Width  := 160;
        btnCancelGallery.Height := 0;
        btnCancelGallery.Margins.Rect := RectF(8, 0, 0, 0);
        AniIndicator.Align  := TAlignLayout.Right;
        AniIndicator.Width  := 36;
        lblGalleryStatus.Align := TAlignLayout.Client;
        lblGalleryStatus.Margins.Rect := RectF(12, 0, 8, 0);
        lblGalleryStatus.TextSettings.Font.Size := 12;
        FBottomPanel.Height := 180;
        FBottomPanel.Padding.Rect := RectF(10, 4, 10, 10);
        ScrollBox.Padding.Rect := RectF(6, 0, 6, 6);
      end;
  end;

  if Assigned(FJobs) then
    for LJob in FJobs do
      ApplyJobLayout(LJob, LMode);
end;

{ TFormParallelGallery — HTTP worker }

procedure TFormParallelGallery.FetchImageToBitmap(const AUrl: string;
  const AParams: ISafeThread4DParams;
  var AContext: TThreadContext;
  out ABitmap: TBitmap;
  out ABytesDownloaded: Int64;
  out AElapsedMs: Double);
var
  LClient       : TNetHTTPClient;
  LStream       : TMemoryStream;
  LResponse     : IHTTPResponse;
  LStart        : UInt64;
  LBitmap       : TBitmap;
  LProgressProxy: TDownloadProgressProxy;
begin
  ABitmap          := nil;
  ABytesDownloaded := 0;
  AElapsedMs       := 0;

  LClient        := TNetHTTPClient.Create(nil);
  LStream        := TMemoryStream.Create;
  LProgressProxy := TDownloadProgressProxy.Create(AParams, 0.15, 0.90);
  try
    LClient.ConnectionTimeout := 10_000;
    LClient.ResponseTimeout   := 25_000;
    LClient.OnReceiveData     := LProgressProxy.HandleReceiveData;

    LStart := TThread.GetTickCount64;
    try
      LResponse := LClient.Get(AUrl, LStream);
      AElapsedMs := TThread.GetTickCount64 - LStart;

      TSafeThread4D.CheckCancel(AParams, AContext);

      if LResponse.StatusCode <> 200 then
        raise Exception.CreateFmt('HTTP %d — %s',
          [LResponse.StatusCode, LResponse.StatusText]);

      ABytesDownloaded := LStream.Size;
      LStream.Position := 0;
      LBitmap := TBitmap.Create;
      try
        LBitmap.LoadFromStream(LStream);
        ABitmap := LBitmap;
      except
        LBitmap.Free;
        raise;
      end;
    except
      on E: Exception do
      begin
        if Assigned(AParams) and AParams.GetCancelRequested then
          TSafeThread4D.CheckCancel(AParams, AContext);
        raise;
      end;
    end;
  finally
    LProgressProxy.Free;
    LStream.Free;
    LClient.Free;
  end;
end;

{ TFormParallelGallery — Job lifecycle }

procedure TFormParallelGallery.UpdateGalleryStatus;
var
  LRunning, LDone, LError, LCancelled, LQueued: Integer;
  LJob: TImageDownloadJob;
begin
  if FIsClosing then
    Exit;

  LRunning := 0;
  LDone := 0;
  LError := 0;
  LCancelled := 0;
  LQueued := 0;

  for LJob in FJobs do
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
  end;

  lblGalleryStatus.Text := Format(
    'Queued: %d   Running: %d   Done: %d   Error: %d   Cancelled: %d   Max parallel: %d',
    [LQueued, LRunning, LDone, LError, LCancelled, MAX_PARALLEL_DOWNLOADS]);

  btnCancelGallery.Enabled := LRunning > 0;
  if not btnCancelGallery.Enabled then
    btnCancelGallery.Text := 'Cancel all';

  btnStartGallery.Enabled := (LRunning = 0) and not FIsClosing;

  AniIndicator.Visible := LRunning > 0;
  AniIndicator.Enabled := LRunning > 0;
end;

procedure TFormParallelGallery.StartJob(AJob: TImageDownloadJob);
var
  LParams   : ISafeThread4DParams;
  LParamsRaw: Pointer;
begin
  AJob.Proxy := TJobTerminateProxy.Create(Self, AJob);

  LParams :=
    TSafeThread4DParams.New
      .SetThreadName(Format('Gallery-%0.3d', [AJob.Index]))
      .SetThreadId(AJob.Index)
      .SetMeasureTime(True)
      .SetFreeOnTerminate(True)
      .SetCompleteWithError(False)
      .SetProgressIntervalMs(30)
      {$IFDEF MSWINDOWS}
      .SetThreadPriority(PriorityIdle)
      {$ENDIF}
      .SetOnInitialize(
        procedure(AContext: TThreadContext)
        begin
          if FIsClosing then Exit;
          AJob.Started := True;
          AJob.SetStatus('Starting...', 0.02);
          Log(Format('[Init] %s', [AJob.ObjectKey]));
        end)
      .SetOnProgress(
        procedure(APct: Single)
        begin
          // OnProgress runs on the main thread (marshalled by SafeThread4D).
          if FIsClosing then Exit;
          if Assigned(AJob.ProgressBar) then
            AJob.ProgressBar.Value := APct * 100;
        end)
      .SetOnSuccess(
        procedure(AContext: TThreadContext)
        begin
          // OnSuccess runs on the main thread (marshalled by SafeThread4D).
          if FIsClosing then Exit;
          AJob.Succeeded := True;
          if Assigned(AJob.Bitmap) then
            AJob.Thumbnail.Bitmap.Assign(AJob.Bitmap);
          AJob.SetStatus(
            Format('Done — %.0f KB   %.3f s network   %.3f s total',
              [AJob.BytesDownloaded / 1024,
               AJob.PhaseMs / 1000,
               AContext.ElapsedMilliseconds / 1000]),
            1.0);
          Log(Format('[Success] %s', [AJob.ObjectKey]));
        end)
      .SetOnError(
        procedure(const AErrorMessage: string; const AContext: TThreadContext)
        begin
          // OnError runs on the main thread (marshalled by SafeThread4D).
          AJob.Failed := True;
          FreeAndNil(AJob.Bitmap);
          if not FIsClosing then
          begin
            AJob.SetStatus('Error — ' + AErrorMessage, 1.0);
            Log(Format('[Error] %s — %s', [AJob.ObjectKey, AErrorMessage]));
          end;
        end)
      .SetOnCancel(
        procedure(AContext: TThreadContext)
        begin
          // OnCancel runs on the main thread (marshalled by SafeThread4D).
          AJob.Cancelled := True;
          FreeAndNil(AJob.Bitmap);
          if not FIsClosing then
          begin
            AJob.SetStatus('Cancelled', 1.0);
            Log(Format('[Cancel] %s', [AJob.ObjectKey]));
          end;
        end)
      .SetOnTerminate(
        procedure(AContext: TThreadContext)
        begin
          // OnTerminate runs on the main thread (marshalled by SafeThread4D).
          AJob.ElapsedMs := AContext.ElapsedMilliseconds;
        end)
      .SetOnTerminateEvent(AJob.Proxy.HandleTerminate)
      .SetOnExecute(
        procedure(AContext: TThreadContext)
        var
          LParams: ISafeThread4DParams;
        begin
          // Weak -> Strong to avoid capturing LParams inside its own closure set.
          LParams := ISafeThread4DParams(IInterface(LParamsRaw));
          if LParams = nil then
            raise Exception.Create('Internal error: ParamsRaw not initialized.');

          TSafeThread4D.CheckCancel(LParams, AContext);

          TThread.Synchronize(nil,
            procedure
            begin
              if FIsClosing then Exit;
              AJob.SetStatus('Opening connection...', -1);
            end);
          TSafeThread4D.ReportProgress(LParams, 0.10);

          TThread.Synchronize(nil,
            procedure
            begin
              if FIsClosing then Exit;
              AJob.SetStatus('Downloading...', -1);
            end);

          FetchImageToBitmap(
            AJob.Url, LParams, AContext, AJob.Bitmap, AJob.BytesDownloaded, AJob.PhaseMs);

          TSafeThread4D.CheckCancel(LParams, AContext);

          TThread.Synchronize(nil,
            procedure
            begin
              if FIsClosing then Exit;
              AJob.SetStatus(
                Format('Downloaded %.0f KB — decoding...',
                  [AJob.BytesDownloaded / 1024]),
                -1);
            end);
          TSafeThread4D.ReportProgress(LParams, 0.95);

          TSafeThread4D.CheckCancel(LParams, AContext);

          TThread.Synchronize(nil,
            procedure
            begin
              if FIsClosing then Exit;
              AJob.SetStatus('Ready', -1);
            end);
          TSafeThread4D.ReportProgress(LParams, 1.0, True);
        end);

  try
    TSafeThread4D.StartThreadWithWeakRef(LParams, LParamsRaw, AJob.Params);
    Inc(FActiveDownloads);
    UpdateGalleryStatus;
  except
    on E: Exception do
    begin
      AJob.Params := nil;
      FreeAndNil(AJob.Proxy);
      raise;
    end;
  end;
end;

procedure TFormParallelGallery.StartPendingJobs;
var
  LJob: TImageDownloadJob;
begin
  while (FActiveDownloads < MAX_PARALLEL_DOWNLOADS) and
        (FNextJobIndex < FJobs.Count) and
        not FGlobalCancel do
  begin
    LJob := FJobs[FNextJobIndex];
    Inc(FNextJobIndex);
    StartJob(LJob);
  end;
  UpdateGalleryStatus;
end;

procedure TFormParallelGallery.JobTerminated(AJob: TImageDownloadJob);
begin
  if AJob.Finished then
    Exit;

  AJob.Finished := True;
  AJob.Params   := nil;
  FreeAndNil(AJob.Bitmap);

  if FActiveDownloads > 0 then
    Dec(FActiveDownloads);

  if not FIsClosing then
  begin
    if not (AJob.Succeeded or AJob.Failed or AJob.Cancelled) then
      AJob.SetStatus(Format('Finished — %.3f s', [AJob.ElapsedMs / 1000]), 1.0);
    Log(Format('[Terminate] %s — %.3f s', [AJob.ObjectKey, AJob.ElapsedMs / 1000]));
  end;

  if not FGlobalCancel and not FIsClosing then
    StartPendingJobs
  else
    UpdateGalleryStatus;
end;

{ TFormParallelGallery — Lifecycle handlers }

procedure TFormParallelGallery.btnStartGalleryClick(Sender: TObject);
begin
  if FIsClosing then
    Exit;
  if FActiveDownloads > 0 then
  begin
    Log('[Info] A gallery batch is already running.');
    Exit;
  end;

  FGlobalCancel := False;
  BuildDemoObjectList;
  Log('[Start] Starting bounded parallel downloads...');
  StartPendingJobs;
end;

procedure TFormParallelGallery.btnCancelGalleryClick(Sender: TObject);
begin
  RequestCancelAll;
end;

procedure TFormParallelGallery.FormResizeHandler(Sender: TObject);
begin
  ApplyResponsiveLayout;
end;

procedure TFormParallelGallery.FormCloseHandler(Sender: TObject;
  var Action: TCloseAction);
(*
  Close-time drain policy.

  This example intentionally uses a bounded shutdown drain so the last queued
  lifecycle callbacks can finish before the runtime-built form disappears.
*)
begin
  FIsClosing := True;
  Log('=== Shutting down ===');
  RequestCancelAll;
  DrainUntilReleased(DRAIN_TIMEOUT_MS);
  Log('=== Shutdown complete ===');
end;

{ TFormParallelGallery — Shutdown }

procedure TFormParallelGallery.RequestCancelAll;
var
  LJob: TImageDownloadJob;
begin
  FGlobalCancel := True;

  if Assigned(btnCancelGallery) then
  begin
    btnCancelGallery.Enabled := False;
    btnCancelGallery.Text := 'Cancelling...';
  end;

  for LJob in FJobs do
  begin
    if Assigned(LJob.Params) then
    begin
      LJob.Params.RequestCancel;
      if not FIsClosing then
        LJob.SetStatus('Cancelling...', -1);
    end
    else if not LJob.Started and not LJob.Finished then
    begin
      LJob.Cancelled := True;
      LJob.Finished  := True;
      if not FIsClosing then
        LJob.SetStatus('Skipped — global cancel', 1.0);
    end;
  end;

  if not FIsClosing then
    Log('[Cancel] Global cancel requested.');

  UpdateGalleryStatus;
end;

function TFormParallelGallery.AllReleased: Boolean;
var
  LJob: TImageDownloadJob;
begin
  Result := True;
  for LJob in FJobs do
    if Assigned(LJob.Params) then Exit(False);
end;

procedure TFormParallelGallery.DrainUntilReleased(const ATimeoutMs: Integer);
(*
  Bounded UI-thread drain used only during form shutdown.

  Why this is useful
  - During shutdown, downloads may already be finished logically but still be
    waiting for their marshalled OnTerminate / OnCancel / OnError / final UI
    callbacks to run on the main thread.
  - If those callbacks do not run, job params remain published and the form
    appears to hang even though cancellation has already propagated.

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

end.
