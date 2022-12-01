unit DWL.DisCo.UIClient;

interface

uses
  DWL.DisCo;

type
  TdwlDisCoUIClient = class(TdwlDiscoClient)
  strict private
    class var
      FProgressObject: TObject;
  public
    class constructor Create;
    class destructor Destroy;
  end;

implementation

uses
  System.SysUtils, DWL.OS, DWL.DisCo.UIClient.ProgressForm, Vcl.Forms;

type
  TProgressObject = class
  strict private
    FProgressForm: TDiscoUIClientProgressForm;
    procedure CheckProgressForm;
  private
    procedure ProgressBytes(ReceivedBytes, TotalBytes: cardinal; var CancelReceiving: boolean);
    procedure ProgressMessage(const Msg: string; ProcessingFinished: boolean);
  public
    destructor Destroy; override;
  end;

{ TdwlDisCoUIClient }

class constructor TdwlDisCoUIClient.Create;
begin
  inherited;
  FProgressObject := TProgressObject.Create;
  FProgressBytesFunc := TProgressObject(FProgressObject).ProgressBytes;
  FProgressMsgFunc := TProgressObject(FProgressObject).ProgressMessage;
end;

class destructor TdwlDisCoUIClient.Destroy;
begin
  FProgressObject.Free;
  inherited;
end;

{ TProgressObject }

procedure TProgressObject.CheckProgressForm;
begin
  if FProgressForm=nil then
  begin
    FProgressForm := TDiscoUIClientProgressForm.Create(nil);
    FProgressForm.Show;
  end;
  Application.ProcessMessages;
end;

destructor TProgressObject.Destroy;
begin
  FProgressForm.Free;
  inherited Destroy;
end;

procedure TProgressObject.ProgressBytes(ReceivedBytes, TotalBytes: cardinal; var CancelReceiving: boolean);
begin
  CheckprogressForm;
  FProgressForm.Progress(ReceivedBytes, TotalBytes);
  CancelReceiving := FProgressForm.Cancelled;
end;

procedure TProgressObject.ProgressMessage(const Msg: string; ProcessingFinished: boolean);
begin
  if ProcessingFinished then
    FreeAndNil(FProgressForm)
  else
  begin
    CheckProgressForm;
    FProgressForm.Info(Msg);
  end;
end;

end.
