[ -e ./lib.sh ] || {
    echo "This script must be run from the conflict-resolution directory" >&2
    exit 1
}
source ./lib.sh

# Try to simulate a conflict.
cr-start-workflow $A

cr-disable-namespace-replication
cr-disable-history-replication

cr-set-active $B cluster-b

cr-send-signal $A A1
cr-send-signal $B B1

cr-enable-namespace-replication
cr-enable-history-replication

# cluster-a events:
# (1, 1) EVENT_TYPE_WORKFLOW_EXECUTION_STARTED  null null
# (2, 1) EVENT_TYPE_WORKFLOW_TASK_SCHEDULED  null null
# (3, 1) EVENT_TYPE_WORKFLOW_EXECUTION_SIGNALED  A1 null

# cluster-b events:
# (1, 1) EVENT_TYPE_WORKFLOW_EXECUTION_STARTED  null null
# (2, 1) EVENT_TYPE_WORKFLOW_TASK_SCHEDULED  null null
# (3, 2) EVENT_TYPE_WORKFLOW_EXECUTION_SIGNALED  B1 null

cr-set-active $B cluster-b

cr-send-signal $A A2

# A error
# Resend events due to missing mutable state

# B reapplies event

# cluster-a events:
# (1, 1) EVENT_TYPE_WORKFLOW_EXECUTION_STARTED  null null
# (2, 1) EVENT_TYPE_WORKFLOW_TASK_SCHEDULED  null null
# (3, 1) EVENT_TYPE_WORKFLOW_EXECUTION_SIGNALED  A1 null
# (4, 1) EVENT_TYPE_WORKFLOW_EXECUTION_SIGNALED  A2 null

# cluster-b events:
# (1, 1) EVENT_TYPE_WORKFLOW_EXECUTION_STARTED  null null
# (2, 1) EVENT_TYPE_WORKFLOW_TASK_SCHEDULED  null null
# (3, 2) EVENT_TYPE_WORKFLOW_EXECUTION_SIGNALED  B1 null
# (4, 2) EVENT_TYPE_WORKFLOW_EXECUTION_SIGNALED  A1 null
# (5, 2) EVENT_TYPE_WORKFLOW_EXECUTION_SIGNALED  A2 null
