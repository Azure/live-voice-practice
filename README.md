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

This project can be deployed to Azure using the provided infrastructure templates.

```bash
azd up
```

The deployment process provisions the required Azure resources and outputs the application endpoint.


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