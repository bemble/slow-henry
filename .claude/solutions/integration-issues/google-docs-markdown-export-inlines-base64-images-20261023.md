---
module: "Ingest.Drive"
date: "2026-10-23"
problem_type: integration_issue
component: google_drive
symptoms:
  - "Postgrex.Error program_limit_exceeded: string is too long for tsvector (1356990 bytes, max 1048575 bytes) while applying a Drive doc"
  - "Some Drive docs produce hundreds of chunks of base64 noise"
root_cause: "Drive's export of a Google Doc to text/markdown inlines every image as a base64 data: URI (inline ![](data:...) or reference definitions [image1]: <data:...>). One doc was 30 KB of text and 3.7 MB of images; a chunk exceeded Postgres' 1 MB tsvector limit, and base64 made up most of ~2,300 chunks across 20 docs"
severity: high
tags: [google-drive, markdown-export, base64, tsvector, chunking, embeddings]
elixir_version: "1.20.2"
---

# Google Docs markdown export inlines images as base64

## Symptoms

One staged Drive doc failed every attempt with
`string is too long for tsvector (1356990 bytes)`. Checking the corpus:
5 staged docs and 20 indexed docs contained `data:image/...;base64,`
payloads, and their chunks were mostly base64.

## Investigation

1. The failing doc's export: 3.7 MB, of which 30 KB of text and 17 images.
2. The chunks table computes `tsv` as a generated column; a single chunk of a
   base64 blob exceeded the 1 MB tsvector limit.
3. Docs that did index were worse in a quieter way: base64 runs embedded as
   "text", polluting vectors and full-text search.

## Root Cause

`files.export(mimeType: text/markdown)` keeps images by inlining them as
`data:` URIs, either inline or as reference-style definitions at the end of
the document.

## Solution

Strip images before staging (they carry nothing for text retrieval):

```elixir
# RetrievalNode.Ingest.Drive
def strip_images(markdown) do
  markdown
  |> String.replace(~r/^\[[^\]\n]+\]:\s*<?data:[^\s>]*>?[ \t]*\n?/m, "")
  |> String.replace(~r/!\[[^\]\n]*\](\([^)\n]*\)|\[[^\]\n]*\])/, "")
end
```

Called in `DriveSync` on every export. Staged rows were rewritten in place
(content hash recomputed, attempts reset), and indexed chunks of the 20
polluted docs were deleted so the next full pass re-exported them clean.
On the staged backlog: 6.9 MB → 1.2 MB, largest doc 45 KB.

## Prevention

- Look at the size distribution of the first real export of any new source.
- Any generated `tsvector` column has a 1 MB ceiling per row: cap or clean
  chunk text upstream.
