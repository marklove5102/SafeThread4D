program SafeThread.BulkData.Demo;

uses
  System.StartUpCopy,
  FMX.Forms,
  SafeThread.BulkData.Demo.Main in '..\src\SafeThread.BulkData.Demo.Main.pas' {FormMain};

{$R *.res}

begin
  ReportMemoryLeaksOnShutdown := True;
  Application.Initialize;
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
end.
