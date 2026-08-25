# Security

## Scope

This repository contains an Azure Automation runbook, infrastructure templates and tests. Nothing here
runs a service; the runbook executes under the managed identity of whatever Automation Account you deploy
it to, with whatever roles you assign. The threat model is therefore mostly **yours**:

- The identity's write role is full resource-update authority for its scope (there is no field-level
  action for the single property the runbook changes). Assign it only at the smallest scope that contains
  the resources you intend to change, and only for the duration of a change window.
- Anyone who can edit, publish or start runbooks in that Automation Account can act with that identity.
  Treat "start runbook" as writer-equivalent, keep the account dedicated, and alert on runbook, runtime
  environment, identity and role-assignment changes.
- Runtime environments are mutable: pin and record the package versions you validated.

## Reporting a vulnerability

Open a private security advisory on this repository (GitHub → Security → Report a vulnerability). Please
do not open a public issue for security problems. Include the runbook version (`runbookVersion` in the
job `SUMMARY` line), the scenario, and any job output with identifiers removed.

## What is deliberately not in this repository

Subscription, tenant, principal, job and correlation identifiers, live resource names, and any keys,
tokens or SAS values. Test fixtures use synthetic identifiers. If you find a real identifier, report it as
above.
