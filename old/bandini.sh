#!/bin/bash -ex
set -o pipefail

: ${IIB_SOURCE=registry-proxy.engineering.redhat.com}
: ${MIRROR_NAMESPACE=openshift-marketplace}
: ${IIB_NAMESPACE=abeekhof}
: ${FILTER=gitops}
: ${INSTALL=0}

if [ $# -ne 1 ]; then
        echo "Call $0 with one parameter: the IIB number"
        exit 1
fi

function pre_check() {
        if ! oc whoami -t; then
            echo "You need to 'oc login' first"
            exit 1
        fi
        OCP=$(oc get clusterversion -o yaml | grep version: | head -n 1 | awk -F. '{print $2}')
        if [ $OCP -lt 13 ]; then
            echo "We currently do not support OCP < 13"
            exit 1
        fi
}

function configure_internal_registry() {
        password=$1
        echo "Enabling the built-in registry"
        oc patch configs.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge
        export MIRROR_TARGET=$(oc get route default-route -n openshift-image-registry --template='{{ .spec.host }}')
        echo "Giving permission for the cluster to access the registries"
        oc patch image.config.openshift.io/cluster --patch "{\"spec\":{\"registrySources\":{\"allowedRegistries\":[ \"quay.io\", \"registry.redhat.io\", \"registry-proxy.engineering.redhat.com\", \"image-registry.openshift-image-registry.svc:5000\", \"$MIRROR_TARGET\"]}}}" --type=merge
        oc patch image.config.openshift.io/cluster --patch "{\"spec\":{\"registrySources\":{\"insecureRegistries\":[ \"registry-proxy.engineering.redhat.com\", \"image-registry.openshift-image-registry.svc:5000\", \"$MIRROR_TARGET\"]}}}" --type=merge

        echo "Authenticating the cluster to the built-in registry"
        rm -f "${PULLSECRET}" combined.conf
        oc extract secret/pull-secret -n openshift-config --to=- > "${PULLSECRET}"
        jq ".auths += {\"$MIRROR_TARGET\": {\"auth\": \"$(echo -n "kubeadmin:$password" | base64 -w0)\",\"email\": \"noemail@localhost\"}}" < "${PULLSECRET}" > combined.conf
        oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=combined.conf
        rm -f combined.conf
        oc extract secret/pull-secret -n openshift-config --to=- > "${PULLSECRET}"

        echo "Logging into the built-in registry"
        podman login --authfile "${PULLSECRET}" --tls-verify=false "${MIRROR_TARGET}"
        export IIB_TARGET="${MIRROR_TARGET}/$MIRROR_NAMESPACE/"
}

function wait_for_new_catalog() {
        local operator=$1
        local iib=$2
        sTime=1
        while ! oc get -n "${MIRROR_NAMESPACE}" packagemanifests -l "catalog=iib-${iib}" --field-selector "metadata.name=${operator}" \
                -o jsonpath='{.items[0].status.defaultChannel}'; do
                echo "Waiting for the package manifest to appear"
                sleep $sTime
                sTime=20
        done
}

function install_new_iib() {
        local COUNTER=0
        echo "Processing $INDEX_IMAGE"
        export IIB=$(echo $INDEX_IMAGE | sed 's/.*://')
        export IIB_PATH=$PWD/manifests-iib-$IIB
        rm -rf "${IIB_PATH}" && mkdir "${IIB_PATH}"

        pushd "${IIB_PATH}"
        echo "Creating $IIB manifests"
        oc adm catalog mirror --insecure --manifests-only --to-manifests=. $IIB_SOURCE/rh-osbs/iib:$IIB $IIB_SOURCE/rh-osbs 2>&1 | tee catalog.log

        echo "Mirroring $IIB catalog"
        # FIXME(bandini): this sometimes fails and needs a retry mechanism
        rm -f iib.log
        set +e
        while [ ${COUNTER} -lt 3 ]; do
          oc image mirror -a $PULLSECRET $IIB_SOURCE/rh-osbs/iib:$IIB=${IIB_TARGET}iib:$IIB --insecure --keep-manifest-list 2>&1 | tee -a iib.log
          ret=$?
          COUNTER=$((COUNTER+1))
          sleep 1
        done
        set -e
        if [ "${ret}" -ne 0 ]; then
                echo "Uploading IIB to internal registry failed at last try as well"
                exit 1
        fi

        sed -i "s/name: iib$/name: iib-$IIB/" catalogSource.yaml
        sed -i "s@$IIB_SOURCE/rh-osbs/rh-osbs-@$IIB_TARGET@" catalogSource.yaml
        sed -i "s/grpc/grpc\n  displayName: IIB $IIB/"  catalogSource.yaml
        oc apply -f $IIB_PATH/catalogSource.yaml
        wait_for_new_catalog openshift-gitops-operator "${IIB}"
}

function wait_for_mcp_completion() {
        # FIXME(bandini): arbitrary wait for MCP to start applying
        sleep 5
        echo "Waiting for the mirror to start applying"
        while ! oc get mcp | grep -e 'worker.*False.*True.*False'; do sleep 10; done
        echo "Waiting for the mirror to finish applying"
        while ! oc get mcp | grep 'worker.*True.*False.*False'; do sleep 10; done
}


pre_check

pass=$(oc whoami -t)
PULLSECRET=$PWD/.dockerconfigjson
INDEX_IMAGE="$1"

configure_internal_registry "${pass}"
install_new_iib

echo "Handle the operator bundle"
echo "" > mirror.map
image=$(grep -e "^registry-proxy.*bundle" mapping.txt | sed 's/=.*//')
mirrored=$MIRROR_TARGET/$MIRROR_NAMESPACE/$(basename $image | sed -e 's/@.*//')
echo "$image=$mirrored:$IIB" >> mirror.map
image_nohash=$(echo $image | sed -e 's/@.*//')

cat > imagedigestmirror.yaml <<EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
    labels:
        operators.openshift.org/catalog: "true"
    name: iib-$IIB
spec:
    imageDigestMirrors:
        - mirrors:
            - $mirrored
          source: $image_nohash
          mirrorSourcePolicy: NeverContactSource
EOF

channel=$(oc get -n "${MIRROR_NAMESPACE}" packagemanifests -l "catalog=iib-$IIB" --field-selector 'metadata.name=openshift-gitops-operator' \
        -o jsonpath='{.items[0].status.defaultChannel}')
images=$(oc get packagemanifests -l "catalog=iib-$IIB" --field-selector 'metadata.name=openshift-gitops-operator' \
        -o jsonpath="{.items[0].status.channels[?(@.name==\"$channel\")].currentCSVDesc.relatedImages}" | jq -r '. | join(" ")')

for image in $images; do
        # image:    registry.redhat.io/openshift-gitops-1/gitops-rhel8-operator@sha256:b46742d61aa8444b0134959c8edbc96cc11c71bf04c6744a30b2d7e1ebe888a7
        # source:   registry-proxy.engineering.redhat.com/rh-osbs/openshift-gitops-1-gitops-rhel8-operator
        # mirrored: default-route-openshift-image-registry.apps.beekhof412.blueprints.rhecoeng.com/openshift-marketplace/openshift-gitops-1-gitops-rhel8-operator
        sha=$(echo $image | sed 's/.*@/@/')
        source=$(grep $image mapping.txt | sed -e 's/.*=//' -e 's/:.*//')
        mirrored=$MIRROR_TARGET/$MIRROR_NAMESPACE/$(basename $source)

        image_nosha=$(echo $image | sed -e 's/@.*//')
        source_nosha=$(echo $source | sed -e 's/@.*//')
        echo "        - mirrors:" >> imagedigestmirror.yaml
        echo "            - $mirrored" >> imagedigestmirror.yaml
        echo "          source: $image_nosha" >> imagedigestmirror.yaml
        echo "          mirrorSourcePolicy: NeverContactSource" >> imagedigestmirror.yaml
        echo "        - mirrors:" >> imagedigestmirror.yaml
        echo "            - $mirrored" >> imagedigestmirror.yaml
        echo "          source: $source_nosha" >> imagedigestmirror.yaml
        echo "          mirrorSourcePolicy: NeverContactSource" >> imagedigestmirror.yaml
        # This monstrosity if because *sometimes* (e.g. ose-haproxy-router) the
        # image does not exist on registry-proxy but only on registre.redhat.io
        # contrary to what mapping.txt and imageContentSourcePolicy.yaml tell
        # me
        found_image=false
        found_source=false
        found=""
        if skopeo inspect --authfile "${PULLSECRET}" --no-tags "docker://${image}" &> /tmp/image.log; then
                found_image=true
        fi
        if skopeo inspect --authfile "${PULLSECRET}" --no-tags "docker://${source}" &> /tmp/source.log; then
                found_source=true
                found=$(echo $source | sed -e 's/@.*//')
                echo $found$sha=$mirrored:$IIB >> mirror.map
        fi
        if [ $found_image = false ] && [ $found_source = false ]; then
                echo "Both not found ${image} -> ${source}"
                exit 1
        fi

done
COUNTER=0
set +e
while [ ${COUNTER} -lt 3 ]; do
        oc image mirror -a "${PULLSECRET}" -f mirror.map --continue-on-error --insecure --keep-manifest-list 2>&1 | tee "images${COUNTER}".log
        ret=$?
        COUNTER=$((COUNTER+1))
        sleep 5
done
set -e
if [ "${ret}" -ne 0 ]; then
        echo "Uploading all images to internal registry failed at the last try as well"
        exit 1
fi

# apply the mirror changes
oc apply -f imagedigestmirror.yaml

wait_for_mcp_completion

popd
