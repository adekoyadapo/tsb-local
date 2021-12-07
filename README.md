# Service Bridge Deployment testing
## Building
Currently deployed to work on minikube and k8s version < 1.19.0 
### Setup
Ensure the folowing is installed and available
- kubernetes-cli 
`Client Version: v1.21.1`
- tctl version
`1.4.0 +`
- Kubectx from [here](https://github.com/ahmetb/kubectx)
- helm 
`version 3`
### Deployment
1. Create .env file and ensure the following are populated
```
username=      #api username to connect and download binaries and containers
apikey=        #api key for authentication
reg=""         #local or remote registry to store containers which cluster can access 
registry=      #registry with no quotes
cluster_name=  # name of control-plane cluster - found in kube-context
mp_cluster_name= #name of management place cluster - found in kube-context
cp_num= #number of controlplanes to deploy
prefix= #prefix for the controlplane clusters
```
2. Run make commands to setup the management plane and cluster
```
make tsb
```
3. To destroy
```
make destroy
```
