#!/usr/bin/env python3
"""Bounded stdio adapter to ONT's official Dorado client; no decision logic."""
import argparse
import json
import math
import platform
import re
import struct
import sys
import time

MAX_SIGNAL_BYTES = 500000


def validate_request(request):
    if not isinstance(request, dict):
        raise ValueError("request must be an object")
    if not isinstance(request.get("id"), str) or not request["id"] or len(request["id"]) > 256:
        raise ValueError("invalid request id")
    size = request.get("bytes")
    if type(size) is not int or not 0 < size <= MAX_SIGNAL_BYTES or size % 2:
        raise ValueError("invalid signal size")
    for field in ("offset", "scale", "sample_rate"):
        value = request.get(field)
        if type(value) not in (int, float) or not math.isfinite(value):
            raise ValueError(f"invalid {field}")
        if field != "offset" and value <= 0:
            raise ValueError(f"invalid {field}")
    start = request.get("start_sample")
    if type(start) is not int or not 0 <= start < 2**64:
        raise ValueError("invalid start_sample")


def sequence_text(value):
    if isinstance(value, bytes):
        value = value.decode("ascii")
    if not isinstance(value, str) or re.fullmatch("[ACGTNacgtn]*", value) is None:
        raise ValueError("basecaller returned an invalid DNA sequence")
    return value.upper()


def emit(value):
    data = json.dumps(value).encode()
    if len(data) > 2 * 1024 * 1024:
        raise ValueError("response too large")
    sys.stdout.buffer.write(struct.pack("<I", len(data)) + data)
    sys.stdout.buffer.flush()


def package_signal(request, signal):
    """Keep the optional native ONT/NumPy dependencies at the packaging boundary."""
    import numpy as np
    from pybasecall_client_lib.helper_functions import package_read

    return package_read(
        read_id=request["id"], raw_data=np.frombuffer(signal, dtype="<i2").astype(np.int16, copy=False),
        daq_offset=request["offset"], daq_scaling=request["scale"],
        sampling_rate=request["sample_rate"], start_time=request["start_sample"],
    )


def basecall(client, request, signal, timeout):
    read = package_signal(request, signal)
    deadline = time.monotonic() + timeout
    # The pinned PyBasecallClient returns False for queue_full. Fail this job
    # immediately; the coordinator preserves the molecule. Do not retry here.
    if not client.pass_reads([read]):
        raise RuntimeError("Dorado input queue is full")
    while time.monotonic() < deadline:
        for batch in client.get_completed_reads():
            matching = [result for result in batch if result["metadata"]["read_id"] == request["id"]]
            if matching:
                # Preserve split molecules as separate sequences, never concatenate.
                return [sequence_text(result["datasets"]["sequence"]) for result in matching]
        time.sleep(0.002)
    raise TimeoutError("Dorado result deadline exceeded")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--address", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--timeout", type=float, default=3)
    parser.add_argument("--startup-timeout", type=float, default=60)
    parser.add_argument("--test-sequence", help="Explicit test backend; never a real basecall")
    args = parser.parse_args()
    if not all(math.isfinite(value) and value > 0 for value in (args.timeout, args.startup_timeout)):
        parser.error("timeouts must be finite and positive")
    client = None
    try:
        info = {"protocol": 1, "backend": "fixture", "python": platform.python_version()}
        if args.test_sequence is None:
            import numpy as np
            from pybasecall_client_lib import __version__
            from pybasecall_client_lib.pyclient import PyBasecallClient
            client = PyBasecallClient(address=args.address, config=args.model,
                                      priority=PyBasecallClient.high_priority,
                                      client_name="adaptive-cr", num_client_threads=1, retries=0,
                                      connection_timeout=max(1, int(args.startup_timeout * 1000)),
                                      query_timeout=max(1, int(args.timeout * 1000)))
            client.connect()
            info.update(backend="dorado", client_version=__version__, numpy=np.__version__, model=args.model)
        else:
            args.test_sequence = sequence_text(args.test_sequence)
        emit(info)
        while True:
            line = sys.stdin.buffer.readline(16385)
            if not line:
                return
            if len(line) > 16384 or not line.endswith(b"\n"):
                raise ValueError("invalid request header")
            request = json.loads(line)
            validate_request(request)
            size = request["bytes"]
            signal = sys.stdin.buffer.read(size)
            if len(signal) != size:
                raise EOFError("truncated signal")
            try:
                seqs = [args.test_sequence] if client is None else basecall(client, request, signal, args.timeout)
                emit({"id": request["id"], "sequences": seqs})
            except Exception as error:
                emit({"id": request["id"], "error": str(error)})
                return  # recycle connection after errors; no stale pending replies
    except Exception as error:
        emit({"protocol": 1, "error": f"{type(error).__name__}: {error}"})
        raise
    finally:
        if client is not None:
            try:
                client.disconnect()
            except Exception as error:
                print(f"Dorado disconnect: {error}", file=sys.stderr)


if __name__ == "__main__":
    main()
