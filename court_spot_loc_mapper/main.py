"""Local court spot editor. Run with an output path and optional --input path."""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import webbrowser

HERE = Path(__file__).resolve().parent
X_MIN, X_MAX = -250, 250
Y_MIN, Y_MAX = -52, 418
MAX_BODY_BYTES = 2_000_000


def validate_mapping(value: object) -> dict:
    if not isinstance(value, dict) or not isinstance(value.get("spotList"), list):
        raise ValueError('JSON must contain a "spotList" array.')
    spots = []
    labels = set()
    for index, spot in enumerate(value["spotList"]):
        if not isinstance(spot, dict):
            raise ValueError(f"Spot {index + 1} must be an object.")
        label, loc = spot.get("label"), spot.get("loc")
        if not isinstance(label, str) or not label.strip():
            raise ValueError(f"Spot {index + 1} needs a nonempty label.")
        if label in labels:
            raise ValueError(f'Duplicate spot label: "{label}".')
        if not isinstance(loc, dict):
            raise ValueError(f'Spot "{label}" needs a loc object.')
        x, y = loc.get("x"), loc.get("y")
        for axis, number, low, high in (("x", x, X_MIN, X_MAX), ("y", y, Y_MIN, Y_MAX)):
            if isinstance(number, bool) or not isinstance(number, (int, float)) or not math.isfinite(number):
                raise ValueError(f'Spot "{label}" needs a finite numeric {axis}.')
            if not low <= number <= high:
                raise ValueError(f'Spot "{label}" {axis} must be between {low} and {high}.')
        labels.add(label)
        spots.append({"label": label, "loc": {"x": x, "y": y}})
    return {"spotList": spots}


def save_mapping(path: Path, mapping: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.",
            suffix=".tmp", delete=False,
        ) as file:
            temporary = Path(file.name)
            json.dump(mapping, file, ensure_ascii=False, indent=2, allow_nan=False)
            file.write("\n")
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def make_handler(initial_mapping: dict, output_path: Path):
    current = {"mapping": initial_mapping}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            files = {
                "/": (HERE / "index.html", "text/html; charset=utf-8"),
                "/app.js": (HERE / "app.js", "text/javascript; charset=utf-8"),
                "/court.jpg": (HERE / "court.jpg", "image/jpeg"),
            }
            if self.path == "/api/mapping":
                body = json.dumps(current["mapping"], ensure_ascii=False).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif self.path in files:
                path, content_type = files[self.path]
                body = path.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_error(404)

        def do_POST(self):
            if self.path != "/api/mapping":
                self.send_error(404)
                return
            try:
                if self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != "application/json":
                    raise ValueError("Expected application/json.")
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= MAX_BODY_BYTES:
                    raise ValueError("Invalid or oversized request.")
                body = self.rfile.read(length)
                mapping = validate_mapping(json.loads(body))
                save_mapping(output_path, mapping)
                current["mapping"] = mapping
            except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as error:
                self.respond_json(400, {"error": str(error)})
                return
            except OSError as error:
                self.respond_json(500, {"error": f"Could not save file: {error}"})
                return
            self.respond_json(200, {"saved": str(output_path)})

        def respond_json(self, status: int, value: dict) -> None:
            body = json.dumps(value, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return Handler


def main() -> None:
    parser = argparse.ArgumentParser(description="Edit basketball court spot locations in a browser.")
    parser.add_argument("output_json", type=Path, help="JSON file to write when Save is pressed")
    parser.add_argument("--input", dest="input_json", type=Path, help="Existing mapping JSON to load")
    args = parser.parse_args()
    try:
        initial = validate_mapping(json.loads(args.input_json.read_text(encoding="utf-8"))) if args.input_json else {"spotList": []}
    except (OSError, ValueError, json.JSONDecodeError) as error:
        parser.error(f"Cannot load input JSON: {error}")

    output_path = args.output_json.expanduser().resolve()
    server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(initial, output_path))
    url = f"http://127.0.0.1:{server.server_port}/"
    print(f"Court spot editor: {url}", flush=True)
    print(f"Save destination: {output_path}", flush=True)
    print("Press Ctrl+C to stop the editor.", flush=True)
    webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
