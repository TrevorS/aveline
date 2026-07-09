defmodule Aveline.Runtime.Backend do
  @moduledoc """
  Where code-cell source actually evaluates, and where the per-cell
  contexts (bindings + env, keyed by block-id refs) live. The session
  owns ONE backend state per notebook and calls through this seam so
  the evaluation substrate can change without touching the run
  plumbing:

    * `Aveline.Runtime.Backend.Peer` (the default) — boots a `:peer`
      BEAM node with this node's code paths and Explorer preloaded and
      evaluates there: contexts never leave the peer, and a cell that
      halts or wedges its node takes down only the peer — the next
      evaluate boots a fresh one.
    * `Aveline.Runtime.Backend.InProcess` — evaluates inside this BEAM
      via `Aveline.Runtime.Evaluator`: timeout-bounded and
      catch-everything, but sharing the app's code and schedulers.
      The test suite's default; also the fallback for deployments
      that cannot spawn peer nodes.

  Configure with `config :aveline, :runtime_backend, MyBackend`. Every
  outcome is a value — a backend must never raise toward the session —
  and outcomes carry only node-safe terms: the result is rendered
  where the value lives, raw values never cross the seam.
  """

  @type state :: term()
  @type outcome ::
          {:ok, %{result: String.t(), stdout: String.t(), stdout_truncated: boolean()}}
          | {:error, %{message: String.t(), stdout: String.t(), stdout_truncated: boolean()}}

  @doc """
  Boot the substrate. Called lazily by the session on the first
  evaluate, so `{:error, message}` surfaces as an error value per run,
  never a start crash.
  """
  @callback start(opts :: keyword()) :: {:ok, state()} | {:error, String.t()}

  @doc """
  Evaluate one cell: `ref` keys the stored context, `parents` are the
  earlier code cell ids in doc order (the nearest evaluated one
  donates the starting context). `opts` carries `:timeout_ms` and
  `:frame_resolver` through to the evaluator.
  """
  @callback evaluate(
              state(),
              ref :: String.t(),
              source :: String.t(),
              parents :: [String.t()],
              opts :: keyword()
            ) :: {outcome(), state()}

  @doc """
  Drop every stored context whose ref is NOT in `keep_refs` — the
  forget_evaluation GC behind cell deletes.
  """
  @callback prune(state(), keep_refs :: [String.t()]) :: state()

  @doc "Release the substrate (peer node shutdown); called when the session stops."
  @callback stop(state()) :: :ok
end
