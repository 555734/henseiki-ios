"""Attach public licenses to iOS 1.0 (4); never submit or release the app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com"
APP_ID, BUNDLE_ID, VERSION, BUILD = "6833313915", "com.fusena.henseiki", "1.0", "4"
NAME = "third-party-licenses.txt"
LICENSE_URL = "https://github.com/555734/henseiki-ios/blob/88b85a28e566a70cd31daac80b3915c06680b91f/docs/store/third-party-licenses.txt"
EXPECTED_DRAFT_SHA256 = "50292b5ddb38e38eefb305080fb9cbb0b8db7c74eeb816a02a6c340c28c88f8b"

class ReviewError(Exception):
    pass

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

def request(opener, req):
    try:
        with opener.open(req, timeout=45) as response:
            return response.read(4_000_000)
    except urllib.error.HTTPError as error:
        codes = []
        if req.full_url.startswith(API + "/v1/"):
            try:
                codes = [e.get("code", "") for e in json.loads(error.read(64000)).get("errors", [])]
            except (ValueError, OSError):
                pass
        raise ReviewError(f"HTTP {error.code}; API codes: {','.join(codes)}") from None
    except OSError:
        raise ReviewError("Network request failed; URL/credentials omitted.") from None

class Client:
    def __init__(self):
        import jwt
        try:
            token = jwt.encode(
                {"iss": os.environ["ASC_ISSUER_ID"], "iat": int(time.time()) - 10,
                 "exp": int(time.time()) + 900, "aud": "appstoreconnect-v1"},
                os.environ["ASC_KEY_P8"], algorithm="ES256",
                headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})
        except Exception:
            raise ReviewError("Existing App Store Connect credentials could not be loaded.") from None
        self.headers = {"Authorization": "Bearer " + token, "Content-Type": "application/json"}
        self.opener = urllib.request.build_opener(NoRedirect())

    def api(self, method, path, data=None):
        url = path if path.startswith(API + "/v1/") else API + path
        if not url.startswith(API + "/v1/"):
            raise ReviewError("Refusing a non-App-Store-Connect API destination.")
        payload = None if data is None else json.dumps(data).encode()
        for attempt in range(4):
            try:
                raw = request(self.opener, urllib.request.Request(url, data=payload, headers=self.headers, method=method))
                break
            except ReviewError as error:
                transient = str(error).startswith(("HTTP 500;", "HTTP 502;", "HTTP 503;", "HTTP 504;", "HTTP 429;"))
                if method != "GET" or not transient or attempt == 3:
                    raise
                time.sleep(2 ** attempt)
        return json.loads(raw) if raw else {}

    def list(self, path):
        items = []
        while path:
            page = self.api("GET", path)
            items.extend(page["data"])
            path = page.get("links", {}).get("next")
        return items

    def upload(self, operation, content):
        parsed = urllib.parse.urlsplit(operation["url"])
        host = parsed.hostname or ""
        if parsed.scheme != "https" or parsed.username or not (host == "apple.com" or host.endswith(".apple.com")):
            raise ReviewError("Refusing an unexpected asset upload destination.")
        if operation["method"].upper() != "PUT":
            raise ReviewError("Unexpected upload operation method.")
        headers = {h["name"]: h["value"] for h in operation["requestHeaders"]}
        if any(k.lower() == "authorization" for k in headers):
            raise ReviewError("Unexpected authorization header on asset upload.")
        start, length = operation["offset"], operation["length"]
        chunk = content[start:start + length]
        if len(chunk) != length:
            raise ReviewError("Invalid upload range.")
        request(self.opener, urllib.request.Request(operation["url"], data=chunk, headers=headers, method="PUT"))

def target(client):
    print("Stage: verify app identity", flush=True)
    app = client.api("GET", f"/v1/apps/{APP_ID}")["data"]
    if app["attributes"]["bundleId"] != BUNDLE_ID:
        raise ReviewError("App identity mismatch.")
    query = urllib.parse.urlencode({"filter[platform]": "IOS", "filter[versionString]": VERSION})
    print("Stage: read version 1.0", flush=True)
    versions = client.list(f"/v1/apps/{APP_ID}/appStoreVersions?{query}")
    if len(versions) != 1:
        raise ReviewError("Expected exactly one iOS 1.0 version.")
    version = versions[0]
    state = version["attributes"]["appStoreState"]
    if state not in {"REJECTED", "METADATA_REJECTED", "DEVELOPER_REJECTED", "PREPARE_FOR_SUBMISSION"}:
        raise ReviewError("Version is no longer in an editable rejected/preparation state.")
    print("Stage: verify selected build 4", flush=True)
    build = client.api("GET", f'/v1/appStoreVersions/{version["id"]}/build')["data"]
    if not build or build["attributes"]["version"] != BUILD:
        raise ReviewError("Selected build is no longer 4; refusing changes.")
    print("Stage: read saved review notes", flush=True)
    detail = client.api("GET", f'/v1/appStoreVersions/{version["id"]}/appStoreReviewDetail')["data"]
    notes = detail["attributes"].get("notes") or ""
    return detail["id"], {
        "app_id": APP_ID, "version": VERSION, "build": BUILD, "app_store_state": state,
        "notes_characters": len(notes.encode("utf-16-le")) // 2, "notes_draft_pending": "PENDING" in notes,
        "physical_device_qa": "pending", "physical_device_video": "pending", "resubmitted": False}

def wait_complete(client, attachment_id):
    for _ in range(60):
        attachment = client.api("GET", f"/v1/appStoreReviewAttachments/{attachment_id}")["data"]
        state = (attachment["attributes"].get("assetDeliveryState") or {}).get("state")
        if state == "COMPLETE":
            return attachment
        if state == "FAILED":
            raise ReviewError("Attachment processing failed; existing records were preserved.")
        time.sleep(2)
    raise ReviewError("Attachment processing is still pending after 120 seconds.")

def attach(client, review_id, content):
    print("Stage: check existing license attachments", flush=True)
    digest = hashlib.md5(content, usedforsecurity=False).hexdigest()
    existing = [a for a in client.list(f"/v1/appStoreReviewDetails/{review_id}/appStoreReviewAttachments?limit=50")
                if a["attributes"].get("fileName") == NAME]
    if existing:
        if len(existing) != 1 or existing[0]["attributes"].get("sourceFileChecksum") != digest:
            raise ReviewError("Same-name attachment differs; not replacing or deleting it.")
        item = wait_complete(client, existing[0]["id"])
        return {"file_name": NAME, "state": item["attributes"]["assetDeliveryState"]["state"],
                "reused": True, "sha256": hashlib.sha256(content).hexdigest()}
    print("Stage: reserve license attachment", flush=True)
    item = client.api("POST", "/v1/appStoreReviewAttachments", {
        "data": {"type": "appStoreReviewAttachments", "attributes": {"fileName": NAME, "fileSize": len(content)},
                 "relationships": {"appStoreReviewDetail": {
                     "data": {"type": "appStoreReviewDetails", "id": review_id}}}}})["data"]
    operations = sorted(item["attributes"]["uploadOperations"], key=lambda x: x["offset"])
    offset = 0
    print("Stage: validate upload ranges", flush=True)
    for operation in operations:
        if operation["offset"] != offset or operation["length"] <= 0:
            raise ReviewError("Upload ranges are not contiguous.")
        offset += operation["length"]
    if offset != len(content):
        raise ReviewError("Upload ranges do not cover the file exactly.")
    print("Stage: upload license bytes", flush=True)
    for operation in operations:
        client.upload(operation, content)
    print("Stage: commit license upload", flush=True)
    client.api("PATCH", f'/v1/appStoreReviewAttachments/{item["id"]}', {
        "data": {"type": "appStoreReviewAttachments", "id": item["id"],
                 "attributes": {"uploaded": True, "sourceFileChecksum": digest}}})
    item = wait_complete(client, item["id"])
    if item["attributes"].get("sourceFileChecksum") != digest:
        raise ReviewError("Uploaded attachment checksum readback differs.")
    return {"file_name": NAME, "state": item["attributes"]["assetDeliveryState"]["state"],
            "reused": False, "sha256": hashlib.sha256(content).hexdigest()}

def link_licenses(client, review_id):
    path = f"/v1/appStoreReviewDetails/{review_id}"
    notes = client.api("GET", path)["data"]["attributes"].get("notes") or ""
    if LICENSE_URL in notes:
        return {"url": LICENSE_URL, "readback_matches": True, "reused": True}
    canonical = notes.replace("\r\n", "\n").strip()
    if hashlib.sha256(canonical.encode()).hexdigest() != EXPECTED_DRAFT_SHA256:
        raise ReviewError("Review notes changed since the prepared draft; preserving those edits.")
    updated = notes.replace(NAME, LICENSE_URL, 1)
    if updated == notes or len(updated.encode("utf-16-le")) // 2 > 4000:
        raise ReviewError("License reference is missing or updated Notes exceed 4000 characters.")
    client.api("PATCH", path, {"data": {"type": "appStoreReviewDetails", "id": review_id,
                "attributes": {"notes": updated}}})
    saved = client.api("GET", path)["data"]["attributes"].get("notes")
    if saved != updated:
        raise ReviewError("Review Notes readback differs after saving.")
    return {"url": LICENSE_URL, "readback_matches": True, "reused": False}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upload-licenses", action="store_true")
    parser.add_argument("--link-licenses", action="store_true")
    parser.add_argument("--output", type=Path, default=Path("review-status.json"))
    args = parser.parse_args()
    content = Path(__file__).resolve().parents[1].joinpath("docs/store", NAME).read_bytes()
    if not 1000 < len(content) < 100_000 or not content.startswith(b"Third-party licenses"):
        raise ReviewError("Unexpected checked-in license document.")
    client = Client()
    review_id, summary = target(client)
    if args.upload_licenses:
        summary["license_attachment"] = attach(client, review_id, content)
        _, current = target(client)
        summary.update(current)
    else:
        summary["license_attachment"] = "not modified"
    if args.link_licenses:
        summary["license_document"] = link_licenses(client, review_id)
        _, current = target(client)
        summary.update(current)
    args.output.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))

if __name__ == "__main__":
    try:
        main()
    except ReviewError as error:
        print("STOPPED: " + str(error), file=sys.stderr)
        raise SystemExit(1)
