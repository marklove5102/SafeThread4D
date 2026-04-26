// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Eduardo P. Araujo
// https://github.com/eduardoparaujo/SafeThread4D

{*
  Unit   : SafeThread4D.Tests.Support
  Purpose: Shared test-support helpers for the SafeThread4D DUnitX suite.

  Part of the SafeThread4D test suite.

  Notes:
    - Provides message pumping and timed wait helpers.
    - Provides step collection and sequence-joining helpers.
    - Test-internal only; not intended for production use.
*}

unit SafeThread4D.Tests.Support;

interface

uses
  System.Classes,
  System.Generics.Collections,
  System.SysUtils,
  System.SyncObjs;

type
  TSafeThread4DTestSupport = class
  public
    class procedure PumpMessages(const ATimeoutMs: Cardinal; const AStepMs: Cardinal = 5); static;
    class function WaitUntil(
      const ACondition: TFunc<Boolean>;
      const ATimeoutMs: Cardinal;
      const AStepMs: Cardinal = 5): Boolean; static;
    class procedure AddStep(const AList: TList<string>; const AValue: string); static;
    class function JoinSteps(const AList: TList<string>): string; static;
  end;

implementation

class procedure TSafeThread4DTestSupport.PumpMessages(const ATimeoutMs: Cardinal; const AStepMs: Cardinal);
var
  LStart: Cardinal;
begin
  LStart := TThread.GetTickCount;
  repeat
    CheckSynchronize(AStepMs);
    TThread.Sleep(AStepMs);
  until (TThread.GetTickCount - LStart) >= ATimeoutMs;
end;

class function TSafeThread4DTestSupport.WaitUntil(
  const ACondition: TFunc<Boolean>;
  const ATimeoutMs: Cardinal;
  const AStepMs: Cardinal): Boolean;
var
  LStart: Cardinal;
begin
  LStart := TThread.GetTickCount;
  repeat
    CheckSynchronize(AStepMs);
    if ACondition() then
      Exit(True);
    TThread.Sleep(AStepMs);
  until (TThread.GetTickCount - LStart) >= ATimeoutMs;

  CheckSynchronize(AStepMs);
  Result := ACondition();
end;

class procedure TSafeThread4DTestSupport.AddStep(const AList: TList<string>; const AValue: string);
begin
  TMonitor.Enter(AList);
  try
    AList.Add(AValue);
  finally
    TMonitor.Exit(AList);
  end;
end;

class function TSafeThread4DTestSupport.JoinSteps(const AList: TList<string>): string;
var
  I: Integer;
  LSnapshot: TArray<string>;
begin
  TMonitor.Enter(AList);
  try
    LSnapshot := AList.ToArray;
  finally
    TMonitor.Exit(AList);
  end;

  Result := '';
  for I := 0 to High(LSnapshot) do
  begin
    if Result <> '' then
      Result := Result + ' -> ';
    Result := Result + LSnapshot[I];
  end;
end;

end.

