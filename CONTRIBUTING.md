# Contributing

Contributions are accepted under the [Apache License 2.0](LICENSE). By intentionally submitting a contribution for inclusion in AutoPiOverclock, you agree that it is licensed under those terms, as described in Section 5 of the license.

Patches must preserve the safety invariants: no permanent clock writes during testing, no silent EEPROM update, no stale-kernel-log attribution, no claimed pass without a real GPU workload, and verified normal recovery after every candidate.

Run `make test` and `make lint` before proposing a change. Add a fixture for every new failure signature.
