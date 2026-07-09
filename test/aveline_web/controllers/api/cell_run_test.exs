defmodule AvelineWeb.Api.CellRunTest do
  @moduledoc """
  The cell-run surface: POST .../cells/:block_id/run executes and echoes
  the recorded run; GET .../cells/:block_id/runs lists history; docs
  that aren't notebooks refuse with a machine-readable code.
  """
  use AvelineWeb.ConnCase, async: false

  import Aveline.Fixtures

  alias Aveline.DataSources

  defp self_template do
    "postgres://#{System.get_env("PGUSER") || "postgres"}:<password>@#{System.get_env("PGHOST") || "localhost"}/aveline_test#{System.get_env("MIX_TEST_PARTITION")}"
  end

  defp self_password, do: System.get_env("PGPASSWORD") || "postgres"

  setup %{conn: conn} do
    Aveline.DataSources.Cache.flush()
    user = user_fixture()
    ws = workspace_fixture(user)
    {:ok, _ds} = DataSources.create(ws.id, "self", self_template(), self_password(), user.id)
    {_t, plaintext} = token_fixture(user)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{plaintext}")
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")

    {:ok, conn: conn, user: user, ws: ws}
  end

  defp create_notebook(conn, ws) do
    conn
    |> post(~p"/api/workspaces/#{ws.slug}/docs", %{
      "title" => "Orders notebook",
      "slug" => "orders-notebook",
      "kind" => "notebook",
      "blocks" => [
        %{
          "type" => "frame",
          "name" => "orders",
          "input" => %{
            "source" => "self",
            "query" => "select * from (values ('emea', 50), ('amer', 250)) as t(region, amount)"
          },
          "ops" => [%{"op" => "sort", "by" => [%{"col" => "amount", "dir" => "desc"}]}]
        }
      ]
    })
    |> json_response(200)
  end

  defp frame_block_id(conn, ws, slug) do
    body = conn |> get(~p"/api/workspaces/#{ws.slug}/docs/#{slug}") |> json_response(200)
    body["doc"]["blocks"] |> Enum.find(&(&1["type"] == "frame")) |> Map.fetch!("id")
  end

  test "run + list runs round-trip", %{conn: conn, ws: ws} do
    assert %{"ok" => true} = create_notebook(conn, ws)
    block_id = frame_block_id(conn, ws, "orders-notebook")

    run_body =
      conn
      |> post(~p"/api/workspaces/#{ws.slug}/docs/orders-notebook/cells/#{block_id}/run", %{})
      |> json_response(200)

    assert run_body["ok"] == true
    run = run_body["run"]
    assert run["status"] == "ok"
    assert run["block_id"] == block_id
    assert run["doc_version_number"] == 1
    assert run["outputs"]["columns"] == ["region", "amount"]
    assert run["outputs"]["rows"] == [["amer", 250], ["emea", 50]]
    assert run["actor"]["type"] == "agent"
    assert is_integer(run["duration_ms"])

    # A second run appends; the list comes back newest first.
    conn
    |> post(~p"/api/workspaces/#{ws.slug}/docs/orders-notebook/cells/#{block_id}/run", %{})
    |> json_response(200)

    list_body =
      conn
      |> get(~p"/api/workspaces/#{ws.slug}/docs/orders-notebook/cells/#{block_id}/runs")
      |> json_response(200)

    assert list_body["ok"] == true
    assert length(list_body["runs"]) == 2
    assert [%{"status" => "ok"}, %{"status" => "ok"}] = list_body["runs"]

    limited =
      conn
      |> get(~p"/api/workspaces/#{ws.slug}/docs/orders-notebook/cells/#{block_id}/runs?limit=1")
      |> json_response(200)

    assert length(limited["runs"]) == 1
  end

  test "a broken query returns a recorded error run, not a 5xx", %{conn: conn, ws: ws} do
    conn
    |> post(~p"/api/workspaces/#{ws.slug}/docs", %{
      "title" => "Broken",
      "slug" => "broken",
      "kind" => "notebook",
      "blocks" => [
        %{
          "type" => "frame",
          "name" => "bad",
          "input" => %{"source" => "self", "query" => "select nope from nowhere"}
        }
      ]
    })
    |> json_response(200)

    block_id = frame_block_id(conn, ws, "broken")

    body =
      conn
      |> post(~p"/api/workspaces/#{ws.slug}/docs/broken/cells/#{block_id}/run", %{})
      |> json_response(200)

    assert body["ok"] == true
    assert body["run"]["status"] == "error"
    assert body["run"]["outputs"]["error"] =~ "nowhere"
  end

  test "a bogus actor is refused before anything executes", %{conn: conn, ws: ws} do
    create_notebook(conn, ws)
    block_id = frame_block_id(conn, ws, "orders-notebook")

    body =
      conn
      |> post(~p"/api/workspaces/#{ws.slug}/docs/orders-notebook/cells/#{block_id}/run", %{
        "actor" => "bogus"
      })
      |> json_response(422)

    assert body["ok"] == false
    assert body["error"]["code"] == "invalid_actor"

    # A refusal, not an error run — nothing was recorded.
    list_body =
      conn
      |> get(~p"/api/workspaces/#{ws.slug}/docs/orders-notebook/cells/#{block_id}/runs")
      |> json_response(200)

    assert list_body["runs"] == []
  end

  test "execution refuses on kind=doc with a clear code", %{conn: conn, ws: ws} do
    conn
    |> post(~p"/api/workspaces/#{ws.slug}/docs", %{
      "title" => "Plain doc",
      "slug" => "plain-doc",
      "blocks" => [%{"type" => "paragraph", "content" => [%{"text" => "hi"}]}]
    })
    |> json_response(200)

    body =
      conn
      |> post(~p"/api/workspaces/#{ws.slug}/docs/plain-doc/cells/b_anything/run", %{})
      |> json_response(422)

    assert body["ok"] == false
    assert body["error"]["code"] == "not_notebook"
    assert body["error"]["message"] =~ "notebook"
  end

  test "code cells refuse with execution_disabled outside local mode", %{conn: conn, ws: ws} do
    original = Application.fetch_env(:aveline, :deploy_mode)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:aveline, :deploy_mode, value)
        :error -> Application.delete_env(:aveline, :deploy_mode)
      end
    end)

    Application.put_env(:aveline, :deploy_mode, "cloud")

    conn
    |> post(~p"/api/workspaces/#{ws.slug}/docs", %{
      "title" => "Code notebook",
      "slug" => "code-notebook",
      "kind" => "notebook",
      "blocks" => [%{"type" => "code", "language" => "elixir", "content" => "1 + 1"}]
    })
    |> json_response(200)

    doc_body = conn |> get(~p"/api/workspaces/#{ws.slug}/docs/code-notebook") |> json_response(200)
    block_id = doc_body["doc"]["blocks"] |> Enum.find(&(&1["type"] == "code")) |> Map.fetch!("id")

    body =
      conn
      |> post(~p"/api/workspaces/#{ws.slug}/docs/code-notebook/cells/#{block_id}/run", %{})
      |> json_response(422)

    assert body["ok"] == false
    assert body["error"]["code"] == "execution_disabled"
    assert body["error"]["message"] =~ "DEPLOY_MODE=local"

    # A refusal, not an error run — nothing was recorded.
    list_body =
      conn
      |> get(~p"/api/workspaces/#{ws.slug}/docs/code-notebook/cells/#{block_id}/runs")
      |> json_response(200)

    assert list_body["runs"] == []

    # Flipping to local mode makes the same request execute.
    Application.put_env(:aveline, :deploy_mode, "local")

    run_body =
      conn
      |> post(~p"/api/workspaces/#{ws.slug}/docs/code-notebook/cells/#{block_id}/run", %{})
      |> json_response(200)

    assert run_body["run"]["status"] == "ok"
    assert run_body["run"]["outputs"]["result"] == "2"
  end

  test "unknown cells and docs 404", %{conn: conn, ws: ws} do
    create_notebook(conn, ws)

    body =
      conn
      |> post(~p"/api/workspaces/#{ws.slug}/docs/orders-notebook/cells/b_ghost/run", %{})
      |> json_response(404)

    assert body["error"]["code"] == "cell_not_found"

    body =
      conn
      |> post(~p"/api/workspaces/#{ws.slug}/docs/no-such-doc/cells/b_x/run", %{})
      |> json_response(404)

    assert body["error"]["code"] == "not_found"
  end
end
