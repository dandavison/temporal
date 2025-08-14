from datetime import timedelta

from temporalio import workflow

with workflow.unsafe.imports_passed_through():
    from context_builder.activities.context_builder import build_context


@workflow.defn
class ContextBuilder:
    @workflow.run
    async def run(self) -> str:
        raw_context = await workflow.execute_activity(
            build_context,
            schedule_to_close_timeout=timedelta(seconds=10),
        )
        return raw_context
