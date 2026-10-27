import os
import time

from fastapi import FastAPI
from fastapi.responses import JSONResponse

STARTED_AT = time.monotonic()

app = FastAPI()


def failure_mode() -> str:
    return os.getenv("FAILURE_MODE", "none")


def delayed_failure_active() -> bool:
    delay = int(os.getenv("FAILURE_DELAY_SECONDS", "180"))
    return failure_mode() == "delayed" and time.monotonic() - STARTED_AT >= delay


def error() -> JSONResponse:
    return JSONResponse(status_code=500, content={"error": "simulated failure"})


@app.get("/health")
def health():
    if failure_mode() == "health":
        return error()
    return {"status": "ok"}


@app.get("/version")
def version():
    if delayed_failure_active():
        return error()
    return {"version": os.getenv("APP_VERSION", "dev"), "git_sha": os.getenv("GIT_SHA", "unknown")}


@app.get("/")
def root():
    if delayed_failure_active():
        return error()
    return {"message": "order accepted!!", "version": os.getenv("APP_VERSION", "dev")}
