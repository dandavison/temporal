This directory contains tools for simulating conflict resolution during replication.

First checkout the branch [`simulate-conflict-resolution`](https://github.com/dandavison/temporalio-temporal/tree/simulate-conflict-resolution), and manually run the steps in `manual-setup.sh`.

Now `source lib.sh` and use the utilities to create history events in the two clusters. Use `cr-<TAB>` to see the available shell functions.

`conflict_resolution.sh` contains an example session.