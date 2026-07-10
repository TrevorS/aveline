defmodule AvelineWeb.Api.FrameCellsApiTest do
  @moduledoc """
  The notebook frame-cell API: run a cell (capturing a cell_run), list a
  cell's run history, and the refusal on non-notebook docs.
  """
  use AvelineWeb.ConnCase, async: false

  import Aveline.Fixtures

  alias Aveline.DataSources.Cache

  setup %{conn: conn} do
    Cache.flush()
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

  defp create_notebook(conn, ws) do
    conn
    |> post(~p"/api/workspaces/#{ws.slug}/docs", %{
      "title" => "Analysis",
      "kind" => "notebook",
      "blocks" => [%{"type" => "frame", "name" => "ones", "query" => "select 1 as one"}]
    })
    |> json_response(200)
  end

  defp frame_block_id(conn, ws, slug) do
    body =
      conn
      |> get(~p"/api/workspaces/#{ws.slug}/docs/#{slug}")
      |> json_response(200)

    block = Enum.find(body["doc"]["blocks"], &(&1["type"] == "frame"))
    {block["id"], body}
  end

  test "run a cell then list its run", %{conn: conn, ws: ws} do
    create = create_notebook(conn, ws)
    assert create["ok"] == true
    {block_id, _body} = frame_block_id(conn, ws, "analysis")

    run =
      conn
      |> post(~p"/api/workspaces/#{ws.slug}/docs/analysis/cells/#{block_id}/run")
      |> json_response(200)

    assert run["ok"] == true
    assert run["cell_run"]["status"] == "ok"
    assert run["cell_run"]["query_ref"] == "ones"
    assert run["cell_run"]["outputs"]["columns"] == ["one"]

    list =
      conn
      |> get(~p"/api/workspaces/#{ws.slug}/docs/analysis/cells/#{block_id}/runs")
      |> json_response(200)

    assert length(list["cell_runs"]) == 1
    assert hd(list["cell_runs"])["status"] == "ok"
  end

  test "a read echoes the latest run + staleness on the frame cell", %{conn: conn, ws: ws} do
    create_notebook(conn, ws)
    {block_id, _} = frame_block_id(conn, ws, "analysis")

    conn
    |> post(~p"/api/workspaces/#{ws.slug}/docs/analysis/cells/#{block_id}/run")
    |> json_response(200)

    {_id, body} = frame_block_id(conn, ws, "analysis")
    block = Enum.find(body["doc"]["blocks"], &(&1["type"] == "frame"))
    assert block["stale"] == "fresh"
    assert block["run"]["status"] == "ok"
  end

  test "running a cell on a non-notebook doc is refused", %{conn: conn, ws: ws} do
    conn
    |> post(~p"/api/workspaces/#{ws.slug}/docs", %{
      "title" => "Plain doc",
      "blocks" => [%{"type" => "paragraph", "content" => [%{"text" => "hi"}]}]
    })
    |> json_response(200)

    body =
      conn
      |> post(~p"/api/workspaces/#{ws.slug}/docs/plain-doc/cells/b_whatever/run")
      |> json_response(422)

    assert body["ok"] == false
    assert body["error"]["code"] == "not_a_notebook"
  end

  test "running an unknown cell id is a not_found", %{conn: conn, ws: ws} do
    create_notebook(conn, ws)

    body =
      conn
      |> post(~p"/api/workspaces/#{ws.slug}/docs/analysis/cells/b_missing/run")
      |> json_response(404)

    assert body["ok"] == false
  end

  describe "code cells" do
    setup do
      original = Application.get_env(:aveline, :deploy_mode)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:aveline, :deploy_mode)
          v -> Application.put_env(:aveline, :deploy_mode, v)
        end
      end)

      :ok
    end

    defp create_code_notebook(conn, ws) do
      conn
      |> post(~p"/api/workspaces/#{ws.slug}/docs", %{
        "title" => "Code NB",
        "kind" => "notebook",
        "blocks" => [%{"type" => "code", "language" => "elixir", "content" => "6 * 7"}]
      })
      |> json_response(200)

      body =
        conn
        |> get(~p"/api/workspaces/#{ws.slug}/docs/code-nb")
        |> json_response(200)

      block = Enum.find(body["doc"]["blocks"], &(&1["type"] == "code"))
      block["id"]
    end

    test "a run is refused with a structured error outside local mode", %{conn: conn, ws: ws} do
      Application.put_env(:aveline, :deploy_mode, "cloud")
      block_id = create_code_notebook(conn, ws)

      body =
        conn
        |> post(~p"/api/workspaces/#{ws.slug}/docs/code-nb/cells/#{block_id}/run")
        |> json_response(422)

      assert body["ok"] == false
      assert body["error"]["code"] == "execution_disabled"
    end

    test "runs and captures result + stdout in local mode", %{conn: conn, ws: ws} do
      Application.put_env(:aveline, :deploy_mode, "local")
      block_id = create_code_notebook(conn, ws)

      run =
        conn
        |> post(~p"/api/workspaces/#{ws.slug}/docs/code-nb/cells/#{block_id}/run")
        |> json_response(200)

      assert run["ok"] == true
      assert run["cell_run"]["status"] == "ok"
      assert run["cell_run"]["outputs"]["result"] == "42"
    end
  end
end
