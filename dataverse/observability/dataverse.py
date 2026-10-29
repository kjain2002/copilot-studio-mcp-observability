import time
from collections.abc import Iterator
from datetime import UTC, datetime
from email.utils import parsedate_to_datetime
from typing import Any, Protocol
from urllib.parse import urlencode, urlsplit

import requests


class Token(Protocol):
    @property
    def token(self) -> str: ...


class Credential(Protocol):
    def get_token(self, *scopes: str, **kwargs: Any) -> Token: ...


def validate_origin(url: str) -> str:
    parsed = urlsplit(url)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password
            or parsed.query or parsed.fragment or parsed.path not in ("", "/")
            or parsed.port not in (None, 443)):
        raise ValueError("Dataverse URL must be an HTTPS origin")
    if not parsed.hostname.endswith((".dynamics.com", ".microsoftdynamics.us", ".dynamics.cn")):
        raise ValueError("Unsupported Dataverse domain; review sovereign-cloud endpoint configuration")
    return url.rstrip("/")


def retry_delay(header: str | None, attempt: int) -> float:
    if header:
        try:
            delay = float(header)
        except ValueError:
            delay = (parsedate_to_datetime(header) - datetime.now(UTC)).total_seconds()
        if delay > 120:
            raise RuntimeError("Server retry delay exceeds bounded run policy; retry on the next run")
        return max(0, delay)
    return min(2 ** attempt, 60)


class Dataverse:
    def __init__(self, origin: str, credential: Credential):
        self.origin = validate_origin(origin)
        self.api = self.origin + "/api/data/v9.2/"
        self.credential = credential
        self.session = requests.Session()

    def close(self) -> None:
        self.session.close()

    def pages(self, entity: str, select: str, filter_text: str | None = None,
              orderby: str | None = None) -> Iterator[list[dict[str, Any]]]:
        query = {"$select": select}
        if filter_text:
            query["$filter"] = filter_text
        if orderby:
            query["$orderby"] = orderby
        next_url: str | None = self.api + entity + "?" + urlencode(query)
        visited: set[str] = set()
        while next_url:
            if not next_url.startswith(self.api) or next_url in visited:
                raise ValueError("Unsafe or cyclic Dataverse pagination URL")
            visited.add(next_url)
            data = self._get(next_url)
            if not isinstance(data.get("value"), list):
                raise ValueError("Dataverse response lacks value array")
            yield data["value"]
            next_url = data.get("@odata.nextLink")

    def _get(self, url: str) -> dict[str, Any]:
        for attempt in range(6):
            token = self.credential.get_token(self.origin + "/.default").token
            try:
                response = self.session.get(
                    url,
                    headers={"Authorization": "Bearer " + token, "Accept": "application/json",
                             "OData-Version": "4.0", "OData-MaxVersion": "4.0",
                             "Prefer": "odata.maxpagesize=500"},
                    timeout=(10, 90), allow_redirects=False,
                )
            except (requests.Timeout, requests.ConnectionError):
                if attempt == 5:
                    raise RuntimeError("Dataverse transport failed after bounded retries") from None
                time.sleep(retry_delay(None, attempt))
                continue
            with response:
                if response.status_code == 200:
                    return response.json()
                if response.status_code not in (429, 500, 502, 503, 504) or attempt == 5:
                    raise RuntimeError(f"Dataverse request failed (HTTP {response.status_code}); body omitted")
                time.sleep(retry_delay(response.headers.get("Retry-After"), attempt))
        raise RuntimeError("Dataverse retry limit reached")
