// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Eduardo P. Araujo
// https://github.com/eduardoparaujo/SafeThread4D

{*
  Unit   : SafeThread.Download.Demo.Main
  Purpose: Download demo for SafeThread4D, covering JSON and image downloads,
           UI-safe completion, cooperative cancellation, and bounded shutdown.

  Part of the SafeThread4D examples.

  Author        : Eduardo P. Araujo
  Created       : 2026-04-26
  Last modified : 2026-04-26
  Version       : 1.0.0

  Notes:
    - Demonstrates the weak + strong startup pattern.
    - Uses CheckSynchronize as a bounded host-app shutdown drain.
    - This unit is an example form, not part of the runtime library.
*}

unit SafeThread.Download.Demo.Main;

interface

uses
  System.Classes,
  System.Net.HttpClient,
  System.Net.HttpClientComponent,
  System.SysUtils,
  System.UITypes,

  FMX.Controls,
  FMX.Controls.Presentation,
  FMX.Forms,
  FMX.Graphics,
  FMX.Memo,
  FMX.Memo.Types,
  FMX.Objects,
  FMX.ScrollBox,
  FMX.StdCtrls,
  FMX.TabControl,
  FMX.Types,

  SafeThread4D;

type
  // Simple holder for JSON payload; in a real app this would likely be parsed
  // into a structured model.
  TDownloadResult = class
    JSONData: string;
  end;

  TDownloadReceiveDataProxy = class
  private
    FParams: ISafeThread4DParams;
  public
    constructor Create(const AParams: ISafeThread4DParams);
    procedure HandleReceiveData(const ASender: TObject; AContentLength, AReadCount: Int64; var AAbort: Boolean);
  end;

  TFormMain = class(TForm)
    TabControl            : TTabControl;
    tabDownloads          : TTabItem;
    btnDownloadJSON       : TButton;
    cbxJSONError          : TCheckBox;
    btnCancelDownloadJSON : TButton;
    btnDownloadImage      : TButton;
    btnCancelDownloadImage: TButton;
    MemoJSON              : TMemo;
    AniIndicatorJSON      : TAniIndicator;
    rctImage              : TRectangle;
    Image                 : TImage;
    AniIndicatorImage     : TAniIndicator;
    rctLog                : TRectangle;
    MemoLog               : TMemo;
    lblDownloadJSONStatus : TLabel;
    lblDownloadImageStatus: TLabel;

    procedure btnDownloadJSONClick(Sender: TObject);
    procedure btnDownloadImageClick(Sender: TObject);
    procedure btnCancelDownloadImageClick(Sender: TObject);
    procedure btnCancelDownloadJSONClick(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);

  private
    { Private declarations }

    // Downloads.
    FDownloadImageParams: ISafeThread4DParams;
    FDownloadJSONParams : ISafeThread4DParams;

    // Worker payloads.
    procedure DownloadJSON(const AParams: ISafeThread4DParams; var AContext: TThreadContext; const ADownloadResult: TDownloadResult);
    procedure DownloadImage(const AParams: ISafeThread4DParams; var AContext: TThreadContext; out ABitmap: TBitmap);

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
  // URLs used by the demo.
  JSON_URL  = 'https://jsonplaceholder.typicode.com/comments';
  IMAGE_URL = 'https://picsum.photos/200/300?grayscale';

  // Heartbeat cadence.
  HEARTBEAT_MS = 300;

  // Image timeout (ms) - separate from SafeThread4D timeout, just to demonstrate
  // an extra timing channel inside the worker.
  IMAGE_TIMEOUT_MS = 100_000;

  // 15 seconds to close elegantly.
  DRAIN_TIMEOUT_MS = 15_000;

{ TDownloadReceiveDataProxy }

constructor TDownloadReceiveDataProxy.Create(const AParams: ISafeThread4DParams);
begin
  inherited Create;
  FParams := AParams;
end;

procedure TDownloadReceiveDataProxy.HandleReceiveData(const ASender: TObject; AContentLength, AReadCount: Int64; var AAbort: Boolean);
begin
  AAbort := Assigned(FParams) and FParams.GetCancelRequested;
  if AAbort then
    Exit;

  if (AContentLength > 0) and Assigned(FParams) then
    TSafeThread4D.ReportProgress(FParams, AReadCount / AContentLength);
end;

{ TFormMain — JSON download }

procedure TFormMain.DownloadJSON(const AParams: ISafeThread4DParams; var AContext: TThreadContext; const ADownloadResult: TDownloadResult);
var
  LHttpClient: TNetHttpClient;
  LProxy     : TDownloadReceiveDataProxy;
  LResponse  : IHTTPResponse;
  LContent   : TStringStream;
begin
  // Small switch to force an error and exercise OnError / OnCancel flows.
  if cbxJSONError.IsChecked then
    raise Exception.Create('Simulated error during JSON download');

  TSafeThread4D.CheckCancel(AParams, AContext);

  LHttpClient := TNetHttpClient.Create(nil);
  LProxy := TDownloadReceiveDataProxy.Create(AParams);
  LContent := TStringStream.Create('', TEncoding.UTF8);
  try
    LHttpClient.OnReceiveData := LProxy.HandleReceiveData;

    LResponse := LHttpClient.Get(JSON_URL, LContent);

    TSafeThread4D.CheckCancel(AParams, AContext);

    if LResponse.StatusCode = 200 then
      ADownloadResult.JSONData := LContent.DataString
    else
    begin
      case LResponse.StatusCode of
        404:
          raise Exception.CreateFmt('Resource not found at %s', [JSON_URL]);

        405 .. 499:
          raise Exception.CreateFmt('Client error (%d): %s',
            [LResponse.StatusCode, LResponse.StatusText]);

        500 .. 599:
          raise Exception.CreateFmt('Server error (%d): %s',
            [LResponse.StatusCode, LResponse.StatusText]);
      else
        raise Exception.CreateFmt('Unexpected error (%d): %s',
          [LResponse.StatusCode, LResponse.StatusText]);
      end;
    end;
  finally
    LContent.Free;
    LProxy.Free;
    LHttpClient.Free;
  end;
end;

procedure TFormMain.btnDownloadJSONClick(Sender: TObject);
var
  LParams   : ISafeThread4DParams;
  LParamsRaw: Pointer;
  LResult   : TDownloadResult;
begin
  if Assigned(FDownloadJSONParams) then
    Exit;

  LResult := TDownloadResult.Create;

  LParams :=
    TSafeThread4DParams.New
      .SetThreadName('DownloadJSON')
      .SetThreadId(3)
      .SetMeasureTime(True)
      .SetCompleteWithError(True)
      .SetFreeOnTerminate(True)
      {$IFDEF MSWINDOWS}
      .SetThreadPriority(PriorityIdle)
      {$ENDIF}
      .SetHeartbeatIntervalMs(HEARTBEAT_MS)
      .SetOnHeartbeat(
        procedure
        var
          LBlip: Char;
          LTs  : string;
        begin
          if Odd(TThread.GetTickCount64 div HEARTBEAT_MS) then
            LBlip := '●'
          else
            LBlip := '◦';

          LTs := FormatDateTime('hh:nn:ss', Now);

          {$IFDEF ANDROID}
          lblDownloadJSONStatus.Text := Format('[HB] ANR guard %s  %s', [LBlip, LTs]);
          {$ELSE}
          lblDownloadJSONStatus.Text := Format('[HB] UI ping %s  %s', [LBlip, LTs]);
          {$ENDIF}
        end)
      .SetOnInitialize(
        procedure(AContext: TThreadContext)
        begin
          AniIndicatorJSON.Visible := True;
          AniIndicatorJSON.Enabled := True;
          lblDownloadJSONStatus.Text := 'Downloading JSON...';

          if Sender is TButton then
            TButton(Sender).Enabled := False;

          MemoLog.Lines.Clear;
          MemoLog.Lines.Add(Format(
            '[Init] Thread "%s" (Native ID: %d, Logical ID: %d) started.',
            [AContext.ThreadName, AContext.NativeThreadID, AContext.LogicalThreadID]));
        end)
      .SetOnProgress(
        procedure(APct: Single)
        begin
          lblDownloadJSONStatus.Text := Format('Downloading JSON... %.0f%%', [APct * 100]);
        end)
      .SetProgressIntervalMs(80)
      .SetOnExecute(
        procedure(AContext: TThreadContext)
        var
          LParams: ISafeThread4DParams;
        begin
          LParams := ISafeThread4DParams(IInterface(LParamsRaw));
          if LParams = nil then
            raise Exception.Create('Internal error: ParamsRaw not initialized.');

          DownloadJSON(LParams, AContext, LResult);
        end)
      .SetOnSuccess(
        procedure(AContext: TThreadContext)
        begin
          MemoJSON.Lines.Add(LResult.JSONData);
          lblDownloadJSONStatus.Text := 'JSON download completed.';
          MemoLog.Lines.Add(Format(
            '[Success] Thread "%s" (Native ID: %d, Logical ID: %d) completed successfully.',
            [AContext.ThreadName, AContext.NativeThreadID, AContext.LogicalThreadID]));
        end)
      .SetOnError(
        procedure(const AErrorMessage: string; const AContext: TThreadContext)
        begin
          lblDownloadJSONStatus.Text := 'JSON download failed.';
          MemoLog.Lines.Add(Format(
            '[Error] Thread "%s" (Native ID: %d, Logical ID: %d) failed: %s',
            [AContext.ThreadName, AContext.NativeThreadID, AContext.LogicalThreadID, AErrorMessage]));
        end)
      .SetOnCancel(
        procedure(AContext: TThreadContext)
        begin
          lblDownloadJSONStatus.Text := 'JSON download cancelled.';
          MemoLog.Lines.Add(Format(
            '[Cancel] Thread "%s" (Native ID: %d, Logical ID: %d) was cancelled.',
            [AContext.ThreadName, AContext.NativeThreadID, AContext.LogicalThreadID]));
        end)
      .SetOnTerminate(
        procedure(AContext: TThreadContext)
        begin
          AniIndicatorJSON.Enabled := False;
          AniIndicatorJSON.Visible := False;

          if Sender is TButton then
            TButton(Sender).Enabled := True;

          MemoLog.Lines.Add(Format(
            '[Terminate] Thread "%s" (Native ID: %d, Logical ID: %d) finished. Elapsed: %.3f s.',
            [AContext.ThreadName, AContext.NativeThreadID, AContext.LogicalThreadID,
             AContext.ElapsedMilliseconds / 1000]));

          LResult.Free;
          FDownloadJSONParams := nil;
        end);

  TSafeThread4D.StartThreadWithWeakRef(LParams, LParamsRaw, FDownloadJSONParams);
end;

procedure TFormMain.btnCancelDownloadJSONClick(Sender: TObject);
begin
  if Assigned(FDownloadJSONParams) then
  begin
    MemoLog.Lines.Add('[User] Cancellation request (JSON)...');
    FDownloadJSONParams.RequestCancel;
  end;
end;

{ TFormMain — Image download }

procedure TFormMain.DownloadImage(const AParams: ISafeThread4DParams; var AContext: TThreadContext; out ABitmap: TBitmap);
var
  LHttpClient: TNetHttpClient;
  LProxy     : TDownloadReceiveDataProxy;
  LStream    : TMemoryStream;
  LResponse  : IHTTPResponse;
  LBitmap    : TBitmap;
begin
  ABitmap := nil;
  TSafeThread4D.CheckCancel(AParams, AContext);

  LHttpClient := TNetHttpClient.Create(nil);
  LProxy      := TDownloadReceiveDataProxy.Create(AParams);
  LStream     := TMemoryStream.Create;
  try
    LHttpClient.OnReceiveData := LProxy.HandleReceiveData;

    LResponse := LHttpClient.Get(IMAGE_URL, LStream);

    TSafeThread4D.CheckCancel(AParams, AContext);

    if LResponse.StatusCode <> 200 then
      raise Exception.CreateFmt('Failed to fetch image (Status: %d)',
        [LResponse.StatusCode]);

    LStream.Position := 0;
    LBitmap := TBitmap.Create;
    try
      LBitmap.LoadFromStream(LStream);
      ABitmap := LBitmap;
    except
      LBitmap.Free;
      raise;
    end;
  finally
    LStream.Free;
    LProxy.Free;
    LHttpClient.Free;
  end;
end;

procedure TFormMain.btnDownloadImageClick(Sender: TObject);
var
  LParams   : ISafeThread4DParams;
  LParamsRaw: Pointer;
  LBitmap   : TBitmap;
begin
  if Assigned(FDownloadImageParams) then
    Exit;

  LBitmap := nil;

  LParams :=
    TSafeThread4DParams.New
      .SetThreadName('DownloadImage')
      .SetThreadId(4)
      .SetMeasureTime(True)
      .SetCompleteWithError(False)
      .SetFreeOnTerminate(True)
      {$IFDEF MSWINDOWS}
      .SetThreadPriority(PriorityIdle)
      {$ENDIF}
      .SetHeartbeatIntervalMs(HEARTBEAT_MS)
      .SetOnHeartbeat(
        procedure
        var
          LBlip: Char;
          LTs  : string;
        begin
          if Odd(TThread.GetTickCount64 div HEARTBEAT_MS) then
            LBlip := '●'
          else
            LBlip := '◦';

          LTs := FormatDateTime('hh:nn:ss', Now);

          {$IFDEF ANDROID}
          lblDownloadImageStatus.Text := Format('[HB] ANR guard %s  %s', [LBlip, LTs]);
          {$ELSE}
          lblDownloadImageStatus.Text := Format('[HB] UI ping %s  %s', [LBlip, LTs]);
          {$ENDIF}
        end)
      .SetOnInitialize(
        procedure(AContext: TThreadContext)
        begin
          Image.Bitmap.Clear(TAlphaColors.Null);

          AniIndicatorImage.Visible := True;
          AniIndicatorImage.Enabled := True;
          lblDownloadImageStatus.Text := 'Downloading image...';

          if Sender is TButton then
            TButton(Sender).Enabled := False;

          MemoLog.Lines.Clear;
          MemoLog.Lines.Add(Format(
            '[Init] Thread "%s" (Native ID: %d, Logical ID: %d) started.',
            [AContext.ThreadName, AContext.NativeThreadID, AContext.LogicalThreadID]));
        end)
      .SetOnProgress(
        procedure(APct: Single)
        begin
          lblDownloadImageStatus.Text := Format('Downloading image... %.0f%%', [APct * 100]);
        end)
      .SetProgressIntervalMs(80)
      .SetOnExecute(
        procedure(AContext: TThreadContext)
        var
          LParams: ISafeThread4DParams;
        begin
          LParams := ISafeThread4DParams(IInterface(LParamsRaw));
          if LParams = nil then
            raise Exception.Create('Internal error: ParamsRaw not initialized.');

          DownloadImage(LParams, AContext, LBitmap);
        end)
      .SetOnSuccess(
        procedure(AContext: TThreadContext)
        begin
          if Assigned(LBitmap) then
          begin
            Image.Bitmap.Assign(LBitmap);
            LBitmap.Free;
            LBitmap := nil;
          end;

          lblDownloadImageStatus.Text := 'Image download completed.';
          MemoLog.Lines.Add(Format(
            '[Success] Thread "%s" (Native ID: %d, Logical ID: %d) completed successfully.',
            [AContext.ThreadName, AContext.NativeThreadID, AContext.LogicalThreadID]));
        end)
      .SetOnError(
        procedure(const AErrorMessage: string; const AContext: TThreadContext)
        begin
          lblDownloadImageStatus.Text := 'Image download failed.';
          MemoLog.Lines.Add(Format(
            '[Error] Thread "%s" (Native ID: %d, Logical ID: %d) failed: %s',
            [AContext.ThreadName, AContext.NativeThreadID, AContext.LogicalThreadID, AErrorMessage]));
        end)
      .SetOnCancel(
        procedure(AContext: TThreadContext)
        begin
          if Assigned(LBitmap) then
          begin
            LBitmap.Free;
            LBitmap := nil;
          end;

          lblDownloadImageStatus.Text := 'Image download cancelled.';
          MemoLog.Lines.Add(Format(
            '[Cancel] Thread "%s" (Native ID: %d, Logical ID: %d) was cancelled.',
            [AContext.ThreadName, AContext.NativeThreadID, AContext.LogicalThreadID]));
        end)
      .SetOnTerminate(
        procedure(AContext: TThreadContext)
        begin
          if Assigned(LBitmap) then
          begin
            LBitmap.Free;
            LBitmap := nil;
          end;

          AniIndicatorImage.Enabled := False;
          AniIndicatorImage.Visible := False;

          if Sender is TButton then
            TButton(Sender).Enabled := True;

          MemoLog.Lines.Add(Format(
            '[Terminate] Thread "%s" (Native ID: %d, Logical ID: %d) finished. Elapsed: %.3f s.',
            [AContext.ThreadName, AContext.NativeThreadID, AContext.LogicalThreadID,
             AContext.ElapsedMilliseconds / 1000]));

          FDownloadImageParams := nil;
        end);

  TSafeThread4D.StartThreadWithWeakRef(LParams, LParamsRaw, FDownloadImageParams);
end;

procedure TFormMain.btnCancelDownloadImageClick(Sender: TObject);
begin
  if Assigned(FDownloadImageParams) then
  begin
    MemoLog.Lines.Add('[User] Cancellation request (Image)...');
    FDownloadImageParams.RequestCancel;
  end;
end;

{ TFormMain — Shutdown }

procedure TFormMain.RequestCancelAll;
  procedure Cancel(var AParams: ISafeThread4DParams; const ATag: string);
  begin
    if Assigned(AParams) then
    begin
      MemoLog.Lines.Add('[Close] Cancel ' + ATag);
      AParams.RequestCancel;
    end;
  end;
begin
  // Cancellation for all known tasks.
  Cancel(FDownloadJSONParams , 'DownloadJSON');
  Cancel(FDownloadImageParams, 'DownloadImage');
end;

function TFormMain.AllReleased: Boolean;
begin
  Result :=
    (FDownloadImageParams = nil) and
    (FDownloadJSONParams  = nil);
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
    //   the close sequence appears to hang even though cancellation was
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
      MemoLog.Lines.Add('[Close] Timeout waiting for workers to finish');
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
  MemoLog.Lines.Add('=== Application shutting down ===');

  // 1) General cancel.
  RequestCancelAll;

  // 2) Drain until all F...Params are NIL (via OnTerminate).
  DrainUntilReleased(DRAIN_TIMEOUT_MS);

  MemoLog.Lines.Add('=== Shutdown complete ===');
end;

end.
