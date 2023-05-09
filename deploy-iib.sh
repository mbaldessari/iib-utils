#!/bin/bash -ex

INDEX_IMAGES="$*"
: ${IIB_SOURCE=registry-proxy.engineering.redhat.com}
: ${MIRROR_NAMESPACE=abeekhof}
: ${INSTALL=0}
: ${MIRROR_ARGS=""}
: ${MIRROR_TARGET="internal"}

PULLSECRET=$PWD/.dockerconfigjson

OCP=$(oc get clusterversion -o yaml | grep version: | head -n 1 | awk -F. '{print $2}' )
if [ $OCP -lt 13 ]; then
    # From ocp 4.13, the internal registry supports --keep-manifest-list
    MIRROR_TARGET=quay.io
fi

function update_mirror_files() {
    local map=$1
    local icsp=$2
    local image=$3
    local source=$4
    local mirrored=$5

    local image_nohash=$(echo $image | sed -e 's/@.*//')
    local fulltag=$(basename $image_nohash$IIB | sha256sum)
    local tag=${fulltag:0:6}

    if [ $OCP -lt 13 ]; then
        mirrored=$MIRRORED_IIB
    fi

    echo $image=$mirrored:$tag >> $map
    #echo -e "  - mirrors:\n    - $mirrored\n    source: $image" >> $ICSP
    if [ $OCP -lt 13 ]; then
        echo -e "  - source: $image_nohash" >> $icsp
        echo -e "    mirrors:" >> $icsp
        echo -e "    - $mirrored" >> $icsp
    else
        echo -e "       - mirrors:" >> $icsp
        echo -e "         - $mirrored" >> $icsp
        echo -e "         source: $image_nohash" >> $icsp
        echo -e "         mirrorSourcePolicy: NeverContactSource" >> $icsp
    fi
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

    function wait_for_mcp_completion() {
        # FIXME(bandini): arbitrary wait for MCP to start applying
        sleep 5
        echo "Waiting for the mirror to start applying"
        while ! oc get mcp | grep -e 'worker.*False.*True.*False'; do sleep 10; done
        echo "Waiting for the mirror to finish applying"
        while ! oc get mcp | grep 'worker.*True.*False.*False'; do sleep 10; done
    }

function install_new_iib() {
    local COUNTER=0

    echo "Processing $IIB_ENTRY"
    IIB=$(echo $* | sed 's/.*://')
    IIB_PATH=$PWD/manifests-iib-$IIB
    #rm -rf $IIB_PATH
    if [ ! -d $IIB_PATH ]; then
        mkdir $IIB_PATH
    fi
    pushd "${IIB_PATH}"

    MIRRORED_IIB=${MIRROR_TARGET}/$MIRROR_NAMESPACE/iib
    if [ ! -e imageContentSourcePolicy.yaml ]; then
        echo "Creating $IIB manifests"
        oc adm catalog mirror --insecure --manifests-only --to-manifests=. $IIB_SOURCE/rh-osbs/iib:$IIB $IIB_SOURCE/rh-osbs 2>&1 | tee catalog.log
    fi

    echo "Mirroring $IIB catalog"
    # FIXME(bandini): this sometimes fails and needs a retry mechanism
    rm -f iib.log
    set +e
    while [ ${COUNTER} -lt 3 ]; do
        oc image mirror -a $PULLSECRET $IIB_SOURCE/rh-osbs/iib:$IIB=${MIRRORED_IIB} --insecure --keep-manifest-list 2>&1 | tee -a iib.log
        ret=$?
        COUNTER=$((COUNTER+1))
        sleep 1
    done
    set -e
    if [ "${ret}" -ne 0 ]; then
        echo "Uploading IIB to internal registry failed at last try as well"
        exit 1
    fi

    echo "Mirroring $IIB catalog"

    CATALOG=cat.yaml
    cat catalogSource.yaml > $CATALOG
    sed -i "s/name: iib$/name: iib-$IIB/" $CATALOG
    sed -i "s@image:.*@image: ${MIRRORED_IIB}:$IIB@" $CATALOG
    sed -i "s/grpc/grpc\n  displayName: IIB $IIB/"  $CATALOG
    oc apply -f $CATALOG

    wait_for_new_catalog openshift-gitops-operator "${IIB}"
}


if [ $MIRROR_TARGET = "internal" ]; then
    # FIXME(bandini): we need to find a way to login in the internal registry with an alternate
    #                 user that does not require `oc login`
    if ! oc whoami -t; then
        echo "You need to 'oc login' first"
        exit 1
    fi

    echo "Enabling the built-in registry"
    oc patch configs.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge
    MIRROR_TARGET=$(oc get route default-route -n openshift-image-registry --template='{{ .spec.host }}')
    MIRROR_NAMESPACE=openshift-marketplace

# doesn't work...
#echo "Allow everyone to pull from the internal registry"
#oc -n $MIRROR_NAMESPACE policy add-role-to-group registry-viewer system:unauthenticated

    password=$(oc whoami -t)
    echo "Authenticating the cluster to the built-in registry"
    # filename must be .dockerconfigjson for use with 'oc set data'

    if [ ! -e $PULLSECRET ] || [ ! -s $PULLSECRET ]; then
        echo "Extracting pull secrets from cluster"
        oc extract secret/pull-secret -n openshift-config --to=- > $PULLSECRET
    fi

    if ! grep -q $MIRROR_TARGET $PULLSECRET; then
        jq ".auths += {\"$MIRROR_TARGET\": {\"auth\": \"$(echo -n "kubeadmin:$password" | base64 -w0)\",\"email\": \"noemail@localhost\"}}" < "${PULLSECRET}" > "${PULLSECRET}.tmpfile"
        mv "${PULLSECRET}.tmpfile" "${PULLSECRET}"
        rm -f "${PULLSECRET}.tmpfile"
        oc set data secret/pull-secret -n openshift-config --from-file=$PULLSECRET
    fi

    echo "Logging into the built-in registry"
    podman login --authfile $PULLSECRET --tls-verify=false $MIRROR_TARGET

    echo "Giving permission for the cluster to access the registries"
    oc patch image.config.openshift.io/cluster --patch "{\"spec\":{\"registrySources\":{\"allowedRegistries\":[ \"quay.io\", \"registry.redhat.io\", \"registry-proxy.engineering.redhat.com\", \"image-registry.openshift-image-registry.svc:5000\", \"$MIRROR_TARGET\"]}}}" --type=merge
    oc patch image.config.openshift.io/cluster --patch "{\"spec\":{\"registrySources\":{\"insecureRegistries\":[ \"registry-proxy.engineering.redhat.com\", \"image-registry.openshift-image-registry.svc:5000\", \"$MIRROR_TARGET\"]}}}" --type=merge
fi

for IIB_ENTRY in $(echo $INDEX_IMAGES | tr ',' '\n'); do
    install_new_iib $IIB_ENTRY

    echo "Calculating $IIB images"
    # The default mapping is broken for some images
    # sed -i 's@rh-osbs-red-hat@red-hat@' imageContentSourcePolicy.yaml
    #sed -i 's@rh-osbs/workload-availability@rh-osbs/red-hat-workload-availability@g' imageContentSourcePolicy.yaml
    #sed -i 's@healthcheck-rhel8-operator@healthcheck-operator@g' imageContentSourcePolicy.yaml
    #sed -i 's@node-remediation-console-rhel8@node-remediation-console@g' imageContentSourcePolicy.yaml

    echo "" > mirror.map
    if [ $OCP -lt 13 ]; then
        ICSP=icsp.yaml
        head -n 9 imageContentSourcePolicy.yaml > $ICSP
        sed -i "s/name: iib-0$/name: iib-$IIB/" $ICSP
    else
        ICSP=imagedigestmirror.yaml
        cat > $ICSP <<EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
    labels:
        operators.openshift.org/catalog: "true"
    name: iib-$IIB
spec:
    imageDigestMirrors:
EOF
    fi

    echo "Handle the operator bundle"
    image=$(grep -e "^registry-proxy.*bundle" mapping.txt | sed 's/=.*//')
    image_nohash=$(echo $image | sed -e 's/@.*//')
    fulltag=$(basename $image | sha256sum)
    tag=${fulltag:0:6}
    mirrored=$MIRROR_TARGET/$MIRROR_NAMESPACE/$(basename $image | sed -e 's/@.*//' )

    update_mirror_files mirror.map $ICSP $image $image_nohash $mirrored

    channel=$(oc get  -n ${MIRROR_NAMESPACE} packagemanifests  -l "catalog=iib-$IIB" --field-selector 'metadata.name=openshift-gitops-operator' \
             -o jsonpath='{.items[0].status.defaultChannel }')
    images=$(oc get packagemanifests -l "catalog=iib-$IIB" --field-selector 'metadata.name=openshift-gitops-operator' \
            -o jsonpath="{.items[0].status.channels[?(@.name==\"$channel\")].currentCSVDesc.relatedImages}" | jq -r '. | join(" ")')

    for image in $images; do
        # image:    registry.redhat.io/openshift-gitops-1/gitops-rhel8-operator@sha256:b46742d61aa8444b0134959c8edbc96cc11c71bf04c6744a30b2d7e1ebe888a7
        # source:   registry-proxy.engineering.redhat.com/rh-osbs/openshift-gitops-1-gitops-rhel8-operator
        # mirrored: default-route-openshift-image-registry.apps.beekhof412.blueprints.rhecoeng.com/openshift-marketplace/openshift-gitops-1-gitops-rhel8-operator
        image_nohash=$(echo $image | sed -e 's/@.*//')
        source=$(grep $image mapping.txt | sed -e 's/.*=//' -e 's/:.*//')
        mirrored=$MIRROR_TARGET/$MIRROR_NAMESPACE/$(basename $source )
        tag=$IIB

        # This monstrosity if because *sometimes* (e.g. ose-haproxy-router) the
        # image does not exist on registry-proxy but only on registry.redhat.io
        # contrary to what mapping.txt and imageContentSourcePolicy.yaml tell
        # me
        if skopeo inspect --authfile "${PULLSECRET}" --no-tags "docker://${source}" &> /tmp/source.log; then
            echo "Found $source"
        elif skopeo inspect --authfile "${PULLSECRET}" --no-tags "docker://${image}" &> /tmp/image.log; then
            echo "$source not found, defaulting to $image_nohash"
            source=$image_nohash
        else
            echo "Neither ${image} nor ${source} found"
            exit 1
        fi

        update_mirror_files mirror.map $ICSP $image $source $mirrored
    done

    echo "Mirroring $IIB images"
    oc image mirror -a $PULLSECRET -f mirror.map --continue-on-error --insecure --keep-manifest-list $MIRROR_ARGS 2>&1 | tee images.log

    cat $ICSP
    oc apply -f $ICSP
    popd
done

wait_for_mcp_completion

if [ $INSTALL != 0 ]; then
    echo Do install
fi

# sed -i 's@rh-osbs/workload-availability@rh-osbs/red-hat-workload-availability@g' icsp.yaml
# sed -i 's@red-hat-workload-availability-node-healthcheck-rhel8-operator@red-hat-workload-availability-node-healthcheck-operator@g' icsp.yaml
# sed -i 's@red-hat-workload-availability-node-remediation-console-rhel8@red-hat-workload-availability-node-remediation-console@g' icsp.yaml
#  - image: registry-proxy.engineering.redhat.com/rh-osbs/red-hat-workload-availability-node-healthcheck-operator-bundle@sha256:de8ba3976dbe6fb33a4a47b6cddde0d1cde0f0ee5c50e0dc52922862c70dd0d5
