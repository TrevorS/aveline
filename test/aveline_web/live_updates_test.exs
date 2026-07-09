defmodule AvelineWeb.LiveUpdatesTest do
  use AvelineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Aveline.Broadcasts
  alias Aveline.Docs
  alias Aveline.Fixtures

  setup %{conn: conn} do
    owner = Fixtures.user_fixture()
    ws = Fixtures.workspace_fixture(owner)

    conn = conn |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_session(:user_id, owner.id)
    %{conn: conn, ws: ws, owner: owner}
  end

  # Broadcast-triggered refetches are debounced, so the re-render is not
  # synchronous with the write — poll until the needle appears (or, with
  # present?: false, disappears).
  defp settled(lv, needle, opts \\ []) do
    present? = Keyword.get(opts, :present?, true)
    settled(lv, needle, present?, 40)
  end

  defp settled(lv, needle, present?, tries) do
    html = render(lv)

    cond do
      html =~ needle == present? ->
        html

      tries == 0 ->
        html

      true ->
        Process.sleep(25)
        settled(lv, needle, present?, tries - 1)
    end
  end

  describe "broadcast events" do
    test "version 1 publishes :doc_created, later versions :doc_updated", %{ws: ws, owner: owner} do
      Broadcasts.subscribe(Broadcasts.workspace_docs_topic(ws.id))

      doc = Fixtures.doc_fixture(ws, owner, slug: "born", title: "Born")
      assert_receive {:doc_created, %{slug: "born", version_number: 1}}

      {:ok, _} =
        Docs.apply_ops(
          doc,
          [],
          %{actor_user_id: owner.id, actor_type: "agent", title: "Reborn"},
          intent: "rename"
        )

      assert_receive {:doc_updated, %{slug: "born", version_number: 2}}
      refute_receive {:doc_created, _}
    end
  end

  describe "docs list" do
    test "a doc created elsewhere appears without refresh", %{conn: conn, ws: ws, owner: owner} do
      {:ok, lv, html} = live(conn, "/w/#{ws.slug}/docs")
      refute html =~ "Fresh from an agent"

      Fixtures.doc_fixture(ws, owner, slug: "fresh", title: "Fresh from an agent")

      assert settled(lv, "Fresh from an agent") =~ "Fresh from an agent"
    end

    test "edits, deletes, and restores re-render the list", %{conn: conn, ws: ws, owner: owner} do
      doc = Fixtures.doc_fixture(ws, owner, slug: "churn", title: "Original title")
      {:ok, lv, html} = live(conn, "/w/#{ws.slug}/docs")
      assert html =~ "Original title"

      {:ok, v2} =
        Docs.apply_ops(
          doc,
          [],
          %{actor_user_id: owner.id, actor_type: "agent", title: "Renamed title"},
          intent: "rename"
        )

      html = settled(lv, "Renamed title")
      assert html =~ "Renamed title"
      refute html =~ "Original title"

      {:ok, _} = Docs.soft_delete(v2, owner.id)
      refute settled(lv, "Renamed title", present?: false) =~ "Renamed title"

      {:ok, _} = Docs.restore(v2.base_doc_id, owner.id)
      assert settled(lv, "Renamed title") =~ "Renamed title"
    end

    test "a broadcast refresh keeps filter and grouping state", %{conn: conn, ws: ws, owner: owner} do
      Fixtures.doc_fixture(ws, owner, slug: "t-one", title: "Ticket one", tags: ["ticket", "status:todo"])
      Fixtures.doc_fixture(ws, owner, slug: "plain", title: "Plain doc")

      {:ok, lv, html} = live(conn, "/w/#{ws.slug}/docs?group=status&tag[]=ticket")
      assert html =~ "Ticket one"
      refute html =~ "Plain doc"

      Fixtures.doc_fixture(ws, owner, slug: "t-two", title: "Ticket two", tags: ["ticket", "status:todo"])

      html = settled(lv, "Ticket two")
      # New doc lands in its kanban section; the tag filter still applies.
      assert html =~ "Ticket two"
      assert html =~ "group-head-name"
      refute html =~ "Plain doc"
    end

    test "a burst of events coalesces into one queued refetch", %{conn: conn, ws: ws, owner: owner} do
      {:ok, lv, _html} = live(conn, "/w/#{ws.slug}/docs")

      for n <- 1..5 do
        Fixtures.doc_fixture(ws, owner, slug: "burst-#{n}", title: "Burst doc #{n}")
      end

      html = settled(lv, "Burst doc 5")
      for n <- 1..5, do: assert(html =~ "Burst doc #{n}")
    end
  end

  describe "home" do
    test "recently changed updates when a doc ships a version", %{conn: conn, ws: ws, owner: owner} do
      {:ok, lv, html} = live(conn, "/w/#{ws.slug}")
      refute html =~ "Fresh from an agent"

      doc = Fixtures.doc_fixture(ws, owner, slug: "fresh", title: "Fresh from an agent")
      assert settled(lv, "Fresh from an agent") =~ "Fresh from an agent"

      {:ok, _} =
        Docs.apply_ops(
          doc,
          [],
          %{actor_user_id: owner.id, actor_type: "agent", title: "Fresh, revised"},
          intent: "revise"
        )

      html = settled(lv, "Fresh, revised")
      assert html =~ "Fresh, revised"
      assert html =~ "v2"
    end
  end
end
