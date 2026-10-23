defmodule RetrievalNode.Embedding.Reembed do
  @moduledoc """
  Recomputes the embedding of every stored chunk with the configured
  embedding implementation — needed after switching backend, model or task
  prefixes, since vectors from different setups don't mix in one index.

  By default only chunks whose `embedding_profile` differs from the current
  `Embedding.profile/0` are redone, so an interrupted run simply resumes;
  `all: true` redoes everything. Chunks are not re-chunked: the embedded text
  is rebuilt from the stored `context_breadcrumb` and `content`, exactly as
  `Ingest.FileIngest` builds it.
  """

  import Ecto.Query

  alias RetrievalNode.Chunking.Breadcrumb
  alias RetrievalNode.Embedding
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, Source}

  @default_batch 256

  @doc """
  Options: `:source` (a source name), `:all` (also chunks already on the
  current profile), `:batch` (chunks per round trip), `:after` (start after
  this chunk id), `:progress` (fn receiving
  `%{done:, total:, last_id:}` after each batch). Returns `{:ok, count}`.
  """
  def run(opts \\ []) do
    batch = Keyword.get(opts, :batch, @default_batch)
    progress = Keyword.get(opts, :progress, fn _ -> :ok end)
    profile = Embedding.profile()
    base = opts[:source] |> scope() |> stale(profile, opts[:all])
    total = Repo.aggregate(after_id(base, opts[:after]), :count)

    count = loop(base, opts[:after], batch, total, 0, {progress, profile})
    {:ok, count}
  end

  defp loop(base, last_id, batch, total, done, {progress, profile} = ctx) do
    rows =
      base
      |> after_id(last_id)
      |> order_by([c], c.id)
      |> limit(^batch)
      |> select([c], {c.id, c.context_breadcrumb, c.content, c.content_hash})
      |> Repo.all()

    case rows do
      [] ->
        done

      rows ->
        vectors =
          rows
          |> Enum.map(fn {_, crumb, content, _} -> text(crumb, content) end)
          |> Embedding.embed_batch()

        if length(vectors) != length(rows),
          do: raise("embed_batch returned #{length(vectors)} vectors for #{length(rows)} chunks")

        write!(rows, vectors, profile)

        {last, _, _, _} = List.last(rows)
        done = done + length(rows)
        progress.(%{done: done, total: total, last_id: last})
        loop(base, last, batch, total, done, ctx)
    end
  end

  # Only if the chunk's text is still the one embedded: the server may have
  # rewritten it meanwhile (with the current profile already), and its vector
  # must not be replaced by the old text's.
  defp write!(rows, vectors, profile) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      Enum.zip_with(rows, vectors, fn {id, _, _, hash}, vector ->
        Repo.update_all(from(c in Chunk, where: c.id == ^id and c.content_hash == ^hash),
          set: [embedding: Pgvector.new(vector), embedding_profile: profile, updated_at: now]
        )
      end)
    end)
  end

  # Same text FileIngest embeds: the breadcrumb prepended to the chunk text.
  defp text(crumb, content) when crumb in [nil, ""], do: content
  defp text(crumb, content), do: Breadcrumb.prepend(crumb, content)

  defp scope(nil), do: from(c in Chunk)

  defp scope(name) do
    case Repo.get_by(Source, name: name) do
      nil -> raise ArgumentError, "no source named #{inspect(name)}"
      source -> from(c in Chunk, where: c.source_id == ^source.id)
    end
  end

  defp stale(query, _profile, true), do: query

  defp stale(query, profile, _all),
    do: where(query, [c], is_nil(c.embedding_profile) or c.embedding_profile != ^profile)

  defp after_id(query, nil), do: query
  defp after_id(query, id), do: where(query, [c], c.id > ^id)
end
