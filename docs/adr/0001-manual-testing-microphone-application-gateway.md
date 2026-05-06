# ADR-0001: Use Application Gateway with WAF and IP allow-list to enable manual end-user testing of voice features

- **Status:** Accepted
- **Date:** 2026-05-06
- **Deciders:** Platform engineering owners of `Azure/live-voice-practice`
- **Scope:** Network-isolated deployments (`enableNetworkIsolation = true`) where the app must be exercised by a real human with a microphone connected to their local machine
- **Related:** [ADR-0002](0002-bring-your-own-domain-and-certificate.md) — Bring Your Own Domain and Bring Your Own Certificate for the public ingress

---

## Context and Problem Statement

Live Voice Practice is deployed with full network isolation: the Azure Container Apps (ACA) environment is created with `vnetConfiguration.internal = true`, all backend services (Cosmos DB, AI Search, App Configuration, Speech, AI Foundry, Storage, ACR) are reachable only via private endpoints, and a Windows jumpbox in the same VNet is the only management plane.

The app's primary user-facing flow is a **two-way voice conversation** with a synthetic avatar. Validating this flow end-to-end requires a real microphone: the browser must capture audio from the operator's machine, send it to the ACA-hosted backend over WebRTC/HTTPS, and receive synthesized speech and avatar video back.

Inside a network-isolated environment, the only sanctioned way for an operator to reach the app is the jumpbox, which is accessed through Azure Bastion. **Azure Bastion does not redirect audio input** (microphone) — neither in the HTML5 client nor in the native client (`az network bastion rdp`). This is documented and confirmed by Microsoft: *"Audio input is not supported at the moment."* ([Azure Bastion - Remote audio](https://learn.microsoft.com/en-us/azure/bastion/vm-about#remote-audio)). The Bastion gateway drops the audio capture virtual channel before it reaches the RDP host; no VM-side configuration, `.rdp` flag, or registry change can recover the channel.

The avatar (audio output, video) renders correctly inside Bastion because only the playback channel is needed. Microphone input is the missing capability.

We therefore need a path that lets a designated tester reach the deployed app from their own workstation (where the microphone is physically connected) **without dismantling the network isolation that the deployment is meant to demonstrate**.

---

## Decision Drivers

1. **Preserve the demonstrated network-isolation posture.** This deployment exists in part to show that the app can be operated under strict private-networking constraints. Recreating the ACA environment as `internal: false`, or otherwise turning the app itself into a public service, defeats that purpose.
2. **Defense in depth.** The exposed surface should sit *in front of* the application tier, not on the jumpbox or on backend services. The exposed surface should provide WAF, TLS termination, and identity-aware controls.
3. **Bounded blast radius.** Any compromise of the testing entry point must not yield direct access to backend data plane (Cosmos, Foundry, App Configuration secrets, Speech keys) nor administrative control over the resource group.
4. **Reversibility.** The testing entry point must be add/remove-able without re-provisioning the application or its environment, and without changing the application's FQDN or backend wiring.
5. **Time and cost proportionate to a one-off manual verification.** This is not a permanent production capability; it is an operator path used to confirm a behavior in a deployed environment.
6. **Auditability.** The exposed surface must be visible in standard Azure auditing (NSG flow logs, Diagnostic settings, Activity log) and should not require trust in the jumpbox identity.

---

## Considered Options

### Option A — Recreate the ACA environment as `internal: false` and add IP restrictions on the Container App ingress

Tear down the existing managed environment, redeploy the workload into a new environment created with `vnetConfiguration.internal = false`, and rely on `ipSecurityRestrictions` on the Container App ingress to restrict access to the operator's egress IP.

**Pros**
- No new networking resource needed.
- IP restriction at the Container Apps platform layer.

**Cons**
- The environment's `internal` flag is **immutable**; redeploy is the only path. This invalidates the deployment under test.
- The app itself becomes the public surface. No WAF, no identity layer in front by default.
- The application FQDN changes with the new environment, breaking any artifacts (smoke probes, runbooks, screenshots) that referenced the previous one.
- Loses the "network-isolated" property of the deployment that we are trying to preserve while validating the user experience.

### Option B — Place Azure Application Gateway (WAF v2) in front of the existing internal ACA environment, restricted to the operator's IP

Stand up an Application Gateway v2 with WAF in a dedicated subnet of the existing VNet. The backend pool targets the internal load-balancer IP/FQDN of the ACA managed environment. Public access reaches the Application Gateway, which enforces a WAF policy and an IP allow-list, terminates TLS, and forwards to the internal app over the VNet. The ACA environment and the app remain `internal`. Tear down the Application Gateway when manual testing is done.

**Pros**
- The ACA environment, the app, and all backend services remain unchanged and unreachable from the public internet.
- Public surface is a managed service designed to be public-facing (Application Gateway with WAF v2): TLS termination, OWASP rule set, IP allow-list, request logging, integration with Azure Monitor.
- The exposed component does not have any role assignments on the resource group's data plane. A compromise of the gateway does not yield Cosmos / App Configuration / Foundry credentials, only the in-VNet HTTP path to the app.
- Add and remove without touching the application: no FQDN changes, no redeploy, no jumpbox change.
- Time-bounded operationally: provision when starting a testing window, delete when done. Hourly billing only while it exists.
- Clear audit posture: a single, named, public-facing resource appears in the resource group during the testing window.

**Cons**
- Provisioning Application Gateway v2 takes ~20-40 minutes the first time (subnet, public IP, gateway, listener, backend pool, health probe, WAF policy).
- Recurring cost while running: roughly USD 0.45-0.55 per hour for the gateway plus capacity units (negligible at low traffic), so a few dollars per testing window.
- The gateway needs its own dedicated subnet in the VNet (cannot share with other resources). Allocating the subnet must not conflict with the existing AILZ address plan.
- TLS certificate management for the public listener (use a managed certificate via Key Vault, or a temporary self-signed certificate accepted by the operator's browser).

### Option C — Attach a temporary public IP to the jumpbox VM, restrict NSG to the operator's IP, and use direct RDP (bypassing Bastion)

Native RDP forwards the local microphone normally. The browser inside the jumpbox can then reach the internal app and use the redirected mic.

**Pros**
- Smallest implementation effort (a public IP, an NSG rule).
- Lowest direct cost (a public IP costs cents per day).
- No change to the application or its environment.

**Cons**
- **The exposed component is the jumpbox, not the app.** The jumpbox holds a User-Assigned Managed Identity with administrative-grade permissions on the resource group (necessary so that bootstrap, Cosmos seed, and Search index management can run from the VM). A compromise of the jumpbox is a compromise of the deployment's data plane via that identity.
- Authentication is a local password on a workgroup VM. No Entra ID, no MFA, no conditional access. NLA only mitigates pre-auth exposure.
- Operator's egress IP can change (mobile, carrier-grade NAT, ISP DHCP, corporate VPN toggles), causing self-lockout mid-testing.
- A VM with a public IP in a network-isolated resource group is a visible deviation from the documented posture. Any policy or compliance check that evaluates this resource group will flag it.
- No WAF, no TLS at the public surface; RDP itself is the protocol exposed.

### Option D — Do nothing, accept that voice features cannot be manually validated in network-isolated deployments from this workstation

**Pros**
- No change, no cost, no exposure.

**Cons**
- The voice feature, which is the primary user-facing capability of the app, cannot be exercised end-to-end in network-isolated deployments by the operator. Bugs that only manifest with real audio cannot be caught here.

---

## Decision Outcome

**Chosen option: Option B — Application Gateway (WAF v2) in front of the internal ACA environment, restricted by IP allow-list.**

This option places the public surface where a public surface belongs (in front of the app, not on the management VM), keeps the network-isolation posture of the application and its backend services intact, gives a bounded blast radius (compromise of the gateway does not yield identity-based access to the data plane), and is cleanly add/remove-able for the duration of a manual testing window.

Option C was the most tempting on raw effort, and was rejected because it inverts the security model: it exposes the most privileged identity in the resource group (the jumpbox MI, which is privileged precisely so that data-plane bootstrap can run from within the VNet) over a credential-only protocol. The convenience does not justify the lateral-movement risk.

Option A was rejected because it requires destroying the deployment under test in order to test it, and because the application is not the right surface to make public.

Option D was rejected because validating the voice round-trip end to end is part of the value this repository is supposed to deliver.

---

## Scope and Constraints of the Manual-Testing Pattern

This decision is **scoped strictly to enabling a single, time-bounded, IP-restricted manual testing window**. It is not a recommendation to operate the app behind a public Application Gateway as steady state.

The pattern is bounded as follows.

- **Lifecycle.** The Application Gateway is provisioned at the start of a testing window and deleted at its end. It is not part of the steady-state Bicep for the deployment. Implementation will live in an opt-in module that is invoked manually, not from `azd provision`.
- **Access.** The WAF policy and Application Gateway listener restrict source IP to the operator's egress IP only. The IP is a parameter of the opt-in module and is set at deployment time.
- **TLS.** A certificate referenced from the existing Key Vault is used on the listener. The certificate is supplied by the deployer; the accelerator does not issue, renew, or own it. See [ADR-0002](0002-bring-your-own-domain-and-certificate.md) for the boundary between the accelerator and the deployer on domain and certificate ownership.
- **Routing.** A single backend pool targets the existing internal ACA environment's default domain. The gateway forwards all paths to the same backend; no path-based routing is needed for this scope.
- **WAF.** OWASP Core Rule Set in Detection mode for the first run, then Prevention mode once the app's request shape (WebRTC signaling, audio uploads) is known to pass.
- **Logging.** The gateway is created with a Diagnostic Setting that ships access logs and firewall logs to the existing Log Analytics workspace.
- **No managed identity for the gateway** beyond what is required to read the TLS certificate from Key Vault. The gateway is not granted any data-plane role.

Concretely, the resources added for a testing window are:

1. A subnet (`agw-subnet`, /27 or larger) in the existing VNet.
2. A standard public IP.
3. An Application Gateway v2 with WAF v2 SKU.
4. A WAF policy with the OWASP rule set and an IP-restriction custom rule.
5. (Optional) A DNS A record on a hostname the operator already controls, pointing to the public IP, for a friendlier URL with a real certificate.

Removal is the inverse list, in reverse order, executed by the same opt-in module with a `--delete` flag. The application, its environment, the jumpbox, and all backend services are untouched in either direction.

---

## Consequences

### Positive
- The application, its environment, and all backend services keep their `internal` posture unchanged for the entire testing window. The "network-isolated" claim of the deployment remains accurate; the testing path is a labeled exception in front of the app, not a hole in it.
- Voice features can be validated by a human with a real microphone, against the actual deployed app, including the network path through the gateway and the VNet to the app's ingress.
- The exposed component is the right one (the app's public face), it is a managed service designed for this role, and it is replaceable without touching the workload.
- Audit and review surfaces are clean: a single named gateway, a single WAF policy, a single public IP, all in the same resource group, all visible in Activity Log.

### Negative / Risks
- **Cost while running.** Application Gateway v2 with WAF v2 has hourly billing; testing windows must be short and explicitly closed (delete, not stop, the gateway when done).
- **First-time configuration overhead.** ~20-40 minutes the first time, faster on repeat once the opt-in module is in place.
- **TLS edge cases.** If the operator does not have a domain to attach, the self-signed listener will trigger browser warnings; some browsers refuse `getUserMedia` in fully-untrusted contexts. Mitigation: prefer a managed certificate via Key Vault on a hostname the operator controls.
- **WAF false positives.** WebRTC signaling and audio uploads may be flagged by some OWASP rules; tuning may be needed before switching from Detection to Prevention.
- **Subnet allocation.** Application Gateway requires its own subnet; the address plan must accommodate it without overlapping AILZ-managed subnets.

### Mitigations
- Document a "tear-down" command that the opt-in module always runs in CI when a testing window closes; treat a leftover gateway as an incident.
- Pin the WAF policy version and the Application Gateway SKU in the opt-in module so that successive testing windows are reproducible.
- Capture the IP allow-list in a parameter file generated at deployment time, never committed.
- Treat the gateway logs and the app's request logs as joinable: correlate by time and source IP for any incident review.

---

## Out of Scope

- Steady-state public exposure of the app for production use. That would be a separate decision with different drivers (multi-region, DDoS Standard, custom domains, identity-aware proxying, persistent WAF tuning).
- Replacing Bastion as the jumpbox access path. Bastion remains the operator path for everything except the manual mic-driven verification of the voice feature.
- Resolving the underlying Bastion limitation. Audio input redirection in Azure Bastion is a platform constraint and is tracked by Microsoft; this ADR does not depend on that being lifted.

---

## References

- [Azure Bastion - About VM connections and features (Remote audio)](https://learn.microsoft.com/en-us/azure/bastion/vm-about#remote-audio)
- [Azure Bastion FAQ](https://learn.microsoft.com/en-us/azure/bastion/bastion-faq)
- [Application Gateway v2 with WAF](https://learn.microsoft.com/en-us/azure/web-application-firewall/ag/ag-overview)
- [Azure Container Apps - networking environment with `internal = true`](https://learn.microsoft.com/en-us/azure/container-apps/networking)
- Repository: [`docs/network-isolation-jumpbox-runbook.md`](../network-isolation-jumpbox-runbook.md) — manual UI testing limitation section
