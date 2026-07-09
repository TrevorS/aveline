defmodule Aveline.Runtime.Backend.InProcess do
  @moduledoc """
  Evaluates code cells inside this BEAM; the backend state is the
  plain contexts map. See `Aveline.Runtime.Backend` for the seam and
  `Aveline.Runtime.Evaluator` for the mechanics.
  """

  @behaviour Aveline.Runtime.Backend

  alias Aveline.Runtime.Evaluator

  @impl true
  def start(_opts), do: {:ok, %{}}

  @impl true
  def evaluate(contexts, ref, source, parents, opts) do
    case Evaluator.eval(source, Evaluator.parent_context(contexts, parents), opts) do
      {:ok, %{context: context} = ok} ->
        {{:ok, Map.take(ok, [:result, :stdout, :stdout_truncated])}, Map.put(contexts, ref, context)}

      {:error, error} ->
        {{:error, error}, contexts}
    end
  end

  @impl true
  def prune(contexts, keep_refs), do: Map.take(contexts, keep_refs)

  @impl true
  def stop(_contexts), do: :ok
end
