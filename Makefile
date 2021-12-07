ifneq (,$(wildcard ./.env))
    include .env
    export
endif

tsb: mgt mgt-prereq mgt-setup ctr-deploy output

tsb-app: mgt mgt-prereq mgt-setup ctr kx-mp cp-setup bookinfo_app traffic_gen kx-mp output traffic_gen

tctl_version :=$(shell /usr/local/bin/tctl version --local-only | awk '{print substr($$3,2)}')

check-env:
ifndef reg
	$(error Please update .env file and run make prereq)
endif

image-sync: check-env
	tctl install image-sync --username $(username) --apikey $(apikey) --registry $(reg)

mgt: check-env
	@echo "===========================";
	@echo "Creating MGT cluster";
	@minikube start --kubernetes-version=$(k8s) --memory=8172 \
		--cpus=4 --addons="metallb,metrics-server" \
		--container-runtime=docker \
		--driver=kvm2 \
		--insecure-registry $(reg) -p ${mp_cluster_name} >> /dev/null 2>&1
	@kubectl wait --for=condition=available --timeout=300s --all deployments -A >> /dev/null
	@kubectl wait --for=condition=ready --timeout=300s --all pods -A >> /dev/null
	@echo "MGT cluster created";
	$(eval cluster :=${mp_cluster_name})
	@envsubst < .env > tmp
	@echo "Creating loadBalancer IP pool";
	@${MAKE} metallb >> /dev/null 

metallb:
	@echo "Getting the cluster IP and creating loadBalancer IP ranges..."
	$(eval metallbip :=$(shell infra/nextip.sh))
	$(eval metallbip2 :=$(shell infra/nextip2.sh))
	@envsubst < infra/metallb-config.yaml | kubectl apply -f - >> /dev/null
	@echo "loadBalancer IP ranges configured..."
	@echo "default range ${metallbip}"
	@echo "extra range ${metallbip2}";

mgt-prereq:
	@echo "===========================";
	@echo "Creating MGT prereq, certmanager and elasticsearch";
	@kubectx ${mp_cluster_name} >> /dev/null;
	@echo "Creating certmanager...";
	@helm repo add jetstack https://charts.jetstack.io >> /dev/null;
	@helm upgrade --install certmanager -n  cert-manager jetstack/cert-manager \
		--namespace cert-manager \
		--create-namespace \
		--set installCRDs=true >> /dev/null;
	@kubectl wait --for=condition=available --timeout=200s --all deployments -n cert-manager >> /dev/null;
	@echo "certmanager deployed...";
	@echo "Creating elasticsearch";
	@kubectl apply -f elastic/eck-all-in-one.yaml >> /dev/null 2>&1;
	@sleep 30;
	@kubectl wait --for=condition=ready --timeout=200s --all pods -n elastic-system >> /dev/null;
	@kubectl apply -f elastic/es.yaml >> /dev/null;
	@sleep 30;
	@echo "waiting for elasticsearch... This can take up to 5min(s)"
	@kubectl wait --for=condition=ready --timeout=600s --all pods -n elastic-system >> /dev/null;
	@sleep 300s;
	@echo "elasticsearch deployed...";
	@echo "===========================";
	@echo "Setting up managementplane";
	@tctl install manifest management-plane-operator \
	  --registry ${registry} | kubectl apply -f - >> /dev/null;
	@kubectl wait --for=condition=available --timeout=120s --all deployments -n tsb >> /dev/null;
	@kubectl wait --for=condition=ready --timeout=300s --all pods -n elastic-system >> /dev/null;
	@kubectl apply -f mp/tsb-server-crt.yaml >> /dev/null;
	@kubectl wait --for=condition=ready --timeout=120s --all pods -n tsb >> /dev/null;
	@echo "managementplane setup complete...";

mgt-setup: kx-mp
	@echo "===========================";
	@echo "Deploying managementplane...";
	$(eval elastic_host :=$(shell kubectl -n elastic-system get service tsb-es-http -o jsonpath='{.status.loadBalancer.ingress[0].ip}'))
	@mp/tctl-management-plane-secrets.sh >> /dev/null;
	@kubectl apply -f mp/tctl/managementplanesecrets.yaml >> /dev/null;
	@envsubst < mp/managementplane-minikube.yaml | kubectl apply -f - >> /dev/null;
	@sleep 30;
	@echo "waiting for managementplane...";
	@kubectl wait --for=condition=available --timeout=600s --all deployments -n tsb >> /dev/null;
	@kubectl create job -n tsb teamsync-bootstrap --from=cronjob/teamsync >> /dev/null;
	@kubectl wait --for=condition=ready --timeout=500s --all pods -n tsb >> /dev/null
	@echo "managementplane deployed...";

ctr-deploy: 
	@echo "===========================";
	@echo "Creating controlplane clusters...";
	@${MAKE} ctr >> /dev/null;
	@echo "${cp_num} Controlplane clusters created ...";
	@${MAKE} kx-mp >> /dev/null;
	@echo "===========================";
	@echo "deploying controlplane...";
	@${MAKE} cp-setup >> /dev/null;
	@echo "Controlplane... deployed";


ctr: SHELL:=/bin/bash
ctr: check-env
	num=1 ; while [[ $$num -le ${cp_num} ]] ; \
	do minikube start --kubernetes-version=$(k8s) --memory=16384 \
		--cpus=6 --addons="metallb,metrics-server" \
		--container-runtime=docker \
		--driver=kvm2 \
		--insecure-registry $(reg) -p ${prefix}-$$num >> /dev/null 2>&1; \
	    kubectl wait --for=condition=available --timeout=300s --all deployments -A >> /dev/null; \
	    kubectl wait --for=condition=ready --timeout=300s --all pods -A >> /dev/null ; \
	    export cluster=${prefix}-$$num; \
	    envsubst < .env > tmp; \
		${MAKE} metallb >> /dev/null ; \
		((num = num + 1)) ;\
	done

kx-mp:
	@kubectx ${mp_cluster_name} >> /dev/null;
	@sleep 5;

cp-setup: kx-mp
	$(eval tctl_host :=$(shell kubectl -n tsb get service envoy -o jsonpath='{.status.loadBalancer.ingress[0].ip}'))
	$(eval elastic_host :=$(shell kubectl -n elastic-system get service tsb-es-http -o jsonpath='{.status.loadBalancer.ingress[0].ip}'))
	num=1 ; while [[ $$num -le ${cp_num} ]] ; \
	do export cluster=${prefix}-$$num; \
	   cp/tctl-control-plane.sh; \
	   kubectx ${prefix}-$$num >> /dev/null; \
	   sleep 10; \
	   kubectl apply -f cp/tctl/${prefix}-$$num-clusteroperators.yaml >> /dev/null; \
	   kubectl wait --for=condition=available --timeout=120s --all deployments -n istio-system >> /dev/null; \
	   kubectl wait --for=condition=ready --timeout=300s --all pods -n istio-system >> /dev/null; \
	   kubectl apply -f cp/tctl/${prefix}-$$num-controlplane-secrets.yaml >> /dev/null; \
	   sleep 5; \
	   envsubst < cp/controlplane.yaml | kubectl apply -f - >> /dev/null; \
	   kubectl wait --for=condition=available --timeout=300s --all deployments -n istio-system >> /dev/null; \
	   kubectl wait --for=condition=ready --timeout=300s --all pods -n istio-system >> /dev/null; \
	   kubectx ${mp_cluster_name} >> /dev/null;	\
	   ((num = num + 1)) ;\
	done

destroy_mp:
	@kubectx mp >> /dev/null;
	@kubectl delete -f mp/elastic/es.yaml --wait=true;
	@kubectl delete -f mp/elastic/eck-all-in-one.yaml --wait=true;
	@kubectl delete -f mp/cert-manager/certmanager.yaml --wait=true;
	@sleep 10;

output: kx-mp
	@echo "===========================";
	@echo "Getting Endpoints and Credentials...";
	$(eval tctl_host :=$(shell kubectl -n tsb get service envoy -o jsonpath='{.status.loadBalancer.ingress[0].ip}'))
	@echo "Visit https://${tctl_host}:8443"
	@echo "Credentials"
	@echo " username: admin"
	@echo " password: admin"


bookinfo_app:
	@echo "===========================";
	@echo "Deploying bookinfo app...";
	@kubectl apply -f tsb/bookinfo/bookinfo.yml -n bookinfo >> /dev/null;
	@kubectl apply -f tsb/bookinfo/ingress.yaml -n bookinfo >> /dev/null;
	@kubectl wait --for=condition=available --timeout=300s --all deployments -n bookinfo >> /dev/null;
	@kubectl wait --for=condition=ready --timeout=300s --all pods -n bookinfo >> /dev/null;
	@kubectl create secret tls bookinfo-certs \
		--key tsb/bookinfo/bookinfo.key \
		--cert tsb/bookinfo/bookinfo.crt -n bookinfo >> /dev/null;
	@echo "bookinfo deployed...";

bookinfo_app_tsb:
	@tctl apply -f tsb/bookinfo/tenant.yaml;
	@tctl apply -f tsb/bookinfo/workspace.yaml
	@tctl apply -f tsb/bookinfo/groups.yaml;
	@tctl apply -f tsb/bookinfo/gateway.yaml;
	@sleep 60;


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
	@echo "===========================";
	@echo "removing clusters...";
	@minikube delete --all >> /dev/null 2>&1
	@echo "Cluster removed...";
	@rm -rf tmp 

