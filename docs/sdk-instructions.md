**Contents**
<small>
- [Execution context categories](#execution-context-categories)
  * [Identifying code context](#identifying-code-context)
    + [Workflow definition](#workflow-definition)
    + [Activity definition](#activity-definition)
    + [Nexus operation code](#nexus-operation-code)
- [How Temporal works](#how-temporal-works)
- [Rules and guidelines for Workflow code](#rules-and-guidelines-for-workflow-code)
- [How to review diffs and PRs](#how-to-review-diffs-and-prs)
- [Rules and guidelines for Activity code](#rules-and-guidelines-for-activity-code)
- [Rules and guidelines for Nexus Operation code](#rules-and-guidelines-for-nexus-operation-code)
- [Rules and guidelines for Client code](#rules-and-guidelines-for-client-code)
- [Reviewing diffs and PRs](#reviewing-diffs-and-prs)
- [Language-specific instructions](#language-specific-instructions)
  * [.NET / C#](#net--c%23)
  * [Go](#go)
    + [Identifying Workflow code](#identifying-workflow-code)
  * [Java](#java)
  * [Python](#python)
  * [Ruby](#ruby)
  * [Typescript](#typescript)
</small>

-----------------------------------------------------------------------------------------------------------------------

This document contains instructions for writing and reviewing code that uses the Temporal SDKs.

External references:

https://docs.temporal.io/<br>
https://github.com/temporalio/sdk-dotnet<br>
https://github.com/temporalio/sdk-go<br>
https://github.com/temporalio/sdk-java<br>
https://github.com/temporalio/sdk-python<br>
https://github.com/temporalio/sdk-ruby<br>
https://github.com/temporalio/sdk-typescript<br>




## Execution context categories

When writing and reviewing code that uses Temporal SDKs you must always understand which of the following execution
context categories applies to the code at hand:

- **Workflow code**: any code in a file that contains a Temporal Workflow definition, or is called transitively from such a file.

- **Activity code**: code in a Temporal Activity definition, and any code called transitively from that context.

- **Nexus operation code**: code in a Nexus Operation definition, and any code called transitively from that context.

- **Normal user application code**: user application code that starts and interacts with Temporal Workflows or creates
  and interacts with Temporal Schedules and is not in one of the above categories.


### Identifying code context

Use any of the following to classify code context:

#### Workflow definition
- A workflow definition annotation/decorator is present on the function/class.
- The function/class is registered with a Worker as an available Workflow.
- The function/class is referenced in a start/execute Workflow/Child Workflow call.
- Uses Workflow-only APIs (e.g. starting/executing Activities/Child Workflows, handling Queries/Updates/Signals,
  waiting on durable timers or condition predicates, accessing Workflow Info). These APIs may not be used outside of Workflow code.

#### Activity definition
- An activity definition annotation/decorator is present on the function/class.
- The function/class is registered with a Worker as an available Activity.
- The function/class is referenced in a start/execute Activity call from Workflow code.
- Uses Activity-only APIs (e.g. heartbeating, accessing Activity Info, accesses a Temporal gRPC Client object)

#### Nexus operation code
- An Nexus Operation definition annotation/decorator is present on the function/class.
- The function/class is referenced as a Nexus Operation in a Nexus Service definition.
- The function/class is referenced in a start/execute Nexus Operation call.
- It uses Nexus Operation-only APIs (e.g. Nexus-specific calls to start Workflows/Activities or send
  Signals/Updates/Queries etc)

If you infer that code context is X and yet you see usage inconsistent with that inference, it should be reported to the
user as a possible error. Likewise, unregistered Workflows/Activities/Nexus Services should be reported.


## How Temporal works
Authoring and advising on Temporal SDK code at an expert level requires some understanding the basics of how Temporal
works internally.

An application using Temporal comprises user code classifiable into the above 4 execution contexts, together with
Temporal workers executing Workflow/Activity/Nexus tasks. These components communicate via gRPC with a certain Namespace
in a Temporal server instance (self-hosted, or a Temporal Cloud cell, or the `temporal server start dev` dev server).

Key methods (unary) of the gRPC service include:
- low-latency calls to start and interact with workflows, that the server responds to immediately, e.g.
  StartWorkflowExecution, RequestCancelWorkflowExecution, SignalWorkflowExecution
- long-polls used by normal application code to wait for results, e.g. GetWorkflowExecutionHistory,
  PollWorkflowExecutionUpdate)
- long-polls used by workers to dequeue tasks on their task queue: e.g. PollWorkflowTaskQueue, PollActivityTaskQueue,
  PollNexusTaskQueue

A Temporal Workflow is a durable execution that typically has only one ultimate purpose: to orchestrate
(start/cancel/wait-for) Activity and Nexus operation executions. A less common use case is purely to store and retrieve
state, for example as a form of distributed lock service.

Workflows make two key guarantees:
1. The activities it invokes are retried according to a retry policy (which defaults to forever with backoff).
2. It doesn’t matter if the process executing the workflow crashes: the workflow will resume from where it left off with
   every local variable in every frame of every stack in precisely the same state.

Thus from the user's point-of-view, their workflow executions are invincible. In particular note that guarantee (2)
implies that workflow code can wait for arbitrarily long periods or until a local condition becomes true, as long as a
worker is running with (a compatible version of) the workflow registered and it's in communication with the server
instance on which the workflow event history is stored.

The programming model is that all this happens without the user needing to think about it: workflow code should
generally be written as if it were normal (non-durable) code, using the concurrency mechanisms offered by that SDK for
use in Workflows (which, in the case of Python, Typescript, C#, and Ruby, are very close to native concurrency APIs of
those languages) and, when communicating with a Temporal user, you should typically not need to talk about internals.
Nevertheles, authoring and advising on Temporal SDK code does require some understanding of internals. For example:
- It is essential that users learn how to avoid causing Non-Determinism Errors (TMPRL1100) when deploying new versions
  of their Workflow code.
- The Workflow Event History is directly exposed to users in the Temporal Web UI.
- Users need to understand that their Workflow code cannot do anything non-deterministic, including that it cannot make
  network calls, and that in some SDK languages sandboxing imposes additional requirements on their workflow code.
- It makes interpreting some stack traces (and even some error messages) easier.

Accordingly, we now provide a high-level overview of how Temporal Workflows work internally, and how they are able to resume
precisely in the case of interruption. This is not a complete description, but you should be able to extrapolate from
this to infer how the remaining functionality works internally.

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
   workflow code, and Query/Update/Signal handler executions. The tasks are implemented using either native concurrency
   mechanisms (Python, Typescript, C#/.NET, and Ruby) or a custom scheduler backed by native threads or goroutines
   (Java, or Go); see [Language-specific instructions](#language-specific-instructions). "Cooperative" means that
   switching between tasks only occurs at certain points: in Python, Typescript, and .NET these points are syntactically
   obvious (they have an await); in Java and Go they occur wherever you call an SDK API to perform an async operation.

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
   - The server fails to write an event for each command
   - An unhandled exception / panic occurs during execution of user code (in which case the Worker calls RespondWorkflowTaskFailed)
   - The Worker fails to respond to the WFT within the allotted timeout

   In these cases the WFT will be dispatched again: the default behavior of Temporal is to retry WFTs forever until they
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
   main/run method in a new task in the concurrency runtime used by the Workflow Worker for that language (see
   [Language-specific instructions](#language-specific-instructions)), with arguments obtained from the input payload in
   the event attributes (after deserializing and applying the appropriate Data Converter).

The Workflow Worker now executes the first WFT as described above, resulting in a sequence of Commands being sent to the
server and corresponding new events being written to history. Subsequent server-side events trigger the dispatch of the
next WFT, and so on until the Workflow closes (completes successfully, fails, is cancelled, is terminated).


Additional notes:
[TODO: expand this section]

- Once history reaches a certain size (see is-continue-as-new-suggested workflow APIs), the Workflow Execution should
  Continue-As-New. This creates a new Workflow Execution with a new RunID, but sharing the same WorkflowID. Thus from
  the users point-of-view a single workflow is in general a chain of workflow runs linked by a shared workflow ID.
- Temporal users use the Temporal web UI to view and debug Workflows. It presents a view of the Workflow as a sequence
  of History events, with detailed event attributes, and error messages / stack traces in the case of activity / WFT
  failures, etc.
- A workflow may start ChildWorkflows, and send Signals to other workflows in the same namespace.
- Over-the-wire format and custom encoding of payloads (arguments and return values of Workflow, Activities, Nexus
  Operations, Child Workflows, Updates, Signals, etc) can be controlled by custom Data Converters
- The SDKs provide an "interceptor" facility allowing custom user code to be wrapped around gRPC calls, intercepting in
  the inbound and outbound directions.
- Workflows support Query handlers; Queries differ in some important respects from Signals and Updates: a Query handler
  must not block and thus may not create any commands; it must not have any side effect on Workflow state; sending and
  handling queries creates no events in History (and hence they are sometimes delivered via a special out-of-band task,
  if no WFT is available to deliver them to the worker).
- Activity Workers and Nexus Workers may be run in the same process as Workflow Workers or in their own processes.
- An ActivityTaskScheduled event causes the server to dispatch an Activity Task; the Activity must be registered with an
  ActivityWorker; the ActivityWorker executes it; user Activity code should use the heartbeating APIs provided.
- NexusOperationScheduled causes the server to make a Nexus RPC call to the target namespace (which may be the same
  namespace), resulting in a NexusTask being dispatched to the Nexus Worker in the target namespace, which is handled by
  looking up the requested Nexus Operation in the requested Nexus Service (this must have been registered with the
  worker by the user). Nexus Workers are similar in many respects to Activity Workers. The operation may respond
  synchronously (in which case the target namespace sends the result in the Nexus RPC response and the caller namespace
  Workflow receives NexusOperationCompleted without NexusOperationStarted, which it responds to by unblocking both
  wait-for-start and wait-for-compeletion futures) or asynchronously (in which case the target namespace responds to the
  Nexus RPC with an operation token resulting in the caller namespace Workflow receiving NexusOperationStarted, which
  unblocks the start future; when the Nexus operation finally completes the target namespace server will use the Nexus
  callback URL to deliver the final result/failure to the caller namespace, resulting in the caller namespace workflow
  receiving NexusOperationCompleted and unblocking the wait-for-completion future)


## Rules and guidelines for Workflow code

1.



## How to review diffs and PRs

This section describes how to review a diff between two states of a codebase that uses Temporal SDKs. We'll refer to
them as the Current State S0 and the Proposed State S1. We'll assume that it is proposed to deploy the Proposed State to
Temporal Workers that are currently running the Current State.

We'll also assume that
1. The Proposed State would be 100% correct if we were starting from scratch
2. We move atomically from a state in which all services have state S0 deployed to one in which all have state S1 deployed.

Therefore all the problems in this section derive from a Workflow Worker running the Proposed State replaying a history
that was (at least partially) created by a service running the Current State, or vice versa.


1. **Signatures of Workflow run method and Signal/Update/Query handlers**: You must not remove any parameters, you
  must not add any required parameters, and you must not change the meaning of existing parameters. Regarding a parameter in the
  signature that is a compound object of some sort that has fields (struct / class / dataclass / etc), you must not
  remove any fields, and you may add a field only if it is given a default value.

2. **Return types** You must not change the return type of an Activity, Child Workflow, Nexus Operation

3. **Order of command-generating calls** You must not cause the sequence of commands generated by the workflow to
  change, whether as a result of additions or removals of command-generating calls, or as a result of changes to control
  flow logic or wait conditions.








1. A service running the Proposed State receives a message (task) from a service running the Current State, or vice versa.






## Rules and guidelines for Activity code
## Rules and guidelines for Nexus Operation code
## Rules and guidelines for Client code


## Reviewing diffs and PRs

## Language-specific instructions

The precise nature of the workflow tasks depends on the language: in Python they are asyncio coroutines, in Typescript
they are the standard event loop microtasks, in Go they are goroutines under the control of a custom cooperative
multitasking framework, in Java they are threads under the control of a custom cooperative multitasking framework, in C#
they are asynchronous tasks, in Ruby they are TODO.

C#, Python, Typescript, Ruby make use of the shared `sdk-core` Rust library and are referred to as "core SDKs".

### .NET / C#


### Go
- map iteration

#### Identifying Workflow code
A Workflow in Go is a normal function or method. It can be identified as a Workflow by the fact that (1) it takes
`workflow.Context` as its first argument, and somewhere in the codebase it will be (2) passed to one of the worker
methods `RegisterWorkflow` or `RegisterWorkflowWithOptions`, and (3) started from Client/Activity/Nexus code context via `ExecuteWorkflow`.

### Java

`sdk-java` may be used from Kotlin code.


### Python
- `asyncio.wait` etc
- pass-through (e.g. activity) imports
- use pydantic data converter if codebase uses pydantic
- sync and async activities


### Ruby


### Typescript
A Workflow in Typescript is a normal async function. It is registered with the worker using either the `workflowBundle` or `workflowsPath` worker options. Thus