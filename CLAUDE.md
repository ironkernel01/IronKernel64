# CLAUDE.md

Read `AGENTS.md` first: repository map, build and test commands, the rules the tree enforces and where a new feature goes. The design is in `Documentation/ironkernel64_spec.md`.

The rules that matter most:

- Never commit, print or log `fw_1541/netshare_config.h` (network share credentials). Release images use `fw_1541/build.ps1 -Public`.
- Never edit `third_party/`; changes go through deviation entries and `tools/third_party.json`.
- Run `scripts/ik64_host_tests.sh` after firmware changes and `scripts/ik64_regression.ps1` after RTL changes before committing.
