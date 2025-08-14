import asyncio
import uuid

from temporalio.client import Client
from temporalio.worker import Worker

from context_builder.activities.context_builder import build_context
from context_builder.workflows.context_builder import ContextBuilder


async def main():
    client = await Client.connect("localhost:7233")

    async with Worker(
        client,
        task_queue="context-builder-task-queue",
        workflows=[ContextBuilder],
        activities=[build_context],
    ) as worker:
        result = await client.execute_workflow(
            ContextBuilder.run,
            id=str(uuid.uuid4()),
            task_queue=worker.task_queue,
        )
        print(result)


if __name__ == "__main__":
    asyncio.run(main())
