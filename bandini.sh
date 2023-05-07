#!/bin/bash -ex
#
: ${INTERNAL_MIRROR="registry-proxy.engineering.redhat.com"}
: ${INTERNAL_PATH="rh-osbs"}
: ${INTERNAL_IMAGE="iib"}
: ${INTERNAL_TAG="489388"}
: ${OPERATOR="openshift-gitops-operator"}
: ${NEW_INDEX_NAME="foo:latest"}

IMG="${INTERNAL_MIRROR}/${INTERNAL_PATH}/${INTERNAL_IMAGE}:${INTERNAL_TAG}"
FOLDER="test-bandini-${INTERNAL_IMAGE}-${INTERNAL_TAG}/configs"
echo "Fetching ${IMG}"
podman pull "${IMG}"

INDEX_RENDER="/tmp/bandini-${INTERNAL_IMAGE}-${INTERNAL_TAG}.json"
opm render "${IMG}" > "${INDEX_RENDER}"

mkdir -p "${FOLDER}"
cat "${INDEX_RENDER}" | jq 'select( .package == "'${OPERATOR}'" or .name == "'${OPERATOR}'")'> "${FOLDER}"/index.json
pushd "${FOLDER}"
opm alpha bundle generate -d . -c . -p . -u .
podman build -t "${NEW_INDEX_NAME}" -f bundle.Dockerfile
popd
