program SafeThread.RestSync.Demo;

uses
  System.StartUpCopy,
  FMX.Forms,
  SafeThread.RestSync.Demo.Main in '..\src\SafeThread.RestSync.Demo.Main.pas' {Form1};

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TFormMain, Form1);
  Application.Run;
end.
