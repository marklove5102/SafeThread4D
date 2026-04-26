program SafeThread.Concurrency.Demo;

uses
  System.StartUpCopy,
  FMX.Forms,
  SafeThread.Concurrency.Demo.Main in '..\src\SafeThread.Concurrency.Demo.Main.pas' {FormMain};

{$R *.res}

begin
  ReportMemoryLeaksOnShutdown := True;
  Application.Initialize;
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
end.
