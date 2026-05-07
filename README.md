<h1 align="center">Live Voice Practice Platform</h1>

<p align="center">
A real-time AI-powered voice training platform for call-center and customer-service practice using Azure Voice Live and Azure AI services.
</p>

<p align="center">
<a href="./LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-green.svg" style="height:27px; vertical-align:middle;"/></a>
<a href="https://aka.ms/deploytoazurebutton"><img src="https://aka.ms/deploytoazurebutton" alt="Deploy to Azure" style="height:27px; vertical-align:middle;"/></a>
</p>


## Overview

This repository implements a **voice-based practice and training platform for call-center agents**, using real-time AI-driven customer simulations. The application acts as a **virtual practice partner**, allowing trainees to engage in realistic conversations with an AI-powered customer and receive structured feedback after the session.

Key capabilities include:

* **Real-time voice conversations** with an AI-powered customer
* **Configurable training scenarios derived from training materials**
* **Customer behavior guided by curated example transcripts**
* **Automatic conversation transcript capture**
* **Post-session scoring and structured feedback**
* **Evaluation using reusable rubrics**
* **Secure deployment in a private cloud environment**

In a typical session, a trainee selects a practice scenario and begins a real-time voice conversation with an AI-driven customer through **Azure Voice Live**, while transcripts and interaction events are captured. After the session ends, the interaction is evaluated asynchronously to generate structured feedback. Scenarios, rubric-based evaluation, and example transcripts enable more structured and repeatable training workflows.


## Deployment

This project supports two deployment modes:

- **Basic** (public endpoints) — fastest path, suitable for dev/demo:

  ```bash
  azd up
  ```

- **Network-isolated** (private endpoints + jumpbox + Azure Firewall + Application Gateway WAF v2) — production-grade:

  ```bash
  azd env set NETWORK_ISOLATION true
  azd provision   # from your workstation
  # then connect to the jumpbox via Bastion and run azd deploy + postProvision there
  ```

  Network isolation now also provisions an **Application Gateway WAF v2 in skeleton mode** in front of the internally posted Container App (since AILZ `v1.1.6` adopted upstream issue [`#49`](https://github.com/Azure/bicep-ptn-aiml-landing-zone/issues/49)). The gateway is inert until you complete a deployer-side BYO domain + certificate step. Follow [docs/manual-testing/public-ingress-runbook.md](docs/manual-testing/public-ingress-runbook.md) to promote it to live mode and reach the app from a real workstation with a real microphone.

### Defaults at a glance

| Parameter | Always | Only when `NETWORK_ISOLATION=true` |
|---|---|---|
| Container App identity (`useUAI=false`) | **System-assigned (default)** | (same) |
| ACS media egress firewall rules (`enableAcsMediaEgress`) | n/a (no firewall) | **enabled (default)** — opens UDP 3478-3481 / TCP 443+3478-3481 to `AzureCloud` for Speech avatar / ACS Calling / Teams Media |
| Application Gateway WAF v2 skeleton (`publicIngress.enabled`) | n/a (Container App ingress is public) | **enabled (default)** — inert until you complete BYO domain + cert in the public-ingress runbook |

Override any of these with `azd env set` (e.g. `azd env set USE_UAI true`, `azd env set ENABLE_ACS_MEDIA_EGRESS false`, `azd env set PUBLIC_INGRESS_ENABLED false`) before `azd provision`.

See **[docs/deployment.md](docs/deployment.md)** for the full step-by-step guide covering both modes (prerequisites, env variables, the workstation/jumpbox split for network isolation, post-provision hook, image build via the in-VNet ACR Tasks agent pool, validation, and teardown).

Quick reference for the jumpbox split (subnets, firewall allow-list, troubleshooting): [docs/network-isolation-jumpbox-runbook.md](docs/network-isolation-jumpbox-runbook.md).

Speech is provisioned by the AILZ Bicep template (`deploySpeechService=true` by default, AILZ v1.1.4+). To opt out:

```bash
azd env set DEPLOY_SPEECH_SERVICE false
```


## Local Development

1. Clone the repository

2. Copy the environment template

```bash
cp .env.template .env
```

3. Configure the required Azure credentials

4. Build and run the backend

```bash
./scripts/build.sh
cd backend
python src/app.py
```

Open the application at:

```
http://localhost:8000
```


## Project Origin and Acknowledgments

This project builds upon the sample **[Voice Live API Sales Coach](https://github.com/Azure-Samples/voicelive-api-salescoach)**. This repository extends the original implementation to support a **voice-based practice platform for customer-service and call-center training scenarios**, introducing configurable scenarios based on training materials, rubric-driven evaluation, and curated example transcripts.

The foundational architecture and part of the initial implementation originate from the original repository and its contributors. We thank the authors for making their work available as open source.


## License

This project is licensed under the **MIT License**.

See the `LICENSE` file for details.