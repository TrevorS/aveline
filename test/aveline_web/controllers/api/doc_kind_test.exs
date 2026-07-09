defmodule AvelineWeb.Api.DocKindTest do
  @moduledoc """
  docs.kind over the API: create accepts "doc" | "notebook" (default
  "doc"), rejects anything else, and both list + show echo the kind.
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

  test "create + show round-trip for both kinds", %{conn: conn, ws: ws} do
    for kind <- ["doc", "notebook"] do
      create_body =
        conn
        |> post(~p"/api/workspaces/#{ws.slug}/docs", %{
          "title" => "A #{kind}",
          "slug" => "a-#{kind}",
          "blocks" => [%{"type" => "paragraph", "content" => [%{"text" => "Hi"}]}],
          "kind" => kind
        })
        |> json_response(200)

      assert create_body["ok"] == true

      show_body =
        conn
        |> get(~p"/api/workspaces/#{ws.slug}/docs/a-#{kind}")
        |> json_response(200)

      assert show_body["doc"]["kind"] == kind
    end

    index_body =
      conn |> get(~p"/api/workspaces/#{ws.slug}/docs") |> json_response(200)

    kinds = Map.new(index_body["docs"], &{&1["slug"], &1["kind"]})
    assert kinds["a-doc"] == "doc"
    assert kinds["a-notebook"] == "notebook"
  end

  test "kind defaults to doc when omitted", %{conn: conn, ws: ws} do
    conn
    |> post(~p"/api/workspaces/#{ws.slug}/docs", %{
      "title" => "Plain",
      "blocks" => []
    })
    |> json_response(200)

    show_body =
      conn |> get(~p"/api/workspaces/#{ws.slug}/docs/plain") |> json_response(200)

    assert show_body["doc"]["kind"] == "doc"
  end

  test "an unknown kind is rejected with the standard envelope", %{conn: conn, ws: ws} do
    body =
      conn
      |> post(~p"/api/workspaces/#{ws.slug}/docs", %{
        "title" => "Ghost",
        "blocks" => [],
        "kind" => "spreadsheet"
      })
      |> json_response(422)

    assert body["ok"] == false
    assert body["error"]["code"] == "validation_failed"
    assert body["error"]["message"] =~ "notebook"
  end

  test "a kind flip through apply_ops is rejected, not silently dropped", %{conn: conn, ws: ws} do
    conn
    |> post(~p"/api/workspaces/#{ws.slug}/docs", %{
      "title" => "Stays a notebook",
      "slug" => "stays-a-notebook",
      "blocks" => [],
      "kind" => "notebook"
    })
    |> json_response(200)

    body =
      conn
      |> patch(~p"/api/workspaces/#{ws.slug}/docs/stays-a-notebook", %{
        "intent" => "attempt kind flip",
        "kind" => "doc",
        "operations" => [
          %{
            "op" => "append_block",
            "block" => %{"type" => "paragraph", "content" => [%{"text" => "More"}]}
          }
        ]
      })
      |> json_response(422)

    assert body["ok"] == false
    assert body["error"]["code"] == "validation_failed"
    assert body["error"]["message"] =~ "immutable"

    # The rejected PATCH shipped nothing — still v1, still a notebook.
    show_body =
      conn
      |> get(~p"/api/workspaces/#{ws.slug}/docs/stays-a-notebook")
      |> json_response(200)

    assert show_body["doc"]["version_number"] == 1
    assert show_body["doc"]["kind"] == "notebook"
  end
end
