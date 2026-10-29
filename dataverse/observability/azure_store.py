import logging
import threading
from typing import Any

from azure.core.exceptions import AzureError, ResourceExistsError
from azure.storage.blob import BlobLeaseClient, ContainerClient, ContentSettings

from .collector import json_bytes

logger = logging.getLogger(__name__)


class BlobStore:
    def __init__(self, account_url: str, container: str, credential: Any, environment_id: str):
        self.container = ContainerClient(account_url, container, credential=credential)
        self.state = self.container.get_blob_client(f"environments/{environment_id}/checkpoint.json")
        self.lease: BlobLeaseClient | None = None
        self.stop = threading.Event()
        self.lost = threading.Event()
        self.thread: threading.Thread | None = None

    def __enter__(self) -> "BlobStore":
        try:
            self.state.upload_blob(b"{}", overwrite=False)
        except ResourceExistsError:
            pass
        try:
            self.lease = self.state.acquire_lease(lease_duration=60)
        except AzureError:
            self.container.close()
            raise RuntimeError("Cannot acquire environment checkpoint lease; check concurrent runs and storage access") from None
        self.thread = threading.Thread(target=self._renew, daemon=True)
        self.thread.start()
        return self

    def _renew(self) -> None:
        while not self.stop.wait(20):
            try:
                if self.lease is None:
                    self.lost.set()
                    return
                self.lease.renew()
            except AzureError:
                self.lost.set()
                logger.error("Environment lease renewal failed; checkpoint advancement is blocked")
                return

    def guard(self) -> None:
        if self.lost.is_set() or self.lease is None:
            raise RuntimeError("Environment lease lost; rerun from the last committed checkpoint")

    def checkpoint(self) -> dict[str, Any]:
        import json
        self.guard()
        return json.loads(self.state.download_blob(lease=self.lease).readall())

    def put(self, name: str, data: bytes, content_type: str) -> None:
        self.guard()
        self.container.upload_blob(name, data, overwrite=True,
                                   content_settings=ContentSettings(content_type=content_type))

    def advance(self, checkpoint: dict[str, Any]) -> None:
        self.guard()
        self.state.upload_blob(json_bytes(checkpoint), overwrite=True, lease=self.lease,
                               content_settings=ContentSettings(content_type="application/json"))

    def __exit__(self, exc_type: Any, exc_value: Any, traceback: Any) -> None:
        self.stop.set()
        if self.thread:
            self.thread.join(timeout=30)
        try:
            if self.lease and not self.lost.is_set():
                self.lease.release()
        finally:
            self.container.close()
