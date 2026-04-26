// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Eduardo P. Araujo
// https://github.com/eduardoparaujo/SafeThread4D

{*
  Unit   : SafeThread.Concurrency.Demo.Main
  Purpose: Multi-tool SafeThread4D demo covering cooperative timeout,
           cooperative cancellation, progress publication, CPU-bound work,
           parallel fan-out/fan-in, closure patterns, and deliberate
           UI blocking for ANR awareness.

  Part of the SafeThread4D examples.

  Author        : Eduardo P. Araujo
  Created       : 2026-04-26
  Last modified : 2026-04-26
  Version       : 1.0.0

  Notes:
    - This unit is an example form, not part of the SafeThread4D runtime.
    - btnWrongUseClick intentionally demonstrates a retain cycle and a leak.
    - Shutdown draining uses CheckSynchronize as a bounded host-app close
      policy so pending UI-thread terminations can complete cleanly.
*}

unit SafeThread.Concurrency.Demo.Main;

interface

uses
  System.Classes,
  System.Diagnostics,
  System.SyncObjs,
  System.SysUtils,
  System.UITypes,
  System.Variants,

  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}

  FMX.Controls.Presentation,
  FMX.Controls,
  FMX.Edit,
  FMX.Forms,
  FMX.Memo,
  FMX.Memo.Types,
  FMX.Objects,
  FMX.ScrollBox,
  FMX.StdCtrls,
  FMX.TabControl,
  FMX.Types,

  SafeThread4D;

type
  TFormMain = class(TForm)
    btnTimeoutDemo      : TButton;
    btnStartWaitDemo    : TButton;
    btnCpuLoop          : TButton;
    btnCpuLoopCancel    : TButton;
    btnBenchA           : TButton;
    btnBenchB           : TButton;
    btnParallel         : TButton;
    pbarCpuLoop         : TProgressBar;
    TabControl          : TTabControl;
    tabConcurrencyBench : TTabItem;
    rctBenchB           : TRectangle;
    MemoBenchB          : TMemo;
    btnWrongUse         : TButton;
    tabPatterns         : TTabItem;
    btnRightUse         : TButton;
    rctWrongRightLog    : TRectangle;
    MemoWrongRightLog   : TMemo;
    rctStartWait        : TRectangle;
    MemoStartWait       : TMemo;
    rctTimeOut          : TRectangle;
    MemoTimeOut         : TMemo;
    rctParallelLog      : TRectangle;
    MemoParallelLog     : TMemo;
    rctCPULoopLog       : TRectangle;
    MemoCPULoopLog      : TMemo;
    rctBenchA           : TRectangle;
    MemoBenchA          : TMemo;
    pbarParallel        : TProgressBar;
    btnForceAnr         : TButton;
    edtANR              : TEdit;
    rctLog              : TRectangle;
    MemoLog             : TMemo;

    procedure btnTimeoutDemoClick(Sender: TObject);
    procedure btnStartWaitDemoClick(Sender: TObject);
    procedure btnCpuLoopClick(Sender: TObject);
    procedure btnCpuLoopCancelClick(Sender: TObject);
    procedure btnBenchAClick(Sender: TObject);
    procedure btnBenchBClick(Sender: TObject);
    procedure btnParallelClick(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure btnWrongUseClick(Sender: TObject);
    procedure btnRightUseClick(Sender: TObject);
    procedure btnForceAnrClick(Sender: TObject);

  private
    { Private declarations }

    // Concurrency & Bench.
    FTimeoutParams      : ISafeThread4DParams;
    FStartWaitParams    : ISafeThread4DParams;
    FCPULoopParams      : ISafeThread4DParams;
    FBenchAParams       : ISafeThread4DParams;
    FBenchBParams       : ISafeThread4DParams;
    FParallelData       : TArray<Integer>;
    FParallelParams     : TArray<ISafeThread4DParams>;
    FParallelPrepParams : ISafeThread4DParams;
    FParallelRemaining  : Integer;
    FParallelSum        : Int64;
    FIsClosing          : Boolean;

    // Patterns (wrong vs right).
    FWrongParams, FRightParams: ISafeThread4DParams;

    // Parallel fan-out.
    procedure LaunchWorkers(const AWorkerCount: Integer);

    // Shutdown.
    procedure RequestCancelAll;
    function AllReleased: Boolean;
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
  DRAIN_TIMEOUT_MS = 15_000; // 15 s to close elegantly.

{ TFormMain — Concurrency & Bench }

procedure TFormMain.btnCpuLoopClick(Sender: TObject);
(*
  CPU-CANCEL DEMO (tight CPU loop with cooperative cancel and progress throttle).

  Purpose
  - Stress CPU with nested loops while remaining cancellable and UI-responsive.

  Key points
  - Rebuild Params from a weak pointer inside OnExecute (avoids retain cycles).
  - Cooperative cancel checks in the outer loop and also every 4096 inner
    iterations.
  - Progress updates throttled to ~60 ms minimum.
  - Optional pacing knobs to slow the run so the Cancel button is testable.
*)
var
  LParams   : ISafeThread4DParams;
  LParamsRaw: Pointer; // Weak pointer to avoid capturing 'LParams' inside closures.
begin
  // If a run is active and not cancelled, ignore this click.
  if Assigned(FCPULoopParams) and not FCPULoopParams.CancelRequested then
    Exit;

  MemoCPULoopLog.Lines.Clear;
  pbarCpuLoop.Value := 0;
  MemoCPULoopLog.Lines.Add('CPU test...');

  LParams :=
    TSafeThread4DParams.New
      .SetThreadName('CPU-Cancel-Demo')
      .SetFreeOnTerminate(True)
      .SetMeasureTime(True)
      .SetOnProgress(
        procedure(APct: Single)
        begin
          pbarCpuLoop.Value := APct * 100;
        end)
      .SetProgressIntervalMs(60)
      .SetOnExecute(
        procedure(AContext: TThreadContext)
        var
          LOuter, LInner, LTotal: Int64;
          LCount: UInt64;
          LSw: TStopwatch;
          LMinStepMs: Integer;
          LParams: ISafeThread4DParams; // Scoped strong ref.
        begin
          // Weak -> Strong.
          LParams := ISafeThread4DParams(IInterface(LParamsRaw));
          if LParams = nil then
            raise Exception.Create('Internal error: ParamsRaw not initialized.');

          LTotal := 500;
          LMinStepMs := 80; // 50..150 ms per outer step.
          LCount := 0;

          for LOuter := 1 to LTotal do
          begin
            TSafeThread4D.CheckCancel(LParams, AContext);

            LSw := TStopwatch.StartNew;

            // "Hot" (CPU-bound) work.
            for LInner := 1 to 100_000 do
            begin
              LCount := LCount xor UInt64(LOuter * LInner);

              // Check every 4096 iterations.
              if (LInner and $FFF) = 0 then
                TSafeThread4D.CheckCancel(LParams, AContext);
            end;

            // Padding until reaching LMinStepMs (yields CPU and keeps cancel responsive).
            while LSw.ElapsedMilliseconds < LMinStepMs do
            begin
              TSafeThread4D.CheckCancel(LParams, AContext);
              TThread.Sleep(1);
            end;

            if (LOuter mod 5) = 0 then
              TSafeThread4D.ReportProgress(LParams, LOuter / LTotal);
          end;
        end)
      .SetOnCancel(
        procedure(AContext: TThreadContext)
        begin
          MemoCPULoopLog.Lines.Add('[Cancel] Loop stopped promptly by user.');
        end)
      .SetOnTerminate(
        procedure(AContext: TThreadContext)
        begin
          MemoCPULoopLog.Lines.Add('CPU demo finished');
          FCPULoopParams := nil;
        end);

  TSafeThread4D.StartThreadWithWeakRef(LParams, LParamsRaw, FCPULoopParams);
end;

procedure TFormMain.btnCpuLoopCancelClick(Sender: TObject);
begin
  if Assigned(FCPULoopParams) then
  begin
    MemoCPULoopLog.Lines.Add('[User] Cancellation request...');
    FCPULoopParams.RequestCancel;
  end;
end;

procedure TFormMain.btnParallelClick(Sender: TObject);
(*
  PARALLEL SUM — Fan-out + fan-in demo.

  - Prepares a large array in a background thread.
  - Fans out to N workers, each summing a slice.
  - Fan-in via TInterlocked.Add on FParallelSum.
*)
const
  NWORKERS = 4;
  N = 200_000_000;
var
  LPrep: ISafeThread4DParams;
begin
  if Assigned(FParallelPrepParams) then
    Exit;

  MemoParallelLog.Lines.Clear;
  MemoParallelLog.Lines.Add('Parallel sum: preparing data...');

  LPrep :=
    TSafeThread4DParams.New
      .SetThreadName('Parallel-Prepare')
      .SetFreeOnTerminate(True)
      .SetMeasureTime(True)
      .SetOnProgress(
        procedure(APct: Single)
        begin
          pbarParallel.Value := APct * 100;
        end)
      .SetProgressIntervalMs(50)
      .SetOnExecute(
        procedure(AContext: TThreadContext)
        var
          I, LBlock, LProcessed: Integer;
        begin
          SetLength(FParallelData, N);
          LBlock := 262_144; // 256K.
          LProcessed := 0;

          for I := 0 to N - 1 do
          begin
            if (LProcessed and (LBlock - 1)) = 0 then
            begin
              TSafeThread4D.CheckCancel(FParallelPrepParams, AContext);
              TSafeThread4D.ReportProgress(FParallelPrepParams, LProcessed / N);
              TThread.Sleep(1); // Gentle yield.
            end;

            FParallelData[I] := 1;
            Inc(LProcessed);
          end;

          TSafeThread4D.CheckCancel(FParallelPrepParams, AContext);
          TSafeThread4D.ReportProgress(FParallelPrepParams, 1.0, True);
        end)
      .SetOnSuccess(
        procedure(AContext: TThreadContext)
        begin
          MemoParallelLog.Lines.Add('Data ready. Launching workers...');
          LaunchWorkers(NWORKERS);
        end)
      .SetOnError(
        procedure(const AErrorMessage: string; const AContext: TThreadContext)
        begin
          MemoParallelLog.Lines.Add('[Prepare error] ' + AErrorMessage);
          SetLength(FParallelData, 0);
        end)
      .SetOnTerminate(
        procedure(AContext: TThreadContext)
        begin
          FParallelPrepParams := nil;
        end);

  FParallelPrepParams := LPrep;
  TSafeThread4D.StartThread(LPrep);
end;

procedure TFormMain.btnTimeoutDemoClick(Sender: TObject);
(*
  TIMEOUT DEMO — Cooperative timeout with progress throttling (weak-pointer Params).

  Note: progress de-duplication is performed inside OnExecute (LLastPctSent),
  so the OnProgress closure does not need to capture any outer state.
*)
var
  LParams   : ISafeThread4DParams;
  LParamsRaw: Pointer;
begin
  if Assigned(FTimeoutParams) then
    Exit;

  LParams :=
    TSafeThread4DParams.New
      .SetThreadName('Timeout Demo')
      .SetFreeOnTerminate(True)
      .SetTimeoutMs(3000)
      .SetMeasureTime(True)
      .SetOnInitialize(
        procedure(AContext: TThreadContext)
        begin
          MemoTimeOut.Lines.Clear;

          if Sender is TButton then
            TButton(Sender).Enabled := False;

          MemoTimeOut.Lines.Add('[Init] Timeout Demo started...');
        end)
      .SetOnProgress(
        procedure(APct: Single)
        begin
          MemoTimeOut.Lines.Add(Format('[Progress] %d%%', [Trunc(APct * 100)]));
        end)
      .SetProgressIntervalMs({$IFDEF ANDROID}250{$ELSE}200{$ENDIF})
      .SetOnTimeout(
        procedure(AContext: TThreadContext)
        begin
          MemoTimeOut.Lines.Add('[Timeout] Time has run out.');
        end)
      .SetOnError(
        procedure(const AErrorMessage: string; const AContext: TThreadContext)
        begin
          MemoTimeOut.Lines.Add('[Error] ' + AErrorMessage);
        end)
      .SetOnTerminate(
        procedure(AContext: TThreadContext)
        begin
          MemoTimeOut.Lines.Add(
            Format('[Terminate] Time elapsed: %.3fs', [AContext.ElapsedMilliseconds / 1000]));
          btnTimeoutDemo.Enabled := True;
          FTimeoutParams := nil;
        end)
      .SetOnExecute(
        procedure(AContext: TThreadContext)
        var
          I, LTotal: Integer;
          LLastPctSent, LPctInt: Integer;
          LParams: ISafeThread4DParams; // Scoped strong ref.
        begin
          // Weak -> Strong.
          LParams := ISafeThread4DParams(IInterface(LParamsRaw));
          if LParams = nil then
            raise Exception.Create('Internal error: ParamsRaw not initialized.');

          LTotal := 1_000_000_000;
          LLastPctSent := -1;

          for I := 1 to LTotal do
          begin
            // Cooperative checks.
            TSafeThread4D.CheckCancel(LParams, AContext);
            TSafeThread4D.CheckTimeout(LParams, AContext);

            // Every ~262,144 iterations, calculate integer %.
            if (I and $3FFFF) = 0 then
            begin
              LPctInt := Integer((Int64(I) * 100) div LTotal);

              if LPctInt <> LLastPctSent then
              begin
                LLastPctSent := LPctInt;
                TSafeThread4D.ReportProgress(LParams, LPctInt / 100.0);
              end;

              {$IFDEF ANDROID}
              TThread.Yield;
              {$ENDIF}
            end;
          end;
        end);

  TSafeThread4D.StartThreadWithWeakRef(LParams, LParamsRaw, FTimeoutParams);
end;

procedure TFormMain.btnStartWaitDemoClick(Sender: TObject);
(*
  START/WAIT DEMO — Short background task with progress (weak-pointer Params).
*)
var
  LParams   : ISafeThread4DParams;
  LParamsRaw: Pointer; // Weak pointer to avoid capturing 'LParams' inside closures.
begin
  if Assigned(FStartWaitParams) then
    Exit;

  if Sender is TButton then
    TButton(Sender).Enabled := False;

  LParams :=
    TSafeThread4DParams.New
      .SetThreadName('Start/Wait Demo')
      .SetFreeOnTerminate(True)
      .SetMeasureTime(True)
      .SetOnInitialize(
        procedure(AContext: TThreadContext)
        begin
          MemoStartWait.Lines.Clear;
          MemoStartWait.Lines.Add('[Init] Start/Wait Demo...');
        end)
      .SetOnProgress(
        procedure(APct: Single)
        begin
          MemoStartWait.Lines.Add(Format('[Progress] %.0f%%', [APct * 100]));
        end)
      .SetProgressIntervalMs(100)
      .SetOnTerminate(
        procedure(AContext: TThreadContext)
        begin
          MemoStartWait.Lines.Add(
            Format('[Terminate] Time Elapsed: %.3fs', [AContext.ElapsedMilliseconds / 1000]));
          btnStartWaitDemo.Enabled := True;
          FStartWaitParams := nil; // Allow next run.
        end)
      .SetCompleteWithError(False)
      .SetOnExecute(
        procedure(AContext: TThreadContext)
        var
          I: Integer;
          LParams: ISafeThread4DParams; // Scoped strong ref.
        begin
          // Weak -> Strong.
          LParams := ISafeThread4DParams(IInterface(LParamsRaw));
          if LParams = nil then
            raise Exception.Create('Internal error: ParamsRaw not initialized.');

          for I := 1 to 50 do
          begin
            TSafeThread4D.CheckCancel(LParams, AContext);

            // Simulate work.
            TThread.Sleep(50);

            // Progress every 5 steps (~10%).
            if (I mod 5) = 0 then
              TSafeThread4D.ReportProgress(LParams, I / 50);
          end;
        end);

  TSafeThread4D.StartThreadWithWeakRef(LParams, LParamsRaw, FStartWaitParams);
end;

procedure TFormMain.btnBenchAClick(Sender: TObject);
(*
  BENCH-A — Sleepy I/O benchmark with cooperative cancel + timing.
*)
var
  LParams   : ISafeThread4DParams;
  LParamsRaw: Pointer; // Weak pointer to avoid capturing 'LParams' inside closures.
begin
  if Assigned(FBenchAParams) and not FBenchAParams.CancelRequested then
    Exit;

  MemoBenchA.Lines.Clear;
  MemoBenchA.Lines.Add('Benchmark A...');

  LParams :=
    TSafeThread4DParams.New
      .SetThreadName('Bench-A')
      .SetFreeOnTerminate(True)
      .SetMeasureTime(True)
      .SetOnProgress(
        procedure(APct: Single)
        begin
          MemoBenchA.Lines.Add(Format('[Progress] %.0f%%', [APct * 100]));
        end)
      .SetProgressIntervalMs(100)
      .SetOnExecute(
        procedure(AContext: TThreadContext)
        var
          I: Integer;
          LParams: ISafeThread4DParams; // Scoped strong ref.
        begin
          // Weak -> Strong.
          LParams := ISafeThread4DParams(IInterface(LParamsRaw));
          if LParams = nil then
            raise Exception.Create('Internal error: ParamsRaw not initialized.');

          for I := 1 to 200 do
          begin
            TSafeThread4D.CheckCancel(LParams, AContext);
            TThread.Sleep(5); // Simulated I/O.

            if (I mod 20) = 0 then
              TSafeThread4D.ReportProgress(LParams, I / 200); // ~10% checkpoints.
          end;
        end)
      .SetOnTerminate(
        procedure(AContext: TThreadContext)
        begin
          MemoBenchA.Lines.Add(
            Format('Bench A: %d ms', [AContext.ElapsedMilliseconds]));
          FBenchAParams := nil;
        end);

  TSafeThread4D.StartThreadWithWeakRef(LParams, LParamsRaw, FBenchAParams);
end;

procedure TFormMain.btnBenchBClick(Sender: TObject);
(*
  BENCH-B — CPU-bound nested loops with cooperative cancel, progress & timing.
*)
var
  LParams   : ISafeThread4DParams;
  LParamsRaw: Pointer; // Weak pointer to avoid capturing 'LParams' inside closures.
begin
  // If a run is active and not cancelled, ignore this click.
  if Assigned(FBenchBParams) and not FBenchBParams.CancelRequested then
    Exit;

  MemoBenchB.Lines.Clear;
  MemoBenchB.Lines.Add('Benchmark B...');

  LParams :=
    TSafeThread4DParams.New
      .SetThreadName('Bench-B')
      .SetFreeOnTerminate(True)
      .SetMeasureTime(True)
      .SetOnProgress(
        procedure(APct: Single)
        begin
          MemoBenchB.Lines.Add(Format('[Progress] %.0f%%', [APct * 100]));
        end)
      .SetProgressIntervalMs(60)
      .SetOnExecute(
        procedure(AContext: TThreadContext)
        var
          I, J: Integer;
          LAcc: UInt64;
          LParams: ISafeThread4DParams; // Scoped strong ref.
        begin
          // Weak -> Strong.
          LParams := ISafeThread4DParams(IInterface(LParamsRaw));
          if LParams = nil then
            raise Exception.Create('Internal error: ParamsRaw not initialized.');

          LAcc := 0;
          for I := 1 to 1000 do
          begin
            // Cooperative check on the outer loop.
            TSafeThread4D.CheckCancel(LParams, AContext);

            for J := 1 to 1000 do
            begin
              LAcc := LAcc + UInt64(I * J);
              // Cheap inner check every 1024 iterations.
              if (J and $3FF) = 0 then
                TSafeThread4D.CheckCancel(LParams, AContext);
            end;

            // Progress every 16 outer steps (~1.6%).
            if (I and $0F) = 0 then
              TSafeThread4D.ReportProgress(LParams, I / 1000);
          end;
        end)
      .SetOnTerminate(
        procedure(AContext: TThreadContext)
        begin
          MemoBenchB.Lines.Add(
            Format('Bench B: %d ms', [AContext.ElapsedMilliseconds]));
          FBenchBParams := nil;
        end);

  TSafeThread4D.StartThreadWithWeakRef(LParams, LParamsRaw, FBenchBParams);
end;

procedure TFormMain.btnForceAnrClick(Sender: TObject);
var
  LMs: Integer;
  LSw: TStopwatch;
begin
  // WORST-PRACTICE DEMO: intentionally blocking the main thread.
  // Use ONLY on test devices; on Android this can trigger a real ANR dialog.

  // Parse value or fall back to 10s.
  if not TryStrToInt(edtANR.Text, LMs) then
    LMs := 10_000;

  // Clamp to a "reasonable" range (1s..60s).
  if LMs < 1_000 then
    LMs := 1_000;
  if LMs > 60_000 then
    LMs := 60_000;

  MemoLog.Lines.Add(
    Format('[ANR demo] Blocking UI thread for %d ms (DO NOT do this in real code).', [LMs])
  );

  btnForceAnr.Enabled := False;
  try
    // This is exactly what we want to demonstrate as WRONG:
    // long, blocking work on the main thread.
    LSw := TStopwatch.StartNew;
    TThread.Sleep(LMs);
  finally
    btnForceAnr.Enabled := True;
    MemoLog.Lines.Add(
      Format('[ANR demo] UI thread is back after %d ms of unresponsiveness. Use workers + heartbeat instead.',
        [LSw.ElapsedMilliseconds]));
  end;
end;

{ TFormMain — Patterns: Wrong vs Right }

procedure TFormMain.btnWrongUseClick(Sender: TObject);
(*
  WRONG PATTERN — Capturing the params interface inside the closure.

  - Closure captures 'LParams' and 'LParams' holds the closure -> reference cycle.

  OBSERVABLE EFFECT
  - After clicking this button and closing the application, you will see
    a memory leak report (ReportMemoryLeaksOnShutdown = True in the .dpr).
  - This leak is INTENTIONAL and is exactly the point of this demo:
    the retain cycle prevents TSafeThread4DParams from ever being freed.
  - Compare with btnRightUseClick — that pattern does NOT leak.
*)
var
  LParams: ISafeThread4DParams; // Interface variable (reference counted).
  LN: Integer;
begin
  LN := 5_000_000;

  LParams :=
    TSafeThread4DParams.New
      .SetThreadName('Demo-Wrong')
      .SetMeasureTime(True)
      .SetOnInitialize(
        procedure(AContext: TThreadContext)
        begin
          MemoWrongRightLog.Lines.Clear;
          MemoWrongRightLog.Lines.Add('[Wrong] Starting...');
          MemoWrongRightLog.Lines.Add('[Wrong] NOTE: closing the app now will report a memory leak.');
          MemoWrongRightLog.Lines.Add('[Wrong] That leak is the demo. The closure captured ''LParams'',');
          MemoWrongRightLog.Lines.Add('[Wrong] creating a retain cycle that prevents cleanup.');
          MemoWrongRightLog.Lines.Add('[Wrong] Click "Right Use" to see the correct pattern (no leak).');
        end)
      .SetOnProgress(
        procedure(APct: Single)
        begin
          MemoWrongRightLog.Lines.Add(Format('[Wrong] %.0f%%', [APct * 100]));
        end)
      .SetProgressIntervalMs(100)
      // ERROR: the closure CAPTURES 'LParams' (builds the LParams <-> closure cycle).
      .SetOnExecute(
        procedure(AContext: TThreadContext)
        var
          I: Integer;
        begin
          for I := 1 to LN do
          begin
            // Using 'LParams' here captures it in the closure:
            if LParams.CancelRequested then
              Exit;

            if (I and $3FFFF) = 0 then
              // Using 'LParams' again still captures it:
              TSafeThread4D.ReportProgress(LParams, I / LN);
          end;
        end)
      .SetOnError(
        procedure(const AErrorMessage: string; const AContext: TThreadContext)
        begin
          MemoWrongRightLog.Lines.Add('[Wrong][Error] ' + AErrorMessage);
        end)
      .SetOnTerminate(
        procedure(AContext: TThreadContext)
        begin
          MemoWrongRightLog.Lines.Add(
            Format('[Wrong] Done in %.3fs', [AContext.ElapsedMilliseconds / 1000]));
          // Releases the external strong ref; the internal cycle existed during the run.
          FWrongParams := nil;
        end);

  // External strong ref allows UI-side cancel, but does NOT fix the capture cycle.
  FWrongParams := LParams;
  TSafeThread4D.ExecuteThread(LParams);
end;

procedure TFormMain.btnRightUseClick(Sender: TObject);
(*
  RIGHT PATTERN — "Weak + Strong" (no capture of the params interface).

  - Closure only sees a raw pointer (LParamsRaw).
  - OnExecute rebuilds a local interface from LParamsRaw and uses that.
  - External field FRightParams is the single authoritative strong ref.
*)
var
  LParams   : ISafeThread4DParams; // Interface variable (will NOT be captured).
  LParamsRaw: Pointer;             // Weak snapshot (no AddRef; safe to store in closures).
  LN: Integer;
begin
  LN := 5_000_000;

  LParams :=
    TSafeThread4DParams.New
      .SetThreadName('Demo-Right')
      .SetMeasureTime(True)
      .SetOnInitialize(
        procedure(AContext: TThreadContext)
        begin
          MemoWrongRightLog.Lines.Clear;
          MemoWrongRightLog.Lines.Add('[Right] Starting...');
        end)
      .SetOnProgress(
        procedure(APct: Single)
        begin
          MemoWrongRightLog.Lines.Add(Format('[Right] %.0f%%', [APct * 100]));
        end)
      .SetProgressIntervalMs(100)
      .SetOnExecute(
        procedure(AContext: TThreadContext)
        var
          I: Integer;
          LParams: ISafeThread4DParams; // Scoped strong ref.
        begin
          // Weak -> Strong.
          LParams := ISafeThread4DParams(IInterface(LParamsRaw));
          if LParams = nil then
            raise Exception.Create('Internal error: ParamsRaw not initialized.');

          for I := 1 to LN do
          begin
            // Cooperative cancel (cheap).
            TSafeThread4D.CheckCancel(LParams, AContext);

            if (I and $3FFFF) = 0 then
              TSafeThread4D.ReportProgress(LParams, I / LN);
          end;
        end)
      .SetOnError(
        procedure(const AErrorMessage: string; const AContext: TThreadContext)
        begin
          MemoWrongRightLog.Lines.Add('[Right][Error] ' + AErrorMessage);
        end)
      .SetOnTerminate(
        procedure(AContext: TThreadContext)
        begin
          MemoWrongRightLog.Lines.Add(
            Format('[Right] Done in %.3fs', [AContext.ElapsedMilliseconds / 1000]));
          // Drop the last authoritative strong ref -> object can be destroyed.
          FRightParams := nil;
        end);

  TSafeThread4D.StartThreadWithWeakRef(LParams, LParamsRaw, FRightParams);
end;

{ TFormMain — Parallel fan-out }

procedure TFormMain.LaunchWorkers(const AWorkerCount: Integer);
  procedure StartWorker(const AWorkerIndex, AFromIdx, AToIdx: Integer);
  var
    LParams: ISafeThread4DParams;
  begin
    LParams :=
      TSafeThread4DParams.New
        .SetThreadName(Format('Worker-%d', [AWorkerIndex]))
        .SetFreeOnTerminate(True)
        .SetMeasureTime(True)
        .SetOnExecute(
          procedure(AContext: TThreadContext)
          var
            K: Integer;
            LLocalSum: Int64;
          begin
            LLocalSum := 0;
            for K := AFromIdx to AToIdx do
            begin
              if (K and $3FFFF) = 0 then
                TSafeThread4D.CheckCancel(FParallelParams[AWorkerIndex], AContext);
              Inc(LLocalSum, FParallelData[K]); // read-only.
            end;
            TSafeThread4D.CheckCancel(FParallelParams[AWorkerIndex], AContext);
            TInterlocked.Add(FParallelSum, LLocalSum);
          end)
        .SetOnError(
          procedure(const AErrorMessage: string; const AContext: TThreadContext)
          begin
            MemoParallelLog.Lines.Add(
              Format('[Worker %d error] %s', [AWorkerIndex, AErrorMessage]));
          end)
        .SetOnTerminate(
          procedure(AContext: TThreadContext)
          var
            X: Integer;
          begin
            if TInterlocked.Decrement(FParallelRemaining) = 0 then
            begin
              MemoParallelLog.Lines.Add(
                'Parallel sum completed. Sum = ' + FParallelSum.ToString);
              for X := Low(FParallelParams) to High(FParallelParams) do
                FParallelParams[X] := nil; // Release refs.

              SetLength(FParallelData, 0); // Optional: release buffer.
            end;
          end);

    FParallelParams[AWorkerIndex] := LParams;
    TSafeThread4D.StartThread(LParams);
  end;
var
  LWorkerIndex, LChunk, LFromIdx, LToIdx, LN: Integer;
begin
  LN := Length(FParallelData);
  if LN = 0 then
  begin
    MemoParallelLog.Lines.Add('[Parallel] No data to process.');
    Exit;
  end;

  SetLength(FParallelParams, AWorkerCount);
  FParallelSum       := 0;
  FParallelRemaining := AWorkerCount;

  LChunk := LN div AWorkerCount;
  if LChunk <= 0 then
    LChunk := 1;

  for LWorkerIndex := 0 to AWorkerCount - 1 do
  begin
    LFromIdx := LWorkerIndex * LChunk;
    if LWorkerIndex = AWorkerCount - 1 then
      LToIdx := LN - 1
    else
      LToIdx := LFromIdx + LChunk - 1;

    if LFromIdx <= LToIdx then
      StartWorker(LWorkerIndex, LFromIdx, LToIdx);
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
var
  I: Integer;
begin
  // Cancellation for all known tasks.
  Cancel(FTimeoutParams,       'TimeoutDemo');
  Cancel(FStartWaitParams,     'StartWaitDemo');
  Cancel(FCPULoopParams,       'CpuLoop');
  Cancel(FBenchAParams,        'BenchA');
  Cancel(FBenchBParams,        'BenchB');
  Cancel(FWrongParams,         'WrongUse');
  Cancel(FRightParams,         'RightUse');

  Cancel(FParallelPrepParams,  'ParallelPrep');
  for I := Low(FParallelParams) to High(FParallelParams) do
    if Assigned(FParallelParams[I]) then
    begin
      MemoLog.Lines.Add(Format('[Close] Cancel ParallelWorker[%d]', [I]));
      FParallelParams[I].RequestCancel;
    end;
end;

function TFormMain.AllReleased: Boolean;
var
  I: Integer;
begin
  // Single-ref params must all be released.
  Result :=
    (FTimeoutParams       = nil) and
    (FStartWaitParams     = nil) and
    (FCPULoopParams       = nil) and
    (FBenchAParams        = nil) and
    (FBenchBParams        = nil) and
    (FParallelPrepParams  = nil) and
    (FWrongParams         = nil) and
    (FRightParams         = nil);

  if not Result then
    Exit;

  // Each parallel worker entry must also be released.
  for I := Low(FParallelParams) to High(FParallelParams) do
    if Assigned(FParallelParams[I]) then
      Exit(False);
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
  FIsClosing := True;
  MemoLog.Lines.Add('=== Application shutting down ===');

  // 1) General cancel for all active tasks.
  RequestCancelAll;

  // 2) Bounded host-app drain so pending UI-bound terminations can run.
  DrainUntilReleased(DRAIN_TIMEOUT_MS);

  // 3) Final cleanup of auxiliary resources.
  SetLength(FParallelParams, 0);
  SetLength(FParallelData, 0);

  MemoLog.Lines.Add('=== Shutdown complete ===');
end;

end.
