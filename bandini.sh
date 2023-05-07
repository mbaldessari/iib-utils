#!/bin/bash -ex
#
INDEX_IMAGES="$*"
: ${IIB_SOURCE=registry-proxy.engineering.redhat.com}
: ${MIRROR_NAMESPACE=openshift-marketplace}
: ${IIB_NAMESPACE=abeekhof}
: ${FILTER=gitops}
: ${INSTALL=0}
: ${MIRROR_ARGS=""}

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

function apply_image_digest_mirror_set() {
        GITROOT=$(git rev-parse --show-toplevel)
        MIRRORSET="${GITROOT}/imagedigestmirrorset.yaml"
        sed -e "s@TEMPLATEROUTE@${IIB_TARGET}@" -e "s@TEMPLATESOURCE@${IIB_SOURCE}/rh-osbs@" "${MIRRORSET}" | oc apply -f-
}


pass=$(oc whoami -t)
PULLSECRET=$PWD/.dockerconfigjson

pre_check
configure_internal_registry "${pass}"


for IIB_ENTRY in $(echo $INDEX_IMAGES | tr ',' '\n'); do 
        echo "Processing $IIB_ENTRY" 
        export IIB=$(echo $IIB_ENTRY | sed 's/.*://') 
        export IIB_PATH=$PWD/manifests-iib-$IIB 
        rm -rf $IIB_PATH && mkdir $IIB_PATH
        pushd $IIB_PATH

        echo "Creating $IIB manifests"
        oc adm catalog mirror --insecure --manifests-only --to-manifests=. $IIB_SOURCE/rh-osbs/iib:$IIB $IIB_SOURCE/rh-osbs 2>&1 | tee catalog.log

        echo "Mirroring $IIB catalog" 
        # FIXME(bandini): this sometimes fails and needs a retry mechanism
        oc image mirror -a $PULLSECRET $IIB_SOURCE/rh-osbs/iib:$IIB=${IIB_TARGET}iib:$IIB --insecure --keep-manifest-list 2>&1 | tee iib.log 

        sed -i "s/name: iib$/name: iib-$IIB/" catalogSource.yaml  
        sed -i "s@$IIB_SOURCE/rh-osbs/rh-osbs-@$IIB_TARGET@" catalogSource.yaml
        sed -i "s/grpc/grpc\n  displayName: IIB $IIB/"  catalogSource.yaml
        oc apply -f $IIB_PATH/catalogSource.yaml  
        wait_for_new_catalog openshift-gitops-operator "${IIB}"
	      channel=$(oc get -n "${MIRROR_NAMESPACE}" packagemanifests -l "catalog=iib-$IIB" --field-selector 'metadata.name=openshift-gitops-operator' \
                -o jsonpath='{.items[0].status.defaultChannel }')
        popd
done 


