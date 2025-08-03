Temporal (https://temporal.io/) is a durable execution platform.
This is a monorepo for Temporal development.

## System function and architecture

The purpose of Temporal is for users to be able to introduce "durable execution" into their own systems.

A typical codebase that does not use durable execution contains many fallible side-effectful calls performing network I/O, orchestrated via traditional control flow and language concurrency primitives. The authors of the codebase must implement their own retry mechanisms, and handle unexpected process termination by resuming appropriately, which implies that they are somehow managing to durably save state (databases, durable task queues / message buses, etc) at every appropriate point, maintaining consistency between their in-memory and on-disk data. Furthermore they have no simple way to wait for arbitrary durations until arbitrary conditions become true. Implementing such a system correctly is extremely difficult and in practice most such systems are both incorrect and expensive to create and maintain.

Temporal provides SDK libraries supplying primitives that perform all the difficult-to-implement things mentioned above.

A codebase that uses Temporal can be divided into four "code contexts":

-  **"Client code"** - normal application code that possesses an instance of a Temporal gRPC client (e.g. `src/sdk-python/temporalio/client.py`, `src/sdk-go/client/`, `src/sdk-java/temporal-sdk/src/main/java/io/temporal/client/`) that it uses to start and interact with workflows (interactions include cancel, and sending Queries, Signals, and Updates). The client is connected to a specified server namespace and may only interact with workflows in that namespace.

- **Workflows** - a workflow contains a main function that orchestrates invocations of activities, nexus operations, and child workflows, and can wait for arbitrary durations until arbitrary conditions become true, and can signal another workflow in the same namespace. It may also define handlers for Signals, Queries, and Updates. The code must be 100% deterministic (the SDKs supply deterministic versions of PRNGs, UUID generators, hash-map based container data structures, concurrent task schedulers, etc), and in general should not perform any I/O. Each SDK uses a deterministic cooperative multitasking concurrency runtime to execute workflow code. In Go and Java this is a custom scheduler on top of goroutines and threads respectively, in Python it is the asyncio event loop, and in Typescript it is the native event loop.

- **Activities** - an activity is a normal function that can perform I/O and have side effects. It may send heartbeat requests to the server; the heartbeat responses may contain messages such as a cancellation request. It may obtain a Temporal client and act as Client Code.

- **Nexus operations** - a nexus operation is a normal function like an activity that must either return a synchronous result within a short amount of time, or kick off an asynchronous execution (typically a workflow) to handle the task and respond synchronously with an operation token.

The SDKs implement "workers" (e.g. `src/sdk-python/temporalio/worker`, `src/sdk-go/worker/`, `src/sdk-java/temporal-sdk/src/main/java/io/temporal/worker/`) that poll for workflow/activity/nexus tasks and execute them as appropriate for the task type. Users must run Temporal worker processes themselves. A Temporal worker contains a connected instance of the same gRPC client abstraction as is used by the user's Client code.

For Python, Typescript, .NET, and Ruby, all communication between the SDK's gRPC Client and the server occurs via the shared `sdk-core` Rust library, thus for them two sets of protobuf definitions are in use: those for communication between "lang" and sdk-core (`src/sdk-core/sdk-core-protos/protos/local/temporal/sdk/core/`) and those for communication between sdk-core and the server (`src/api`). In contrast, neither Go nor Java use the Rust library and hence they only use the `src/api` protos.


A high-level overview of how Temporal Workflows work internally follows:

1. Whenever the server has reason to know that a certain user Workflow Execution should be able to make progress, it
   dispatches a Workflow Task (WFT) on that task queue. A WFT contains the sequence of History Events from the start of
   the Workflow to the current time (however, (a) see the "sticky" optimization described below and (b) the WFT contains
   the first page of history only; the Worker fetches subsequent pages as necessary). Reasons for dispatching a WFT
   include (a) the Workflow has just started, (b) a Signal or Update has been received targeting that Workflow, or (c)
   an Activity, Nexus Operation, or Child Workflow has made a state transition (e.g. started, failed, or completed) that
   the Workflow must be informed about.

2. The SDK arranges for the Workflow Worker to handle an invocation of a user Workflow by executing one or more
   concurrent tasks in a cooperative and logically single-threaded fashion. One of these tasks    corresponds to the
   workflow main function/method, and there may be others corresponding to child tasks spawned explicitly by user
   workflow code, and Query/Update/Signal handler executions.

3. The Workflow Worker handles the WFT by "replaying" the users Workflow code from the beginning, applying events from
   history to workflow state machines to unblock certain futures that the user code becomes blocked on. Futures that
   user workflow code becomes blocked on can be divided into two categories: (1) waiting for some server-side event to
   occur (e.g. waiting for a timer, waiting for an activity to complete or fail, waiting for a Child Workflow or Nexus
   operation to start, or waiting for a Child Workflow or Nexus operation to complete or fail.) and (2) waiting for some
   local concurrency primitive or using the SDK's API to wait for a boolean condition to become true. Note that user
   workflow code must never attempt to do I/O directly (logging/tracing/metrics are handled by dedicated SDK APIs), so
   it should never become blocked on network requests. History events are used to unblock the category (1) futures;
   category (2) futures must become unblocked in due course  or else the Workflow will fail with a "deadlock" error
   (TMPRL1101).

   Once all history events have been applied, the user workflow code will become blocked on futures that will not be
   resolved in this WFT (we are executing "new code"). In the case of category (1) futures, when the future was created,
   a Command was appended to a list of commands. Once all concurrent tasks related to this Workflow (the main task, any
   spawned child tasks, and any Signal or Update handler executions) have become blocked, the WFT is complete, and the
   Worker sends the list of commands to the server using the RespondWorkflowTaskCompleted gRPC method. The server
   handles that request by (in a single transaction) writing an event to history (TimerStarted, ActivityTaskScheduled
   etc) for each command and recording the WFT as completed.

   The following will cause the WFT *not* to be recorded as completed:
   - The server fails to write an event for some command
   - An unhandled exception / panic occurs during execution of user code (in which case the Worker calls RespondWorkflowTaskFailed)
   - The Worker fails to respond to the WFT within the allotted timeout

   In these cases ("workflow task failure") the WFT will be dispatched again: the default behavior of Temporal is to retry WFTs forever until they
   succeed. Note that this allows users to deploy new Workflow code to fix the issue.

3. In fact, a Workflow Worker may be in "sticky" mode for a certain Workflow Execution, meaning that it is advertising
   to the server that it has the Workflow Execution in memory, with all futures blocked as they were at the end of the
   last WFT. In this case, the server sends only a slice of history corresponding to events that occurred since the last
   RespondWorkflowTaskCompleted was handled (e.g. new Signals and Updates, and new Activity/Nexus Operation / Child
   Workflow started/completed events). If the Workflow Worker indeed has the Workflow Execution in memory then it will
   not perform replay; otherwise, the WFT will fail and the server will send a new WFT in non-sticky mode.

Thus when a user starts a Workflow, what happens is:

1. User application (or Activity, or Nexus Operation) code uses an SDK client connected to a certain namespace to start
   a Workflow on a certain task queue by making a `StartWorkflowExecution` gRPC call (e.g. `ExecuteWorkflow(...)` in Go,
   `client.start_workflow(...)` in Python, etc).
2. The server dispatches a Workflow Task (WFT) on that task queue. A Workflow Task always contains a slice of History
   Events. In this case those events are [WorkflowExecutionStarted, WorkflowTaskScheduled, WorkflowTaskStarted].
3. A Workflow Worker long-poll picks up this WFT. The Workflow Worker handles the WFT by locating the registered
   Workflow corresponding to the workflow type in the WorkflowExecutionStarted event attributes, and invoking its
   main/run method in a new task in the concurrency runtime used by the Workflow Worker for that language, with arguments obtained from the input payload in
   the event attributes (after deserializing and applying the appropriate Data Converter).

The Workflow Worker now executes the first WFT as described above, resulting in a sequence of Commands being sent to the
server and corresponding new events being written to history. Subsequent server-side events trigger the dispatch of the
next WFT, and so on until the Workflow closes (completes successfully, fails, is cancelled, is terminated).


## Repository layout
- `src/api` - gRPC API for communication between `server` and {`sdk-core`, `sdk-go`, `sdk-java`}
- `src/server` - Temporal server
- `src/sdk-core` - Rust library shared by {`sdk-python`, `sdk-typescript`, `sdk-dotnet`, `sdk-ruby`}
- `src/sdk-go` - Temporal Go SDK
- `src/sdk-java` - Temporal Java SDK
- `src/sdk-python` - Temporal Python SDK
- `src/sdk-ruby` - Temporal Ruby SDK
- `src/sdk-typescript` - Temporal Typescript SDK
- `src/samples-go` - Temporal Go SDK samples
- `src/samples-java` - Temporal Java SDK samples
- `src/samples-python` - Temporal Python SDK samples
- `src/samples-python` - Temporal Ruby SDK samples
- `src/samples-typescript` - Temporal Typescript SDK samples
- `src/nexus-sdk-go` - Nexus Go SDK
- `src/nexus-sdk-java` - Nexus Java SDK
- `src/nexus-sdk-python` - Nexus Python SDK
- `src/nexus-sdk-typescript` - Nexus Typescript SDK


