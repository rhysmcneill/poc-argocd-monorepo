.PHONY: help bootstrap ui password status sync clean

ARGOCD_NS      := argocd
ARGOCD_VERSION := 7.8.0
ARGOCD_PORT    := 8080

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

bootstrap: ## Install ArgoCD on minikube and seed the root Application
	@bash scripts/bootstrap-minikube.sh

ui: ## Port-forward the ArgoCD UI to localhost:$(ARGOCD_PORT)
	@echo "ArgoCD UI → http://localhost:$(ARGOCD_PORT)"
	@echo "Username  → admin"
	@echo "Password  → run: make password"
	@kubectl port-forward svc/argocd-server -n $(ARGOCD_NS) $(ARGOCD_PORT):443

password: ## Print the initial ArgoCD admin password
	@kubectl get secret argocd-initial-admin-secret \
		-n $(ARGOCD_NS) \
		-o jsonpath='{.data.password}' | base64 -d && echo

status: ## Show status of all ArgoCD Applications
	@kubectl get applications -n $(ARGOCD_NS)

sync: ## Force a sync of the root Application
	@kubectl patch application root \
		-n $(ARGOCD_NS) \
		--type merge \
		-p '{"operation":{"initiatedBy":{"username":"make"},"sync":{"revision":"HEAD"}}}'

clean: ## Uninstall ArgoCD and remove all Applications from minikube
	@echo "Removing ArgoCD..."
	@helm uninstall argocd -n $(ARGOCD_NS) || true
	@kubectl delete namespace $(ARGOCD_NS) --ignore-not-found
	@echo "Done."
