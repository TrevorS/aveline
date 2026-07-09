defmodule Aveline.Frames.Expr do
  @moduledoc """
  The frame expression AST — validation, normalization, and compilation.

  Expressions are JSON maps with exactly one key (matching the wire
  format):

    * `%{"col" => name}`        — a column reference
    * `%{"lit" => value}`       — a literal (number, string, boolean, null)
    * `%{"add" => [l, r]}`      — arithmetic: add / sub / mul / div
    * `%{"gt" => [l, r]}`       — comparison: eq / neq / gt / gte / lt / lte
    * `%{"and" => [l, r]}`      — boolean: and / or
    * `%{"not" => expr}`        — boolean negation

  Capped at depth #{8} and #{64} nodes so a pathological expression is a
  validation error, never a runaway walk.

  This module is pure — no Repo, no Explorer at validation time.
  `compile/1` returns a closure over a dataframe that builds the
  expression's `Explorer.Series`; only `Aveline.Frames.Executor` ever
  invokes it (and rescues anything Explorer raises into an error value).
  """

  @max_depth 8
  @max_nodes 64
  @max_col_name 128

  @binary_ops ~w(add sub mul div eq neq gt gte lt lte and or)
  @unary_ops ~w(not)

  def max_depth, do: @max_depth
  def max_nodes, do: @max_nodes

  @doc """
  Validate and normalize an expression. Returns `{:ok, normalized}`
  (known keys only, so junk fields strip) or `{:error, reason}`.
  """
  def validate(expr) do
    with {:ok, normalized, _nodes} <- walk(expr, 1, 0) do
      {:ok, normalized}
    end
  end

  @doc "Every column name the expression references, deduplicated."
  def columns(%{"col" => name}), do: [name]
  def columns(%{"lit" => _}), do: []
  def columns(%{"not" => inner}), do: columns(inner)

  def columns(%{} = node) do
    case Map.to_list(node) do
      [{op, [l, r]}] when op in @binary_ops -> Enum.uniq(columns(l) ++ columns(r))
      _ -> []
    end
  end

  @doc """
  Compile a normalized expression to a closure `fn dataframe ->
  series_or_scalar end`. Scalar-only subtrees fold with plain Elixir
  operators; anything touching a column builds `Explorer.Series` calls.
  """
  def compile(%{"col" => name}), do: fn df -> df[name] end
  def compile(%{"lit" => value}), do: fn _df -> value end

  def compile(%{"not" => inner}) do
    inner_fun = compile(inner)

    fn df ->
      case inner_fun.(df) do
        v when is_boolean(v) -> not v
        series -> Explorer.Series.not(series)
      end
    end
  end

  def compile(%{} = node) do
    [{op, [l, r]}] = Map.to_list(node)
    left_fun = compile(l)
    right_fun = compile(r)

    fn df -> apply_binary(op, left_fun.(df), right_fun.(df)) end
  end

  # ===== Internal: validation walk =====

  defp walk(_expr, depth, _nodes) when depth > @max_depth,
    do: {:error, "expression too deep (max #{@max_depth} levels)"}

  defp walk(_expr, _depth, nodes) when nodes >= @max_nodes,
    do: {:error, "expression too large (max #{@max_nodes} nodes)"}

  defp walk(%{"col" => name} = node, _depth, nodes) when map_size(node) == 1 do
    if is_binary(name) and name != "" and byte_size(name) <= @max_col_name,
      do: {:ok, %{"col" => name}, nodes + 1},
      else: {:error, "col must be a non-empty column name (max #{@max_col_name} chars)"}
  end

  defp walk(%{"lit" => value} = node, _depth, nodes) when map_size(node) == 1 do
    if is_number(value) or is_binary(value) or is_boolean(value) or is_nil(value),
      do: {:ok, %{"lit" => value}, nodes + 1},
      else: {:error, "lit must be a number, string, boolean, or null"}
  end

  defp walk(%{} = node, depth, nodes) do
    case Map.to_list(node) do
      [{op, args}] when op in @binary_ops ->
        case args do
          [l, r] ->
            with {:ok, l, nodes} <- walk(l, depth + 1, nodes + 1),
                 {:ok, r, nodes} <- walk(r, depth + 1, nodes) do
              {:ok, %{op => [l, r]}, nodes}
            end

          _ ->
            {:error, "#{op} takes exactly two operands: {\"#{op}\": [left, right]}"}
        end

      [{op, inner}] when op in @unary_ops ->
        with {:ok, inner, nodes} <- walk(inner, depth + 1, nodes + 1) do
          {:ok, %{op => inner}, nodes}
        end

      [{op, _}] when is_binary(op) ->
        {:error,
         "unknown expression op #{inspect(op)}; expected col, lit, or one of #{inspect(@binary_ops ++ @unary_ops)}"}

      _ ->
        {:error, "expression node must be an object with exactly one key"}
    end
  end

  defp walk(_expr, _depth, _nodes),
    do: {:error, "expression must be an object (e.g. {\"col\": \"amount\"})"}

  # ===== Internal: compiled-op dispatch =====

  # At least one Explorer series: Series ops accept a scalar on either
  # side. Both scalars: plain Elixir — a type mismatch raises and the
  # executor turns it into an error value.
  defp apply_binary(op, l, r) do
    if is_struct(l, Explorer.Series) or is_struct(r, Explorer.Series),
      do: apply(Explorer.Series, series_fun(op), [l, r]),
      else: scalar_apply(op, l, r)
  end

  defp series_fun("add"), do: :add
  defp series_fun("sub"), do: :subtract
  defp series_fun("mul"), do: :multiply
  defp series_fun("div"), do: :divide
  defp series_fun("eq"), do: :equal
  defp series_fun("neq"), do: :not_equal
  defp series_fun("gt"), do: :greater
  defp series_fun("gte"), do: :greater_equal
  defp series_fun("lt"), do: :less
  defp series_fun("lte"), do: :less_equal
  defp series_fun("and"), do: :and
  defp series_fun("or"), do: :or

  defp scalar_apply("add", l, r), do: l + r
  defp scalar_apply("sub", l, r), do: l - r
  defp scalar_apply("mul", l, r), do: l * r
  defp scalar_apply("div", l, r), do: l / r
  defp scalar_apply("eq", l, r), do: l == r
  defp scalar_apply("neq", l, r), do: l != r
  defp scalar_apply("gt", l, r), do: l > r
  defp scalar_apply("gte", l, r), do: l >= r
  defp scalar_apply("lt", l, r), do: l < r
  defp scalar_apply("lte", l, r), do: l <= r
  defp scalar_apply("and", l, r), do: l and r
  defp scalar_apply("or", l, r), do: l or r
end
