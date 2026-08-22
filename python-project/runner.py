"""ETL.py çıktısını JSON olarak loglar ve çıkış kodunu CronJob'a iletir."""

import contextlib
import io
import json
import os
import runpy
import sys
import time
import traceback
from datetime import UTC, datetime

ETL_SCRIPT = os.environ.get("ETL_SCRIPT", os.path.join(os.path.dirname(__file__), "ETL.py"))


def log(level, msg, **fields):
    """Tek satır JSON log üretir."""
    record = {
        "ts": datetime.now(UTC).isoformat(),
        "level": level,
        "service": "etl",
        "msg": msg,
    }
    record.update(fields)
    print(json.dumps(record, default=str), flush=True)


def main():
    started = time.monotonic()
    log("info", "etl.start", script=ETL_SCRIPT)

    captured = io.StringIO()
    try:
        with contextlib.redirect_stdout(captured):
            runpy.run_path(ETL_SCRIPT, run_name="__main__")
    except Exception as exc:
        emit_captured(captured)
        log(
            "error",
            "etl.failed",
            error=str(exc),
            error_type=type(exc).__name__,
            traceback=traceback.format_exc(),
            duration_ms=elapsed_ms(started),
        )
        return 1

    emit_captured(captured)
    log("info", "etl.success", duration_ms=elapsed_ms(started))
    return 0


def emit_captured(buffer):
    for line in buffer.getvalue().splitlines():
        if line.strip():
            log("info", "etl.output", output=line)


def elapsed_ms(started):
    return int((time.monotonic() - started) * 1000)


if __name__ == "__main__":
    sys.exit(main())
