[ -e ./lib.sh ] || {
    echo "This script must be run from the conflict-resolution directory" >&2
    exit 1
}
source ./lib.sh

# Try to simulate a conflict.
cr-start-workflow $A
cr-disable-replication
cr-failover cluster-b
cr-send-signal $B B1
cr-failover cluster-a
cr-enable-replication
cr-send-signal $A A1
cr-list-events
cluster-a events:
# (1, 101) EVENT_TYPE_WORKFLOW_EXECUTION_STARTED  null null
# (2, 101) EVENT_TYPE_WORKFLOW_TASK_SCHEDULED  null null
# (3, 101) EVENT_TYPE_WORKFLOW_EXECUTION_SIGNALED  B1 null
# (4, 201) EVENT_TYPE_WORKFLOW_EXECUTION_SIGNALED  A1 null

# cluster-b events:
# (1, 101) EVENT_TYPE_WORKFLOW_EXECUTION_STARTED  null null
# (2, 101) EVENT_TYPE_WORKFLOW_TASK_SCHEDULED  null null
# (3, 101) EVENT_TYPE_WORKFLOW_EXECUTION_SIGNALED  B1 null
# (4, 201) EVENT_TYPE_WORKFLOW_EXECUTION_SIGNALED  A1 null
