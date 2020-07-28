manual starup script

https://github.com/kubernetes-sigs/kind/issues/702#issuecomment-664569840

```
kind create cluster --config local-cluster/kind-cfg.yaml 
helmfile -f local-cluster/helmfile.yaml apply
kubectl apply -f local-cluster/echo-server-infra-test.yaml
kubectl expose replicaset echo --type=LoadBalancer
kubectl apply -f local-cluster/dashboard-admin.yaml
kubectl port-forward --address localhost,0.0.0.0 service/echo 8080:8080
# NOTE: tilt up is broken until I can figure out why helmfile template command doesn't create pods in teh correct namespaces

# disable admin-user

 kubectl delete clusterrolebinding kubernetes-dashboard
```

get scret for kubectl dasboard

```
# https://thorsten-hans.com/access-kubernetes-dashboard-on-rbac-enabled-azure-kubernetes
kubectl -n kube-system describe secret $(kubectl -n kube-system get secret | grep kubernetes-dashboard-token | awk '{print $1}')
```