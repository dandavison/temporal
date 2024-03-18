NS=ns1
A=localhost:7233
B=localhost:8233
WID=my-workflow-id

start-workflow() {
    local addr=$1
    temporal workflow -n $NS --address $addr start --task-queue my-task-queue -w $WID --type my-workflow
}

terminate-workflow() {
    local addr=$1
    temporal workflow -n $NS --address $addr terminate -w $WID
}

send-signal() {
    local addr=$1
    local input=$2
    temporal workflow -n $NS --address $addr signal -w $WID --name my-signal --input "\"$input\""
}

run-worker() {
    local addr=$1
    ../sdk-python/.venv/bin/python ./conflict_resolution/conflict_resolution.py $addr
}

send-update() {
    local addr=$1
    local input=$2
    temporal workflow -n $NS --address $addr update -w $WID --name my-update --input "\"$input\""
}

failover() {
    local cluster=$1
    tctl --ns $NS namespace update --active_cluster $cluster
}

# history.ReplicationMaxEventId dynamic config entry added in
# https://github.com/temporalio/temporal/compare/main...dandavison:temporalio-temporal:update-reapply-conflict-resolution
dc-enable-replication() {
    dc-set-replication-max-id -1
}

dc-disable-replication() {
    dc-set-replication-max-id 1
}

dc-set-replication-max-id() {
    local id=$1
    sed -i '/history.ReplicationMaxEventId:/,/value:/ s/value: .*/value: '$id'\n/' config/dynamicconfig/development-cass.yaml
    dc-query-replication-max-id
    echo -n "\nWaiting 5s for dynamic config change..."
    sleep 5
    echo
}

dc-query-replication-max-id() {
    sed -n '/history.ReplicationMaxEventId:/,/value:/p' config/dynamicconfig/development-cass.yaml
}

list-events() {
    local addr=$1
    temporal workflow -n $NS --address $addr show --output json -w $WID |
        jq -r '.events[] | "(\(.eventId), \(.version)) \(.eventType)  \(.workflowExecutionSignaledEventAttributes.input[0]) \(.workflowExecutionUpdateAcceptedEventAttributes.acceptedRequest.input.args[0])"'
}

list-events-both-clusters() {
    echo "cluster-a events:"
    list-events $A
    echo
    echo "cluster-b events:"
    list-events $B
}

# Setup
# These commands have to be run manually, in different terminals.
if false; then
    make start-dependencies-cdc
    make install-schema-xdc

    # Start two unconnected clusters (see config/development-cluster-*.yaml)
    make start-xdc-cluster-a
    make start-xdc-cluster-b

    # Add cluster b as a remote of a
    tctl --address $A admin cluster upsert-remote-cluster --frontend_address $B
    # Add cluster a as a remote of b
    tctl --address $B admin cluster upsert-remote-cluster --frontend_address $A

    # The next command sometimes fails ("Invalid cluster name: cluster-b"). I think we need to wait for something to propagate?
    sleep 60
    # Register a multi-region namespace
    tctl --ns $NS namespace register --global_namespace true --active_cluster cluster-a --clusters cluster-a cluster-b
fi

# Simulate a conflict. We will send a signal to a non-active cluster.
if false; then

    start-workflow $A
    dc-set-replication-max-id 2
    send-signal $A A1
    list-events-both-clusters
    failover cluster-b
    dc-set-replication-max-id 3

    # failover

    # simulate conflict
    # re-enable replication
    send-signal $B 2
fi
