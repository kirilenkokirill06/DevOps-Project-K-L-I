#!/usr/bin/env python3
"""
Integration and Chaos Engineering Test Suite for HAProxy + Nginx Cluster.

This test suite performs the following validations:
1. Round Robin balancing distribution: Checks if traffic is balanced evenly.
2. Sticky Sessions: Checks if cookie inserts force stickiness to the same backend.
3. Chaos/Failover resilience: Automatically shuts down nodes, measures switch time,
   and validates HTTP 200 OK continuity.
4. Recovery validation: Verifies nodes are brought back online and handle requests.
5. Edge case behavior: Verifies behavior under extreme conditions (all backends down).

Dependencies:
    pip install pytest requests
"""

import os
import re
import time
import subprocess
import pytest
import requests

# Target URL for HAProxy frontend
BASE_URL = os.getenv("TEST_TARGET_URL", "http://127.0.0.1")
COMPOSE_FILE = os.getenv("TEST_COMPOSE_FILE", "../../docker-compose.yml")


def run_compose_cmd(action, service_name=None):
    """Helper function to run docker compose commands."""
    cmd = ["docker", "compose", "-f", COMPOSE_FILE, action]
    if service_name:
        cmd.append(service_name)

    result = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False
    )
    return result.returncode == 0, result.stdout, result.stderr


def get_backend_name(response_text):
    """Helper to extract backend hostname from response HTML."""
    match = re.search(r"nginx_backend_[1-3]", response_text)
    if match:
        return match.group(0)
    return None


@pytest.fixture(autouse=True)
def ensure_stack_running():
    """Fixture to ensure the stack is started before tests and restored after."""
    # Start stack
    success, _, err = run_compose_cmd("up", "-d")
    if not success:
        pytest.skip(f"Failed to start docker compose stack: {err}")

    # Wait for HAProxy health check
    time.sleep(5)

    yield

    # Restore all backends after test
    run_compose_cmd("start")
    time.sleep(3)


def test_round_robin_balancing():
    """Verify that HAProxy uses Round Robin to balance requests evenly."""
    responses = []

    # Send 15 requests and record which node handled each
    for _ in range(15):
        try:
            resp = requests.get(BASE_URL, timeout=3)
            assert resp.status_code == 200
            backend = get_backend_name(resp.text)
            if backend:
                responses.append(backend)
        except requests.RequestException as e:
            pytest.fail(f"HTTP request failed: {e}")

    # Check that we received responses from all 3 backends
    unique_backends = set(responses)
    assert len(unique_backends) == 3, f"Expected 3 backends, got: {unique_backends}"

    # Verify distribution (should be roughly equal, e.g., 5 each for 15 requests)
    for backend in unique_backends:
        count = responses.count(backend)
        assert 4 <= count <= 6, f"Imbalanced distribution: {backend} handled {count} requests"


def test_sticky_sessions():
    """Verify that Sticky Sessions are honored via the SERVERID cookie."""
    session = requests.Session()

    # First request: get the cookie and establish the backend
    try:
        resp = session.get(BASE_URL, timeout=3)
        assert resp.status_code == 200
        assert "SERVERID" in session.cookies, "HAProxy did not insert SERVERID cookie"

        initial_backend = get_backend_name(resp.text)
        assert initial_backend is not None

        # Send 10 subsequent requests with the same session/cookie
        for _ in range(10):
            subsequent_resp = session.get(BASE_URL, timeout=3)
            assert subsequent_resp.status_code == 200
            current_backend = get_backend_name(subsequent_resp.text)
            assert current_backend == initial_backend, (
                f"Session was routed to {current_backend} instead of pinned {initial_backend}"
            )
    except requests.RequestException as e:
        pytest.fail(f"HTTP request failed during sticky session verification: {e}")


def test_chaos_failover_and_resilience():
    """
    Chaos Engineering Test:
    1. Stop Nginx Backend 1.
    2. Check that system remains healthy and redirects traffic.
    3. Stop Nginx Backend 2.
    4. Validate system is still healthy with 1 live backend.
    5. Measure transition/failover latency.
    """
    # 1. Stop backend 1 (nginx1)
    success, _, err = run_compose_cmd("stop", "nginx1")
    assert success, f"Failed to stop nginx1: {err}"

    # Wait for HAProxy active check to mark server down (inter 2s, fall 3 -> ~6s max)
    time.sleep(6)

    # Send requests and verify they are only handled by nginx2 and nginx3
    backends_seen = set()
    for _ in range(10):
        resp = requests.get(BASE_URL, timeout=3)
        assert resp.status_code == 200
        backend = get_backend_name(resp.text)
        assert backend != "nginx_backend_1", "HAProxy sent traffic to stopped backend nginx1!"
        backends_seen.add(backend)

    assert "nginx_backend_2" in backends_seen or "nginx_backend_3" in backends_seen

    # 2. Stop backend 2 (nginx2)
    success, _, err = run_compose_cmd("stop", "nginx2")
    assert success, f"Failed to stop nginx2: {err}"

    # Measure switch latency and ensure availability
    start_time = time.time()
    failover_latency = 0.0

    # Send traffic immediately and repeatedly during transition
    nginx3_active = False
    for _ in range(15):
        try:
            resp = requests.get(BASE_URL, timeout=2)
            if resp.status_code == 200:
                backend = get_backend_name(resp.text)
                if backend == "nginx_backend_3":
                    if not nginx3_active:
                        failover_latency = time.time() - start_time
                        nginx3_active = True
        except requests.RequestException:
            # Short transient failure is possible if request hits exactly during switch,
            # but HAProxy should route transparently.
            pass
        time.sleep(0.5)

    assert nginx3_active, "System did not failover to nginx3!"
    assert failover_latency < 6.0, f"Failover switch latency too high: {failover_latency}s"

    # 3. Verify that requests ONLY go to nginx3 now
    for _ in range(5):
        resp = requests.get(BASE_URL, timeout=3)
        assert resp.status_code == 200
        assert get_backend_name(resp.text) == "nginx_backend_3"


def test_edge_case_all_backends_down():
    """Verify system edge case behavior: All backends are down."""
    # Stop all Nginx nodes
    success, _, err = run_compose_cmd("stop", "nginx1")
    assert success
    success, _, err = run_compose_cmd("stop", "nginx2")
    assert success
    success, _, err = run_compose_cmd("stop", "nginx3")
    assert success

    time.sleep(6)  # wait for checks to run

    try:
        resp = requests.get(BASE_URL, timeout=5)
        # HAProxy should return 503 Service Unavailable when no backend is available
        assert resp.status_code == 503
    except requests.RequestException as e:
        pytest.fail(f"Connection failed instead of returning HTTP 503: {e}")


def test_node_recovery():
    """Verify that when a stopped node recovers, it is reintegrated into the pool."""
    # Stop nginx1
    run_compose_cmd("stop", "nginx1")
    time.sleep(6)

    # Confirm it does not receive traffic
    for _ in range(5):
        resp = requests.get(BASE_URL, timeout=3)
        assert get_backend_name(resp.text) != "nginx_backend_1"

    # Start nginx1 back up
    success, _, err = run_compose_cmd("start", "nginx1")
    assert success, f"Failed to start nginx1: {err}"

    # Wait for HAProxy to detect it is back online (inter 2s, rise 2 -> ~4s)
    time.sleep(5)

    # Verify it receives traffic again
    nginx1_recovered = False
    for _ in range(15):
        resp = requests.get(BASE_URL, timeout=3)
        if get_backend_name(resp.text) == "nginx_backend_1":
            nginx1_recovered = True
            break

    assert nginx1_recovered, "Recovered backend nginx1 did not rejoin the active balancing pool"
