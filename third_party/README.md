# third_party/

This directory holds unmodified upstream code and data. Only this README is committed.

Install or verify the trees with:

```
python -I tools/setup_third_party.py           # fetch and install every entry
python -I tools/setup_third_party.py --check   # verify installed trees, fetch nothing
```

- `tools/third_party.json` pins each entry: upstream URL, commit, the files taken and a
  SHA-256 digest of the installed tree. Setup fails when a fetched tree does not match.
- `tools/third_party/<name>.SOURCE.txt` is the provenance note that setup writes into
  `third_party/<name>/SOURCE.txt`, together with the pin.
- `--mirror NAME=PATH` names another fetch source for an entry. No RTLNet tree is installed here: the
  network core is the netlist `fpga/netlist/ik64_net_core.dcp`, and the shared-machine scripts of the
  private `ironkernel/` repository live in `ironkernel/src` (see `tools/setup_ironkernel.py`).
- Files here are never edited. Project changes to third-party behaviour are recorded as
  `IK64_DEVIATION` entries in `fw_*/DEVIATIONS.md`.

| Entry | Upstream | License |
|---|---|---|
| libsmb2 | Ronnie Sahlberg, libsmb2 | LGPL-2.1-or-later (lib/, include/) |
| open-roms | MEGA65 Open ROMs (character set) | LGPL-3.0-or-later |
| resid | Dag Lem, reSID 0.16 code base | GPL-2.0-or-later |
| dormann | Klaus Dormann, 6502 functional and decimal tests | GPL-3.0 |
