# CLAUDE.md — msMarketplaceOffer-azureVirtualDesktopPoc

> This file is automatically read by Claude Code at session start.
> It defines the operating context, standards, and startup ritual for all
> AI-assisted work in the `msMarketplaceOffer-azureVirtualDesktopPoc` repository.

---

## Organisational Context

This repository is part of the **frameType Solutions** offer portfolio.
Org-level standards, taxonomy, and operating model live in:

> `frametypeSolutions/contextFrametype-Operations`

**Always read `contextFrametype-Operations/CLAUDE.md` before beginning work in this repo.**
That file defines the founding philosophy, documentation standards, IaC conventions,
Microsoft program alignment, and the open item prefix registry that govern all work
across the portfolio.

---

## This Repository's Role

**`msMarketplaceOffer-azureVirtualDesktopPoc`** is the **public delivery surface**
for the frameType Solutions Cloud-Native AVD managed application offer.

| Concern | Detail |
|---|---|
| Offer type | Azure Application — Managed Application (transactable) |
| Partner Center offer | Cloud-Native AVD PoC |
| Publisher | frameType Solutions (MPN: 6905680) |
| Repo visibility | **Public** |
| Primary audience | Customers who have deployed the offer; prospective customers evaluating it |

### ⚠️ Public Repository — Content Rules

This repository is **publicly visible**. The following must never appear here:

- Tenant IDs, subscription IDs, or any environment-specific identifiers
- Internal build decisions, TTK notes, or Partner Center submission details
- Draft or unreviewed content — all content here has passed a promotion gate
- Sensitive internal context of any kind

**When in doubt, it belongs in `msMarketplaceBuild-azureVirtualDesktopPoc` (private), not here.**

### What Lives Here
- `preDeploymentScripts/` — customer-facing pre-deployment scripts (promoted from build repo)
- `postDeploymentScripts/` — customer-facing post-deployment scripts (promoted from build repo)
- `README.md` — customer-facing documentation, aligned with Marketplace listing body
- Finalized marketing collateral approved for public consumption
- GitHub Actions workflow for PowerShell script signing (frameType certificate via Azure Artifact Signing)

### What Does Not Live Here
- Bicep source — lives in `solutionDev-azureVirtualDesktop` (private)
- ARM JSON templates and packaging — lives in `msMarketplaceBuild-azureVirtualDesktopPoc` (private)
- Draft or in-progress content of any kind

---

## Three-Repository Architecture

Every frameType Solutions offer follows this pattern:

| Repo | Role | Visibility |
|---|---|---|
| `solutionDev-{offer}` | IaC source, Bicep, agentic workspace, RAG/MCP context | Private |
| `msMarketplaceBuild-{offer}Poc` | Offer assembly, ARM JSON, createUiDefinition, TTK, Partner Center artifacts | Private |
| `msMarketplaceOffer-{offer}Poc` | Public delivery surface — signed scripts, customer docs, marketing collateral | Public |

**This repo is the public tier.** Content here is promoted from the private build repo
at defined release gates — it is never authored directly here first.

---

## Content Promotion Model

```
msMarketplaceBuild-azureVirtualDesktopPoc (private — source of truth)
        │
        │  Promotion gate — reviewed, tested, signed
        ▼
msMarketplaceOffer-azureVirtualDesktopPoc (public — this repo)
        │
        │  Dynamic pull — future state
        ▼
frametypesolutions.com product page
```

Script signing is part of the promotion gate — scripts are signed with the
frameType certificate via the Azure Artifact Signing GitHub Actions workflow
before being considered ready for customer use. This workflow is still under
development.

---

## Session Startup Ritual

**Always complete in order before starting work:**

1. Read `contextFrametype-Operations/CLAUDE.md` — org-level standards and philosophy
2. Read `HANDOFF.md` in this repository — current state and open items
3. Review the public content rules above before making any changes
4. If working on scripts — check signing workflow status before promoting new versions
5. Confirm your understanding of current state before proceeding
6. State what you understand — do not assume

---

## Repository Structure

```
msMarketplaceOffer-azureVirtualDesktopPoc/
├── CLAUDE.md                          # This file
├── HANDOFF.md                         # Session handoff — read first, write last
├── README.md                          # Customer-facing documentation
│
├── preDeploymentScripts/              # Promoted and signed pre-deployment scripts
│   └── avdPreDeployment.ps1
│
├── postDeploymentScripts/             # Promoted and signed post-deployment scripts
│   └── avdPostDeployment.ps1
│   └── Set-ScalingPlanHostPoolAssociation.ps1
│
└── .github/
    └── workflows/
        └── sign-scripts.yml           # PowerShell signing workflow (in development)
```

---

## Script Signing Workflow

Scripts in this repository are signed with the frameType Solutions certificate
using Azure Artifact Signing via a GitHub Actions workflow.

| Item | Status |
|---|---|
| Azure Artifact Signing account | Configured |
| GitHub Actions workflow | Under development |
| Scripts currently signed | 🔄 Pending workflow completion |

**Until the signing workflow is complete**, scripts promoted here should include
a clear note in the README directing customers to unblock and verify the script
before running.

---

## README Alignment

The `README.md` in this repository should remain closely aligned with the
Marketplace listing body in Partner Center. The public README is the
customer's primary reference after deployment. Key alignment points:

- Post-deployment steps must match what is described in `createUiDefinition.json`
- Script names and parameters must match the actual promoted scripts
- Any architectural changes in `mainTemplate.json` must be reflected here

---

## Open Items (This Repo)

Open items in this repository use the `AVD-OFFER-0xx` prefix.

| ID | Title | Priority | Notes |
|---|---|---|---|
| **AVD-OFFER-001** | Complete script signing GitHub Actions workflow | High | frameType certificate via Azure Artifact Signing — workflow under development |
| **AVD-OFFER-002** | README alignment review — post-publish cleanup | Medium | Verify README accurately reflects published offer state, post-deployment steps, and script instructions |
| **AVD-OFFER-003** | Marketing collateral — add finalised assets | Low | Any approved public-facing collateral for the AVD offer |

---

## Related Repositories

| Repo | Role | Visibility |
|---|---|---|
| `frametypeSolutions/contextFrametype-Operations` | Org-level standards, taxonomy, operating model | Private |
| `frametypeSolutions/solutionDev-azureVirtualDesktop` | Bicep source, IaC, agentic workspace | Private |
| `frametypeSolutions/msMarketplaceBuild-azureVirtualDesktopPoc` | Offer build, ARM JSON, Partner Center artifacts | Private |

---

## Tone and Working Style

- This is the customer-facing surface — clarity and polish matter more than completeness
- Never publish content that hasn't been reviewed against the public content rules
- Script changes always flow from the build repo — never edit scripts directly here
- *"Stay in the flow, avoid the noise."*
