#!/usr/bin/env zsh
# tctl variable
tctl_org=tetrate
tctl_username=admin
tctl_password=admin
tctl_tenant=minikube
cluster_name=${cluster}
# elastic
es_password=$(kubectl get secret elastic-credentials -n tsb -o jsonpath={.data.password} | base64 -d)
es_username=$(kubectl get secret elastic-credentials -n tsb -o jsonpath={.data.username} | base64 -d)
es_cacert=$(kubectl get secret es-certs -n tsb -o json | jq -r '.data["ca.crt"]' | base64 -d)
tctl_host=$(kubectl -n tsb get service envoy -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# tctl setup
tctl config clusters set default --bridge-address ${tctl_host}:8443 --tls-insecure
tctl config users set admin --org ${tctl_org} --username ${tctl_username} --password ${tctl_password} --tenant ${tctl_tenant}
tctl config profiles set default --cluster="default" --username=${tctl_password}
tctl config profiles set-current "default"
export cluster_name=${cluster}
envsubst < cp/cp-cluster.yaml | tctl apply -f -
sleep 5
tctl install manifest cluster-operators --registry ${registry} > cp/tctl/${cluster}-clusteroperators.yaml
tctl install manifest control-plane-secrets \
    --elastic-password ${es_password} \
    --elastic-username ${es_username} \
    --elastic-ca-certificate ${es_cacert} \
    --cluster ${cluster} \
    --controlplane istio-system \
    --xcp-certs "$(tctl install cluster-certs --cluster ${cluster})" > cp/tctl/${cluster}-controlplane-secrets.yaml
