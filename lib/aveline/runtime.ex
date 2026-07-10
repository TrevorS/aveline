defmodule Aveline.Runtime do
  @moduledoc """
  Public entry point for evaluating notebook code cells.

  One supervised `Runtime.Session` runs per open notebook (keyed by
  `base_doc_id`), owning that notebook's accumulated bindings so cells see
  each other's variables. `eval/4` finds or starts the session and runs a
  cell against it, returning the captured result — never raising, because
  the backend turns exceptions/throws/exits/timeouts into `:error` results.

  Execution is a runtime capability, gated elsewhere (`Aveline.Runs`
  refuses code-cell runs outside `DEPLOY_MODE=local`). This module is the
  mechanism; the policy lives at the run boundary.
  """

  alias Aveline.Runtime.Session
  alias Aveline.Runtime.SessionSupervisor

  @doc """
  Evaluate `source` (labelled by `cell_id`) in `base_doc_id`'s session,
  starting the session if needed. `opts` carries `:workspace_id` (the
  `query/1` bridge context) and optionally `:backend`. Returns the backend
  result map `%{status: :ok | :error, result, stdout, error, duration_ms}`.
  """
  def eval(base_doc_id, cell_id, source, opts \\ [])
      when is_binary(base_doc_id) and is_binary(cell_id) and is_binary(source) do
    with {:ok, pid} <- session(base_doc_id, opts) do
      Session.eval(pid, cell_id, source, opts)
    end
  end

  @doc """
  The running session pid for `base_doc_id`, starting one if absent.
  `opts` are used only when starting (`:backend`, `:workspace_id`).
  """
  def session(base_doc_id, opts \\ []) when is_binary(base_doc_id) do
    case Session.whereis(base_doc_id) do
      nil -> SessionSupervisor.start_session(Keyword.put(opts, :base_doc_id, base_doc_id))
      pid -> {:ok, pid}
    end
  end

  @doc "Stop the notebook's session (drops its accumulated bindings)."
  def stop(base_doc_id) when is_binary(base_doc_id) do
    case Session.whereis(base_doc_id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(SessionSupervisor, pid)
    end
  end
end
