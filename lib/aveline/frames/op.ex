defmodule Aveline.Frames.Op do
  @moduledoc """
  Per-op shape validation for the frame pipeline. Pure — no Repo, no
  Explorer.

  Ops are tagged maps with string keys (matching the JSON wire format):

    filter:     %{"op" => "filter", "expr" => <expr>}
    mutate:     %{"op" => "mutate", "name" => "margin", "expr" => <expr>}
    group_by:   %{"op" => "group_by", "columns" => ["region"]}
    summarise:  %{"op" => "summarise",
                  "aggs" => [%{"name" => "total", "fn" => "sum", "col" => "amount"}]}
    sort:       %{"op" => "sort", "by" => [%{"col" => "total", "dir" => "desc"}]}
    select:     %{"op" => "select", "columns" => ["region", "total"]}
    head:       %{"op" => "head", "n" => 10}

  Sequence legality (group_by pairs with summarise, op count cap) is
  `Aveline.Frames.Pipeline`'s job; this module only checks one op's shape.
  """

  alias Aveline.Frames.Expr

  @ops ~w(filter mutate group_by summarise sort select head)
  @agg_fns ~w(sum mean count min max)
  @dirs ~w(asc desc)

  @max_col_name 128
  @max_new_name 64
  @max_list 32
  @max_head 50_000

  @new_name_re ~r/^[a-z][a-z0-9_]*$/

  def ops, do: @ops
  def agg_fns, do: @agg_fns

  @doc """
  Validate one op. Returns `{:ok, normalized}` (known fields only, so
  junk strips) or `{:error, reason}`.
  """
  def validate(%{"op" => "filter", "expr" => expr}) do
    with {:ok, expr} <- prefix(Expr.validate(expr), "filter.expr") do
      {:ok, %{"op" => "filter", "expr" => expr}}
    end
  end

  def validate(%{"op" => "filter"}), do: {:error, "filter requires expr"}

  def validate(%{"op" => "mutate", "name" => name, "expr" => expr}) do
    cond do
      not new_name?(name) ->
        {:error, "mutate.name must be a snake_case identifier (max #{@max_new_name} chars)"}

      true ->
        with {:ok, expr} <- prefix(Expr.validate(expr), "mutate.expr") do
          {:ok, %{"op" => "mutate", "name" => name, "expr" => expr}}
        end
    end
  end

  def validate(%{"op" => "mutate"}), do: {:error, "mutate requires name and expr"}

  def validate(%{"op" => "group_by", "columns" => columns}) do
    with {:ok, columns} <- column_list(columns, "group_by.columns") do
      {:ok, %{"op" => "group_by", "columns" => columns}}
    end
  end

  def validate(%{"op" => "group_by"}), do: {:error, "group_by requires columns (list)"}

  def validate(%{"op" => "summarise", "aggs" => aggs}) when is_list(aggs) do
    cond do
      aggs == [] ->
        {:error, "summarise.aggs cannot be empty"}

      length(aggs) > @max_list ->
        {:error, "summarise.aggs too long (max #{@max_list})"}

      true ->
        with {:ok, aggs} <- validate_aggs(aggs) do
          {:ok, %{"op" => "summarise", "aggs" => aggs}}
        end
    end
  end

  def validate(%{"op" => "summarise"}),
    do: {:error, "summarise requires aggs (list of {name, fn, col})"}

  def validate(%{"op" => "sort", "by" => by}) when is_list(by) do
    cond do
      by == [] ->
        {:error, "sort.by cannot be empty"}

      length(by) > @max_list ->
        {:error, "sort.by too long (max #{@max_list})"}

      true ->
        with {:ok, by} <- validate_sort_keys(by) do
          {:ok, %{"op" => "sort", "by" => by}}
        end
    end
  end

  def validate(%{"op" => "sort"}),
    do: {:error, "sort requires by (list of {col, dir?})"}

  def validate(%{"op" => "select", "columns" => columns}) do
    with {:ok, columns} <- column_list(columns, "select.columns") do
      {:ok, %{"op" => "select", "columns" => columns}}
    end
  end

  def validate(%{"op" => "select"}), do: {:error, "select requires columns (list)"}

  def validate(%{"op" => "head", "n" => n}) do
    if is_integer(n) and n >= 1 and n <= @max_head,
      do: {:ok, %{"op" => "head", "n" => n}},
      else: {:error, "head.n must be an integer between 1 and #{@max_head}"}
  end

  def validate(%{"op" => "head"}), do: {:error, "head requires n (integer)"}

  def validate(%{"op" => op}) when is_binary(op),
    do: {:error, "unknown frame op #{inspect(op)}; expected one of #{inspect(@ops)}"}

  def validate(_), do: {:error, "frame op must be an object with an \"op\" field"}

  # ===== Internal =====

  defp validate_aggs(aggs) do
    Enum.reduce_while(aggs, {:ok, []}, fn agg, {:ok, acc} ->
      case validate_agg(agg) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        err -> {:halt, err}
      end
    end)
  end

  defp validate_agg(%{"name" => name, "fn" => fun, "col" => col}) do
    cond do
      not new_name?(name) ->
        {:error, "agg.name must be a snake_case identifier (max #{@max_new_name} chars)"}

      fun not in @agg_fns ->
        {:error, "agg.fn must be one of #{inspect(@agg_fns)}"}

      not column_name?(col) ->
        {:error, "agg.col must be a non-empty column name (max #{@max_col_name} chars)"}

      true ->
        {:ok, %{"name" => name, "fn" => fun, "col" => col}}
    end
  end

  defp validate_agg(_), do: {:error, "each agg must be {name, fn, col}"}

  defp validate_sort_keys(by) do
    Enum.reduce_while(by, {:ok, []}, fn key, {:ok, acc} ->
      case validate_sort_key(key) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        err -> {:halt, err}
      end
    end)
  end

  defp validate_sort_key(%{"col" => col} = key) do
    dir = Map.get(key, "dir", "asc")

    cond do
      not column_name?(col) ->
        {:error, "sort key col must be a non-empty column name (max #{@max_col_name} chars)"}

      dir not in @dirs ->
        {:error, "sort key dir must be \"asc\" or \"desc\""}

      true ->
        {:ok, %{"col" => col, "dir" => dir}}
    end
  end

  defp validate_sort_key(_), do: {:error, "each sort key must be {col, dir?}"}

  defp column_list(columns, field) do
    cond do
      not is_list(columns) or columns == [] ->
        {:error, "#{field} must be a non-empty list of column names"}

      length(columns) > @max_list ->
        {:error, "#{field} too long (max #{@max_list})"}

      Enum.any?(columns, &(not column_name?(&1))) ->
        {:error, "#{field} must be non-empty column names (max #{@max_col_name} chars each)"}

      true ->
        {:ok, columns}
    end
  end

  defp column_name?(col),
    do: is_binary(col) and col != "" and byte_size(col) <= @max_col_name

  defp new_name?(name),
    do: is_binary(name) and byte_size(name) <= @max_new_name and Regex.match?(@new_name_re, name)

  defp prefix({:error, msg}, field), do: {:error, "#{field}: #{msg}"}
  defp prefix(ok, _field), do: ok
end
