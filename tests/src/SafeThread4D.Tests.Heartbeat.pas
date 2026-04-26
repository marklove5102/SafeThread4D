// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Eduardo P. Araujo
// https://github.com/eduardoparaujo/SafeThread4D

{*
  Unit   : SafeThread4D.Tests.Heartbeat
  Purpose: DUnitX fixture covering heartbeat behavior during active work,
           cancellation, and shutdown.

  Part of the SafeThread4D test suite.

  Notes:
    - Verifies heartbeat delivery while the worker is active.
    - Confirms disabled heartbeat stays silent.
    - Confirms heartbeat stops cleanly after termination or cancellation.
*}

unit SafeThread4D.Tests.Heartbeat;

interface

uses
  DUnitX.TestFramework,
  System.Classes,
  System.SyncObjs,
  System.SysUtils,
  SafeThread4D;

type
  [TestFixture]
  TSafeThread4DHeartbeatTests = class
  public
    [Test] procedure Heartbeat_Enabled_FiresWhileWorkerIsActive;
    [Test] procedure Heartbeat_Disabled_DoesNotFire;
    [Test] procedure Heartbeat_StopsAfterTermination;
    [Test] procedure Heartbeat_RespectsCancellation_AndStops;
  end;

implementation

uses
  SafeThread4D.Tests.Support;

procedure TSafeThread4DHeartbeatTests.Heartbeat_Enabled_FiresWhileWorkerIsActive;
var
  Params: ISafeThread4DParams;
  ReleaseWork: TEvent;
  Count: Integer;
begin
  Count := 0;
  ReleaseWork := TEvent.Create(nil, True, False, '');
  try
    Params := TSafeThread4DParams.New
      .SetHeartbeatIntervalMs(50)
      .SetOnExecute(
        procedure(Ctx: TThreadContext)
        begin
          ReleaseWork.WaitFor(1000);
        end)
      .SetOnHeartbeat(
        procedure
        begin
          TInterlocked.Increment(Count);
        end);

    TSafeThread4D.StartThread(Params);

    Assert.IsTrue(
      TSafeThread4DTestSupport.WaitUntil(
        function: Boolean
        begin
          Result := Count >= 1;
        end,
        1000),
        'Heartbeat did not fire while worker was active.');

    ReleaseWork.SetEvent;

    Assert.IsTrue(
      TSafeThread4DTestSupport.WaitUntil(
        function: Boolean
        begin
          Result := not Params.IsRunning;
        end,
        3000),
        'Worker did not terminate in time.');
  finally
    ReleaseWork.Free;
  end;
end;

procedure TSafeThread4DHeartbeatTests.Heartbeat_Disabled_DoesNotFire;
var
  Params: ISafeThread4DParams;
  Count: Integer;
begin
  Count := 0;

  Params := TSafeThread4DParams.New
    .SetHeartbeatIntervalMs(0) // Explicit: 0 means disabled.
    .SetOnExecute(
      procedure(Ctx: TThreadContext)
      begin
        TThread.Sleep(150);
      end)
    .SetOnHeartbeat(
      procedure
      begin
        TInterlocked.Increment(Count);
      end);

  TSafeThread4D.StartThread(Params);

  Assert.IsTrue(
    TSafeThread4DTestSupport.WaitUntil(
      function: Boolean
      begin
        Result := not Params.IsRunning;
      end,
      3000),
      'Task did not terminate in time.');

  TSafeThread4DTestSupport.PumpMessages(100);

  Assert.AreEqual(0, Count);
end;

procedure TSafeThread4DHeartbeatTests.Heartbeat_StopsAfterTermination;
var
  Params: ISafeThread4DParams;
  ReleaseWork: TEvent;
  CountAtEnd: Integer;
  FinalCount: Integer;
begin
  CountAtEnd := 0;
  FinalCount := 0;
  ReleaseWork := TEvent.Create(nil, True, False, '');
  try
    Params := TSafeThread4DParams.New
      .SetHeartbeatIntervalMs(40)
      .SetOnExecute(
        procedure(Ctx: TThreadContext)
        begin
          ReleaseWork.WaitFor(1000);
        end)
      .SetOnHeartbeat(
        procedure
        begin
          TInterlocked.Increment(FinalCount);
        end);

    TSafeThread4D.StartThread(Params);

    Assert.IsTrue(
      TSafeThread4DTestSupport.WaitUntil(
        function: Boolean
        begin
          Result := FinalCount >= 1;
        end,
        1000),
        'Heartbeat did not fire while worker was active.');

    ReleaseWork.SetEvent;

    Assert.IsTrue(
      TSafeThread4DTestSupport.WaitUntil(
        function: Boolean
        begin
          Result := not Params.IsRunning;
        end,
        3000),
        'Worker did not terminate in time.');

    CountAtEnd := FinalCount;
    TSafeThread4DTestSupport.PumpMessages(200);

    Assert.IsTrue(CountAtEnd >= 1);
    Assert.AreEqual(CountAtEnd, FinalCount);
  finally
    ReleaseWork.Free;
  end;
end;

procedure TSafeThread4DHeartbeatTests.Heartbeat_RespectsCancellation_AndStops;
var
  Params: ISafeThread4DParams;
  ExecuteStarted: TEvent;
  CancelCalled: Boolean;
  CountAfterStop: Integer;
  Count: Integer;
begin
  ExecuteStarted := TEvent.Create(nil, True, False, '');
  try
    CancelCalled := False;
    CountAfterStop := 0;
    Count := 0;

    Params := TSafeThread4DParams.New
      .SetHeartbeatIntervalMs(40)
      .SetOnExecute(
        procedure(Ctx: TThreadContext)
        var
          I: Integer;
        begin
          ExecuteStarted.SetEvent;
          for I := 1 to 100 do
          begin
            TSafeThread4D.CheckCancel(Params, Ctx);
            TThread.Sleep(10);
          end;
        end)
      .SetOnHeartbeat(
        procedure
        begin
          TInterlocked.Increment(Count);
        end)
      .SetOnCancel(
        procedure(Ctx: TThreadContext)
        begin
          CancelCalled := True;
        end);

    TSafeThread4D.StartThread(Params);

    Assert.AreEqual(
      wrSignaled,
      ExecuteStarted.WaitFor(1000),
      'OnExecute did not start in time.');

    Assert.IsTrue(
      TSafeThread4DTestSupport.WaitUntil(
        function: Boolean
        begin
          Result := Count >= 1;
        end,
        1000),
        'Heartbeat did not fire before cancellation.');

    TSafeThread4D.Cancel(Params);

    Assert.IsTrue(
      TSafeThread4DTestSupport.WaitUntil(
        function: Boolean
        begin
          Result := CancelCalled and (not Params.IsRunning);
        end,
        3000),
        'Cancelled heartbeat task did not terminate in time.');

    CountAfterStop := Count;
    TSafeThread4DTestSupport.PumpMessages(200);

    Assert.IsTrue(CancelCalled);
    Assert.AreEqual(CountAfterStop, Count);
  finally
    ExecuteStarted.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TSafeThread4DHeartbeatTests);

end.

