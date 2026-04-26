// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Eduardo P. Araujo
// https://github.com/eduardoparaujo/SafeThread4D

{*
  Unit   : SafeThread4D.Tests.Helpers
  Purpose: DUnitX fixture covering helper methods and edge-case behavior in
           the SafeThread4D facade.

  Part of the SafeThread4D test suite.

  Notes:
    - Covers CheckCancel, CheckTimeout, and ReportProgress helpers.
    - Verifies progress clamping behavior.
    - Covers weak/strong startup helper assignment behavior.
*}

unit SafeThread4D.Tests.Helpers;

interface

uses
  DUnitX.TestFramework,
  System.Classes,
  System.SysUtils,
  SafeThread4D;

type
  [TestFixture]
  TSafeThread4DHelperTests = class
  public
    [Test] procedure CheckCancel_DoesNothing_WhenNotCancelled;
    [Test] procedure CheckCancel_RaisesEOperationCancelled_WhenCancelled;

    [Test] procedure CheckTimeout_DoesNothing_WhenTimeoutIsZero;
    [Test] procedure CheckTimeout_RaisesEOperationTimeout_WhenElapsedExceeded;

    [Test] procedure ReportProgress_ClampsNegativeToZero;
    [Test] procedure ReportProgress_ClampsValuesAboveOneToOne;
    [Test] procedure ReportProgress_PassesThroughIntermediateValue;

    [Test] procedure StartThreadWithWeakRef_AssignsStrongRef;
    [Test] procedure StartThreadWithWeakRef_AssignsWeakRef;
  end;

implementation

uses
  System.SyncObjs,
  SafeThread4D.Tests.Support;

procedure TSafeThread4DHelperTests.CheckCancel_DoesNothing_WhenNotCancelled;
var
  Params: ISafeThread4DParams;
  Context: TThreadContext;
begin
  Params := TSafeThread4DParams.New;
  FillChar(Context, SizeOf(Context), 0);

  Assert.WillNotRaise(
    procedure
    begin
      TSafeThread4D.CheckCancel(Params, Context);
    end);

  Assert.IsFalse(Context.ThreadCancel);
end;

procedure TSafeThread4DHelperTests.CheckCancel_RaisesEOperationCancelled_WhenCancelled;
var
  Params: ISafeThread4DParams;
  Context: TThreadContext;
begin
  Params := TSafeThread4DParams.New;
  Params.RequestCancel;
  FillChar(Context, SizeOf(Context), 0);

  Assert.WillRaise(
    procedure
    begin
      TSafeThread4D.CheckCancel(Params, Context);
    end,
    EOperationCancelled);

  Assert.IsTrue(Context.ThreadCancel);
end;

procedure TSafeThread4DHelperTests.CheckTimeout_DoesNothing_WhenTimeoutIsZero;
var
  Params: ISafeThread4DParams;
  Context: TThreadContext;
begin
  Params := TSafeThread4DParams.New.SetTimeoutMs(0);
  FillChar(Context, SizeOf(Context), 0);
  Context.StartTick := UInt64(TThread.GetTickCount);

  Assert.WillNotRaise(
    procedure
    begin
      TSafeThread4D.CheckTimeout(Params, Context);
    end);
end;

procedure TSafeThread4DHelperTests.CheckTimeout_RaisesEOperationTimeout_WhenElapsedExceeded;
var
  Params: ISafeThread4DParams;
  Context: TThreadContext;
begin
  Params := TSafeThread4DParams.New.SetTimeoutMs(10);
  FillChar(Context, SizeOf(Context), 0);
  Context.StartTick := UInt64(TThread.GetTickCount) - 50;

  Assert.WillRaise(
    procedure
    begin
      TSafeThread4D.CheckTimeout(Params, Context);
    end,
    EOperationTimeout);
end;

procedure TSafeThread4DHelperTests.ReportProgress_ClampsNegativeToZero;
var
  Params: ISafeThread4DParams;
  LastProgress: Single;
  ProgressCalled: Boolean;
begin
  LastProgress := -1;
  ProgressCalled := False;

  Params := TSafeThread4DParams.New
    .SetOnProgress(
      procedure(P: Single)
      begin
        ProgressCalled := True;
        LastProgress := P;
      end);

  TSafeThread4D.ReportProgress(Params, -5.0, True);

  Assert.IsTrue(
    TSafeThread4DTestSupport.WaitUntil(
      function: Boolean
      begin
        Result := ProgressCalled;
      end,
      500),
    'Progress callback was not invoked.');

  Assert.IsTrue(Abs(LastProgress - 0.0) < 0.0001);
end;

procedure TSafeThread4DHelperTests.ReportProgress_ClampsValuesAboveOneToOne;
var
  Params: ISafeThread4DParams;
  LastProgress: Single;
  ProgressCalled: Boolean;
begin
  LastProgress := -1;
  ProgressCalled := False;

  Params := TSafeThread4DParams.New
    .SetOnProgress(
      procedure(P: Single)
      begin
        ProgressCalled := True;
        LastProgress := P;
      end);

  TSafeThread4D.ReportProgress(Params, 5.0, True);

  Assert.IsTrue(
    TSafeThread4DTestSupport.WaitUntil(
      function: Boolean
      begin
        Result := ProgressCalled;
      end,
      500),
      'Progress callback was not invoked.');

  Assert.IsTrue(Abs(LastProgress - 1.0) < 0.0001);
end;

procedure TSafeThread4DHelperTests.ReportProgress_PassesThroughIntermediateValue;
var
  Params: ISafeThread4DParams;
  LastProgress: Single;
  ProgressCalled: Boolean;
begin
  LastProgress := -1;
  ProgressCalled := False;

  Params := TSafeThread4DParams.New
    .SetOnProgress(
      procedure(P: Single)
      begin
        ProgressCalled := True;
        LastProgress := P;
      end);

  TSafeThread4D.ReportProgress(Params, 0.5, True);

  Assert.IsTrue(
    TSafeThread4DTestSupport.WaitUntil(
      function: Boolean
      begin
        Result := ProgressCalled;
      end,
      500),
      'Progress callback was not invoked.');

  Assert.IsTrue(Abs(LastProgress - 0.5) < 0.0001);
end;

procedure TSafeThread4DHelperTests.StartThreadWithWeakRef_AssignsStrongRef;
var
  Params: ISafeThread4DParams;
  StrongRef: ISafeThread4DParams;
  WeakRef: Pointer;
  Terminated: Boolean;
begin
  Terminated := False;

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

  TSafeThread4D.StartThreadWithWeakRef(Params, WeakRef, StrongRef);

  Assert.IsTrue(Assigned(StrongRef), 'StrongRef should be assigned.');
  Assert.IsTrue(Assigned(StrongRef.GetOnExecute), 'OnExecute should be assigned in StrongRef.');

  Assert.IsTrue(
    TSafeThread4DTestSupport.WaitUntil(
      function: Boolean
      begin
        Result := Terminated;
      end,
      1000),
    'The worker did not terminate in time.');

  StrongRef := nil;
  TSafeThread4DTestSupport.PumpMessages(50);
end;

procedure TSafeThread4DHelperTests.StartThreadWithWeakRef_AssignsWeakRef;
var
  Params: ISafeThread4DParams;
  StrongRef: ISafeThread4DParams;
  WeakRef: Pointer;
  Terminated: Boolean;
begin
  Terminated := False;

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

  TSafeThread4D.StartThreadWithWeakRef(Params, WeakRef, StrongRef);

  Assert.IsNotNull(WeakRef, 'WeakRef should not be nil.');
  Assert.IsTrue(Assigned(StrongRef), 'StrongRef should be assigned.');

  Assert.IsTrue(
    TSafeThread4DTestSupport.WaitUntil(
      function: Boolean
      begin
        Result := Terminated;
      end,
      1000),
      'The worker did not terminate in time.');

  StrongRef := nil;
  TSafeThread4DTestSupport.PumpMessages(50);
end;

initialization
  TDUnitX.RegisterTestFixture(TSafeThread4DHelperTests);

end.

