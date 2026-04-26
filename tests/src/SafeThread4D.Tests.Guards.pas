// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Eduardo P. Araujo
// https://github.com/eduardoparaujo/SafeThread4D

{*
  Unit   : SafeThread4D.Tests.Guards
  Purpose: DUnitX fixture covering public guard rails and invalid-call
           behavior for SafeThread4D.

  Part of the SafeThread4D test suite.

  Notes:
    - Verifies main-thread guard behavior for CancelAndWait.
    - Confirms raw TThread handle helpers are intentionally rejected.
    - Covers nil-safe helper calls where applicable.
*}

unit SafeThread4D.Tests.Guards;

interface

uses
  DUnitX.TestFramework,
  System.Classes,
  System.SysUtils,
  SafeThread4D;

type
  [TestFixture]
  TSafeThread4DGuardTests = class
  public
    [Test] procedure CancelAndWait_FromMainThread_Raises;
    [Test] procedure WaitFor_ForRawHandle_AlwaysRaises;
    [Test] procedure IsThreadRunning_ForRawHandle_AlwaysRaises;
    [Test] procedure IsThreadRunning_NilParams_ReturnsFalse;
    [Test] procedure Cancel_Nil_DoesNotRaise;
    [Test] procedure CancelAndWait_Nil_DoesNotRaise;
  end;

implementation

procedure TSafeThread4DGuardTests.CancelAndWait_FromMainThread_Raises;
var
  Params: ISafeThread4DParams;
begin
  Params := TSafeThread4DParams.New
    .SetOnExecute(
      procedure(Ctx: TThreadContext)
      begin
        TThread.Sleep(20);
      end);

  Assert.WillRaise(
    procedure
    begin
      TSafeThread4D.CancelAndWait(Params);
    end,
    Exception);
end;

procedure TSafeThread4DGuardTests.WaitFor_ForRawHandle_AlwaysRaises;
begin
  Assert.WillRaise(
    procedure
    begin
      TSafeThread4D.WaitFor(nil);
    end,
    Exception);
end;

procedure TSafeThread4DGuardTests.IsThreadRunning_ForRawHandle_AlwaysRaises;
begin
  Assert.WillRaise(
    procedure
    begin
      TSafeThread4D.IsThreadRunning(TThread(nil));
    end,
    Exception);
end;

procedure TSafeThread4DGuardTests.IsThreadRunning_NilParams_ReturnsFalse;
begin
  Assert.IsFalse(TSafeThread4D.IsThreadRunning(ISafeThread4DParams(nil)));
end;

procedure TSafeThread4DGuardTests.Cancel_Nil_DoesNotRaise;
begin
  Assert.WillNotRaise(
    procedure
    begin
      TSafeThread4D.Cancel(nil);
    end);
end;

procedure TSafeThread4DGuardTests.CancelAndWait_Nil_DoesNotRaise;
begin
  Assert.WillNotRaise(
    procedure
    begin
      TSafeThread4D.CancelAndWait(nil);
    end);
end;

initialization
  TDUnitX.RegisterTestFixture(TSafeThread4DGuardTests);

end.

