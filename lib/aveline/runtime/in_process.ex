defmodule Aveline.Runtime.InProcess do
  @moduledoc """
  The default `Runtime.Backend`: evaluate Elixir on the app node, isolated
  and bounded. Mechanics borrowed from Livebook's evaluator, scaled to v1:

    * bindings accumulate — each cell evaluates against the variables the
      earlier cells left behind, so a notebook reads top-to-bottom like an
      IEx session (`x = query("orders")` in one cell, `length(x["rows"])`
      in the next);
    * `query/1` is in scope via a `Macro.Env` carrying `import
      Aveline.Runtime.Bridge`, so cells never alias or dot-call it;
    * stdout is captured by swapping the evaluating process's group leader
      for a `StringIO`, so `IO.puts` lands on the run, not the app log;
    * evaluation runs in a `Task.Supervisor.async_nolink` task under
      `Aveline.TaskSupervisor` — nolink so a crash never reaches the
      session — and is `Task.shutdown`-killed at the timeout;
    * exceptions, throws, and exits are caught as values, so the worst a
      cell can do is produce an `:error` run.

  A raising or looping cell therefore leaves the session and its
  accumulated bindings intact (the errored eval simply doesn't advance
  them) — no unrecoverable teardown.
  """

  @behaviour Aveline.Runtime.Backend

  # Imported (not aliased) so the `cell_env/0` Macro.Env carries `query/1`,
  # `query_df/1`, and `to_df/1` into every cell's scope, and so
  # `put_workspace/1` is a bare call here.
  import Aveline.Runtime.Bridge

  # `require`d (with :as) at module scope so `cell_env/0` (`__ENV__`) carries
  # both the alias AND the macro context into every cell — Explorer's
  # `DF.filter(col > 1)` / `DF.mutate(x: a + b)` forms are macros that expand
  # bare column names, so `require` (not just `alias`) is what makes them
  # work. A cell writes `DF.…` / `Series.…` with no setup; this is what makes
  # the DuckDB catalog and Explorer compose.
  require Explorer.DataFrame, as: DF
  alias Explorer.Series

  # Imported into the cell scope so a cell writes `db(from d in "docs", …)`
  # with no qualification. warn: false — InProcess itself doesn't use it; it
  # rides `cell_env/0` into every cell.
  import Ecto.Query, warn: false

  @result_row_cap 500

  @default_timeout :timer.seconds(10)

  @impl true
  def init(_opts), do: {:ok, %{bindings: []}}

  @impl true
  def eval(%{bindings: bindings} = state, cell_id, source, opts) do
    ws_id = Keyword.get(opts, :workspace_id)
    user_id = Keyword.get(opts, :actor_user_id)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    started = System.monotonic_time(:millisecond)

    task =
      Task.Supervisor.async_nolink(Aveline.TaskSupervisor, fn ->
        evaluate(source, bindings, ws_id, user_id)
      end)

    outcome =
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, evaluated} -> evaluated
        nil -> {:error, "evaluation timed out after #{timeout}ms and was killed", "", bindings}
        {:exit, reason} -> {:error, "evaluation crashed: #{inspect(reason)}", "", bindings}
      end

    duration = System.monotonic_time(:millisecond) - started
    build(outcome, duration, state, cell_id)
  end

  # Runs on the throwaway task process. Swaps the group leader for a
  # StringIO to capture stdout, evaluates against the bridge-imported env,
  # and turns any failure into a value — nothing escapes.
  defp evaluate(source, bindings, ws_id, user_id) do
    {:ok, capture} = StringIO.open("")
    Process.group_leader(self(), capture)
    put_workspace(ws_id)
    put_user(user_id)

    # `with_diagnostics` collects the compiler's own messages, so a compile
    # error (e.g. an undefined variable) reports the real reason instead of
    # the generic "cannot compile file" a bare CompileError carries.
    {outcome, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          {value, new_bindings} = Code.eval_string(source, bindings, cell_env())
          {result, table, chart} = render_value(value)
          {:ok, result, table, chart, new_bindings}
        rescue
          error -> {:error, Exception.message(error)}
        catch
          :throw, value -> {:error, "throw: #{inspect(value)}"}
          :exit, reason -> {:error, "exit: #{inspect(reason)}"}
        end
      end)

    {_in, stdout} = StringIO.contents(capture)
    StringIO.close(capture)

    case outcome do
      {:ok, result, table, chart, new_bindings} ->
        {:ok, result, stdout, table, chart, new_bindings}

      {:error, message} ->
        {:error, error_message(message, diagnostics), stdout, bindings}
    end
  end

  # The return value decides the output channel, as `{result_string, table,
  # chart}`: a `Plot` renders a chart, a DataFrame/Series renders a table
  # (capped at #{@result_row_cap} rows), anything else keeps the inspected
  # string.
  defp render_value(%Aveline.Runtime.Plot{data: data, viz: viz}) do
    {"#Plot[#{viz["type"]}]", nil, %{"data" => coerce_table(data), "viz" => viz}}
  end

  defp render_value(%DF{} = df) do
    {rows, cols} = DF.shape(df)
    {"#Explorer.DataFrame [#{rows} rows x #{cols} cols]", df_table(df, rows), nil}
  end

  defp render_value(%Series{} = series) do
    {"#Explorer.Series [#{Series.size(series)}]", series_table(series), nil}
  end

  defp render_value([first | _] = list) when is_map(first) and not is_struct(first) do
    {"#{length(list)} rows", coerce_table(list), nil}
  end

  defp render_value(other), do: {inspect(other, pretty: true, limit: 100), nil, nil}

  # Coerce a plot's data (DataFrame | columns/rows map | list of maps) into
  # the `%{"columns", "rows"}` shape the ChartRenderer expects.
  defp coerce_table(%DF{} = df), do: df_table(df, elem(DF.shape(df), 0))
  defp coerce_table(%Series{} = series), do: series_table(series)

  defp coerce_table(%{"columns" => cols, "rows" => rows}),
    do: %{"columns" => cols, "rows" => rows, "truncated" => false}

  defp coerce_table([first | _] = maps) when is_map(first) do
    keys = Map.keys(first)

    %{
      "columns" => Enum.map(keys, &to_string/1),
      "rows" => Enum.map(maps, fn m -> Enum.map(keys, fn k -> cell_value(m[k]) end) end),
      "truncated" => false
    }
  end

  defp series_table(series) do
    values = Series.to_list(series)

    %{
      "columns" => ["value"],
      "rows" => values |> Enum.take(@result_row_cap) |> Enum.map(&[cell_value(&1)]),
      "truncated" => length(values) > @result_row_cap
    }
  end

  defp df_table(df, total_rows) do
    head = DF.head(df, @result_row_cap)
    cols = DF.names(head)
    columns = Enum.map(cols, fn c -> head[c] |> Series.to_list() |> Enum.map(&cell_value/1) end)

    %{
      "columns" => cols,
      "rows" => Enum.zip_with(columns, & &1),
      "truncated" => total_rows > @result_row_cap
    }
  end

  # jsonb-safe coercion for table cells: primitives pass through; Date /
  # Decimal / etc. become strings so the run's outputs encode cleanly.
  defp cell_value(v) when is_number(v) or is_binary(v) or is_boolean(v) or is_nil(v), do: v
  defp cell_value(v), do: to_string(v)

  # Prefer the compiler's diagnostics (specific) over the raised message
  # (often generic) when a compile error produced both.
  defp error_message(message, []), do: message

  defp error_message(_message, diagnostics),
    do: Enum.map_join(diagnostics, "\n", & &1.message)

  # An evaluation environment that imports the cell bridge, so `query/1`
  # resolves without the cell aliasing anything. Captured fresh per eval;
  # it carries imports/aliases only, not bindings (those are threaded
  # explicitly through `eval_string`).
  defp cell_env, do: __ENV__

  defp build({:ok, result, stdout, table, chart, new_bindings}, duration, state, _cell_id) do
    reply = %{
      status: :ok,
      result: result,
      table: table,
      chart: chart,
      stdout: stdout,
      error: nil,
      duration_ms: duration
    }

    {reply, %{state | bindings: new_bindings}}
  end

  defp build({:error, message, stdout, bindings}, duration, state, _cell_id) do
    reply = %{
      status: :error,
      result: nil,
      stdout: stdout,
      error: message,
      duration_ms: duration
    }

    # Bindings are left where they were — a failed cell doesn't advance state.
    {reply, %{state | bindings: bindings}}
  end
end
