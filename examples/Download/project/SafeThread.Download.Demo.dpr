program SafeThread.Download.Demo;

uses
  System.StartUpCopy,
  FMX.Forms,
  SafeThread.Download.Demo.Main in '..\src\SafeThread.Download.Demo.Main.pas' {FormMain};

{$R *.res}

begin
  ReportMemoryLeaksOnShutdown := True;
  Application.Initialize;
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
end.
