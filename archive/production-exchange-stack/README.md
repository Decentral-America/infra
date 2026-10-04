# Production exchange web stack (archived, NOT reconciled)

These manifests are the **only git copies** of the production web apps that
ran on the LKE cluster `decentral-cluster` (Linode cluster id 513120), which
has since been deleted. They were copied onto the testnet cluster
`dcc-peer-testnet` (615553) in August 2026 as a migration rehearsal, then
retired from it in the testnet "shared 8 GB bundle" cleanup (PR #171).

What is here:

| Path | What it is |
|------|------------|
| `exchange/deployments.yaml`, `services.yaml` | wallet (`decentral.exchange`), chart / tradeview (`charts.decentral.exchange`), explorer (`decentralscan.com`), data-service frontend, candles and pairs workers, data-service docs (`data-service.decentralchain.io`), postgres-sync backend |
| `exchange/ingress.yaml` | ingress-nginx Ingress objects for the hosts above |
| `exchange/cluster-issuer.yaml` | cert-manager `letsencrypt-prod` ClusterIssuer (it was never applied on 615553; see its header) |
| `exchange/postgres.secret.yaml`, `manual-tls-backup.secret.yaml` | SOPS-encrypted Secrets (testnet age key, same recipient as `clusters/testnet/*.secret.yaml`). They are still encrypted; nothing here is plaintext. |
| `exchange-platform/` | the ingress-nginx and cert-manager HelmReleases that existed only to serve this stack |
| `flux/exchange.yaml`, `flux/exchange-platform.yaml` | the two Flux `Kustomization` objects that used to reconcile the two directories above. Their `spec.path` still points at the old `./clusters/testnet/apps/...` locations, kept unchanged as a record of how they were wired. |

Facts to know before reusing any of this:

- **Production DNS was never cut over to the testnet cluster.** The hosts
  above kept resolving to the production cluster the whole time; the copy on
  615553 only ever answered requests addressed to its own NodeBalancer IP.
- **Flux does not reconcile anything under `archive/`.** The testnet root
  Kustomization is `./clusters/testnet` (see
  `clusters/testnet/flux-system/gotk-sync.yaml`) and no Flux Kustomization
  points into this directory. Renovate's `kubernetes` and `flux` managers only
  match `clusters/**`, so these files get no dependency bumps either.
- The testnet cluster no longer runs helm-controller, ingress-nginx or
  cert-manager, and it has no `role=exchange` node pool. A production rebuild
  needs its own cluster with those pieces, plus a Flux install that includes
  `helm-controller`.
- Image tags are as they were in August 2026 (`blockchaincostarica/*`). Check
  each against the current production release before reusing it.

Kept for a future production rebuild. Do not add these paths back to
`clusters/testnet/kustomization.yaml`.
