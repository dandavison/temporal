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

cr-failover() {
    local cluster=$1
    [ -n "$cluster" ] && [[ $cluster = cluster-a || $cluster = cluster-b ]] || {
        echo "cr-failover cluster-a/b" >&2
        return 1
    }
    tctl --ns $NS namespace update --active_cluster $cluster
    cr-describe-namespace
}

cr-describe-namespace() {
    temporal operator namespace describe $NS | grep -F ReplicationConfig.ActiveClusterName
}

# https://github.com/dandavison/temporalio-temporal/tree/simulate-conflict-resolution
cr-enable-replication() {
    cr-set-replication-max-id -1
}

cr-disable-replication() {
    cr-set-replication-max-id 1
}

cr-set-replication-max-id() {
    local id=$1
    [ -n "$id" ] || {
        echo "cr-set-replication-max-id" >&2
        return 1
    }
    sed -i '/history.ReplicationMaxEventId:/,/value:/ s/value: .*/value: '$id'\n/' $DYNAMIC_CONFIG
    cr-query-replication-max-id
    echo -n "\nWaiting 5s for dynamic config change..."
    sleep 5
    echo
}

cr-query-replication-max-id() {
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
