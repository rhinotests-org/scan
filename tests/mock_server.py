"""A stand-in for the RhinoTests CI API, driven by a scenario name in the token.

The token is `rt_<scenario>`; each scenario scripts the answers the action should cope with.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

REPORT = "https://app.rhinotests.com/scans/runs/report/app.example.com"
calls: dict[str, int] = {}


def result(high: int, medium: int, low: int, grade: str) -> dict:
    return {
        "status": "done",
        "phase": "finished",
        "percent": 100,
        "failure": None,
        "result": {
            "grade": grade,
            "open": high + medium + low,
            "bySeverity": {"high": high, "medium": medium, "low": low},
        },
    }


FINAL = {
    "clean": result(0, 0, 0, "A"),
    "low": result(0, 0, 2, "B"),
    "medium": result(0, 1, 2, "C"),
    "high": result(1, 1, 0, "D"),
    "flaky": result(0, 0, 0, "A"),
    "slow": None,
    "failed": {
        "status": "failed",
        "phase": "finished",
        "percent": 100,
        "result": None,
        "failure": {"code": "unreachable", "message": "The site did not answer"},
    },
}

REFUSALS = {
    "revoked": (401, {"code": "invalid_token", "message": "Missing or invalid API token"}),
    "poor": (402, {"code": "insufficient_credits", "message": "Not enough credits"}),
    "plan": (403, {"code": "plan_required", "message": "Plan", "details": {"feature": "apiAccess"}}),
    "unverified": (409, {"code": "domain_unverified", "message": "Domain is not verified"}),
    "busy": (409, {"code": "scan_in_progress", "message": "A scan is running"}),
    "unknown": (422, {"code": "invalid_scan", "message": "Unknown domain or profile"}),
    "down": (503, {"message": "Service Unavailable"}),
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args) -> None:  # noqa: D102 - keep the test output clean
        pass

    def send(self, status: int, body: dict, headers: dict | None = None) -> None:
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(raw)

    def scenario(self) -> str:
        return self.headers.get("authorization", "").removeprefix("Bearer rt_")

    def count(self, key: str) -> int:
        calls[key] = calls.get(key, 0) + 1
        return calls[key]

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("content-length", "0"))
        sent = json.loads(self.rfile.read(length) or b"{}")
        name = self.scenario()
        if not self.headers.get("user-agent"):
            return self.send(403, {"message": "Forbidden"})
        if name in REFUSALS:
            return self.send(*REFUSALS[name])
        # The firewall in front of the API answers 403 without our error format, once.
        if name == "flaky" and self.count("flaky-post") == 1:
            return self.send(403, {"message": "Forbidden"})
        self.send(
            201,
            {
                "id": f"scan-{name}",
                "status": "queued",
                "domain": sent.get("domain"),
                "profile": sent.get("profile"),
                "reportUrl": REPORT,
            },
        )

    def do_GET(self) -> None:  # noqa: N802
        name = self.scenario()
        seen = self.count(f"get-{name}")
        if name == "flaky" and seen == 1:
            return self.send(429, {"code": "rate_limited", "message": "Slow down"}, {"Retry-After": "1"})
        if name == "flaky" and seen == 2:
            return self.send(502, {"message": "Bad Gateway"})
        final = FINAL.get(name)
        if final is None or seen < 2:
            return self.send(
                200,
                {
                    "id": f"scan-{name}",
                    "status": "running",
                    "phase": "scanning",
                    "percent": 40,
                    "failure": None,
                    "result": None,
                    "reportUrl": REPORT,
                },
            )
        self.send(200, {"id": f"scan-{name}", "reportUrl": REPORT, **final})


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
