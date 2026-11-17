"""Exercise production attachment guards without credentials or network."""
import hashlib
import unittest
from unittest.mock import patch
import app_store_review as review

class FakeClient:
    def __init__(self, content=b"test"):
        self.content = content
        self.checksum = hashlib.md5(content).hexdigest()
        self.existing = []
        self.calls = []
        self.chunks = []
        self.state, self.build, self.bundle = "REJECTED", "4", review.BUNDLE_ID
        self.operations = [{"offset": 0, "length": len(content), "method": "PUT",
                            "url": "https://upload.blobstore.apple.com/asset", "requestHeaders": []}]

    def list(self, path):
        if "appStoreVersions?" in path:
            return [{"id": "v", "attributes": {"appStoreState": self.state}}]
        return self.existing

    def api(self, method, path, data=None):
        self.calls.append((method, path, data))
        if path == "/v1/apps/" + review.APP_ID:
            return {"data": {"attributes": {"bundleId": self.bundle}}}
        if path.endswith("/build"):
            return {"data": {"attributes": {"version": self.build}}}
        if path.endswith("/appStoreReviewDetail"):
            return {"data": {"id": "r", "attributes": {"notes": "PENDING"}}}
        if method == "POST":
            return {"data": {"id": "a", "attributes": {"uploadOperations": self.operations}}}
        if method == "PATCH":
            self.checksum = data["data"]["attributes"]["sourceFileChecksum"]
            return {}
        if path == "/v1/appStoreReviewAttachments/a":
            return {"data": {"id": "a", "attributes": {
                "assetDeliveryState": {"state": "COMPLETE"}, "sourceFileChecksum": self.checksum}}}
        raise AssertionError(path)

    def upload(self, operation, content):
        self.chunks.append(content[operation["offset"]:operation["offset"] + operation["length"]])

class Guards(unittest.TestCase):
    def test_scope_rejects_another_app_build_or_review_state(self):
        for attribute, value in [("bundle", "other.app"), ("build", "5"), ("state", "WAITING_FOR_REVIEW")]:
            client = FakeClient()
            setattr(client, attribute, value)
            with self.subTest(attribute=attribute), self.assertRaises(review.ReviewError):
                review.target(client)
            self.assertFalse(any(m != "GET" for m, _, _ in client.calls))

    def test_existing_complete_attachment_is_reused_without_mutation(self):
        client = FakeClient()
        client.existing = [{"id": "a", "attributes": {
            "fileName": review.NAME, "sourceFileChecksum": client.checksum}}]
        result = review.attach(client, "r", client.content)
        self.assertTrue(result["reused"])
        self.assertFalse(any(m != "GET" for m, _, _ in client.calls))

    def test_same_name_different_file_is_preserved(self):
        client = FakeClient()
        client.existing = [{"id": "a", "attributes": {
            "fileName": review.NAME, "sourceFileChecksum": "different"}}]
        with self.assertRaises(review.ReviewError):
            review.attach(client, "r", client.content)
        self.assertFalse(client.calls)

    def test_upload_commits_checksum_and_reads_back_complete(self):
        client = FakeClient(b"license document")
        result = review.attach(client, "r", client.content)
        self.assertEqual(b"".join(client.chunks), client.content)
        self.assertEqual(result["state"], "COMPLETE")
        self.assertEqual([m for m, _, _ in client.calls], ["POST", "PATCH", "GET"])

    def test_invalid_ranges_never_transmit_file(self):
        client = FakeClient()
        client.operations[0]["offset"] = 1
        with self.assertRaises(review.ReviewError):
            review.attach(client, "r", client.content)
        self.assertFalse(client.chunks)
        self.assertFalse(any(m == "PATCH" for m, _, _ in client.calls))

    def test_unexpected_upload_destination_never_connects(self):
        client = object.__new__(review.Client)
        client.opener = None
        for url in ["http://upload.blobstore.apple.com/a", "https://example.com/a",
                    "https://user@upload.blobstore.apple.com/a"]:
            with self.subTest(url=url), patch.object(review, "request") as transmit:
                operation = {"url": url, "method": "PUT", "requestHeaders": [], "offset": 0, "length": 4}
                with self.assertRaises(review.ReviewError):
                    client.upload(operation, b"test")
                transmit.assert_not_called()

if __name__ == "__main__":
    unittest.main()
