defmodule AvelineWeb.Api.DocKindTest do
  @moduledoc """
  The API surface for `kind`: create accepts "doc"/"notebook", rejects
  anything else with the canonical envelope, and both summary/full views
  echo the kind back.
  """
  use AvelineWeb.ConnCase, async: false

  import Aveline.Fixtures

  setup %{conn: conn} do
    user = user_fixture()
    ws = workspace_fixture(user)
    {_t, plaintext} = token_fixture(user)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{plaintext}")
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")

    {:ok, conn: conn, user: user, ws: ws}
  end

  test "create defaults kind to doc and echoes it on get", %{conn: conn, ws: ws} do
    conn
    |> post(~p"/api/workspaces/#{ws.slug}/docs", %{"title" => "Plain doc"})
    |> json_response(200)

    body =
      conn
      |> get(~p"/api/workspaces/#{ws.slug}/docs/plain-doc")
      |> json_response(200)

    assert body["doc"]["kind"] == "doc"
  end

  test "create with kind: notebook renders as a notebook", %{conn: conn, ws: ws} do
    create =
      conn
      |> post(~p"/api/workspaces/#{ws.slug}/docs", %{
        "title" => "Analysis notebook",
        "kind" => "notebook",
        "blocks" => [%{"type" => "paragraph", "content" => [%{"text" => "hi"}]}]
      })
      |> json_response(200)

    assert create["ok"] == true

    body =
      conn
      |> get(~p"/api/workspaces/#{ws.slug}/docs/analysis-notebook")
      |> json_response(200)

    assert body["doc"]["kind"] == "notebook"
    assert length(body["doc"]["blocks"]) == 1
  end

  test "create rejects an unknown kind with an envelope error", %{conn: conn, ws: ws} do
    body =
      conn
      |> post(~p"/api/workspaces/#{ws.slug}/docs", %{
        "title" => "Weird doc",
        "kind" => "spreadsheet"
      })
      |> json_response(422)

    assert body["ok"] == false
    assert body["error"]["message"] =~ "kind"
  end

  test "list_current includes notebooks in the index summary", %{conn: conn, ws: ws} do
    conn
    |> post(~p"/api/workspaces/#{ws.slug}/docs", %{"title" => "NB one", "kind" => "notebook"})
    |> json_response(200)

    body =
      conn
      |> get(~p"/api/workspaces/#{ws.slug}/docs")
      |> json_response(200)

    nb = Enum.find(body["docs"], &(&1["slug"] == "nb-one"))
    assert nb["kind"] == "notebook"
  end
end
