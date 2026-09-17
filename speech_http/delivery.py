"""Generator-to-player delivery, restricted to operator-configured targets."""
import json
import re
import urllib.error
import urllib.request
from urllib.parse import urlsplit


def targets_from_json(value):
    targets = json.loads(value)
    if not isinstance(targets, dict):
        raise ValueError("playback targets must be a JSON object")
    for name, url in targets.items():
        if not re.fullmatch(r"[a-zA-Z0-9_-]{1,64}", name) or not isinstance(url, str):
            raise ValueError("invalid playback target")
        parsed = urlsplit(url)
        if (parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or
                parsed.password or parsed.query or parsed.fragment or parsed.path not in ("", "/")):
            raise ValueError("playback target must be an HTTP(S) origin")
    return targets


def validate_delivery(data, targets):
    if (not isinstance(data, dict) or not isinstance(data.get("target"), str) or
            data["target"] not in targets):
        raise ValueError("unknown playback target; configure READER_SPEECH_PLAYBACK_TARGETS")
    for name, size in (("session", 32), ("delivery_token", 64)):
        if not isinstance(data.get(name), str) or not re.fullmatch(r"[a-f0-9]{" + str(size) + "}", data[name]):
            raise ValueError("invalid playback session")
    if type(data.get("id")) is not int or data["id"] < 0:
        raise ValueError("invalid playback utterance ID")
    return dict(data, endpoint=targets[data["target"]].rstrip("/"))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def upload(delivery, part, body=b"{}", content_type="application/json"):
    url = (f'{delivery["endpoint"]}/v1/sessions/{delivery["session"]}'
           f'/audio/{delivery["id"]}/{part}')
    request = urllib.request.Request(url, data=body, headers={
        "Content-Type": content_type, "Authorization": "Bearer " + delivery["delivery_token"]})
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=15) as response:
            if response.status != 200 or not json.load(response).get("ok"):
                raise RuntimeError("playback delivery rejected")
    except urllib.error.HTTPError as exc:
        status = exc.code
        exc.close()
        raise RuntimeError(f"playback delivery rejected (HTTP {status}); session may have stopped") from None
    except (OSError, ValueError):
        raise RuntimeError("playback server unavailable") from None
