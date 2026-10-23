# README Documentation Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove Status tables, "Task N" references, and implementation tracking details from README.md files across all three repositories to make documentation user-focused (how to use the repo, how it's built) rather than project-management focused.

**Architecture:** Each repository's README.md contains a Status table with phase/state/verified-by tracking that reads like project management. These tables and any "Task N" references will be removed while preserving all user-facing documentation (architecture, API reference, configuration, local development, deployment, runbooks, ADRs, project structure).

**Tech Stack:** Markdown documentation files across three repositories

**Spec:** User requirement: "I'm pretty sure some of those MD files contain step information regarding the tasks you did and information that is not really relevant for someone who wants to know how to use the repo and how it's built, etc"

## Global Constraints

- Preserve all user-facing content: architecture descriptions, API references, configuration tables, local development guides, deployment instructions, operational notes, runbook links, ADR links, project structure
- Remove only: Status tables (phase/state/verified-by tracking), "Task N" references, "Known Limitations" sections with implementation details, any other project-management tracking content
- Each repository's README must be cleaned independently
- Verify cleaned README still renders properly and has all user-relevant information
- Commit each repository's changes separately with descriptive messages

---

### Task 1: Clean up platform-infra/README.md

**Files:**
- Modify: `/Users/romeurosa/Repositories/fullstack/platform-infra/README.md`

**Interfaces:**
- Consumes: Current platform-infra/README.md with Status table (lines 6-41), "Task 12" references, "Known Limitations" with implementation details
- Produces: Cleaned README.md with user-focused documentation only

- [ ] **Step 1: Read current README.md and identify all content to remove**

```bash
# The file has:
# - Status table (lines 6-41): 29 rows with Phase/State/Verified By columns
# - "Task 12" references in comments
# - "Known Limitations" section with implementation tracking details
# All of this should be removed
```

- [ ] **Step 2: Create cleaned version of README.md**

Create the cleaned README.md by removing:
1. The entire Status table (from "## Status" heading through the 29-row table and any trailing comments)
2. Any "Task 12" or similar task references
3. The "Known Limitations" section that contains implementation tracking details
4. Any other project-management tracking content

Preserve all:
- Repository overview and purpose
- Architecture diagrams
- Quick start / prerequisites
- Directory structure
- Key workflows
- Environment information
- Runbook links
- ADR links
- Any user-facing operational guidance

- [ ] **Step 3: Write cleaned README.md to file**

```bash
# Write the cleaned content to platform-infra/README.md
```

- [ ] **Step 4: Verify the cleaned README.md**

```bash
# Check that:
# - No Status table remains
# - No "Task N" references remain
# - All user-facing sections are intact
# - Markdown renders properly
cat platform-infra/README.md | head -100
```

- [ ] **Step 5: Commit changes**

```bash
cd /Users/romeurosa/Repositories/fullstack/platform-infra
git add README.md
git commit -m "docs: remove Status table and task tracking from platform-infra README

- Remove 29-row Status table with phase/state/verified-by tracking
- Remove Task 12 references and implementation tracking comments
- Remove Known Limitations section with project-management details
- Preserve all user-facing documentation (architecture, quick start, workflows, runbooks, ADRs)"
```

---

### Task 2: Clean up platform-services-node/README.md

**Files:**
- Modify: `/Users/romeurosa/Repositories/fullstack/platform-services-node/README.md`

**Interfaces:**
- Consumes: Current platform-services-node/README.md with Status table (lines 5-27)
- Produces: Cleaned README.md with user-focused documentation only

- [ ] **Step 1: Read current README.md and identify all content to remove**

```bash
# The file has:
# - Status table (lines 5-27): 22 rows with Phase/State/Verified By columns
# All of this should be removed
```

- [ ] **Step 2: Create cleaned version of README.md**

Create the cleaned README.md by removing:
1. The entire Status table (from "## Status" heading through the 22-row table)

Preserve all:
- Repository overview and purpose
- Architecture
- API reference
- Configuration
- Local development guide
- Deployment instructions
- Operational notes
- Runbook links
- ADR links
- Project structure

- [ ] **Step 3: Write cleaned README.md to file**

```bash
# Write the cleaned content to platform-services-node/README.md
```

- [ ] **Step 4: Verify the cleaned README.md**

```bash
# Check that:
# - No Status table remains
# - All user-facing sections are intact
# - Markdown renders properly
cat platform-services-node/README.md | head -100
```

- [ ] **Step 5: Commit changes**

```bash
cd /Users/romeurosa/Repositories/fullstack/platform-services-node
git add README.md
git commit -m "docs: remove Status table from platform-services-node README

- Remove 22-row Status table with phase/state/verified-by tracking
- Preserve all user-facing documentation (architecture, API, config, local dev, deployment, runbooks, ADRs)"
```

---

### Task 3: Clean up platform-frontend/README.md

**Files:**
- Modify: `/Users/romeurosa/Repositories/fullstack/platform-frontend/README.md`

**Interfaces:**
- Consumes: Current platform-frontend/README.md with Status table (lines 407-426)
- Produces: Cleaned README.md with user-focused documentation only

- [ ] **Step 1: Read current README.md and identify all content to remove**

```bash
# The file has:
# - Status table (lines 407-426): 18 rows with Phase/State/Verified By columns
# All of this should be removed
```

- [ ] **Step 2: Create cleaned version of README.md**

Create the cleaned README.md by removing:
1. The entire Status table (from "## Status" heading through the 18-row table)

Preserve all:
- Repository overview and purpose
- Architecture
- Getting started / prerequisites
- Project structure
- Configuration
- Local development
- Deployment
- Testing
- Runbook links
- ADR links
- Onboarding guide link

- [ ] **Step 3: Write cleaned README.md to file**

```bash
# Write the cleaned content to platform-frontend/README.md
```

- [ ] **Step 4: Verify the cleaned README.md**

```bash
# Check that:
# - No Status table remains
# - All user-facing sections are intact
# - Markdown renders properly
cat platform-frontend/README.md | head -100
```

- [ ] **Step 5: Commit changes**

```bash
cd /Users/romeurosa/Repositories/fullstack/platform-frontend
git add README.md
git commit -m "docs: remove Status table from platform-frontend README

- Remove 18-row Status table with phase/state/verified-by tracking
- Preserve all user-facing documentation (architecture, getting started, config, local dev, deployment, testing, runbooks, ADRs, onboarding)"
```

---

### Task 4: Final verification across all repositories

**Files:**
- Verify: `/Users/romeurosa/Repositories/fullstack/platform-infra/README.md`
- Verify: `/Users/romeurosa/Repositories/fullstack/platform-services-node/README.md`
- Verify: `/Users/romeurosa/Repositories/fullstack/platform-frontend/README.md`

**Interfaces:**
- Consumes: All three cleaned README.md files
- Produces: Verification report confirming no task-tracking content remains

- [ ] **Step 1: Verify no Status tables remain in any README**

```bash
grep -n "## Status" platform-infra/README.md platform-services-node/README.md platform-frontend/README.md || echo "No Status tables found - GOOD"
```

- [ ] **Step 2: Verify no "Task N" references remain**

```bash
grep -ni "task [0-9]" platform-infra/README.md platform-services-node/README.md platform-frontend/README.md || echo "No Task N references found - GOOD"
```

- [ ] **Step 3: Verify key user-facing sections exist in all READMEs**

```bash
# Check each README has essential sections
for repo in platform-infra platform-services-node platform-frontend; do
  echo "=== $repo ==="
  grep -E "^## (Architecture|Quick Start|Prerequisites|Configuration|Local Development|Deployment|Operational Notes|Runbooks|ADR|Project Structure|Getting Started|Testing)" $repo/README.md
done
```

- [ ] **Step 4: Generate summary report**

```bash
echo "=== CLEANUP VERIFICATION SUMMARY ==="
echo "platform-infra: $(grep -c '## Status' platform-infra/README.md || echo 0) Status tables, $(grep -ic 'task [0-9]' platform-infra/README.md || echo 0) Task refs"
echo "platform-services-node: $(grep -c '## Status' platform-services-node/README.md || echo 0) Status tables, $(grep -ic 'task [0-9]' platform-services-node/README.md || echo 0) Task refs"
echo "platform-frontend: $(grep -c '## Status' platform-frontend/README.md || echo 0) Status tables, $(grep -ic 'task [0-9]' platform-frontend/README.md || echo 0) Task refs"
```