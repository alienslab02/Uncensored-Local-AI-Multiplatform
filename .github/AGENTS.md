# .github/ — CI and GitHub metadata

## Purpose

Workflows (e.g. APK builds), issue templates if added.

## Rules

1. Don’t upload secrets; use GitHub Actions secrets.
2. CI should not download multi-GB models by default.
3. Keep workflows reproducible and pinned where practical.
4. Voice Docker e2e is optional/manual — don’t block APK CI on Fish GPU.
