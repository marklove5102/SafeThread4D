// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Eduardo P. Araujo
// https://github.com/eduardoparaujo/SafeThread4D

{*
  Unit   : SafeThread4D.Tests.Progress
  Purpose: DUnitX fixture covering progress publication, throttling rules,
           and forced final 100% behavior.

  Part of the SafeThread4D test suite.

  Notes:
    - Verifies worker-to-UI progress delivery.
    - Covers throttle suppression and interval-respecting updates.
    - Confirms final 100% publication ordering and deduplication.
*}

unit SafeThread4D.Tests.Progress;

interface

uses
  DUnitX.TestFramework,
  System.Classes,
  System.Generics.Collections,
  System.SysUtils,
  SafeThread4D;

type
  [TestFixture]
  TSafeThread4DProgressTests = class
  public
    [Test] procedure Progress_FromWorker_ReachesUI;
    [Test] procedure Progress_FirstPulse_IsNotThrottled_AndRapidUpdatesAreSuppressed;
    [Test] procedure Progress_SpacedUpdates_RespectInterval;
    [Test] procedure Progress_ForcedFinal100_FiresBeforeOnSuccess;
    [Test] procedure Progress_ForcedFinal100_NotDuplicated_WhenSuccessAndCompleteBothExist;
  end;

implementation

uses
  SafeThread4D.Tests.Support;

procedure TSafeThread4DProgressTests.Progress_FromWorker_ReachesUI;
var
  Params: ISafeThread4DParams;
  Terminated: Boolean;
  ProgressCount: Integer;
  LastProgress: Single;
begin
  Terminated := False;
  ProgressCount := 0;
  LastProgress := -1;

  Params := TSafeThread4DParams.New
    .SetOnExecute(
      procedure(Ctx: TThreadContext)
      begin
        TSafeThread4D.ReportProgress(Params, 0.5);
        TThread.Sleep(20);
      end)
    .SetOnProgress(
      procedure(P: Single)
      begin
        Inc(ProgressCount);
        LastProgress := P;
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
      3000),
      'Progress test did not terminate in time.');

  TSafeThread4DTestSupport.PumpMessages(50);

  Assert.AreEqual(1, ProgressCount);
  Assert.IsTrue(Abs(LastProgress - 0.5) < 0.0001);
end;

procedure TSafeThread4DProgressTests.Progress_FirstPulse_IsNotThrottled_AndRapidUpdatesAreSuppressed;
var
  Params: ISafeThread4DParams;
  Terminated: Boolean;
  Values: TList<Single>;
begin
  Terminated := False;
  Values := TList<Single>.Create;
  try
    Params := TSafeThread4DParams.New
      .SetProgressIntervalMs(1000)
      .SetOnExecute(
        procedure(Ctx: TThreadContext)
        begin
          TSafeThread4D.ReportProgress(Params, 0.1);
          TThread.Sleep(20);
          TSafeThread4D.ReportProgress(Params, 0.2);
          TThread.Sleep(20);
          TSafeThread4D.ReportProgress(Params, 0.3);
        end)
      .SetOnProgress(
        procedure(P: Single)
        begin
          Values.Add(P);
        end)
      // Note: no OnSuccess/OnComplete is set here,
      // so the forced final 100% pulse does not fire in this scenario.
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
        3000),
        'Progress suppression test did not terminate in time.');

    TSafeThread4DTestSupport.PumpMessages(50);

    Assert.AreEqual(1, Values.Count, 'Throttle should suppress rapid updates within the interval.');
    Assert.IsTrue(Abs(Values[0] - 0.1) < 0.0001);
  finally
    Values.Free;
  end;
end;

procedure TSafeThread4DProgressTests.Progress_SpacedUpdates_RespectInterval;
var
  Params: ISafeThread4DParams;
  Terminated: Boolean;
  Values: TList<Single>;
begin
  Terminated := False;
  Values := TList<Single>.Create;
  try
    Params := TSafeThread4DParams.New
      .SetProgressIntervalMs(50)
      .SetOnExecute(
        procedure(Ctx: TThreadContext)
        begin
          TSafeThread4D.ReportProgress(Params, 0.1);
          TThread.Sleep(80);
          TSafeThread4D.ReportProgress(Params, 0.2);
          TThread.Sleep(80);
          TSafeThread4D.ReportProgress(Params, 0.3);
        end)
      .SetOnProgress(
        procedure(P: Single)
        begin
          Values.Add(P);
        end)
      // Note: no OnSuccess/OnComplete is set here,
      // so the forced final 100% pulse does not fire in this scenario.
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
        3000),
        'Spaced progress test did not terminate in time.');

    TSafeThread4DTestSupport.PumpMessages(50);

    Assert.AreEqual(3, Values.Count);
    Assert.IsTrue(Abs(Values[0] - 0.1) < 0.0001);
    Assert.IsTrue(Abs(Values[1] - 0.2) < 0.0001);
    Assert.IsTrue(Abs(Values[2] - 0.3) < 0.0001);
  finally
    Values.Free;
  end;
end;

procedure TSafeThread4DProgressTests.Progress_ForcedFinal100_FiresBeforeOnSuccess;
var
  Params: ISafeThread4DParams;
  Terminated: Boolean;
  Steps: TList<string>;
begin
  Terminated := False;
  Steps := TList<string>.Create;
  try
    Params := TSafeThread4DParams.New
      .SetOnExecute(
        procedure(Ctx: TThreadContext)
        begin
          TThread.Sleep(20);
        end)
      .SetOnProgress(
        procedure(P: Single)
        begin
          if Abs(P - 1.0) < 0.0001 then
            TSafeThread4DTestSupport.AddStep(Steps, 'OnProgress100')
          else
            TSafeThread4DTestSupport.AddStep(Steps, 'OnProgressOther');
        end)
      .SetOnSuccess(
        procedure(Ctx: TThreadContext)
        begin
          TSafeThread4DTestSupport.AddStep(Steps, 'OnSuccess');
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
        'Final 100 before success test did not terminate in time.');

    Assert.AreEqual(
      'OnProgress100 -> OnSuccess -> OnTerminate',
      TSafeThread4DTestSupport.JoinSteps(Steps));
  finally
    Steps.Free;
  end;
end;

procedure TSafeThread4DProgressTests.Progress_ForcedFinal100_NotDuplicated_WhenSuccessAndCompleteBothExist;
var
  Params: ISafeThread4DParams;
  Terminated: Boolean;
  Steps: TList<string>;
  HundredCount: Integer;
begin
  Terminated := False;
  HundredCount := 0;
  Steps := TList<string>.Create;
  try
    Params := TSafeThread4DParams.New
      .SetOnExecute(
        procedure(Ctx: TThreadContext)
        begin
          TThread.Sleep(20);
        end)
      .SetOnProgress(
        procedure(P: Single)
        begin
          if Abs(P - 1.0) < 0.0001 then
          begin
            Inc(HundredCount);
            TSafeThread4DTestSupport.AddStep(Steps, 'OnProgress100');
          end
          else
            TSafeThread4DTestSupport.AddStep(Steps, 'OnProgressOther');
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
        3000),
        'Final 100 deduplication test did not terminate in time.');

    Assert.AreEqual(1, HundredCount);
    Assert.AreEqual(
      'OnProgress100 -> OnSuccess -> OnComplete -> OnTerminate',
      TSafeThread4DTestSupport.JoinSteps(Steps));
  finally
    Steps.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TSafeThread4DProgressTests);

end.

