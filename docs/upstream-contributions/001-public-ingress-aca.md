# Optional public ingress (Application Gateway) for ACA-internal scenarios that require browser-side device capabilities

> **Target repository:** `Azure/AI-Landing-Zones`
> **Type:** Feature request
> **Status:** Draft, not yet filed
> **Suggested labels:** `enhancement`, `networking`, `application-gateway`, `container-apps`

---

## Summary

When an Azure AI Landing Zone deployment uses a Container Apps environment with `vnetConfiguration.internal = true`, the application is reachable only from inside the VNet. For workloads whose validation requires browser-side device capabilities — most notably **microphone capture** for voice-driven workloads — the operator path through Azure Bastion is insufficient: Azure Bastion does not redirect audio input ([documented Microsoft limitation](https://learn.microsoft.com/en-us/azure/bastion/vm-about#remote-audio)). There is no VM-side configuration that recovers the redirected audio capture channel; the limitation is at the gateway protocol layer.

This issue proposes adding an **optional, opt-in, secure-by-default public ingress** to the Azure AI Landing Zones blueprint, implemented as an Application Gateway (WAF v2) in front of the existing internal Container Apps environment. The ingress is disabled by default; deployments that do not require browser-side device capabilities are unaffected.

## Motivating scenarios

The pattern is generic. Any workload deployed on an internal Container Apps environment that needs browser-side capabilities — microphone, camera, geolocation, file system access, push notifications — is gated by the same Bastion limitation and benefits from the same solution.

A concrete motivating workload is [`Azure/live-voice-practice`](https://github.com/Azure/live-voice-practice), an accelerator that exercises real-time voice interaction against synthesized avatars. End-to-end validation of that workload requires a real microphone connected to a real workstation. Other plausible consumers include any voice-AI demo, video-call applications, or applications that probe local hardware.

## Why an Application Gateway, in front of the existing internal environment

Three properties matter for this pattern:

1. **The application's network posture is not modified.** The Container Apps environment retains `internal = true`. The application's FQDN inside the VNet does not change. Backend services (Cosmos, Search, App Configuration, Foundry, Speech, Storage, ACR) remain behind their private endpoints. The "network-isolated" claim of the deployment under test remains accurate.

2. **The exposed surface is the right one.** A Public IP attached to the jumpbox VM in the same resource group would expose the most privileged identity in that resource group (the jumpbox managed identity that bootstraps data-plane resources). A WAF gateway terminating TLS in front of the application exposes the application's HTTP surface, where it belongs, with TLS termination, OWASP rule set, and an IP allow-list.

3. **The ingress is reversible.** A deployment may be created with the ingress disabled, validated for non-interactive scenarios, then re-deployed with the ingress enabled when interactive validation is needed, then re-deployed with the ingress disabled when validation is complete. No application redeploy. No FQDN change. No backend reconfiguration.

## Proposed design

The design is intentionally narrow at the API surface and broad at the override surface. A small number of strongly-typed parameters describe the happy path; advanced configuration is supplied as opaque objects that the module unions with its defaults. This pattern keeps the common case ergonomic while leaving headroom for advanced scenarios that the maintainers may not want to enumerate up front.

### Parameter contract

```bicep
@description('Optional public ingress (Application Gateway WAF v2) in front of the internal Container App. Disabled by default. When enabled, deploys a secure-by-default skeleton that the operator completes via the portal or a follow-up deployment.')
param publicIngress publicIngressType = {
  enabled: false
}

@export()
type publicIngressType = {
  enabled: bool

  @description('Optional. WAF policy mode. Defaults to Prevention.')
  wafMode: ('Prevention' | 'Detection')?

  @description('Optional. SKU and capacity overrides (e.g., autoscale min/max, alternative SKU name). Schema follows the Application Gateway REST API ApplicationGatewaySku and ApplicationGatewayAutoscaleConfiguration shapes; unioned with the module defaults.')
  capacity: object?

  @description('Optional. Custom WAF rules in addition to the managed rule set. Schema follows the WAF Policy REST API WebApplicationFirewallCustomRule shape.')
  wafCustomRules: object[]?

  @description('Optional. SSL policy overrides (minimum protocol version, cipher suites). Schema follows the Application Gateway REST API ApplicationGatewaySslPolicy shape; unioned with the module defaults.')
  sslPolicy: object?
}
```

### Defaults when `enabled = true`

The module deploys a skeleton that is **secure by default and inert until the operator completes configuration**. No operator-supplied values are required at deployment time beyond `enabled = true` itself.

The skeleton consists of:

- **Public IP**, Standard SKU, Static, zonal. The IP is allocated at deployment time so the operator can configure DNS against a stable value.
- **Application Gateway**, WAF v2 SKU, zone-redundant across all available zones in the region, autoscale 0–2 capacity units.
- **WAF policy**, OWASP Core Rule Set 3.2, Prevention mode (override via `wafMode = 'Detection'`).
- **Backend pool**, pre-populated with the Container App's internal FQDN, resolved from the existing Container Apps environment outputs of the landing zone.
- **Backend HTTP settings**, HTTPS:443, `pickHostNameFromBackendAddress = true`, connection draining enabled, default health probe targeting `/`.
- **HTTPS listener**, port 443, with a self-signed bootstrap certificate generated and stored in the deployment's Key Vault. The bootstrap certificate is **not** intended to serve traffic to humans; it exists so that the gateway can boot, expose its public IP, and remain in a deny-by-default network posture while the operator configures the real certificate.
- **HTTP listener**, port 80, configured to redirect to the HTTPS listener.
- **Diagnostic settings**, shipping access logs and firewall logs to the Log Analytics workspace already present in the landing zone.
- **Network Security Group on the Application Gateway subnet**, configured with **deny-all inbound** as the only rule beyond the platform-mandatory `AzureLoadBalancer` and `GatewayManager` allows. Operator-supplied source CIDRs are added by the operator after deployment.

This means: after deployment, the gateway exists, the public IP is allocated, the backend wiring is correct, and **no human can reach the gateway** until the operator (1) adds an inbound allow rule for their source IP on the NSG, and (2) attaches a real certificate to the HTTPS listener for a hostname they configure.

### Operator completion (post-deploy, portal-driven)

The runbook supplied with the module documents the following steps, all performed in the Azure portal or via a small set of CLI commands. None of these steps require re-running the landing zone's Bicep.

1. Read the `publicIngressOutputs.publicIp` output from the deployment.
2. Configure DNS at the operator's registrar/provider so that the chosen hostname resolves to that public IP.
3. Obtain a TLS certificate for the chosen hostname from any certification authority the operator's organization accepts. The accelerator does not prescribe an issuer.
4. Import the certificate into the deployment's Key Vault.
5. Update the HTTPS listener (portal: Application Gateway → Listeners → edit) to reference the imported certificate and to set the listener hostname to the chosen hostname. SNI multi-listener is supported by the underlying gateway and is allowed but not required.
6. Add the testers' source CIDRs as allow rules on the Application Gateway subnet's NSG (portal: NSG → Inbound rules → add).
7. Validate end-to-end from a tester's workstation.

When the testing window closes, the inverse runbook removes the allow rules and re-deploys with `publicIngress.enabled = false`, which removes the gateway, the public IP, and the WAF policy in a single step.

### Outputs

The module exposes the artifacts an operator needs to complete configuration and the artifacts a deployer needs to wire into other tooling:

```bicep
output publicIngressOutputs object = {
  publicIp: <string>           // Public IP value, after allocation
  publicIpResourceId: <string> // For Diagnostic Setting consumers
  gatewayResourceId: <string>  // For portal navigation, scripts
  nsgResourceId: <string>      // For NSG rule additions
  bootstrapCertSecretId: <string> // KV reference to the placeholder cert; intentionally not a real listener cert
}
```

### Outputs the module **consumes** from the rest of the landing zone

For the module to be self-contained, the landing zone must expose the following as stable, named outputs from its existing modules. Where these already exist, they should be reused; where they do not, this issue requests adding them.

- The Application Gateway subnet's resource ID. (The blueprint already provisions a dedicated subnet for this purpose at `192.168.3.0/27` in the default address plan; only the output is missing.)
- The Container App's internal FQDN.
- The Key Vault's resource ID and name.
- The Log Analytics workspace's resource ID.
- The VNet's resource ID (for completeness; some downstream consumers want it).

If the maintainers prefer, these can be exposed under a single `landingZoneOutputs` aggregate object rather than as individual outputs.

## What this design is not

This design intentionally does **not** include:

- **Domain registration or DNS management.** The operator brings their own domain. The module accepts and exposes the public IP; the operator configures DNS at their registrar.
- **Certificate issuance, renewal, or storage automation.** The operator brings their own certificate. The module references a certificate located in Key Vault; the operator imports the certificate at the cadence their CA requires. The module does not endorse, integrate with, or depend on any specific certification authority, ACME client, or renewal automation.
- **Identity layering.** Entra ID, App Proxy, OIDC, and similar identity-aware proxies are out of scope for this module. They are a separate concern that may be addressed by a follow-up issue.
- **Per-path routing, multiple backends, or advanced rewrite rules.** The default routing is "all paths to the single backend that is the Container App." Operators who need more can use the `wafCustomRules` and the standard portal-side configuration of the Application Gateway after deployment.

## Cost transparency

Deployments that opt in pay Application Gateway v2 hourly charges (currently approximately USD 0.246 per gateway hour plus capacity-unit charges) plus a Standard Public IP. Documentation should state this and recommend that operators delete the gateway when their testing window closes. The default of `enabled = false` ensures that consumers who do not opt in pay nothing for this feature.

## Backwards compatibility

The proposed parameter is optional and defaults to `enabled = false`. Existing deployments are unaffected. No existing parameter is renamed, repurposed, or removed.

## Open questions for maintainers

I have opinions on each of these but they are explicitly open for discussion before I (or anyone) opens a PR.

1. **Aggregate object vs. flat parameters.** The proposal uses a single `publicIngress` object. An alternative is a small number of top-level parameters (`publicIngressEnabled`, `publicIngressWafMode`, etc.). The aggregate keeps the parameter list short but is harder to override one field at a time from a JSON parameter file. Maintainers' preference?

2. **Bootstrap certificate.** The proposal generates a self-signed certificate at deployment time and stores it in Key Vault, so the gateway can boot. An alternative is to leave the HTTPS listener absent until the operator attaches a real cert, exposing only the HTTP→HTTPS redirect listener. The bootstrap option is more deterministic; the no-bootstrap option is more honest about the post-deploy gap. Maintainers' preference?

3. **Default for `wafMode`.** The proposal defaults to Prevention. Some workloads (notably WebRTC signaling and audio uploads) hit OWASP false positives that take tuning to clear. An alternative is Detection by default with a documented opt-in to Prevention. Maintainers' preference?

4. **Subnet ownership.** The blueprint already provisions a subnet sized for an Application Gateway. The proposal assumes the module **consumes** that subnet rather than creating a new one. If the maintainers prefer the module to provision its own subnet, the address plan needs a slot.

5. **Output shape.** The proposal uses an aggregate `publicIngressOutputs` object. Alternative is individual outputs. Maintainers' preference?

6. **Module location.** Where in the repository tree should the module live? `modules/networking/public-ingress/`? `modules/optional/public-ingress/`? The repository's existing convention should win.

7. **Test coverage.** What level of test coverage is expected for an opt-in module? `bicep build` validation, `az deployment what-if`, an actual deploy test in a CI subscription, all of the above?

8. **Coordination with other features.** Are there in-flight features in the blueprint that intersect with this proposal (private DNS resolver, Front Door integration, custom WAF policy patterns) and that should influence the design?

## Out of scope for this issue

- Any change to how the Container Apps environment itself is provisioned.
- Any change to the existing jumpbox or Bastion configuration.
- Any change to backend services (Cosmos, Search, App Configuration, Foundry, Speech, Storage, ACR).
- Steady-state production patterns. This module is opt-in for time-bounded operator-driven scenarios; productionizing the same shape (multi-region, DDoS Standard, identity-aware proxy, persistent WAF tuning) is a separate decision.

## References

- [Azure Bastion — Remote audio limitation (audio input is not supported)](https://learn.microsoft.com/en-us/azure/bastion/vm-about#remote-audio)
- [Application Gateway v2 with WAF](https://learn.microsoft.com/en-us/azure/web-application-firewall/ag/ag-overview)
- [Application Gateway — Key Vault certificate references](https://learn.microsoft.com/en-us/azure/application-gateway/key-vault-certs)
- [Container Apps — internal networking](https://learn.microsoft.com/en-us/azure/container-apps/networking)
- Motivating workload: [`Azure/live-voice-practice`](https://github.com/Azure/live-voice-practice)
- Architectural Decision Records that informed this proposal:
  - [`docs/adr/0001-manual-testing-microphone-application-gateway.md`](https://github.com/Azure/live-voice-practice/blob/main/docs/adr/0001-manual-testing-microphone-application-gateway.md)
  - [`docs/adr/0002-bring-your-own-domain-and-certificate.md`](https://github.com/Azure/live-voice-practice/blob/main/docs/adr/0002-bring-your-own-domain-and-certificate.md)
