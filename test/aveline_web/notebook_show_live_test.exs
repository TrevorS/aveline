defmodule AvelineWeb.NotebookShowLiveTest do
  use AvelineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Aveline.Docs
  alias Aveline.Fixtures

  setup %{conn: conn} do
    owner = Fixtures.user_fixture()
    ws = Fixtures.workspace_fixture(owner)

    {:ok, nb} =
      Docs.create_doc(%{
        workspace_id: ws.id,
        owner_id: owner.id,
        actor_user_id: owner.id,
        actor_type: "agent",
        title: "Churn analysis",
        slug: "churn-analysis",
        blocks: [%{"type" => "paragraph", "content" => [%{"text" => "Findings"}]}],
        kind: "notebook"
      })

    conn = conn |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_session(:user_id, owner.id)
    %{conn: conn, ws: ws, owner: owner, nb: nb}
  end

  test "a notebook renders at /nb/ with the notebook badge", %{conn: conn, ws: ws} do
    {:ok, lv, html} = live(conn, "/w/#{ws.slug}/nb/churn-analysis")

    assert html =~ "Churn analysis"
    assert html =~ "Findings"
    assert has_element?(lv, ".article-title-row .chip", "notebook")
  end

  test "the same notebook also resolves at /d/", %{conn: conn, ws: ws} do
    {:ok, lv, html} = live(conn, "/w/#{ws.slug}/d/churn-analysis")

    assert html =~ "Churn analysis"
    assert has_element?(lv, ".article-title-row .chip", "notebook")
  end

  test "a plain doc shows no notebook badge", %{conn: conn, ws: ws, owner: owner} do
    Fixtures.doc_fixture(ws, owner, slug: "plain", title: "Plain doc")

    {:ok, lv, html} = live(conn, "/w/#{ws.slug}/d/plain")

    assert html =~ "Plain doc"
    refute has_element?(lv, ".article-title-row .chip", "notebook")
  end

  describe "code cells" do
    setup %{ws: ws, owner: owner} do
      original = Application.fetch_env(:aveline, :deploy_mode)

      on_exit(fn ->
        case original do
          {:ok, value} -> Application.put_env(:aveline, :deploy_mode, value)
          :error -> Application.delete_env(:aveline, :deploy_mode)
        end
      end)

      {:ok, nb} =
        Docs.create_doc(%{
          workspace_id: ws.id,
          owner_id: owner.id,
          actor_user_id: owner.id,
          actor_type: "agent",
          title: "Code notebook",
          slug: "code-notebook",
          kind: "notebook",
          blocks: [%{"type" => "code", "language" => "elixir", "content" => "1 + 1"}]
        })

      %{code_nb: nb}
    end

    test "outside local mode: source + quiet disabled note, no run button", %{conn: conn, ws: ws} do
      Application.put_env(:aveline, :deploy_mode, "cloud")

      {:ok, lv, html} = live(conn, "/w/#{ws.slug}/nb/code-notebook")

      assert html =~ "1 + 1"
      assert has_element?(lv, ".blk-code-cell .cell-exec-disabled", "execution disabled")
      assert has_element?(lv, ".blk-code-cell .frame-badge-never")
      refute has_element?(lv, ".blk-code-cell .frame-run-btn")
    end

    test "in local mode: running renders stdout and result panes", %{conn: conn, ws: ws, code_nb: nb, owner: owner} do
      Application.put_env(:aveline, :deploy_mode, "local")
      [code] = nb.blocks

      {:ok, _} =
        Docs.apply_ops(
          nb,
          [
            %{
              "op" => "modify_block",
              "id" => code["id"],
              "patch" => %{"content" => ~s|IO.puts("hi there")\n40 + 2|}
            }
          ],
          %{actor_user_id: owner.id, actor_type: "agent"},
          intent: "print something"
        )

      {:ok, lv, _html} = live(conn, "/w/#{ws.slug}/nb/code-notebook")
      refute has_element?(lv, ".cell-exec-disabled")

      lv
      |> element(".frame-run-btn")
      |> render_click()

      html = render_async(lv, 15_000)
      assert html =~ "hi there"
      assert html =~ "42"
      assert has_element?(lv, ".cell-stdout")
      assert has_element?(lv, ".cell-result")
      refute has_element?(lv, ".frame-badge-never")
    end
  end
end
