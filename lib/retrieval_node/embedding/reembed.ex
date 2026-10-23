defmodule RetrievalNode.Embedding.Reembed do
  @moduledoc """
  Recomputes the embedding of every stored chunk with the configured
  embedding implementation — needed after switching backend, model or task
  prefixes, since vectors from different setups don't mix in one index.

  Chunks are not re-chunked: the embedded text is rebuilt from the stored
  `context_breadcrumb` and `content`, exactly as `Ingest.FileIngest` builds
  it. Batches are walked in `id` order, so a run can resume with `after:`.
  """

  import Ecto.Query

  alias RetrievalNode.Chunking.Breadcrumb
  alias RetrievalNode.Embedding
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, Source}

  @default_batch 256

  @doc """
  Options: `:source` (a source name), `:batch` (chunks per round trip),
  `:after` (resume after this chunk id), `:progress` (fn receiving
  `%{done:, total:, last_id:}` after each batch). Returns `{:ok, count}`.
  """
  def run(opts \\ []) do
    batch = Keyword.get(opts, :batch, @default_batch)
    progress = Keyword.get(opts, :progress, fn _ -> :ok end)
    base = scope(opts[:source])
    total = Repo.aggregate(after_id(base, opts[:after]), :count)

    count = loop(base, opts[:after], batch, total, 0, progress)
    {:ok, count}
  end

  defp loop(base, last_id, batch, total, done, progress) do
    rows =
      base
      |> after_id(last_id)
      |> order_by([c], c.id)
      |> limit(^batch)
      |> select([c], {c.id, c.context_breadcrumb, c.content})
      |> Repo.all()

    case rows do
      [] ->
        done

      rows ->
        vectors =
          rows
          |> Enum.map(fn {_, crumb, content} -> text(crumb, content) end)
          |> Embedding.embed_batch()

        if length(vectors) != length(rows),
          do: raise("embed_batch returned #{length(vectors)} vectors for #{length(rows)} chunks")

        write!(rows, vectors)

        {last, _, _} = List.last(rows)
        done = done + length(rows)
        progress.(%{done: done, total: total, last_id: last})
        loop(base, last, batch, total, done, progress)
    end
  end

  defp write!(rows, vectors) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      Enum.zip_with(rows, vectors, fn {id, _, _}, vector ->
        Repo.update_all(from(c in Chunk, where: c.id == ^id),
          set: [embedding: Pgvector.new(vector), updated_at: now]
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

  defp after_id(query, nil), do: query
  defp after_id(query, id), do: where(query, [c], c.id > ^id)
end
