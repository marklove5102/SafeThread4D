# From `Button1Click` to SafeThread4D

### A guide through threading concepts in Delphi, from the real problem to the mechanism that solves it

---

If you have ever written something in Delphi that made a button turn white, the cursor switch to an hourglass, and the user keep clicking because they thought the application had frozen, this text is for you.

The good news is that a solution exists. The less comfortable news is that the solution involves learning a few concepts that, at first glance, seem like theory far removed from practice: *threads, synchronization, memory ordering, atomic operations, events, heartbeat, cooperative cancellation*. The approach here is to follow the natural path: start from the real pain, show how it appears in code, and only then introduce the concept that solves that specific problem.

By the end, the goal is for you to understand not only **how** to use threads in Delphi, but **why** each piece exists. As a practical culmination, you will see **SafeThread4D**, a mechanism that consolidates these decisions into an API that is small on the surface but dense underneath.

---

## Part 1 — Why threads exist

Imagine a screen with two buttons: **Download** and **Upload**.
The user clicks **Download**. The operation starts.
Before it finishes, they try to click **Upload**. It does not respond.
They try to move the window, click again, interact with the screen — and the interface no longer responds as it should.

**This does not happen because the button's code is "extensive".**
It happens because the *main thread* has been busy for too long.

In Delphi, the *main thread* — also called the *primary thread* or *UI thread* — is responsible for drawing the interface, receiving clicks, processing events, updating controls, and executing the code behind your visual controls.

If a blocking operation runs on it, the entire interface has to wait.

And there is an important detail here: **you do not always realize in advance that an operation will take time**.
Sometimes the method looks small. Sometimes the file to download is small. Sometimes your connection seems fast. Sometimes the rendering looks simple.
But the delay may be elsewhere: the server may be slow to respond, the network may have high latency, the database may be slow, or some external dependency may simply not return control quickly.

Consider this seemingly innocent example:

```delphi
procedure TForm1.btDownloadClick(Sender: TObject);
var
  LHttp: THTTPClient;
  LStream: TMemoryStream;
begin
  LHttp := THTTPClient.Create;
  LStream := TMemoryStream.Create;
  try
    LHttp.Get('https://example.com/image.jpg', LStream);
    Image1.Bitmap.LoadFromStream(LStream);
  finally
    LStream.Free;
    LHttp.Free;
  end;
end;
```

The central point is this:

> **it does not matter whether the method has 3 lines or 300.**
> If it holds the main thread for too long, the interface stops responding as it should.

The idea behind **threading** is precisely to move this kind of potentially slow operation to another line of execution.

> A **thread** is an independent line of execution within the same process.
> While the main thread handles the interface, another thread can download files, read from the database, process data, serialize content, or execute any blocking operation without freezing the UI.

The intuition is simple. The problems begin when we try to do this incorrectly.

---

## Part 2 — Creating your first thread

In Delphi, the most direct way to create a thread is with `TThread.CreateAnonymousThread`:

```delphi
procedure TForm1.btDownloadClick(Sender: TObject);
begin
  TThread.CreateAnonymousThread(
    procedure
    var
      LHttp: THTTPClient;
      LStream: TMemoryStream;
    begin
      LHttp := THTTPClient.Create;
      LStream := TMemoryStream.Create;
      try
        LHttp.Get('https://example.com/image.jpg', LStream);
        Image1.Bitmap.LoadFromStream(LStream); // ← the problem is here
      finally
        LStream.Free;
        LHttp.Free;
      end;
    end
  ).Start;
end;
```

### Note — What is this `procedure` inside `CreateAnonymousThread`?

If you have never seen this construct before, it may look strange to have a `procedure` declared **inside** a method call. It has a name: an **anonymous method** (or *closure*).

An anonymous method is a block of code that can be **passed as a parameter**, as if it were an ordinary value. It has no name — hence "anonymous".

What makes it special is that it **remembers the variables from the scope where it was created**. That is, variables declared in the method containing the closure remain accessible **from within** it, even when the closure runs later, in a different context — including a different thread.

In the example above, the `procedure` passed to `CreateAnonymousThread` is an anonymous method. When `Start` is called, the thread executes that block of code in the background. This idea appears several times throughout this guide, and it is the mechanism through which the SafeThread4D API receives its lifecycle callbacks (`OnExecute`, `OnSuccess`, `OnError`, etc.).

---

You run it. The screen **no longer freezes** during the download. It looks like it worked.

But the program may start behaving oddly: corrupted images, intermittent crashes, failures that do not always appear — sometimes only on the client's machine.

The reason is important:

> **Visual components belong to the main thread.**
> In Delphi, you should not touch `TLabel`, `TButton`, `TImage`, `TGrid`, `TMemo`, `TListView`, or any other visual control from a worker thread.

The golden rule is this:

> **The UI can only be manipulated by the main thread.**

This solves one of the problems. But as soon as we start placing work in parallel, another kind of concern arises.

---

## Part 3 — When a thread solves one problem, another appears

Once you move an operation to a worker thread, the interface no longer freezes. Good.

But now there is a new reality: **two lines of execution coexist** within the same process.

- the **main thread** remains responsible for the interface;
- the **worker thread** now handles the slow work.

At first, this seems simple. But a new kind of question quickly appears:

> **how do two different threads share or publish state correctly?**

Even before we get to the classic race condition case, there is already a practical concern: one thread produces information, and the other needs to reflect that information in the UI.

For example: a worker thread may be downloading a series of images, and the interface may want to show how many have already finished. The worker advances; the interface needs to keep up.

This is where concepts such as **state publication**, **UI synchronization**, and **coordination between threads** begin to matter.

But the classic race condition is easier to see in an even simpler example: several threads modifying the same counter.

---

## Part 4 — Race conditions: when several threads modify the same state

A **race condition** occurs when the correct result depends on the exact order in which several threads execute — and that order is unpredictable.

A classic example is a shared counter.

### Incorrect example: several threads incrementing a shared counter

```delphi
var
  GCounter: Integer;

procedure TForm1.Button1Click(Sender: TObject);
var
  I: Integer;
begin
  GCounter := 0;

  for I := 1 to 10 do
    TThread.CreateAnonymousThread(
      procedure
      var
        J: Integer;
      begin
        for J := 1 to 100000 do
          Inc(GCounter);
      end
    ).Start;

  Sleep(2000); // illustrative only — see the note at the end of this section
  ShowMessage('Counter = ' + IntToStr(GCounter));
end;
```

Note that the `for` loop launches 10 threads. At first glance, the result should always be **1,000,000**.

But it is not. Depending on execution, you may get smaller numbers.
The reason is that `Inc(GCounter)` **is not an atomic operation**. Underneath, it involves read, add, and write. If several threads do this simultaneously, one update may overwrite another.

Another point worth emphasizing: a thread created when `I = 9` may very well begin executing before any of the previous ones. The actual order of execution is decided by the operating system, not by the order of creation. In this particular scenario, it is unpredictable.

This is exactly what characterizes a race condition:

> **two or more threads modify the same state, but without proper synchronization.**

### Correct example: the same scenario, but with an atomic operation

Now see the same example, handling the counter correctly. `GCounter` is the same global variable as before; the only difference is how it is incremented:

```delphi
uses
  System.SyncObjs;

procedure TForm1.Button2Click(Sender: TObject);
var
  I: Integer;
begin
  GCounter := 0;

  for I := 1 to 10 do
    TThread.CreateAnonymousThread(
      procedure
      var
        J: Integer;
      begin
        for J := 1 to 100000 do
          TInterlocked.Increment(GCounter);
      end
    ).Start;

  Sleep(2000); // illustrative only — see the note at the end of this section
  ShowMessage('Counter = ' + IntToStr(GCounter));
end;
```

The difference here is in a single line:

```delphi
TInterlocked.Increment(GCounter);
```

The increment is now **atomic** from a concurrency standpoint.
The threads still execute in parallel, but the counter update is no longer vulnerable to the incorrect interleaving of read, add, and write.

> **Note:** `TInterlocked` will be formally introduced in Part 7. For now, it is enough to know that this is the correct way to increment an integer shared between threads.

### What this contrast teaches

Both buttons do essentially the same thing:

- they create several threads;
- each thread performs many increments;
- at the end, the program displays the counter value.

But there is one essential difference:

- in the first button, the counter is modified naively;
- in the second, it is modified with an atomic operation.

This contrast reveals a central point:

> **the problem is not simply "using multiple threads".**
> The problem is **using multiple threads on the same state without proper coordination**.

### Where this pattern appears in practice

Although this example uses a simple counter, the idea behind it appears frequently in real software.

This kind of shared state is common when tracking, for instance:

- how many downloads have already finished;
- how many records have already been processed;
- how many tasks are still running;
- how many items failed;
- how many workers remain active.

In many cases, these numbers end up being shown in the interface: labels, progress bars, grids, status lists, visual indicators, and other main-thread elements.

That is precisely where care must increase:

- the state shared between threads must be updated correctly;
- and the interface must be updated in the correct context — that is, by the main thread.

In other words: the counter in this example is small, but the pattern it represents is extremely common in real-world scenarios.

### How far this example goes

The counter example was chosen because it makes the error easy to see. It is a good entry point for understanding race conditions and the usefulness of atomic operations such as `TInterlocked`.

But concurrency issues are not limited to numeric variables. More complex shared state — such as messages, lists, objects, collections, or combinations of values used by the interface — may require other forms of coordination, such as well-defined ownership, explicit publication, `TMonitor`, `TCriticalSection`, or equivalent strategies.

These cases exist and matter, but they would expand the scope of this text considerably. Here, the goal is to build the right intuition without turning the guide into a full treatise on synchronization.

That deeper treatment can be addressed in a future continuation.

### Important note

In both examples, `Sleep(2000)` was kept only to simplify the demonstration.

Because it is inside `Button1Click` / `Button2Click`, it runs on the **main thread** and therefore freezes the interface temporarily.

In real code, waiting for threads to finish with `Sleep` is not the correct approach.
Later we will see appropriate mechanisms for termination coordination, such as `TEvent`, and, in the case of SafeThread4D, the role of `FCompletedEvent` and `CancelAndWait`.

---

## Part 5 — The memory model of modern processors

The natural intuition is to think: "line 1, then line 2, then line 3".

In practice, modern processors do two things for performance:

1. **Instruction reordering**: if an operation does not depend on the previous one, the CPU may execute it in a different order.
2. **Per-core caches**: a write may become temporarily visible only to one core, while another core still sees the old value.

From the perspective of your own thread, everything looks consistent. But for another thread running on another core, the order and visibility of the data may be different.

This is the **memory ordering** problem.

A useful intuition to keep in mind:

> **Each thread has its own momentary view of shared memory.**
> That memory only starts behaving as truly shared once proper synchronization is in place.

That is why a simple `Counter := Counter + 1` is not safe across threads. It is also why even `while not Finished do Sleep(10)` may be inadequate if that flag is not being published correctly.

Now that the problems have been laid out, let us move on to the tools.

---

## Part 6 — `Synchronize` and `Queue`: how to communicate with the main thread

Back to the UI problem: if the worker thread cannot touch the interface directly, how does it request the interface to be updated?

Delphi offers two central mechanisms for this: `Synchronize` and `Queue`.

### `TThread.Synchronize`

```delphi
TThread.Synchronize(nil,
  procedure
  begin
    Image1.Bitmap.LoadFromStream(LStream);
    Label1.Text := 'Done';
  end
);
```

The worker thread asks the main thread to execute that code **and waits** until it happens.

This is a **synchronous** call.

### `TThread.Queue`

```delphi
TThread.Queue(nil,
  procedure
  begin
    Label1.Text := 'Progress: 45%';
  end
);
```

Here the worker thread simply **enqueues** a request for the main thread and continues. The visual execution happens later, when the main thread processes the queue.

This is an **asynchronous** call.

### Practical intuition

- Use **`Synchronize`** when the logic that follows depends on the UI already having been updated.
- Use **`Queue`** when you just want to notify the UI and move on.

Short rule:

> **`Synchronize` waits. `Queue` publishes.**

### Important — common pitfalls

`Synchronize` is meant to be called **from a worker thread**, asking the main thread to run UI code.

Two patterns to avoid:

- **Calling `Synchronize` from the main thread itself.** The main thread cannot wait for itself. Depending on context, this can deadlock or behave unpredictably.
- **Nesting `Synchronize` inside another `Synchronize`.** The outer call is already running on the main thread; the inner call would ask the main thread to wait for itself. Same kind of trap.

The mental model is simple: `Synchronize` is a bridge **from worker to UI**. It is not meant to be called when you are already on the UI side. SafeThread4D's `CancelAndWait`, for instance, explicitly rejects being called from the main thread for exactly this reason.

This solves communication with the interface. But we still need to address safe sharing of state between threads.

---

## Part 7 — Atomic operations

Back to the counter from Part 4: the correct way to increment it across threads is to use an atomic operation.

In Delphi, this means using `TInterlocked`:

```delphi
uses
  System.SyncObjs;

var
  GCounter: Integer;

begin
  GCounter := 0;
  TInterlocked.Increment(GCounter);
end;
```

The increment is now indivisible from a concurrency standpoint, and the value is correctly published to the other threads.

`TInterlocked` offers an essential set of operations:

- `Increment`
- `Decrement`
- `Add`
- `Exchange`
- `CompareExchange`

> **Whenever a variable is shared between threads, assume it needs atomic access.**

In SafeThread4D, this pattern appears throughout:

- `FRunningInt`
- `FExecutionActiveInt`
- `FCancelRequested`
- `FThreadHadErrorInt`

They all look like simple integers, but they are manipulated via `TInterlocked`. This is not overkill — it is the correct way to publish concurrent state.

---

## Part 8 — `TEvent`: waiting without polling or wasting CPU

Now suppose one thread needs to wait for another to finish.

The wrong solution is this:

```delphi
while not Finished do
  Sleep(10);
```

This is bad for three reasons:

1. the flag may not be published correctly;
2. you are doing unnecessary polling;
3. if this happens on the main thread, the UI freezes again.

The correct tool is `TEvent`.

```delphi
uses
  System.SyncObjs;

var
  FReadyEvent: TEvent;

begin
  FReadyEvent := TEvent.Create(nil, True, False, '');
end;
```

One thread does:

```delphi
FReadyEvent.SetEvent;
```

Another does:

```delphi
FReadyEvent.WaitFor(INFINITE);
```

While the event is not signaled, the waiting thread is genuinely blocked — no polling, no unnecessary CPU consumption.

> **`TEvent` is the correct mechanism for wait coordination between threads.**

In SafeThread4D, this appears as `FCompletedEvent`, which is the basis of `CancelAndWait`.

---

## Part 9 — Cooperative cancellation

Now imagine this scenario: the user started the download and then clicked "Cancel".

The worst idea would be to "kill" the thread abruptly. A thread may be:

- in the middle of a write;
- holding a resource;
- in the middle of a structural change;
- inside a `finally` block that still needs to run.

That is why the modern model is **cooperative cancellation**.

The idea is simple:

- the main thread **signals** that it wants to cancel;
- the worker thread, at strategic points, **checks** that signal;
- if cancellation has been requested, the worker exits cleanly.

Conceptual example:

```delphi
var
  FCancelled: Integer;

procedure TForm1.btCancelClick(Sender: TObject);
begin
  TInterlocked.Exchange(FCancelled, 1);
end;
```

In the worker thread:

```delphi
if TInterlocked.CompareExchange(FCancelled, 0, 0) = 1 then
  Exit;
```

If the snippet above looks unusual, here is what it does: `CompareExchange(x, 0, 0)` is the standard Delphi idiom for **reading an `Integer` atomically**. It compares `x` with `0`, replaces it with `0` if equal (a no-op in practice), and returns the previous value. The net effect is "read the current value of `x` with full memory ordering guarantees". On Delphi versions where it is available, `TInterlocked.Read` does the same thing more directly.

In SafeThread4D, this becomes something cleaner:

```delphi
TSafeThread4D.CheckCancel(Params, Context);
```

If cancellation has been requested, the mechanism raises a specific exception (`EOperationCancelled`), and execution exits while still running every necessary `finally` block.

> **Cooperative cancellation does not yank the thread away by force. It lets the thread terminate cleanly.**

---

## Part 10 — ANR on Android and the heartbeat idea

If you also develop for Android, there is an additional concern: the operating system monitors UI responsiveness.

Android itself has a mechanism called a **watchdog** — literally, a "guard dog". It is an operating system component that observes the application's main thread. If the main thread goes too long without showing enough activity, the watchdog concludes the application has frozen and displays the well-known ANR (*Application Not Responding*) dialog, with the option to close the app.

Even when the heavy work is off the main thread, there are still scenarios where the UI may become "too quiet" for the watchdog, especially in long operations with sparse synchronization points.

A practical strategy for this is the **heartbeat**:

> an auxiliary thread that, at regular intervals, publishes a small "pulse" on the main thread to show that the interface is still alive.

Conceptual example:

```delphi
// Conceptual pseudocode
while FStopEvent.WaitFor(500) <> wrSignaled do
begin
  TThread.Queue(nil,
    procedure
    begin
      // Small UI pulse
    end);
end;

// Elsewhere:
FStopEvent.SetEvent;
```

The idea seems simple. Implementing it correctly is not.

The real difficulties are:

- stopping the heartbeat at the right time;
- not leaving residual pings after the task ends;
- avoiding callbacks into a dead UI;
- getting the shutdown order right.

This is exactly why SafeThread4D treats heartbeat as part of the mechanism, rather than as an improvised detail in each project.

---

### Note — Strong and weak references in Delphi

Before moving on to Part 11, it is worth pausing to understand a concept that appears in the next example: the **strong reference / weak reference** pair.

In Delphi, when you work with **interfaces** (such as `ISafeThread4DParams`), the underlying object uses **reference counting**. Each time someone stores the interface in a variable, an internal counter goes up. When the variable goes out of scope or is cleared, the counter goes down. When it reaches zero, the object is released automatically.

A **strong reference** is the ordinary, everyday variable:

```delphi
var
  LParams: ISafeThread4DParams; // strong reference
begin
  LParams := TSafeThread4DParams.New; // counter rises to 1
end; // LParams goes out of scope, counter returns to 0, object is released
```

A **weak reference** is a copy of the object's address that **does not** participate in the count. In Delphi, the common idiom is to convert the interface to `Pointer`, which does not call `AddRef`:

```delphi
var
  LWeakRef: Pointer;
begin
  LWeakRef := Pointer(LParams); // does not increment the counter
end;
```

Why does this matter? Because there is a trap called a **retain cycle**: if an object holds a strong reference to an anonymous method, and that anonymous method, in turn, captures the same object strongly, the two end up keeping each other alive forever. Neither is released, even when nobody else needs them.

The **weak + strong** pattern solves this:

- a variable outside the closure holds the **strong** reference (and controls the lifetime);
- inside the closure, only a **weak** reference is captured (a `Pointer`), to be reconverted into a typed interface when needed.

SafeThread4D exposes this pattern explicitly through `StartThreadWithWeakRef`, precisely so that `OnExecute` callbacks can query their own `Params` (for instance, to call `CheckCancel`) without creating a retain cycle. This is the pattern shown in the Part 11 example.

---

## Part 11 — SafeThread4D: the concepts in a cohesive package

Let us return to the download from Part 1, now written with SafeThread4D, faithful to the current design.

The example below assumes the form has two private fields: `FDownloadedStream: TMemoryStream` (to hand the downloaded payload from the worker to the UI) and `FParams: ISafeThread4DParams` (the strong reference used for cancellation and observation).

```delphi
uses
  System.Net.HttpClient,
  System.Classes,
  System.SysUtils,
  SafeThread4D;

procedure TForm1.btDownloadClick(Sender: TObject);
var
  LParams: ISafeThread4DParams;
  LWeakRef: Pointer;
begin
  LParams := TSafeThread4DParams.New
    .SetThreadName('ImageDownload')
    .SetOnExecute(
      procedure(AContext: TThreadContext)
      var
        LHttp: THTTPClient;
        LStream: TMemoryStream;
        LP: ISafeThread4DParams;
      begin
        LP := ISafeThread4DParams(IInterface(LWeakRef));
        if LP = nil then
          raise Exception.Create('Internal error: WeakRef not initialized.');

        LHttp := THTTPClient.Create;
        LStream := TMemoryStream.Create;
        try
          TSafeThread4D.CheckCancel(LP, AContext);

          LHttp.Get('https://example.com/large-image.jpg', LStream);

          TSafeThread4D.CheckCancel(LP, AContext);

          LStream.Position := 0;

          // FDownloadedStream is not a visual control, so transferring
          // ownership of the stream here does not violate the UI-thread rule.
          // Even so, it remains shared state and must be handled under
          // a clear ownership contract between the worker and the UI.
          FDownloadedStream := LStream;
          LStream := nil; // transfer ownership
        finally
          LStream.Free;
          LHttp.Free;
        end;
      end
    )
    .SetOnSuccess(
      procedure(AContext: TThreadContext)
      begin
        if Assigned(FDownloadedStream) then
        begin
          FDownloadedStream.Position := 0;
          Image1.Bitmap.LoadFromStream(FDownloadedStream);
          FreeAndNil(FDownloadedStream);
        end;
        Label1.Text := 'Download completed';
      end
    )
    .SetOnError(
      procedure(const AErrorMessage: string; const AContext: TThreadContext)
      begin
        FreeAndNil(FDownloadedStream);
        Label1.Text := 'Error: ' + AErrorMessage;
      end
    )
    .SetOnCancel(
      procedure(AContext: TThreadContext)
      begin
        FreeAndNil(FDownloadedStream);
        Label1.Text := 'Cancelled by user';
      end
    )
    .SetHeartbeatIntervalMs(500)
    .SetOnHeartbeat(
      procedure
      begin
        // Small UI pulse — useful in long-running mobile scenarios
      end
    );

  TSafeThread4D.StartThreadWithWeakRef(LParams, LWeakRef, FParams);
end;

procedure TForm1.btCancelClick(Sender: TObject);
begin
  if Assigned(FParams) then
    TSafeThread4D.Cancel(FParams);
end;
```

### What each piece solves

| Piece                                        | What it solves                                                                       |
| -------------------------------------------- | ------------------------------------------------------------------------------------ |
| `SetOnExecute`                               | Moves potentially slow work off the main thread.                                     |
| `SetOnSuccess`                               | Ensures that UI updates happen on the main thread.                                   |
| `SetOnError`                                 | Centralizes failure handling in a UI-safe context.                                   |
| `SetOnCancel`                                | Provides a clean path for observed cancellation.                                     |
| `CheckCancel`                                | Implements cooperative cancellation.                                                 |
| `SetHeartbeatIntervalMs` + `SetOnHeartbeat`  | Offers optional UI pulses for long-running mobile scenarios.                         |
| Internal `TInterlocked`                      | Ensures safe publication of shared state.                                            |
| Internal `FCompletedEvent`                   | Enables safe waiting via `CancelAndWait`, independent of the `TThread` lifetime.     |
| `StartThreadWithWeakRef`                     | Avoids retain cycles when the callback needs to use its own `Params`.                |

### Important notes about this example

1. **If your `OnExecute` does not need to consult `Params`**, you can use `StartThread(...)` directly and avoid the weak+strong pattern altogether.
2. **If the callback needs to call `CheckCancel`, `CheckTimeout`, or `ReportProgress`**, the `StartThreadWithWeakRef` pattern is the safest way to avoid capturing `Params` strongly.
3. In a real application, the strong reference (`FParams`, in this example) should be released when it is no longer needed — typically in `OnTerminate` or `OnTerminateEvent`.
4. The heartbeat **mitigates ANR scenarios**, but should not be marketed as a "magic guarantee". It exists to keep the UI breathing during real, long-running scenarios, especially on mobile.
5. `OnCancel` does not mean that all structural cleanup has already finished. It means that cancellation was observed and the corresponding UI callback has fired. The final termination publication still passes through the remainder of the lifecycle and through the termination proxy.
6. **`Cancel` only requests cancellation; it does not wait for the worker to finish.** That is intentional — the `btCancelClick` handler runs on the main thread, and the main thread should never block waiting for a worker. If you genuinely need to wait until the worker has finished (for instance, in a custom shutdown sequence run from a background thread), use `TSafeThread4D.CancelAndWait(Params)`. As discussed in Part 8, that wait is built on top of an internal `TEvent`, and the API explicitly rejects being called from the main thread.

SafeThread4D was born from the observation that, in every new project requiring robust threading — progress, cancellation, timeout, heartbeat, correct synchronization, orderly shutdown — the same set of patterns kept being rewritten with small variations and, almost always, with subtle bugs. After encountering these problems repeatedly, the solution was to implement the complete set once, with tests, review, and discipline, and then make it available for reuse.

The result is a mechanism with a small public surface (few public methods) but dense in correct decisions underneath. With about 30 lines of fluent configuration, the developer obtains:

- execution on a separate thread with a predictable lifecycle;
- *throttled* progress, without saturating the main thread queue;
- cooperative cancellation via clean exception handling;
- cooperative timeout with the same mechanics;
- heartbeat with orderly shutdown, without residual pings;
- safe waiting via `CancelAndWait`, using an internal `TEvent`;
- thread naming for debugging;
- atomic flags for all shared state;
- and many additional details the user does not have to manage manually.

---

## Recommended reading

For readers who want to go deeper into the world of threads in Delphi, three works in the field are worth highlighting:

- **Primož Gabrijelčič** — [*Delphi High Performance* (2nd edition)](https://www.amazon.com/dp/1805125877)
- **Dalija Prasnikar** — [*Delphi Thread Safety Patterns*](https://www.amazon.com/dp/B0BJ8BD22J)
- **Cesar Romero Silva** — [*Delphi Multithreading: Threads, Concurrency, Parallelism and Asynchronous Programming*](https://www.amazon.com/dp/6501779057)

---

## Epilogue — Next steps

If you have made it this far, you already have a solid conceptual foundation in threading. And that already carries great value: you know **why** each piece exists.

Natural next steps:

1. **Clone SafeThread4D** and run the examples.
2. **Read the project README**, with more elaborate use cases.
3. **Read the `ARCHITECTURE.md`** if you want to understand the mechanism from the inside.
4. **Read the source code** calmly. The point is not to memorize it, but to recognize the patterns.

And if, at some point, you find your own `Button1Click` with a thread inside, `TInterlocked` scattered through the code, a `TEvent` lost somewhere, and a cancellation flag whose publication you are not sure about, that may be precisely the moment to stop rebuilding the mechanism from scratch in every project.

---

*This text is an introductory conceptual guide. For practical usage and mechanism details, consult the [README.md](../README.md), the architecture document, and the project examples.*