defmodule AvelineWeb.LiveUpdatesLiveTest do
  @moduledoc """
  NB5 — live updates on the open surfaces. The docs list and home page
  subscribe to the workspace docs topic and refresh in place on any doc
  write; a notebook viewer streams cell runs, so a second viewer watches
  a run land without a reload.
  """
  use AvelineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Aveline.DataSources.Cache
  alias Aveline.Fixtures

  setup %{conn: conn} do
    Cache.flush()
    owner = Fixtures.user_fixture()
    ws = Fixtures.workspace_fixture(owner)
    %{conn: login(conn, owner), ws: ws, owner: owner}
  end

  defp login(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  describe "docs list live updates" do
    test "a doc write elsewhere re-renders the list without a reload", %{
      conn: conn,
      ws: ws,
      owner: owner
    } do
      Fixtures.doc_fixture(ws, owner, slug: "already-here", title: "Already Here")

      {:ok, lv, html} = live(conn, "/w/#{ws.slug}/docs")
      assert html =~ "Already Here"
      refute html =~ "Streamed In"

      # A second actor ships a doc — publishing fans out to the workspace
      # docs topic, which the list LiveView is subscribed to.
      Fixtures.doc_fixture(ws, owner, slug: "streamed-in", title: "Streamed In")

      assert render(lv) =~ "Streamed In"
    end

    test "an edit to an existing doc restacks it live", %{conn: conn, ws: ws, owner: owner} do
      doc = Fixtures.doc_fixture(ws, owner, slug: "renamable", title: "Old Name")

      {:ok, lv, html} = live(conn, "/w/#{ws.slug}/docs")
      assert html =~ "Old Name"

      {:ok, _v2} =
        Aveline.Docs.apply_ops(
          doc,
          [],
          %{title: "New Name", actor_user_id: owner.id, actor_type: "human"},
          intent: "rename"
        )

      html = render(lv)
      assert html =~ "New Name"
      refute html =~ "Old Name"
    end
  end

  describe "home live updates" do
    test "recently-changed reflects a new version", %{conn: conn, ws: ws, owner: owner} do
      {:ok, lv, html} = live(conn, "/w/#{ws.slug}")
      refute html =~ "Fresh Off The Press"

      Fixtures.doc_fixture(ws, owner, slug: "fresh", title: "Fresh Off The Press")

      assert render(lv) =~ "Fresh Off The Press"
    end
  end

  describe "cell-run streaming to a second viewer" do
    test "running a cell in one viewer lands the output in another", %{
      conn: conn,
      ws: ws,
      owner: owner
    } do
      {:ok, nb} =
        Aveline.Docs.create_doc(%{
          workspace_id: ws.id,
          owner_id: owner.id,
          actor_user_id: owner.id,
          actor_type: "human",
          kind: "notebook",
          slug: "streaming-nb",
          title: "Streaming Notebook",
          blocks: [%{"type" => "frame", "name" => "ones", "query" => "select 1 as one"}]
        })

      path = "/w/#{ws.slug}/d/#{nb.slug}"

      # Two independent viewers of the same notebook.
      {:ok, runner, _} = live(conn, path)
      {:ok, watcher, watcher_html} = live(login(build_conn(), owner), path)

      # Neither has run the cell yet.
      refute watcher_html =~ "<td>1</td>"

      # The runner presses Run. The run executes and broadcasts a
      # cell_run_finished on the doc topic both viewers subscribe to.
      runner |> element("button.frame-run-btn") |> render_click()

      # The runner picks up its own broadcast and shows the output.
      assert render(runner) =~ "<td>1</td>"

      # And the second viewer sees it land without any reload.
      assert render(watcher) =~ "<td>1</td>"
    end
  end
end
