defmodule Aveline.Runtime.CellHelpers do
  @moduledoc """
  Functions imported into every code cell evaluation.

  `frame/1` is the bindings bridge from code cells to frame cells: it
  resolves an upstream frame by name through a resolver the run placed
  in the evaluating process (closing over the frame's latest captured
  outputs) and rebuilds the Explorer dataframe from them. Misses raise
  — inside a cell a raise is caught by the evaluator and recorded as
  an error run, never a crash.
  """

  @resolver_key :aveline_frame_resolver

  @doc false
  def put_frame_resolver(resolver) when is_function(resolver, 1),
    do: Process.put(@resolver_key, resolver)

  @doc """
  The dataframe of an upstream frame cell, rebuilt from its latest
  captured run. Only available inside a code cell evaluation.
  """
  def frame(name) when is_binary(name) do
    resolver =
      Process.get(@resolver_key) ||
        raise "frame/1 only works inside a notebook code cell"

    with {:ok, outputs} <- resolver.(name),
         {:ok, df} <- Aveline.Frames.Executor.from_outputs(outputs) do
      df
    else
      {:error, message} -> raise message
    end
  end
end
