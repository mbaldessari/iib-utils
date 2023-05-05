#!/bin/bash -ex

INDEX_IMAGES="$*"
: ${IIB_SOURCE=registry-proxy.engineering.redhat.com}
: ${IIB_NAMESPACE=openshift-marketplace}
: ${QUAY_NAMESPACE=abeekhof}
: ${FILTER=gitops}
: ${OCP=12}
: ${INSTALL=0}
: ${MIRROR_ARGS=""}

if [ $(oc whoami -t | wc -c) != 51 ]; then
    echo "You need to 'oc login' first"
    false
fi

echo "Enabling the built-in registry"
oc patch configs.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge
export MIRROR_TARGET=$(oc get route default-route -n openshift-image-registry --template='{{ .spec.host }}') 

password=$(oc whoami -t)

echo "Authenticating the cluster to the built-in registry"
PULLSECRET=$PWD/.dockerconfigjson
oc extract secret/pull-secret -n openshift-config  --to=- > $PULLSECRET
set +e
grep -q $MIRROR_TARGET $PULLSECRET
rc=$?
set -e
if [ $rc = 1 ]; then
    jq ".auths += {\"$MIRROR_TARGET\": {\"auth\": \"$(echo -n "kubeadmin:$password" | base64)\",\"email\": \"noemail@localhost\"}}" < $PULLSECRET > combined.conf
    oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=combined.conf
    rm -f combined.conf
    oc extract secret/pull-secret -n openshift-config  --to=- > $PULLSECRET
fi

echo "Logging into the built-in registry"
podman login --authfile $PULLSECRET --tls-verify=false $MIRROR_TARGET 

echo "Giving permission for the cluster to access the registries"
oc patch image.config.openshift.io/cluster --patch "{\"spec\":{\"registrySources\":{\"allowedRegistries\":[ \"quay.io\", \"registry.redhat.io\", \"registry-proxy.engineering.redhat.com\", \"image-registry.openshift-image-registry.svc:5000\", \"$MIRROR_TARGET\"]}}}" --type=merge
oc patch image.config.openshift.io/cluster --patch "{\"spec\":{\"registrySources\":{\"insecureRegistries\":[ \"registry-proxy.engineering.redhat.com\", \"image-registry.openshift-image-registry.svc:5000\", \"$MIRROR_TARGET\"]}}}" --type=merge

IIB_TARGET="quay.io/$QUAY_NAMESPACE/"
if [ $OCP = 13 ]; then
    # From ocp 4.13, the internal registry supports --keep-manifest-list
    IIB_TARGET="${MIRROR_TARGET}/$IIB_NAMESPACE/rh-osbs-"
    MIRROR_ARGS="$MIRROR_ARGS --keep-manifest-list"
fi

for IIB_ENTRY in $(echo $INDEX_IMAGES | tr ',' '\n'); do 
	echo "Processing $IIB_ENTRY" 
	export IIB=$(echo $IIB_ENTRY | sed 's/.*://') 
	export IIB_PATH=$PWD/manifests-iib-$IIB 
	rm -rf $IIB_PATH
	mkdir $IIB_PATH
	cd $IIB_PATH

	echo "Creating $IIB manifests"
	oc adm catalog mirror --insecure --manifests-only --to-manifests=. $IIB_SOURCE/rh-osbs/iib:$IIB $IIB_SOURCE/rh-osbs 2>&1 | tee catalog-$IIB.log

	echo "Mirroring $IIB catalog" 
	oc image mirror -a $PULLSECRET $IIB_SOURCE/rh-osbs/iib:$IIB=${IIB_TARGET}iib:$IIB --insecure --keep-manifest-list 2>&1 | tee image-$IIB.log 

	sed -i "s/name: iib$/name: iib-$IIB/" catalogSource.yaml  
	sed -i "s@$IIB_SOURCE/rh-osbs/rh-osbs-@$IIB_TARGET@" catalogSource.yaml
	sed -i "s/grpc/grpc\n  displayName: IIB $IIB/"  catalogSource.yaml
	oc apply -f $IIB_PATH/catalogSource.yaml  

	echo "Mirroring $IIB images" 
	cp imageContentSourcePolicy.yaml imageContentSourcePolicy.yaml.orig
	sed -i "s/name: iib-0$/name: iib-$IIB/" imageContentSourcePolicy.yaml

	# The mapping is broken for some images
	# sed -i 's@rh-osbs-red-hat@red-hat@' imageContentSourcePolicy.yaml
	sed -i 's@rh-osbs/workload-availability@rh-osbs/red-hat-workload-availability@g' imageContentSourcePolicy.yaml
	sed -i 's@healthcheck-rhel8-operator@healthcheck-operator@g' imageContentSourcePolicy.yaml
	sed -i 's@node-remediation-console-rhel8@node-remediation-console@g' imageContentSourcePolicy.yaml

	channel=""
	sTime=1
	while [ "x$channel" = x ]; do
	    echo "Waiting for the package manifest to appear"
	    sleep $sTime
	    set +e
	    channel=$(oc get  -n ${IIB_NAMESPACE} packagemanifests  -l "catalog=iib-$IIB" --field-selector 'metadata.name=openshift-gitops-operator' -o jsonpath='{.items[0].status.defaultChannel }')
	    set -e
	    sTime=60
	done
	images=$(oc get packagemanifests  -l "catalog=iib-$IIB" --field-selector 'metadata.name=openshift-gitops-operator' -o jsonpath="{.items[0].status.channels[?(@.name==\"$channel\")].currentCSVDesc.relatedImages}" | tr ',][' ' ' | tr -d '"' )

#  - image: registry-proxy.engineering.redhat.com/rh-osbs/openshift-gitops-1-gitops-operator-bundle@sha256:b62de4ef5208e2cc358649bd59e0b9f750f95d91184725135b7705f9f60cc70a
#+ oc image mirror registry-proxy.engineering.redhat.com/rh-osbs/rh-osbs-openshift-gitops-1-gitops-operator-bundle@sha256:b62de4ef5208e2cc358649bd59e0b9f750f95d91184725135b7705f9f60cc70a=default-route-openshift-image-registry.apps.beekhof412.blueprints.rhecoeng.com/openshift-marketplace/rh-osbs-openshift-gitops-1-gitops-operator-bundle:489388 --insecure
	
	echo "" > mirror.map
	head -n 9 imageContentSourcePolicy.yaml > icsp.yaml
	for image in $bundle $images; do
	    # image:    registry.redhat.io/openshift-gitops-1/gitops-rhel8-operator@sha256:b46742d61aa8444b0134959c8edbc96cc11c71bf04c6744a30b2d7e1ebe888a7
	    # source:   registry-proxy.engineering.redhat.com/rh-osbs/openshift-gitops-1-gitops-rhel8-operator:2a416676
	    # mirrored: default-route-openshift-image-registry.apps.beekhof412.blueprints.rhecoeng.com/openshift-marketplace/openshift-gitops-1-gitops-rhel8-operator
	    sha=$(echo $image | sed 's/.*@/@/')
	    source=$(grep $image mapping.txt | sed -e 's/.*=//' -e 's/:.*//')
	    mirrored=$MIRROR_TARGET/$IIB_NAMESPACE/$(basename $source )
	    
	    echo $source$sha=$mirrored:$IIB >> mirror.map
	    
	    echo -e "  - mirrors:\n    - $mirrored\n    source: $image" >> icsp.yaml

	    
	done

	cat mirror.map
	oc image mirror -a $PULLSECRET -f mirror.map --insecure $MIRROR_ARGS | tee images.log

	cat icsp.yaml
	oc apply -f icsp.yaml
	cd ..
done

echo Waiting for the mirror to start applying
oc get mcp
while [ "x$(oc get mcp | grep 'worker.*False.*True.*False')" = x ]; do sleep 10; done     
echo Waiting for the mirror to finish applying
oc get mcp
while [ "x$(oc get mcp | grep 'worker.*True.*False.*False')" = x ]; do sleep 10; done     
oc get mcp

if [ $INSTALL != 0 ]; then
    echo Do install
fi

# sed -i 's@rh-osbs/workload-availability@rh-osbs/red-hat-workload-availability@g' manifests-iib-${ICSP_NR}/imageContentSourcePolicy.yaml
# sed -i 's@red-hat-workload-availability-node-healthcheck-rhel8-operator@red-hat-workload-availability-node-healthcheck-operator@g' manifests-iib-${ICSP_NR}/imageContentSourcePolicy.yaml
# sed -i 's@red-hat-workload-availability-node-remediation-console-rhel8@red-hat-workload-availability-node-remediation-console@g' manifests-iib-${ICSP_NR}/imageContentSourcePolicy.yaml

#  - image: registry-proxy.engineering.redhat.com/rh-osbs/red-hat-workload-availability-node-healthcheck-operator-bundle@sha256:de8ba3976dbe6fb33a4a47b6cddde0d1cde0f0ee5c50e0dc52922862c70dd0d5
