We (Temporal) are working on introducing a new framework for sync and async RPC
communication called Nexus. It's built on top of a synchronous HTTP protocol, as described
at https://github.com/nexus-rpc/api/blob/main/SPEC.md (study this spec carefully).

We have created "Nexus SDKs" in Python, Typescript, Go, Java. These are named
src/nexus-sdk-$lang on disk, github repos nexus-rpc/sdk-$lang.

And of course the Temporal SDKs exist for those languages: src/sdk-$lang on disk, github repos
temporalio/sdk-$lang.

## Work already done: call Nexus operations from Temporal workflows

So far, what we've done is make it possible to call nexus operations **from Temporal
worklows only**. This section describes that work, which you'll find implemented in the
Nexus and Temporal SDKs.

First, we added to the Nexus SDKs components (interfaces, base classes/enums etc) for
users to define nexus services/operations, and also "handler" abstractions which will be
used by people implementing servers or workers that host and execute Nexus operations.

Then we added to the Temporal repos the following:

1. The ability for user code in a Temporal workflow in the "caller namespace" to call and
   cancel Nexus operations. As with all Workflow APIs, this involves issuing Commands to
   Temporal server such as ScheduleNexusOperation, CancelNexusOperation, etc. During each
   workflow task, the workflow advances its concurrent routines
   (coroutines/goroutines/threads depending on language) until all are blocked waiting for
   something (e.g. a nexus operation/activity/child workflow result, a timer fired event)
   in a future workflow task from the server. The Commands collected during that workflow
   task are then sent in a task completion to the server, which causes the server to
   durably persist one workflow history event per command.
   
2. The ability for Temporal server in the caller namespace to respond to events written to
   history such as NexusOperationScheduled by initiating a Nexus HTTP StartOperation call
   to the target namespace (using an "Endpoint" abstraction to address the nexus service
   in the other namespace).
   
3. The handler namespace receives the Nexus HTTP call and responds to it by dispatching a
   NexusTask to a queue (similar to Temporal's Workflow and Activity Task queues). That
   Nexus Task is not persisted durably; instead it must be picked up by a NexusWorker
   (which uses the "handler" abstraction from the nexus sdk) and responded to
   synchronously, while the HTTP caller is waiting.
   
4. As you'll have understood from the Nexus spec, the Nexus operation executed by the
   Nexus worker responds either in "sync" mode (with the actual result/error) or in "async
   mode" (with an operation token). Either way, this response is delivered in a Task
   completion RPC to the server and becomes the HTTP response to the caller namespace,
   causes a new event to be written in the caller namespace (NexusOperationStarted in  the
   case of a async mode response, or NexusOperationCompleted in the case of a sync mode
   response) and then gives rise to a workflow task delivering the updated state to the
   workflow.


Notice the special status of the Go SDK in the above: since Temporal server is implemented
in Go, we had an immediate need from the outset in Go for components that we did not
immediately need in the other languages. Most notably: implementations of a Nexus HTTP
client (used in the caller namespace) and an HTTP server implementing the Nexus HTTP spec
(for the handler namespace). So despite what I said about us only having implemented
calling of Nexus operations from Workflows so far, that is not true for Go!

As a result, you should more or less look to the Go SDK as a "reference implementation" of
Nexus, when considering what other languages should look like. After Go, you should look
at Java: both those languages support for calling Nexus operations from workflows is GA.
