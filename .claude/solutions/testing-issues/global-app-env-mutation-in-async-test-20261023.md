---
module: "RetrievalNode.SearchFallbackTest"
date: "2026-10-23"
problem_type: test_failure
component: testing
symptoms:
  - "An unrelated async test fails with RetrievalNode.Embedding.Unavailable: embedding server down (test)"
root_cause: "A new test swapped the global :embedding_impl (Application.put_env) inside an async: true module (HybridQueryTest), so concurrently running async tests (ReembedTest) picked up the failing impl"
severity: low
tags: [exunit, async, application-env, flaky-test]
elixir_version: "1.20.2"
---

# Swapping global app env in an async test breaks other tests

## Symptoms

Adding a "search falls back to full-text when embeddings are unavailable"
test to `HybridQueryTest` made `ReembedTest` fail with the test's
`Embedding.Unavailable` exception.

## Root Cause

`Application.put_env/3` is global to the VM. `async: true` modules run
concurrently, so one module's swap leaks into the others for its duration.

## Solution

Move any test that changes app env into its own `async: false` module
(`search_fallback_test.exs`). ExUnit runs every async module first, then the
sync ones serially, so sync modules never overlap async ones.

## Prevention

- Rule: a test that calls `Application.put_env` lives in an `async: false`
  module, and restores the previous value in `on_exit`.
