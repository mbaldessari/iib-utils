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


if [ $MIRROR_TARGET = "internal" ]; then
    if [ $(oc whoami -t | wc -c) != 51 ]; then
	echo "You need to 'oc login' first"
	false
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

    if [ ! -e $PULLSECRET ]; then
	oc extract secret/pull-secret -n openshift-config  --to=- > $PULLSECRET
    fi

    set +e
    grep -q $MIRROR_TARGET $PULLSECRET
    rc=$?
    set -e
    
    if [ $rc = 1 ]; then
	jq ".auths += {\"$MIRROR_TARGET\": {\"auth\": \"$(echo -n "kubeadmin:$password" | base64  -w 0)\",\"email\": \"noemail@localhost\"}}" < $PULLSECRET > $PULLSECRET
	jq ".auths += {\"quay.io\": {\"auth\": \"$(echo -n "abeekhof+blueprints:XTYZQFWG21AP0BYVCX7RV5HZLZM87SRGB9F5PPYP6SCRZ4BL75GWW7O9P4C01QYL" | base64  -w 0)\",\"email\": \"noemail@localhost\"}}" < $PULLSECRET > $PULLSECRET
	oc set data secret/pull-secret -n openshift-config --from-file=$PULLSECRET
    fi

    echo "Logging into the built-in registry"
    podman login --authfile $PULLSECRET --tls-verify=false $MIRROR_TARGET 

    echo "Giving permission for the cluster to access the registries"
    oc patch image.config.openshift.io/cluster --patch "{\"spec\":{\"registrySources\":{\"allowedRegistries\":[ \"quay.io\", \"registry.redhat.io\", \"registry-proxy.engineering.redhat.com\", \"image-registry.openshift-image-registry.svc:5000\", \"$MIRROR_TARGET\"]}}}" --type=merge
    oc patch image.config.openshift.io/cluster --patch "{\"spec\":{\"registrySources\":{\"insecureRegistries\":[ \"registry-proxy.engineering.redhat.com\", \"image-registry.openshift-image-registry.svc:5000\", \"$MIRROR_TARGET\"]}}}" --type=merge
fi

for IIB_ENTRY in $(echo $INDEX_IMAGES | tr ',' '\n'); do 
	echo "Processing $IIB_ENTRY" 
	IIB=$(echo $IIB_ENTRY | sed 's/.*://') 
	IIB_PATH=$PWD/manifests-iib-$IIB 
	#rm -rf $IIB_PATH
	if [ ! -d $IIB_PATH ]; then
	    mkdir $IIB_PATH
	fi
	cd $IIB_PATH

	MIRRORED_IIB=${MIRROR_TARGET}/$MIRROR_NAMESPACE/iib
	if [ ! -e imageContentSourcePolicy.yaml ]; then
	    echo "Creating $IIB manifests"
	    oc adm catalog mirror --insecure --manifests-only --to-manifests=. $IIB_SOURCE/rh-osbs/iib:$IIB $IIB_SOURCE/rh-osbs 2>&1 | tee catalog.log
	fi
	
	echo "Mirroring $IIB catalog" 
	oc image mirror -a $PULLSECRET $IIB_SOURCE/rh-osbs/iib:$IIB=${MIRRORED_IIB} --insecure --keep-manifest-list 2>&1 | tee iib.log 

	CATALOG=cat.yaml
	cat catalogSource.yaml > $CATALOG
	sed -i "s/name: iib$/name: iib-$IIB/" $CATALOG  
	sed -i "s@image:.*@image: ${MIRRORED_IIB}:$IIB@" $CATALOG
	sed -i "s/grpc/grpc\n  displayName: IIB $IIB/"  $CATALOG
	oc apply -f $CATALOG  

	echo "Calculating $IIB images" 
	# The default mapping is broken for some images
	# sed -i 's@rh-osbs-red-hat@red-hat@' imageContentSourcePolicy.yaml
	#sed -i 's@rh-osbs/workload-availability@rh-osbs/red-hat-workload-availability@g' imageContentSourcePolicy.yaml
	#sed -i 's@healthcheck-rhel8-operator@healthcheck-operator@g' imageContentSourcePolicy.yaml
	#sed -i 's@node-remediation-console-rhel8@node-remediation-console@g' imageContentSourcePolicy.yaml

	channel=""
	sTime=1
	while [ "x$channel" = x ]; do
	    echo "Waiting for the package manifest to appear"
	    sleep $sTime
	    set +e
	    channel=$(oc get  -n ${MIRROR_NAMESPACE} packagemanifests  -l "catalog=iib-$IIB" --field-selector 'metadata.name=openshift-gitops-operator' -o jsonpath='{.items[0].status.defaultChannel }')
	    set -e
	    sTime=20
	done

	echo "" > mirror.map
	ICSP=icsp.yaml
	head -n 9 imageContentSourcePolicy.yaml > $ICSP
	sed -i "s/name: iib-0$/name: iib-$IIB/" $ICSP

	echo "Handle the operator bundle"
	image=$(grep -e "^registry-proxy.*bundle" mapping.txt | sed 's/=.*//')
	fulltag=$(basename $image | sha256sum)
	tag=${fulltag:0:6}
	if [ $OCP = 12 ]; then
	    mirrored=$MIRRORED_IIB
	else
	    mirrored=$MIRROR_TARGET/$MIRROR_NAMESPACE/$(basename $image | sed -e 's/@.*//' )	    
	fi

	echo $image=$mirrored:$tag >> mirror.map
	#echo -e "  - mirrors:\n    - $mirrored\n    source: $image" >> $ICSP
	echo -e "  - source: $(echo $image | sed -e 's/@.*//')\n    mirrors:\n    - $mirrored" >> $ICSP
	

#  - image: registry-proxy.engineering.redhat.com/rh-osbs/openshift-gitops-1-gitops-operator-bundle@sha256:b62de4ef5208e2cc358649bd59e0b9f750f95d91184725135b7705f9f60cc70a
#+ oc image mirror registry-proxy.engineering.redhat.com/rh-osbs/rh-osbs-openshift-gitops-1-gitops-operator-bundle@sha256:b62de4ef5208e2cc358649bd59e0b9f750f95d91184725135b7705f9f60cc70a=default-route-openshift-image-registry.apps.beekhof412.blueprints.rhecoeng.com/openshift-marketplace/rh-osbs-openshift-gitops-1-gitops-operator-bundle:489388 --insecure
	
	images=$(oc get packagemanifests  -l "catalog=iib-$IIB" --field-selector 'metadata.name=openshift-gitops-operator' -o jsonpath="{.items[0].status.channels[?(@.name==\"$channel\")].currentCSVDesc.relatedImages}" | tr ',][' ' ' | tr -d '"' )
	for image in $images; do
	    # image:    registry.redhat.io/openshift-gitops-1/gitops-rhel8-operator@sha256:b46742d61aa8444b0134959c8edbc96cc11c71bf04c6744a30b2d7e1ebe888a7
	    # source:   registry-proxy.engineering.redhat.com/rh-osbs/openshift-gitops-1-gitops-rhel8-operator
	    # mirrored: default-route-openshift-image-registry.apps.beekhof412.blueprints.rhecoeng.com/openshift-marketplace/openshift-gitops-1-gitops-rhel8-operator
	    sha=$(echo $image | sed 's/.*@/@/')
	    source=$(grep $image mapping.txt | sed -e 's/.*=//' -e 's/:.*//')
	    mirrored=$MIRROR_TARGET/$MIRROR_NAMESPACE/$(basename $source )
	    tag=$IIB
	    if [ $OCP = 12 ]; then
		mirrored=$MIRRORED_IIB
		fulltag=$(basename $source | sha256sum)
		tag=${fulltag:0:6}
	    fi
	    
	    echo $source$sha=$mirrored:$tag >> mirror.map	    
	    #echo -e "  - mirrors:\n    - $mirrored\n    source: $source" >> $ICSP	    
	    echo -e "  - source: $(echo $image | sed -e 's/@.*//')\n    mirrors:\n    - $mirrored" >> $ICSP
	done

	echo "Mirroring $IIB images" 
	oc image mirror -a $PULLSECRET -f mirror.map --continue-on-error --insecure --keep-manifest-list $MIRROR_ARGS 2>&1 | tee images.log

	cat $ICSP
	oc apply -f $ICSP
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

# sed -i 's@rh-osbs/workload-availability@rh-osbs/red-hat-workload-availability@g' icsp.yaml
# sed -i 's@red-hat-workload-availability-node-healthcheck-rhel8-operator@red-hat-workload-availability-node-healthcheck-operator@g' icsp.yaml
# sed -i 's@red-hat-workload-availability-node-remediation-console-rhel8@red-hat-workload-availability-node-remediation-console@g' icsp.yaml
#  - image: registry-proxy.engineering.redhat.com/rh-osbs/red-hat-workload-availability-node-healthcheck-operator-bundle@sha256:de8ba3976dbe6fb33a4a47b6cddde0d1cde0f0ee5c50e0dc52922862c70dd0d5
