defmodule RetrievalNode.Ingest.DrivePolicy do
  @moduledoc """
  Which Drive files may be indexed. Pure functions over Drive file maps (as
  returned with `Ingest.Drive`'s field list).

  A file is indexable when it is a non-trashed Google Doc, **in scope**, and
  **allowed by its classification**:

    * scope — owned by the user (My Drive, when `my_drive` is on), in one of
      the configured shared drives, or below one of the configured folders;
    * classification — no Classification label at all, or a label whose
      selected choice(s) are all allowed (Public / Internal). A label applied
      without a value is *not* allowed: fail closed.
  """

  alias RetrievalNode.Ingest.Drive

  @type classification :: %{label_id: String.t(), field_id: String.t(), allowed: MapSet.t()}
  @type scope :: %{my_drive: boolean(), drives: MapSet.t(), folders: MapSet.t()}

  @max_depth 30

  @doc "A live (non-trashed) Google Doc."
  def doc?(%{"mimeType" => mime} = file), do: mime == Drive.doc_mime() and file["trashed"] != true
  def doc?(_), do: false

  @doc "Whether the classification label (if any) allows indexing."
  @spec classification_allowed?(map(), classification()) :: boolean()
  def classification_allowed?(file, %{label_id: label_id, field_id: field_id, allowed: allowed}) do
    labels = get_in(file, ["labelInfo", "labels"]) || []

    case Enum.find(labels, &(&1["id"] == label_id)) do
      nil ->
        true

      label ->
        selection = get_in(label, ["fields", field_id, "selection"]) || []
        selection != [] and Enum.all?(selection, &MapSet.member?(allowed, &1))
    end
  end

  @doc """
  Whether `file` is in `scope`. `parents_of` resolves a folder id to its
  parent ids (memoize it — it is called while walking up the tree).
  """
  @spec in_scope?(map(), scope(), (String.t() -> [String.t()])) :: boolean()
  def in_scope?(file, scope, parents_of) do
    (scope.my_drive and owned_by_me?(file)) or
      MapSet.member?(scope.drives, file["driveId"]) or
      (MapSet.size(scope.folders) > 0 and
         below?(file["parents"] || [], scope.folders, parents_of, 0, MapSet.new()))
  end

  @doc "Indexable = live doc + in scope + classification allowed."
  def indexable?(file, scope, classification, parents_of) do
    doc?(file) and classification_allowed?(file, classification) and
      in_scope?(file, scope, parents_of)
  end

  defp owned_by_me?(file), do: Enum.any?(file["owners"] || [], &(&1["me"] == true))

  defp below?([], _folders, _parents_of, _depth, _seen), do: false
  defp below?(_ids, _folders, _parents_of, depth, _seen) when depth > @max_depth, do: false

  defp below?(ids, folders, parents_of, depth, seen) do
    if Enum.any?(ids, &MapSet.member?(folders, &1)) do
      true
    else
      seen = MapSet.union(seen, MapSet.new(ids))

      ids
      |> Enum.flat_map(parents_of)
      |> Enum.reject(&MapSet.member?(seen, &1))
      |> Enum.uniq()
      |> below?(folders, parents_of, depth + 1, seen)
    end
  end
end
