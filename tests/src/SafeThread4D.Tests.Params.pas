// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Eduardo P. Araujo
// https://github.com/eduardoparaujo/SafeThread4D

{*
  Unit   : SafeThread4D.Tests.Params
  Purpose: DUnitX fixture covering default values, fluent configuration, and
           callback storage in TSafeThread4DParams.

  Part of the SafeThread4D test suite.

  Notes:
    - Verifies constructor defaults and runtime flag defaults.
    - Covers fluent chaining of configuration methods.
    - Confirms configured callbacks are stored and retrievable.
*}

unit SafeThread4D.Tests.Params;

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  SafeThread4D;

type
  [TestFixture]
  TSafeThread4DParamsTests = class
  public
    [Test] procedure New_DefaultTimeout_IsZero;
    [Test] procedure New_DefaultProgressInterval_Is100;
    [Test] procedure New_DefaultFreeOnTerminate_IsTrue;
    [Test] procedure New_DefaultCompleteWithError_IsFalse;
    [Test] procedure New_DefaultThreadId_IsMinusOne;
    [Test] procedure New_DefaultThreadName_IsEmpty;
    [Test] procedure New_DefaultCancelRequested_IsFalse;
    [Test] procedure New_DefaultThreadHadError_IsFalse;
    [Test] procedure New_DefaultIsRunning_IsFalse;

    [Test] procedure RequestCancel_SetsCancelRequested;
    [Test] procedure SetThreadHadError_TrueAndFalse_AreReflected;

    [Test] procedure FluentChaining_PreservesConfiguredValues;
    [Test] procedure ConfiguredCallbacks_AreReturnedAndInvocable;
  end;

implementation

procedure TSafeThread4DParamsTests.New_DefaultTimeout_IsZero;
var
  Params: ISafeThread4DParams;
begin
  Params := TSafeThread4DParams.New;
  Assert.AreEqual<Cardinal>(0, Params.GetTimeoutMs);
end;

procedure TSafeThread4DParamsTests.New_DefaultProgressInterval_Is100;
var
  Params: ISafeThread4DParams;
begin
  Params := TSafeThread4DParams.New;
  Assert.AreEqual<Cardinal>(100, Params.GetProgressIntervalMs);
end;

procedure TSafeThread4DParamsTests.New_DefaultFreeOnTerminate_IsTrue;
var
  Params: ISafeThread4DParams;
begin
  Params := TSafeThread4DParams.New;
  Assert.IsTrue(Params.GetFreeOnTerminate);
end;

procedure TSafeThread4DParamsTests.New_DefaultCompleteWithError_IsFalse;
var
  Params: ISafeThread4DParams;
begin
  Params := TSafeThread4DParams.New;
  Assert.IsFalse(Params.GetCompleteWithError);
end;

procedure TSafeThread4DParamsTests.New_DefaultThreadId_IsMinusOne;
var
  Params: ISafeThread4DParams;
begin
  Params := TSafeThread4DParams.New;
  Assert.AreEqual(-1, Params.GetThreadId);
end;

procedure TSafeThread4DParamsTests.New_DefaultThreadName_IsEmpty;
var
  Params: ISafeThread4DParams;
begin
  Params := TSafeThread4DParams.New;
  Assert.AreEqual('', Params.GetThreadName);
end;

procedure TSafeThread4DParamsTests.New_DefaultCancelRequested_IsFalse;
var
  Params: ISafeThread4DParams;
begin
  Params := TSafeThread4DParams.New;
  Assert.IsFalse(Params.GetCancelRequested);
end;

procedure TSafeThread4DParamsTests.New_DefaultThreadHadError_IsFalse;
var
  Params: ISafeThread4DParams;
begin
  Params := TSafeThread4DParams.New;
  Assert.IsFalse(Params.GetThreadHadError);
end;

procedure TSafeThread4DParamsTests.New_DefaultIsRunning_IsFalse;
var
  Params: ISafeThread4DParams;
begin
  Params := TSafeThread4DParams.New;
  Assert.IsFalse(Params.IsRunning);
end;

procedure TSafeThread4DParamsTests.RequestCancel_SetsCancelRequested;
var
  Params: ISafeThread4DParams;
begin
  Params := TSafeThread4DParams.New;

  Assert.IsFalse(Params.GetCancelRequested);
  Params.RequestCancel;
  Assert.IsTrue(Params.GetCancelRequested);
end;

procedure TSafeThread4DParamsTests.SetThreadHadError_TrueAndFalse_AreReflected;
var
  Params: ISafeThread4DParams;
begin
  Params := TSafeThread4DParams.New;

  Params.SetThreadHadError(True);
  Assert.IsTrue(Params.GetThreadHadError);

  Params.SetThreadHadError(False);
  Assert.IsFalse(Params.GetThreadHadError);
end;

procedure TSafeThread4DParamsTests.FluentChaining_PreservesConfiguredValues;
var
  Params: ISafeThread4DParams;
begin
  Params := TSafeThread4DParams.New
    .SetThreadName('job-1')
    .SetThreadId(42)
    .SetTimeoutMs(5000)
    .SetProgressIntervalMs(250)
    .SetFreeOnTerminate(False)
    .SetCompleteWithError(True)
    .SetMeasureTime(True);

  Assert.AreEqual('job-1', Params.GetThreadName);
  Assert.AreEqual(42, Params.GetThreadId);
  Assert.AreEqual<Cardinal>(5000, Params.GetTimeoutMs);
  Assert.AreEqual<Cardinal>(250, Params.GetProgressIntervalMs);
  Assert.IsFalse(Params.GetFreeOnTerminate);
  Assert.IsTrue(Params.GetCompleteWithError);
  Assert.IsTrue(Params.GetMeasureTime);
end;

procedure TSafeThread4DParamsTests.ConfiguredCallbacks_AreReturnedAndInvocable;
var
  Params: ISafeThread4DParams;
  Context: TThreadContext;

  InitCalled: Boolean;
  ExecCalled: Boolean;
  SuccessCalled: Boolean;
  CompleteCalled: Boolean;
  TerminateCalled: Boolean;
  CancelCalled: Boolean;
  TimeoutCalled: Boolean;
  ProgressCalled: Boolean;
  ErrorCalled: Boolean;
  HeartbeatCalled: Boolean;

  ProgressValue: Single;
  ErrorMessage: string;

  InitCb: TContextCallback;
  ExecCb: TContextCallback;
  SuccessCb: TContextCallback;
  CompleteCb: TContextCallback;
  TerminateCb: TContextCallback;
  CancelCb: TContextCallback;
  TimeoutCb: TContextCallback;
  ProgressCb: TProgressCallback;
  ErrorCb: TErrorCallback;
  HeartbeatCb: THeartbeatProc;
begin
  FillChar(Context, SizeOf(Context), 0);

  InitCalled := False;
  ExecCalled := False;
  SuccessCalled := False;
  CompleteCalled := False;
  TerminateCalled := False;
  CancelCalled := False;
  TimeoutCalled := False;
  ProgressCalled := False;
  ErrorCalled := False;
  HeartbeatCalled := False;
  ProgressValue := -1;
  ErrorMessage := '';

  Params := TSafeThread4DParams.New
    .SetOnInitialize(
      procedure(Ctx: TThreadContext)
      begin
        InitCalled := True;
      end)
    .SetOnExecute(
      procedure(Ctx: TThreadContext)
      begin
        ExecCalled := True;
      end)
    .SetOnSuccess(
      procedure(Ctx: TThreadContext)
      begin
        SuccessCalled := True;
      end)
    .SetOnComplete(
      procedure(Ctx: TThreadContext)
      begin
        CompleteCalled := True;
      end)
    .SetOnTerminate(
      procedure(Ctx: TThreadContext)
      begin
        TerminateCalled := True;
      end)
    .SetOnCancel(
      procedure(Ctx: TThreadContext)
      begin
        CancelCalled := True;
      end)
    .SetOnTimeout(
      procedure(Ctx: TThreadContext)
      begin
        TimeoutCalled := True;
      end)
    .SetOnProgress(
      procedure(P: Single)
      begin
        ProgressCalled := True;
        ProgressValue := P;
      end)
    .SetOnError(
      procedure(const AErrorMessage: string; const AContext: TThreadContext)
      begin
        ErrorCalled := True;
        ErrorMessage := AErrorMessage;
      end)
    .SetOnHeartbeat(
      procedure
      begin
        HeartbeatCalled := True;
      end);

  InitCb := Params.GetOnInitialize;
  ExecCb := Params.GetOnExecute;
  SuccessCb := Params.GetOnSuccess;
  CompleteCb := Params.GetOnComplete;
  TerminateCb := Params.GetOnTerminate;
  CancelCb := Params.GetOnCancel;
  TimeoutCb := Params.GetOnTimeout;
  ProgressCb := Params.GetOnProgress;
  ErrorCb := Params.GetOnError;
  HeartbeatCb := Params.GetOnHeartbeat;

  Assert.IsTrue(Assigned(InitCb));
  Assert.IsTrue(Assigned(ExecCb));
  Assert.IsTrue(Assigned(SuccessCb));
  Assert.IsTrue(Assigned(CompleteCb));
  Assert.IsTrue(Assigned(TerminateCb));
  Assert.IsTrue(Assigned(CancelCb));
  Assert.IsTrue(Assigned(TimeoutCb));
  Assert.IsTrue(Assigned(ProgressCb));
  Assert.IsTrue(Assigned(ErrorCb));
  Assert.IsTrue(Assigned(HeartbeatCb));

  InitCb(Context);
  ExecCb(Context);
  SuccessCb(Context);
  CompleteCb(Context);
  TerminateCb(Context);
  CancelCb(Context);
  TimeoutCb(Context);
  ProgressCb(0.5);
  ErrorCb('boom', Context);
  HeartbeatCb;

  Assert.IsTrue(InitCalled);
  Assert.IsTrue(ExecCalled);
  Assert.IsTrue(SuccessCalled);
  Assert.IsTrue(CompleteCalled);
  Assert.IsTrue(TerminateCalled);
  Assert.IsTrue(CancelCalled);
  Assert.IsTrue(TimeoutCalled);
  Assert.IsTrue(ProgressCalled);
  Assert.IsTrue(ErrorCalled);
  Assert.IsTrue(HeartbeatCalled);

  Assert.IsTrue(Abs(ProgressValue - 0.5) < 0.0001);
  Assert.AreEqual('boom', ErrorMessage);
end;

initialization
  TDUnitX.RegisterTestFixture(TSafeThread4DParamsTests);

end.
