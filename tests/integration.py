#!/usr/bin/env python3
"""Real gRPC + minimap2 with an explicitly synthetic basecall backend."""
import argparse
from collections import Counter
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time

from stream_end_proxy import StreamEndProxy

ROOT = Path(__file__).resolve().parents[1]


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def validate_action_accounting(decisions, acks, end):
    """Every action must be acknowledged exactly once or remain unresolved."""
    sent = {row['action_id']: row for row in decisions}
    assert len(sent) == len(decisions), 'duplicate decision action ID'
    acknowledged = set()
    for ack in acks:
        action_id = ack['action_id']
        assert action_id in sent, ('unknown acknowledgment', action_id)
        assert action_id not in acknowledged, ('duplicate acknowledgment', action_id)
        decision = sent[action_id]
        assert (ack['channel'], ack['read_id']) == (decision['channel'], decision['read_id']), ack
        assert ack['status'] == 0, ack
        acknowledged.add(action_id)
    unresolved = sent.keys() - acknowledged
    assert end['unacknowledged_actions'] == len(unresolved), ('unaccounted actions', end, unresolved)
    # Unresolved accepts retain reservations, never confirmed successes.
    for field, action_ids in (('confirmed', acknowledged), ('pending', unresolved)):
        expected = Counter(sent[action_id]['group'] for action_id in action_ids
                           if sent[action_id].get('group'))
        actual = end[field]
        groups = actual.keys() | expected.keys()
        assert all(actual.get(group, 0) == expected[group] for group in groups), (field, actual, expected)
    return unresolved


def run(binary, mode, channels=16):
    with tempfile.TemporaryDirectory(prefix='adaptive-integration-') as directory:
        tmp = Path(directory)
        port = free_port()
        reference = str(ROOT / 'examples/reference.fa')
        server_config = dict(samples=[dict(path=reference, circular=True)], channels=channels,
                             workers=4, duration_seconds=2.0, chunk_ms=100, mean_read_length=20000,
                             manager_port=free_port(), position_port=port, output=str(tmp / 'reads'))
        if mode in ('shutdown', 'disconnect'):
            server_config['duration_seconds'] = 30.0
        if mode == 'stream_end':
            server_config['read_length_sigma'] = 0.0
        if mode == 'tls':
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                            '-keyout', str(tmp / 'key.pem'), '-out', str(tmp / 'cert.pem'),
                            '-days', '1', '-subj', '/CN=localhost', '-addext',
                            'subjectAltName=DNS:localhost,IP:127.0.0.1'], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            server_config.update(tls_cert=str(tmp / 'cert.pem'), tls_key=str(tmp / 'key.pem'))
        (tmp / 'server.json').write_text(json.dumps(server_config))
        sequence = json.loads((ROOT / 'examples/replay.jsonl').read_text().splitlines()[1])['sequences'][0]
        config = dict(reference=reference, targets=['host' if mode == 'reject' else 'virus'],
                      host='localhost', port=port, tls=mode == 'tls', last_channel=channels,
                      workers=4, min_samples=500, step_samples=500, max_samples=10000,
                      deadline_ms=1500, bridge_timeout_ms=3000, observe=mode == 'observe',
                      allow_test_bridge=True, fixture_sequence=sequence, log=str(tmp / 'audit.jsonl'),
                      quota=1 if mode in ('quota', 'stream_end') else 0)
        if mode == 'stream_end':
            # All first prefixes arrive at the final tick (2 s * 5 kHz).
            config.update(min_samples=10000)
        if mode == 'tls':
            config['ca_file'] = str(tmp / 'cert.pem')
        if mode in ('deadline', 'worker_error'):
            bridge = (ROOT / 'scripts/dorado_bridge.py').read_text()
            if mode == 'deadline':
                bridge = bridge.replace('seqs = [args.test_sequence]', 'time.sleep(0.25)\n                seqs = [args.test_sequence]')
                config.update(deadline_ms=50)
            else:
                bridge = bridge.replace('seqs = [args.test_sequence]', 'raise RuntimeError("injected backend failure")\n                seqs = [args.test_sequence]')
            (tmp / 'bridge.py').write_text(bridge)
            config['bridge_script'] = str(tmp / 'bridge.py')
        (tmp / 'client.json').write_text(json.dumps(config))
        with (tmp / 'server.log').open('w+') as log:
            server = subprocess.Popen([str(binary), '-c', str(tmp / 'server.json')], stdout=log, stderr=log)
            proxy = None
            try:
                for _ in range(100):
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=0.1):
                            break
                    except OSError:
                        time.sleep(0.05)
                if mode == 'stream_end':
                    proxy = StreamEndProxy(port)
                    config['port'] = proxy.port
                    (tmp / 'client.json').write_text(json.dumps(config))
                started = time.monotonic()
                command = [str(ROOT / 'bin/adaptive'), '-c', str(tmp / 'client.json')]
                if mode in ('shutdown', 'disconnect'):
                    process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE,
                                               stderr=subprocess.PIPE, text=True)
                    try:
                        for _ in range(250):
                            audit = tmp / 'audit.jsonl'
                            if audit.exists() and '"event":"decision"' in audit.read_text():
                                break
                            if process.poll() is not None:
                                raise AssertionError('client exited before first decision')
                            time.sleep(0.02)
                        else:
                            raise AssertionError('no decision before shutdown test')
                        if mode == 'shutdown':
                            process.terminate()
                        else:
                            server.kill()
                            server.wait(timeout=5)
                        stdout, stderr = process.communicate(timeout=10)
                        client = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
                    finally:
                        if process.poll() is None:
                            process.kill()
                            process.communicate()
                else:
                    client = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=20)
                if (client.returncode != 0) != (mode == 'disconnect'):
                    log.seek(0)
                    raise AssertionError(f'{mode}: {client.stderr}\n{log.read()}')
                events = [json.loads(line) for line in (tmp / 'audit.jsonl').read_text().splitlines()]
                decisions = [row for row in events if row['event'] == 'decision']
                acks = [row for row in events if row['event'] == 'ack']
                assert decisions, mode
                assert events[0]['backend'] == 'fixture'
                assert events[-1]['event'] == 'end'
                if mode == 'shutdown':
                    assert events[-1]['outcome'] == 'signal'
                if mode == 'disconnect':
                    assert events[-1]['outcome'] == 'error'
                    assert any(row['event'] == 'error' for row in events)
                elif mode != 'shutdown':
                    assert events[-1]['outcome'] == 'stream_end'
                assert len({row['read_id'] for row in decisions}) == len(decisions)
                if mode == 'observe':
                    assert not acks
                    assert events[-1]['unacknowledged_actions'] == 0
                else:
                    # The final signal can produce decisions after Moleflow
                    # ends its RPC. Account for them; do not require late ACKs.
                    validate_action_accounting(decisions, acks, events[-1])
                    if mode not in ('shutdown', 'disconnect', 'stream_end'):
                        assert acks, 'no device action was acknowledged'
                choices = [row['choice'] for row in decisions]
                if mode == 'reject':
                    assert set(choices) == {'Reject'}
                    assert any(json.loads(row)['end_reason'] == 'unblock_mux_change'
                               for row in (tmp / 'reads/reads.jsonl').read_text().splitlines())
                elif mode in ('quota', 'stream_end'):
                    assert choices.count('Accept') == 1 and 'Reject' in choices
                    if mode == 'stream_end':
                        assert not acks
                        assert len(decisions) == channels
                        assert events[-1]['unacknowledged_actions'] == channels
                        assert events[-1]['confirmed'].get('virus', 0) == 0
                        assert events[-1]['pending']['virus'] == 1
                    else:
                        assert events[-1]['confirmed']['virus'] == 1
                else:
                    assert set(choices) == {'Accept'}, choices
                if mode == 'deadline':
                    assert all(row['reason'] == 'decision_deadline' for row in decisions)
                    assert any(row['event'] == 'stale_result' for row in events)
                if mode == 'worker_error':
                    assert all(row['reason'] == 'worker_error' for row in decisions)
                print(json.dumps(dict(mode=mode, channels=channels, decisions=len(decisions),
                                      acks=len(acks), unacknowledged=events[-1]['unacknowledged_actions'],
                                      deadline_fallbacks=sum(row['reason'] == 'decision_deadline' for row in decisions),
                                      elapsed_s=round(time.monotonic()-started, 3))), flush=True)
            finally:
                if proxy:
                    proxy.close()
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--moleflow', required=True, type=Path)
    args = parser.parse_args()
    for case in ('accept', 'reject', 'quota', 'observe', 'tls', 'deadline', 'worker_error', 'shutdown', 'disconnect', 'stream_end'):
        run(args.moleflow.resolve(), case)
    run(args.moleflow.resolve(), 'quota', channels=512)
