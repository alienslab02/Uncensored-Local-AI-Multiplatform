# test/ — Automated tests

## Purpose

Dart/Flutter tests for services and widgets.

## Rules

1. Name files `*_test.dart`.
2. Prefer unit tests for `LocalApiServerService` / pure logic; widget tests only when valuable.
3. Don’t require real GGUF files or Docker in CI unit tests — mock/fake.
4. Voice Docker e2e is manual/runbook-based unless a compose test profile is added later.
