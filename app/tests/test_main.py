import pytest
from fastapi.testclient import TestClient

from main import app

client = TestClient(app)


@pytest.fixture(autouse=True)
def env(monkeypatch):
    monkeypatch.setenv("APP_VERSION", "1.0.0")
    monkeypatch.setenv("GIT_SHA", "abc1234")
    monkeypatch.delenv("FAILURE_MODE", raising=False)
    monkeypatch.delenv("FAILURE_DELAY_SECONDS", raising=False)


def test_none_mode():
    assert client.get("/health").json() == {"status": "ok"}
    assert client.get("/version").json() == {"version": "1.0.0", "git_sha": "abc1234"}
    assert client.get("/").status_code == 200


def test_health_mode(monkeypatch):
    monkeypatch.setenv("FAILURE_MODE", "health")
    assert client.get("/health").status_code == 500
    assert client.get("/").status_code == 200


def test_delayed_mode_before_delay(monkeypatch):
    monkeypatch.setenv("FAILURE_MODE", "delayed")
    assert client.get("/health").status_code == 200
    assert client.get("/").status_code == 200
    assert client.get("/version").status_code == 200


def test_delayed_mode_after_delay(monkeypatch):
    monkeypatch.setenv("FAILURE_MODE", "delayed")
    monkeypatch.setenv("FAILURE_DELAY_SECONDS", "0")
    assert client.get("/health").status_code == 200
    assert client.get("/").status_code == 500
    assert client.get("/version").status_code == 500
