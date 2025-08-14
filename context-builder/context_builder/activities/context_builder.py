from temporalio import activity


@activity.defn
async def build_context() -> str:
    return "some context"
