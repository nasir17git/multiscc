# multiscc


```
- `./create-cluster.sh` 이후 http://localhost:30002로 argoCD접근 (admin/admin1!)
- kubectl apply -f ./helmtest/application/argocd.yaml -n argocd
  - application 등록되면서 자동동기화
```