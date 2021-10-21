ifneq (,$(wildcard ./.env))
    include .env
    export
endif

tsb: mgt mgt-prereq mgt-setup ctr kx-mp cp-setup output

tsb-app: mgt mgt-prereq mgt-setup ctr kx-mp cp-setup kx-mp output bookinfo_app traffic_gen

tctl_version :=$(shell /usr/local/bin/tctl version --local-only | awk '{print substr($$3,2)}')

check-env:
ifndef reg
	$(error Please update .env file and run make prereq)
endif

image-sync: check-env
	tctl install image-sync --username $(username) --apikey $(apikey) --registry $(reg)

mgt: check-env
	minikube start --kubernetes-version=$(k8s) --memory=8192 \
		--cpus=8 --driver=hyperkit --addons="metallb,metrics-server" \
		--insecure-registry $(reg) -p mp \
		&& sleep 20 && kubectl apply -f mp/metallb-config.yaml
mgt-prereq:
	@kubectx mp >> /dev/null;
	helm repo add jetstack https://charts.jetstack.io;
	helm install certmanager -n  cert-manager jetstack/cert-manager \
		--namespace cert-manager \
		--create-namespace \
		--set installCRDs=true;
#	kubectl apply -f cert-manager/cert-manager.yaml;
	kubectl wait --for=condition=available --timeout=200s --all deployments -n cert-manager;
	kubectl apply -f elastic/eck-all-in-one.yaml;
	kubectl wait --for=condition=ready --timeout=200s --all pods -n elastic-system;
	kubectl apply -f elastic/es.yaml;
	sleep 30;
	kubectl wait --for=condition=ready --timeout=200s --all pods -n elastic-system;
	tctl install manifest management-plane-operator \
	  --registry ${registry} | kubectl apply -f -;
	kubectl wait --for=condition=available --timeout=120s --all deployments -n tsb;
	kubectl wait --for=condition=ready --timeout=300s --all pods -n elastic-system;
	kubectl apply -f mp/tsb-server-crt.yaml;
	kubectl wait --for=condition=ready --timeout=120s --all pods -n tsb;

mgt-setup:
	$(eval elastic_host :=$(shell kubectl -n elastic-system get service tsb-es-http -o jsonpath='{.status.loadBalancer.ingress[0].ip}'))
	mp/tctl-management-plane-secrets.sh;
	kubectl apply -f mp/tctl/managementplanesecrets.yaml;
	sleep 20;
	@envsubst < mp/managementplane-minikube.yaml | kubectl apply -f -;
	sleep 20;
	kubectl wait --for=condition=available --timeout=300s --all deployments -n tsb;
	kubectl create job -n tsb teamsync-bootstrap --from=cronjob/teamsync;
	sleep 30;

ctr: check-env
	minikube start --kubernetes-version=$(k8s) --memory=8192 \
		--cpus=8 --driver=hyperkit --addons="metallb,metrics-server" \
		--insecure-registry $(reg) -p cp \
		&& sleep 20 && kubectl apply -f cp/metallb-config.yaml;

kx-mp:
	@kubectx mp >> /dev/null;
	@sleep 3

cp-setup:
	$(eval tctl_host :=$(shell kubectl -n tsb get service envoy -o jsonpath='{.status.loadBalancer.ingress[0].ip}'))
	$(eval elastic_host :=$(shell kubectl -n elastic-system get service tsb-es-http -o jsonpath='{.status.loadBalancer.ingress[0].ip}'))
	cp/tctl-control-plane.sh;
	@kubectx cp >> /dev/null;
	kubectl apply -f cp/tctl/${cluster_name}-clusteroperators.yaml;
	sleep 20;
	kubectl wait --for=condition=available --timeout=120s --all deployments -n istio-system;
	kubectl apply -f cp/tctl/${cluster_name}-controlplane-secrets.yaml;
	sleep 20;
	@envsubst < cp/controlplane.yaml | kubectl apply -f -;
	sleep 20;
	kubectl wait --for=condition=available --timeout=300s --all deployments -n istio-system;
	@sleep 60;

destroy_mp:
	-@kubectx mp >> /dev/null;
	kubectl delete -f mp/elastic/es.yaml --wait=true;
	kubectl delete -f mp/elastic/eck-all-in-one.yaml --wait=true;
	kubectl delete -f mp/cert-manager/certmanager.yaml --wait=true;

output: kx-mp
	-@sleep 3;
	-@echo "Visit https://$(shell kubectl -n tsb get service envoy -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):8443"
	-@echo "Credentials\n username: admin \n password: admin"

kx-cp:
	@kubectx cp >> /dev/null;
	@sleep 3

bookinfo_app: kx-cp
	@sleep 5;
	kubectl apply -f tsb/bookinfo/bookinfo.yml -n bookinfo;
	kubectl apply -f tsb/bookinfo/ingress.yaml -n bookinfo;
	kubectl create secret tls bookinfo-certs \
		--key tsb/bookinfo/bookinfo.key \
		--cert tsb/bookinfo/bookinfo.crt -n bookinfo;
	tctl apply -f tsb/bookinfo/tenant.yaml;
	tctl apply -f tsb/bookinfo/workspace.yaml
	tctl apply -f tsb/bookinfo/groups.yaml;
	tctl apply -f tsb/bookinfo/gateway.yaml;


traffic_gen: kx-cp
	$(eval bookinfo_gw :=$(shell kubectl -n bookinfo get service tsb-gateway-bookinfo -o jsonpath='{.status.loadBalancer.ingress[0].ip}'))
	@envsubst < tsb/bookinfo/traffic-gen.yaml | kubectl apply -f -;

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
	-@kubectx mp >> /dev/null
	$(eval tctl_host :=$(shell kubectl -n tsb get service envoy -o jsonpath='{.status.loadBalancer.ingress[0].ip}'))
	$(eval elastic_host :=$(shell kubectl -n elastic-system get service tsb-es-http -o jsonpath='{.status.loadBalancer.ingress[0].ip}'))
	-@echo ${elastic_host}
	-@echo ${tctl_host}
destroy:
	minikube delete --all