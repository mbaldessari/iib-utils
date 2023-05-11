# IIB Utilities

A set of ansible plays to fetch an IIB (Image Index Bundle, aka a container created by the operator sdk
that contains a bunch of references to operators that can be installed in an OpenShift cluster)

Run `make lookup` to see which IIBs are available.

Typically IIB are pre-release stuff that leaves on some internal boxes. What these scripts do is fetch
the IIB internally, mirror it to the registry inside the cluster, parse all the needed images and mirror
those to the internal cluster registry and then set up the registries.conf files on all nodes so
that the images used are the ones pointing to the internal cluster.

Run `make iib` with the following environment variables set:

* KUBEADMINAPI=https://api.mcg-hub.blueprints.rhecoeng.com:6443
* IIB=492329
* KUBEADMINPASS="11111-22222-33333-44444"
