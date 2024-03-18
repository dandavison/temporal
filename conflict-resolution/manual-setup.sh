# These commands have to be run manually, in different terminals.
make start-dependencies-cdc
make install-schema-xdc
# Start two unconnected clusters (see config/development-cluster-*.yaml)
make start-xdc-cluster-a
make start-xdc-cluster-b

source ./lib.sh
# Add cluster b as a remote of a
tctl --address $A admin cluster upsert-remote-cluster --frontend_address $B
# Add cluster a as a remote of b
tctl --address $B admin cluster upsert-remote-cluster --frontend_address $A
# The next command sometimes fails ("Invalid cluster name: cluster-b"). I think we need to wait for something to propagate?
# Register a multi-region namespace
tctl --ns $NS namespace register --global_namespace true --active_cluster cluster-a --clusters cluster-a cluster-b
