defmodule Aveline.Runtime.Session do
  @moduledoc """
  One evaluation session per open notebook (keyed by `base_doc_id`): a
  Registry-named GenServer under `Aveline.Runtime.SessionSupervisor`
  that owns the notebook's backend state (the per-cell contexts, or
  the peer node holding them) and serializes evaluations — cells in
  one notebook never race each other, they queue.

  The session holds STATE, not safety: evaluation happens in the
  backend (see `Aveline.Runtime.Backend`), which bounds it with a
  timeout and catches everything, so a raising or hung cell comes back
  as an error value and the session survives with its contexts intact.
  Sessions are `:temporary` — nothing restarts one that dies; the next
  `evaluate/4` just starts a fresh, empty session — and they stop
  themselves after 10 idle minutes. Each session also subscribes to
  its doc topic and prunes the contexts of cells an edit deleted
  (forget_evaluation GC), so a deleted cell's dataframes don't linger
  for the whole idle window.
  """

  use GenServer, restart: :temporary

  alias Aveline.Broadcasts
  alias Aveline.Frames.Graph

  @idle_timeout_ms 600_000

  # ===== Client =====

  def start_link({base_doc_id, opts}) do
    GenServer.start_link(__MODULE__, {base_doc_id, opts}, name: via(base_doc_id))
  end

  @doc """
  The running session for a notebook, started on first use. `opts`
  (`:backend`, `:idle_timeout_ms`) only apply when this call is the one
  that starts it.
  """
  def ensure(base_doc_id, opts \\ []) do
    case DynamicSupervisor.start_child(
           Aveline.Runtime.SessionSupervisor,
           {__MODULE__, {base_doc_id, opts}}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc """
  Evaluate one cell's source in the notebook's session. `opts`:

    * `:parents` — earlier code cell ids in doc order; the nearest one
      already evaluated donates the starting context
    * `:frame_resolver`, `:timeout_ms` — passed through to the backend

  Returns the backend's outcome; a session that goes away mid-call is
  an error value, not a caller crash.
  """
  def evaluate(base_doc_id, block_id, source, opts \\ []) do
    {:ok, pid} = ensure(base_doc_id, opts)

    try do
      # :infinity — never abandon a call the session will still serve.
      # Every eval is bounded INSIDE the backend, so a caller only ever
      # waits on the bounded evals queued ahead of it; a caller-side
      # deadline here would record a false error run while the session
      # went on to evaluate the cell anyway (side effects executed,
      # output lost, provenance contradicting what ran).
      GenServer.call(pid, {:evaluate, block_id, source, opts}, :infinity)
    catch
      :exit, _reason ->
        {:error,
         %{
           message: "the notebook's runtime session went away mid-evaluation; rerun the cell",
           stdout: "",
           stdout_truncated: false
         }}
    end
  end

  def whereis(base_doc_id), do: GenServer.whereis(via(base_doc_id))

  defp via(base_doc_id), do: {:via, Registry, {Aveline.Runtime.Registry, base_doc_id}}

  # ===== Server =====

  @impl true
  def init({base_doc_id, opts}) do
    # A dying peer node exits its linked control process toward us —
    # that must land as an ignorable message (and let terminate/2 stop
    # the backend), never kill the session.
    Process.flag(:trap_exit, true)
    Broadcasts.subscribe(Broadcasts.doc_topic(base_doc_id))

    state = %{
      backend: Keyword.get(opts, :backend, default_backend()),
      # Started lazily on the first evaluate so a boot failure (a
      # refused peer node) is an error VALUE per eval, never an
      # ensure/2 crash.
      backend_state: :not_started,
      opts: opts,
      idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, @idle_timeout_ms)
    }

    {:ok, state, state.idle_timeout_ms}
  end

  @impl true
  def handle_call({:evaluate, block_id, source, opts}, _from, state) do
    case ensure_backend(state) do
      {:ok, state} ->
        {outcome, backend_state} =
          state.backend.evaluate(
            state.backend_state,
            block_id,
            source,
            Keyword.get(opts, :parents, []),
            opts
          )

        {:reply, outcome, %{state | backend_state: backend_state}, state.idle_timeout_ms}

      {:error, message} ->
        outcome = {:error, %{message: message, stdout: "", stdout_truncated: false}}
        {:reply, outcome, state, state.idle_timeout_ms}
    end
  end

  @impl true
  def handle_info(:timeout, state), do: {:stop, :normal, state}

  # forget_evaluation GC: an edit that deletes a code cell must drop
  # its stored context (bindings can hold large rebuilt dataframes)
  # instead of letting it linger until the idle stop.
  def handle_info({:doc_updated, %{blocks: blocks}}, %{backend_state: backend_state} = state)
      when backend_state != :not_started do
    keep = for %{"type" => "code", "id" => id} <- Graph.cells(blocks), do: id
    {:noreply, %{state | backend_state: state.backend.prune(backend_state, keep)}, state.idle_timeout_ms}
  end

  def handle_info(_msg, state), do: {:noreply, state, state.idle_timeout_ms}

  @impl true
  def terminate(_reason, %{backend_state: :not_started}), do: :ok
  def terminate(_reason, state), do: state.backend.stop(state.backend_state)

  defp ensure_backend(%{backend_state: :not_started} = state) do
    case state.backend.start(state.opts) do
      {:ok, backend_state} -> {:ok, %{state | backend_state: backend_state}}
      {:error, message} -> {:error, message}
    end
  end

  defp ensure_backend(state), do: {:ok, state}

  defp default_backend,
    do: Application.get_env(:aveline, :runtime_backend, Aveline.Runtime.Backend.Peer)
end
