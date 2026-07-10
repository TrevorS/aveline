defmodule Aveline.Runtime.Session do
  @moduledoc """
  One evaluation session per open notebook: a supervised process that owns
  a backend's accumulated state (bindings) and serializes cell evaluations
  for that notebook. Registered by `base_doc_id` in
  `Aveline.Runtime.Registry`, started on demand under
  `Aveline.Runtime.SessionSupervisor`, and idle-stopped after
  `@idle_timeout` so an abandoned notebook doesn't hold state forever.

  Crash isolation is layered: the backend runs each eval in a nolink task
  it kills on timeout, so user code can't fault the session; and the
  session is `restart: :temporary` under a DynamicSupervisor, so even a
  fault in the session itself just drops it (its state was disposable
  captured runs already persisted) without disturbing the app. The next
  eval starts a fresh session with empty bindings.
  """

  use GenServer, restart: :temporary

  alias Aveline.Runtime.Registry, as: SessionRegistry

  @idle_timeout :timer.minutes(10)
  @eval_timeout :timer.seconds(10)

  # ── client ─────────────────────────────────────────────────────────

  def start_link(opts) do
    base_doc_id = Keyword.fetch!(opts, :base_doc_id)
    GenServer.start_link(__MODULE__, opts, name: via(base_doc_id))
  end

  @doc """
  Evaluate `source` (labelled by `cell_id`) in the session for
  `base_doc_id`, accumulating bindings. `opts` carries `:workspace_id`
  (the `query/1` bridge context). Returns the backend's captured result
  map (`%{status, result, stdout, error, duration_ms}`).
  """
  def eval(pid, cell_id, source, opts) when is_pid(pid),
    do: GenServer.call(pid, {:eval, cell_id, source, opts}, @eval_timeout + :timer.seconds(5))

  @doc "Registry `:via` tuple for the notebook's session."
  def via(base_doc_id), do: {:via, Registry, {SessionRegistry, base_doc_id}}

  @doc "The running session pid for `base_doc_id`, or `nil`."
  def whereis(base_doc_id) do
    case Registry.lookup(SessionRegistry, base_doc_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # ── server ─────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    backend = Keyword.get(opts, :backend, Aveline.Runtime.InProcess)

    case backend.init(opts) do
      {:ok, backend_state} ->
        state = %{
          base_doc_id: Keyword.fetch!(opts, :base_doc_id),
          backend: backend,
          backend_state: backend_state,
          idle_timeout: Keyword.get(opts, :idle_timeout, @idle_timeout)
        }

        {:ok, arm_idle(state)}

      {:error, reason} ->
        {:stop, {:backend_init_failed, reason}}
    end
  end

  @impl true
  def handle_call({:eval, cell_id, source, opts}, _from, state) do
    opts = Keyword.put_new(opts, :timeout, @eval_timeout)
    {reply, backend_state} = state.backend.eval(state.backend_state, cell_id, source, opts)
    {:reply, reply, arm_idle(%{state | backend_state: backend_state})}
  end

  @impl true
  def handle_info(:idle_stop, state) do
    # Guard against a race: an eval may have landed after this timer fired
    # but before we handled it. Only stop if we've genuinely been idle the
    # full window; otherwise re-arm for the remaining time.
    idle_for = System.monotonic_time(:millisecond) - state.last_active

    if idle_for >= state.idle_timeout do
      {:stop, :normal, state}
    else
      Process.send_after(self(), :idle_stop, state.idle_timeout - idle_for)
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Mark activity and (re)arm the idle countdown on every eval.
  defp arm_idle(state) do
    Process.send_after(self(), :idle_stop, state.idle_timeout)
    Map.put(state, :last_active, System.monotonic_time(:millisecond))
  end
end
