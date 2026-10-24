"""Packaged local engine entry point. No shell, reload worker or public listener."""

import argparse
import asyncio
import os
from pathlib import Path
import sys

import uvicorn
from main import app


async def run(port):
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port,
        loop="asyncio", http="h11", ws="none", access_log=False, log_level="warning"))
    parent = int(os.environ.get("MOCHI_PARENT_PID", "0"))

    async def watch_parent():
        while not server.should_exit:
            await asyncio.sleep(2)
            if parent and os.getppid() != parent:
                server.should_exit = True

    watch = asyncio.create_task(watch_parent()) if parent else None
    try:
        await server.serve()
    finally:
        if watch:
            watch.cancel()
            await asyncio.gather(watch, return_exceptions=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Mochi local music engine")
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error("Choose a local port between 1024 and 65535")
    if getattr(sys, "frozen", False):
        os.environ.setdefault("MOCHI_DATA_DIRECTORY", str(Path.home() / "Library/Application Support/Mochi/Engine"))
    asyncio.run(run(args.port))
