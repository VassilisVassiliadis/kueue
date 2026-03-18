#!/bin/bash
set -e

# Script to test PyTorchJob with AdmissionGatedBy feature

NAMESPACE="vv-testing"
JOB_NAME="pytorch-admission-gated-test"
TIMEOUT=10

echo "=========================================="
echo "PyTorchJob AdmissionGatedBy Test"
echo "=========================================="

# Check if logged into cluster
if ! kubectl get namespace ${NAMESPACE} &> /dev/null; then
    echo "Error: Cannot access namespace ${NAMESPACE}"
    exit 1
fi
oc project ${NAMESPACE}
echo " Using namespace: ${NAMESPACE}"

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up resources..."
    kubectl delete pytorchjob ${JOB_NAME} -n ${NAMESPACE} --ignore-not-found=true
    echo " Cleanup complete"
}

trap cleanup EXIT

# Ensure LocalQueue exists
echo ""
echo "Checking for LocalQueue 'user-queue'..."
if ! kubectl get localqueue user-queue -n ${NAMESPACE} &> /dev/null; then
    echo "Warning: LocalQueue 'user-queue' not found. Creating a basic setup..."
    
    # Create a basic ClusterQueue and LocalQueue for testing
    cat <<EOF | kubectl apply -f -
apiVersion: kueue.x-k8s.io/v1beta2
kind: ResourceFlavor
metadata:
  name: default-flavor
---
apiVersion: kueue.x-k8s.io/v1beta2
kind: ClusterQueue
metadata:
  name: cluster-queue
spec:
  namespaceSelector: {}
  resourceGroups:
  - coveredResources: ["cpu", "memory", "nvidia.com/gpu"]
    flavors:
    - name: default-flavor
      resources:
      - name: "cpu"
        nominalQuota: 100
      - name: "memory"
        nominalQuota: 1000Gi
      - name: "nvidia.com/gpu"
        nominalQuota: 10
---
apiVersion: kueue.x-k8s.io/v1beta2
kind: LocalQueue
metadata:
  namespace: ${NAMESPACE}
  name: user-queue
spec:
  clusterQueue: cluster-queue
EOF
    echo " Created basic queue setup"
else
    echo " LocalQueue 'user-queue' exists"
fi

# Create PyTorchJob with AdmissionGatedBy annotation
echo ""
echo "=========================================="
echo "Step 1: Creating PyTorchJob with AdmissionGatedBy"
echo "=========================================="

cat <<EOF | kubectl apply -f -
apiVersion: kubeflow.org/v1
kind: PyTorchJob
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
  annotations:
    kueue.x-k8s.io/admission-gated-by: "test.example.com/gate"
  labels:
    kueue.x-k8s.io/queue-name: user-queue
spec:
  pytorchReplicaSpecs:
    Master:
      replicas: 1
      restartPolicy: OnFailure
      template:
        spec:
          containers:
          - name: pytorch
            image: ubuntu:latest
            command:
            - /bin/bash
            - -c
            - "echo hello world"
            resources:
              requests:
                nvidia.com/gpu: "1"
              limits:
                nvidia.com/gpu: "1"
EOF

echo " PyTorchJob created with AdmissionGatedBy annotation"

# Get the workload name
echo ""
echo "Waiting for Workload to be created..."
sleep 2

WORKLOAD_NAME=""
for i in {1..30}; do
    # Find workload by owner reference to the PyTorchJob
    WORKLOAD_NAME=$(kubectl get workloads -n ${NAMESPACE} -o json 2>/dev/null | jq -r ".items[] | select(.metadata.ownerReferences[]? | select(.kind==\"PyTorchJob\" and .name==\"${JOB_NAME}\")) | .metadata.name" | head -n 1)
    if [ -n "$WORKLOAD_NAME" ]; then
        break
    fi
    sleep 1
done

if [ -z "$WORKLOAD_NAME" ]; then
    echo "Error: Workload not created"
    exit 1
fi

echo " Workload created: ${WORKLOAD_NAME}"

# Monitor workload - should remain inadmissible
echo ""
echo "=========================================="
echo "Step 2: Verifying Workload remains inadmissible"
echo "=========================================="
echo "Monitoring for ${TIMEOUT} seconds..."

START_TIME=$(date +%s)
INADMISSIBLE_CONFIRMED=false

while [ $(($(date +%s) - START_TIME)) -lt ${TIMEOUT} ]; do
    # Check if workload has QuotaReserved condition with status False and reason AdmissionGated
    QUOTA_RESERVED=$(kubectl get workload ${WORKLOAD_NAME} -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="QuotaReserved")].status}' 2>/dev/null || echo "")
    QUOTA_REASON=$(kubectl get workload ${WORKLOAD_NAME} -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="QuotaReserved")].reason}' 2>/dev/null || echo "")
    
    if [ "$QUOTA_RESERVED" = "False" ] && [ "$QUOTA_REASON" = "AdmissionGated" ]; then
        INADMISSIBLE_CONFIRMED=true
        echo "   Workload is inadmissible (QuotaReserved=False, reason=AdmissionGated)"
    else
        echo "  - Workload status: QuotaReserved=${QUOTA_RESERVED}, reason=${QUOTA_REASON}"
    fi
    
    # Check admission status
    ADMITTED=$(kubectl get workload ${WORKLOAD_NAME} -n ${NAMESPACE} -o jsonpath='{.status.admission}' 2>/dev/null || echo "")
    if [ -n "$ADMITTED" ]; then
        echo "Error: Workload was admitted while gate was present!"
        exit 1
    fi
    
    sleep 2
done

if [ "$INADMISSIBLE_CONFIRMED" = "true" ]; then
    echo " Workload remained inadmissible for ${TIMEOUT} seconds as expected"
else
    echo "Warning: Could not confirm inadmissible status, but workload was not admitted"
fi

# Patch PyTorchJob to remove annotation and GPU requirement
echo ""
echo "=========================================="
echo "Step 3: Removing AdmissionGatedBy and GPU requirement"
echo "=========================================="

kubectl patch pytorchjob ${JOB_NAME} -n ${NAMESPACE} --type=json -p='[
  {"op": "remove", "path": "/metadata/annotations/kueue.x-k8s.io~1admission-gated-by"},
  {"op": "replace", "path": "/spec/pytorchReplicaSpecs/Master/template/spec/containers/0/resources/requests", "value": {}},
  {"op": "replace", "path": "/spec/pytorchReplicaSpecs/Master/template/spec/containers/0/resources/limits", "value": {}}
]'

echo " PyTorchJob patched"

# The workload may be recreated, so we need to find it again
echo ""
echo "Waiting for Workload to be updated/recreated..."
sleep 3

NEW_WORKLOAD_NAME=""
for i in {1..30}; do
    # Find workload by owner reference to the PyTorchJob
    NEW_WORKLOAD_NAME=$(kubectl get workloads -n ${NAMESPACE} -o json 2>/dev/null | jq -r ".items[] | select(.metadata.ownerReferences[]? | select(.kind==\"PyTorchJob\" and .name==\"${JOB_NAME}\")) | .metadata.name" | head -n 1)
    if [ -n "$NEW_WORKLOAD_NAME" ]; then
        break
    fi
    sleep 1
done

if [ -z "$NEW_WORKLOAD_NAME" ]; then
    echo "Error: Workload not found after patch"
    exit 1
fi

echo " Monitoring workload: ${NEW_WORKLOAD_NAME}"

# Monitor workload - should become admissible
echo ""
echo "=========================================="
echo "Step 4: Verifying Workload becomes admissible"
echo "=========================================="
echo "Monitoring for ${TIMEOUT} seconds..."

START_TIME=$(date +%s)
ADMISSIBLE_CONFIRMED=false

while [ $(($(date +%s) - START_TIME)) -lt ${TIMEOUT} ]; do
    # Check if workload is admissible (no AdmissionGated reason, but not yet admitted)
    QUOTA_RESERVED=$(kubectl get workload ${NEW_WORKLOAD_NAME} -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="QuotaReserved")].status}' 2>/dev/null || echo "")
    QUOTA_REASON=$(kubectl get workload ${NEW_WORKLOAD_NAME} -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="QuotaReserved")].reason}' 2>/dev/null || echo "")
    ADMITTED=$(kubectl get workload ${NEW_WORKLOAD_NAME} -n ${NAMESPACE} -o jsonpath='{.status.admission}' 2>/dev/null || echo "")
    
    # Admissible means: not gated AND not yet admitted (or could be admitted)
    if [ "$QUOTA_REASON" != "AdmissionGated" ] && [ -n "$QUOTA_REASON" ]; then
        ADMISSIBLE_CONFIRMED=true
        echo "   Workload is now admissible (QuotaReserved=${QUOTA_RESERVED}, reason=${QUOTA_REASON})"
        break
    else
        echo "  - Waiting... QuotaReserved=${QUOTA_RESERVED}, reason=${QUOTA_REASON}, admitted=${ADMITTED}"
    fi
    
    sleep 2
done

if [ "$ADMISSIBLE_CONFIRMED" = "false" ]; then
    echo "Error: Workload did not become admissible within ${TIMEOUT} seconds"
    exit 1
fi

echo " Workload became admissible within ${TIMEOUT} seconds"

# Monitor workload - should become admitted
echo ""
echo "=========================================="
echo "Step 5: Verifying Workload becomes admitted"
echo "=========================================="
echo "Monitoring for ${TIMEOUT} seconds..."

START_TIME=$(date +%s)
ADMITTED_CONFIRMED=false

while [ $(($(date +%s) - START_TIME)) -lt ${TIMEOUT} ]; do
    ADMITTED=$(kubectl get workload ${NEW_WORKLOAD_NAME} -n ${NAMESPACE} -o jsonpath='{.status.admission}' 2>/dev/null || echo "")
    
    if [ -n "$ADMITTED" ]; then
        ADMITTED_CONFIRMED=true
        echo "   Workload is admitted"
        break
    else
        echo "  - Waiting for admission..."
    fi
    
    sleep 2
done

if [ "$ADMITTED_CONFIRMED" = "false" ]; then
    echo "Error: Workload was not admitted within ${TIMEOUT} seconds"
    exit 1
fi

echo " Workload was admitted within ${TIMEOUT} seconds"

# Monitor PyTorchJob - should become unsuspended
echo ""
echo "=========================================="
echo "Step 6: Verifying PyTorchJob becomes unsuspended"
echo "=========================================="
echo "Monitoring for ${TIMEOUT} seconds..."

START_TIME=$(date +%s)
UNSUSPENDED_CONFIRMED=false

while [ $(($(date +%s) - START_TIME)) -lt ${TIMEOUT} ]; do
    SUSPENDED=$(kubectl get pytorchjob ${JOB_NAME} -n ${NAMESPACE} -o jsonpath='{.spec.runPolicy.suspend}' 2>/dev/null || echo "true")
    
    if [ "$SUSPENDED" = "false" ] || [ -z "$SUSPENDED" ]; then
        UNSUSPENDED_CONFIRMED=true
        echo "   PyTorchJob is unsuspended"
        break
    else
        echo "  - Waiting for unsuspend... (suspend=${SUSPENDED})"
    fi
    
    sleep 2
done

if [ "$UNSUSPENDED_CONFIRMED" = "false" ]; then
    echo "Error: PyTorchJob was not unsuspended within ${TIMEOUT} seconds"
    exit 1
fi

echo " PyTorchJob was unsuspended within ${TIMEOUT} seconds"

# Summary
echo ""
echo "=========================================="
echo "TEST PASSED "
echo "=========================================="
echo "Summary:"
echo "  1.  PyTorchJob created with AdmissionGatedBy annotation"
echo "  2.  Workload remained inadmissible while gate was present"
echo "  3.  AdmissionGatedBy annotation removed and GPU requirement set to 0"
echo "  4.  Workload became admissible within ${TIMEOUT} seconds"
echo "  5.  Workload was admitted within ${TIMEOUT} seconds"
echo "  6.  PyTorchJob was unsuspended within ${TIMEOUT} seconds"
echo ""
echo "All test steps completed successfully!"

