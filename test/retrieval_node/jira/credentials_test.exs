defmodule RetrievalNode.Jira.CredentialsTest do
  use ExUnit.Case, async: false

  alias RetrievalNode.Jira.Credentials
  alias RetrievalNode.Secrets

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    prev = %{
      data_dir: Application.get_env(:retrieval_node, :data_dir),
      jira: Application.get_env(:retrieval_node, :jira)
    }

    Application.put_env(:retrieval_node, :data_dir, dir)
    Application.put_env(:retrieval_node, :jira, [])

    on_exit(fn ->
      Application.put_env(:retrieval_node, :data_dir, prev.data_dir)
      Application.put_env(:retrieval_node, :jira, prev.jira)
    end)
  end

  test "normalize_base_url keeps the site, or the scoped-token gateway prefix" do
    assert Credentials.normalize_base_url("acme.atlassian.net") ==
             {:ok, "https://acme.atlassian.net"}

    assert Credentials.normalize_base_url(" https://Acme.atlassian.net/browse/P-1 ") ==
             {:ok, "https://acme.atlassian.net"}

    assert Credentials.normalize_base_url("https://api.atlassian.com/ex/jira/c1d/rest/api/3") ==
             {:ok, "https://api.atlassian.com/ex/jira/c1d"}

    assert Credentials.normalize_base_url("http://localhost:8080/jira") ==
             {:ok, "http://localhost:8080"}

    assert Credentials.normalize_base_url("") == :error
    assert Credentials.normalize_base_url("ftp://acme") == :error
  end

  test "site_url is the stored site, else the base URL unless it is the gateway" do
    site = "https://acme.atlassian.net"
    gateway = "https://api.atlassian.com/ex/jira/c1d"

    assert Credentials.site_url(%{base_url: site}) == site
    assert Credentials.site_url(%{base_url: gateway}) == nil
    assert Credentials.site_url(%{base_url: gateway, site_url: site}) == site
  end

  test "stored credentials are used; a complete environment set overrides them" do
    assert Credentials.source() == nil
    assert Credentials.get() == {:error, :jira_not_configured}

    stored = %{base_url: "https://a.atlassian.net", email: "a@x.com", api_token: "s"}
    :ok = Credentials.store(stored)
    assert Credentials.get() == {:ok, Map.put(stored, :site_url, nil)}

    # A partial environment doesn't count.
    Application.put_env(:retrieval_node, :jira, api_token: "e")
    assert Credentials.source() == :secrets

    Application.put_env(:retrieval_node, :jira,
      base_url: "https://e.atlassian.net",
      email: "e@x.com",
      api_token: "e"
    )

    assert {:env, {:ok, %{api_token: "e"}}} = {Credentials.source(), Credentials.get()}

    Application.put_env(:retrieval_node, :jira, [])
    :ok = Credentials.forget()
    assert Secrets.get("jira_api_token") == nil
    assert Credentials.source() == nil
  end
end
