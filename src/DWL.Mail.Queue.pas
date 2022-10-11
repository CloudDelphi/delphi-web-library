unit DWL.Mail.Queue;

interface

uses
  DWL.Params, IdMessage, System.Generics.Collections, DWL.Logging,
  System.Classes, System.Rtti;

const
  Param_mailQueue_Domains = 'mailqueue_domains';

type
  TdwlMailQueue = record
  strict private
  class var
    FParams: IdwlParams;
    FMailSendThread: TThread;
    class procedure ParamChanged(Sender: IdwlParams; const Key: string; const Value: TValue); static;
  private
  class var
    FMailAddedEvent: THandle;
    FDomainContexts: TDictionary<string, IdwlParams>;
    FDefaultDomainContextParams: IdwlParams;
    class procedure Log(const Msg: string; SeverityLevel: TdwlLogSeverityLevel=lsNotice); static;
  public
    class constructor Create;
    class destructor Destroy;
    /// <summary>
    ///   <para>
    ///     Call Configure to activate the MailQueue. The Params object will
    ///     'taken' and when sending is active modified internally within the processor (f.e. when
    ///     refreshtokens are changed), This opens the possibility to attach
    ///     an event to the Params to save the changes persistently.
    ///   </para>
    ///   <para>
    ///     Needed keys: <br />- MySQL configuration related keys like host,
    ///     username, password and db <br />- mailqueue_domains (only when sending enabled): a JSON
    ///     string with an array of objects. each object represents a
    ///     delivery domain and needs to contains keys for domain, host,
    ///     port, username, password or endpoint/clientid/refreshtoken in the
    ///     case of oauth2 configuration <br />
    ///   </para>
    /// </summary>
    class procedure Configure(Params: IdwlParams; EnableMailSending: boolean=false); static;
    /// <summary>
    ///   Queues an Indy TIdMessage for sending. Please note ownership of
    ///   the IdMessage is not taken! You have to free it yourself (because you
    ///   also created it ;-)
    /// </summary>
    class procedure QueueForSending(Msg: TIdMessage); static;
  end;


implementation

uses
  DWL.MySQL, DWL.Params.Consts, System.JSON, Winapi.Windows, System.SysUtils,
  IdSMTP, IdSSLOpenSSL, IdSASL, DWL.HTTP.APIClient.OAuth2, DWL.HTTP.APIClient,
  IdAssignedNumbers, System.Math, IdExplicitTLSClientServerBase, DWL.Classes;

type
  TdwlMailStatus = (msQueued=0, msRetrying=2, msSent=5, msError=9);

  TIdSASLOAuth2 = class(TIdSASL)
  private
    FToken: string;
    FUser: string;
  public
    property Token: string read FToken write FToken;
    property User: string read FUser write FUser;
    class function ServiceName: TIdSASLServiceName; override;
    function StartAuthenticate(const AChallenge, AHost, AProtocolName: string): string; override;
  end;

  TMailSendThread = class(TThread)
  strict private
    FParams: IdwlParams;
    FSMTP: TIdSMTP;
    FIdSASL: TIdSASLOAuth2;
    FCurrentContextParams: IdwlParams;
    FCurrentRefreshToken: string;
    procedure FreeSMTP;
    procedure Process;
    function ProcessMsg(Msg: TIdMessage): TdwlResult;
    procedure Refreshtoken_Callback(var Token: string; Action: TdwlAPIAuthorizerCallBackAction);
  protected
    procedure Execute; override;
  public
    constructor Create(Params: IdwlParams);
  end;

{ TdwlMailQueue }

class procedure TdwlMailQueue.Configure(Params: IdwlParams; EnableMailSending: boolean=false);
const
  SQL_CheckTable = 'CREATE TABLE IF NOT EXISTS dwl_mailqueue (' +
    'Id INT UNSIGNED NOT NULL AUTO_INCREMENT, ' +
    'MomentInQueue DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, ' +
    'Status TINYINT NOT NULL DEFAULT ''0'', ' +
    'Attempts TINYINT NULL DEFAULT ''0'', ' +
    'DelayedUntil DATETIME NULL DEFAULT NULL, ' +
    'MomentSent DATETIME NULL DEFAULT NULL, ' +
    'ProcessingLog TEXT NULL, ' +
    'BccRecipients TEXT NULL, ' +
    'Eml LONGTEXT NOT NULL, ' +
    'PRIMARY KEY (Id), ' +
    'INDEX `StatusDelayedUntilIndex` (`Status`, `DelayedUntil`))';
begin
  FParams := Params;
  if EnableMailSending then
  begin
    FParams.WriteValue(Param_CreateDatabase, true);
    FParams.WriteValue(Param_TestConnection, true);
    var Session := New_MySQLSession(FParams);
    FParams.ClearKey(Param_CreateDatabase);
    FParams.ClearKey(Param_TestConnection);
    SeSsion.CreateCommand(SQL_CheckTable).Execute;
    FDomainContexts := TDictionary<string, IdwlParams>.Create;
    var DomainContextStr := FParams.StrValue(Param_mailQueue_Domains);
    if DomainContextStr<>'' then
    begin
      var JSON := TJSONObject.ParseJSONValue(DomainContextStr);
      try
        if JSON is TJSONArray then
        begin
          var Enum := TJSONArray(JSON).GetEnumerator;
          try
            while ENum.MoveNext do
            begin
              if not (ENum.Current is TJSONObject) then
              begin
                Log('Configured mailqueue_domains array contains a non-object entry', lsError);
                Break;
              end;
              var DomainParams := New_Params;
              DomainParams.WriteJSON(TJSONObject(ENum.Current));
              var Domain: string;
              if not DomainParams.TryGetStrValue('domain', Domain) then
                Log('Missing domain in on of the configured contexts', lsError)
              else
              begin
                DomainParams.EnableChangeTracking(ParamChanged);
                if Domain='*' then
                  FDefaultDomainContextParams := DomainParams
                else
                  FDomainContexts.Add(Domain, DomainParams);
              end;
            end;
          finally
            Enum.Free;
          end;
        end
        else
          Log('Configured mailqueue_domains is not an JSON array', lsError);
      finally
        JSON.Free;
      end;
    end;
    if FDomainContexts.Count=0 then
      Log('No domains configured, mail will not be processed', lsWarning)
    else
    begin
      var ThreadParams := New_Params;
      FParams.AssignTo(ThreadParams, Params_SQLConnection);
      FMailSendThread := TMailSendThread.Create(ThreadParams);
    end;
  end;
end;

class constructor TdwlMailQueue.Create;
begin
  inherited;
  FMailAddedEvent := CreateEvent(nil, false, false, nil);
end;

class destructor TdwlMailQueue.Destroy;
begin
  // terminate thread
  if FMailSendThread<>nil then
  begin
    FMailSendThread.Terminate;
    SetEvent(FMailAddedEvent); {To wake up thread for termination}
    FMailSendThread.WaitFor;
    FMailSendThread.Free;
  end;
  CloseHandle(FMailAddedEvent);
  FDomainContexts.Free;
  inherited;
end;

class procedure TdwlMailQueue.Log(const Msg: string; SeverityLevel: TdwlLogSeverityLevel=lsNotice);
begin
  TdwlLogger.Log(Msg, SeverityLevel, '', 'mailqueue');
end;

class procedure TdwlMailQueue.ParamChanged(Sender: IdwlParams; const Key: string; const Value: TValue);
const
  SQL_InsertOrUpdateParameter=
    'INSERT INTO dwl_parameters (`Key`, `Value`) VALUES (?, ?) ON DUPLICATE KEY UPDATE `Value`=VALUES(`Value`)';
begin
  // effectivly the only thing that is written to Params is a new refreshtoken
  // we need to save it back into the database
  if Key=Param_Refreshtoken then // just to be sure (and for documentation purposes ;-)
  begin
    var JSONArray := TJSONArray.Create;
    try
      if FDefaultDomainContextParams<>NIL then
      begin
        var JSONObject := TJSONObject.Create;
        JSONArray.Add(JSOnObject);
        FDefaultDomainContextParams.PutIntoJSONObject(JSONObject);
      end;
      var ENum := FDomainContexts.GetEnumerator;
      try
        while ENum.MoveNext do
        begin
          var JSONObject := TJSONObject.Create;
          JSONArray.Add(JSOnObject);
          ENum.Current.Value.PutIntoJSONObject(JSONObject);
        end;
      finally
        ENum.Free;
      end;
      var Cmd := New_MySQLSession(FParams).CreateCommand(SQL_InsertOrUpdateParameter);
      Cmd.Parameters.SetTextDataBinding(0, Param_mailQueue_Domains);
      Cmd.Parameters.SetTextDataBinding(1, JSONArray.ToJSON);
      Cmd.Execute;
    finally
      JSONArray.Free;
    end;
  end;
end;

class procedure TdwlMailQueue.QueueForSending(Msg: TIdMessage);
const
  SQL_InsertInQueue = 'INSERT INTO dwl_mailqueue (bccrecipients, eml) VALUES (?, ?)';
var
  Str: TStringStream;
begin
  Str := TStringStream.Create;
  try
    Msg.SaveToStream(Str);
    Str.Seek(0, soBeginning);
    var Cmd := New_MySQLSession(FParams).CreateCommand(SQL_InsertInQueue);
    Cmd.Parameters.SetTextDataBinding(0, Msg.BccList.EMailAddresses);
    Cmd.Parameters.SetTextDataBinding(1, Str.ReadString(MaxInt));
    Cmd.Execute;
    SetEvent(FMailAddedEvent);
  finally
    Str.Free;
  end;
end;

{ TMailSendThread }

constructor TMailSendThread.Create(Params: IdwlParams);
begin
  inherited Create;
  FParams := Params;
end;

procedure TMailSendThread.Execute;
begin
  while not Terminated do
  begin
    Process;
    WaitForSingleObject(TdwlMailQueue.FMailAddedEvent, 300000{5 min});
  end;
end;

procedure TMailSendThread.FreeSMTP;
begin
  if FSMTP=nil then
    Exit;
  FreeAndNil(FSMTP);
  FreeAndNil(FIdSASL);
  FCurrentContextParams := nil;
end;

procedure TMailSendThread.Process;
const
  SQL_GetQueuedMail =
    'SELECT Id, eml, bccrecipients, Attempts FROM dwl_mailqueue '+
    'WHERE (Status<?) and ((DelayedUntil is NULL) or (DelayedUntil<=CURRENT_TIMESTAMP())) '+
    'and ((Attempts IS NULL) or (Attempts<?)) ORDER BY Status, DelayedUntil';
  SQL_UPDATE_part1 = 'UPDATE dwl_mailqueue SET status=';
  SQL_UPDATE_part3_Complete = ', attempts=?, momentsent=CURRENT_TIMESTAMP() WHERE id=?';
  SQL_UPDATE_part3_Retry = ', attempts=?, DelayedUntil=DATE_ADD(CURRENT_TIMESTAMP(), INTERVAL 5 MINUTE) WHERE id=?';
  SQL_UPDATE_part3_Error = ', attempts=?, DelayedUntil=NULL WHERE id=?';
  MAX_ATTEMPTS = 5;
begin
  try
    var Session := New_MySQLSession(FParams);
    var Cmd_Queue := Session.CreateCommand(SQL_GetQueuedMail);
    Cmd_Queue.Parameters.SetIntegerDataBinding(0, ord(msSent));
    Cmd_Queue.Parameters.SetIntegerDataBinding(1, MAX_ATTEMPTS);
    Cmd_Queue.Execute;
    var Reader := Cmd_Queue.Reader;
    while Reader.Read do
    begin
      var Current_ID := Reader.GetInteger(0);
      var Attempts := Reader.GetInteger(3, true);
      inc(Attempts);
      var Str := TStringStream.Create(Reader.GetString(1));
      try
        var Msg := TIdMessage.Create(nil);
        try
          Msg.LoadFromStream(Str);
          Msg.BccList.EMailAddresses := Cmd_Queue.Reader.GetString(2, true);
          var Update_SQL := SQL_UPDATE_part1;
          var Res := ProcessMsg(Msg);
          if Res.Success then
            Update_SQL := Update_SQL+byte(msSent).ToString+SQL_UPDATE_part3_Complete
          else
          begin
            if Attempts=MAX_ATTEMPTS then
              Update_SQL := Update_SQL+byte(msError).ToString+SQL_UPDATE_part3_Error
            else
              Update_SQL := Update_SQL+byte(msRetrying).ToString+SQL_UPDATE_part3_Retry;
          end;
          var Cmd := Session.CreateCommand(Update_SQL);
          Cmd.Parameters.SetIntegerDataBinding(0, Attempts);
          Cmd.Parameters.SetIntegerDataBinding(1, Current_ID);
          Cmd.Execute;
          if Res.Success then
            TdwlMailQueue.Log('Successfully sent mail to '+Msg.Recipients.EMailAddresses, lsTrace)
          else
            TdwlMailQueue.Log('Failed to sent mail ['+Res.ErrorMsg+'] to '+Msg.Recipients.EMailAddresses, lsTrace);
        finally
          Msg.Free;
        end;
      finally
        Str.Free;
      end;
     end;
  finally
    FreeSMTP;
    FCurrentContextParams := nil;
  end;
end;

function TMailSendThread.ProcessMsg(Msg: TIdMessage): TdwlResult;
const
  MAX_DIRECT_ATTEMPTS=2;
begin
  var MailIsSent := false;
  try
    var DomainFrom := Msg.From.Address;
    var P := pos('@', DomainFrom);
    DomainFrom := LowerCase(trim(Copy(DomainFrom, p+1, MaxInt)));
    // introduced an attemptcount to handle email servers who just disconnect the
    // first time as a spam prevention measure
    var AttemptCount := 0;
    while (not MailIsSent) and (AttemptCount<MAX_DIRECT_ATTEMPTS) do
    begin
      var DomainContextParams: IdwlParams;
      if not TdwlMailQueue.FDomainContexts.TryGetValue(DomainFrom, DomainContextParams) then
        DomainContextParams := TdwlMailQueue.FDefaultDomainContextParams;
      if (FSMTP=nil) or (not FSMTP.Connected) or (FCurrentContextParams<>DomainContextParams) then
      begin
        FreeSMTP;
        FSMTP := TIdSMTP.Create(nil);
        FCurrentContextParams := DomainContextParams;
        // AdR 20190820: See if setting timeouts prevent the queue from
        // hanging sometimes...
        FSMTP.ConnectTimeout := 30000; {30 secs}
        FSMTP.ReadTimeout := 30000; {30 secs}
        FSMTP.Host := FCurrentContextParams.StrValue(Param_Host);
        FSMTP.Port := FCurrentContextParams.IntValue(Param_Port, 25);
        FSMTP.Username := FCurrentContextParams.StrValue(Param_Username);
        FCurrentRefreshToken := FCurrentContextParams.StrValue(Param_Refreshtoken);
        if FCurrentRefreshToken<>'' then
        begin
          FSMTP.AuthType := satSASL;
          var Authorizer := New_OAuth2Authorizer(Refreshtoken_Callback, FCurrentContextParams.StrValue('endpoint'), FCurrentContextParams.StrValue('clientid'), FCurrentContextParams.StrValue('redirect_uri'), []{scopes not needed, are already embedded in refreshtoken}, '');
          var AccessToken := Authorizer.GetAccesstoken;
          if AccessToken='' then
          begin
            TdwlMailQueue.Log('Error fetching Access token for Context: '+DomainFrom);
            Exit;
          end;
          FIdSASL := TIdSASLOAuth2.Create(nil);
          FIdSASL.Token := AccessToken;
          FIdSASL.User := FSMTP.Username;
          FSMTP.SASLMechanisms.Add.SASL := FIdSASL;
        end
        else
          FSMTP.Password := FCurrentContextParams.StrValue('password');
        if (FSMTP.Port= IdPORT_ssmtp) or (FSMTP.Port=Id_PORT_submission) then
        begin
          var sslHandler := TIdSSLIOHandlerSocketOpenSSL.Create(FSMTP);
          sslHandler.SSLOptions.Method := sslvTLSv1_2;
          FSMTP.IOHandler := sslHandler;
          if FSMTP.Port=IdPORT_ssmtp then
            FSMTP.UseTLS := utUseImplicitTLS
          else
            FSMTP.UseTLS := utUseExplicitTLS;
        end;
        FSMTP.Connect;
      end;
      try
        if not FSMTP.Connected then
          raise Exception.Create('Failed to connect to mailserver');
        FSMTP.Send(Msg);
        MailIsSent := true;
      except
        on E: Exception do
        begin
          if AttemptCount<MAX_DIRECT_ATTEMPTS then
            // in office 365 an exception occurs because the server just disconnects (as spam prevention)
            // let's try another attempt immediately
            FSMTP.Disconnect
          else
            raise;
        end;
      end;
    end;
    if not MailIsSent and Result.Success then
      Result.AddErrorMsg('For some unknown reason mail was not sent');
  except
    on E:Exception do
      Result.AddErrorMsg('Failed delivery for "'+Msg.From.Address+'": '+E.Message);
  end;
end;

procedure TMailSendThread.Refreshtoken_Callback(var Token: string; Action: TdwlAPIAuthorizerCallBackAction);
begin
  if Action=acaGetRefreshtoken then
    Token := FCurrentRefreshToken;
  if Action=acaNewRefreshtoken then
  begin
    FCurrentContextParams.WriteValue(Param_Refreshtoken, Token);
    // we need to add here that the mailqueue_domains is written back to params
  end;
end;

{ TIdSASLOAuth2 }

class function TIdSASLOAuth2.ServiceName: TIdSASLServiceName;
begin
  Result := 'XOAUTH2';
end;

function TIdSASLOAuth2.StartAuthenticate(const AChallenge, AHost, AProtocolName: string): string;
begin
  Result := 'user=' + FUser + Chr($01) + 'auth=Bearer ' + FToken + Chr($01) + Chr($01);
end;

end.
