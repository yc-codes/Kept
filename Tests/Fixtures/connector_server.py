"""Loopback fixture for the built-in connector integration tests."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

FEED = """<?xml version="1.0"?>
<rss version="2.0"><channel><title>Fixture Feed</title>
<item><guid>fixture-entry</guid><title>Connector article</title>
<link>https://example.test/article</link><pubDate>Tue, 02 Jan 2024 12:30:00 GMT</pubDate></item>
</channel></rss>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body, content_type="application/json", headers=()):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        for key, value in headers:
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        request = urlsplit(self.path)
        path = request.path
        token = self.headers.get("Authorization")
        if path in ("/user", "/user/starred", "/rest/v1/user", "/rest/v1/raindrops/0"):
            if token == "Bearer rejected":
                return self.reply(401, "{}")
            if token == "Bearer rate-limited":
                return self.reply(403, "{}", headers=[("X-RateLimit-Remaining", "0")])
            if token == "Bearer malformed":
                return self.reply(200, "not JSON")
            if token != "Bearer fixture-token":
                return self.reply(403, "{}")
        query = parse_qs(request.query)
        if path == "/user":
            payload = {"login": "fixture-user"}
        elif path == "/user/starred":
            if self.headers.get("Accept") != "application/vnd.github.star+json":
                return self.reply(400, "{}")
            page = int(query["page"][0])
            indices = range(100) if page == 1 else [100] if page == 2 else []
            payload = [
                {
                    "starred_at": "2024-01-02T12:30:00Z",
                    "repo": {"id": index, "full_name": f"fixture/repo-{index}",
                             "html_url": f"https://example.test/repo-{index}", "description": "  Test star  "},
                }
                for index in indices
            ]
            if page == 2:
                payload.append({"repo": {"id": 99_999}})
        elif path == "/rest/v1/user":
            payload = {"user": {"fullName": "Fixture Account"}}
        elif path == "/rest/v1/raindrops/0":
            page = int(query["page"][0])
            indices = range(50) if page == 0 else [50] if page == 1 else []
            payload = {"items": [
                {"_id": index, "link": f"https://example.test/bookmark-{index}",
                 "title": "  Bookmark  " if index == 0 else "", "created": "2024-01-02T12:30:00.100Z"}
                for index in indices
            ]}
        elif path == "/feed":
            return self.reply(200, FEED, "application/rss+xml")
        elif path == "/not-feed":
            return self.reply(200, "<html/>", "text/html")
        elif path == "/unavailable":
            return self.reply(503, "{}")
        else:
            return self.reply(404, "{}")
        self.reply(200, json.dumps(payload))


if __name__ == "__main__":
    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        print(server.server_port, flush=True)
        server.serve_forever()
