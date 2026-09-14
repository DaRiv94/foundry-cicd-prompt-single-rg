# Prompt agent CI/CD, single resource group (lightweight topology)

This project promotes a Microsoft Foundry prompt agent from dev to test to prod when all three environments live inside ONE Foundry project. The agent is a Frankies Bakery customer service agent: one model deployment plus `agent/instructions.md`, no tools.

The three environments are three agents in the same project, told apart by a name suffix. Every promotion creates a new immutable version of the agent for that environment from the same instructions file. Prod is pinned to the version that passed the gate.

```
rg-ais-eus-pasingle                      one resource group
  msf-ais-eus-pasingle                   Microsoft Foundry account (keyless, Entra only)
    chat-model                           gpt-5-nano deployment, same name in every environment
    prj-ais-eus-pasingle                 Foundry project
      frankies-bakery-support-dev        versions 1, 2, 3 ...   endpoint serves the latest version
      frankies-bakery-support-test       versions 1, 2, 3 ...   the evaluation gate runs here
      frankies-bakery-support-prod       versions 1, 2, 3 ...   endpoint PINNED to the promoted version
  id-ais-eus-pasingle-cicd               managed identity the pipeline signs in as (Foundry Owner on this group)
```

Zero secrets. GitHub Actions signs in to Azure with OpenID Connect as the managed identity. The Foundry account has local auth disabled, so there is no key to leak.

## How promotion works

| Stage | Trigger | What runs | Gate |
|---|---|---|---|
| dev | push to any branch except `main` | deploy infra, create a new agent version, smoke test | none |
| test | push to `main` (job 2 of the Release run) | deploy infra, new version, smoke test, evaluation gate | 6-row evaluation, 80 percent must pass |
| prod | push to `main` (job 3 of the Release run) | wait for the reviewer, deploy infra, new version, pin the endpoint, smoke test the pin | a person approves |

The Release run moves the same commit through dev, test, and prod. The prod job waits because the `prod` GitHub Environment has a required reviewer. The evaluation gate blocks prod because the prod job declares `needs: test`.

## Prerequisites

Azure

- A subscription where you can create resource groups and role assignments.
- Quota for `gpt-5-nano` GlobalStandard in East US: 10K tokens per minute for the one account.

Local machine

- Azure CLI 2.80 or later with Bicep (`az bicep upgrade`).
- GitHub CLI (`gh auth login` with the `repo` and `workflow` scopes).
- Python 3.12.
- PowerShell 7 or Bash. Every script has both.

GitHub

- A public repo. Required reviewers on Environments are free only on public repos.

## Files in this folder

- `agent/instructions.md` is the agent. Edit this file to change the agent, then promote it.
- `evals/bakery-eval-set.jsonl` holds six questions with the phrase each answer must contain.
- `infra/main.bicep` creates the Foundry account, the project, the `chat-model` deployment, and one role assignment. Deployed once, because all three environments share it.
- `scripts/0_prepare` creates the resource group and grants you Foundry Owner on it.
- `scripts/0b_pipeline_identity` creates the managed identity, its three federated credentials, the GitHub Environments, and the variables.
- `scripts/1_deploy_infra` runs the Bicep deployment. The pipeline runs this same file.
- `scripts/2_deploy_agent.py` creates a new immutable version of the agent for one environment.
- `scripts/3_smoke_test.py` asks the agent endpoint one question and fails on an empty answer.
- `scripts/4_evaluate.py` runs the evaluation gate against one version and exits 1 below 80 percent.
- `scripts/5_pin_version.py` routes 100 percent of the prod endpoint to one version. Rollback uses the same script.
- `scripts/99_teardown` deletes the resource group.
- `.github/workflows/deploy-stage.yml` is the one reusable stage. `dev.yml` and `release.yml` call it.
- `adding-capabilities.md` explains what changes when you add web search, file search, Azure AI Search, an MCP server, or code execution.

## Set up

Windows (PowerShell)

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env
az login
```

Mac / Linux (Bash)

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
az login
```

Open `.env` and replace the two placeholders: your subscription id and, for later, your GitHub repo as `owner/name`. Every script refuses to run while a placeholder is still there.

## Run it locally first

Do the whole promotion by hand once. It is the same sequence the pipeline runs, so when the pipeline runs later you already know every step.

Windows (PowerShell)

```powershell
.\scripts\0_prepare.ps1
.\scripts\1_deploy_infra.ps1 -Env dev

# dev
python scripts\2_deploy_agent.py --env dev
python scripts\3_smoke_test.py --env dev

# test: the gate runs here
python scripts\2_deploy_agent.py --env test
python scripts\3_smoke_test.py --env test
python scripts\4_evaluate.py --env test --agent-version 1

# prod: pin, then prove the pin
python scripts\2_deploy_agent.py --env prod
python scripts\5_pin_version.py --env prod --agent-version 1
python scripts\3_smoke_test.py --env prod
```

Mac / Linux (Bash)

```bash
./scripts/0_prepare.sh
./scripts/1_deploy_infra.sh dev

# dev
python scripts/2_deploy_agent.py --env dev
python scripts/3_smoke_test.py --env dev

# test: the gate runs here
python scripts/2_deploy_agent.py --env test
python scripts/3_smoke_test.py --env test
python scripts/4_evaluate.py --env test --agent-version 1

# prod: pin, then prove the pin
python scripts/2_deploy_agent.py --env prod
python scripts/5_pin_version.py --env prod --agent-version 1
python scripts/3_smoke_test.py --env prod
```

What you see

- `1_deploy_infra` prints the project endpoint. It takes two to three minutes the first time and seconds after that.
- `2_deploy_agent` prints `frankies-bakery-support-dev version 1 created`. Run it again and you get version 2. Versions are never edited.
- `4_evaluate` polls for about two minutes, prints one line per question, then `Pass rate 6/6 = 100% (minimum 80%)` and `GATE PASSED`. It also prints a link to the report in the Foundry portal.
- `5_pin_version` prints which version the prod endpoint now serves.

Where to look in the Foundry portal: open the project, then Agents. You see three agents. Open one and look at its versions and the `git_sha` and `env` metadata on each. On the prod agent, the endpoint settings show the pinned version instead of "always use latest".

The infra script takes an environment name only so the pipeline runs the same command in every stage. In this topology it deploys the same template into the same group every time, and Bicep changes nothing that already matches.

## Wire up GitHub

1. Create a public repo and push this folder to its `main` branch.
2. Put the repo name in `.env` as `GITHUB_REPO=owner/name`.
3. Run the bootstrap script. It needs `az login` and `gh auth login`.

Windows (PowerShell)

```powershell
.\scripts\0b_pipeline_identity.ps1
```

Mac / Linux (Bash)

```bash
./scripts/0b_pipeline_identity.sh
```

It creates one managed identity in the resource group with three federated credentials, one per GitHub Environment. Each credential trusts only jobs that run inside that Environment, so the `prod` job is the only job that gets a token after a reviewer approves. The identity gets Foundry Owner on the resource group and nothing else. Foundry Owner covers `az deployment group create`, the Foundry account, and the agents inside it.

4. Wait about ten minutes for the role assignment to propagate, then push a change or start the Release workflow from the Actions tab.

Federated credential subjects: GitHub issues an immutable subject for repos created after July 2026, `repo:OWNER@OWNER-ID/REPO@REPO-ID:environment:NAME`. The script reads both ids with `gh api` and builds that subject. If the first login fails with `AADSTS70021`, the error shows the subject GitHub sent. Compare it with `az identity federated-credential list`.

## The promotion loop

This is the loop a developer runs every day.

1. Create a branch and edit `agent/instructions.md`. For example, change Saturday closing time from 6 PM to 5 PM.
2. Push the branch. The Dev workflow deploys a new version of `frankies-bakery-support-dev` and smoke tests it. Open the run in the Actions tab and read the answer in the smoke test step.
3. Open a pull request and merge it.
4. The Release workflow starts on `main`: the dev job runs again on the merge commit, then the test job creates a test version and runs the evaluation gate, then the prod job waits.
5. Approve the prod job in the Actions tab. It creates the prod version, pins the endpoint to it, and smoke tests the pinned endpoint. The smoke test output shows the new closing time.

Nothing reaches prod without a passing gate on the exact commit and a human approval.

## Break the gate

See the gate do its job once.

1. On a branch, delete rule 3 from `agent/instructions.md` (the "I will connect you with a team member" sentence) and change the Sunday hours to "9 AM to 2 PM Sunday".
2. Merge it. The test job's evaluation step fails two of six rows, prints `Pass rate 4/6 = 67%`, exits 1, and the prod job never starts. Prod keeps serving the pinned version.
3. Restore both edits and merge. The gate passes and prod gets the fixed version.

The gate tolerates one miss on purpose, so a single wrong row passes at 83 percent. Six rows is small. With a real evaluation set you raise the row count and the threshold together.

## Rollback

Prod serves one pinned version. To go back, pin the previous one.

Windows (PowerShell)

```powershell
python scripts\5_pin_version.py --env prod --agent-version 1
```

Mac / Linux (Bash)

```bash
python scripts/5_pin_version.py --env prod --agent-version 1
```

A pin cannot be removed, only re-pointed. There is no way back to "always use latest" once an endpoint is pinned, which is fine: prod should never serve "whatever was created last".

## Where a bigger gate would go

The gate is one deterministic substring check per row, so it needs no judge model. To add an LLM-judged criterion such as task adherence, deploy a judge model in Bicep and add a second entry to `testing_criteria` in `scripts/4_evaluate.py`. The pipeline does not change.

## Cost

Foundry accounts, projects, and agents cost nothing while idle. You pay for tokens when a smoke test or evaluation runs, and six evaluation rows on gpt-5-nano cost a fraction of a cent. The evaluation run itself is free of charge beyond the tokens.

## Teardown

Windows (PowerShell)

```powershell
.\scripts\99_teardown.ps1
```

Mac / Linux (Bash)

```bash
./scripts/99_teardown.sh
```

The script lists the resource group, asks you to type DELETE, and deletes it. The managed identity and the role assignments live inside the group, so nothing is left behind in Azure. The GitHub repo and its Environments stay and cost nothing.

## When to use this topology

Use one project for all three environments when one small team owns the agent and cheap, fast setup matters more than isolation. Everything shares one account, one quota, and one set of role assignments. A mistake in dev cannot break prod's agent versions, but it can spend prod's quota, and anyone with access to the project sees all three agents.

Do not use it when different teams need different access to dev and prod, when compliance needs separate audit trails per environment, or when prod needs its own capacity. Project `01-prompt-agent-multi-rg` shows the same agent with three resource groups.

I recommend this topology for learning and for prototypes because you get the full promotion loop with one resource group and one identity. Move to three resource groups before the agent has real users.

## Adding capabilities

See `adding-capabilities.md` for what changes when you add web search, file search, RAG with Azure AI Search, an MCP server, or code execution.
