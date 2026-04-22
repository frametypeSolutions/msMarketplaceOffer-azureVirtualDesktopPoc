# Session Handoff
**Date:** 2026-04-21
**Session Medium:** Claude.ai Desktop
**Next Session Target:** Desktop (Laptop or Cloud PC)
**Project Home:** frameType Solutions — msMarketplaceOffer-azureVirtualDesktopPoc

---

## What We Did This Session

### Primary Objective
Established cross-repository context architecture for the AVD offer ecosystem.
Drafted `CLAUDE.md` and `HANDOFF.md` for all three AVD repositories in alignment
with the `contextFrametype-Operations` pattern. Formalised the three-repository
naming convention for all frameType Solutions Marketplace offers.

### Documents Produced or Modified

| File | Version | Action | Location |
|---|---|---|---|
| `CLAUDE.md` | 1.0 | Created | `msMarketplaceOffer-azureVirtualDesktopPoc` root |
| `HANDOFF.md` | 1.0 | Created | `msMarketplaceOffer-azureVirtualDesktopPoc` root |

---

## Decisions Made This Session

### Three-Repository Architecture Formalised
Every frameType Solutions Marketplace offer follows a three-repository pattern:

| Repo | Role | Visibility |
|---|---|---|
| `solutionDev-{offer}` | IaC source, Bicep, agentic workspace, RAG/MCP context | Private |
| `msMarketplaceBuild-{offer}Poc` | Offer assembly, ARM JSON, createUiDefinition, TTK, Partner Center artifacts | Private |
| `msMarketplaceOffer-{offer}Poc` | Public delivery surface — signed scripts, customer docs, marketing collateral | Public |

### camelCase as Organisational Convention
camelCase is a frameType Solutions signature applied consistently across all
repo names, script names, tag values, and ARM template identifiers.

### Content Promotion Gate Confirmed
Content flows from private build repo → this public repo at defined release
gates. Content is never authored directly in this repo first. Script signing
is part of the promotion gate.

---

## Current State of All Active Content

### Scripts (source in `msMarketplaceBuild-azureVirtualDesktopPoc`)
| Script | Promoted | Signed |
|---|---|---|
| `avdPreDeployment.ps1` | ✅ | 🔄 Pending signing workflow |
| `avdPostDeployment.ps1` | ✅ | 🔄 Pending signing workflow |
| `Set-ScalingPlanHostPoolAssociation.ps1` | ✅ | 🔄 Pending signing workflow |

### Script Signing Workflow
- Azure Artifact Signing account: configured
- GitHub Actions workflow: under development (AVD-OFFER-001)

### README
- Present and customer-facing
- AVD-OFFER-002: post-publish alignment review pending

---

## Open Items

| ID | Title | Priority | Notes |
|---|---|---|---|
| **AVD-OFFER-001** | Complete script signing GitHub Actions workflow | High | frameType certificate via Azure Artifact Signing |
| **AVD-OFFER-002** | README alignment review | Medium | Verify against published offer state and post-deployment steps |
| **AVD-OFFER-003** | Marketing collateral | Low | Add finalised public-facing assets when approved |

---

## Commit Recommendation

```
docs: add CLAUDE.md and HANDOFF.md — session context architecture

- Add CLAUDE.md (v1.0) — repo operating context, public content rules,
  startup ritual, content promotion model, open items, related repos
- Add HANDOFF.md (v1.0) — initial session state capture
```

---

## Suggested Next Session Focus

- **AVD-OFFER-001** — Complete the script signing workflow. This is the
  primary outstanding item for this repo and unblocks the promotion gate
  from operating as intended.
- **AVD-OFFER-002** — README alignment review once signing workflow is resolved.

---

## Background Context (Persistent)

- **Matthew Collins** — Azure infrastructure consultant, MCT, founder of frameType Solutions
- Specializations: Azure IaC (Bicep), Azure AI Foundry, agentic AI, AVD, networking
- Certifications: AZ-700, AZ-140 | Pursuing: AZ-104, AZ-305, GitHub Actions, Microsoft AI
- Working toward Microsoft MVP nomination
- Building a SaaS AI product for Azure infrastructure (RAG + Azure AI Search + Azure AI Foundry)
- Brand anchor: *"Stay in the flow, avoid the noise."*
- GitHub org: `frametypeSolutions` | Personal: `azurearchetype`

---

*This file was generated at the close of a session on 2026-04-21.*
*Commit alongside all modified files as a single session-close commit.*
