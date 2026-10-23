defmodule RetrievalNode.Ingest.Drive do
  @moduledoc """
  Thin Google Drive + Drive Labels client for `Ingest.Workers.DriveSync`.

  Every call covers My Drive **and** shared drives (`supportsAllDrives` /
  `includeItemsFromAllDrives`), paginates to the end, and asks for the
  Classification label's values (`includeLabels`) so `Ingest.DrivePolicy` can
  filter on them. Auth is `Google.OAuth.access_token/0`.

  Results are `{:ok, _}`, `{:snooze, seconds}` on a 429 / rate-limit 403, or
  `{:error, reason}`. Req options are extended by `:drive_req_options`, which
  tests point at a `Req.Test` plug.
  """

  alias RetrievalNode.Google.OAuth

  @doc_mime "application/vnd.google-apps.document"
  @folder_mime "application/vnd.google-apps.folder"
  @file_fields "id,name,mimeType,parents,driveId,trashed,modifiedTime,webViewLink,owners(me),labelInfo"
  @page_size 1000

  def doc_mime, do: @doc_mime
  def folder_mime, do: @folder_mime

  # --- changes feed ---

  @doc "Token marking 'now' in the changes feed."
  def start_page_token do
    with {:ok, body} <-
           get("/drive/v3/changes/startPageToken", supportsAllDrives: true) do
      {:ok, body["startPageToken"]}
    end
  end

  @doc """
  All changes since `token`, following `nextPageToken` until Drive hands back
  `newStartPageToken` (the cursor for the next sync).
  """
  def changes(token, label_id) do
    params = [
      pageSize: @page_size,
      supportsAllDrives: true,
      includeItemsFromAllDrives: true,
      includeLabels: label_id,
      fields: "nextPageToken,newStartPageToken,changes(fileId,removed,file(#{@file_fields}))"
    ]

    collect_changes(token, params, [])
  end

  defp collect_changes(token, params, acc) do
    with {:ok, body} <- get("/drive/v3/changes", [{:pageToken, token} | params]) do
      acc = acc ++ Enum.map(body["changes"] || [], &parse_change/1)

      case body do
        %{"nextPageToken" => next} when is_binary(next) -> collect_changes(next, params, acc)
        %{"newStartPageToken" => new} -> {:ok, %{changes: acc, cursor: new}}
        _ -> {:error, :changes_without_cursor}
      end
    end
  end

  defp parse_change(%{"fileId" => id} = change) do
    file = change["file"]
    %{file_id: id, removed: change["removed"] == true or is_nil(file), file: file}
  end

  # --- listing ---

  @doc "Google Docs owned by the user (My Drive)."
  def my_drive_docs(label_id) do
    list_files(
      "'me' in owners and mimeType = '#{@doc_mime}' and trashed = false",
      label_id,
      corpora: "user"
    )
  end

  @doc "Google Docs of a shared drive."
  def shared_drive_docs(drive_id, label_id) do
    list_files("mimeType = '#{@doc_mime}' and trashed = false", label_id,
      corpora: "drive",
      driveId: drive_id
    )
  end

  @doc "Google Docs and sub-folders directly inside a folder."
  def folder_children(folder_id, label_id) do
    list_files(
      "'#{escape(folder_id)}' in parents and trashed = false and " <>
        "(mimeType = '#{@doc_mime}' or mimeType = '#{@folder_mime}')",
      label_id,
      corpora: "allDrives"
    )
  end

  defp list_files(q, label_id, extra) do
    params =
      [
        q: q,
        pageSize: @page_size,
        supportsAllDrives: true,
        includeItemsFromAllDrives: true,
        includeLabels: label_id,
        fields: "nextPageToken,files(#{@file_fields})"
      ] ++ extra

    collect_files(params, nil, [])
  end

  defp collect_files(params, page_token, acc) do
    params = if page_token, do: [{:pageToken, page_token} | params], else: params

    with {:ok, body} <- get("/drive/v3/files", params) do
      acc = acc ++ (body["files"] || [])

      case body["nextPageToken"] do
        next when is_binary(next) -> collect_files(params, next, acc)
        _ -> {:ok, acc}
      end
    end
  end

  # --- single objects ---

  @doc "A shared drive by id, or `{:error, :not_found}`."
  def get_drive(id), do: get("/drive/v3/drives/#{seg(id)}", fields: "id,name")

  @doc "A file's metadata (`fields` defaults to what the policy needs)."
  def get_file(id, fields \\ @file_fields) do
    get("/drive/v3/files/#{seg(id)}", fields: fields, supportsAllDrives: true)
  end

  @doc "A Google Doc exported as markdown."
  def export_doc(file_id) do
    with {:ok, body} <- get("/drive/v3/files/#{seg(file_id)}/export", mimeType: "text/markdown") do
      {:ok, to_string(body)}
    end
  end

  # --- labels ---

  @doc """
  The published label titled "Classification": its id, the id of its selection
  field, and the ids of the choices that may be indexed (`allowed` display
  names, case-insensitive). Errors when the label or allowed choices are
  missing — the caller must then index nothing.
  """
  def classification_label(title \\ "Classification", allowed \\ ~w(Public Internal)) do
    with {:ok, body} <-
           get(labels_base_url() <> "/v2/labels",
             view: "LABEL_VIEW_FULL",
             publishedOnly: true,
             pageSize: 200
           ) do
      parse_classification(body, title, allowed)
    end
  end

  @doc false
  def parse_classification(body, title, allowed) do
    wanted = MapSet.new(allowed, &String.downcase/1)

    with %{} = label <-
           Enum.find(
             body["labels"] || [],
             &(downcase(get_in(&1, ["properties", "title"])) == downcase(title))
           ),
         %{} = field <- Enum.find(label["fields"] || [], &is_map(&1["selectionOptions"])),
         choices = get_in(field, ["selectionOptions", "choices"]) || [],
         ids =
           for(
             c <- choices,
             MapSet.member?(wanted, downcase(get_in(c, ["properties", "displayName"]))),
             into: MapSet.new(),
             do: c["id"]
           ),
         true <- MapSet.size(ids) > 0 do
      {:ok, %{label_id: label["id"], field_id: field["id"], allowed: ids}}
    else
      _ -> {:error, :classification_label_not_found}
    end
  end

  defp downcase(nil), do: nil
  defp downcase(s), do: String.downcase(s)

  # --- http ---

  defp get(url, params) do
    with {:ok, token} <- OAuth.access_token() do
      case Req.get(req(token), url: url, params: params) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, body}

        {:ok, %{status: 401}} ->
          OAuth.invalidate()
          {:error, :unauthorized}

        {:ok, %{status: 404}} ->
          {:error, :not_found}

        {:ok, %{status: status} = resp} when status == 429 ->
          {:snooze, retry_after(resp)}

        {:ok, %{status: 403, body: body} = resp} ->
          forbidden(resp, body)

        {:ok, %{status: status, body: body}} ->
          {:error, {:drive_http, status, truncate(body)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Drive reports per-user rate limits as 403 rateLimitExceeded.
  defp forbidden(resp, body) do
    if rate_limited?(body),
      do: {:snooze, retry_after(resp)},
      else: {:error, {:drive_http, 403, truncate(body)}}
  end

  defp rate_limited?(%{"error" => %{"errors" => errors}}) when is_list(errors),
    do: Enum.any?(errors, &(&1["reason"] in ["rateLimitExceeded", "userRateLimitExceeded"]))

  defp rate_limited?(_), do: false

  # Retry-After may be absent, an HTTP-date, or garbage; fall back to 60s.
  defp retry_after(resp) do
    with [value | _] <- Req.Response.get_header(resp, "retry-after"),
         {seconds, _} <- Integer.parse(value),
         true <- seconds > 0 do
      seconds
    else
      _ -> 60
    end
  end

  # Oban persists error terms; keep only a short prefix of the response body.
  defp truncate(body), do: body |> inspect(limit: 5, printable_limit: 200) |> String.slice(0, 200)

  # Ids come from API responses or sources.toml: keep them a single path segment.
  defp seg(id), do: URI.encode(id, &URI.char_unreserved?/1)

  # Drive query string literal: escape backslash and single quote.
  defp escape(id), do: id |> String.replace("\\", "\\\\") |> String.replace("'", "\\'")

  defp labels_base_url do
    Application.get_env(:retrieval_node, :drive, [])[:labels_base_url] ||
      "https://drivelabels.googleapis.com"
  end

  defp req(token) do
    cfg = Application.get_env(:retrieval_node, :drive, [])

    [
      base_url: cfg[:base_url] || "https://www.googleapis.com",
      auth: {:bearer, token},
      # 429s are handled above ({:snooze, _}); disable Req's own retry.
      retry: false,
      finch: RetrievalNode.Finch
    ]
    |> Keyword.merge(Application.get_env(:retrieval_node, :drive_req_options, []))
    |> Req.new()
  end
end
