unit REST.Handler;

interface

uses
  System.Classes, System.SysUtils,
  {$IF DECLARED(FireMonkeyVersion)}
  FMX.Types, FMX.Forms,
  {$ELSE}
  Vcl.Forms,
  {$ENDIF}
  REST.Client, REST.Json, JSON;

type
  THandlerException = class(Exception);

  TParam = TArray<string>;

  TParams = TArray<TParam>;

  TResponseError = record
    Code: Integer;
    Text: string;
  end;

  TResponse = record
    Success: Boolean;
    JSON: string;
    Error: TResponseError;
    function GetJSONValue: TJSONValue;
    function AsObject<T: class, constructor>(out Value: T): Boolean;
  end;

  TOnHandlerError = procedure(Sender: TObject; E: Exception; Code: Integer; Text: string) of object;

  TOnHandlerLog = procedure(Sender: TObject; const Value: string) of object;

  TOnHandlerExecute = function(Sender: TObject; Request: TRESTRequest): TResponse;

  TRequestConstruct = class
    class var
      Client: TRESTClient;
  public
    class function Request(Resource: string; Params: TParams): TRESTRequest;
  end;

  TRESTHandler = class
  private
    FStartRequest: Cardinal;
    FRequests: Integer;
    FRESTClient: TRESTClient;
    FOnError: TOnHandlerError;
    FOnLog: TOnHandlerLog;
    FOwner: TObject;
    FExecuting: Integer;
    FFullLog: Boolean;
    FRequestLimitPerSecond: Integer;
    FUsePseudoAsync: Boolean;
    FOnExecute: TOnHandlerExecute;
    FQueueWaits: Integer;
    function FExecute(Request: TRESTRequest): TResponse;
    function GetExecuting: Boolean;
    function FOnExecuted(Request: TRESTRequest): TResponse;
    procedure Queue;
    procedure FLog(const Value: string);
    procedure ProcError(E: Exception); overload;
    procedure SetOnError(const Value: TOnHandlerError);
    procedure SetOnLog(const Value: TOnHandlerLog);
    procedure SetOwner(const Value: TObject);
    procedure SetFullLog(const Value: Boolean);
    procedure SetRequestLimitPerSecond(const Value: Integer);
    procedure SetUsePseudoAsync(const Value: Boolean);
    procedure SetOnExecute(const Value: TOnHandlerExecute);
    procedure InternalExecute(Request: TRESTRequest);
  public
    constructor Create(AOwner: TObject);
    destructor Destroy; override;
    procedure Log(Sender: TObject; const Text: string);
    //
    property Owner: TObject read FOwner write SetOwner;
    //
    function Execute(Request: string; Params: TParams): TResponse; overload;
    function Execute(Request: string; Param: TParam): TResponse; overload;
    function Execute(Request: string): TResponse; overload;
    function Execute(Request: TRESTRequest; FreeRequset: Boolean = False): TResponse; overload;
    //
    property OnError: TOnHandlerError read FOnError write SetOnError;
    property OnLog: TOnHandlerLog read FOnLog write SetOnLog;
    property OnExecute: TOnHandlerExecute read FOnExecute write SetOnExecute;
    //
    property Client: TRESTClient read FRESTClient;
    property Executing: Boolean read GetExecuting;
    property QueueWaits: Integer read FQueueWaits;
    //
    property UsePseudoAsync: Boolean read FUsePseudoAsync write SetUsePseudoAsync;
    property FullLog: Boolean read FFullLog write SetFullLog;
    property RequestLimitPerSecond: Integer read FRequestLimitPerSecond write SetRequestLimitPerSecond;
  end;

implementation

procedure WaitTime(MS: Int64);
begin
  if MS <= 0 then
    Exit;
  MS := TThread.GetTickCount + MS;
  while MS > TThread.GetTickCount do
    Sleep(100);
end;

{ TRequsetConstruct }

class function TRequestConstruct.Request(Resource: string; Params: TParams): TRESTRequest;
var
  Param: TParam;
begin
  Result := TRESTRequest.Create(nil);
  Result.Client := Client;
  Result.Resource := Resource;
  Result.Response := TRESTResponse.Create(Result);
  for Param in Params do
  begin
    if not Param[0].IsEmpty then
      Result.Params.AddItem(Param[0], Param[1]);
  end;
end;

{ TRESTHandler }

constructor TRESTHandler.Create(AOwner: TObject);
begin
  inherited Create;
  FOwner := AOwner;
  FExecuting := 0;
  FStartRequest := 0;
  FQueueWaits := 0;
  FRequests := 0;
  FUsePseudoAsync := True;
  FRequestLimitPerSecond := 3;
  FRESTClient := TRESTClient.Create(nil);
  FRESTClient.Accept := 'application/json, text/plain; q=0.9, text/html;q=0.8,';
  FRESTClient.AcceptCharset := 'UTF-8, *;q=0.8';

  TRequestConstruct.Client := FRESTClient;
end;

destructor TRESTHandler.Destroy;
begin
  FRESTClient.Free;
  inherited;
end;

function TRESTHandler.Execute(Request: string; Param: TParam): TResponse;
begin
  Result := Execute(TRequestConstruct.Request(Request, [Param]), True);
end;

function TRESTHandler.Execute(Request: string; Params: TParams): TResponse;
begin
  Result := Execute(TRequestConstruct.Request(Request, Params), True);
end;

function TRESTHandler.Execute(Request: string): TResponse;
begin
  Result := Execute(TRequestConstruct.Request(Request, []), True);
end;

function TRESTHandler.Execute(Request: TRESTRequest; FreeRequset: Boolean): TResponse;
begin
  try
    Inc(FExecuting);
    Result := FExecute(Request);
  finally
    if FreeRequset then
      Request.Free;
    Dec(FExecuting);
  end;
end;

procedure TRESTHandler.Queue;
begin
  //Без очереди
  if FRequestLimitPerSecond <= 0 then
    Exit;
  FRequests := FRequests + 1;
  //Если был запрос
  if FStartRequest > 0 then
  begin
    Inc(FQueueWaits);
    //Если предел запросов
    if FRequests > FRequestLimitPerSecond then
    begin
      FRequests := 0;
      WaitTime(1000 - Int64(TThread.GetTickCount - FStartRequest));
    end;
    Dec(FQueueWaits);
  end;
  FStartRequest := TThread.GetTickCount;
end;

procedure TRESTHandler.InternalExecute(Request: TRESTRequest);
begin
  Queue;
  Request.Execute;
end;

function TRESTHandler.FExecute(Request: TRESTRequest): TResponse;
var
  IsDone: Boolean;
  Error: Exception;
begin
  Error := nil;
  Result.Success := False;
  if FFullLog then
    FLog(Request.GetFullRequestURL);
  try
    IsDone := False;
    //Если вызов из главного потока, то создаем поток и ждем выполнения через Application.ProcessMessages
    if FUsePseudoAsync and (TThread.Current.ThreadID = MainThreadID) then
    begin
      with TThread.CreateAnonymousThread(
        procedure
        begin
          try
            InternalExecute(Request);
          except
            on E: Exception do
              Error := E;
          end;
          IsDone := True;
        end) do
      begin
        FreeOnTerminate := False;
        Start;
        while (not IsDone) and (not Finished) do
          Application.ProcessMessages;
        Free;
      end;
      if Assigned(Error) then
        raise Error;
    end
    else
    begin
      InternalExecute(Request);
      IsDone := True;
    end;

    if IsDone then
    begin
      if FFullLog then
        FLog(Request.Response.JSONText);

      Result := FOnExecuted(Request);
    end;
  except
    on E: Exception do
      ProcError(E);
  end;
end;

function TRESTHandler.FOnExecuted(Request: TRESTRequest): TResponse;
begin
  if Assigned(FOnExecute) then
    Result := FOnExecute(Self, Request)
  else
  begin
    Result.JSON := Request.Response.JSONText;
    Result.Success := True;
  end;
end;

procedure TRESTHandler.FLog(const Value: string);
begin
  if Assigned(FOnLog) then
    FOnLog(Self, Value);
end;

function TRESTHandler.GetExecuting: Boolean;
begin
  Result := FExecuting > 0;
end;

procedure TRESTHandler.Log(Sender: TObject; const Text: string);
begin
  if Assigned(FOnLog) then
    FOnLog(Sender, Text);
end;

procedure TRESTHandler.SetOnError(const Value: TOnHandlerError);
begin
  FOnError := Value;
end;

procedure TRESTHandler.SetOnExecute(const Value: TOnHandlerExecute);
begin
  FOnExecute := Value;
end;

procedure TRESTHandler.SetOnLog(const Value: TOnHandlerLog);
begin
  FOnLog := Value;
end;

procedure TRESTHandler.SetOwner(const Value: TObject);
begin
  FOwner := Value;
end;

procedure TRESTHandler.SetRequestLimitPerSecond(const Value: Integer);
begin
  FRequestLimitPerSecond := Value;
end;

procedure TRESTHandler.SetUsePseudoAsync(const Value: Boolean);
begin
  FUsePseudoAsync := Value;
end;

procedure TRESTHandler.SetFullLog(const Value: Boolean);
begin
  FFullLog := Value;
end;

procedure TRESTHandler.ProcError(E: Exception);
begin
  if Assigned(FOnError) then
    FOnError(Self, E, 0, E.Message);
end;

{ TResponse }

{$WARNINGS OFF}
function TResponse.AsObject<T>(out Value: T): Boolean;
begin
  if Success then
  try
    Value := TJson.JsonToObject<T>(JSON);
    Result := True;
  except
    Result := False;
  end
  else
    Result := False;
end;

function TResponse.GetJSONValue: TJSONValue;
begin
  if Success and (not JSON.IsEmpty) then
    Result := TJSONObject.ParseJSONValue(UTF8ToString(JSON))
  else
    Result := nil;
end;
{$WARNINGS ON}

end.

