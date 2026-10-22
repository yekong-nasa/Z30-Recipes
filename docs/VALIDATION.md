# Validation for 1.0.4

- Swift Package tests: **57 passed, 0 failed**, including complete curve preservation, all six traditional base encoders, batch file import and duplicate handling, invalid-file continuation, mock-camera writes, readback, partial failure, connection reuse and cancellation.
- Public Xcode project: Release iOS build passed with signing disabled.
- Test fixtures: generated from `tools/generate_test_fixtures.py`; no real camera serial number, third-party preset LUT or device backup is included.
- Development-device observations: Standard, Neutral and plain Monochrome writes and full readback succeeded on a Z30 running C 1.20. Some Neutral recipes were also independently checked through camera-generated SD exports.
- Monochrome filter/colored toning, automatic sentinels and the remaining traditional bases need further physical-camera coverage.
- Full Flexible Color rendering/conversion is not implemented.

No personal hardware logs or camera backup files are published. Reproduce software validation using the commands in the README.
