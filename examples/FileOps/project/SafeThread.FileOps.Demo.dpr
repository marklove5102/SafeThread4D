program SafeThread.FileOps.Demo;

uses
  System.StartUpCopy,
  FMX.Forms,
  SafeThread.FileOps.Demo.Main in '..\src\SafeThread.FileOps.Demo.Main.pas' {FormMain};

{$R *.res}

begin
  ReportMemoryLeaksOnShutdown := True;
  Application.Initialize;
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
end.
