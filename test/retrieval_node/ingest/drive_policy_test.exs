defmodule RetrievalNode.Ingest.DrivePolicyTest do
  use ExUnit.Case, async: true

  alias RetrievalNode.Ingest.{Drive, DrivePolicy}

  @cls [
    %{
      label_id: "lbl",
      field_id: "fld",
      allowed: MapSet.new(["public", "internal"]),
      unlabeled: true
    }
  ]
  def no_parents(_id), do: []
  @no_parents &__MODULE__.no_parents/1

  defp doc(attrs \\ %{}),
    do: Map.merge(%{"id" => "d1", "mimeType" => Drive.doc_mime(), "parents" => ["p0"]}, attrs)

  defp labelled(selection),
    do: %{
      "labelInfo" => %{
        "labels" => [%{"id" => "lbl", "fields" => %{"fld" => %{"selection" => selection}}}]
      }
    }

  defp scope(attrs),
    do: Map.merge(%{my_drive: false, drives: MapSet.new(), folders: MapSet.new()}, attrs)

  describe "labels_allowed?/2" do
    test "no Classification label: allowed (other labels don't matter)" do
      assert DrivePolicy.labels_allowed?(doc(), @cls)

      other = %{"labelInfo" => %{"labels" => [%{"id" => "other", "fields" => %{}}]}}
      assert DrivePolicy.labels_allowed?(doc(other), @cls)
    end

    test "Public or Internal: allowed" do
      assert DrivePolicy.labels_allowed?(doc(labelled(["public"])), @cls)
      assert DrivePolicy.labels_allowed?(doc(labelled(["internal"])), @cls)
    end

    test "any other choice, or a label without value: not allowed" do
      refute DrivePolicy.labels_allowed?(doc(labelled(["confidential"])), @cls)
      refute DrivePolicy.labels_allowed?(doc(labelled(["public", "confidential"])), @cls)
      refute DrivePolicy.labels_allowed?(doc(labelled([])), @cls)

      no_field = %{"labelInfo" => %{"labels" => [%{"id" => "lbl", "fields" => %{}}]}}
      refute DrivePolicy.labels_allowed?(doc(no_field), @cls)
    end

    test "every filter must pass; without `unlabeled`, the label is required" do
      team = %{label_id: "team", field_id: "tf", allowed: MapSet.new(["cloud"]), unlabeled: false}
      filters = @cls ++ [team]

      team_label = fn choice ->
        %{"id" => "team", "fields" => %{"tf" => %{"selection" => [choice]}}}
      end

      with_labels = fn labels -> doc(%{"labelInfo" => %{"labels" => labels}}) end

      refute DrivePolicy.labels_allowed?(doc(), filters)
      assert DrivePolicy.labels_allowed?(with_labels.([team_label.("cloud")]), filters)
      refute DrivePolicy.labels_allowed?(with_labels.([team_label.("core")]), filters)

      public = %{"id" => "lbl", "fields" => %{"fld" => %{"selection" => ["public"]}}}
      secret = %{"id" => "lbl", "fields" => %{"fld" => %{"selection" => ["confidential"]}}}
      assert DrivePolicy.labels_allowed?(with_labels.([public, team_label.("cloud")]), filters)
      refute DrivePolicy.labels_allowed?(with_labels.([secret, team_label.("cloud")]), filters)
    end

    test "no filters: everything passes" do
      assert DrivePolicy.labels_allowed?(doc(labelled(["confidential"])), [])
    end
  end

  describe "in_scope?/3" do
    test "My Drive: owned by me, only when my_drive is on" do
      mine = doc(%{"owners" => [%{"me" => true}]})
      theirs = doc(%{"owners" => [%{"me" => false}]})

      assert DrivePolicy.in_scope?(mine, scope(%{my_drive: true}), @no_parents)
      refute DrivePolicy.in_scope?(theirs, scope(%{my_drive: true}), @no_parents)
      refute DrivePolicy.in_scope?(mine, scope(%{my_drive: false}), @no_parents)
    end

    test "shared with me: only directly shared docs, only when shared_with_me is on" do
      shared =
        doc(%{"sharedWithMeTime" => "2026-10-01T09:00:00.000Z", "owners" => [%{"me" => false}]})

      in_shared_folder = doc(%{"owners" => [%{"me" => false}]})

      assert DrivePolicy.in_scope?(shared, scope(%{shared_with_me: true}), @no_parents)
      refute DrivePolicy.in_scope?(shared, scope(%{shared_with_me: false}), @no_parents)
      refute DrivePolicy.in_scope?(in_shared_folder, scope(%{shared_with_me: true}), @no_parents)
    end

    test "shared drive by driveId" do
      file = doc(%{"driveId" => "drv"})
      assert DrivePolicy.in_scope?(file, scope(%{drives: MapSet.new(["drv"])}), @no_parents)
      refute DrivePolicy.in_scope?(file, scope(%{drives: MapSet.new(["other"])}), @no_parents)
    end

    test "below an included folder, at any depth" do
      tree = %{"p0" => ["p1"], "p1" => ["p2"], "p2" => ["root"], "root" => []}
      parents_of = &Map.get(tree, &1, [])

      assert DrivePolicy.in_scope?(doc(), scope(%{folders: MapSet.new(["p0"])}), parents_of)
      assert DrivePolicy.in_scope?(doc(), scope(%{folders: MapSet.new(["p2"])}), parents_of)

      refute DrivePolicy.in_scope?(
               doc(),
               scope(%{folders: MapSet.new(["elsewhere"])}),
               parents_of
             )
    end

    test "parent cycles terminate" do
      loop = %{"p0" => ["p1"], "p1" => ["p0"]}

      refute DrivePolicy.in_scope?(
               doc(),
               scope(%{folders: MapSet.new(["x"])}),
               &Map.get(loop, &1, [])
             )
    end
  end

  test "indexable?/4 needs a live doc, in scope, with allowed labels" do
    s = scope(%{my_drive: true})
    mine = %{"owners" => [%{"me" => true}]}

    assert DrivePolicy.indexable?(doc(mine), s, @cls, @no_parents)
    refute DrivePolicy.indexable?(doc(Map.put(mine, "trashed", true)), s, @cls, @no_parents)

    refute DrivePolicy.indexable?(
             doc(Map.put(mine, "mimeType", "application/pdf")),
             s,
             @cls,
             @no_parents
           )

    refute DrivePolicy.indexable?(
             doc(Map.merge(mine, labelled(["confidential"]))),
             s,
             @cls,
             @no_parents
           )

    refute DrivePolicy.indexable?(doc(), s, @cls, @no_parents)
  end

  test "Drive.strip_images/1 drops inline and reference-style images, keeps the text" do
    b64 = String.duplicate("iVBORw0KGgo", 50)

    markdown = """
    # Plan

    Intro ![chart](data:image/png;base64,#{b64}) and more.

    ![][image1]

    See [the doc](https://example.com/doc).

    [image1]: <data:image/png;base64,#{b64}>
    """

    stripped = Drive.strip_images(markdown)

    refute stripped =~ "base64"
    refute stripped =~ "image1"
    assert stripped =~ "# Plan"
    assert stripped =~ "Intro  and more."
    assert stripped =~ "[the doc](https://example.com/doc)"
  end

  test "label_filters/1 defaults to Classification: Public / Internal or no label" do
    assert DrivePolicy.label_filters(%{}) == [
             %{
               "label" => "Classification",
               "values" => ["Public", "Internal"],
               "unlabeled" => true
             }
           ]

    assert DrivePolicy.label_filters(%{"include_labels" => []}) == []
  end

  test "Drive.parse_label_filters/2 resolves each label, its selection field and choices" do
    body = %{
      "labels" => [
        %{"id" => "x", "properties" => %{"title" => "Project"}, "fields" => []},
        %{
          "id" => "lbl",
          "properties" => %{"title" => "Classification"},
          "fields" => [
            %{"id" => "txt", "textOptions" => %{}},
            %{
              "id" => "fld",
              "selectionOptions" => %{
                "choices" => [
                  %{"id" => "c-pub", "properties" => %{"displayName" => "Public"}},
                  %{"id" => "c-int", "properties" => %{"displayName" => "internal"}},
                  %{"id" => "c-conf", "properties" => %{"displayName" => "Confidential"}}
                ]
              }
            }
          ]
        }
      ]
    }

    filter = fn label, values, unlabeled ->
      %{"label" => label, "values" => values, "unlabeled" => unlabeled}
    end

    assert {:ok, [cls, project]} =
             Drive.parse_label_filters(body, [
               filter.("classification", ~w(Public Internal), true),
               filter.("Project", [], true)
             ])

    assert %{label_id: "lbl", field_id: "fld", unlabeled: true, names: ["Public", "internal"]} =
             cls

    assert cls.allowed == MapSet.new(["c-pub", "c-int"])
    assert %{label_id: "x", field_id: nil, unlabeled: true} = project
    assert project.allowed == MapSet.new()

    assert {:error, {:label_not_found, "Team"}} =
             Drive.parse_label_filters(body, [filter.("Team", ["Cloud"], false)])

    assert {:error, {:label_choices_not_found, "Classification", ["Secret"]}} =
             Drive.parse_label_filters(body, [filter.("Classification", ~w(Public Secret), true)])

    assert {:error, {:label_without_choices, "Project"}} =
             Drive.parse_label_filters(body, [filter.("Project", ["A"], false)])
  end
end
