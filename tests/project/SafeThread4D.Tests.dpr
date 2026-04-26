// SPDX-License-Identifier: MIT
// SafeThread4D DUnitX test runner.
// Console runner for the SafeThread4D automated test suite.

program SafeThread4D.Tests;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils,
  DUnitX.TestFramework,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.XML.NUnit,
  SafeThread4D.Tests.Support in '..\src\SafeThread4D.Tests.Support.pas',
  SafeThread4D.Tests.Params in '..\src\SafeThread4D.Tests.Params.pas',
  SafeThread4D.Tests.Helpers in '..\src\SafeThread4D.Tests.Helpers.pas',
  SafeThread4D.Tests.Lifecycle in '..\src\SafeThread4D.Tests.Lifecycle.pas',
  SafeThread4D.Tests.CancelTimeout in '..\src\SafeThread4D.Tests.CancelTimeout.pas',
  SafeThread4D.Tests.ErrorSemantics in '..\src\SafeThread4D.Tests.ErrorSemantics.pas',
  SafeThread4D.Tests.Guards in '..\src\SafeThread4D.Tests.Guards.pas',
  SafeThread4D.Tests.ReuseAndCompletion in '..\src\SafeThread4D.Tests.ReuseAndCompletion.pas',
  SafeThread4D.Tests.Heartbeat in '..\src\SafeThread4D.Tests.Heartbeat.pas',
  SafeThread4D.Tests.Progress in '..\src\SafeThread4D.Tests.Progress.pas';

procedure PauseAtEnd;
begin
  if SameText(GetEnvironmentVariable('CI'), 'true') or
     SameText(GetEnvironmentVariable('CI'), '1') or
     FindCmdLineSwitch('no-pause', ['-', '/'], True) then
    Exit;

  Writeln;
  Writeln('Press Enter to close...');
  Readln;
end;

var
  Runner: ITestRunner;
  Results: IRunResults;
  Logger: ITestLogger;
  NUnitLogger: ITestLogger;
begin
  try
    TDUnitX.CheckCommandLine;

    Runner := TDUnitX.CreateRunner;
    Runner.UseRTTI := True;
    Runner.FailsOnNoAsserts := False;

    Logger := TDUnitXConsoleLogger.Create(True);
    Runner.AddLogger(Logger);

    NUnitLogger := TDUnitXXMLNUnitFileLogger.Create;
    Runner.AddLogger(NUnitLogger);

    Results := Runner.Execute;

    if Assigned(Results) and (not Results.AllPassed) then
      ExitCode := 1
    else
      ExitCode := 0;

  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;

  PauseAtEnd;
end.

