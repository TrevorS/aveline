defmodule Aveline.RunsCodeCellTest do
  @moduledoc """
  Code cells through Runs.run_cell: the local-mode capability gate
  (a refusal, never an error run), captured stdout + inspected result,
  error runs, bindings flowing between cells, the frame("name")
  bindings bridge over a stubbed frame run, and derived staleness
  across the frame → code chain.
  """
  # Mutates the global :deploy_mode application env, so no async.
  use Aveline.DataCase, async: false

  alias Aveline.DataSources
  alias Aveline.Docs
  alias Aveline.Fixtures
  alias Aveline.Runs
  alias Aveline.Runs.CellRun

  defp self_template do
    "postgres://#{System.get_env("PGUSER") || "postgres"}:<password>@#{System.get_env("PGHOST") || "localhost"}/aveline_test#{System.get_env("MIX_TEST_PARTITION")}"
  end

  defp self_password, do: System.get_env("PGPASSWORD") || "postgres"

  setup do
    original = Application.fetch_env(:aveline, :deploy_mode)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:aveline, :deploy_mode, value)
        :error -> Application.delete_env(:aveline, :deploy_mode)
      end
    end)

    user = Fixtures.user_fixture()
    ws = Fixtures.workspace_fixture(user)
    {:ok, _ds} = DataSources.create(ws.id, "self", self_template(), self_password(), user.id)
    %{user: user, ws: ws}
  end

  defp local_mode!, do: Application.put_env(:aveline, :deploy_mode, "local")
  defp cloud_mode!, do: Application.put_env(:aveline, :deploy_mode, "cloud")

  defp notebook!(ws, user, blocks) do
    {:ok, doc} =
      Docs.create_doc(%{
        workspace_id: ws.id,
        owner_id: user.id,
        actor_user_id: user.id,
        actor_type: "agent",
        kind: "notebook",
        title: "Code notebook",
        blocks: blocks,
        intent: "test"
      })

    doc
  end

  defp code_cell(source, extra \\ %{}) do
    Map.merge(%{"type" => "code", "language" => "elixir", "content" => source}, extra)
  end

  defp orders_frame do
    %{
      "type" => "frame",
      "name" => "orders",
      "input" => %{"source" => "self", "query" => "select 1 as amount"}
    }
  end

  defp code_ids(doc) do
    for b <- doc.blocks, b["type"] == "code", do: b["id"]
  end

  defp actor(user), do: %{user_id: user.id, type: "agent"}

  # A captured frame run without ever dialing the data source — the
  # bridge binds through cell_runs, so a row is a full stub.
  defp stub_frame_run!(doc, frame_block, outputs) do
    %CellRun{}
    |> CellRun.changeset(%{
      workspace_id: doc.workspace_id,
      base_doc_id: doc.base_doc_id,
      doc_version_id: doc.id,
      block_id: frame_block["id"],
      snapshot_hash: Runs.snapshot_hash(frame_block, []),
      status: "ok",
      outputs: outputs,
      actor_type: "agent",
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  describe "capability gate" do
    test "outside local mode a code cell refuses without recording", %{user: user, ws: ws} do
      cloud_mode!()
      doc = notebook!(ws, user, [code_cell("1 + 1")])
      [bid] = code_ids(doc)

      assert {:error, :execution_disabled} = Runs.run_cell(doc, bid, actor(user))
      assert Runs.latest_per_cell(doc.base_doc_id) == %{}
    end

    test "frame cells still run outside local mode", %{user: user, ws: ws} do
      cloud_mode!()
      doc = notebook!(ws, user, [orders_frame()])
      [frame] = doc.blocks

      assert {:ok, %CellRun{status: "ok"}} = Runs.run_cell(doc, frame["id"], actor(user))
    end
  end

  describe "run_cell/3 — code cells (local mode)" do
    setup do
      local_mode!()
      :ok
    end

    test "captures result, stdout, and provenance", %{user: user, ws: ws} do
      doc = notebook!(ws, user, [code_cell(~s|IO.puts("hi")\n40 + 2|, %{"name" => "answer"})])
      [bid] = code_ids(doc)

      assert {:ok, %CellRun{} = run} = Runs.run_cell(doc, bid, actor(user))
      assert run.status == "ok"
      assert run.outputs["result"] == "42"
      assert run.stdout == "hi\n"
      assert run.base_doc_id == doc.base_doc_id
      assert run.doc_version_id == doc.id
      assert String.length(run.snapshot_hash) == 64
      assert is_integer(run.duration_ms)
    end

    test "a raising cell records an error run — never a raise", %{user: user, ws: ws} do
      doc = notebook!(ws, user, [code_cell(~s|raise "kaboom"|)])
      [bid] = code_ids(doc)

      assert {:ok, %CellRun{status: "error"} = run} = Runs.run_cell(doc, bid, actor(user))
      assert run.outputs["error"] =~ "kaboom"
      assert [%CellRun{status: "error"}] = Runs.list_runs(doc.base_doc_id, bid)
    end

    test "bindings flow from earlier code cells", %{user: user, ws: ws} do
      doc = notebook!(ws, user, [code_cell("x = 20"), code_cell("x * 2 + 2")])
      [first, second] = code_ids(doc)

      assert {:ok, %CellRun{status: "ok"}} = Runs.run_cell(doc, first, actor(user))
      assert {:ok, %CellRun{status: "ok"} = run} = Runs.run_cell(doc, second, actor(user))
      assert run.outputs["result"] == "42"
    end

    test "frame(\"name\") binds an upstream frame's captured run", %{user: user, ws: ws} do
      doc =
        notebook!(ws, user, [
          orders_frame(),
          code_cell(~s{frame("orders") |> Explorer.DataFrame.n_rows()})
        ])

      [frame_block, _code] = doc.blocks
      [bid] = code_ids(doc)

      stub_frame_run!(doc, frame_block, %{
        "columns" => ["region", "amount"],
        "rows" => [["emea", 50], ["amer", 250]]
      })

      assert {:ok, %CellRun{status: "ok"} = run} = Runs.run_cell(doc, bid, actor(user))
      assert run.outputs["result"] == "2"

      # Both fresh: the code run's chain hangs off the frame's hash.
      runs = Runs.latest_per_cell(doc.base_doc_id)
      frame_id = frame_block["id"]
      assert %{^frame_id => :fresh, ^bid => :fresh} = Runs.staleness(doc, runs)
    end

    test "an unrun upstream frame records an error run", %{user: user, ws: ws} do
      doc = notebook!(ws, user, [orders_frame(), code_cell(~s{frame("orders")})])
      [bid] = code_ids(doc)

      assert {:ok, %CellRun{status: "error"} = run} = Runs.run_cell(doc, bid, actor(user))
      assert run.outputs["error"] =~ "has not been run yet"
    end

    test "editing a code cell's source renders its capture stale", %{user: user, ws: ws} do
      doc = notebook!(ws, user, [code_cell("1 + 1")])
      [bid] = code_ids(doc)

      {:ok, _} = Runs.run_cell(doc, bid, actor(user))
      assert %{^bid => :fresh} = Runs.staleness(doc, Runs.latest_per_cell(doc.base_doc_id))

      {:ok, v2} =
        Docs.apply_ops(
          doc,
          [%{"op" => "modify_block", "id" => bid, "patch" => %{"content" => "2 + 2"}}],
          %{actor_user_id: user.id, actor_type: "agent"},
          intent: "change the source"
        )

      assert %{^bid => :stale} = Runs.staleness(v2, Runs.latest_per_cell(v2.base_doc_id))
    end
  end

  describe "code block validation" do
    test "an optional name must be a snake_case identifier", %{user: user, ws: ws} do
      doc = notebook!(ws, user, [code_cell("1", %{"name" => "answer_v2"})])
      assert [%{"name" => "answer_v2"}] = doc.blocks

      assert {:error, msg} =
               Docs.create_doc(%{
                 workspace_id: ws.id,
                 owner_id: user.id,
                 actor_user_id: user.id,
                 actor_type: "agent",
                 kind: "notebook",
                 title: "Bad name",
                 blocks: [code_cell("1", %{"name" => "Not A Name"})],
                 intent: "test"
               })

      assert msg =~ "code.name"
    end

    test "code blocks (even elixir) stay valid in plain docs", %{user: user, ws: ws} do
      {:ok, doc} =
        Docs.create_doc(%{
          workspace_id: ws.id,
          owner_id: user.id,
          actor_user_id: user.id,
          actor_type: "agent",
          title: "Plain doc with a snippet",
          blocks: [code_cell("IO.puts(:hi)")],
          intent: "test"
        })

      # But it is not a runnable cell there — kind gates first.
      [bid] = code_ids(doc)
      assert {:error, :not_notebook} = Runs.run_cell(doc, bid, actor(user))
    end
  end
end
