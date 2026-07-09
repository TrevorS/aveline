defmodule AvelineWeb.FrameCellLiveTest do
  @moduledoc """
  Frame cells in DocShowLive: rendered states (never run / captured
  output / stale badge), the run button, and in-place updates from
  :cell_run_* broadcasts — rendering never executes anything.
  """
  use AvelineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Aveline.DataSources
  alias Aveline.Docs
  alias Aveline.Fixtures
  alias Aveline.Runs

  defp self_template do
    "postgres://#{System.get_env("PGUSER") || "postgres"}:<password>@#{System.get_env("PGHOST") || "localhost"}/aveline_test#{System.get_env("MIX_TEST_PARTITION")}"
  end

  defp self_password, do: System.get_env("PGPASSWORD") || "postgres"

  setup %{conn: conn} do
    Aveline.DataSources.Cache.flush()
    owner = Fixtures.user_fixture()
    ws = Fixtures.workspace_fixture(owner)
    {:ok, _ds} = DataSources.create(ws.id, "self", self_template(), self_password(), owner.id)

    {:ok, nb} =
      Docs.create_doc(%{
        workspace_id: ws.id,
        owner_id: owner.id,
        actor_user_id: owner.id,
        actor_type: "agent",
        title: "Orders notebook",
        slug: "orders-notebook",
        kind: "notebook",
        blocks: [
          %{
            "type" => "frame",
            "name" => "orders",
            "input" => %{
              "source" => "self",
              "query" => "select * from (values ('emea', 50), ('amer', 250)) as t(region, amount)"
            }
          }
        ]
      })

    conn = conn |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_session(:user_id, owner.id)
    %{conn: conn, ws: ws, owner: owner, nb: nb}
  end

  test "an unrun cell shows name, not-run badge, and a run button", %{conn: conn, ws: ws} do
    {:ok, lv, html} = live(conn, "/w/#{ws.slug}/nb/orders-notebook")

    assert html =~ "orders"
    assert has_element?(lv, ".frame-badge-never")
    assert has_element?(lv, ".frame-run-btn")
    assert has_element?(lv, ".frame-empty")
  end

  test "clicking run captures output and renders it in place", %{conn: conn, ws: ws, nb: nb} do
    {:ok, lv, _html} = live(conn, "/w/#{ws.slug}/nb/orders-notebook")
    [frame] = nb.blocks

    lv
    |> element(".frame-run-btn")
    |> render_click()

    # The run executes off-process (start_async); its :cell_run_finished
    # broadcast lands before the async completes, so awaiting the async
    # renders the captured output.
    html = render_async(lv, 15_000)
    assert html =~ "amer"
    assert html =~ "250"
    # Fresh output: no staleness badges, provenance caption present.
    refute has_element?(lv, ".frame-badge-stale")
    refute has_element?(lv, ".frame-badge-never")
    assert html =~ "run v1"

    # The run really landed in cell_runs, not in the doc.
    assert %{} = runs = Runs.latest_per_cell(nb.base_doc_id)
    assert runs[frame["id"]].status == "ok"
    reloaded = Docs.get_current_by_base(nb.base_doc_id)
    refute Enum.any?(reloaded.blocks, &Map.has_key?(&1, "result"))
  end

  test "a terminal broadcast with run: nil clears the running state without dropping the capture",
       %{conn: conn, ws: ws, nb: nb, owner: owner} do
    [frame] = nb.blocks
    {:ok, _run} = Runs.run_cell(nb, frame["id"], %{user_id: owner.id, type: "agent"})

    {:ok, lv, _html} = live(conn, "/w/#{ws.slug}/nb/orders-notebook")

    Aveline.Broadcasts.publish_doc_event(:cell_run_started, %{
      base_doc_id: nb.base_doc_id,
      workspace_id: nb.workspace_id,
      block_id: frame["id"]
    })

    assert render(lv) =~ "running…"

    # A run that never records (runner died, insert failed) still ends
    # with a terminal event — the viewer must not stay on "running…",
    # and the previously captured output stays on screen.
    Aveline.Broadcasts.publish_doc_event(:cell_run_finished, %{
      base_doc_id: nb.base_doc_id,
      workspace_id: nb.workspace_id,
      block_id: frame["id"],
      run: nil
    })

    html = render(lv)
    refute html =~ "running…"
    assert html =~ "emea"
  end

  test "a broadcast run from elsewhere updates the open view", %{conn: conn, ws: ws, nb: nb, owner: owner} do
    {:ok, lv, _html} = live(conn, "/w/#{ws.slug}/nb/orders-notebook")
    [frame] = nb.blocks

    # Another actor (API/CLI) runs the cell.
    {:ok, _run} = Runs.run_cell(nb, frame["id"], %{user_id: owner.id, type: "agent"})

    html = render(lv)
    assert html =~ "emea"
    refute has_element?(lv, ".frame-badge-never")
  end

  test "editing the cell renders the captured output stale", %{conn: conn, ws: ws, nb: nb, owner: owner} do
    [frame] = nb.blocks
    {:ok, _run} = Runs.run_cell(nb, frame["id"], %{user_id: owner.id, type: "agent"})

    {:ok, lv, _html} = live(conn, "/w/#{ws.slug}/nb/orders-notebook")
    refute has_element?(lv, ".frame-badge-stale")

    {:ok, _v2} =
      Docs.apply_ops(
        nb,
        [
          %{
            "op" => "modify_block",
            "id" => frame["id"],
            "patch" => %{
              "input" => %{"source" => "self", "query" => "select 1 as amount"}
            }
          }
        ],
        %{actor_user_id: owner.id, actor_type: "agent"},
        intent: "change the query"
      )

    # The :doc_updated broadcast re-derives staleness in place.
    render(lv)
    assert has_element?(lv, ".frame-badge-stale")
  end
end
