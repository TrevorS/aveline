defmodule Aveline.Runtime.Backend do
  @moduledoc """
  The pluggable evaluation engine behind a `Runtime.Session`. A backend
  owns the accumulated evaluation state for one notebook and evaluates a
  cell's source against it, returning a captured result plus the updated
  state.

  Two backends exist:

    * `Aveline.Runtime.InProcess` — evaluates on the app node in a
      supervised, timeout-bounded task (shipped; the default).
    * `Aveline.Runtime.Peer` — a stub for a future isolated BEAM peer
      node (Livebook's standalone-runtime pattern), so a cell can't reach
      app internals. Not implemented yet.

  A backend never raises for user-code failures: an exception, throw,
  exit, or timeout in the cell comes back as an `:error` result, so a
  bad cell can never take the session — or the app — down.
  """

  @typedoc """
  One captured evaluation:

    * `:status` — `:ok` (evaluated) or `:error` (raised / threw / exited /
      timed out).
    * `:result` — the inspected return value on success, `nil` on error.
    * `:stdout` — everything the cell wrote to the group leader.
    * `:error` — a human-readable failure message on error, `nil` on ok.
    * `:duration_ms` — wall-clock evaluation time.
  """
  @type result :: %{
          status: :ok | :error,
          result: String.t() | nil,
          stdout: String.t(),
          error: String.t() | nil,
          duration_ms: non_neg_integer()
        }

  @doc "Initialize per-notebook evaluation state."
  @callback init(opts :: keyword) :: {:ok, state :: term} | {:error, term}

  @doc """
  Evaluate `source` (labelled by `cell_id`) against `state`, returning the
  captured `result` and the updated state (e.g. accumulated bindings).
  `opts` carries at least `:workspace_id` (for the `query/1` bridge) and
  `:timeout` (ms).
  """
  @callback eval(state :: term, cell_id :: String.t(), source :: String.t(), opts :: keyword) ::
              {result, state :: term}
end
