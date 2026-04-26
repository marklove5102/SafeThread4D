/// <summary>
///   Cooperative, UI-safe task runner for FMX.
///   Provides structured background execution with predictable lifecycle
///   callbacks, throttled progress updates, cooperative cancel/timeout,
///   thread naming, and optional heartbeat signaling for Android ANR awareness.
/// </summary>
///
/// <remarks>
///   SafeThread4D is designed to make asynchronous work explicit, traceable,
///   and deterministic — especially on mobile platforms where timing and UI
///   responsiveness are critical.
///
///   • All long-running work executes exclusively on a background thread.
///   • All UI interactions occur strictly through main-thread callbacks.
///   • No internal calls to Application.ProcessMessages are ever performed.
///
///   The core features include:
///     • Cooperative cancellation (CheckCancel)
///     • Cooperative timeout (CheckTimeout)
///     • Throttled progress reporting (ReportProgress)
///     • Optional heartbeat pings for Android ANR mitigation
///     • Weak + Strong startup pattern (avoids closure retain cycles)
///     • Thread naming for debugging and logging
///     • Built-in timing and logical thread identifiers
///     • Safe waiting via internal completion event (CancelAndWait)
///     • Atomic runtime state with full concurrency hardening
///     • Deterministic callback ordering (Synchronize-based)
///     • Thread priority support (Windows only — POSIX platforms such as
///       Android, iOS, and macOS impose kernel-level scheduling policies
///       that make user-level priority control unreliable or ineffective;
///       the API is intentionally gated behind {$IFDEF MSWINDOWS} to
///       prevent misleading cross-platform expectations).
/// </remarks>
///
/// <author>
///   Eduardo P. Araujo
/// </author>
///
/// <license>
///   MIT License — see LICENSE for details.
/// </license>
///
/// <info>
//    https://github.com/eduardoparaujo/SafeThread4D
/// </info>
///
/// <version>
///   Version : 1.0.0
///   Created : 2025-04-26
///   Updated : 2026-04-26
/// </version>
///
/// <history>
///   1.0.0 — Initial public release.
///
///     Lifecycle & execution model:
///       • Cooperative cancel/timeout via CheckCancel / CheckTimeout.
///       • Dedicated lifecycle callbacks (OnInitialize, OnExecute, OnSuccess,
///         OnComplete, OnError, OnCancel, OnTimeout, OnTerminate).
///       • Throttled progress reporting with first-pulse bypass.
///       • Guaranteed single final OnProgress(1.0) before OnSuccess/OnComplete.
///       • Heartbeat thread for Android ANR awareness.
///       • Weak + Strong startup pattern to avoid closure retain cycles.
///       • Thread naming and built-in timing.
///
///     Concurrency hardening:
///       • All runtime flags accessed via TInterlocked.
///       • Atomic thread handle publication (CompareExchange<TThread>).
///       • Deterministic OnError callback ordering via Synchronize.
///       • Safe thread-handle snapshots for all status queries.
///
///     Waiting & coordination:
///       • Internal completion event for safe CancelAndWait.
///       • CancelAndWait independent of TThread.FreeOnTerminate.
///       • Main-thread guard for WaitFor / CancelAndWait (deadlock prevention).
///       • Heartbeat shutdown ordered under the worker finally block.
///
///     Params lifecycle:
///       • Concurrent reuse of the same params instance is rejected.
///       • Runtime flags reset on each StartThread call.
///       • TTerminateProxy holds a strong params reference until termination.
///
///     Platform notes:
///       • Thread priority is supported only on Windows. The API is
///         conditionally compiled via {$IFDEF MSWINDOWS} because on POSIX
///         platforms (Android, iOS, macOS, Linux) priority mapping is
///         subject to kernel scheduling constraints that make it unreliable
///         or require elevated privileges. Gating the API prevents users
///         from writing code that would silently behave differently across
///         platforms.
/// </history>

unit SafeThread4D;

interface

uses
  System.Classes,
  System.Diagnostics,
  System.SysUtils,
  System.SyncObjs;

{$IFDEF MSWINDOWS}
const
  // Friendly aliases for TThreadPriority values.
  // Available on Windows only — see unit-level remarks about platform
  // scheduling constraints on POSIX systems.
  PriorityIdle         = tpIdle;
  PriorityLowest       = tpLowest;
  PriorityLower        = tpLower;
  PriorityNormal       = tpNormal;
  PriorityHigher       = tpHigher;
  PriorityHighest      = tpHighest;
  PriorityTimeCritical = tpTimeCritical;
{$ENDIF}

type
  {================}
  {== Exceptions ==}
  {================}

  EOperationCancelled = class(Exception);
  EOperationTimeout   = class(Exception);

  {====================}
  {== Thread context ==}
  {====================}
  // Immutable snapshot of the cooperative thread state
  // passed into lifecycle callbacks and helpers.

  TThreadContext = record
    ThreadName: string;
    NativeThreadID: TThreadID;
    LogicalThreadID: Integer;
    ThreadHadError: Boolean;
    ThreadCancel: Boolean;
    ElapsedMilliseconds: Int64;
    StartTick: UInt64;
  end;

  {====================}
  {== Callback types ==}
  {====================}

  TContextCallback  = reference to procedure(AContext: TThreadContext);
  TProgressCallback = reference to procedure(AProgress: Single);
  TErrorCallback    = reference to procedure(const AErrorMessage: string; const AContext: TThreadContext);
  THeartbeatProc    = reference to procedure;

  {================================================}
  {== Parameter interface (fluent configuration) ==}
  {================================================}

  ISafeThread4DParams = interface
    ['{E0B51183-B09F-4F20-AA34-0233881382B7}']

    // Fluent setters — lifecycle callbacks.
    function SetOnInitialize(const AProc: TContextCallback): ISafeThread4DParams;
    function SetOnInitializeEvent(const AProc: TNotifyEvent): ISafeThread4DParams;
    function SetOnExecute(const AProc: TContextCallback): ISafeThread4DParams;
    function SetOnSuccess(const AProc: TContextCallback): ISafeThread4DParams;
    function SetOnComplete(const AProc: TContextCallback): ISafeThread4DParams;
    function SetOnTerminate(const AProc: TContextCallback): ISafeThread4DParams;
    function SetOnTerminateEvent(const AProc: TNotifyEvent): ISafeThread4DParams;
    function SetOnError(const AProc: TErrorCallback): ISafeThread4DParams;
    function SetOnCancel(const AProc: TContextCallback): ISafeThread4DParams;

    // Fluent setters — progress and timeout.
    function SetOnProgress(const AProc: TProgressCallback): ISafeThread4DParams;
    function SetProgressIntervalMs(const AIntervalMs: Cardinal): ISafeThread4DParams;
    function SetTimeoutMs(const ATimeoutMs: Cardinal): ISafeThread4DParams;
    function SetOnTimeout(const AProc: TContextCallback): ISafeThread4DParams;

    // Fluent setters — heartbeat (Android ANR / UI watchdog friendly).
    function SetHeartbeatIntervalMs(const AIntervalMs: Cardinal): ISafeThread4DParams;
    function SetOnHeartbeat(const AProc: THeartbeatProc): ISafeThread4DParams;

    // Fluent setters — lifecycle and configuration flags.
    function SetFreeOnTerminate(const AValue: Boolean): ISafeThread4DParams;
    function SetCompleteWithError(const AValue: Boolean): ISafeThread4DParams;
    {$IFDEF MSWINDOWS}
    function SetThreadPriority(const APriority: TThreadPriority): ISafeThread4DParams;
    {$ENDIF}

    // Fluent setters — identification and diagnostics.
    function SetThreadName(const AName: string): ISafeThread4DParams;
    function SetThreadId(const AId: Integer): ISafeThread4DParams;
    function SetMeasureTime(const AValue: Boolean): ISafeThread4DParams;

    // Getters — lifecycle callbacks.
    function GetOnInitialize: TContextCallback;
    function GetOnInitializeEvent: TNotifyEvent;
    function GetOnExecute: TContextCallback;
    function GetOnSuccess: TContextCallback;
    function GetOnComplete: TContextCallback;
    function GetOnTerminate: TContextCallback;
    function GetOnTerminateEvent: TNotifyEvent;
    function GetOnError: TErrorCallback;
    function GetOnCancel: TContextCallback;

    // Getters — progress and timeout.
    function GetOnProgress: TProgressCallback;
    function GetProgressIntervalMs: Cardinal;
    function GetTimeoutMs: Cardinal;
    function GetOnTimeout: TContextCallback;

    // Getters — heartbeat.
    function GetHeartbeatIntervalMs: Cardinal;
    function GetOnHeartbeat: THeartbeatProc;

    // Getters — flags and configuration.
    function GetCompleteWithError: Boolean;
    function GetFreeOnTerminate: Boolean;
    {$IFDEF MSWINDOWS}
    function GetThreadPriority: TThreadPriority;
    {$ENDIF}

    // Getters — identification and diagnostics.
    function GetThreadName: string;
    function GetThreadId: Integer;
    function GetMeasureTime: Boolean;

    // Runtime state — atomic.
    function GetThreadHadError: Boolean;
    procedure SetThreadHadError(const AValue: Boolean);
    function GetCancelRequested: Boolean;
    procedure RequestCancel;

    // Thread handle and status.
    function GetThread: TThread;
    function IsRunning: Boolean;

    // Properties (convenience and readability).
    property OnInitialize: TContextCallback read GetOnInitialize;
    property OnInitializeEvent: TNotifyEvent read GetOnInitializeEvent;
    property OnExecute: TContextCallback read GetOnExecute;
    property OnSuccess: TContextCallback read GetOnSuccess;
    property OnComplete: TContextCallback read GetOnComplete;
    property OnTerminate: TContextCallback read GetOnTerminate;
    property OnTerminateEvent: TNotifyEvent read GetOnTerminateEvent;
    property OnError: TErrorCallback read GetOnError;
    property OnCancel: TContextCallback read GetOnCancel;

    property OnProgress: TProgressCallback read GetOnProgress;
    property ProgressIntervalMs: Cardinal read GetProgressIntervalMs;
    property TimeoutMs: Cardinal read GetTimeoutMs;
    property OnTimeout: TContextCallback read GetOnTimeout;

    property HeartbeatIntervalMs: Cardinal read GetHeartbeatIntervalMs;
    property OnHeartbeat: THeartbeatProc read GetOnHeartbeat;

    property CompleteWithError: Boolean read GetCompleteWithError;
    property FreeOnTerminate: Boolean read GetFreeOnTerminate;
    {$IFDEF MSWINDOWS}
    property ThreadPriority: TThreadPriority read GetThreadPriority;
    {$ENDIF}

    property ThreadName: string read GetThreadName;
    property ThreadId: Integer read GetThreadId;
    property MeasureTime: Boolean read GetMeasureTime;

    property ThreadHadError: Boolean read GetThreadHadError write SetThreadHadError;
    property CancelRequested: Boolean read GetCancelRequested;
    property Thread: TThread read GetThread;
  end;

  {================================================}
  {== Concrete parameter holder (fluent builder) ==}
  {================================================}

  // Design note: fields are 'private' (not 'strict private') because
  // TTerminateProxy (declared in the implementation section of this same
  // unit) needs direct access to the atomic runtime state during the
  // termination phase. Same-unit coupling is intentional and documented.
  TSafeThread4DParams = class(TInterfacedObject, ISafeThread4DParams)
  private
    // Lifecycle callbacks.
    FOnInitialize: TContextCallback;
    FOnInitializeEvent: TNotifyEvent;
    FOnExecute: TContextCallback;
    FOnSuccess: TContextCallback;
    FOnComplete: TContextCallback;
    FOnTerminate: TContextCallback;
    FOnTerminateEvent: TNotifyEvent;
    FOnError: TErrorCallback;
    FOnCancel: TContextCallback;

    // Progress and timeout.
    FOnProgress: TProgressCallback;
    FOnTimeout: TContextCallback;
    FProgressIntervalMs: Cardinal;
    FTimeoutMs: Cardinal;

    // Heartbeat.
    FHeartbeatIntervalMs: Cardinal;
    FOnHeartbeat: THeartbeatProc;

    // Flags and configuration.
    FCompleteWithError: Boolean;
    FFreeOnTerminate: Boolean;
    {$IFDEF MSWINDOWS}
    FThreadPriority: TThreadPriority;
    {$ENDIF}

    // Identification and diagnostics.
    FThreadName: string;
    FThreadId: Integer;
    FMeasureTime: Boolean;

    // Atomic runtime state — accessed only via TInterlocked.
    FThreadHadErrorInt: Integer;  // 0 = no error, 1 = error.
    FCancelRequested: Integer;    // 0 = not cancelled, 1 = cancelled.
    FRunningInt: Integer;         // 1 from StartThread until proxy finishes termination.
                                  // Used by Params.IsRunning / IsThreadRunning(Params) / CancelAndWait
                                  // as the logical lifecycle state of the task.
    FExecutionActiveInt: Integer; // 1 only while the worker body is logically active.
                                  // Cleared in the worker finally block before heartbeat shutdown
                                  // so any already queued heartbeat ping can self-abort safely.

    // Internal completion event — supports safe CancelAndWait independent of
    // TThread lifetime. Created signaled (idle state).
    FCompletedEvent: TEvent;

    // Runtime thread handle — atomic access only via AtomicGetThread.
    FThread: TThread;
    function AtomicGetThread: TThread; inline;

  public
    constructor Create;
    destructor Destroy; override;
    class function New: ISafeThread4DParams;

    // Fluent setters — lifecycle callbacks.
    function SetOnInitialize(const AProc: TContextCallback): ISafeThread4DParams; inline;
    function SetOnInitializeEvent(const AProc: TNotifyEvent): ISafeThread4DParams; inline;
    function SetOnExecute(const AProc: TContextCallback): ISafeThread4DParams; inline;
    function SetOnSuccess(const AProc: TContextCallback): ISafeThread4DParams; inline;
    function SetOnComplete(const AProc: TContextCallback): ISafeThread4DParams; inline;
    function SetOnTerminate(const AProc: TContextCallback): ISafeThread4DParams; inline;
    function SetOnTerminateEvent(const AProc: TNotifyEvent): ISafeThread4DParams; inline;
    function SetOnError(const AProc: TErrorCallback): ISafeThread4DParams; inline;
    function SetOnCancel(const AProc: TContextCallback): ISafeThread4DParams; inline;

    // Fluent setters — progress and timeout.
    function SetOnProgress(const AProc: TProgressCallback): ISafeThread4DParams; inline;
    function SetProgressIntervalMs(const AIntervalMs: Cardinal): ISafeThread4DParams; inline;
    function SetTimeoutMs(const ATimeoutMs: Cardinal): ISafeThread4DParams; inline;
    function SetOnTimeout(const AProc: TContextCallback): ISafeThread4DParams; inline;

    // Fluent setters — heartbeat.
    function SetHeartbeatIntervalMs(const AIntervalMs: Cardinal): ISafeThread4DParams; inline;
    function SetOnHeartbeat(const AProc: THeartbeatProc): ISafeThread4DParams; inline;

    // Fluent setters — flags and configuration.
    function SetFreeOnTerminate(const AValue: Boolean): ISafeThread4DParams; inline;
    function SetCompleteWithError(const AValue: Boolean): ISafeThread4DParams; inline;
    {$IFDEF MSWINDOWS}
    function SetThreadPriority(const APriority: TThreadPriority): ISafeThread4DParams; inline;
    {$ENDIF}

    // Fluent setters — identification and diagnostics.
    function SetThreadName(const AName: string): ISafeThread4DParams; inline;
    function SetThreadId(const AId: Integer): ISafeThread4DParams; inline;
    function SetMeasureTime(const AValue: Boolean): ISafeThread4DParams; inline;

    // Getters — lifecycle callbacks.
    function GetOnInitialize: TContextCallback; inline;
    function GetOnInitializeEvent: TNotifyEvent; inline;
    function GetOnExecute: TContextCallback; inline;
    function GetOnSuccess: TContextCallback; inline;
    function GetOnComplete: TContextCallback; inline;
    function GetOnTerminate: TContextCallback; inline;
    function GetOnTerminateEvent: TNotifyEvent; inline;
    function GetOnError: TErrorCallback; inline;
    function GetOnCancel: TContextCallback; inline;

    // Getters — progress and timeout.
    function GetOnProgress: TProgressCallback; inline;
    function GetProgressIntervalMs: Cardinal; inline;
    function GetTimeoutMs: Cardinal; inline;
    function GetOnTimeout: TContextCallback; inline;

    // Getters — heartbeat.
    function GetHeartbeatIntervalMs: Cardinal; inline;
    function GetOnHeartbeat: THeartbeatProc; inline;

    // Getters — flags and configuration.
    function GetCompleteWithError: Boolean; inline;
    function GetFreeOnTerminate: Boolean; inline;
    {$IFDEF MSWINDOWS}
    function GetThreadPriority: TThreadPriority; inline;
    {$ENDIF}

    // Getters — identification and diagnostics.
    function GetThreadName: string; inline;
    function GetThreadId: Integer; inline;
    function GetMeasureTime: Boolean; inline;

    // Runtime state — atomic.
    function GetThreadHadError: Boolean; inline;
    procedure SetThreadHadError(const AValue: Boolean); inline;
    function GetCancelRequested: Boolean; inline;
    procedure RequestCancel; inline;

    // Thread handle and status.
    function GetThread: TThread; inline;
    function IsRunning: Boolean; inline;
  end;

  {===============================================}
  {== Thread runner facade (static entrypoints) ==}
  {===============================================}

  TSafeThread4D = class
  public
    // Start that returns a TThread handle.
    // Prefer Params.IsRunning / CancelAndWait for lifecycle coordination.
    // If you plan to call WaitFor on the returned handle later, set FreeOnTerminate=False.
    class function StartThread(const AParams: ISafeThread4DParams): TThread; static;

    // Compatibility shim: starts the worker and ignores the handle.
    class procedure ExecuteThread(const AParams: ISafeThread4DParams); static;

    // Encapsulated weak+strong startup pattern.
    class procedure StartThreadWithWeakRef(const AParams: ISafeThread4DParams; out AWeakRef: Pointer; var AStrongRef: ISafeThread4DParams); overload; static;
    class procedure StartThreadWithWeakRef(const AParams: ISafeThread4DParams; var AStrongRef: ISafeThread4DParams); overload; static;

    // Cooperative helpers — to be called from user code inside OnExecute.
    class procedure CheckCancel(const AParams: ISafeThread4DParams; var AContext: TThreadContext); static;
    class procedure CheckTimeout(const AParams: ISafeThread4DParams; var AContext: TThreadContext); static;
    class procedure ReportProgress(const AParams: ISafeThread4DParams; const AProgress: Single; const AForce: Boolean = False); static;

    // Intentionally disabled for raw TThread handles — cannot be validated safely.
    class procedure WaitFor(const AThread: TThread); static;
    class function IsThreadRunning(const AThread: TThread): Boolean; overload; static;

    // Safe status and coordination via params.
    class function IsThreadRunning(const AParams: ISafeThread4DParams): Boolean; overload; static;
    class procedure Cancel(const AParams: ISafeThread4DParams); static;
    class procedure CancelAndWait(const AParams: ISafeThread4DParams); static;
  end;

implementation

threadvar
  // Per-thread variable: last progress dispatch tick count, used for throttling.
  // Reset to 0 at the start of every worker body so that throttle state never
  // leaks across executions on the same OS thread (defensive — anonymous
  // threads normally die after each task, but this removes any dependency
  // on that assumption).
  GLastProgressTick: UInt64;

{====================================}
{== Internal helpers (unit-scoped) ==}
{====================================}

// Returns the native thread ID of the current thread.
// Falls back to MainThreadID only if TThread.Current is nil, which is
// extremely rare (typically only when called from non-Delphi-managed code).
function GetNativeThreadIDSafe: TThreadID;
var
  LThread: TThread;
begin
  {$IF declared(TThread.Current)}
  LThread := TThread.Current;
  {$ELSE}
  LThread := TThread.CurrentThread;
  {$IFEND}
  if LThread <> nil then
    Exit(LThread.ThreadID);
  Result := MainThreadID;
end;

// Returns a monotonic 64-bit tick count. Abstracts over Delphi version differences.
function TickCount64Safe: UInt64;
begin
  {$IF declared(TThread.GetTickCount64)}
  Result := TThread.GetTickCount64;
  {$ELSE}
  Result := GetTickCount64; // SysUtils.
  {$IFEND}
end;

// Checks whether the caller is on the main thread using the OS thread ID
// directly. This avoids the fallback in GetNativeThreadIDSafe, which could
// produce a false positive if TThread.Current returned nil for a genuine
// worker thread (possible in native callbacks).
function IsMainThreadSafe: Boolean;
begin
  Result := TThread.CurrentThread.ThreadID = MainThreadID;
end;

{===============================================================}
{== TTerminateProxy — publishes final completion state safely ==}
{===============================================================}

type
  TTerminateProxy = class
  private
    FParams: ISafeThread4DParams;    // Strong reference — keeps params alive until OnTerminate fires.
    FParamsObj: TSafeThread4DParams; // Concrete params reference for internal state cleanup.
    FUserHandler: TNotifyEvent;      // User's OnTerminate event handler, if any.
  public
    constructor Create(const AParams: ISafeThread4DParams; const AUserHandler: TNotifyEvent);
    procedure HandleTerminate(Sender: TObject);
  end;

constructor TTerminateProxy.Create(const AParams: ISafeThread4DParams; const AUserHandler: TNotifyEvent);
var
  LParamsObject: TObject;
begin
  inherited Create;
  FParams := AParams;
  FUserHandler := AUserHandler;

  LParamsObject := AParams as TObject;
  if LParamsObject is TSafeThread4DParams then
    FParamsObj := TSafeThread4DParams(LParamsObject)
  else
    FParamsObj := nil;
end;

procedure TTerminateProxy.HandleTerminate(Sender: TObject);
begin
  try
    // Clear the thread handle atomically to avoid dangling references.
    if Assigned(FParamsObj) then
      TInterlocked.Exchange<TThread>(FParamsObj.FThread, nil);

    // Forward to the user's handler, if any.
    if Assigned(FUserHandler) then
      FUserHandler(Sender);
  finally
    // Publish final completion state — order matters:
    // clear active/running flags first, then release the completed event.
    if Assigned(FParamsObj) then
    begin
      TInterlocked.Exchange(FParamsObj.FExecutionActiveInt, 0);
      TInterlocked.Exchange(FParamsObj.FRunningInt, 0);
      FParamsObj.FCompletedEvent.SetEvent;
    end;

    FParams := nil;
    Free; // Self-destruct the proxy.
  end;
end;

{=========================}
{== TSafeThread4DParams ==}
{=========================}

function TSafeThread4DParams.AtomicGetThread: TThread;
begin
  // Generic CompareExchange<TThread> provides atomic read without a cast
  // through Pointer, which could trigger warnings on some compiler versions.
  Result := TInterlocked.CompareExchange<TThread>(FThread, nil, nil);
end;

constructor TSafeThread4DParams.Create;
begin
  inherited Create;

  // Lifecycle callbacks.
  FOnInitialize      := nil;
  FOnInitializeEvent := nil;
  FOnExecute         := nil;
  FOnSuccess         := nil;
  FOnComplete        := nil;
  FOnTerminate       := nil;
  FOnTerminateEvent  := nil;
  FOnError           := nil;
  FOnCancel          := nil;

  // Progress and timeout.
  FOnProgress         := nil;
  FOnTimeout          := nil;
  FProgressIntervalMs := 100;
  FTimeoutMs          := 0; // 0 = no timeout.

  // Heartbeat.
  FHeartbeatIntervalMs := 0; // 0 = disabled.
  FOnHeartbeat         := nil;

  // Flags and configuration.
  FCompleteWithError := False; // Do not call OnComplete when an error occurs.
  FFreeOnTerminate   := True;  // Auto-free thread on termination.
  {$IFDEF MSWINDOWS}
  FThreadPriority    := PriorityNormal;
  {$ENDIF}

  // Identification and diagnostics.
  FThreadName := '';
  FThreadId   := -1; // -1 = no user-defined ID.

  {$IFDEF DEBUG}
  FMeasureTime := True;  // Enabled by default in debug builds.
  {$ELSE}
  FMeasureTime := False; // Disabled by default in release builds.
  {$ENDIF}

  // Atomic runtime state.
  FThreadHadErrorInt  := 0;
  FCancelRequested    := 0;
  FRunningInt         := 0;
  FExecutionActiveInt := 0;

  // Thread handle.
  FThread := nil;

  // Completion event — manual reset, initial state signaled (idle).
  FCompletedEvent := TEvent.Create(nil, True, True, '');
end;

destructor TSafeThread4DParams.Destroy;
begin
  FCompletedEvent.Free;
  inherited Destroy;
end;

class function TSafeThread4DParams.New: ISafeThread4DParams;
begin
  Result := TSafeThread4DParams.Create;
end;

// Fluent setters — lifecycle callbacks.

function TSafeThread4DParams.SetOnInitialize(const AProc: TContextCallback): ISafeThread4DParams;
begin
  FOnInitialize := AProc;
  Result := Self;
end;

function TSafeThread4DParams.SetOnInitializeEvent(const AProc: TNotifyEvent): ISafeThread4DParams;
begin
  FOnInitializeEvent := AProc;
  Result := Self;
end;

function TSafeThread4DParams.SetOnExecute(const AProc: TContextCallback): ISafeThread4DParams;
begin
  FOnExecute := AProc;
  Result := Self;
end;

function TSafeThread4DParams.SetOnSuccess(const AProc: TContextCallback): ISafeThread4DParams;
begin
  FOnSuccess := AProc;
  Result := Self;
end;

function TSafeThread4DParams.SetOnComplete(const AProc: TContextCallback): ISafeThread4DParams;
begin
  FOnComplete := AProc;
  Result := Self;
end;

function TSafeThread4DParams.SetOnTerminate(const AProc: TContextCallback): ISafeThread4DParams;
begin
  FOnTerminate := AProc;
  Result := Self;
end;

function TSafeThread4DParams.SetOnTerminateEvent(const AProc: TNotifyEvent): ISafeThread4DParams;
begin
  FOnTerminateEvent := AProc;
  Result := Self;
end;

function TSafeThread4DParams.SetOnError(const AProc: TErrorCallback): ISafeThread4DParams;
begin
  FOnError := AProc;
  Result := Self;
end;

function TSafeThread4DParams.SetOnCancel(const AProc: TContextCallback): ISafeThread4DParams;
begin
  FOnCancel := AProc;
  Result := Self;
end;

// Fluent setters — progress and timeout.

function TSafeThread4DParams.SetOnProgress(const AProc: TProgressCallback): ISafeThread4DParams;
begin
  FOnProgress := AProc;
  Result := Self;
end;

function TSafeThread4DParams.SetProgressIntervalMs(const AIntervalMs: Cardinal): ISafeThread4DParams;
begin
  FProgressIntervalMs := AIntervalMs;
  Result := Self;
end;

function TSafeThread4DParams.SetTimeoutMs(const ATimeoutMs: Cardinal): ISafeThread4DParams;
begin
  FTimeoutMs := ATimeoutMs;
  Result := Self;
end;

function TSafeThread4DParams.SetOnTimeout(const AProc: TContextCallback): ISafeThread4DParams;
begin
  FOnTimeout := AProc;
  Result := Self;
end;

// Fluent setters — heartbeat.

function TSafeThread4DParams.SetHeartbeatIntervalMs(const AIntervalMs: Cardinal): ISafeThread4DParams;
begin
  FHeartbeatIntervalMs := AIntervalMs;
  Result := Self;
end;

function TSafeThread4DParams.SetOnHeartbeat(const AProc: THeartbeatProc): ISafeThread4DParams;
begin
  FOnHeartbeat := AProc;
  Result := Self;
end;

// Fluent setters — flags and configuration.

function TSafeThread4DParams.SetFreeOnTerminate(const AValue: Boolean): ISafeThread4DParams;
begin
  FFreeOnTerminate := AValue;
  Result := Self;
end;

function TSafeThread4DParams.SetCompleteWithError(const AValue: Boolean): ISafeThread4DParams;
begin
  FCompleteWithError := AValue;
  Result := Self;
end;

{$IFDEF MSWINDOWS}
function TSafeThread4DParams.SetThreadPriority(const APriority: TThreadPriority): ISafeThread4DParams;
begin
  FThreadPriority := APriority;
  Result := Self;
end;
{$ENDIF}

// Fluent setters — identification and diagnostics.

function TSafeThread4DParams.SetThreadName(const AName: string): ISafeThread4DParams;
begin
  FThreadName := AName;
  Result := Self;
end;

function TSafeThread4DParams.SetThreadId(const AId: Integer): ISafeThread4DParams;
begin
  FThreadId := AId;
  Result := Self;
end;

function TSafeThread4DParams.SetMeasureTime(const AValue: Boolean): ISafeThread4DParams;
begin
  FMeasureTime := AValue;
  Result := Self;
end;

// Getters — lifecycle callbacks.

function TSafeThread4DParams.GetOnInitialize: TContextCallback;
begin
  Result := FOnInitialize;
end;

function TSafeThread4DParams.GetOnInitializeEvent: TNotifyEvent;
begin
  Result := FOnInitializeEvent;
end;

function TSafeThread4DParams.GetOnExecute: TContextCallback;
begin
  Result := FOnExecute;
end;

function TSafeThread4DParams.GetOnSuccess: TContextCallback;
begin
  Result := FOnSuccess;
end;

function TSafeThread4DParams.GetOnComplete: TContextCallback;
begin
  Result := FOnComplete;
end;

function TSafeThread4DParams.GetOnTerminate: TContextCallback;
begin
  Result := FOnTerminate;
end;

function TSafeThread4DParams.GetOnTerminateEvent: TNotifyEvent;
begin
  Result := FOnTerminateEvent;
end;

function TSafeThread4DParams.GetOnError: TErrorCallback;
begin
  Result := FOnError;
end;

function TSafeThread4DParams.GetOnCancel: TContextCallback;
begin
  Result := FOnCancel;
end;

// Getters — progress and timeout.

function TSafeThread4DParams.GetOnProgress: TProgressCallback;
begin
  Result := FOnProgress;
end;

function TSafeThread4DParams.GetProgressIntervalMs: Cardinal;
begin
  Result := FProgressIntervalMs;
end;

function TSafeThread4DParams.GetTimeoutMs: Cardinal;
begin
  Result := FTimeoutMs;
end;

function TSafeThread4DParams.GetOnTimeout: TContextCallback;
begin
  Result := FOnTimeout;
end;

// Getters — heartbeat.

function TSafeThread4DParams.GetHeartbeatIntervalMs: Cardinal;
begin
  Result := FHeartbeatIntervalMs;
end;

function TSafeThread4DParams.GetOnHeartbeat: THeartbeatProc;
begin
  Result := FOnHeartbeat;
end;

// Getters — flags and configuration.

function TSafeThread4DParams.GetCompleteWithError: Boolean;
begin
  Result := FCompleteWithError;
end;

function TSafeThread4DParams.GetFreeOnTerminate: Boolean;
begin
  Result := FFreeOnTerminate;
end;

{$IFDEF MSWINDOWS}
function TSafeThread4DParams.GetThreadPriority: TThreadPriority;
begin
  Result := FThreadPriority;
end;
{$ENDIF}

// Getters — identification and diagnostics.

function TSafeThread4DParams.GetThreadName: string;
begin
  Result := FThreadName;
end;

function TSafeThread4DParams.GetThreadId: Integer;
begin
  Result := FThreadId;
end;

function TSafeThread4DParams.GetMeasureTime: Boolean;
begin
  Result := FMeasureTime;
end;

// Runtime state — atomic.

function TSafeThread4DParams.GetThreadHadError: Boolean;
begin
  Result := TInterlocked.CompareExchange(FThreadHadErrorInt, 0, 0) = 1;
end;

procedure TSafeThread4DParams.SetThreadHadError(const AValue: Boolean);
begin
  TInterlocked.Exchange(FThreadHadErrorInt, Ord(AValue));
end;

function TSafeThread4DParams.GetCancelRequested: Boolean;
begin
  Result := TInterlocked.CompareExchange(FCancelRequested, 0, 0) = 1;
end;

procedure TSafeThread4DParams.RequestCancel;
begin
  TInterlocked.Exchange(FCancelRequested, 1);
end;

// Thread handle and status.

function TSafeThread4DParams.GetThread: TThread;
begin
  Result := AtomicGetThread;
end;

function TSafeThread4DParams.IsRunning: Boolean;
begin
  Result := TInterlocked.CompareExchange(FRunningInt, 0, 0) = 1;
end;

{===================}
{== TSafeThread4D ==}
{===================}

class function TSafeThread4D.StartThread(const AParams: ISafeThread4DParams): TThread;
var
  LThread: TThread;
  LOnInitialize, LOnExecute, LOnSuccess, LOnComplete, LOnTerminate: TContextCallback;
  LOnCancel: TContextCallback;
  LOnError: TErrorCallback;
  LOnInitializeEvent, LOnTerminateEvent: TNotifyEvent;
  LOnTimeout: TContextCallback;
  LOnProgress: TProgressCallback;
  LContext: TThreadContext;
  LStopwatch: TStopwatch;
  LHeartbeatInterval: Cardinal;
  LHeartbeatProc: THeartbeatProc;
  LStopEvent: TEvent; // Signals the end of the worker to close the heartbeat watchdog.
  LParamsObj: TObject;
  LParamsCore: TSafeThread4DParams;
  LProxy: TTerminateProxy;
begin
  if not Assigned(AParams) then
    raise Exception.Create('TSafeThread4D: Params parameter cannot be nil.');

  LParamsObj := AParams as TObject;
  if not (LParamsObj is TSafeThread4DParams) then
    raise Exception.Create('TSafeThread4D: Params must be created by TSafeThread4DParams.New.');

  LParamsCore := TSafeThread4DParams(LParamsObj);

  // Reject concurrent reuse of the same params instance.
  if TInterlocked.CompareExchange(LParamsCore.FRunningInt, 1, 0) <> 0 then
    raise Exception.Create('TSafeThread4D: This params instance is already running. Create a new params object or wait for completion.');

  LThread := nil;
  LProxy := nil;

  try
    // Reset runtime state for this new execution.
    TInterlocked.Exchange(LParamsCore.FCancelRequested, 0);
    TInterlocked.Exchange(LParamsCore.FThreadHadErrorInt, 0);
    TInterlocked.Exchange(LParamsCore.FExecutionActiveInt, 1);
    TInterlocked.Exchange<TThread>(LParamsCore.FThread, nil);
    LParamsCore.FCompletedEvent.ResetEvent;

    // Pre-context with user-provided data.
    LContext.ThreadName := AParams.GetThreadName;
    LContext.LogicalThreadID := AParams.GetThreadId;
    LContext.NativeThreadID := 0; // Will be filled inside the worker.
    LContext.ThreadHadError := False;
    LContext.ThreadCancel := False;
    LContext.ElapsedMilliseconds := 0;
    LContext.StartTick := 0;

    // Capture callbacks.
    LOnInitialize      := AParams.GetOnInitialize;
    LOnInitializeEvent := AParams.GetOnInitializeEvent;
    LOnExecute         := AParams.GetOnExecute;
    LOnSuccess         := AParams.GetOnSuccess;
    LOnComplete        := AParams.GetOnComplete;
    LOnTerminate       := AParams.GetOnTerminate;
    LOnTerminateEvent  := AParams.GetOnTerminateEvent;
    LOnCancel          := AParams.GetOnCancel;
    LOnError           := AParams.GetOnError;
    LOnTimeout         := AParams.GetOnTimeout;
    LOnProgress        := AParams.GetOnProgress;

    // Heartbeat configuration.
    LHeartbeatInterval := AParams.GetHeartbeatIntervalMs;
    LHeartbeatProc := AParams.GetOnHeartbeat;
    LStopEvent := nil;

    if not Assigned(LOnExecute) then
      raise Exception.Create('TSafeThread4D: OnExecute is required.');

    // If heartbeat is enabled, prepare the stop signal and start the watchdog.
    if LHeartbeatInterval > 0 then
    begin
      try
        LStopEvent := TEvent.Create(nil, True, False, '');
        TThread.CreateAnonymousThread(
          procedure
          var
            LWaitResult: TWaitResult;
          begin
            try
              while True do
              begin
                LWaitResult := LStopEvent.WaitFor(LHeartbeatInterval);
                if LWaitResult = wrSignaled then
                  Break;

                if AParams.GetCancelRequested then
                  Continue;

                // Ping: keeps the UI "breathing" (Android ANR mitigation).
                TThread.Queue(nil,
                  procedure
                  begin
                    if AParams.GetCancelRequested then Exit;
                    if TInterlocked.CompareExchange(LParamsCore.FExecutionActiveInt, 0, 0) = 0 then Exit;
                    if Assigned(LHeartbeatProc) then
                      LHeartbeatProc();
                  end);
              end;
            finally
              LStopEvent.Free; // Watchdog owns the event.
            end;
          end
        ).Start;

      except
        LStopEvent := nil; // Disable heartbeat if creation fails.
      end;
    end;

    LThread := TThread.CreateAnonymousThread(
      procedure
      var
        LDoComplete: Boolean;
        LErrorMessage: string;
        LFinalProgressSent: Boolean;
      begin
        try
          // Reset throttle state per worker execution.
          GLastProgressTick := 0;
          LFinalProgressSent := False;

          // Thread name for debugging (only if provided).
          if Trim(AParams.GetThreadName) <> '' then
          begin
            if AParams.GetThreadId > -1 then
              TThread.NameThreadForDebugging(Format('%s-%d', [AParams.GetThreadName, AParams.GetThreadId]))
            else
              TThread.NameThreadForDebugging(AParams.GetThreadName);
          end;

          // Native OS thread ID and timing base.
          LContext.NativeThreadID := GetNativeThreadIDSafe;
          LContext.ElapsedMilliseconds := 0;
          LContext.StartTick := TickCount64Safe;
          LContext.ThreadCancel := AParams.GetCancelRequested;
          LContext.ThreadHadError := False;

          LDoComplete := not LContext.ThreadCancel;

          try
            // Initialize phase (UI thread).
            if Assigned(LOnInitializeEvent) and not AParams.GetCancelRequested then
              TThread.Synchronize(nil,
                procedure
                begin
                  LOnInitializeEvent(nil);
                end);

            if Assigned(LOnInitialize) and not AParams.GetCancelRequested then
              TThread.Synchronize(nil,
                procedure
                begin
                  LOnInitialize(LContext);
                end);

            // Execute phase (worker thread).
            LContext.ThreadCancel := AParams.GetCancelRequested;
            if not LContext.ThreadCancel then
            begin
              if AParams.GetMeasureTime then
              begin
                LStopwatch := TStopwatch.StartNew;
                try
                  // Tip: within OnExecute, call CheckCancel/CheckTimeout at
                  //      critical points for an immediate response to cancel/timeout.
                  LOnExecute(LContext);
                finally
                  LContext.ElapsedMilliseconds := LStopwatch.ElapsedMilliseconds;
                end;
              end
              else
                LOnExecute(LContext);
            end;

            // Success phase (UI thread).
            if Assigned(LOnSuccess) then
            begin
              LContext.ThreadCancel := AParams.GetCancelRequested;
              if not LContext.ThreadCancel then
              begin
                if Assigned(LOnProgress) and not LFinalProgressSent then
                begin
                  TThread.Synchronize(nil,
                    procedure
                    begin
                      LOnProgress(1.0);
                    end);
                  LFinalProgressSent := True;
                end;

                TThread.Synchronize(nil,
                  procedure
                  begin
                    LOnSuccess(LContext);
                  end);
              end;
            end;

          except
            on E: EOperationCancelled do
            begin
              // Clean exit by cancellation.
              LDoComplete := False;
              LContext.ThreadCancel := True;
            end;

            on E: EOperationTimeout do
            begin
              // Clean exit by timeout (not treated as an error).
              LDoComplete := False;
              if Assigned(LOnTimeout) then
                TThread.Synchronize(nil,
                  procedure
                  begin
                    LOnTimeout(LContext);
                  end);
            end;

            on E: Exception do
            begin
              LDoComplete := AParams.GetCompleteWithError;
              LErrorMessage := E.Message;

              LContext.ThreadHadError := True;
              AParams.SetThreadHadError(True);

              if Assigned(LOnError) then
                TThread.Synchronize(nil,
                  procedure
                  begin
                    LOnError(LErrorMessage, LContext);
                  end);
            end;
          end;

          // Cancel callback (worker -> UI). Cancel observation is independent
          // of the path: even on success/timeout/error, if a cancel was
          // requested concurrently, OnCancel still fires.
          LContext.ThreadCancel := AParams.GetCancelRequested or LContext.ThreadCancel;
          if LContext.ThreadCancel and Assigned(LOnCancel) then
            TThread.Synchronize(nil,
              procedure
              begin
                LOnCancel(LContext);
              end);

          // Complete phase (UI thread).
          if LDoComplete and (not LContext.ThreadCancel) and Assigned(LOnComplete) then
          begin
            if Assigned(LOnProgress) and not LFinalProgressSent then
            begin
              TThread.Synchronize(nil,
                procedure
                begin
                  LOnProgress(1.0);
                end);
              LFinalProgressSent := True;
            end;

            TThread.Synchronize(nil,
              procedure
              begin
                LOnComplete(LContext);
              end);
          end;

          // Terminate phase (UI thread).
          if Assigned(LOnTerminate) then
            TThread.Synchronize(nil,
              procedure
              begin
                LOnTerminate(LContext);
              end);
        finally
          // Shutdown order is critical: clear FExecutionActiveInt first so
          // any already-queued heartbeat ping self-aborts when it runs,
          // then signal the heartbeat watchdog to close.
          TInterlocked.Exchange(LParamsCore.FExecutionActiveInt, 0);

          if Assigned(LStopEvent) then
            LStopEvent.SetEvent;
        end;
      end);

    {$IFDEF MSWINDOWS}
    LThread.Priority := AParams.GetThreadPriority;
    {$ENDIF}
    LThread.FreeOnTerminate := AParams.GetFreeOnTerminate;

    // Store thread reference in params for tracking.
    TInterlocked.Exchange<TThread>(LParamsCore.FThread, LThread);

    // Chain OnTerminate via proxy (clears FThread, signals completion,
    // and forwards the user event).
    LProxy := TTerminateProxy.Create(AParams, LOnTerminateEvent);
    try
      LThread.OnTerminate := LProxy.HandleTerminate;
      LThread.Start;
    except
      // Startup failed before the proxy could self-destruct through OnTerminate.
      LThread.OnTerminate := nil;
      LProxy.Free;
      LProxy := nil;

      // Retract the published thread handle immediately.
      TInterlocked.Exchange<TThread>(LParamsCore.FThread, nil);

      // If the heartbeat watchdog is already alive, signal it to stop.
      if Assigned(LStopEvent) then
      begin
        LStopEvent.SetEvent;
        LStopEvent := nil; // Ownership is already with the watchdog thread.
      end;

      // The worker thread object never started, so it must be freed here.
      LThread.Free;
      LThread := nil;
      raise;
    end;

    Result := LThread;
  except
    // Publication path for startup failure — ensures any concurrent
    // CancelAndWait is unblocked before the exception propagates.
    TInterlocked.Exchange<TThread>(LParamsCore.FThread, nil);
    TInterlocked.Exchange(LParamsCore.FExecutionActiveInt, 0);
    TInterlocked.Exchange(LParamsCore.FRunningInt, 0);
    LParamsCore.FCompletedEvent.SetEvent;

    // Best-effort heartbeat shutdown if startup failed after the watchdog was created.
    if Assigned(LStopEvent) then
      LStopEvent.SetEvent;

    raise;
  end;
end;

class procedure TSafeThread4D.ExecuteThread(const AParams: ISafeThread4DParams);
begin
  // Compatibility shim: just starts and ignores the handle.
  StartThread(AParams);
end;

class procedure TSafeThread4D.StartThreadWithWeakRef(const AParams: ISafeThread4DParams; out AWeakRef: Pointer; var AStrongRef: ISafeThread4DParams);
// Encapsulated weak+strong startup pattern to avoid closure retain cycles.
begin
  if not Assigned(AParams) then
    raise Exception.Create('TSafeThread4D: Params parameter cannot be nil.');

  // Weak + Strong canonical pattern.
  AWeakRef   := Pointer(AParams); // Weak — no AddRef, avoids circular reference.
  AStrongRef := AParams;          // Strong — maintains object lifetime and allows UI cancel.
  ExecuteThread(AParams);         // Start thread. Cleanup in OnTerminate (caller should clear AStrongRef).
end;

class procedure TSafeThread4D.StartThreadWithWeakRef(const AParams: ISafeThread4DParams; var AStrongRef: ISafeThread4DParams);
var
  LWeakRef: Pointer;
begin
  StartThreadWithWeakRef(AParams, LWeakRef, AStrongRef);
end;

class procedure TSafeThread4D.CheckCancel(const AParams: ISafeThread4DParams; var AContext: TThreadContext);
begin
  AContext.ThreadCancel := AParams.GetCancelRequested;
  if AContext.ThreadCancel then
    raise EOperationCancelled.Create('Operation cancelled.');
end;

class procedure TSafeThread4D.CheckTimeout(const AParams: ISafeThread4DParams; var AContext: TThreadContext);
var
  LTimeoutMs: Cardinal;
  LNowTick: UInt64;
begin
  LTimeoutMs := AParams.GetTimeoutMs;
  if LTimeoutMs = 0 then Exit; // No timeout configured.

  LNowTick := TickCount64Safe;
  if (LNowTick - AContext.StartTick) >= LTimeoutMs then
    raise EOperationTimeout.Create('Operation timed out.');
end;

class procedure TSafeThread4D.ReportProgress(const AParams: ISafeThread4DParams; const AProgress: Single; const AForce: Boolean);
var
  LNowTick: UInt64;
  LProgress: Single;
  LOnProgress: TProgressCallback;
begin
  if not Assigned(AParams) then Exit;

  LOnProgress := AParams.GetOnProgress;
  if not Assigned(LOnProgress) then Exit;

  // Clamp progress to the valid range [0..1].
  if AProgress < 0 then LProgress := 0
  else if AProgress > 1 then LProgress := 1
  else LProgress := AProgress;

  // If AForce=True, bypass throttling and dispatch immediately.
  // Queue is preserved here because ReportProgress is a general-purpose
  // helper that may be called from multiple contexts. Ordered final 100%
  // dispatches are handled explicitly inside StartThread before OnSuccess
  // and OnComplete.
  if AForce then
  begin
    TThread.Queue(nil,
      procedure
      begin
        LOnProgress(LProgress);
      end);
    Exit;
  end;

  // Normal throttled progress reporting.
  LNowTick := TickCount64Safe;

  // First progress update is always immediate.
  if GLastProgressTick = 0 then
  begin
    GLastProgressTick := LNowTick;
    TThread.Queue(nil,
      procedure
      begin
        LOnProgress(LProgress);
      end);
    Exit;
  end;

  // Dispatch only if enough time has elapsed since the last update.
  if (LNowTick - GLastProgressTick) >= AParams.GetProgressIntervalMs then
  begin
    GLastProgressTick := LNowTick;
    TThread.Queue(nil,
      procedure
      begin
        LOnProgress(LProgress);
      end);
  end;
end;

class procedure TSafeThread4D.WaitFor(const AThread: TThread);
begin
  raise Exception.Create('TSafeThread4D: WaitFor(Thread) is intentionally disabled because a raw TThread handle cannot be validated safely. Use CancelAndWait(Params), Params.IsRunning, or keep FreeOnTerminate=False and manage the thread handle yourself.');
end;

class function TSafeThread4D.IsThreadRunning(const AThread: TThread): Boolean;
begin
  raise Exception.Create('TSafeThread4D: IsThreadRunning(Thread) is intentionally disabled because a raw TThread handle cannot be validated safely. Use IsThreadRunning(Params) or Params.IsRunning instead.');
end;

class function TSafeThread4D.IsThreadRunning(const AParams: ISafeThread4DParams): Boolean;
begin
  if not Assigned(AParams) then
    Exit(False);

  Result := AParams.IsRunning;
end;

class procedure TSafeThread4D.Cancel(const AParams: ISafeThread4DParams);
begin
  if Assigned(AParams) then
    AParams.RequestCancel;
end;

class procedure TSafeThread4D.CancelAndWait(const AParams: ISafeThread4DParams);
var
  LParamsObj: TObject;
  LParamsCore: TSafeThread4DParams;
begin
  if not Assigned(AParams) then
    Exit;

  if IsMainThreadSafe then
    raise Exception.Create('TSafeThread4D: CancelAndWait cannot be called on the main thread because synchronized callbacks may deadlock.');

  // Signal cancellation first.
  AParams.RequestCancel;

  LParamsObj := AParams as TObject;
  if not (LParamsObj is TSafeThread4DParams) then
    raise Exception.Create('TSafeThread4D: CancelAndWait requires params created by TSafeThread4DParams.New.');

  LParamsCore := TSafeThread4DParams(LParamsObj);

  // Safe wait, independent of TThread.FreeOnTerminate.
  LParamsCore.FCompletedEvent.WaitFor(High(Cardinal));
end;

end.
