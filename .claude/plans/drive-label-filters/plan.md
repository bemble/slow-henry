# Plan: configurable Drive label filters

**Status**: IMPLEMENTED, in review (2026-10-24) · **Branch**: `feat/drive-label-filters`

## Problem

The Drive filter was hard-coded (see `google-drive`): a doc was indexed only
with no `Classification` label, or classified `Public` / `Internal`. Another
label title, other choices, or a second label (e.g. a team label) needed a
code change.

## Decisions

1. **Label filters in `sources.toml`.** `[drive]` gains an array of tables:

   ```toml
   [[drive.include_labels]]
   label = "Classification"        # label title, case-insensitive
   values = ["Public", "Internal"] # its indexable choices, case-insensitive
   unlabeled = true                # docs without the label pass too (default false)
   ```

   `unlabeled` stands for "no value" in the filter (TOML has no `none`).
2. **Every filter must pass.** A doc passes one when it carries the label with
   selected choice(s) all in `values`, or doesn't carry it and `unlabeled` is
   on. A label applied without a value still fails (fail closed, unchanged).
3. **Defaults keep today's behaviour.** No `include_labels`: the Classification
   filter above. `include_labels = []`: no filter at all, every doc in scope is
   indexed and the Labels API isn't called.
4. **Stored only when not the default.** `SourcesFile` normalizes each filter
   (all three keys set) and puts `include_labels` in the source config only
   when it differs from the default, so existing sources don't read as changed.
   A changed filter set is a scope change: it queues a full pass, which also
   deletes docs that no longer pass.
5. **Always written.** The editor writes the filters even when they are the
   default, so the file shows what is applied.
6. **Strict resolution.** `Drive.label_filters/1` resolves every filter
   against the published labels; a missing label, a missing selection field
   (when `values` is set) or any unknown choice name is an error, and the sync
   stages nothing. A typo must not silently drop docs. (Before, one matching
   choice was enough.)
7. **Validation** in `SourcesFile`: non-empty `label`, `values` a list of
   names, boolean `unlabeled`, no unknown keys, no duplicate label, and no
   filter matching nothing (`values = []` without `unlabeled`).
8. **`includeLabels`** on listings and the changes feed is the comma-separated
   ids of every filtered label (omitted with no filter).
9. **UI.** `/sources/edit` lists the filters (label, comma-separated values,
   "Docs without it"), with add / remove. `/connections` checks them after
   authorizing and shows one line per label, or the resolution error.

## Not done

- Filtering on non-selection fields (text, user, date) or on a given field of
  a label with several selection fields (the first one is used).
- An "any of" combination between filters.
