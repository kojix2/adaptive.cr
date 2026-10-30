# adaptive-cr 0.3.0 validation

2026-10-30, Linux x86_64, Crystal 1.22.0, native POD5 0.3.49.

- Crystal: 23 specs, zero failures (docs/spec-v0.3.0.txt).
- Python bridge: 13 tests passed (docs/python-v0.3.0.txt).
- Ameba: 23 source/spec/example files, zero failures; formatting passed.
- Configuration validation and sequence replay produced Reject / Accept / Reject.
- Updated Moleflow integration: 10 scenarios passed, including accept, reject,
  quota, observe, TLS, deadline, worker failure, shutdown, disconnect and
  512-channel quota (docs/integration-v0.3.0.jsonl).
- At disconnection/run end, unresolved actions are recorded as unacknowledged;
  successful test completion does not imply that all operations were acknowledged.
- Official Python POD5 reader independently confirmed exported ADC/calibration
  from the official v6 fixture. The exported files passed --check-signal using
  the explicitly synthetic backend (not a real Dorado server).
- POD5 export tests preserve ADC, calibration, sample rate and start sample;
  cover UUID selection, length truncation, existing-output protection and rollback.

The integration basecaller is an explicitly synthetic fixture. No GPU Dorado
server or physical MinKNOW device was tested. No new speed/RSS benchmark is
claimed. POD5 diagnostic extraction decodes a full read and rejects reads larger
than 10 million samples before allocating its signal buffer.
