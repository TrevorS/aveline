defmodule Aveline.Frames.Pipeline do
  @moduledoc """
  Whole-pipeline validation for a frame cell's ops. Pure — no Repo, no
  Explorer.

  On top of per-op shape checks (`Aveline.Frames.Op`) this enforces:

    * at most #{16} ops per pipeline
    * `group_by` must be immediately followed by `summarise` (a dangling
      group changes the meaning of everything after it); a bare
      `summarise` aggregates the whole frame
    * schema threading — column references are checked against the set
      of columns known at that point in the pipeline. A source query's
      columns are unknown until run time, so threading starts at
      `:unknown`; a `summarise` or `select` pins the set (its output
      columns are fully determined by the op itself), and every op after
      that is checked concretely.
  """

  alias Aveline.Frames.Expr
  alias Aveline.Frames.Op

  @max_ops 16

  def max_ops, do: @max_ops

  @doc """
  Validate a full op list. Returns `{:ok, normalized_ops}` or
  `{:error, reason}`.
  """
  def validate(ops) when is_list(ops) do
    cond do
      length(ops) > @max_ops ->
        {:error, "too many ops (max #{@max_ops} per frame)"}

      true ->
        with {:ok, ops} <- validate_each(ops),
             {:ok, _schema} <- schema(:unknown, ops) do
          {:ok, ops}
        end
    end
  end

  def validate(_), do: {:error, "frame.ops must be a list"}

  @doc """
  Thread the column set through the pipeline. `columns` is `:unknown`
  (source query — columns only known at run time) or a list of names.
  Returns `{:ok, :unknown | [name]}` for the output schema, or
  `{:error, reason}` when an op references a column that provably
  doesn't exist at that point — or when a `group_by` isn't immediately
  followed by its `summarise`.
  """
  def schema(columns, ops) when columns == :unknown or is_list(columns) do
    thread(ops, columns)
  end

  # ===== Internal =====

  defp validate_each(ops) do
    Enum.reduce_while(ops, {:ok, []}, fn op, {:ok, acc} ->
      case Op.validate(op) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        err -> {:halt, err}
      end
    end)
  end

  # group_by + summarise thread as a pair: the output is exactly the
  # group columns + agg names, concrete even over an unknown input.
  defp thread(
         [%{"op" => "group_by", "columns" => group_cols}, %{"op" => "summarise", "aggs" => aggs} | rest],
         cols
       ) do
    with :ok <- known(group_cols, cols, "group_by"),
         :ok <- known(Enum.map(aggs, & &1["col"]), cols, "summarise") do
      thread(rest, group_cols ++ Enum.map(aggs, & &1["name"]))
    end
  end

  defp thread([%{"op" => "group_by"} | _], _cols),
    do: {:error, "group_by must be immediately followed by summarise"}

  # Bare summarise aggregates the whole frame into one row of aggs.
  defp thread([%{"op" => "summarise", "aggs" => aggs} | rest], cols) do
    with :ok <- known(Enum.map(aggs, & &1["col"]), cols, "summarise") do
      thread(rest, Enum.map(aggs, & &1["name"]))
    end
  end

  defp thread([%{"op" => "filter", "expr" => expr} | rest], cols) do
    with :ok <- known(Expr.columns(expr), cols, "filter") do
      thread(rest, cols)
    end
  end

  defp thread([%{"op" => "mutate", "name" => name, "expr" => expr} | rest], cols) do
    with :ok <- known(Expr.columns(expr), cols, "mutate") do
      thread(rest, add_column(cols, name))
    end
  end

  defp thread([%{"op" => "sort", "by" => by} | rest], cols) do
    with :ok <- known(Enum.map(by, & &1["col"]), cols, "sort") do
      thread(rest, cols)
    end
  end

  defp thread([%{"op" => "select", "columns" => columns} | rest], cols) do
    with :ok <- known(columns, cols, "select") do
      thread(rest, columns)
    end
  end

  defp thread([%{"op" => "head"} | rest], cols), do: thread(rest, cols)

  defp thread([], cols), do: {:ok, cols}

  defp add_column(:unknown, _name), do: :unknown
  defp add_column(cols, name), do: Enum.uniq(cols ++ [name])

  defp known(_refs, :unknown, _op), do: :ok

  defp known(refs, cols, op) do
    case Enum.reject(refs, &(&1 in cols)) do
      [] -> :ok
      missing -> {:error, "#{op} references unknown column(s): #{Enum.join(missing, ", ")}"}
    end
  end
end
