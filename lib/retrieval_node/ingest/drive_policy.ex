defmodule RetrievalNode.Ingest.DrivePolicy do
  @moduledoc """
  Which Drive files may be indexed. Pure functions over Drive file maps (as
  returned with `Ingest.Drive`'s field list).

  A file is indexable when it is a non-trashed Google Doc, **in scope**, and
  **allowed by every label filter**:

    * scope — owned by the user (My Drive, when `my_drive` is on), shared
      directly with the user (when `shared_with_me` is on), in one of the
      configured shared drives, or below one of the configured folders;
    * label filters — `include_labels` of `[drive]` in sources.toml
      (`label_filters/1`). A doc passes a filter when it carries the label
      with selected choice(s) all among `values`, or when it doesn't carry
      the label and `unlabeled` is on. A label applied without a value is
      *not* allowed: fail closed. By default: no "Classification" label, or
      classified Public / Internal. No filters: every doc passes.
  """

  alias RetrievalNode.Ingest.Drive

  @typedoc "A label filter resolved against the Drive Labels API (`Drive.label_filters/1`)."
  @type label_filter :: %{
          label_id: String.t(),
          field_id: String.t() | nil,
          allowed: MapSet.t(),
          unlabeled: boolean()
        }
  @type scope :: %{
          my_drive: boolean(),
          shared_with_me: boolean(),
          drives: MapSet.t(),
          folders: MapSet.t()
        }

  @max_depth 30
  @default_label_filters [
    %{"label" => "Classification", "values" => ["Public", "Internal"], "unlabeled" => true}
  ]

  @doc "The label filters of a Drive source without `include_labels`."
  def default_label_filters, do: @default_label_filters

  @doc """
  The label filters of a Drive source config, as written in sources.toml
  (`%{"label" => title, "values" => [choice names], "unlabeled" => bool}`).
  """
  @spec label_filters(map()) :: [map()]
  def label_filters(config), do: Map.get(config, "include_labels", @default_label_filters)

  @doc "A live (non-trashed) Google Doc."
  def doc?(%{"mimeType" => mime} = file), do: mime == Drive.doc_mime() and file["trashed"] != true
  def doc?(_), do: false

  @doc "Whether the file's labels pass every filter."
  @spec labels_allowed?(map(), [label_filter()]) :: boolean()
  def labels_allowed?(file, filters) do
    labels = get_in(file, ["labelInfo", "labels"]) || []
    Enum.all?(filters, &passes?(labels, &1))
  end

  defp passes?(labels, %{label_id: label_id, field_id: field_id, allowed: allowed} = filter) do
    case Enum.find(labels, &(&1["id"] == label_id)) do
      nil ->
        filter.unlabeled

      label ->
        selection = (field_id && get_in(label, ["fields", field_id, "selection"])) || []
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
      (Map.get(scope, :shared_with_me, false) and shared_with_me?(file)) or
      MapSet.member?(scope.drives, file["driveId"]) or
      (MapSet.size(scope.folders) > 0 and
         below?(file["parents"] || [], scope.folders, parents_of, 0, %{}))
  end

  @doc "Indexable = live doc + in scope + labels allowed."
  def indexable?(file, scope, filters, parents_of) do
    doc?(file) and labels_allowed?(file, filters) and
      in_scope?(file, scope, parents_of)
  end

  defp owned_by_me?(file), do: Enum.any?(file["owners"] || [], &(&1["me"] == true))

  # Drive sets sharedWithMeTime on items shared directly with the user only,
  # not on the contents of a shared folder.
  defp shared_with_me?(file), do: is_binary(file["sharedWithMeTime"]) and not owned_by_me?(file)

  # `seen` is a plain map (id => true): a MapSet seeded with MapSet.new() trips
  # Dialyzer's opaque-type checks on OTP 29.
  defp below?([], _folders, _parents_of, _depth, _seen), do: false
  defp below?(_ids, _folders, _parents_of, depth, _seen) when depth > @max_depth, do: false

  defp below?(ids, folders, parents_of, depth, seen) do
    if Enum.any?(ids, &MapSet.member?(folders, &1)) do
      true
    else
      seen = Map.merge(seen, Map.from_keys(ids, true))

      ids
      |> Enum.flat_map(parents_of)
      |> Enum.reject(&Map.has_key?(seen, &1))
      |> Enum.uniq()
      |> below?(folders, parents_of, depth + 1, seen)
    end
  end
end
