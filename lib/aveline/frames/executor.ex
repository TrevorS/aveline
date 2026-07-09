defmodule Aveline.Frames.Executor do
  @moduledoc """
  The one impure edge of the Frames context: turns a columns/rows input
  (a Runner result or an upstream run's outputs) into an Explorer
  DataFrame, applies a validated op pipeline lazily, collects, and caps
  the output at #{500} rows (`"truncated" => true` when cut).

  Runs inside an unlinked supervised task with the same 12s ceiling as
  `Aveline.DataSources.Runner` — a hung or crashing pipeline can only
  take down the task, never the caller.

  Errors come back as strings, not raises: a frame with a broken
  pipeline is a state on the run, never a failed read or a crashed
  caller.
  """

  alias Aveline.Frames.Expr

  @task_timeout_ms 12_000
  @output_row_cap 500

  def output_row_cap, do: @output_row_cap

  @doc """
  Execute `ops` (already validated by `Frames.Pipeline`) against a
  `%{"columns" => [...], "rows" => [[...]]}` input. Returns
  `{:ok, %{"columns" => ..., "rows" => ..., "truncated"? => true}}` or
  `{:error, reason_string}`.
  """
  def run(%{"columns" => columns, "rows" => rows}, ops)
      when is_list(columns) and is_list(rows) and is_list(ops) do
    task =
      Task.Supervisor.async_nolink(Aveline.TaskSupervisor, fn ->
        execute(columns, rows, ops)
      end)

    case Task.yield(task, @task_timeout_ms) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, "frame execution failed: " <> exit_message(reason)}

      nil ->
        case Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          _ -> {:error, "frame execution timed out"}
        end
    end
  end

  def run(_input, _ops), do: {:error, "frame input must be a columns/rows result"}

  @doc """
  Rebuild a dataframe from a run's captured outputs — the bindings
  bridge for code cells (`frame("name")`). Same construction as
  `run/2`'s input step; errors are strings, never raises.
  """
  def from_outputs(%{"columns" => columns, "rows" => rows})
      when is_list(columns) and is_list(rows),
      do: build(columns, rows)

  def from_outputs(_outputs), do: {:error, "frame outputs must be a columns/rows result"}

  defp exit_message(%{__exception__: true} = e), do: Exception.message(e)
  defp exit_message({%{__exception__: true} = e, _stacktrace}), do: Exception.message(e)
  defp exit_message(other), do: inspect(other) |> String.slice(0, 200)

  # ===== In-task pipeline =====

  defp execute(columns, rows, ops) do
    with {:ok, df} <- build(columns, rows) do
      df
      |> Explorer.DataFrame.lazy()
      |> apply_ops(ops)
      |> Explorer.DataFrame.collect()
      |> shape()
    end
  rescue
    # Explorer raises on type mismatches, unknown columns, malformed
    # masks — all authoring errors that must surface as run states.
    e -> {:error, "frame execution failed: " <> Exception.message(e)}
  end

  defp build(columns, rows) do
    cond do
      columns == [] ->
        {:error, "frame input has no columns"}

      Enum.uniq(columns) != columns ->
        {:error, "frame input has duplicate column names; alias them apart in the query"}

      true ->
        series =
          columns
          |> Enum.with_index()
          |> Map.new(fn {name, i} -> {name, Enum.map(rows, &Enum.at(&1, i))} end)

        # DataFrame.new from a map loses column order; select restores it.
        {:ok, series |> Explorer.DataFrame.new() |> Explorer.DataFrame.select(columns)}
    end
  end

  # Pipeline validation guarantees group_by is immediately followed by
  # summarise; the pair applies as one grouped aggregation.
  defp apply_ops(df, [%{"op" => "group_by", "columns" => cols}, %{"op" => "summarise"} = s | rest]) do
    df
    |> Explorer.DataFrame.group_by(cols)
    |> summarise(s)
    |> apply_ops(rest)
  end

  defp apply_ops(df, [%{"op" => "filter", "expr" => expr} | rest]) do
    mask = Expr.compile(expr)

    df
    |> Explorer.DataFrame.filter_with(fn d -> mask.(d) end)
    |> apply_ops(rest)
  end

  defp apply_ops(df, [%{"op" => "mutate", "name" => name, "expr" => expr} | rest]) do
    value = Expr.compile(expr)

    df
    |> Explorer.DataFrame.mutate_with(fn d -> [{name, value.(d)}] end)
    |> apply_ops(rest)
  end

  defp apply_ops(df, [%{"op" => "summarise"} = s | rest]) do
    df |> summarise(s) |> apply_ops(rest)
  end

  defp apply_ops(df, [%{"op" => "sort", "by" => by} | rest]) do
    df
    |> Explorer.DataFrame.sort_with(fn d ->
      Enum.map(by, fn %{"col" => col, "dir" => dir} ->
        {if(dir == "desc", do: :desc, else: :asc), d[col]}
      end)
    end)
    |> apply_ops(rest)
  end

  defp apply_ops(df, [%{"op" => "select", "columns" => columns} | rest]) do
    df |> Explorer.DataFrame.select(columns) |> apply_ops(rest)
  end

  defp apply_ops(df, [%{"op" => "head", "n" => n} | rest]) do
    df |> Explorer.DataFrame.head(n) |> apply_ops(rest)
  end

  defp apply_ops(df, []), do: df

  defp summarise(df, %{"aggs" => aggs}) do
    Explorer.DataFrame.summarise_with(df, fn d ->
      Enum.map(aggs, fn %{"name" => name, "fn" => fun, "col" => col} ->
        {name, agg(fun, d[col])}
      end)
    end)
  end

  defp agg("sum", series), do: Explorer.Series.sum(series)
  defp agg("mean", series), do: Explorer.Series.mean(series)
  defp agg("count", series), do: Explorer.Series.count(series)
  defp agg("min", series), do: Explorer.Series.min(series)
  defp agg("max", series), do: Explorer.Series.max(series)

  defp shape(df) do
    truncated? = Explorer.DataFrame.n_rows(df) > @output_row_cap
    df = Explorer.DataFrame.head(df, @output_row_cap)

    names = Explorer.DataFrame.names(df)
    by_column = Explorer.DataFrame.to_columns(df, atom_keys: false)

    rows =
      names
      |> Enum.map(&Map.fetch!(by_column, &1))
      |> Enum.zip_with(fn cells -> Enum.map(cells, &json_safe/1) end)

    out = %{"columns" => names, "rows" => rows}
    {:ok, if(truncated?, do: Map.put(out, "truncated", true), else: out)}
  end

  # Cells must survive Jason encoding into cell_runs.outputs. Explorer
  # returns non-finite floats as atoms; they become nil (a chart can
  # render a gap; JSON has no Infinity).
  defp json_safe(v) when v in [:nan, :infinity, :neg_infinity], do: nil
  defp json_safe(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp json_safe(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp json_safe(%Date{} = d), do: Date.to_iso8601(d)
  defp json_safe(%Time{} = t), do: Time.to_iso8601(t)
  defp json_safe(%Decimal{} = d), do: Decimal.to_float(d)
  defp json_safe(v) when is_number(v) or is_boolean(v) or is_nil(v) or is_binary(v), do: v
  defp json_safe(v), do: inspect(v)
end
