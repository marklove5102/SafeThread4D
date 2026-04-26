// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Eduardo P. Araujo
// https://github.com/eduardoparaujo/SafeThread4D

{*
  Unit   : SafeThread4D.Tests.ReuseAndCompletion
  Purpose: DUnitX fixture covering sequential reuse, completion publication,
           and CancelAndWait semantics.

  Part of the SafeThread4D test suite.

  Notes:
    - Verifies concurrent reuse rejection and sequential reuse success.
    - Covers IsRunning publication during execution and after termination.
    - Verifies CancelAndWait behavior before and after completion.
*}

unit SafeThread4D.Tests.ReuseAndCompletion;

interface

uses
  DUnitX.TestFramework,
  System.Classes,
  System.Generics.Collections,
  System.SysUtils,
  System.SyncObjs,
  SafeThread4D;

type
  [TestFixture]
  TSafeThread4DReuseAndCompletionTests = class
  public
    [Test] procedure StartThread_OnAlreadyRunningParams_Raises;
    [Test] procedure StartThread_AfterCompletion_CanBeReusedSuccessfully;
    [Test] procedure IsRunning_DuringExecution_IsTrue_AndFalseAfterTermination;
    [Test] procedure CancelAndWait_FromWorkerThread_BlocksUntilCompletionPublication;
    [Test] procedure CancelAndWait_AfterAlreadyCompleted_ReturnsImmediately;
  end;

implementation

uses
  SafeThread4D.Tests.Support;

procedure TSafeThread4DReuseAndCompletionTests.StartThread_OnAlreadyRunningParams_Raises;
var
  Params: ISafeThread4DParams;
  ExecuteStarted: TEvent;
begin
  ExecuteStarted := TEvent.Create(nil, True, False, '');
  try
    Params := TSafeThread4DParams.New
      .SetOnExecute(
        procedure(Ctx: TThreadContext)
        begin
          ExecuteStarted.SetEvent;
          TThread.Sleep(200);
        end);

    TSafeThread4D.StartThread(Params);

    Assert.AreEqual(
      wrSignaled,
      ExecuteStarted.WaitFor(1000),
      'OnExecute did not start in time.');

    Assert.WillRaise(
      procedure
      begin
        TSafeThread4D.StartThread(Params);
      end,
      Exception);

    Assert.IsTrue(
      TSafeThread4DTestSupport.WaitUntil(
        function: Boolean
        begin
          Result := not Params.IsRunning;
        end,
        3000),
        'Initial task did not leave running state in time.');
  finally
    ExecuteStarted.Free;
  end;
end;

procedure TSafeThread4DReuseAndCompletionTests.StartThread_AfterCompletion_CanBeReusedSuccessfully;
var
  Params: ISafeThread4DParams;
  ExecuteCount: Integer;
  TerminateCount: Integer;
begin
  ExecuteCount := 0;
  TerminateCount := 0;

  Params := TSafeThread4DParams.New
    .SetOnExecute(
      procedure(Ctx: TThreadContext)
      begin
        TInterlocked.Increment(ExecuteCount);
        TThread.Sleep(20);
      end)
    .SetOnTerminate(
      procedure(Ctx: TThreadContext)
      begin
        TInterlocked.Increment(TerminateCount);
      end);

  TSafeThread4D.StartThread(Params);

  Assert.IsTrue(
    TSafeThread4DTestSupport.WaitUntil(
      function: Boolean
      begin
        Result := (TerminateCount = 1) and (not Params.IsRunning);
      end,
      3000),
      'First execution was not fully published as completed in time.');

  TSafeThread4D.StartThread(Params);

  Assert.IsTrue(
    TSafeThread4DTestSupport.WaitUntil(
      function: Boolean
      begin
        Result := (TerminateCount = 2) and (not Params.IsRunning);
      end,
      3000),
      'Second execution was not fully published as completed in time.');

  Assert.AreEqual(2, ExecuteCount);
  Assert.AreEqual(2, TerminateCount);
end;

procedure TSafeThread4DReuseAndCompletionTests.IsRunning_DuringExecution_IsTrue_AndFalseAfterTermination;
var
  Params: ISafeThread4DParams;
  ReleaseWork: TEvent;
begin
  ReleaseWork := TEvent.Create(nil, True, False, '');
  try
    Params := TSafeThread4DParams.New
      .SetOnExecute(
        procedure(Ctx: TThreadContext)
        begin
          ReleaseWork.WaitFor(1000);
        end);

    TSafeThread4D.StartThread(Params);

    Assert.IsTrue(
      TSafeThread4DTestSupport.WaitUntil(
        function: Boolean
        begin
          Result := Params.IsRunning;
        end,
        1000),
        'Params never entered running state.');

    Assert.IsTrue(Params.IsRunning);
    Assert.IsTrue(TSafeThread4D.IsThreadRunning(Params));

    ReleaseWork.SetEvent;

    Assert.IsTrue(
      TSafeThread4DTestSupport.WaitUntil(
        function: Boolean
        begin
          Result := not Params.IsRunning;
        end,
        3000),
        'Params did not leave running state in time.');

    Assert.IsFalse(Params.IsRunning);
    Assert.IsFalse(TSafeThread4D.IsThreadRunning(Params));
  finally
    ReleaseWork.Free;
  end;
end;

procedure TSafeThread4DReuseAndCompletionTests.CancelAndWait_FromWorkerThread_BlocksUntilCompletionPublication;
var
  Params: ISafeThread4DParams;
  Steps: TList<string>;
  ExecuteStarted: TEvent;
  WaitReturnedFlag: Boolean;
begin
  Steps := TList<string>.Create;
  ExecuteStarted := TEvent.Create(nil, True, False, '');
  try
    WaitReturnedFlag := False;

    Params := TSafeThread4DParams.New
      .SetOnExecute(
        procedure(Ctx: TThreadContext)
        var
          I: Integer;
        begin
          TSafeThread4DTestSupport.AddStep(Steps, 'OnExecute');
          ExecuteStarted.SetEvent;

          for I := 1 to 50 do
          begin
            TSafeThread4D.CheckCancel(Params, Ctx);
            TThread.Sleep(10);
          end;
        end)
      .SetOnCancel(
        procedure(Ctx: TThreadContext)
        begin
          TSafeThread4DTestSupport.AddStep(Steps, 'OnCancel');
        end)
      .SetOnTerminate(
        procedure(Ctx: TThreadContext)
        begin
          TSafeThread4DTestSupport.AddStep(Steps, 'OnTerminate');
          TThread.Sleep(50);
        end);

    TSafeThread4D.StartThread(Params);

    Assert.AreEqual(
      wrSignaled,
      ExecuteStarted.WaitFor(1000),
      'OnExecute did not start in time.');

    TThread.CreateAnonymousThread(
      procedure
      begin
        TSafeThread4D.CancelAndWait(Params);
        TSafeThread4DTestSupport.AddStep(Steps, 'CancelAndWaitReturned');
        WaitReturnedFlag := True;
      end).Start;

    Assert.IsTrue(
      TSafeThread4DTestSupport.WaitUntil(
        function: Boolean
        begin
          Result := WaitReturnedFlag;
        end,
        3000),
        'CancelAndWait did not return in time.');

    Assert.AreEqual(
      'OnExecute -> OnCancel -> OnTerminate -> CancelAndWaitReturned',
      TSafeThread4DTestSupport.JoinSteps(Steps));
  finally
    ExecuteStarted.Free;
    Steps.Free;
  end;
end;

procedure TSafeThread4DReuseAndCompletionTests.CancelAndWait_AfterAlreadyCompleted_ReturnsImmediately;
var
  Params: ISafeThread4DParams;
  Terminated: Boolean;
  WaitReturnedFlag: Boolean;
  ElapsedMs: Cardinal;
begin
  Terminated := False;
  WaitReturnedFlag := False;

  Params := TSafeThread4DParams.New
    .SetOnExecute(
      procedure(Ctx: TThreadContext)
      begin
        TThread.Sleep(20);
      end)
    .SetOnTerminate(
      procedure(Ctx: TThreadContext)
      begin
        Terminated := True;
      end);

  TSafeThread4D.StartThread(Params);

  Assert.IsTrue(
    TSafeThread4DTestSupport.WaitUntil(
      function: Boolean
      begin
        Result := Terminated and (not Params.IsRunning);
      end,
      3000),
      'Task was not fully published as completed in time.');

  ElapsedMs := TThread.GetTickCount;

  TThread.CreateAnonymousThread(
    procedure
    begin
      TSafeThread4D.CancelAndWait(Params);
      WaitReturnedFlag := True;
    end).Start;

  Assert.IsTrue(
    TSafeThread4DTestSupport.WaitUntil(
      function: Boolean
      begin
        Result := WaitReturnedFlag;
      end,
      1000),
      'CancelAndWait did not return quickly for already-completed task.');

  ElapsedMs := TThread.GetTickCount - ElapsedMs;
  Assert.IsTrue(ElapsedMs < 200, 'CancelAndWait should return quickly after completion.');
end;

initialization
  TDUnitX.RegisterTestFixture(TSafeThread4DReuseAndCompletionTests);

end.

