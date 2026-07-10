defmodule Aveline.CodeCellsTest do
  @moduledoc """
  Elixir code cells end-to-end through `Aveline.Runs`: the local-mode
  execution gate, run capture (result + stdout on the row), the derived
  staleness of a code cell over its own source, read-time annotation, and
  the `query/1` bridge reaching a captured run. `async: false` because
  these mutate the global `:deploy_mode` / `:runtime_query_fun` app env.
  """
  use Aveline.DataCase, async: false

  alias Aveline.Docs
  alias Aveline.Fixtures
  alias Aveline.Repo
  alias Aveline.Runs
  alias Aveline.Runs.CellRun

  setup do
    original = Application.get_env(:aveline, :deploy_mode)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:aveline, :deploy_mode)
        v -> Application.put_env(:aveline, :deploy_mode, v)
      end

      Application.delete_env(:aveline, :runtime_query_fun)
    end)

    user = Fixtures.user_fixture()
    ws = Fixtures.workspace_fixture(user)
    %{user: user, ws: ws}
  end

  defp code_cell(source, opts \\ []) do
    base = %{"type" => "code", "language" => "elixir", "content" => source}
    if name = opts[:name], do: Map.put(base, "name", name), else: base
  end

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

  defp actor(user), do: %{user_id: user.id, actor_type: "agent"}
  defp local!, do: Application.put_env(:aveline, :deploy_mode, "local")
  defp cloud!, do: Application.put_env(:aveline, :deploy_mode, "cloud")

  describe "execution gate" do
    test "a code cell refuses to run outside local mode", %{ws: ws, user: user} do
      cloud!()
      {:ok, nb} = notebook(ws, user, [code_cell("1 + 1")])
      [%{"id" => block_id}] = nb.blocks

      assert {:error, :execution_disabled, msg} = Runs.run_cell(nb, block_id, actor(user))
      assert msg =~ "local"

      # Nothing captured — a refused run is not a run.
      assert Repo.aggregate(CellRun, :count) == 0
    end

    test "a code cell runs in local mode and captures result + stdout", %{ws: ws, user: user} do
      local!()
      {:ok, nb} = notebook(ws, user, [code_cell(~s|IO.puts("hi")\n6 * 7|)])
      [%{"id" => block_id} = original] = nb.blocks

      assert {:ok, run} = Runs.run_cell(nb, block_id, actor(user))
      assert run.status == "ok"
      assert run.query_ref == nil
      assert run.outputs["result"] == "42"
      assert run.outputs["stdout"] == "hi\n"
      assert run.block_id == block_id
      assert run.doc_version_id == nb.id

      assert Repo.aggregate(CellRun, :count) == 1

      # The stored doc version is untouched — no outputs leaked into blocks.
      reloaded = Docs.get_current_by_base(nb.base_doc_id)
      assert reloaded.version_number == 1
      assert reloaded.blocks == [original]
    end

    test "a raising cell is captured as an error run, not a failure", %{ws: ws, user: user} do
      local!()
      {:ok, nb} = notebook(ws, user, [code_cell(~s|raise "boom"|)])
      [%{"id" => block_id}] = nb.blocks

      assert {:ok, run} = Runs.run_cell(nb, block_id, actor(user))
      assert run.status == "error"
      assert run.error_text =~ "boom"
      refute Map.has_key?(run.outputs, "result")
    end

    test "a non-elixir code block is not a runnable cell", %{ws: ws, user: user} do
      local!()
      {:ok, nb} = notebook(ws, user, [%{"type" => "code", "language" => "sql", "content" => "select 1"}])
      [%{"id" => block_id}] = nb.blocks

      assert {:error, :not_found} = Runs.run_cell(nb, block_id, actor(user))
    end
  end

  describe "annotate" do
    test "marks elixir code cells with run + staleness + exec flag", %{ws: ws, user: user} do
      local!()
      {:ok, nb} = notebook(ws, user, [code_cell("1 + 1", name: "adder")])
      [%{"id" => block_id}] = nb.blocks
      {:ok, _} = Runs.run_cell(nb, block_id, actor(user))

      annotated = Runs.annotate(Docs.get_current_by_base(nb.base_doc_id))
      assert [%{"cell" => true, "exec_enabled" => true, "run" => run, "stale" => "fresh"}] = annotated.blocks
      assert run["status"] == "ok"
      assert run["outputs"]["result"] == "2"
    end

    test "echoes exec_enabled=false in a non-local deployment", %{ws: ws, user: user} do
      cloud!()
      {:ok, nb} = notebook(ws, user, [code_cell("1 + 1")])

      annotated = Runs.annotate(Docs.get_current_by_base(nb.base_doc_id))
      assert [%{"cell" => true, "exec_enabled" => false, "run" => nil, "stale" => "never_run"}] = annotated.blocks
    end

    test "leaves non-elixir code blocks as static blocks", %{ws: ws, user: user} do
      cloud!()
      {:ok, nb} = notebook(ws, user, [%{"type" => "code", "language" => "text", "content" => "hi"}])

      annotated = Runs.annotate(Docs.get_current_by_base(nb.base_doc_id))
      [block] = annotated.blocks
      refute Map.has_key?(block, "cell")
      refute Map.has_key?(block, "run")
    end
  end

  describe "staleness (derived from source)" do
    test "fresh right after a run, stale after the cell source is edited", %{ws: ws, user: user} do
      local!()
      {:ok, nb} = notebook(ws, user, [code_cell("1 + 1")])
      [%{"id" => block_id}] = nb.blocks
      {:ok, _} = Runs.run_cell(nb, block_id, actor(user))

      latest = Runs.latest_per_cell(nb.base_doc_id)
      assert Runs.staleness(nb, latest) == %{block_id => :fresh}

      # Edit the cell's source — a new doc version moves the fingerprint.
      ops = [%{"op" => "modify_block", "id" => block_id, "patch" => %{"content" => "2 + 2"}}]
      {:ok, edited} = Docs.apply_ops(nb, ops, %{actor_user_id: user.id, actor_type: "agent"}, dispositions: [])

      assert Runs.staleness(edited, latest) == %{block_id => :stale}
    end

    test "never_run before any run", %{ws: ws, user: user} do
      local!()
      {:ok, nb} = notebook(ws, user, [code_cell("1 + 1")])
      [%{"id" => block_id}] = nb.blocks

      assert Runs.staleness(nb, Runs.latest_per_cell(nb.base_doc_id)) == %{block_id => :never_run}
    end
  end

  describe "query/1 bridge" do
    test "a code cell reads a catalog query's result (stubbed run)", %{ws: ws, user: user} do
      local!()

      Application.put_env(:aveline, :runtime_query_fun, fn _ws_id, name ->
        %{"columns" => ["label"], "rows" => [[name]]}
      end)

      {:ok, nb} =
        notebook(ws, user, [code_cell(~s|result = query("orders")\nhd(hd(result["rows"]))|)])

      [%{"id" => block_id}] = nb.blocks

      assert {:ok, run} = Runs.run_cell(nb, block_id, actor(user))
      assert run.status == "ok"
      assert run.outputs["result"] == ~s|"orders"|
    end
  end

  describe "materialize/2" do
    test "saves a computed result as a referenceable catalog query", %{ws: ws, user: user} do
      local!()

      src = ~S|materialize("saved_rows", %{"columns" => ["a", "b"], "rows" => [[1, "x"], [2, "y"]]})|
      {:ok, nb} = notebook(ws, user, [code_cell(src)])
      [%{"id" => block_id}] = nb.blocks

      assert {:ok, run} = Runs.run_cell(nb, block_id, actor(user))
      assert run.status == "ok"

      # The catalog now has a derived query by that name, encoding the data.
      query = Aveline.DataSources.Queries.get_current_by_name(ws.id, "saved_rows")
      assert query.kind == "derived"
      assert query.sql =~ "VALUES"
      assert query.created_by_id == user.id
    end
  end
end
