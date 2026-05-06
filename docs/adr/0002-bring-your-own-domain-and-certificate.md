# ADR-0002: Bring Your Own Domain and Bring Your Own Certificate for the public ingress

- **Status:** Accepted
- **Date:** 2026-05-06
- **Deciders:** Platform engineering owners of `Azure/live-voice-practice`
- **Scope:** The optional public ingress introduced by [ADR-0001](0001-manual-testing-microphone-application-gateway.md). Specifically, the question of who owns the public hostname presented to testers, and who owns the TLS certificate served on that hostname.
- **Supersedes:** None
- **Related:** [ADR-0001](0001-manual-testing-microphone-application-gateway.md) — Use Application Gateway with WAF and IP allow-list to enable manual end-user testing of voice features

---

## Context and Problem Statement

[ADR-0001](0001-manual-testing-microphone-application-gateway.md) established that, when manual browser-based testing of voice features is required against a network-isolated deployment, an Application Gateway (WAF v2) is provisioned in front of the existing internal Azure Container Apps environment. That gateway terminates TLS on a public listener.

Two distinct artifacts must exist for that public listener to be reachable by a real browser, by a real human, on a real workstation:

1. **A public DNS name** that resolves to the Application Gateway's public IP — the address testers type into a browser.
2. **A TLS certificate** issued for that DNS name by a certification authority whose root the testers' browsers trust by default.

Both are necessary. Without (1), the gateway is reachable only by IP, which forces a host-header configuration that is inconvenient and fragile. Without (2), modern browsers either refuse the connection outright or silently disable browser APIs that this application depends on (`getUserMedia` for the microphone, in particular, requires a secure context with a trusted certificate; certificate-warning bypasses do not lift this restriction in Chrome, Edge, or Firefox).

These artifacts can be supplied in different ways. The choice has direct consequences for who can deploy the accelerator, how many people can deploy it independently in parallel, what governance constraints apply, and what the failure modes look like. This ADR records that choice.

---

## Decision Drivers

1. **Multi-deployer scalability.** This accelerator is consumed by many teams and individuals, each operating in their own subscription, with their own resource group, often with their own organizational policies. Any artifact that requires central coordination becomes a bottleneck and a single point of failure.
2. **Tenant and organizational isolation.** A deployment in one organization must not depend on, share state with, or be observable from a deployment in another organization. Identifiers, certificates, and DNS records produced for one deployment must not exist in another deployment's blast radius.
3. **Compatibility with deployer governance.** Many organizations have explicit constraints on which certification authorities they accept, how DNS names are issued, and what data may be sent to third parties. The accelerator must accommodate these constraints rather than override them.
4. **Operational simplicity for the accelerator itself.** The accelerator's Bicep, scripts, and CI must not take ownership of artifacts whose lifecycle they cannot reliably manage (renewals, revocations, ownership transfers, payment, organizational signoff). Owning such lifecycles in the accelerator codebase creates ongoing toil with no proportionate user benefit.
5. **Auditability of the deployer's choices.** The accelerator should record what was supplied (a hostname, a certificate reference) without recording how the deployer obtained it. The "how" is the deployer's choice and the deployer's audit trail.
6. **Reversibility.** A deployer must be able to add, change, or remove their domain and certificate without redeploying the application or its environment. The accelerator must not bind itself to a specific name or certificate at provisioning time.

---

## Considered Options

### Option 1 — The accelerator owns a single public domain, deployers receive a subdomain

The accelerator project would register and operate a single root domain. Each deployment would receive a subdomain on it, either statically assigned or dynamically allocated, and the accelerator would issue and renew certificates for those subdomains using a centrally configured CA integration.

**Pros**
- A new deployer needs nothing of their own to start.
- The accelerator's documentation can show a complete, working URL out of the box.
- Renewals are automated by the accelerator's central plumbing.

**Cons**
- The accelerator project becomes a registrar, a DNS operator, and a certificate operator for every consumer, including consumers in other organizations and other tenants. This is a fundamentally different mandate from "an accelerator template."
- Centralized DNS and certificate issuance for third-party deployments creates a shared dependency: an outage, a policy change, an ownership transfer, or a billing lapse in the accelerator's central infrastructure breaks every deployment everywhere.
- Cross-tenant trust: a certificate issued by the accelerator's central authority for a name pointing at a deployer's resources implicitly says the accelerator vouches for that deployer's binding. The accelerator project is not in a position to vouch.
- Privacy: certificate transparency logs publish every issued certificate. Every deployment's existence, name, and approximate timing become public artifacts of the accelerator project.
- Many enterprise consumers cannot use external-controlled DNS or certificates due to internal policy. This option excludes them.
- Naming collisions, abuse handling, takedown obligations, and quota allocation across deployers all become the accelerator project's operational problem.

### Option 2 — The accelerator issues a temporary self-signed certificate on a deployer-supplied DNS name

The accelerator generates a self-signed certificate at provision time, names the listener after a hostname the deployer provides, and lets the deployer rotate to a publicly-trusted certificate later if they choose.

**Pros**
- Zero external dependency. The accelerator can deploy a complete, internally-consistent listener without any third-party interaction.
- Deployment is uniformly deterministic across consumers.

**Cons**
- A self-signed certificate is rejected by browsers' secure-context requirement for `getUserMedia`. The very capability this accelerator exists to validate — microphone capture in a real browser — does not function on a self-signed listener. Bypassing the warning by clicking through does not lift the restriction; modern browsers gate `getUserMedia` on the *origin* being a secure context, not on the user accepting the certificate.
- Even when the platform-level secure-context restriction is bypassed via developer flags (e.g. Chromium's `--unsafely-treat-insecure-origin-as-secure`), the bypass is per-launch, per-workstation, and inadequate for a multi-tester scenario.
- Self-signed material has no rotation story and no auditable issuer. It is acceptable as a temporary bootstrap but unacceptable as the steady state for the listener that testers actually hit.

### Option 3 — Bring Your Own Domain and Bring Your Own Certificate (BYO-D + BYO-C)

The accelerator does not own, register, route, or issue any of: domains, DNS records, TLS certificates. The deployer supplies all three.

The accelerator's responsibility is to:
- Provision the Application Gateway in a deterministic, secure-by-default state.
- Allocate and expose a Public IP whose value is known after provisioning so the deployer can configure DNS.
- Accept a reference to a certificate located in the deployer's Key Vault, on the listener configuration, with a reference contract that does not encode the certificate's issuer, validity period, or rotation policy.
- Document the operator runbook end to end: how to point a domain at the gateway, how to obtain a certificate for that name, how to upload the certificate to Key Vault, and how to attach it to the listener.

**Pros**
- Each deployment is self-contained. There is no shared dependency between deployments. Outages, policy changes, payment lapses, and ownership transfers are bounded to a single deployment and its single owning organization.
- The deployer chooses a domain consistent with their organization's naming convention and an issuer consistent with their organization's CA policy. Enterprise consumers with strict CA, DNS, or supply-chain rules can meet those rules without modification to the accelerator.
- Certificate transparency exposes only the deployer's own choices, in the deployer's own logs and records. The accelerator project is not implicated by, nor responsible for, any deployment's public footprint.
- The accelerator codebase has no recurring operational responsibility beyond the Bicep that provisions infrastructure. It does not own renewals, revocations, billing, or abuse handling.
- Subdomains of a deployer's chosen domain are free to create, allowing the same deployer to host multiple deployments (for example, separating dev and prod environments) at the cost of one domain.
- The certificate reference contract does not constrain the deployer's choice of issuer. Public CAs, internal enterprise CAs, free CAs, and paid CAs are all equally acceptable to the accelerator's Bicep.

**Cons**
- A first-time deployer must register a domain and obtain a certificate before testers can reach the deployment. Both are deployer-side prerequisites and are not provided by the accelerator.
- The accelerator's documentation must guide deployers through these prerequisites. Deployers unfamiliar with DNS and TLS face a learning curve.
- No single "happy URL" can be published in the accelerator's marketing material; each deployment's URL is owned by its deployer.

### Option 4 — Bring Your Own Domain, accelerator-managed certificate

The deployer supplies a domain. The accelerator issues and renews a certificate for it on behalf of the deployer, integrating with a specific CA chosen by the accelerator project.

**Pros**
- One fewer artifact for the deployer to obtain.
- A homogeneous renewal story across deployments, defined by the accelerator.

**Cons**
- The accelerator imposes a specific CA on every consumer. Consumers whose policies forbid that CA are blocked. Consumers whose policies require a specific other CA are blocked.
- The accelerator becomes responsible for renewal liveness in every deployment. A bug in the accelerator's renewal path silently expires every consumer's certificate.
- Certificate issuance involves domain validation, which means the accelerator must hold credentials to prove control over the deployer's domain. Either it requires credentials it should not have, or it asks the deployer to do the validation step manually, in which case the work split is the same as in Option 3 with extra coupling.
- For renewal automation specifically, mainstream patterns require either a long-lived secret with delegated rights on the deployer's DNS zone or a long-lived service principal with similar rights. Both choices push the accelerator into a privilege the accelerator project cannot reasonably hold across organizations and tenants.

---

## Decision Outcome

**Chosen option: Option 3 — Bring Your Own Domain and Bring Your Own Certificate.**

The accelerator does not register, route, issue, renew, or store any domain or certificate. Deployers are responsible for:

1. Acquiring a domain or subdomain they control.
2. Creating a DNS A record that points the desired hostname at the Application Gateway's public IP, which the accelerator outputs after provisioning.
3. Obtaining a TLS certificate for that hostname from any certification authority their organization accepts and whose root is trusted by their testers' browsers.
4. Importing that certificate into the deployer's Azure Key Vault.
5. Updating the Application Gateway listener (in the Azure portal, by Bicep parameter, or by CLI) to reference the imported certificate.

The accelerator is responsible for:

1. Provisioning the Application Gateway in a state where the Public IP is allocated, the backend pool already targets the internal application correctly, and the listener boots with a placeholder configuration that will not serve traffic to testers.
2. Outputting the Public IP and the resource identifiers needed by the deployer's runbook.
3. Documenting the runbook end to end.
4. Accepting the deployer's certificate reference once provided and using it on the listener without imposing constraints on the certificate's issuer, validity period, or rotation cadence.

This split is the smallest contract that lets the accelerator deploy a working, secure-by-default ingress while leaving every artifact whose lifecycle it cannot manage under the deployer's control.

---

## Consequences

### Positive

- **Each deployment is independent.** No shared root domain, no shared CA, no central account, no central credential. A failure in one deployment is bounded to that deployment.
- **Compatible with enterprise governance.** Deployers operating under strict CA, DNS, or organizational naming policies can comply by choosing accordingly. The accelerator does not need to be modified.
- **Deployer keeps ownership of identity-bearing artifacts.** The hostname, the certificate, and the trust chain that ties them together are deployer-owned. The accelerator project does not vouch for any deployment.
- **Subdomain reuse for multi-environment scenarios.** A deployer who registers a single domain can host multiple environments (`dev`, `prod`, `staging`, etc.) by creating subdomains, with no additional accelerator-side work and no per-environment domain cost.
- **The accelerator codebase carries no recurring operational responsibility for domains or certificates.** No renewal cron, no central billing, no abuse intake, no quota allocation. The Bicep and runbook are sufficient.
- **Reversible.** Adding, changing, or removing a domain or a certificate does not redeploy the application, does not change the application's FQDN inside the VNet, and does not affect any backend service.

### Negative

- **First-time setup friction.** A deployer must register a domain and obtain a certificate before the gateway is usable for testers. The runbook must guide both steps explicitly, including how a deployer with no prior experience can complete them.
- **Per-deployer cost.** Domains have a recurring cost, paid by each deployer. Certificates may have a cost depending on the deployer's chosen issuer.
- **No published "demo URL".** Accelerator documentation cannot show a single working URL because every deployment has a different one.
- **DNS propagation timing.** A deployer who configures DNS may need to wait for propagation before certificate validation succeeds and before testers can reach the gateway.

### Mitigations

- The accelerator's runbook is the durable artifact that compensates for the first-time setup friction. It must be kept current, must enumerate prerequisites explicitly, and must be testable end to end on a fresh deployment.
- The accelerator's listener boots in a state that does not serve real traffic to testers. The deployer's configuration is the gating step, not a race condition. Misconfigured deployments fail closed.
- The Bicep parameter that accepts a certificate reference is optional and may be left unset on the first deploy. The deployer can complete the certificate side after provisioning, in the portal, without re-running Bicep.
- The Network Security Group on the Application Gateway subnet is provisioned in a deny-by-default state. Even when DNS and certificate are not yet configured, no public traffic reaches the gateway. Testers' source IPs must be added explicitly by the deployer when ready.

---

## Operational Implications

- **Domain acquisition** is a deployer task. The runbook lists what to look for in a domain registrar (control of DNS for the chosen domain, ability to publish A and TXT records) but does not select one for the deployer.
- **Certificate acquisition** is a deployer task. The runbook lists the requirements the certificate must meet (issued for the chosen hostname, issued by a CA whose root is in mainstream browser trust stores, valid at the time of testing) but does not select an issuer for the deployer.
- **Certificate import into Key Vault** is documented as a portal step and as a CLI step. The accelerator's Bicep does not embed the certificate; it references it.
- **Certificate renewal** is a deployer task at whatever cadence the deployer's chosen issuer requires. The accelerator's Bicep does not renew certificates.
- **DNS record management** is a deployer task. The runbook shows the records that must exist (one A record for the listener hostname; TXT records as required by the deployer's chosen CA for domain validation) but does not manage them.
- **Rotation** is a deployer task. The accelerator's Bicep accepts a Key Vault certificate identifier; updating that identifier is the rotation interface.

---

## What This ADR Does Not Decide

This ADR records the *boundary* between the accelerator and the deployer. It does not select:

- A domain registrar.
- A DNS provider.
- A certification authority.
- An ACME client (or no ACME client).
- A renewal cadence.
- A naming convention for hostnames.

Each of those is a deployer-side choice. The accelerator's runbook may list options to help a deployer evaluate, but the runbook does not endorse one over another, and the Bicep does not depend on any of them.

---

## Out of Scope

- Steady-state production exposure of the application. This decision is made in the context of [ADR-0001](0001-manual-testing-microphone-application-gateway.md), which is itself scoped to manual testing windows. A production exposure pattern would re-evaluate domain and certificate ownership against a different set of drivers (custom domains as a product feature, multi-region routing, identity-aware proxying, etc.).
- Identity layering on top of the listener (Entra ID, AAD App Proxy, OIDC). This ADR does not preclude such layering; it simply does not address it.
- The mechanics of upstream contribution to the Azure AI Landing Zones repository. Any parameter contract introduced by this decision is proposed upstream as a separate work item.

---

## References

- [ADR-0001 — Application Gateway pattern for manual testing](0001-manual-testing-microphone-application-gateway.md)
- [Azure Application Gateway — Key Vault certificate references](https://learn.microsoft.com/en-us/azure/application-gateway/key-vault-certs)
- [`docs/network-isolation-jumpbox-runbook.md`](../network-isolation-jumpbox-runbook.md) — Manual UI testing limitation section
- MDN: [Secure contexts and `getUserMedia`](https://developer.mozilla.org/en-US/docs/Web/API/MediaDevices/getUserMedia#privacy_and_security)
