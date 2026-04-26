// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Eduardo P. Araujo
// https://github.com/eduardoparaujo/SafeThread4D

{*
  Unit   : SafeThread4D.Tests.CancelTimeout
  Purpose: DUnitX fixture covering cooperative cancellation and cooperative
           timeout paths for SafeThread4D.

  Part of the SafeThread4D test suite.

  Notes:
    - Verifies callback ordering on cancellation and timeout.
    - Confirms that success and completion are skipped when appropriate.
    - Uses shared helpers from SafeThread4D.Tests.Support.
*}

unit SafeThread4D.Tests.CancelTimeout;

interface

uses
  DUnitX.TestFramework,
  System.Classes,
  System.Generics.Collections,
  System.SysUtils,
  SafeThread4D;

type
  [TestFixture]
  TSafeThread4DCancelTimeoutTests = class
  public
    [Test] procedure CancelDuringOnExecute_FiresOnCancel_SkipsSuccessAndComplete;
    [Test] procedure CooperativeTimeout_WhenChecked_FiresOnTimeoutPath;
  end;

implementation

uses
  System.SyncObjs,
  SafeThread4D.Tests.Support;

procedure TSafeThread4DCancelTimeoutTests.CancelDuringOnExecute_FiresOnCancel_SkipsSuccessAndComplete;
var
  Params: ISafeThread4DParams;
  Steps: TList<string>;
  Terminated: Boolean;
  ExecuteStarted: TEvent;
begin
  Steps := TList<string>.Create;
  ExecuteStarted := TEvent.Create(nil, True, False, '');
  try
    Terminated := False;

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
      .SetOnSuccess(
        procedure(Ctx: TThreadContext)
        begin
          TSafeThread4DTestSupport.AddStep(Steps, 'OnSuccess');
        end)
      .SetOnComplete(
        procedure(Ctx: TThreadContext)
        begin
          TSafeThread4DTestSupport.AddStep(Steps, 'OnComplete');
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
          Terminated := True;
        end);

    TSafeThread4D.StartThread(Params);

    Assert.AreEqual(
      wrSignaled,
      ExecuteStarted.WaitFor(1000),
      'OnExecute did not start in time.');

    TSafeThread4D.Cancel(Params);

    Assert.IsTrue(
      TSafeThread4DTestSupport.WaitUntil(
        function: Boolean
        begin
          Result := Terminated;
        end,
        3000),
      'Cancelled task did not terminate in time. Current sequence: ' + TSafeThread4DTestSupport.JoinSteps(Steps));

    Assert.AreEqual(
      'OnExecute -> OnCancel -> OnTerminate',
      TSafeThread4DTestSupport.JoinSteps(Steps));
  finally
    ExecuteStarted.Free;
    Steps.Free;
  end;
end;

procedure TSafeThread4DCancelTimeoutTests.CooperativeTimeout_WhenChecked_FiresOnTimeoutPath;
var
  Params: ISafeThread4DParams;
  Steps: TList<string>;
  Terminated: Boolean;
begin
  Steps := TList<string>.Create;
  try
    Terminated := False;

    Params := TSafeThread4DParams.New
      .SetTimeoutMs(30)
      .SetOnExecute(
        procedure(Ctx: TThreadContext)
        begin
          TSafeThread4DTestSupport.AddStep(Steps, 'OnExecute');
          TThread.Sleep(60);
          TSafeThread4D.CheckTimeout(Params, Ctx);
        end)
      .SetOnSuccess(
        procedure(Ctx: TThreadContext)
        begin
          TSafeThread4DTestSupport.AddStep(Steps, 'OnSuccess');
        end)
      .SetOnComplete(
        procedure(Ctx: TThreadContext)
        begin
          TSafeThread4DTestSupport.AddStep(Steps, 'OnComplete');
        end)
      .SetOnTimeout(
        procedure(Ctx: TThreadContext)
        begin
          TSafeThread4DTestSupport.AddStep(Steps, 'OnTimeout');
        end)
      .SetOnTerminate(
        procedure(Ctx: TThreadContext)
        begin
          TSafeThread4DTestSupport.AddStep(Steps, 'OnTerminate');
          Terminated := True;
        end);

    TSafeThread4D.StartThread(Params);

    Assert.IsTrue(
      TSafeThread4DTestSupport.WaitUntil(
        function: Boolean
        begin
          Result := Terminated;
        end,
        3000),
        'Timed-out task did not terminate in time. Current sequence: ' + TSafeThread4DTestSupport.JoinSteps(Steps));

    Assert.AreEqual(
      'OnExecute -> OnTimeout -> OnTerminate',
      TSafeThread4DTestSupport.JoinSteps(Steps));
  finally
    Steps.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TSafeThread4DCancelTimeoutTests);

end.

