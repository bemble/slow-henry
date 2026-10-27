defmodule RetrievalNodeWeb.SourcesEditLive do
  @moduledoc """
  Editor for `sources.toml` (`RetrievalNode.SourcesFile`): GitHub repos
  picked from the token's list (`Ingest.GitHub.list_repos/0`), other git
  URLs, Jira projects (by key), and the Google Drive scope.

  One tab per kind of source (`?tab=`), plus a Review tab showing
  `SourcesFile.plan/1`; edits made in any tab are kept until saved. Save
  writes the file with `SourcesFile.save/3` — refused when the file changed
  on disk since the page loaded — then has the watcher apply it right away.
  """
  use RetrievalNodeWeb, :live_view

  alias RetrievalNode.GitHub.OAuth, as: GitHubOAuth
  alias RetrievalNode.Google.OAuth, as: GoogleOAuth
  alias RetrievalNode.Ingest.{Drive, DrivePolicy, GitHub}
  alias RetrievalNode.Jira.Credentials, as: JiraCredentials
  alias RetrievalNode.SourcesFile
  alias RetrievalNode.SourcesFile.Watcher

  # Picker rows shown at once; the search narrows the rest.
  @max_matches 50

  @tabs ~w(github other jira drive review)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: "Edit sources",
        query: "",
        review: nil,
        dirty: false,
        drive_info: %{},
        url_form: 0,
        jira_form: 0,
        jira_connected: JiraCredentials.configured?()
      )
      |> load_file()
      |> load_github()

    {:ok, socket}
  end

  defp load_file(socket) do
    path = path()

    case SourcesFile.load_with_hash(path) do
      {:ok, entries, hash} ->
        by_type = Enum.group_by(entries, & &1.source_type)

        socket
        |> assign(path: path, hash: hash, load_error: nil)
        |> assign(
          repos: Enum.map(by_type[:git_repo] || [], &row_from_entry/1),
          jira: Enum.map(by_type[:jira_project] || [], &jira_row/1),
          drive: drive_state(List.first(by_type[:drive_folder] || []))
        )
        |> resolve_drive_ids()

      {:error, msg} ->
        assign(socket, path: path, hash: nil, load_error: msg, repos: [], jira: [], drive: nil)
    end
  end

  # The file the watcher applies (it may have been started with another path).
  defp path do
    case Watcher.status() do
      %{path: path} -> path
      nil -> SourcesFile.default_path()
    end
  end

  defp load_github(socket) do
    cond do
      not connected?(socket) -> assign(socket, github: :loading)
      not GitHubOAuth.authorized?() -> assign(socket, github: :not_connected)
      true -> socket |> assign(github: :loading) |> start_async(:github, &GitHub.list_repos/0)
    end
  end

  defp row_from_entry(entry) do
    %{
      key: new_key(),
      name: entry.name,
      url: entry.identifier,
      active: entry.active,
      pull_requests: entry.config["pull_requests"] == true,
      open_pull_requests: entry.config["open_pull_requests"] == true,
      bot_pull_requests: entry.config["bot_pull_requests"] == true,
      exclude: entry.config["exclude"] || []
    }
  end

  defp new_key, do: "r#{System.unique_integer([:positive])}"

  defp jira_row(entry) do
    %{
      key: new_key(),
      project: entry.identifier,
      active: entry.active,
      options: for(o <- SourcesFile.jira_options(), entry.config[o] == true, do: o)
    }
  end

  defp drive_state(nil), do: nil

  defp drive_state(entry) do
    %{
      my_drive: entry.config["my_drive"],
      shared_with_me: entry.config["shared_with_me"] == true,
      active: entry.active,
      include: entry.config["include"],
      labels: Enum.map(DrivePolicy.label_filters(entry.config), &label_row/1)
    }
  end

  # A label filter as form fields: values as one comma-separated input.
  defp label_row(filter) do
    %{
      label: filter["label"],
      values: Enum.join(filter["values"], ", "),
      unlabeled: filter["unlabeled"]
    }
  end

  # Looks up the name of every Drive id not checked yet.
  defp resolve_drive_ids(%{assigns: %{drive: nil}} = socket), do: socket

  defp resolve_drive_ids(socket) do
    if connected?(socket) and GoogleOAuth.authorized?() do
      socket.assigns.drive.include
      |> Enum.filter(&(Drive.id_from_input(&1) == {:ok, &1}))
      |> Enum.reject(&Map.has_key?(socket.assigns.drive_info, &1))
      |> Enum.reduce(socket, &describe_drive_id/2)
    else
      socket
    end
  end

  defp describe_drive_id(id, socket) do
    socket
    |> update(:drive_info, &Map.put(&1, id, :loading))
    |> start_async({:drive, id}, fn -> Drive.describe(id) end)
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in @tabs, do: params["tab"], else: "github"
    socket = assign(socket, tab: tab)

    {:noreply,
     if(tab == "review", do: assign(socket, review: plan_review(socket.assigns)), else: socket)}
  end

  @impl true
  def handle_async(:github, {:ok, {:ok, repos}}, socket),
    do: {:noreply, assign(socket, github: {:ok, repos})}

  def handle_async(:github, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, github: {:error, reason})}

  def handle_async(:github, {:exit, reason}, socket),
    do: {:noreply, assign(socket, github: {:error, reason})}

  def handle_async({:drive, id}, {:ok, result}, socket),
    do: {:noreply, update(socket, :drive_info, &Map.put(&1, id, result))}

  def handle_async({:drive, id}, {:exit, reason}, socket),
    do: {:noreply, update(socket, :drive_info, &Map.put(&1, id, {:error, reason}))}

  @impl true
  def handle_event("search", %{"query" => query}, socket),
    do: {:noreply, assign(socket, query: query)}

  def handle_event("close_search", _params, socket),
    do: {:noreply, assign(socket, query: "")}

  def handle_event("change", params, socket) do
    repos = Enum.map(socket.assigns.repos, &update_repo(&1, params["repos"][&1.key]))
    jira = Enum.map(socket.assigns.jira, &update_jira(&1, params["jira"][&1.key]))
    drive = update_drive(socket.assigns.drive, params["drive"])
    {:noreply, socket |> edited(repos: repos, jira: jira, drive: drive) |> resolve_drive_ids()}
  end

  def handle_event("toggle_github", %{"full_name" => full_name}, socket) do
    repos = socket.assigns.repos

    repos =
      case Enum.split_with(repos, &(github_name(&1) == String.downcase(full_name))) do
        {[], _} -> repos ++ [github_row(full_name, socket.assigns.github, repos)]
        {_selected, rest} -> rest
      end

    {:noreply, edited(socket, repos: repos)}
  end

  def handle_event("add_url", %{"url" => url}, socket) do
    url = String.trim(url)

    socket =
      if url == "" do
        socket
      else
        row = new_row(name_from_url(url), url, socket.assigns.repos)

        edited(socket,
          repos: socket.assigns.repos ++ [row],
          url_form: socket.assigns.url_form + 1
        )
      end

    {:noreply, socket}
  end

  # Project keys are upper-case; validation reports anything else.
  def handle_event("add_jira", %{"project" => project}, socket) do
    project = project |> String.trim() |> String.upcase()

    socket =
      if project == "" or Enum.any?(socket.assigns.jira, &(&1.project == project)) do
        socket
      else
        row = %{key: new_key(), project: project, active: true, options: []}

        edited(socket,
          jira: socket.assigns.jira ++ [row],
          jira_form: socket.assigns.jira_form + 1
        )
      end

    {:noreply, socket}
  end

  def handle_event("remove_jira", %{"key" => key}, socket),
    do: {:noreply, edited(socket, jira: Enum.reject(socket.assigns.jira, &(&1.key == key)))}

  def handle_event("remove_repo", %{"key" => key}, socket),
    do: {:noreply, edited(socket, repos: Enum.reject(socket.assigns.repos, &(&1.key == key)))}

  def handle_event("add_exclude", %{"key" => key}, socket),
    do: {:noreply, edit_repo(socket, key, &%{&1 | exclude: &1.exclude ++ [""]})}

  def handle_event("remove_exclude", %{"key" => key, "index" => index}, socket) do
    index = String.to_integer(index)
    {:noreply, edit_repo(socket, key, &%{&1 | exclude: List.delete_at(&1.exclude, index)})}
  end

  def handle_event("enable_drive", _params, socket) do
    drive = %{
      my_drive: true,
      shared_with_me: false,
      active: true,
      include: [],
      labels: Enum.map(DrivePolicy.default_label_filters(), &label_row/1)
    }

    {:noreply, edited(socket, drive: drive)}
  end

  def handle_event("disable_drive", _params, socket),
    do: {:noreply, edited(socket, drive: nil)}

  def handle_event("add_include", _params, socket) do
    drive = socket.assigns.drive
    {:noreply, edited(socket, drive: %{drive | include: drive.include ++ [""]})}
  end

  def handle_event("add_label", _params, socket) do
    drive = socket.assigns.drive
    row = %{label: "", values: "", unlabeled: false}
    {:noreply, edited(socket, drive: %{drive | labels: drive.labels ++ [row]})}
  end

  def handle_event("remove_label", %{"index" => index}, socket) do
    drive = socket.assigns.drive
    labels = List.delete_at(drive.labels, String.to_integer(index))
    {:noreply, edited(socket, drive: %{drive | labels: labels})}
  end

  def handle_event("remove_include", %{"index" => index}, socket) do
    drive = socket.assigns.drive
    include = List.delete_at(drive.include, String.to_integer(index))
    {:noreply, edited(socket, drive: %{drive | include: include})}
  end

  # Submitting a form (Enter in a field) opens the Review tab.
  def handle_event("review", _params, %{assigns: %{tab: "review"}} = socket),
    do: {:noreply, assign(socket, review: plan_review(socket.assigns))}

  def handle_event("review", _params, socket),
    do: {:noreply, push_patch(socket, to: ~p"/sources/edit?tab=review")}

  def handle_event("save", _params, socket) do
    %{path: path, hash: hash} = socket.assigns

    with {:ok, entries} <- entries(socket.assigns),
         {:ok, _hash} <- SourcesFile.save(path, entries, hash) do
      {:noreply, socket |> put_flash_applied() |> push_navigate(to: ~p"/")}
    else
      {:error, :conflict} ->
        msg =
          "#{path} changed on disk since this page was loaded. " <>
            "Reload the page to edit its current content (your edits here are lost)."

        {:noreply, socket |> assign(review: nil) |> put_flash(:error, msg)}

      {:error, msg} ->
        {:noreply, assign(socket, review: {:error, msg})}
    end
  end

  # The watcher applies the file now instead of on its next tick.
  defp put_flash_applied(socket) do
    case Watcher.status() && Watcher.check_now() do
      nil ->
        put_flash(socket, :info, "Sources saved. Apply them with mix rn.sources.")

      %{error: nil} ->
        put_flash(socket, :info, "Sources saved and applied.")

      %{error: error} ->
        put_flash(socket, :error, "Sources saved but not applied: #{error}")
    end
  end

  defp plan_review(assigns) do
    with {:ok, entries} <- entries(assigns),
         {:ok, changes} <- SourcesFile.plan(entries) do
      {:ok, changes, SourcesFile.encode(entries)}
    end
  end

  # Any edit invalidates the review.
  defp edited(socket, assigns), do: assign(socket, [review: nil, dirty: true] ++ assigns)

  defp edit_repo(socket, key, fun) do
    repos = Enum.map(socket.assigns.repos, &if(&1.key == key, do: fun.(&1), else: &1))
    edited(socket, repos: repos)
  end

  defp update_repo(row, nil), do: row

  defp update_repo(row, params) do
    %{
      row
      | name: params["name"] || row.name,
        url: params["url"] || row.url,
        active: params["active"] == "true",
        pull_requests: params["pull_requests"] == "true",
        # Disabled (so not sent) while PRs (open PRs) are off.
        open_pull_requests: params["open_pull_requests"] == "true",
        bot_pull_requests: params["bot_pull_requests"] == "true",
        exclude: params["exclude"] || []
    }
  end

  defp update_jira(row, nil), do: row

  defp update_jira(row, params) do
    %{
      row
      | active: params["active"] == "true",
        options: for(o <- SourcesFile.jira_options(), params[o] == "true", do: o)
    }
  end

  defp update_drive(nil, _params), do: nil
  defp update_drive(drive, nil), do: drive

  defp update_drive(drive, params) do
    %{
      drive
      | my_drive: params["my_drive"] == "true",
        shared_with_me: params["shared_with_me"] == "true",
        active: params["active"] == "true",
        include: Enum.map(params["include"] || [], &normalize_id/1),
        labels: update_labels(drive.labels, params["labels"])
    }
  end

  # Rows are keyed by their index; a form without them keeps the rows as they are.
  defp update_labels(rows, nil), do: rows

  defp update_labels(rows, params) do
    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, i} ->
      case params[to_string(i)] do
        nil ->
          row

        p ->
          %{
            label: p["label"] || row.label,
            values: p["values"] || row.values,
            unlabeled: p["unlabeled"] == "true"
          }
      end
    end)
  end

  # A pasted Drive URL becomes its id; anything else is kept for the
  # validation to report.
  defp normalize_id(input) do
    case Drive.id_from_input(input) do
      {:ok, id} -> id
      :error -> input
    end
  end

  # --- rows ---

  defp github_full_name(row) do
    case GitHub.repo_from_url(row.url) do
      {:ok, full_name} -> full_name
      :error -> nil
    end
  end

  # GitHub names are case-insensitive.
  defp github_name(row), do: (name = github_full_name(row)) && String.downcase(name)

  defp github_row(full_name, {:ok, repos}, rows) do
    repo = Enum.find(repos, &(&1.full_name == full_name))
    [_owner, name] = String.split(full_name, "/", parts: 2)
    url = (repo && repo.clone_url) || "https://github.com/#{full_name}.git"
    names = MapSet.new(rows, & &1.name)
    name = if MapSet.member?(names, name), do: String.replace(full_name, "/", "-"), else: name
    new_row(name, url, rows)
  end

  defp new_row(name, url, rows) do
    names = MapSet.new(rows, & &1.name)

    name =
      Enum.find([name | for(i <- 2..99, do: "#{name}-#{i}")], &(not MapSet.member?(names, &1)))

    %{
      key: new_key(),
      name: name,
      url: url,
      active: true,
      pull_requests: false,
      open_pull_requests: false,
      bot_pull_requests: false,
      exclude: []
    }
  end

  # `https://host/org/repo.git` → "repo", made a valid source name.
  defp name_from_url(url) do
    url
    |> String.trim_trailing("/")
    |> String.split(["/", ":"])
    |> List.last()
    |> String.replace_suffix(".git", "")
    |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
    |> String.trim_leading(".")
    |> case do
      "" -> "repo"
      name -> name
    end
  end

  # --- entries ---

  # The form as a TOML document, so `SourcesFile.parse/1` validates it.
  defp entries(%{repos: repos, jira: jira, drive: drive}) do
    git =
      for r <- repos do
        %{
          "name" => String.trim(r.name),
          "url" => String.trim(r.url),
          "active" => r.active,
          "pull_requests" => r.pull_requests,
          "open_pull_requests" => r.pull_requests and r.open_pull_requests,
          "bot_pull_requests" => r.pull_requests and r.open_pull_requests and r.bot_pull_requests,
          "exclude" => non_blank(r.exclude)
        }
      end

    doc = %{
      "git" => git,
      "jira" =>
        for j <- jira do
          Map.merge(
            %{"project" => j.project, "active" => j.active},
            Map.new(j.options, &{&1, true})
          )
        end
    }

    doc =
      if drive,
        do:
          Map.put(doc, "drive", %{
            "my_drive" => drive.my_drive,
            "shared_with_me" => drive.shared_with_me,
            "active" => drive.active,
            "include" => non_blank(drive.include),
            "include_labels" =>
              for l <- drive.labels do
                %{
                  "label" => String.trim(l.label),
                  "values" => non_blank(String.split(l.values, ",")),
                  "unlabeled" => l.unlabeled
                }
              end
          }),
        else: doc

    SourcesFile.parse(doc)
  end

  defp non_blank(values), do: values |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp matches({:ok, repos}, query) do
    query = query |> String.trim() |> String.downcase()
    Enum.filter(repos, &String.contains?(String.downcase(&1.full_name), query))
  end

  defp matches(_github, _query), do: []

  # --- render ---

  @impl true
  def render(assigns) do
    {github_rows, other_rows} = Enum.split_with(assigns.repos, &github_name/1)
    selected = MapSet.new(github_rows, &github_name/1)
    matches = matches(assigns.github, assigns.query)

    assigns =
      assign(assigns,
        github_rows: github_rows,
        other_rows: other_rows,
        selected: selected,
        matches: Enum.take(matches, @max_matches),
        more: max(length(matches) - @max_matches, 0),
        listed: listed(assigns.github)
      )

    ~H"""
    <Layouts.app flash={@flash} active={:sources}>
      <.header>
        Edit sources
        <:subtitle>
          Writes <code>{@path}</code>, which is applied as soon as it is saved.
          Removing a source deactivates it: its indexed chunks stay searchable.
        </:subtitle>
        <:actions>
          <.link navigate={~p"/"} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="size-4" /> Sources
          </.link>
        </:actions>
      </.header>

      <div :if={@load_error} id="load-error" role="alert" class="alert alert-error">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <span>
          <code>{@path}</code>
          is invalid, so it can't be edited here: {@load_error}. Fix it by hand first.
        </span>
      </div>

      <div :if={!@load_error} class="space-y-4">
        <div role="tablist" id="source-tabs" class="tabs tabs-border overflow-x-auto flex-nowrap">
          <.tab_link
            :for={{tab, label, icon, count} <- tab_items(assigns)}
            tab={tab}
            active={@tab}
            label={label}
            icon={icon}
            count={count}
            dirty={tab == "review" && @dirty}
          />
        </div>

        <section :if={@tab == "github"} id="github" role="tabpanel" class="space-y-3">
          <p class="text-sm opacity-70">
            Repositories your GitHub connection can read. Each one is cloned and indexed;
            check <em>Merged PRs</em> to index its merged pull requests too.
          </p>
          <.github_picker
            github={@github}
            query={@query}
            matches={@matches}
            more={@more}
            selected={@selected}
          />
          <form
            :if={@github_rows != []}
            id="github-repos-form"
            phx-change="change"
            phx-submit="review"
            class="space-y-2"
          >
            <.repo_row
              :for={row <- @github_rows}
              row={row}
              github={github_full_name(row)}
              unlisted={@listed != nil && !MapSet.member?(@listed, github_name(row))}
            />
          </form>
        </section>

        <section :if={@tab == "other"} id="other" role="tabpanel" class="space-y-3">
          <p class="text-sm opacity-70">
            Any git URL (<code>https://</code>, <code>ssh://</code>, <code>file://</code>…).
            A public GitHub repo missing from the GitHub list can be added here by its URL.
          </p>
          <form
            :if={@other_rows != []}
            id="other-repos-form"
            phx-change="change"
            phx-submit="review"
            class="space-y-2"
          >
            <.repo_row :for={row <- @other_rows} row={row} />
          </form>
          <form
            id={"add-url-#{@url_form}"}
            phx-submit="add_url"
            class="flex items-start gap-2"
          >
            <div class="grow">
              <.input name="url" value="" placeholder="https://git.example.com/team/repo.git" />
            </div>
            <button type="submit" class="btn btn-sm mt-1">
              <.icon name="hero-plus" class="size-4" /> Add
            </button>
          </form>
        </section>

        <section :if={@tab == "jira"} id="jira" role="tabpanel" class="space-y-3">
          <p class="text-sm opacity-70">
            Resolved issues (status category Done) of each project, by its key: summary,
            description, type and status, plus the fields checked below.
          </p>
          <div :if={!@jira_connected} id="jira-not-connected" role="alert" class="alert alert-warning">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <span>
              <.link navigate={~p"/settings"} class="link">Connect Jira</.link>
              first: projects don't sync without an API token.
            </span>
          </div>
          <form
            :if={@jira != []}
            id="jira-projects-form"
            phx-change="change"
            phx-submit="review"
            class="space-y-2"
          >
            <div
              :for={row <- @jira}
              id={"jira-#{row.key}"}
              class="flex flex-wrap items-center gap-x-4 gap-y-1 rounded-box border border-base-300 px-3 py-2"
            >
              <span class="w-32 font-mono font-medium">{row.project}</span>
              <.input
                type="checkbox"
                id={"#{row.key}-active"}
                name={"jira[#{row.key}][active]"}
                value={row.active}
                label="Active"
              />
              <.input
                :for={o <- SourcesFile.jira_options()}
                type="checkbox"
                id={"#{row.key}-#{o}"}
                name={"jira[#{row.key}][#{o}]"}
                value={o in row.options}
                label={jira_option_label(o)}
              />
              <button
                type="button"
                phx-click="remove_jira"
                phx-value-key={row.key}
                class="btn btn-ghost btn-sm ml-auto"
                title="Remove (deactivates the source)"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>
          </form>
          <form id={"add-jira-#{@jira_form}"} phx-submit="add_jira" class="flex items-start gap-2">
            <div class="w-48">
              <.input name="project" value="" placeholder="Project key, e.g. CLOUD" />
            </div>
            <button type="submit" class="btn btn-sm mt-1">
              <.icon name="hero-plus" class="size-4" /> Add
            </button>
          </form>
        </section>

        <section :if={@tab == "drive"} id="drive" role="tabpanel" class="space-y-3">
          <.drive_form drive={@drive} info={@drive_info} />
        </section>

        <section :if={@tab == "review"} id="review" role="tabpanel" class="space-y-3">
          <.review review={@review} />
          <button
            :if={!@review}
            id="review-again"
            type="button"
            phx-click="review"
            class="btn btn-sm"
          >
            <.icon name="hero-arrow-path" class="size-4" /> Review again
          </button>
        </section>

        <div
          :if={@tab != "review"}
          class="flex items-center justify-end gap-3 border-t border-base-300 pt-4"
        >
          <span :if={@dirty} class="text-sm opacity-70">Unsaved changes</span>
          <.link
            id="review-button"
            patch={~p"/sources/edit?tab=review"}
            class={["btn", if(@dirty, do: "btn-primary", else: "btn-ghost")]}
          >
            <.icon name="hero-eye" class="size-4" /> Review changes
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp tab_items(assigns) do
    [
      {"github", "GitHub", "hero-code-bracket", length(assigns.github_rows)},
      {"other", "Other git", "hero-server-stack", length(assigns.other_rows)},
      {"jira", "Jira", "hero-ticket", length(assigns.jira)},
      {"drive", "Google Drive", "hero-folder", if(assigns.drive, do: "on", else: "off")},
      {"review", "Review & save", "hero-eye", nil}
    ]
  end

  attr :tab, :string, required: true
  attr :active, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :count, :any, default: nil
  attr :dirty, :boolean, default: false

  defp tab_link(assigns) do
    ~H"""
    <.link
      id={"tab-#{@tab}"}
      role="tab"
      aria-selected={to_string(@tab == @active)}
      patch={~p"/sources/edit?tab=#{@tab}"}
      class={["tab gap-2 whitespace-nowrap", @tab == @active && "tab-active"]}
    >
      <.icon name={@icon} class="size-4" />
      {@label}
      <span :if={@count} class="badge badge-sm badge-ghost">{@count}</span>
      <span :if={@dirty} class="status status-warning" title="Unsaved changes"></span>
    </.link>
    """
  end

  defp jira_option_label("parent"), do: "Parent / epic"
  defp jira_option_label(option), do: String.capitalize(option)

  defp listed({:ok, repos}), do: MapSet.new(repos, &String.downcase(&1.full_name))
  defp listed(_github), do: nil

  attr :github, :any, required: true
  attr :query, :string, required: true
  attr :matches, :list, required: true
  attr :more, :integer, required: true
  attr :selected, :any, required: true

  defp github_picker(%{github: :loading} = assigns) do
    ~H"""
    <p id="github-loading" class="text-sm opacity-70">
      <span class="loading loading-spinner loading-xs"></span> Loading your repositories…
    </p>
    """
  end

  defp github_picker(%{github: :not_connected} = assigns) do
    ~H"""
    <p id="github-not-connected" class="text-sm opacity-70">
      <.link navigate={~p"/settings"} class="link">Connect GitHub</.link>
      to pick repositories from a list.
    </p>
    """
  end

  defp github_picker(%{github: {:error, _}} = assigns) do
    ~H"""
    <p id="github-error" class="text-sm text-error">
      Could not list your GitHub repositories: {inspect(elem(@github, 1))}
    </p>
    """
  end

  # A dropdown under the search field, open while it holds text.
  defp github_picker(assigns) do
    ~H"""
    <div id="repo-picker" class="relative" phx-click-away={@query != "" && "close_search"}>
      <form id="repo-search" phx-change="search" phx-submit="search">
        <label class="input w-full">
          <.icon name="hero-magnifying-glass" class="size-4 opacity-50" />
          <input
            type="search"
            name="query"
            value={@query}
            placeholder="Search your repositories to add one"
            phx-debounce="150"
            autocomplete="off"
            class="grow"
          />
        </label>
      </form>
      <ul
        :if={String.trim(@query) != ""}
        id="repo-matches"
        class="absolute z-20 mt-1 max-h-80 w-full overflow-y-auto rounded-box border border-base-300 bg-base-100 shadow-lg"
      >
        <li
          :for={repo <- @matches}
          id={"match-#{String.replace(repo.full_name, ~r/[^A-Za-z0-9_-]/, "-")}"}
          class="border-b border-base-300 last:border-b-0"
        >
          <button
            type="button"
            phx-click="toggle_github"
            phx-value-full_name={repo.full_name}
            class="flex w-full items-center gap-2 px-3 py-1.5 text-left hover:bg-base-200"
          >
            <div class="grow">
              <span class="font-medium">{repo.full_name}</span>
              <.icon :if={repo.private} name="hero-lock-closed" class="size-3 opacity-60" />
              <div :if={repo.description} class="text-xs opacity-60">
                {RetrievalNodeWeb.Format.truncate(repo.description, 100)}
              </div>
            </div>
            <%= if MapSet.member?(@selected, String.downcase(repo.full_name)) do %>
              <span class="badge badge-success badge-sm gap-1">
                <.icon name="hero-check" class="size-3" /> Added
              </span>
            <% else %>
              <span class="badge badge-ghost badge-sm gap-1">
                <.icon name="hero-plus" class="size-3" /> Add
              </span>
            <% end %>
          </button>
        </li>
        <li :if={@matches == []} class="px-3 py-2 text-sm opacity-60">
          No repository matches.
        </li>
        <li :if={@more > 0} class="border-t border-base-300 px-3 py-2 text-sm opacity-60">
          {@more} more — refine the search.
        </li>
      </ul>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :github, :string, default: nil
  attr :unlisted, :boolean, default: false

  defp repo_row(assigns) do
    ~H"""
    <div id={"repo-#{@row.key}"} class="rounded-box border border-base-300 p-3">
      <div class="flex flex-wrap items-start gap-x-4 gap-y-1">
        <div class="w-48">
          <.input name={"repos[#{@row.key}][name]"} value={@row.name} label="Name" />
        </div>
        <div class="min-w-64 grow">
          <.input
            :if={!@github}
            name={"repos[#{@row.key}][url]"}
            value={@row.url}
            label="URL"
          />
          <div :if={@github} class="pt-7">
            <span class="font-medium">{@github}</span>
            <span
              :if={@unlisted}
              class="badge badge-ghost badge-sm"
              title="Not in the repositories your GitHub token lists (fine for a public repo)"
            >
              not listed
            </span>
            <div class="text-xs opacity-60">{@row.url}</div>
          </div>
        </div>
        <div class="flex gap-4 pt-6">
          <.input
            type="checkbox"
            id={"#{@row.key}-active"}
            name={"repos[#{@row.key}][active]"}
            value={@row.active}
            label="Active"
          />
          <.input
            type="checkbox"
            id={"#{@row.key}-prs"}
            name={"repos[#{@row.key}][pull_requests]"}
            value={@row.pull_requests}
            label="Merged PRs"
          />
          <.input
            type="checkbox"
            id={"#{@row.key}-open-prs"}
            name={"repos[#{@row.key}][open_pull_requests]"}
            value={@row.pull_requests and @row.open_pull_requests}
            disabled={not @row.pull_requests}
            label="Open PRs"
          />
          <.input
            type="checkbox"
            id={"#{@row.key}-bot-prs"}
            name={"repos[#{@row.key}][bot_pull_requests]"}
            value={@row.pull_requests and @row.open_pull_requests and @row.bot_pull_requests}
            disabled={not (@row.pull_requests and @row.open_pull_requests)}
            label="Open bot PRs"
          />
        </div>
        <button
          type="button"
          phx-click="remove_repo"
          phx-value-key={@row.key}
          class="btn btn-ghost btn-sm ml-auto mt-6"
          title="Remove (deactivates the source)"
        >
          <.icon name="hero-trash" class="size-4" />
        </button>
      </div>

      <div class="mt-1 space-y-1">
        <div class="text-xs opacity-70">
          Excluded paths (.gitignore-style; <code>!</code> re-includes)
        </div>
        <div :for={{pattern, i} <- Enum.with_index(@row.exclude)} class="flex items-start gap-2">
          <div class="grow">
            <.input
              id={"#{@row.key}-exclude-#{i}"}
              name={"repos[#{@row.key}][exclude][]"}
              value={pattern}
              placeholder="docs/*"
              class="input input-sm w-full font-mono"
            />
          </div>
          <button
            type="button"
            phx-click="remove_exclude"
            phx-value-key={@row.key}
            phx-value-index={i}
            class="btn btn-ghost btn-sm"
            title="Remove pattern"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
        <button
          type="button"
          phx-click="add_exclude"
          phx-value-key={@row.key}
          class="btn btn-ghost btn-xs"
        >
          <.icon name="hero-plus" class="size-4" /> Exclude a path
        </button>
      </div>
    </div>
    """
  end

  attr :drive, :any, required: true
  attr :info, :map, required: true

  defp drive_form(%{drive: nil} = assigns) do
    ~H"""
    <div class="flex items-center gap-3 rounded-box border border-dashed border-base-300 p-4">
      <span class="text-sm opacity-70">Google Drive is not indexed.</span>
      <button id="enable-drive" type="button" phx-click="enable_drive" class="btn btn-sm">
        <.icon name="hero-plus" class="size-4" /> Index Google Drive
      </button>
    </div>
    """
  end

  defp drive_form(assigns) do
    ~H"""
    <form id="drive-form" phx-change="change" phx-submit="review" class="space-y-6">
      <fieldset class="space-y-2">
        <h3 class="font-semibold">Scope</h3>
        <div class="flex flex-wrap gap-6">
        <.input
          type="checkbox"
          id="drive-my-drive"
          name="drive[my_drive]"
          value={@drive.my_drive}
          label="Docs I own"
        />
        <.input
          type="checkbox"
          id="drive-shared"
          name="drive[shared_with_me]"
          value={@drive.shared_with_me}
          label="Docs shared directly with me"
        />
        <.input
          type="checkbox"
          id="drive-active"
          name="drive[active]"
          value={@drive.active}
          label="Active"
        />
        </div>
      </fieldset>

      <fieldset class="space-y-2">
        <h3 class="font-semibold">Label filters</h3>
        <p class="text-xs opacity-70">
          All must pass: a doc passes one when its selected choice(s) are all
          listed, or when it doesn't carry the label and "Docs without it" is checked.
          No filter: every doc in scope is indexed.
        </p>
      <div :for={{l, i} <- Enum.with_index(@drive.labels)} class="flex items-start gap-2">
        <div class="w-56">
          <.input
            id={"drive-label-#{i}"}
            name={"drive[labels][#{i}][label]"}
            value={l.label}
            placeholder="Label title"
            class="input input-sm w-full"
          />
        </div>
        <div class="w-80">
          <.input
            id={"drive-label-values-#{i}"}
            name={"drive[labels][#{i}][values]"}
            value={l.values}
            placeholder="Choices, comma-separated"
            class="input input-sm w-full"
          />
        </div>
        <.input
          type="checkbox"
          id={"drive-label-unlabeled-#{i}"}
          name={"drive[labels][#{i}][unlabeled]"}
          value={l.unlabeled}
          label="Docs without it"
        />
        <button
          type="button"
          phx-click="remove_label"
          phx-value-index={i}
          class="btn btn-ghost btn-sm ml-auto"
          title="Remove"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
      <button id="add-label" type="button" phx-click="add_label" class="btn btn-ghost btn-xs">
        <.icon name="hero-plus" class="size-4" /> Add a label filter
      </button>
      </fieldset>

      <fieldset class="space-y-2">
        <h3 class="font-semibold">Shared drives and folders</h3>
        <p class="text-xs opacity-70">Paste an id or the folder's URL.</p>
      <div :for={{id, i} <- Enum.with_index(@drive.include)} class="flex items-start gap-2">
        <div class="w-96">
          <.input
            id={"drive-include-#{i}"}
            name="drive[include][]"
            value={id}
            placeholder="https://drive.google.com/drive/folders/…"
            class="input input-sm w-full font-mono"
          />
        </div>
        <.drive_id_info info={@info[id]} />
        <button
          type="button"
          phx-click="remove_include"
          phx-value-index={i}
          class="btn btn-ghost btn-sm ml-auto"
          title="Remove"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
      <button id="add-include" type="button" phx-click="add_include" class="btn btn-ghost btn-xs">
        <.icon name="hero-plus" class="size-4" /> Add a shared drive or folder
      </button>
      </fieldset>

      <div class="border-t border-base-300 pt-3">
        <button
          id="disable-drive"
          type="button"
          phx-click="disable_drive"
          class="btn btn-ghost btn-sm text-error"
        >
          <.icon name="hero-trash" class="size-4" /> Stop indexing Google Drive
        </button>
      </div>
    </form>
    """
  end

  attr :info, :any, required: true

  defp drive_id_info(assigns) do
    ~H"""
    <span class="pt-2 text-sm">
      <%= case @info do %>
        <% nil -> %>
        <% :loading -> %>
          <span class="loading loading-spinner loading-xs"></span>
        <% {:ok, %{name: name, kind: kind}} -> %>
          <span class="badge badge-ghost badge-sm">
            {if kind == :shared_drive, do: "shared drive", else: "folder"}
          </span>
          {name}
        <% {:error, :not_found} -> %>
          <span class="text-error">not found, or not shared with you</span>
        <% {:error, :not_a_folder} -> %>
          <span class="text-error">not a folder</span>
        <% {:error, _} -> %>
          <span class="opacity-60">could not check</span>
      <% end %>
    </span>
    """
  end

  attr :review, :any, required: true

  defp review(%{review: nil} = assigns), do: ~H""

  defp review(%{review: {:error, _}} = assigns) do
    ~H"""
    <div id="review-error" role="alert" class="alert alert-error text-sm">
      <.icon name="hero-exclamation-triangle" class="size-5" />
      <span>{elem(@review, 1)}</span>
    </div>
    """
  end

  defp review(assigns) do
    {:ok, changes, body} = assigns.review
    {unchanged, changes} = Enum.split_with(changes, &match?({:unchanged, _}, &1))
    assigns = assign(assigns, changes: changes, unchanged: length(unchanged), body: body)

    ~H"""
    <div id="review-plan" class="space-y-3">
      <ul class="space-y-1 text-sm">
        <li :for={change <- @changes}>{describe(change)}</li>
        <li :if={@changes == []} class="opacity-70">No source changes.</li>
        <li :if={@unchanged > 0} class="opacity-60">{@unchanged} source(s) unchanged.</li>
      </ul>
      <details class="text-sm">
        <summary class="cursor-pointer opacity-70">File preview</summary>
        <pre class="mt-2 overflow-x-auto rounded-box bg-base-200 p-3 text-xs">{@body}</pre>
      </details>
      <button id="save-button" type="button" phx-click="save" class="btn btn-primary">
        <.icon name="hero-check" class="size-4" /> Save
      </button>
    </div>
    """
  end

  defp describe({:add, %{active: false} = e}), do: "Add #{e.name} (inactive)"
  defp describe({:add, e}), do: "Add #{e.name}, then sync it"
  defp describe({:deactivate, s}), do: "Deactivate #{s.name} (its chunks stay searchable)"

  defp describe({:update, s, e}) do
    what =
      [
        s.name != e.name && rename(s, e),
        (s.active and not e.active) && "deactivated",
        (not s.active and e.active) && "reactivated",
        Map.delete(s.config || %{}, "mirror_slug") != e.config && "options changed"
      ]
      |> Enum.filter(& &1)
      |> Enum.join(", ")

    "Update #{s.name}: #{what}"
  end

  defp rename(s, e) do
    case SourcesFile.pinned_slug(s, e) do
      nil -> "renamed to #{e.name}"
      slug -> "renamed to #{e.name} (repo slug #{slug} kept)"
    end
  end
end
