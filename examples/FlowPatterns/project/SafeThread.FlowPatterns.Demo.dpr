program SafeThread.FlowPatterns.Demo;

uses
  System.StartUpCopy,
  FMX.Forms,
  SafeThread.FlowPatterns.Demo.Main in '..\src\SafeThread.FlowPatterns.Demo.Main.pas' {FormMain};

{$R *.res}

begin
  ReportMemoryLeaksOnShutdown := True;
  Application.Initialize;
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
end.
