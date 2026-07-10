defmodule Aveline.CellRunsTest do
  @moduledoc """
  Frame-cell write path (notebook gating, inline-query catalog creation)
  and run-capture (cell_runs, derived staleness) — the catalog-backed
  redesign of NB2. Runs execute pure DERIVED queries entirely in the
  sandboxed engine, so no external data source is needed.
  """
  use Aveline.DataCase, async: false

  alias Aveline.DataSources.Cache
  alias Aveline.DataSources.Queries
  alias Aveline.Docs
  alias Aveline.Fixtures
  alias Aveline.Repo
  alias Aveline.Runs
  alias Aveline.Runs.CellRun

  setup do
    Cache.flush()
    user = Fixtures.user_fixture()
    ws = Fixtures.workspace_fixture(user)
    %{user: user, ws: ws}
  end

  defp frame_inline(name, sql), do: %{"type" => "frame", "name" => name, "query" => sql}
  defp frame_ref(name, ref), do: %{"type" => "frame", "name" => name, "query_ref" => ref}

  defp notebook(ws, user, blocks) do
    Docs.create_doc(%{
      workspace_id: ws.id,
      owner_id: user.id,
      actor_user_id: user.id,
      actor_type: "agent",
      kind: "notebook",
      title: "Notebook #{Fixtures.unique_int()}",
      blocks: blocks
    })
  end

  describe "notebook gating" do
    test "a frame cell is rejected in a kind=doc doc", %{ws: ws, user: user} do
      assert {:error, :frame_requires_notebook, msg} =
               Docs.create_doc(%{
                 workspace_id: ws.id,
                 owner_id: user.id,
                 actor_user_id: user.id,
                 actor_type: "agent",
                 kind: "doc",
                 title: "Plain doc",
                 blocks: [frame_inline("ones", "select 1 as one")]
               })

      assert msg =~ "notebook"
    end

    test "a frame cell is accepted in a notebook", %{ws: ws, user: user} do
      assert {:ok, nb} = notebook(ws, user, [frame_inline("ones", "select 1 as one")])
      assert [%{"type" => "frame"}] = nb.blocks
    end
  end

  describe "inline query creates a catalog query" do
    test "creates a derived query named after the cell and rewrites to query_ref", %{
      ws: ws,
      user: user
    } do
      {:ok, nb} = notebook(ws, user, [frame_inline("ones", "select 1 as one")])

      # The block now carries a query_ref, not the inline SQL.
      assert [%{"query_ref" => "ones"} = block] = nb.blocks
      refute Map.has_key?(block, "query")
      refute Map.has_key?(block, "source")

      # A matching catalog query exists.
      assert %{kind: "derived", sql: "select 1 as one"} =
               Queries.get_current_by_name(ws.id, "ones")
    end

    test "a name collision gets a deterministic suffix", %{ws: ws, user: user} do
      # Pre-occupy the name with a derived query.
      Fixtures.query_fixture(ws, user, "ones", "select 9 as nine")

      {:ok, nb} = notebook(ws, user, [frame_inline("ones", "select 1 as one")])

      assert [%{"query_ref" => "ones_2"}] = nb.blocks
      assert %{sql: "select 1 as one"} = Queries.get_current_by_name(ws.id, "ones_2")
      # The original is untouched.
      assert %{sql: "select 9 as nine"} = Queries.get_current_by_name(ws.id, "ones")
    end
  end

  describe "query_ref form" do
    test "verifies the referenced query exists", %{ws: ws, user: user} do
      Fixtures.query_fixture(ws, user, "existing", "select 1 as one")
      assert {:ok, nb} = notebook(ws, user, [frame_ref("cell", "existing")])
      assert [%{"query_ref" => "existing"}] = nb.blocks
    end

    test "rejects a missing catalog query", %{ws: ws, user: user} do
      assert {:error, :query_not_found, msg} = notebook(ws, user, [frame_ref("cell", "nope")])
      assert msg =~ "nope"
    end
  end

  describe "run_cell" do
    test "writes a cell_run and never touches the doc's stored blocks", %{ws: ws, user: user} do
      {:ok, nb} = notebook(ws, user, [frame_inline("ones", "select 1 as one")])
      [%{"id" => block_id} = original_block] = nb.blocks

      assert {:ok, run} =
               Runs.run_cell(nb, block_id, %{user_id: user.id, actor_type: "agent"})

      assert run.status == "ok"
      assert run.query_ref == "ones"
      assert run.outputs["columns"] == ["one"]
      assert run.outputs["rows"] == [[1]]
      assert run.truncated == false
      assert run.block_id == block_id
      assert run.doc_version_id == nb.id

      # Exactly one cell_run row.
      assert Repo.aggregate(CellRun, :count) == 1

      # The doc version's stored blocks are unchanged — no outputs leaked
      # into the version row, and no new version was made.
      reloaded = Docs.get_current_by_base(nb.base_doc_id)
      assert reloaded.version_number == 1
      assert reloaded.blocks == [original_block]
      refute Enum.any?(reloaded.blocks, &Map.has_key?(&1, "outputs"))
      refute Enum.any?(reloaded.blocks, &Map.has_key?(&1, "run"))
    end

    test "records an error run (query gone) without failing the read", %{ws: ws, user: user} do
      {:ok, nb} = notebook(ws, user, [frame_inline("ones", "select 1 as one")])
      [%{"id" => block_id}] = nb.blocks

      # Delete the query out from under the cell.
      q = Queries.get_current_by_name(ws.id, "ones")
      {:ok, _} = Queries.delete(q, user.id)

      assert {:ok, run} =
               Runs.run_cell(nb, block_id, %{user_id: user.id, actor_type: "agent"})

      assert run.status == "error"
      assert run.error_text =~ "not found"
      assert run.outputs == %{}

      # A notebook read still succeeds and shows the captured error.
      annotated = Runs.annotate(Docs.get_current_by_base(nb.base_doc_id))
      assert [%{"run" => %{"status" => "error"}}] = annotated.blocks
    end

    test "a non-frame / unknown block id is not_found", %{ws: ws, user: user} do
      {:ok, nb} = notebook(ws, user, [frame_inline("ones", "select 1 as one")])

      assert {:error, :not_found} =
               Runs.run_cell(nb, "b_doesnotexist", %{user_id: user.id, actor_type: "agent"})
    end
  end

  describe "staleness (derived, never stored)" do
    test "fresh right after a run, stale after the upstream query changes", %{ws: ws, user: user} do
      {:ok, nb} = notebook(ws, user, [frame_inline("ones", "select 1 as one")])
      [%{"id" => block_id}] = nb.blocks

      {:ok, _run} = Runs.run_cell(nb, block_id, %{user_id: user.id, actor_type: "agent"})

      latest = Runs.latest_per_cell(nb.base_doc_id)
      assert Runs.staleness(nb, latest) == %{block_id => :fresh}

      # Edit the referenced query — a new version moves the fingerprint.
      q = Queries.get_current_by_name(ws.id, "ones")
      {:ok, _} = Queries.edit(q, %{sql: "select 2 as two"}, user.id)

      # Same doc/blocks, recomputed staleness at read time.
      assert Runs.staleness(nb, latest) == %{block_id => :stale}
    end

    test "editing a query two hops upstream renders a chained cell stale", %{ws: ws, user: user} do
      # a → b → cell: the cell references derived `b`, and `b` is built on
      # derived `a`. Editing `a` must move the cell's fingerprint even
      # though the cell doesn't reference `a` directly.
      Fixtures.query_fixture(ws, user, "a", "select 1 as n")
      Fixtures.query_fixture(ws, user, "b", "select n from a")
      {:ok, nb} = notebook(ws, user, [frame_ref("cell", "b")])
      [%{"id" => block_id}] = nb.blocks

      {:ok, _run} = Runs.run_cell(nb, block_id, %{user_id: user.id, actor_type: "agent"})

      latest = Runs.latest_per_cell(nb.base_doc_id)
      assert Runs.staleness(nb, latest) == %{block_id => :fresh}

      # Edit the two-hops-upstream query; the cell should now read stale.
      a = Queries.get_current_by_name(ws.id, "a")
      {:ok, _} = Queries.edit(a, %{sql: "select 2 as n"}, user.id)

      assert Runs.staleness(nb, latest) == %{block_id => :stale}
    end

    test "never_run before any run", %{ws: ws, user: user} do
      {:ok, nb} = notebook(ws, user, [frame_inline("ones", "select 1 as one")])
      [%{"id" => block_id}] = nb.blocks

      assert Runs.staleness(nb, Runs.latest_per_cell(nb.base_doc_id)) == %{block_id => :never_run}
    end
  end

  describe "annotate" do
    test "is a no-op for non-notebook docs", %{ws: ws, user: user} do
      doc = Fixtures.doc_fixture(ws, user, blocks: [%{"type" => "paragraph", "content" => [%{"text" => "hi"}]}])
      assert Runs.annotate(doc) == doc
    end

    test "attaches latest run + staleness onto frame cells", %{ws: ws, user: user} do
      {:ok, nb} = notebook(ws, user, [frame_inline("ones", "select 1 as one")])
      [%{"id" => block_id}] = nb.blocks
      {:ok, _} = Runs.run_cell(nb, block_id, %{user_id: user.id, actor_type: "agent"})

      annotated = Runs.annotate(Docs.get_current_by_base(nb.base_doc_id))
      assert [%{"run" => run, "stale" => "fresh", "query_sql" => sql}] = annotated.blocks
      assert run["status"] == "ok"
      assert run["outputs"]["columns"] == ["one"]
      # the frame's SQL is echoed from its catalog query so the renderer can
      # show a "sql" tab, without the block ever storing it.
      assert sql =~ "select 1"
    end
  end
end
