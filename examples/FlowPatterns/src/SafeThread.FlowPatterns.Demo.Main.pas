// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Eduardo P. Araujo
// https://github.com/eduardoparaujo/SafeThread4D

{*
  Unit   : SafeThread.FlowPatterns.Demo.Main
  Purpose: App-level flow patterns built on top of SafeThread4D 1.0.0:
           retry, debounce, and a simple three-step pipeline.

  Part of the SafeThread4D examples.

  Author        : Eduardo P. Araujo
  Created       : 2026-04-26
  Last modified : 2026-04-26
  Version       : 1.0.0

  Notes:
    - Retry and debounce shown here are application patterns, not native
      SafeThread4D features in version 1.0.0.
    - The demo keeps the current SafeThread4D API:
        * OnExecute receives only TThreadContext
        * OnProgress receives only Single
        * StartThreadWithWeakRef is used when worker code needs Params
    - Shutdown draining uses CheckSynchronize as a bounded host-app close policy.
    - CancelAndWait is intentionally not used on the main thread.
*}

unit SafeThread.FlowPatterns.Demo.Main;

interface

uses
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
  System.StrUtils,
  System.SyncObjs,
  System.SysUtils,
  System.UITypes;

type
  TFormMain = class(TForm)
    TabControl           : TTabControl;

    tabRetry             : TTabItem;
    btnRetryStart        : TButton;
    btnRetryCancel       : TButton;
    lblRetryStatus       : TLabel;
    pbarRetry            : TProgressBar;
    MemoRetryLog         : TMemo;
    chkRetryForceFailure : TCheckBox;

    tabDebounce          : TTabItem;
    edtSearch            : TEdit;
    lblDebounceStatus    : TLabel;
    lblDebounceHint      : TLabel;
    MemoDebounceLog      : TMemo;
    lblDebounceFireCount : TLabel;
    lblDebounceDoneCount : TLabel;

    tabPipeline          : TTabItem;
    btnPipelineStart     : TButton;
    btnPipelineCancel    : TButton;
    lblPipelineStatus    : TLabel;
    pbarPipeline         : TProgressBar;
    MemoPipelineLog      : TMemo;

    procedure FormCreate(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure btnRetryStartClick(Sender: TObject);
    procedure btnRetryCancelClick(Sender: TObject);
    procedure edtSearchChangeTracking(Sender: TObject);
    procedure btnPipelineStartClick(Sender: TObject);
    procedure btnPipelineCancelClick(Sender: TObject);

  private
    { Private declarations }

    // Retry state.
    FRetryParams        : ISafeThread4DParams;
    FRetryForceFailure  : Boolean;
    FRetryRunToken      : Integer;
    FRetryPendingDelay  : Boolean;
    FRetryCurrentAttempt: Integer;

    // Retry delay gate.
    //
    // IMPORTANT — why a TEvent and not TThread.Sleep:
    //
    //   Between two retry attempts, the demo needs to wait for RETRY_DELAY_MS
    //   before launching the next attempt. The naive approach is to spawn an
    //   anonymous thread that calls TThread.Sleep(RETRY_DELAY_MS) and then
    //   queues StartRetryAttempt back to the main thread.
    //
    //   That works during normal operation, but it leaks if the user closes
    //   the form WHILE the delay is in progress. The reason is that
    //   TThread.Sleep is not interruptible: the anonymous thread keeps
    //   sleeping for the full delay even after FormClose has run, and when
    //   it finally wakes up, the queued closure still holds references to
    //   form-owned objects that are already on their way out, and the
    //   anonymous thread itself outlives the form.
    //
    // Fix:
    //   The anonymous thread now waits on this manual-reset TEvent. During
    //   normal operation the event stays reset and WaitFor(RETRY_DELAY_MS)
    //   times out exactly like Sleep. On shutdown, RequestCancelAll signals
    //   the event, the anonymous thread wakes up immediately, observes the
    //   stale run token (or FIsClosing), and exits cleanly.
    //
    //   The shutdown drain also waits until FRetryPendingDelay = False, so
    //   it does not return before the anonymous thread has actually finished.
    FRetryDelayCancelEvent: TEvent;

    // Debounce state.
    FDebounceParams       : ISafeThread4DParams;
    FDebounceFireCount    : Integer;
    FDebounceDoneCount    : Integer;
    FDebounceCurrentQuery : string;
    FDebounceActiveToken  : Integer;

    // Pipeline state.
    FPipeline1Params: ISafeThread4DParams;
    FPipeline2Params: ISafeThread4DParams;
    FPipeline3Params: ISafeThread4DParams;

    // Form shutdown guard.
    FIsClosing: Boolean;

    // Retry helpers.
    procedure StartRetryAttempt(const ARunToken, AAttempt: Integer);
    procedure ScheduleRetryAttempt(const ARunToken, ANextAttempt: Integer);
    procedure RetryTerminate(Sender: TObject);

    // Debounce helpers.
    procedure StartDebouncedSearch(const AToken: Integer; const AQuery: string);
    procedure DebounceTerminate(Sender: TObject);

    // Pipeline helpers.
    procedure PipelineStep1;
    procedure PipelineStep2;
    procedure PipelineStep3;
    procedure CancelPipeline;
    procedure Pipeline1Terminate(Sender: TObject);
    procedure Pipeline2Terminate(Sender: TObject);
    procedure Pipeline3Terminate(Sender: TObject);

    // Shutdown.
    procedure DisableUiForShutdown;
    procedure FlushMainThreadOnce;
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
  // Shutdown drain policy.
  DRAIN_TIMEOUT_MS     = 15_000;
  DRAIN_QUIET_FLUSH_MS = 250;
  DRAIN_FINAL_PASSES   = 8;

  // Retry policy.
  RETRY_MAX      = 3; // Retries after the first attempt.
  RETRY_DELAY_MS = 2000;
  RETRY_WORK_MS  = 800;

  // Debounce policy.
  DEBOUNCE_MS    = 400;
  SEARCH_WORK_MS = 1200;

  // Pipeline timings.
  PIPELINE_STEP1_MS = 1500;
  PIPELINE_STEP2_MS = 2000;
  PIPELINE_STEP3_MS = 1000;

{ TFormMain — Form lifecycle }

procedure TFormMain.FormCreate(Sender: TObject);
begin
  FIsClosing            := False;
  FDebounceFireCount    := 0;
  FDebounceDoneCount    := 0;
  FDebounceCurrentQuery := '';
  FRetryForceFailure    := False;
  FRetryRunToken        := 0;
  FRetryPendingDelay    := False;
  FRetryCurrentAttempt  := 0;
  FDebounceActiveToken  := 0;

  // Manual-reset event, initially non-signaled. The anonymous thread used by
  // ScheduleRetryAttempt waits on this event instead of calling Sleep, so a
  // shutdown can wake it up immediately.
  FRetryDelayCancelEvent := TEvent.Create(nil, True, False, '');

  edtSearch.OnChangeTracking := edtSearchChangeTracking;
end;

procedure TFormMain.DisableUiForShutdown;
begin
  btnRetryStart.Enabled      := False;
  btnRetryCancel.Enabled     := False;
  btnPipelineStart.Enabled   := False;
  btnPipelineCancel.Enabled  := False;
  edtSearch.Enabled          := False;
  TabControl.Enabled         := False;
  edtSearch.OnChangeTracking := nil;
end;

procedure TFormMain.FlushMainThreadOnce;
begin
  // Drain the Synchronize/Queue callback queue explicitly.
  // This helper is used only as part of the bounded shutdown drain.
  CheckSynchronize(0);
end;

procedure TFormMain.FormClose(Sender: TObject; var Action: TCloseAction);
(*
  Close-time drain policy.

  This example intentionally uses a bounded UI-thread drain during shutdown.
  The goal is to let queued OnTerminate / OnCancel / OnError / Queue /
  Synchronize callbacks run before the form disappears.

  Why this is useful
  - A task may already be logically finished, but its final marshalled
    callbacks can still be waiting in the main-thread callback queue.
  - If the form closes before those callbacks are accepted, params references
    may stay published longer than expected and shutdown appears to hang.

  Why this is done here
  - This is host-app shutdown policy only.
  - It is not a recommendation for normal UI flow.
  - The loop is bounded, the UI is disabled first, and no business work is
    performed inside the drain.

  Retry-specific shutdown note
  - If a retry delay is in progress when the user closes the form, the
    shutdown drain must wait for the anonymous delay thread to finish
    cleanly. RequestCancelAll signals FRetryDelayCancelEvent to wake it up
    immediately, and AllReleased only returns True after the delay thread
    has cleared FRetryPendingDelay.
*)
var
  I: Integer;
begin
  FIsClosing := True;
  DisableUiForShutdown;
  RequestCancelAll;
  DrainUntilReleased(DRAIN_TIMEOUT_MS);

  for I := 1 to DRAIN_FINAL_PASSES do
  begin
    FlushMainThreadOnce;
    TThread.Sleep(10);
  end;

  FreeAndNil(FRetryDelayCancelEvent);
end;

{ TFormMain — Retry }

procedure TFormMain.StartRetryAttempt(const ARunToken, AAttempt: Integer);
(*
  RETRY ATTEMPT START
  -------------------

  Purpose
  - Starts one concrete attempt of the retry flow using SafeThread4D 1.0.0.

  Important
  - Retry is not a native SafeThread4D feature in this example.
  - The retry policy is implemented by the application:
      * one SafeThread4D task per attempt
      * OnError decides whether to schedule the next attempt
      * a run token invalidates stale retries after cancel/restart

  Ownership model
  - StartThreadWithWeakRef keeps the authoritative strong reference in
    FRetryParams.
  - The worker rebuilds a scoped strong reference from ParamsRaw when it
    needs cooperative APIs such as CheckCancel and ReportProgress.
*)
var
  LParams   : ISafeThread4DParams;
  LParamsRaw: Pointer;
begin
  if FIsClosing then
    Exit;

  if ARunToken <> FRetryRunToken then
    Exit;

  FRetryCurrentAttempt := AAttempt;
  FRetryPendingDelay := False;

  LParams :=
    TSafeThread4DParams.New
      .SetThreadName(Format('Retry-Attempt-%d', [AAttempt]))
      .SetFreeOnTerminate(True)
      .SetMeasureTime(True)
      .SetProgressIntervalMs(50)
      .SetOnProgress(
        procedure(APct: Single)
        begin
          if FIsClosing or (ARunToken <> FRetryRunToken) then
            Exit;

          pbarRetry.Value := APct * 100;
          lblRetryStatus.Text := Format(
            'Attempt %d of %d... %.0f%%',
            [AAttempt, RETRY_MAX + 1, APct * 100]);
        end)
      .SetOnSuccess(
        procedure(AContext: TThreadContext)
        begin
          if FIsClosing or (ARunToken <> FRetryRunToken) then
            Exit;

          lblRetryStatus.Text := Format(
            'Succeeded on attempt %d of %d  (%.3f s)',
            [AAttempt, RETRY_MAX + 1, AContext.ElapsedMilliseconds / 1000]);
          MemoRetryLog.Lines.Add('[Success] Operation completed.');
        end)
      .SetOnError(
        procedure(const AErrorMessage: string; const AContext: TThreadContext)
        begin
          if FIsClosing or (ARunToken <> FRetryRunToken) then
            Exit;

          if AAttempt <= RETRY_MAX then
          begin
            MemoRetryLog.Lines.Add(Format(
              '[Error] Attempt %d failed: %s',
              [AAttempt, AErrorMessage]));
            ScheduleRetryAttempt(ARunToken, AAttempt + 1);
          end
          else
          begin
            lblRetryStatus.Text := Format(
              'Failed after %d attempt(s).',
              [AAttempt]);
            MemoRetryLog.Lines.Add(Format(
              '[Error] All %d attempt(s) failed: %s',
              [AAttempt, AErrorMessage]));
          end;
        end)
      .SetOnCancel(
        procedure(AContext: TThreadContext)
        begin
          if FIsClosing or (ARunToken <> FRetryRunToken) then
            Exit;

          lblRetryStatus.Text := 'Cancelled.';
          MemoRetryLog.Lines.Add('[Cancel] Operation cancelled by user.');
        end)
      .SetOnTerminateEvent(RetryTerminate)
      .SetOnExecute(
        procedure(AContext: TThreadContext)
        var
          I: Integer;
          LParams: ISafeThread4DParams;
        begin
          LParams := ISafeThread4DParams(IInterface(LParamsRaw));
          if LParams = nil then
            raise Exception.Create('Internal error: ParamsRaw not initialized.');

          TSafeThread4D.ReportProgress(LParams, 0, True);

          for I := 1 to 20 do
          begin
            TSafeThread4D.CheckCancel(LParams, AContext);
            TThread.Sleep(RETRY_WORK_MS div 20);
            TSafeThread4D.ReportProgress(LParams, I / 20);
          end;

          if FRetryForceFailure or (AAttempt <= RETRY_MAX) then
            raise Exception.Create(
              Format('Simulated failure on attempt %d', [AAttempt]));
        end);

  if not FIsClosing then
  begin
    MemoRetryLog.Lines.Add(Format('[Attempt %d] Working...', [AAttempt]));
    lblRetryStatus.Text := Format('Attempt %d of %d...', [AAttempt, RETRY_MAX + 1]);
  end;

  TSafeThread4D.StartThreadWithWeakRef(LParams, LParamsRaw, FRetryParams);
end;

procedure TFormMain.ScheduleRetryAttempt(const ARunToken, ANextAttempt: Integer);
(*
  SCHEDULE NEXT RETRY
  -------------------

  Purpose
  - Waits outside SafeThread4D for the retry delay, then launches the next
    attempt only if the current run token is still valid.

  Why use an anonymous thread here
  - The delay itself is not the background work we want to demonstrate.
  - The anonymous thread is only a simple timing gate.
  - SafeThread4D still owns the real attempt execution.

  Why use FRetryDelayCancelEvent.WaitFor instead of TThread.Sleep
  - WaitFor is interruptible. RequestCancelAll signals the event so the
    anonymous thread wakes up immediately on shutdown, queues nothing back
    to the main thread (because the run token is now stale), and exits.
  - The shutdown drain blocks until FRetryPendingDelay becomes False, which
    only happens when the anonymous thread really finishes. This guarantees
    no stray closure or thread outlives the form.
*)
begin
  if FIsClosing or (ARunToken <> FRetryRunToken) then
    Exit;

  FRetryPendingDelay := True;

  // Make sure the event starts in non-signaled state for this delay window.
  // Any previous shutdown signal has already been consumed by the previous
  // delay thread (or never set during normal flow).
  if Assigned(FRetryDelayCancelEvent) then
    FRetryDelayCancelEvent.ResetEvent;

  MemoRetryLog.Lines.Add(Format(
    '[Retry] Waiting %d ms before attempt %d of %d...',
    [RETRY_DELAY_MS, ANextAttempt, RETRY_MAX + 1]));
  lblRetryStatus.Text := Format(
    'Waiting before attempt %d of %d...',
    [ANextAttempt, RETRY_MAX + 1]);
  pbarRetry.Value := 0;

  TThread.CreateAnonymousThread(
    procedure
    var
      LWaitResult: TWaitResult;
    begin
      try
        // Interruptible wait. Returns wrSignaled immediately if the event
        // was signaled (shutdown / cancel) or wrTimeout when the full delay
        // elapsed normally.
        if Assigned(FRetryDelayCancelEvent) then
          LWaitResult := FRetryDelayCancelEvent.WaitFor(RETRY_DELAY_MS)
        else
          LWaitResult := wrTimeout;

        TThread.Queue(nil,
          procedure
          begin
            try
              if FIsClosing or
                 (ARunToken <> FRetryRunToken) or
                 (LWaitResult = wrSignaled) then
                Exit;

              StartRetryAttempt(ARunToken, ANextAttempt);
            finally
              // Clear the pending-delay flag last, so the shutdown drain
              // can observe it and proceed only after this closure has run.
              FRetryPendingDelay := False;
            end;
          end);
      except
        // Defensive: ensure the flag is cleared even if Queue itself fails
        // during shutdown (the RTL queue may be tearing down).
        FRetryPendingDelay := False;
      end;
    end).Start;
end;

procedure TFormMain.btnRetryStartClick(Sender: TObject);
(*
  RETRY START BUTTON
  ------------------

  Starts a new retry run from attempt 1. A new run token invalidates any
  previous delayed retry launch that may still be pending.
*)
begin
  if FIsClosing then
    Exit;

  if Assigned(FRetryParams) or FRetryPendingDelay then
    Exit;

  Inc(FRetryRunToken);
  FRetryForceFailure := chkRetryForceFailure.IsChecked;
  FRetryPendingDelay := False;
  FRetryCurrentAttempt := 1;

  MemoRetryLog.Lines.Clear;
  pbarRetry.Value := 0;
  lblRetryStatus.Text := 'Starting...';

  MemoRetryLog.Lines.Add(Format(
    '[Config] Max retries: %d  |  Delay: %d ms  |  Force failure: %s',
    [RETRY_MAX, RETRY_DELAY_MS, IfThen(FRetryForceFailure, 'YES', 'no')]));

  btnRetryStart.Enabled  := False;
  btnRetryCancel.Enabled := True;

  StartRetryAttempt(FRetryRunToken, 1);
end;

procedure TFormMain.btnRetryCancelClick(Sender: TObject);
(*
  RETRY CANCEL BUTTON
  -------------------

  Invalidate the current run token and cancel the active attempt, if any.
  This also prevents any already-scheduled delayed retry from starting later
  by signaling FRetryDelayCancelEvent so the delay thread wakes up at once.
*)
begin
  if FIsClosing then
    Exit;

  MemoRetryLog.Lines.Add('[User] Cancel requested...');

  Inc(FRetryRunToken);

  // Wake up the delay thread (if any) immediately. It will observe the
  // stale run token and exit without launching the next attempt. The
  // FRetryPendingDelay flag is cleared by the delay thread itself.
  if Assigned(FRetryDelayCancelEvent) then
    FRetryDelayCancelEvent.SetEvent;

  if Assigned(FRetryParams) then
    FRetryParams.RequestCancel
  else if not FRetryPendingDelay then
  begin
    lblRetryStatus.Text    := 'Cancelled.';
    btnRetryStart.Enabled  := True;
    btnRetryCancel.Enabled := False;
  end;
end;

procedure TFormMain.RetryTerminate(Sender: TObject);
begin
  FRetryParams := nil;

  if not FIsClosing and (not FRetryPendingDelay) then
  begin
    btnRetryStart.Enabled  := True;
    btnRetryCancel.Enabled := False;
  end;
end;

{ TFormMain — Debounce }

procedure TFormMain.StartDebouncedSearch(const AToken: Integer; const AQuery: string);
(*
  DEBOUNCED SEARCH START
  ----------------------

  Purpose
  - Starts the real background search only after the debounce window has
    expired and only if the token still matches the latest user input.

  Why this is split in two layers
  - The anonymous thread is used only as a short delay gate.
  - SafeThread4D is then used for the actual background work.

  This separation is intentional:
  - debounce decides when work may start;
  - SafeThread4D executes the work safely once that decision has been made.

  Token rule
  - Each new keystroke increments FDebounceActiveToken.
  - If a delayed launch wakes up with an older token, it is ignored.
  - This prevents stale launches and stale results from reaching the UI.

  Runtime rule
  - Only the most recent query is allowed to start and complete.
*)
var
  LParams   : ISafeThread4DParams;
  LParamsRaw: Pointer;
begin
  if FIsClosing then
    Exit;

  if AToken <> FDebounceActiveToken then
    Exit;

  FDebounceCurrentQuery := AQuery;

  LParams :=
    TSafeThread4DParams.New
      .SetThreadName('Search-Debounce')
      .SetFreeOnTerminate(True)
      .SetMeasureTime(True)
      .SetOnExecute(
        procedure(AContext: TThreadContext)
        var
          I: Integer;
          LParams: ISafeThread4DParams;
        begin
          LParams := ISafeThread4DParams(IInterface(LParamsRaw));
          if LParams = nil then
            raise Exception.Create('Internal error: ParamsRaw not initialized.');

          for I := 1 to 12 do
          begin
            TSafeThread4D.CheckCancel(LParams, AContext);
            TThread.Sleep(SEARCH_WORK_MS div 12);
          end;
        end)
      .SetOnSuccess(
        procedure(AContext: TThreadContext)
        begin
          if FIsClosing or (AToken <> FDebounceActiveToken) then
            Exit;

          Inc(FDebounceDoneCount);
          lblDebounceDoneCount.Text := Format('Completed: %d', [FDebounceDoneCount]);
          lblDebounceStatus.Text := Format(
            'Results for "%s"  (%.0f ms)',
            [FDebounceCurrentQuery, AContext.ElapsedMilliseconds * 1.0]);
          MemoDebounceLog.Lines.Add(Format(
            '[Search done] "%s"  %.0f ms  |  started=%d  completed=%d',
            [FDebounceCurrentQuery, AContext.ElapsedMilliseconds * 1.0,
             FDebounceFireCount, FDebounceDoneCount]));
        end)
      .SetOnError(
        procedure(const AErrorMessage: string; const AContext: TThreadContext)
        begin
          if FIsClosing or (AToken <> FDebounceActiveToken) then
            Exit;

          lblDebounceStatus.Text := 'Error: ' + AErrorMessage;
          MemoDebounceLog.Lines.Add('[Error] ' + AErrorMessage);
        end)
      .SetOnTerminateEvent(DebounceTerminate);

  lblDebounceStatus.Text := Format('Searching "%s"...', [AQuery]);
  TSafeThread4D.StartThreadWithWeakRef(LParams, LParamsRaw, FDebounceParams);
end;

procedure TFormMain.edtSearchChangeTracking(Sender: TObject);
(*
  DEBOUNCE TRIGGER
  ----------------

  Purpose
  - Reacts to user typing and schedules a delayed search instead of starting
    work immediately on every keystroke.

  Strategy
  1) Cancel the currently running search, if any.
  2) Generate a new token that invalidates any older delayed launch.
  3) Start a short anonymous thread that waits DEBOUNCE_MS.
  4) Return to the main thread with Queue.
  5) Start the real SafeThread4D search only if the token is still current.

  Why both cancel + token are needed
  - Cancel stops a search that is already running.
  - The token prevents an older delayed trigger from starting after a newer
    keystroke has already happened.

  Why use an anonymous thread here
  - In this demo, the anonymous thread exists only to model the debounce delay.
  - The actual search work is still executed by SafeThread4D.
  - This makes the flow easy to understand:
      typing -> wait a little -> then launch the real worker.

  Note
  - For production code, a UI timer can also be a good debounce mechanism.
    Here, the anonymous-thread delay is kept because it makes the separation
    between "delay before launch" and "actual background execution" very clear.
*)
var
  LQuery: string;
  LToken: Integer;
begin
  if FIsClosing then
    Exit;

  if Assigned(FDebounceParams) then
    FDebounceParams.RequestCancel;

  LQuery := Trim(edtSearch.Text);

  Inc(FDebounceActiveToken);
  LToken := FDebounceActiveToken;

  if LQuery = '' then
  begin
    lblDebounceStatus.Text := 'Type something to search...';
    Exit;
  end;

  FDebounceCurrentQuery := LQuery;
  Inc(FDebounceFireCount);
  lblDebounceFireCount.Text := Format('Started: %d', [FDebounceFireCount]);

  lblDebounceStatus.Text := Format(
    'Waiting %d ms before searching "%s"...',
    [DEBOUNCE_MS, LQuery]);

  TThread.CreateAnonymousThread(
    procedure
    begin
      TThread.Sleep(DEBOUNCE_MS);
      TThread.Queue(nil,
        procedure
        begin
          if FIsClosing or (LToken <> FDebounceActiveToken) then
            Exit;

          StartDebouncedSearch(LToken, LQuery);
        end);
    end).Start;
end;

procedure TFormMain.DebounceTerminate(Sender: TObject);
(*
  Clears the authoritative params reference for the current debounced search.
  The token remains the source of truth for deciding whether a launch/result
  is still current.
*)
begin
  if FDebounceActiveToken > 0 then
    FDebounceParams := nil;
end;

{ TFormMain — Pipeline }

procedure TFormMain.CancelPipeline;
(*
  PIPELINE CANCEL
  ---------------

  Cancels whichever step is currently active. The pipeline is modeled as
  three independent SafeThread4D tasks chained through OnSuccess.
*)
begin
  if Assigned(FPipeline1Params) then FPipeline1Params.RequestCancel;
  if Assigned(FPipeline2Params) then FPipeline2Params.RequestCancel;
  if Assigned(FPipeline3Params) then FPipeline3Params.RequestCancel;
end;

procedure TFormMain.PipelineStep1;
(*
  PIPELINE STEP 1
  ---------------

  Demonstrates a staged flow in which each step is a separate SafeThread4D
  task. On success, Step 1 starts Step 2.
*)
var
  LParams   : ISafeThread4DParams;
  LParamsRaw: Pointer;
begin
  if FIsClosing then Exit;
  MemoPipelineLog.Lines.Add('[Step 1] Validating data...');

  LParams :=
    TSafeThread4DParams.New
      .SetThreadName('Pipeline-Step1')
      .SetFreeOnTerminate(True)
      .SetMeasureTime(True)
      .SetProgressIntervalMs(60)
      .SetOnProgress(
        procedure(APct: Single)
        begin
          if FIsClosing then Exit;
          pbarPipeline.Value := APct * 100;
          lblPipelineStatus.Text := Format(
            'Step 1/3 — Validating data... %.0f%%',
            [APct / 0.33 * 100]);
        end)
      .SetOnSuccess(
        procedure(AContext: TThreadContext)
        begin
          if FIsClosing then Exit;
          MemoPipelineLog.Lines.Add(Format(
            '[Step 1] Done in %.0f ms.', [AContext.ElapsedMilliseconds * 1.0]));
          PipelineStep2;
        end)
      .SetOnCancel(
        procedure(AContext: TThreadContext)
        begin
          if FIsClosing then Exit;
          MemoPipelineLog.Lines.Add('[Step 1] Cancelled.');
          lblPipelineStatus.Text    := 'Cancelled.';
          btnPipelineStart.Enabled  := True;
          btnPipelineCancel.Enabled := False;
        end)
      .SetOnError(
        procedure(const AErrorMessage: string; const AContext: TThreadContext)
        begin
          if FIsClosing then Exit;
          MemoPipelineLog.Lines.Add('[Step 1][Error] ' + AErrorMessage);
          lblPipelineStatus.Text    := 'Error in Step 1: ' + AErrorMessage;
          btnPipelineStart.Enabled  := True;
          btnPipelineCancel.Enabled := False;
        end)
      .SetOnTerminateEvent(Pipeline1Terminate)
      .SetOnExecute(
        procedure(AContext: TThreadContext)
        var
          I: Integer;
          LParams: ISafeThread4DParams;
        begin
          LParams := ISafeThread4DParams(IInterface(LParamsRaw));
          if LParams = nil then
            raise Exception.Create('Internal error: ParamsRaw not initialized.');

          for I := 1 to 30 do
          begin
            TSafeThread4D.CheckCancel(LParams, AContext);
            TThread.Sleep(PIPELINE_STEP1_MS div 30);
            TSafeThread4D.ReportProgress(LParams, (I / 30) * 0.33);
          end;
        end);

  TSafeThread4D.StartThreadWithWeakRef(LParams, LParamsRaw, FPipeline1Params);
end;

procedure TFormMain.PipelineStep2;
(*
  PIPELINE STEP 2
  ---------------

  Continues the staged flow. The displayed percentage is normalized from the
  global pipeline range back into the local step range for readability.
*)
var
  LParams   : ISafeThread4DParams;
  LParamsRaw: Pointer;
begin
  if FIsClosing then Exit;
  MemoPipelineLog.Lines.Add('[Step 2] Processing records...');

  LParams :=
    TSafeThread4DParams.New
      .SetThreadName('Pipeline-Step2')
      .SetFreeOnTerminate(True)
      .SetMeasureTime(True)
      .SetProgressIntervalMs(60)
      .SetOnProgress(
        procedure(APct: Single)
        var
          LNormalized: Double;
        begin
          if FIsClosing then Exit;
          pbarPipeline.Value := APct * 100;
          LNormalized := (APct - 0.33) / 0.33;
          lblPipelineStatus.Text := Format(
            'Step 2/3 — Processing records... %.0f%%',
            [LNormalized * 100]);
        end)
      .SetOnSuccess(
        procedure(AContext: TThreadContext)
        begin
          if FIsClosing then Exit;
          MemoPipelineLog.Lines.Add(Format(
            '[Step 2] Done in %.0f ms.', [AContext.ElapsedMilliseconds * 1.0]));
          PipelineStep3;
        end)
      .SetOnCancel(
        procedure(AContext: TThreadContext)
        begin
          if FIsClosing then Exit;
          MemoPipelineLog.Lines.Add('[Step 2] Cancelled.');
          lblPipelineStatus.Text    := 'Cancelled.';
          btnPipelineStart.Enabled  := True;
          btnPipelineCancel.Enabled := False;
        end)
      .SetOnError(
        procedure(const AErrorMessage: string; const AContext: TThreadContext)
        begin
          if FIsClosing then Exit;
          MemoPipelineLog.Lines.Add('[Step 2][Error] ' + AErrorMessage);
          lblPipelineStatus.Text    := 'Error in Step 2: ' + AErrorMessage;
          btnPipelineStart.Enabled  := True;
          btnPipelineCancel.Enabled := False;
        end)
      .SetOnTerminateEvent(Pipeline2Terminate)
      .SetOnExecute(
        procedure(AContext: TThreadContext)
        var
          I: Integer;
          LParams: ISafeThread4DParams;
        begin
          LParams := ISafeThread4DParams(IInterface(LParamsRaw));
          if LParams = nil then
            raise Exception.Create('Internal error: ParamsRaw not initialized.');

          for I := 1 to 40 do
          begin
            TSafeThread4D.CheckCancel(LParams, AContext);
            TThread.Sleep(PIPELINE_STEP2_MS div 40);
            TSafeThread4D.ReportProgress(LParams, 0.33 + (I / 40) * 0.33);
          end;
        end);

  TSafeThread4D.StartThreadWithWeakRef(LParams, LParamsRaw, FPipeline2Params);
end;

procedure TFormMain.PipelineStep3;
(*
  PIPELINE STEP 3
  ---------------

  Final stage of the staged flow. On success, this step restores the main
  pipeline UI state to idle.
*)
var
  LParams   : ISafeThread4DParams;
  LParamsRaw: Pointer;
begin
  if FIsClosing then Exit;
  MemoPipelineLog.Lines.Add('[Step 3] Saving results...');

  LParams :=
    TSafeThread4DParams.New
      .SetThreadName('Pipeline-Step3')
      .SetFreeOnTerminate(True)
      .SetMeasureTime(True)
      .SetProgressIntervalMs(60)
      .SetOnProgress(
        procedure(APct: Single)
        var
          LNormalized: Double;
        begin
          if FIsClosing then Exit;
          pbarPipeline.Value := APct * 100;
          LNormalized := (APct - 0.66) / 0.34;
          lblPipelineStatus.Text := Format(
            'Step 3/3 — Saving results... %.0f%%',
            [LNormalized * 100]);
        end)
      .SetOnSuccess(
        procedure(AContext: TThreadContext)
        begin
          if FIsClosing then Exit;
          MemoPipelineLog.Lines.Add(Format(
            '[Step 3] Done in %.0f ms.', [AContext.ElapsedMilliseconds * 1.0]));
          pbarPipeline.Value := 100;
          lblPipelineStatus.Text := 'Pipeline complete.';
          MemoPipelineLog.Lines.Add(
            '[Pipeline] All 3 steps completed successfully.');
        end)
      .SetOnCancel(
        procedure(AContext: TThreadContext)
        begin
          if FIsClosing then Exit;
          MemoPipelineLog.Lines.Add('[Step 3] Cancelled.');
          lblPipelineStatus.Text := 'Cancelled.';
        end)
      .SetOnError(
        procedure(const AErrorMessage: string; const AContext: TThreadContext)
        begin
          if FIsClosing then Exit;
          MemoPipelineLog.Lines.Add('[Step 3][Error] ' + AErrorMessage);
          lblPipelineStatus.Text := 'Error in Step 3: ' + AErrorMessage;
        end)
      .SetOnTerminateEvent(Pipeline3Terminate)
      .SetOnExecute(
        procedure(AContext: TThreadContext)
        var
          I: Integer;
          LParams: ISafeThread4DParams;
        begin
          LParams := ISafeThread4DParams(IInterface(LParamsRaw));
          if LParams = nil then
            raise Exception.Create('Internal error: ParamsRaw not initialized.');

          for I := 1 to 20 do
          begin
            TSafeThread4D.CheckCancel(LParams, AContext);
            TThread.Sleep(PIPELINE_STEP3_MS div 20);
            TSafeThread4D.ReportProgress(LParams, 0.66 + (I / 20) * 0.34);
          end;
        end);

  TSafeThread4D.StartThreadWithWeakRef(LParams, LParamsRaw, FPipeline3Params);
end;

procedure TFormMain.btnPipelineStartClick(Sender: TObject);
(*
  PIPELINE START BUTTON
  ---------------------

  Starts the first step only if the pipeline is completely idle.
*)
begin
  if FIsClosing then Exit;
  if Assigned(FPipeline1Params) or
     Assigned(FPipeline2Params) or
     Assigned(FPipeline3Params) then Exit;

  MemoPipelineLog.Lines.Clear;
  pbarPipeline.Value     := 0;
  lblPipelineStatus.Text := 'Starting pipeline...';
  btnPipelineStart.Enabled  := False;
  btnPipelineCancel.Enabled := True;

  PipelineStep1;
end;

procedure TFormMain.btnPipelineCancelClick(Sender: TObject);
(*
  PIPELINE CANCEL BUTTON
  ----------------------

  Requests cooperative cancellation for whichever pipeline step is currently
  active.
*)
begin
  if Assigned(FPipeline1Params) or
     Assigned(FPipeline2Params) or
     Assigned(FPipeline3Params) then
  begin
    if not FIsClosing then
      MemoPipelineLog.Lines.Add('[User] Cancel requested...');
    CancelPipeline;
  end;
end;

procedure TFormMain.Pipeline1Terminate(Sender: TObject);
begin
  FPipeline1Params := nil;
end;

procedure TFormMain.Pipeline2Terminate(Sender: TObject);
begin
  FPipeline2Params := nil;
end;

procedure TFormMain.Pipeline3Terminate(Sender: TObject);
begin
  FPipeline3Params := nil;

  if not FIsClosing then
  begin
    btnPipelineStart.Enabled  := True;
    btnPipelineCancel.Enabled := False;
  end;
end;

{ TFormMain — Shutdown }

procedure TFormMain.RequestCancelAll;
(*
  Invalidates pending retry/debounce delayed launches and requests cooperative
  cancellation for active background tasks.

  Note about FRetryDelayCancelEvent:
  - Signaling this event wakes up the anonymous thread inside
    ScheduleRetryAttempt immediately, even if it was sleeping on a long
    RETRY_DELAY_MS window. The delay thread is responsible for clearing
    FRetryPendingDelay on its way out.
*)
begin
  Inc(FRetryRunToken);

  // Wake up the retry delay thread (if any) so it does not keep sleeping
  // through the shutdown drain. FRetryPendingDelay will be cleared by the
  // delay thread itself, which is what AllReleased waits for.
  if Assigned(FRetryDelayCancelEvent) then
    FRetryDelayCancelEvent.SetEvent;

  Inc(FDebounceActiveToken);

  if Assigned(FRetryParams)    then FRetryParams.RequestCancel;
  if Assigned(FDebounceParams) then FDebounceParams.RequestCancel;

  CancelPipeline;
end;

function TFormMain.AllReleased: Boolean;
begin
  // FRetryPendingDelay must also be False here. It is the flag that tells
  // us the anonymous delay thread has finished and its queued closure (if
  // any) has executed on the main thread. Without this check, the shutdown
  // drain could return while the delay thread was still sleeping, which is
  // exactly the case that produced the original memory leak.
  Result :=
    (not FRetryPendingDelay) and
    (FRetryParams     = nil) and
    (FDebounceParams  = nil) and
    (FPipeline1Params = nil) and
    (FPipeline2Params = nil) and
    (FPipeline3Params = nil);
end;

procedure TFormMain.DrainUntilReleased(const ATimeoutMs: Integer);
(*
  Bounded UI-thread drain used only during form shutdown.

  Why this is useful
  - During shutdown, workers or delayed flow callbacks may already be finished
    logically but still be waiting for their marshalled UI-side callbacks to
    run on the main thread.
  - If those callbacks do not run, params references may stay published and
    the close sequence can appear to hang even though cancellation has already
    propagated.

  Why CheckSynchronize is used
  - It is the RTL API intended to drain pending Synchronize / Queue work.
  - This example intentionally does not rely on Application.ProcessMessages
    as a drain mechanism in FMX.

  The quiet-flush window keeps draining callbacks for a short period even
  after AllReleased becomes true, so very late queued UI work can settle
  before the form disappears.
*)
var
  LStart     : UInt64;
  LQuietStart: UInt64;
begin
  LStart      := TThread.GetTickCount64;
  LQuietStart := 0;

  while True do
  begin
    CheckSynchronize(10);

    if AllReleased then
    begin
      if LQuietStart = 0 then
        LQuietStart := TThread.GetTickCount64
      else if (TThread.GetTickCount64 - LQuietStart) >= DRAIN_QUIET_FLUSH_MS then
        Break;
    end
    else
      LQuietStart := 0;

    if (ATimeoutMs > 0) and
       (TThread.GetTickCount64 - LStart >= UInt64(ATimeoutMs)) then
      Break;
  end;
end;

end.
