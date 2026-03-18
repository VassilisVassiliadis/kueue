#!/bin/bash
set -e

# Script to build and deploy Kueue with AdmissionGatedBy feature on OpenShift

KUEUE_NAMESPACE="kueue-system"
TEST_NAMESPACE="vv-testing"
FEATURE_GATES="AdmissionGatedBy=true"
ADMISSION_GATED_BY=true

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-admission-gated-by)
            ADMISSION_GATED_BY=false
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --no-admission-gated-by    Disable the AdmissionGatedBy feature gate"
            echo "  -h, --help                 Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Update feature gates based on flag
if [ "$ADMISSION_GATED_BY" = true ]; then
    echo "AdmissionGatedBy feature gate will be ENABLED"
else
    FEATURE_GATES=""
    echo "AdmissionGatedBy feature gate will be DISABLED"
fi

echo "=========================================="
echo "Kueue Deployment Script for OpenShift"
echo "=========================================="

# Check if logged into OpenShift
if ! oc whoami &> /dev/null; then
    echo "Error: Not logged into OpenShift cluster"
    exit 1
fi

echo " Logged into OpenShift as: $(oc whoami)"
echo " Current cluster: $(oc whoami --show-server)"

# Verify/create Kueue namespace
if ! oc get namespace ${KUEUE_NAMESPACE} &> /dev/null; then
    echo "Creating Kueue namespace: ${KUEUE_NAMESPACE}"
    oc create namespace ${KUEUE_NAMESPACE}
fi

# Verify test namespace exists
if ! oc get namespace ${TEST_NAMESPACE} &> /dev/null; then
    echo "Error: Test namespace ${TEST_NAMESPACE} does not exist"
    exit 1
fi

echo " Using Kueue namespace: ${KUEUE_NAMESPACE}"
echo " Using test namespace: ${TEST_NAMESPACE}"

# Use OpenShift internal registry (nodes trust this by default)
REGISTRY="image-registry.openshift-image-registry.svc:5000"
EXTERNAL_REGISTRY=$(oc get route default-route -n openshift-image-registry --template='{{ .spec.host }}' 2>/dev/null || echo "")

if [ -z "$EXTERNAL_REGISTRY" ]; then
    echo "Warning: Could not find exposed registry route"
    EXTERNAL_REGISTRY="${REGISTRY}"
fi

IMAGE_REPO="${REGISTRY}/${KUEUE_NAMESPACE}/kueue"
IMAGE_TAG="admissiongatedby"
FULL_IMAGE="${IMAGE_REPO}:${IMAGE_TAG}"

echo ""
echo "=========================================="
echo "Building Kueue Container"
echo "=========================================="
echo "Image: ${FULL_IMAGE}"

# Build the container image for host platform
echo "Building image..."
make image-build PLATFORMS="linux/amd64" IMAGE_TAG="${FULL_IMAGE}" PUSH=--load

echo ""
echo "=========================================="
echo "Pushing to OpenShift Registry"
echo "=========================================="

# Create ImageStream if it doesn't exist
echo "Creating ImageStream if needed..."
oc create imagestream kueue -n ${KUEUE_NAMESPACE} 2>/dev/null || echo "ImageStream already exists"

# Login to OpenShift registry with Docker (use external route for push)
echo "Logging into OpenShift registry..."
OC_TOKEN=$(oc whoami -t)
echo "${OC_TOKEN}" | docker login -u $(oc whoami) --password-stdin ${EXTERNAL_REGISTRY}

# Tag image for external registry if different
if [ "${REGISTRY}" != "${EXTERNAL_REGISTRY}" ]; then
    EXTERNAL_IMAGE="${EXTERNAL_REGISTRY}/${KUEUE_NAMESPACE}/kueue:${IMAGE_TAG}"
    echo "Tagging image for external registry..."
    docker tag "${FULL_IMAGE}" "${EXTERNAL_IMAGE}"
    PUSH_IMAGE="${EXTERNAL_IMAGE}"
else
    PUSH_IMAGE="${FULL_IMAGE}"
fi

echo "Pushing image to registry..."
docker push "${PUSH_IMAGE}"

echo ""
echo "=========================================="
echo "Preparing for Deployment"
echo "=========================================="

# Delete problematic CRDs that have version migration issues
echo "Checking for CRDs with version migration issues..."
kubectl delete crd cohorts.kueue.x-k8s.io --ignore-not-found=true
kubectl delete crd topologies.kueue.x-k8s.io --ignore-not-found=true

# Delete existing webhook configurations to avoid endpoint errors during deployment
echo "Removing existing webhook configurations..."
kubectl delete validatingwebhookconfiguration kueue-validating-webhook-configuration --ignore-not-found=true
kubectl delete mutatingwebhookconfiguration kueue-mutating-webhook-configuration --ignore-not-found=true

echo ""
echo "=========================================="
echo "Setting up Image Pull Permissions"
echo "=========================================="

# Allow the default service account to pull images from the namespace
echo "Granting image pull permissions..."
oc policy add-role-to-user system:image-puller system:serviceaccount:${KUEUE_NAMESPACE}:kueue-controller-manager -n ${KUEUE_NAMESPACE}

echo ""
echo "=========================================="
echo "Deploying Kueue"
echo "=========================================="

# Create a temporary directory for kustomize overlay in the project root
TEMP_DIR=$(mktemp -d -p .)
trap "rm -rf ${TEMP_DIR}" EXIT

# Create kustomization overlay
cat > ${TEMP_DIR}/kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: ${KUEUE_NAMESPACE}

resources:
- ../config/default

images:
- name: controller
  newName: ${IMAGE_REPO}
  newTag: ${IMAGE_TAG}

patches:
- patch: |-
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: controller-manager
      namespace: system
    spec:
      template:
        spec:
          containers:
          - name: manager
            image: ${FULL_IMAGE}
            imagePullPolicy: Always
            args:
            - --config=/controller_manager_config.yaml
            - --zap-log-level=2
EOF

# Add feature-gates arg only if FEATURE_GATES is not empty
if [ -n "${FEATURE_GATES}" ]; then
    cat >> ${TEMP_DIR}/kustomization.yaml <<EOF
            - --feature-gates=${FEATURE_GATES}
EOF
fi

cat >> ${TEMP_DIR}/kustomization.yaml <<EOF
  target:
    kind: Deployment
    name: controller-manager

# Use default configuration with PyTorchJob integration
- patch: |-
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: manager-config
      namespace: system
    data:
      controller_manager_config.yaml: |
        apiVersion: config.kueue.x-k8s.io/v1beta2
        kind: Configuration
        health:
          healthProbeBindAddress: :8081
        metrics:
          bindAddress: :8443
        webhook:
          port: 9443
        leaderElection:
          leaderElect: true
          resourceName: c1f6bfd2.kueue.x-k8s.io
        controller:
          groupKindConcurrency:
            Job.batch: 5
            Pod: 5
            Workload.kueue.x-k8s.io: 5
            LocalQueue.kueue.x-k8s.io: 1
            Cohort.kueue.x-k8s.io: 1
            ClusterQueue.kueue.x-k8s.io: 1
            ResourceFlavor.kueue.x-k8s.io: 1
        clientConnection:
          qps: 50
          burst: 100
        integrations:
          frameworks:
          - "batch/job"
          - "kubeflow.org/pytorchjob"
          externalFrameworks:
          - "PyTorchJob.kubeflow.org"
  target:
    kind: ConfigMap
    name: manager-config
EOF

echo "Deploying Kueue with kustomize..."
kubectl apply --server-side --force-conflicts -k ${TEMP_DIR}

echo ""
echo "=========================================="
echo "Waiting for Kueue to be ready"
echo "=========================================="

# Wait for deployment to be ready
echo "Waiting for Kueue controller to be ready..."
kubectl wait --for=condition=available --timeout=300s \
    deployment/kueue-controller-manager -n ${KUEUE_NAMESPACE} || {
    echo "Deployment not ready, checking pod status..."
    kubectl get pods -n ${KUEUE_NAMESPACE}
    kubectl describe deployment kueue-controller-manager -n ${KUEUE_NAMESPACE}
    exit 1
}

# Give webhooks time to register
echo "Waiting for webhooks to be ready..."
sleep 10

# Label the TEST namespace for Kueue management (not the Kueue namespace itself)
echo "Labeling test namespace for Kueue management..."
kubectl label namespace ${TEST_NAMESPACE} kueue.x-k8s.io/managed=true --overwrite

echo ""
echo " Kueue deployment complete!"
echo ""
echo "Deployment details:"
echo "  Kueue Namespace: ${KUEUE_NAMESPACE}"
echo "  Test Namespace: ${TEST_NAMESPACE} (labeled for Kueue management)"
echo "  Image: ${FULL_IMAGE}"
if [ -n "${FEATURE_GATES}" ]; then
    echo "  Feature Gates: ${FEATURE_GATES}"
else
    echo "  Feature Gates: none"
fi
echo ""
echo "To check the deployment:"
echo "  kubectl get pods -n ${KUEUE_NAMESPACE}"
echo "  kubectl logs -n ${KUEUE_NAMESPACE} -l control-plane=controller-manager"
