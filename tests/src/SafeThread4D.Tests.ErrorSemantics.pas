// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Eduardo P. Araujo
// https://github.com/eduardoparaujo/SafeThread4D

{*
  Unit   : SafeThread4D.Tests.ErrorSemantics
  Purpose: DUnitX fixture covering exception-driven lifecycle behavior for
           SafeThread4D.

  Part of the SafeThread4D test suite.

  Notes:
    - Verifies OnError ordering and error publication.
    - Covers CompleteWithError True/False behavior.
    - Confirms ThreadHadError state after worker exceptions.
*}

unit SafeThread4D.Tests.ErrorSemantics;

interface

uses
  DUnitX.TestFramework,
  System.Classes,
  System.Generics.Collections,
  System.SysUtils,
  SafeThread4D;

type
  [TestFixture]
  TSafeThread4DErrorSemanticsTests = class
  public
    [Test] procedure OnExecute_RaisingException_FiresOnError_SkipsOnSuccessAndComplete;
    [Test] procedure OnExecute_RaisingException_WithCompleteWithErrorTrue_FiresOnComplete;
    [Test] procedure OnExecute_RaisingException_WithCompleteWithErrorFalse_SkipsOnComplete;
    [Test] procedure OnExecute_RaisingException_SetsThreadHadError_AndOrdersOnErrorBeforeOnTerminate;
  end;

implementation

uses
  SafeThread4D.Tests.Support;

procedure TSafeThread4DErrorSemanticsTests.OnExecute_RaisingException_FiresOnError_SkipsOnSuccessAndComplete;
var
  Params: ISafeThread4DParams;
  Steps: TList<string>;
  Terminated: Boolean;
begin
  Steps := TList<string>.Create;
  try
    Terminated := False;

    Params := TSafeThread4DParams.New
      .SetOnExecute(
        procedure(Ctx: TThreadContext)
        begin
          TSafeThread4DTestSupport.AddStep(Steps, 'OnExecute');
          raise Exception.Create('boom');
        end)
      .SetOnError(
        procedure(const AErrorMessage: string; const AContext: TThreadContext)
        begin
          TSafeThread4DTestSupport.AddStep(Steps, 'OnError');
          Assert.AreEqual('boom', AErrorMessage);
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
        'Error path did not terminate in time. Current sequence: ' + TSafeThread4DTestSupport.JoinSteps(Steps));

    Assert.AreEqual(
      'OnExecute -> OnError -> OnTerminate',
      TSafeThread4DTestSupport.JoinSteps(Steps));
  finally
    Steps.Free;
  end;
end;

procedure TSafeThread4DErrorSemanticsTests.OnExecute_RaisingException_WithCompleteWithErrorTrue_FiresOnComplete;
var
  Params: ISafeThread4DParams;
  Steps: TList<string>;
  Terminated: Boolean;
begin
  Steps := TList<string>.Create;
  try
    Terminated := False;

    Params := TSafeThread4DParams.New
      .SetCompleteWithError(True)
      .SetOnExecute(
        procedure(Ctx: TThreadContext)
        begin
          TSafeThread4DTestSupport.AddStep(Steps, 'OnExecute');
          raise Exception.Create('boom');
        end)
      .SetOnError(
        procedure(const AErrorMessage: string; const AContext: TThreadContext)
        begin
          TSafeThread4DTestSupport.AddStep(Steps, 'OnError');
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
        'Error path with CompleteWithError=True did not terminate in time. Current sequence: ' + TSafeThread4DTestSupport.JoinSteps(Steps));

    Assert.AreEqual(
      'OnExecute -> OnError -> OnComplete -> OnTerminate',
      TSafeThread4DTestSupport.JoinSteps(Steps));
  finally
    Steps.Free;
  end;
end;

procedure TSafeThread4DErrorSemanticsTests.OnExecute_RaisingException_WithCompleteWithErrorFalse_SkipsOnComplete;
var
  Params: ISafeThread4DParams;
  Steps: TList<string>;
  Terminated: Boolean;
begin
  Steps := TList<string>.Create;
  try
    Terminated := False;

    Params := TSafeThread4DParams.New
      .SetCompleteWithError(False)
      .SetOnExecute(
        procedure(Ctx: TThreadContext)
        begin
          TSafeThread4DTestSupport.AddStep(Steps, 'OnExecute');
          raise Exception.Create('boom');
        end)
      .SetOnError(
        procedure(const AErrorMessage: string; const AContext: TThreadContext)
        begin
          TSafeThread4DTestSupport.AddStep(Steps, 'OnError');
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
        'Error path with CompleteWithError=False did not terminate in time. Current sequence: ' + TSafeThread4DTestSupport.JoinSteps(Steps));

    Assert.AreEqual(
      'OnExecute -> OnError -> OnTerminate',
      TSafeThread4DTestSupport.JoinSteps(Steps));
  finally
    Steps.Free;
  end;
end;

procedure TSafeThread4DErrorSemanticsTests.OnExecute_RaisingException_SetsThreadHadError_AndOrdersOnErrorBeforeOnTerminate;
var
  Params: ISafeThread4DParams;
  Steps: TList<string>;
  Terminated: Boolean;
begin
  Steps := TList<string>.Create;
  try
    Terminated := False;

    Params := TSafeThread4DParams.New
      .SetOnExecute(
        procedure(Ctx: TThreadContext)
        begin
          TSafeThread4DTestSupport.AddStep(Steps, 'OnExecute');
          raise Exception.Create('boom');
        end)
      .SetOnError(
        procedure(const AErrorMessage: string; const AContext: TThreadContext)
        begin
          TSafeThread4DTestSupport.AddStep(Steps, 'OnError');
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
        'Error path did not terminate in time. Current sequence: ' + TSafeThread4DTestSupport.JoinSteps(Steps));

    Assert.IsTrue(Params.GetThreadHadError, 'ThreadHadError should be True after an exception.');
    Assert.AreEqual(
      'OnExecute -> OnError -> OnTerminate',
      TSafeThread4DTestSupport.JoinSteps(Steps));
  finally
    Steps.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TSafeThread4DErrorSemanticsTests);

end.

