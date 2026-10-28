import logging
import os

import azure.functions as func
from azure.identity import ManagedIdentityCredential

from observability.azure_store import BlobStore
from observability.collector import SCHEDULES, Settings, collect
from observability.dataverse import Dataverse

app = func.FunctionApp()
logger = logging.getLogger(__name__)


@app.timer_trigger(schedule="%COLLECTION_SCHEDULE%", arg_name="timer", run_on_startup=False, use_monitor=True)
def export_environment(timer: func.TimerRequest) -> None:
    mode = os.environ["COLLECTION_MODE"]
    if mode not in SCHEDULES or os.environ["COLLECTION_SCHEDULE"] != SCHEDULES[mode]:
        raise ValueError("COLLECTION_MODE and COLLECTION_SCHEDULE must match a supported UTC schedule")
    settings = Settings(
        environment_id=os.environ["ENVIRONMENT_ID"], mode=mode,
        initial_days=int(os.environ.get("INITIAL_DAYS", "7")),
        overlap_hours=int(os.environ.get("OVERLAP_HOURS", "48")),
        slice_hours=int(os.environ.get("SLICE_HOURS", "24")),
        max_transcripts=int(os.environ.get("MAX_TRANSCRIPTS_PER_SLICE", "10000")),
        source_retention_days=int(os.environ.get("SOURCE_RETENTION_DAYS", "30")),
    )
    if timer.past_due:
        logger.warning("Collection timer is past due; recovering from the committed watermark")
    with ManagedIdentityCredential() as credential:
        source = Dataverse(os.environ["DATAVERSE_URL"], credential)
        try:
            with BlobStore(os.environ["REPORTS_ACCOUNT_URL"], os.environ["REPORTS_CONTAINER"],
                           credential, settings.environment_id) as store:
                result = collect(source, store, settings, guard=store.guard)
                logger.info("Collection completed: agents=%d slices=%d",
                            result["AgentCount"], len(result["Manifests"]))
        finally:
            source.close()
