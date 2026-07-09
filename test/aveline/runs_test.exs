defmodule Aveline.RunsTest do
  @moduledoc """
  Cell runs end to end against the test database itself as the data
  source (same "self" stubbing pattern as data_sources_test): source
  cells, chained frames, error runs, derived staleness, and the load-
  bearing invariant that outputs never land in docs.blocks or version
  rows.
  """
  use Aveline.DataCase, async: false

  alias Aveline.Broadcasts
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
    Aveline.DataSources.Cache.flush()
    user = Fixtures.user_fixture()
    ws = Fixtures.workspace_fixture(user)
    {:ok, ds} = DataSources.create(ws.id, "self", self_template(), self_password(), user.id)
    %{user: user, ws: ws, ds: ds}
  end

  defp notebook!(ws, user, blocks) do
    {:ok, doc} =
      Docs.create_doc(%{
        workspace_id: ws.id,
        owner_id: user.id,
        actor_user_id: user.id,
        actor_type: "agent",
        kind: "notebook",
        title: "Orders notebook",
        blocks: blocks,
        intent: "test"
      })

    doc
  end

  defp orders_frame(query \\ "select * from (values ('emea', 50), ('amer', 250), ('amer', 400)) as t(region, amount)") do
    %{"type" => "frame", "name" => "orders", "input" => %{"source" => "self", "query" => query}}
  end

  defp big_orders_frame do
    %{
      "type" => "frame",
      "name" => "big_orders",
      "input" => %{"frame" => "orders"},
      "ops" => [%{"op" => "filter", "expr" => %{"gt" => [%{"col" => "amount"}, %{"lit" => 100}]}}]
    }
  end

  defp block_id(doc, name) do
    Enum.find(doc.blocks, &(&1["name"] == name))["id"]
  end

  defp actor(user), do: %{user_id: user.id, type: "agent"}

  describe "run_cell/3 — source cells" do
    test "captures an ok run with provenance", %{user: user, ws: ws} do
      doc = notebook!(ws, user, [orders_frame()])
      bid = block_id(doc, "orders")

      assert {:ok, %CellRun{} = run} = Runs.run_cell(doc, bid, actor(user))
      assert run.status == "ok"
      assert run.outputs["columns"] == ["region", "amount"]
      assert length(run.outputs["rows"]) == 3
      assert run.workspace_id == ws.id
      assert run.base_doc_id == doc.base_doc_id
      assert run.doc_version_id == doc.id
      assert run.block_id == bid
      assert run.actor_user_id == user.id
      assert run.actor_type == "agent"
      assert is_integer(run.duration_ms)
      assert run.truncated == false
      assert String.length(run.snapshot_hash) == 64

      # Recorded in the workspace event feed.
      assert Enum.any?(Aveline.Events.list_for_workspace(ws.id), fn e ->
               e.action == "cell_run" and e.data["block_id"] == bid and e.data["status"] == "ok"
             end)
    end

    test "ops apply to the fetched rows", %{user: user, ws: ws} do
      frame =
        orders_frame()
        |> Map.put("ops", [
          %{"op" => "group_by", "columns" => ["region"]},
          %{"op" => "summarise", "aggs" => [%{"name" => "total", "fn" => "sum", "col" => "amount"}]},
          %{"op" => "sort", "by" => [%{"col" => "total", "dir" => "desc"}]}
        ])

      doc = notebook!(ws, user, [frame])

      assert {:ok, run} = Runs.run_cell(doc, block_id(doc, "orders"), actor(user))
      assert run.outputs == %{"columns" => ["region", "total"], "rows" => [["amer", 650], ["emea", 50]]}
    end

    test "bad SQL records an error run — never a raise", %{user: user, ws: ws} do
      doc = notebook!(ws, user, [orders_frame("select nope from nowhere")])
      bid = block_id(doc, "orders")

      assert {:ok, %CellRun{status: "error"} = run} = Runs.run_cell(doc, bid, actor(user))
      assert run.outputs["error"] =~ "nowhere"
      # The error run is a record, retrievable like any other.
      assert [%CellRun{status: "error"}] = Runs.list_runs(doc.base_doc_id, bid)
    end

    test "a deleted data source records an error run", %{user: user, ws: ws, ds: ds} do
      doc = notebook!(ws, user, [orders_frame()])
      {:ok, _} = DataSources.delete(ds, user.id)

      assert {:ok, %CellRun{status: "error"} = run} =
               Runs.run_cell(doc, block_id(doc, "orders"), actor(user))

      assert run.outputs["error"] =~ "deleted"
    end

    test "broadcasts started + finished on the doc topic", %{user: user, ws: ws} do
      doc = notebook!(ws, user, [orders_frame()])
      bid = block_id(doc, "orders")
      Broadcasts.subscribe(Broadcasts.doc_topic(doc.base_doc_id))

      {:ok, run} = Runs.run_cell(doc, bid, actor(user))

      assert_receive {:cell_run_started, %{base_doc_id: base, block_id: ^bid}}
      assert base == doc.base_doc_id
      assert_receive {:cell_run_finished, %{block_id: ^bid, run: %CellRun{} = received}}
      assert received.id == run.id
    end
  end

  describe "run_cell/3 — chained frames" do
    test "a dependent binds through its upstream's latest captured run", %{user: user, ws: ws} do
      doc = notebook!(ws, user, [orders_frame(), big_orders_frame()])

      {:ok, _} = Runs.run_cell(doc, block_id(doc, "orders"), actor(user))
      assert {:ok, run} = Runs.run_cell(doc, block_id(doc, "big_orders"), actor(user))

      assert run.status == "ok"
      assert run.outputs["rows"] == [["amer", 250], ["amer", 400]]
    end

    test "running a dependent before its upstream records an error run", %{user: user, ws: ws} do
      doc = notebook!(ws, user, [orders_frame(), big_orders_frame()])

      assert {:ok, %CellRun{status: "error"} = run} =
               Runs.run_cell(doc, block_id(doc, "big_orders"), actor(user))

      assert run.outputs["error"] =~ "has not been run yet"
    end
  end

  describe "refusals" do
    test "kind=doc refuses without recording anything", %{user: user, ws: ws} do
      doc = Fixtures.doc_fixture(ws, user)

      assert {:error, :not_notebook} = Runs.run_cell(doc, "b_whatever", actor(user))
      assert Runs.latest_per_cell(doc.base_doc_id) == %{}
    end

    test "unknown or non-frame block ids refuse", %{user: user, ws: ws} do
      doc =
        notebook!(ws, user, [
          %{"type" => "paragraph", "content" => [%{"text" => "hello"}]},
          orders_frame()
        ])

      para_id = Enum.find(doc.blocks, &(&1["type"] == "paragraph"))["id"]

      assert {:error, :cell_not_found} = Runs.run_cell(doc, "b_ghost", actor(user))
      assert {:error, :cell_not_found} = Runs.run_cell(doc, para_id, actor(user))
    end

    test "a bogus actor refuses before executing or broadcasting", %{user: user, ws: ws} do
      doc = notebook!(ws, user, [orders_frame()])
      bid = block_id(doc, "orders")
      Broadcasts.subscribe(Broadcasts.doc_topic(doc.base_doc_id))

      assert {:error, :invalid_actor} = Runs.run_cell(doc, bid, %{user_id: user.id, type: "bogus"})
      assert Runs.latest_per_cell(doc.base_doc_id) == %{}
      refute_receive {:cell_run_started, _}, 100
    end

    test "a nil actor type defaults to agent", %{user: user, ws: ws} do
      doc = notebook!(ws, user, [orders_frame()])

      assert {:ok, %CellRun{actor_type: "agent"}} =
               Runs.run_cell(doc, block_id(doc, "orders"), %{user_id: user.id})
    end
  end

  describe "staleness/2" do
    test "never_run → fresh → stale on upstream edit, downstream cascades", %{user: user, ws: ws} do
      doc = notebook!(ws, user, [orders_frame(), big_orders_frame()])
      orders_id = block_id(doc, "orders")
      big_id = block_id(doc, "big_orders")

      assert %{^orders_id => :never_run, ^big_id => :never_run} =
               Runs.staleness(doc, Runs.latest_per_cell(doc.base_doc_id))

      {:ok, _} = Runs.run_cell(doc, orders_id, actor(user))
      doc_runs = Runs.latest_per_cell(doc.base_doc_id)
      assert %{^orders_id => :fresh, ^big_id => :never_run} = Runs.staleness(doc, doc_runs)

      {:ok, _} = Runs.run_cell(doc, big_id, actor(user))
      doc_runs = Runs.latest_per_cell(doc.base_doc_id)
      assert %{^orders_id => :fresh, ^big_id => :fresh} = Runs.staleness(doc, doc_runs)

      # Edit the UPSTREAM cell's query — a new doc version, zero runs.
      {:ok, v2} =
        Docs.apply_ops(
          doc,
          [
            %{
              "op" => "modify_block",
              "id" => orders_id,
              "patch" => %{
                "input" => %{
                  "source" => "self",
                  "query" => "select * from (values ('apac', 900)) as t(region, amount)"
                }
              }
            }
          ],
          %{actor_user_id: user.id, actor_type: "agent"},
          intent: "change the upstream query"
        )

      # Both stale, derived purely from hashes — no stored flags anywhere.
      runs = Runs.latest_per_cell(v2.base_doc_id)
      assert %{^orders_id => :stale, ^big_id => :stale} = Runs.staleness(v2, runs)

      # Rerun upstream: it freshens; downstream stays stale (it consumed
      # the OLD upstream output).
      {:ok, _} = Runs.run_cell(v2, orders_id, actor(user))
      runs = Runs.latest_per_cell(v2.base_doc_id)
      assert %{^orders_id => :fresh, ^big_id => :stale} = Runs.staleness(v2, runs)

      # Rerun downstream against the fresh upstream: everything fresh.
      {:ok, _} = Runs.run_cell(v2, big_id, actor(user))
      runs = Runs.latest_per_cell(v2.base_doc_id)
      assert %{^orders_id => :fresh, ^big_id => :fresh} = Runs.staleness(v2, runs)
    end

    test "an error run is never fresh", %{user: user, ws: ws} do
      doc = notebook!(ws, user, [orders_frame("select nope from nowhere")])
      bid = block_id(doc, "orders")

      {:ok, %CellRun{status: "error"}} = Runs.run_cell(doc, bid, actor(user))
      assert %{^bid => :stale} = Runs.staleness(doc, Runs.latest_per_cell(doc.base_doc_id))
    end
  end

  describe "outputs never leak into docs" do
    test "no version row ever carries results", %{user: user, ws: ws} do
      doc = notebook!(ws, user, [orders_frame(), big_orders_frame()])
      {:ok, _} = Runs.run_cell(doc, block_id(doc, "orders"), actor(user))
      {:ok, _} = Runs.run_cell(doc, block_id(doc, "big_orders"), actor(user))

      # Edit after running — the new version must be built from lean
      # blocks, not from anything a run produced.
      {:ok, _v2} =
        Docs.apply_ops(
          doc,
          [%{"op" => "append_block", "block" => %{"type" => "paragraph", "content" => [%{"text" => "notes"}]}}],
          %{actor_user_id: user.id, actor_type: "agent"},
          intent: "add notes"
        )

      for version <- Docs.list_versions(doc.base_doc_id),
          block <- Repo.reload!(%Aveline.Docs.Doc{id: version.id}).blocks do
        refute Map.has_key?(block, "result"), "version v#{version.version_number} block carries result"
        refute Map.has_key?(block, "outputs")
        refute Map.has_key?(block, "schema")
        refute Map.has_key?(block, "source")
        refute Map.has_key?(block, "rows")
      end
    end

    test "a pasted echo strips on write", %{user: user, ws: ws} do
      frame =
        orders_frame()
        |> Map.put("result", %{"columns" => ["x"], "rows" => [[1]]})
        |> Map.put("schema", ["x"])

      doc = notebook!(ws, user, [frame])

      [block] = doc.blocks
      refute Map.has_key?(block, "result")
      refute Map.has_key?(block, "schema")
    end
  end

  describe "doc-level frame validation (Docs context)" do
    test "frame blocks are rejected outside notebooks", %{user: user, ws: ws} do
      assert {:error, msg} =
               Docs.create_doc(%{
                 workspace_id: ws.id,
                 owner_id: user.id,
                 actor_user_id: user.id,
                 actor_type: "agent",
                 kind: "doc",
                 title: "Not a notebook",
                 blocks: [orders_frame()],
                 intent: "test"
               })

      assert msg =~ "only allowed in notebooks"
    end

    test "input.source resolves to the base data source id at write", %{user: user, ws: ws, ds: ds} do
      doc = notebook!(ws, user, [orders_frame()])

      assert [%{"input" => %{"data_source_id" => id, "query" => _}}] = doc.blocks
      assert id == ds.base_data_source_id

      assert {:error, :data_source_not_found, _} =
               Docs.create_doc(%{
                 workspace_id: ws.id,
                 owner_id: user.id,
                 actor_user_id: user.id,
                 actor_type: "agent",
                 kind: "notebook",
                 title: "Ghost source",
                 blocks: [%{"type" => "frame", "name" => "a", "input" => %{"source" => "ghost", "query" => "select 1"}}],
                 intent: "test"
               })
    end

    test "forward frame refs and duplicate names fail the version", %{user: user, ws: ws} do
      assert {:error, msg} =
               Docs.create_doc(%{
                 workspace_id: ws.id,
                 owner_id: user.id,
                 actor_user_id: user.id,
                 actor_type: "agent",
                 kind: "notebook",
                 title: "Backwards",
                 blocks: [big_orders_frame(), orders_frame()],
                 intent: "test"
               })

      assert msg =~ "not an earlier frame"

      assert {:error, msg} =
               Docs.create_doc(%{
                 workspace_id: ws.id,
                 owner_id: user.id,
                 actor_user_id: user.id,
                 actor_type: "agent",
                 kind: "notebook",
                 title: "Twins",
                 blocks: [orders_frame(), orders_frame()],
                 intent: "test"
               })

      assert msg =~ "more than once"
    end

    test "a move_block that breaks the graph fails all-or-nothing", %{user: user, ws: ws} do
      doc = notebook!(ws, user, [orders_frame(), big_orders_frame()])
      big_id = block_id(doc, "big_orders")

      assert {:error, msg} =
               Docs.apply_ops(
                 doc,
                 [%{"op" => "move_block", "id" => big_id, "after" => nil}],
                 %{actor_user_id: user.id, actor_type: "agent"},
                 intent: "move the dependent above its upstream"
               )

      assert msg =~ "not an earlier frame"

      # Nothing shipped.
      assert Docs.get_current_by_base(doc.base_doc_id).version_number == 1
    end
  end

  describe "Runner/Cache row caps" do
    test "row_cap is an option and part of the cache key", %{ds: ds} do
      sql = "select generate_series(1, 1500) as n"

      # Default cap (1000) truncates — and is cached under its own key.
      assert {:ok, capped} = DataSources.Cache.run(ds, sql)
      assert length(capped["rows"]) == DataSources.Runner.row_cap()
      assert capped["truncated"] == true

      # A bigger cap must MISS that cache entry and return everything.
      assert {:ok, full} = DataSources.Cache.run(ds, sql, row_cap: Runs.frame_input_row_cap())
      assert length(full["rows"]) == 1500
      refute Map.has_key?(full, "truncated")
    end
  end
end
