// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Eduardo P. Araujo
// https://github.com/eduardoparaujo/SafeThread4D

{*
  Unit   : SafeThread4D.Tests.Lifecycle
  Purpose: DUnitX fixture covering the standard success lifecycle and basic
           start-up validation rules for SafeThread4D.

  Part of the SafeThread4D test suite.

  Notes:
    - Verifies callback ordering on the success path.
    - Covers startup validation such as nil params and missing OnExecute.
    - Verifies context metadata and elapsed-time measurement.
*}

unit SafeThread4D.Tests.Lifecycle;

interface

uses
  DUnitX.TestFramework,
  System.Classes,
  System.SysUtils,
  SafeThread4D;

type
  [TestFixture]
  TSafeThread4DLifecycleTests = class
  public
    [Test] procedure StartThread_NilParams_Raises;
    [Test] procedure StartThread_WithoutOnExecute_Raises;
    [Test] procedure SuccessPath_FiresExpectedCallbacksInOrder;
    [Test] procedure SuccessPath_ContextCarriesConfiguredNameAndId;
    [Test] procedure SuccessPath_MeasuresElapsedMilliseconds_WhenEnabled;
    [Test] procedure StartThread_IgnoresPreStartCancelRequest_AndRunsNormally;
  end;

implementation

uses
  SafeThread4D.Tests.Support,
  System.Generics.Collections;

procedure TSafeThread4DLifecycleTests.StartThread_NilParams_Raises;
begin
  Assert.WillRaise(
    procedure
    begin
      TSafeThread4D.StartThread(nil);
    end,
    Exception);
end;

procedure TSafeThread4DLifecycleTests.StartThread_WithoutOnExecute_Raises;
var
  Params: ISafeThread4DParams;
begin
  Params := TSafeThread4DParams.New
    .SetOnSuccess(
      procedure(Ctx: TThreadContext)
      begin
      end);

  Assert.WillRaise(
    procedure
    begin
      TSafeThread4D.StartThread(Params);
    end,
    Exception);
end;

procedure TSafeThread4DLifecycleTests.SuccessPath_FiresExpectedCallbacksInOrder;
var
  Params: ISafeThread4DParams;
  Steps: TList<string>;
  Terminated: Boolean;
  Actual: string;
begin
  Steps := TList<string>.Create;
  try
    Terminated := False;

    Params := TSafeThread4DParams.New
      .SetMeasureTime(False)
      .SetOnInitialize(
        procedure(Ctx: TThreadContext)
        begin
          TSafeThread4DTestSupport.AddStep(Steps, 'OnInitialize');
        end)
      .SetOnExecute(
        procedure(Ctx: TThreadContext)
        begin
          TSafeThread4DTestSupport.AddStep(Steps, 'OnExecute');
          TThread.Sleep(20);
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
        2000),
        'Lifecycle did not terminate in time. Current sequence: ' + TSafeThread4DTestSupport.JoinSteps(Steps));

    Actual := TSafeThread4DTestSupport.JoinSteps(Steps);
    Assert.AreEqual(
      'OnInitialize -> OnExecute -> OnSuccess -> OnComplete -> OnTerminate',
      Actual);
  finally
    Steps.Free;
  end;
end;

procedure TSafeThread4DLifecycleTests.SuccessPath_ContextCarriesConfiguredNameAndId;
var
  Params: ISafeThread4DParams;
  Terminated: Boolean;
  ReceivedName: string;
  ReceivedId: Integer;
  ReceivedNativeId: TThreadID;
begin
  Terminated := False;
  ReceivedName := '';
  ReceivedId := -999;
  ReceivedNativeId := 0;

  Params := TSafeThread4DParams.New
    .SetThreadName('sync-job')
    .SetThreadId(7)
    .SetOnExecute(
      procedure(Ctx: TThreadContext)
      begin
        TThread.Sleep(10);
      end)
    .SetOnSuccess(
      procedure(Ctx: TThreadContext)
      begin
        ReceivedName := Ctx.ThreadName;
        ReceivedId := Ctx.LogicalThreadID;
        ReceivedNativeId := Ctx.NativeThreadID;
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
          Result := Terminated;
        end,
        2000),
        'Lifecycle did not terminate in time.');

    Assert.AreEqual('sync-job', ReceivedName);
    Assert.AreEqual(7, ReceivedId);
    Assert.IsTrue(ReceivedNativeId <> 0, 'Native thread ID should be non-zero.');
end;

procedure TSafeThread4DLifecycleTests.SuccessPath_MeasuresElapsedMilliseconds_WhenEnabled;
var
  Params: ISafeThread4DParams;
  Terminated: Boolean;
  Elapsed: Int64;
begin
  Terminated := False;
  Elapsed := 0;

  Params := TSafeThread4DParams.New
    .SetMeasureTime(True)
    .SetOnExecute(
      procedure(Ctx: TThreadContext)
      begin
        TThread.Sleep(40);
      end)
    .SetOnSuccess(
      procedure(Ctx: TThreadContext)
      begin
        Elapsed := Ctx.ElapsedMilliseconds;
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
          Result := Terminated;
        end,
        2000),
        'Lifecycle did not terminate in time.');

    Assert.IsTrue(Elapsed >= 30, 'ElapsedMilliseconds should be at least 30ms for a 40ms sleep.');
    Assert.IsTrue(Elapsed < 500, 'ElapsedMilliseconds should not be unreasonably large.');
end;

procedure TSafeThread4DLifecycleTests.StartThread_IgnoresPreStartCancelRequest_AndRunsNormally;
var
  Params: ISafeThread4DParams;
  Steps: TList<string>;
  Terminated: Boolean;
  Actual: string;
begin
  Steps := TList<string>.Create;
  try
    Terminated := False;

    Params := TSafeThread4DParams.New
      .SetOnInitialize(
        procedure(Ctx: TThreadContext)
        begin
          TSafeThread4DTestSupport.AddStep(Steps, 'OnInitialize');
        end)
      .SetOnExecute(
        procedure(Ctx: TThreadContext)
        begin
          TSafeThread4DTestSupport.AddStep(Steps, 'OnExecute');
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

    Params.RequestCancel;
    TSafeThread4D.StartThread(Params);

    Assert.IsTrue(
      TSafeThread4DTestSupport.WaitUntil(
        function: Boolean
        begin
          Result := Terminated;
        end,
        2000),
        'Lifecycle did not terminate in time. Current sequence: ' + TSafeThread4DTestSupport.JoinSteps(Steps));

    Actual := TSafeThread4DTestSupport.JoinSteps(Steps);
    Assert.AreEqual(
      'OnInitialize -> OnExecute -> OnSuccess -> OnComplete -> OnTerminate',
      Actual);
  finally
    Steps.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TSafeThread4DLifecycleTests);

end.

