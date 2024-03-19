NS=ns1
A=localhost:7233
B=localhost:8233
WID=my-workflow-id

DYNAMIC_CONFIG=../../temporal/config/dynamicconfig/development-cass.yaml
[ -e $DYNAMIC_CONFIG ] || {
    echo "This script must be run from the conflict-resolution directory" >&2
}

cr-start-workflow() {
    local addr=$1
    [ -n "$addr" ] || {
        echo "cr-start-workflow address" >&2
        return 1
    }
    temporal workflow -n $NS --address $addr start --task-queue my-task-queue -w $WID --type my-workflow
}

cr-terminate-workflow() {
    local addr=$1
    [ -n "$addr" ] || {
        echo "cr-terminate-workflow address" >&2
        return 1
    }
    temporal workflow -n $NS --address $addr terminate -w $WID
}

cr-send-signal() {
    local addr=$1
    local input=$2
    [ -n "$addr" ] && [ -n "$input" ] || {
        echo "cr-send-signal address input" >&2
        return 1
    }
    temporal workflow -n $NS --address $addr signal -w $WID --name my-signal --input "\"$input\""
}

cr-run-worker() {
    local addr=$1
    [ -n "$addr" ] || {
        echo "cr-run-worker address" >&2
        return 1
    }
    ../../sdk-python/.venv/bin/python ./conflict_resolution.py $addr
}

cr-send-update() {
    local addr=$1
    local input=$2
    [ -n "$addr" ] && [ -n "$input" ] || {
        echo "cr-send-update address input" >&2
        return 1
    }
    temporal workflow -n $NS --address $addr update -w $WID --name my-update --input "\"$input\""
}

cr-set-active() {
    local addr=$1
    local cluster=$2
    [ -n "$addr" ] && [ -n "$cluster" ] && [[ $cluster = cluster-a || $cluster = cluster-b ]] || {
        echo "cr-set-active address cluster-a/b" >&2
        return 1
    }
    tctl --address $addr --ns $NS namespace update --active_cluster $cluster
    cr-describe-namespace
}

cr-describe-namespace() {
    temporal --address $A operator namespace describe $NS | grep -F ReplicationConfig.ActiveClusterName
    temporal --address $B operator namespace describe $NS | grep -F ReplicationConfig.ActiveClusterName
    cr-query-history-replication
    cr-query-namespace-replication
}

# https://github.com/dandavison/temporalio-temporal/tree/simulate-conflict-resolution
cr-enable-history-replication() {
    -cr-set-history-replication-max-id -1
}

cr-disable-history-replication() {
    -cr-set-history-replication-max-id 1
}

cr-enable-namespace-replication() {
    -cr-set-namespace-replication true
}

cr-disable-namespace-replication() {
    -cr-set-namespace-replication false
}

-cr-set-namespace-replication() {
    local value=$1
    sed -i '/worker.enableNamespaceReplication:/,/value:/ s/value: .*/value: '$value'/' $DYNAMIC_CONFIG
    cr-query-namespace-replication
    echo -n "\nWaiting 5s for dynamic config change..."
    sleep 5
    echo
}

cr-query-namespace-replication() {
    sed -n '/worker.enableNamespaceReplication:/,/value:/p' $DYNAMIC_CONFIG
}

-cr-set-history-replication-max-id() {
    local id=$1
    sed -i '/history.ReplicationMaxEventId:/,/value:/ s/value: .*/value: '$id'/' $DYNAMIC_CONFIG
    cr-query-history-replication
    echo -n "\nWaiting 5s for dynamic config change..."
    sleep 5
    echo
}

cr-query-history-replication() {
    sed -n '/history.ReplicationMaxEventId:/,/value:/p' $DYNAMIC_CONFIG
}

cr-list-events-for-cluster() {
    local addr=$1
    [ -n "$addr" ] || {
        echo "cr-list-events-for-cluster" >&2
        return 1
    }
    temporal workflow -n $NS --address $addr show --output json -w $WID |
        jq -r '.events[] | "(\(.eventId), \(.version)) \(.eventType)  \(.workflowExecutionSignaledEventAttributes.input[0]) \(.workflowExecutionUpdateAcceptedEventAttributes.acceptedRequest.input.args[0])"'
}

cr-list-events() {
    echo "cluster-a events:"
    cr-list-events-for-cluster $A
    echo
    echo "cluster-b events:"
    cr-list-events-for-cluster $B
}
