program SafeThread.ParallelGallery.Demo;

uses
  System.StartUpCopy,
  FMX.Forms,
  SafeThread.ParallelGallery.Demo.Main in '..\src\SafeThread.ParallelGallery.Demo.Main.pas' {FormParallelGallery};

{$R *.res}

begin
  ReportMemoryLeaksOnShutdown := True;
  Application.Initialize;
  Application.CreateForm(TFormParallelGallery, FormParallelGallery);
  Application.Run;
end.
