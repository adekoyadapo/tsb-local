ifneq (,$(wildcard ./.env))
    include .env
    export
endif

check-env:
ifndef reg
	$(error Please update .env file and run make prereq)
endif

image-sync: check-env
	tctl install image-sync --username $(username) --apikey $(apikey) --registry $(reg)

mgt: check-env
	minikube start --kubernetes-version=v1.18.20 --memory=8192 \
		--cpus=8 --driver=hyperkit --addons="metallb,metrics-server" \
		--insecure-registry $(reg) -p mp \
		&& sleep 20 && kubectl apply -f mp/metallb-config.yaml
mgt-prereq:
	kubectx mp;
	helm repo add jetstack https://charts.jetstack.io;
	helm upgrade certmanager -n  cert-manager jetstack/cert-manager \
		--namespace cert-manager \
		--create-namespace \
		--set installCRDs=true;
#	kubectl apply -f cert-manager/cert-manager.yaml;
	kubectl wait --for=condition=available --timeout=200s --all deployments -n cert-manager;
	kubectl apply -f elastic/eck-all-in-one.yaml;
	kubectl wait --for=condition=ready --timeout=200s --all pods -n elastic-system;
	kubectl apply -f elastic/es.yaml;
	sleep 15;
	kubectl wait --for=condition=ready --timeout=600s --all pods -n elastic-system;
	tctl install manifest management-plane-operator \
	  --registry ${registry} | kubectl apply -f -;
	kubectl wait --for=condition=available --timeout=120s --all deployments -n tsb;
	kubectl apply -f mp/tsb-server-crt.yaml;

elastic_host :=$(shell kubectl -n elastic-system get service tsb-es-http -o jsonpath={.status.loadBalancer.ingress[0].ip})
tctl_version :=$(shell /usr/local/bin/tctl version --local-only | awk '{print substr($$3,2)}')
mgt-setup:
	mp/tctl-management-plane-secrets.sh;
	kubectl apply -f mp/tctl/managementplanesecrets.yaml;
	sleep 5;
	@envsubst < mp/managementplane-minikube.yaml | kubectl apply -f -;
	sleep 20;
	kubectl wait --for=condition=available --timeout=300s --all deployments -n tsb;
	kubectl create job -n tsb teamsync-bootstrap --from=cronjob/teamsync;
	sleep 30;

ctr: check-env
	minikube start --kubernetes-version=v1.18.20 --memory=8192 \
		--cpus=8 --driver=hyperkit --addons="metallb,metrics-server" \
		--insecure-registry $(reg) -p cp \
		&& sleep 20 && kubectl apply -f cp/metallb-config.yaml;
		kubectx mp;


#elastic_host_ip:
#	shell kubectl -n elastic-system get service tsb-es-http -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
tctl_host :=$(shell kubectl -n tsb get service envoy -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
cp-setup:
	cp/tctl-control-plane.sh;
	kubectx cp;
	kubectl apply -f cp/tctl/${cluster_name}-clusteroperators.yaml;
	sleep 20;
	kubectl wait --for=condition=available --timeout=120s --all deployments -n istio-system;
	kubectl apply -f cp/tctl/${cluster_name}-controlplane-secrets.yaml;
	sleep 20;
	@envsubst < cp/controlplane.yaml | kubectl apply -f -;
	sleep 20;
	kubectl wait --for=condition=available --timeout=120s --all deployments -n istio-system;	

destroy_mp:
	kubectx mp;
	kubectl delete -f mp/elastic/es.yaml --wait=true;
	kubectl delete -f mp/elastic/eck-all-in-one.yaml --wait=true;
	kubectl delete -f mp/cert-manager/certmanager.yaml --wait=true;

bookinfo_app:
	kubectx cp;
	kubectl create namespace bookinfo;
	kubectl label ns bookinfo istio-injection=enabled --overwrite;
	kubectl apply -f tsb/bookinfo.yml -n bookinfo;
	kubectl apply -f tsb/ingress.yaml -n bookinfo;
	kubectl create secret tls bookinfo-certs \
		--key tsb/bookinfo.key \
		--cert tsb/bookinfo.crt -n bookinfo;
	tctl apply -f tsb/tenant.yaml;
	tctl apply -f tsb/workspace.yaml
	tctl apply -f tsb/groups.yaml;
	tctl apply -f tsb/gateway.yaml;

bookinfo_gw :=$(shell kubectl -n bookinfo get service tsb-gateway-bookinfo -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
traffic_gen:
	kubectx cp
	@envsubst < tsb/traffic-gen.yaml | kubectl apply -f -;

test:
#	elastic_host="$(shell 'kubectl -n elastic-system get service tsb-es-http -o jsonpath={.status.loadBalancer.ingress[0].ip}')"
#	@envsubst < mp/tctl/managementplaneoperator-minikube.yaml;
#	-@echo $(tctl_version)
#	-@echo $(elastic_host)
#	-@echo $(elastic_password)
#	-@echo $(elastic_ca_cert)
#	kubectx mp;
#	elastic_host="${MAKE} elastic_host_ip"
#	-@echo ${elastic_host}
#	@envsubst < cp/controlplane.yaml;
destroy:
	minikube delete --all