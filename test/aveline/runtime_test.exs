defmodule Aveline.RuntimeTest do
  @moduledoc """
  The code-cell runtime: the InProcess evaluator (result, stdout,
  exception/timeout capture, accumulated bindings), the supervised
  session (crash isolation, idle stop), and the `query/1` bridge. Pure
  evaluation — no DB — so these run against the app's runtime tree
  directly. `async: false` because the `query/1` stub and short session
  ids touch global process/app state.
  """
  use ExUnit.Case, async: false

  alias Aveline.Runtime
  alias Aveline.Runtime.Session

  setup do
    on_exit(fn ->
      for key <- [:runtime_query_fun, :runtime_sql_fun, :runtime_source_fun] do
        Application.delete_env(:aveline, key)
      end
    end)

    :ok
  end

  # A fresh notebook id per test so sessions never collide.
  defp nb, do: "nb-" <> Integer.to_string(System.unique_integer([:positive]))

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(5) && wait_until(fun, tries - 1)
    end
  end

  describe "evaluation" do
    test "returns the inspected result of the last expression" do
      assert %{status: :ok, result: "30", error: nil} =
               Runtime.eval(nb(), "c1", "x = 3\nx * 10")
    end

    test "captures stdout separately from the result" do
      assert %{status: :ok, result: ":ok", stdout: "hello\n"} =
               Runtime.eval(nb(), "c1", ~s|IO.puts("hello")|)
    end

    test "an exception becomes an error run, not a raise" do
      assert %{status: :error, result: nil, error: error} =
               Runtime.eval(nb(), "c1", ~s|raise "boom"|)

      assert error =~ "boom"
    end

    test "a throw / exit is caught as an error run" do
      assert %{status: :error, error: error} = Runtime.eval(nb(), "c1", "throw(:nope)")
      assert error =~ "nope"
    end

    test "a runaway cell is killed at the timeout and recorded as an error" do
      assert %{status: :error, error: error, duration_ms: ms} =
               Runtime.eval(nb(), "c1", ":timer.sleep(60_000)", timeout: 100)

      assert error =~ "timed out"
      assert ms < 5_000
    end

    test "bindings accumulate across cells in one session" do
      id = nb()
      assert %{status: :ok} = Runtime.eval(id, "c1", "y = 41")
      assert %{status: :ok, result: "42"} = Runtime.eval(id, "c2", "y + 1")
    end

    test "records how long the evaluation took" do
      assert %{status: :ok, duration_ms: ms} = Runtime.eval(nb(), "c1", "1 + 1")
      assert is_integer(ms) and ms >= 0
    end
  end

  describe "session lifecycle" do
    test "one session is reused for a notebook across evals" do
      id = nb()
      {:ok, pid} = Runtime.session(id)
      Runtime.eval(id, "c1", "1")
      assert Runtime.session(id) == {:ok, pid}
    end

    test "a raising cell does not take the session down" do
      id = nb()
      {:ok, pid} = Runtime.session(id)

      assert %{status: :error} = Runtime.eval(id, "c1", ~s|raise "boom"|)

      # Same session, still alive, still evaluating.
      assert Process.alive?(pid)
      assert Runtime.session(id) == {:ok, pid}
      assert %{status: :ok, result: "2"} = Runtime.eval(id, "c2", "1 + 1")
    end

    test "a cell that kills its own evaluation process leaves the session intact" do
      id = nb()
      {:ok, pid} = Runtime.session(id)

      assert %{status: :error} = Runtime.eval(id, "c1", "Process.exit(self(), :kill)")

      assert Process.alive?(pid)
      assert %{status: :ok} = Runtime.eval(id, "c2", "1 + 1")
    end

    test "killing a session doesn't disturb the supervisor; the next eval starts fresh" do
      id = nb()
      {:ok, pid} = Runtime.session(id)
      Runtime.eval(id, "c1", "z = 99")

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

      # Wait for the Registry to drop the dead pid (its own monitor fires
      # independently of ours), then start fresh.
      wait_until(fn -> Session.whereis(id) == nil end)

      # A fresh session — empty bindings, so the old `z` is gone.
      {:ok, new_pid} = Runtime.session(id)
      assert new_pid != pid
      assert %{status: :error, error: error} = Runtime.eval(id, "c2", "z")
      assert error =~ "z"
    end

    test "the session idle-stops after its idle window" do
      id = nb()
      {:ok, pid} = Session.start_link(base_doc_id: id, idle_timeout: 60)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end
  end

  describe "query/1 bridge" do
    test "reads a catalog query's latest result (stubbed) as columns/rows" do
      Application.put_env(:aveline, :runtime_query_fun, fn _ws, name ->
        %{"columns" => ["name"], "rows" => [[name]]}
      end)

      assert %{status: :ok, result: result} =
               Runtime.eval(nb(), "c1", ~s|query("orders")|, workspace_id: "ws-1")

      assert result =~ "orders"
      assert result =~ "columns"
    end

    test "a failed query surfaces as an error run" do
      Application.put_env(:aveline, :runtime_query_fun, fn _ws, _name ->
        %{"error" => "no such query"}
      end)

      assert %{status: :error, error: error} =
               Runtime.eval(nb(), "c1", ~s|query("gone")|, workspace_id: "ws-1")

      assert error =~ "no such query"
    end
  end

  describe "Explorer integration" do
    setup do
      Application.put_env(:aveline, :runtime_query_fun, fn _ws, _name ->
        %{"columns" => ["city", "pop"], "rows" => [["Tokyo", 37], ["Delhi", 33], ["Paris", 11]]}
      end)

      :ok
    end

    test "query_df/1 turns a catalog result into an Explorer.DataFrame" do
      assert %{status: :ok, result: result} =
               Runtime.eval(nb(), "c1", ~s|df = query_df("cities"); DF.n_rows(df)|, workspace_id: "ws-1")

      assert result == "3"
    end

    test "DF/Series verbs are in scope and a returned DataFrame renders as a table" do
      src = ~S{query_df("cities") |> DF.filter(pop > 20) |> DF.arrange(desc: pop)}

      assert %{status: :ok, result: result, table: table} =
               Runtime.eval(nb(), "c1", src, workspace_id: "ws-1")

      assert result =~ "Explorer.DataFrame"
      assert table["columns"] == ["city", "pop"]
      assert table["rows"] == [["Tokyo", 37], ["Delhi", 33]]
      assert table["truncated"] == false
    end

    test "a scalar result carries no table" do
      assert %{status: :ok, table: nil} = Runtime.eval(nb(), "c1", "1 + 1", workspace_id: "ws-1")
    end

    test "plot/2 returns a chart output rendered through the viz grammar" do
      src = ~S{plot(query_df("cities"), type: :bar, x: "city", y: "pop")}

      assert %{status: :ok, result: result, chart: chart, table: nil} =
               Runtime.eval(nb(), "c1", src, workspace_id: "ws-1")

      assert result =~ "Plot"
      assert chart["viz"] == %{"type" => "bar", "x" => "city", "y" => "pop"}
      assert chart["data"]["columns"] == ["city", "pop"]
    end
  end

  describe "sql / source bridges" do
    test "sql/1 runs ad-hoc DuckDB over the catalog" do
      Application.put_env(:aveline, :runtime_sql_fun, fn _ws, query ->
        assert query =~ "SELECT"
        %{"columns" => ["n"], "rows" => [[3]]}
      end)

      assert %{status: :ok, result: result} =
               Runtime.eval(nb(), "c1", ~S{sql("SELECT count(*) AS n FROM cities")}, workspace_id: "ws-1")

      assert result =~ "columns"
    end

    test "sql/1 accepts an Ecto query, rendering it to SQL with params inlined" do
      Application.put_env(:aveline, :runtime_sql_fun, fn _ws, generated ->
        # the Ecto query renders to SQL naming the catalog query as a table,
        # with the bound literal inlined (no $1 placeholder left).
        assert generated =~ ~s("metrics")
        assert generated =~ "100"
        refute generated =~ "$1"
        %{"columns" => ["region"], "rows" => [["North"]]}
      end)

      src =
        ~S|sql(from m in "metrics", where: m.revenue > 100, select: %{region: m.region})|

      assert %{status: :ok} = Runtime.eval(nb(), "c1", src, workspace_id: "ws-1")
    end

    test "sql_df/1 returns an Explorer.DataFrame" do
      Application.put_env(:aveline, :runtime_sql_fun, fn _ws, _q ->
        %{"columns" => ["n"], "rows" => [[1], [2]]}
      end)

      assert %{status: :ok, result: result} =
               Runtime.eval(nb(), "c1", ~S{DF.n_rows(sql_df("SELECT 1"))}, workspace_id: "ws-1")

      assert result == "2"
    end

    test "from_source/2 runs raw SQL against a named source" do
      Application.put_env(:aveline, :runtime_source_fun, fn _ws, source, _q ->
        assert source == "prod"
        %{"columns" => ["users"], "rows" => [[42]]}
      end)

      assert %{status: :ok, result: result} =
               Runtime.eval(nb(), "c1", ~S{from_source("prod", "SELECT count(*) AS users FROM users")},
                 workspace_id: "ws-1"
               )

      assert result =~ "users"
    end

    test "a source/engine error surfaces as an error run" do
      Application.put_env(:aveline, :runtime_source_fun, fn _ws, _s, _q ->
        %{"error" => "connection refused"}
      end)

      assert %{status: :error, error: error} =
               Runtime.eval(nb(), "c1", ~S{from_source("down", "SELECT 1")}, workspace_id: "ws-1")

      assert error =~ "connection refused"
    end
  end

  describe "ML / stats tools" do
    setup do
      # y = 2x — a perfectly linear relationship for deterministic asserts.
      Application.put_env(:aveline, :runtime_query_fun, fn _ws, _name ->
        %{"columns" => ["x", "y"], "rows" => [[1, 2], [2, 4], [3, 6], [4, 8]]}
      end)

      :ok
    end

    test "to_tensor/1 bridges Explorer data into an Nx tensor" do
      assert %{status: :ok, result: "10"} =
               Runtime.eval(
                 nb(),
                 "c1",
                 ~S{query_df("d")["x"] |> to_tensor() |> Nx.sum() |> Nx.to_number()},
                 workspace_id: "ws-1"
               )
    end

    test "Ecto.Query is imported so a cell writes queries, not SQL strings" do
      assert %{status: :ok, result: "true"} =
               Runtime.eval(
                 nb(),
                 "c1",
                 ~S[match?(%Ecto.Query{}, from(d in "docs", select: d.id))],
                 workspace_id: "ws-1"
               )
    end

    test "a list of maps (e.g. an Ecto result) renders as a table" do
      assert %{status: :ok, table: table} =
               Runtime.eval(nb(), "c1", ~S|[%{a: 1, b: "x"}, %{a: 2, b: "y"}]|, workspace_id: "ws-1")

      assert table["columns"] == ["a", "b"]
      assert table["rows"] == [[1, "x"], [2, "y"]]
    end

    test "Scholar and Statistics are available and consume catalog data" do
      src = ~S"""
      df = query_df("d")
      x = df |> DF.select(["x"]) |> to_tensor()
      y = to_tensor(df["y"])
      _model = Scholar.Linear.LinearRegression.fit(x, y)
      Statistics.correlation(Explorer.Series.to_list(df["x"]), Explorer.Series.to_list(df["y"]))
      |> Float.round(2)
      """

      assert %{status: :ok, result: "1.0"} = Runtime.eval(nb(), "c1", src, workspace_id: "ws-1")
    end
  end
end
