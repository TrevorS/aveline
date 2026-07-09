defmodule Aveline.Runtime.Backend.Peer do
  @moduledoc """
  Evaluates code cells on a peer BEAM node — Livebook's standalone
  runtime pattern. One node per session, booted with this node's code
  paths and `:elixir` + Explorer started, linked to the session so the
  idle stop tears it down. Contexts (bindings + env) live in an Agent
  ON the peer — dataframe NIF resources never cross nodes — and only
  rendered results, stdout, and error messages come back.

  The control channel is a loopback TCP connection (`connection: 0`),
  so neither node needs distribution. A cell that halts or wedges the
  node (`System.halt`, atom/memory exhaustion, stopped applications)
  kills only the peer: the failed call is an error value, and the next
  evaluate boots a fresh node with empty contexts — the session
  restarts cleanly at the cost of rerunning upstream cells.

  Boot failures are error values per run, never crashes; a deployment
  that cannot spawn an `erl` (no executable on PATH) can point
  `:runtime_backend` at `Aveline.Runtime.Backend.InProcess` instead.
  """

  @behaviour Aveline.Runtime.Backend

  alias Aveline.Runtime.Evaluator

  # Node boot + :elixir/Explorer starts; generous — once per session.
  @boot_timeout_ms 30_000
  # The peer call must outlive the evaluator's own ceiling so a slow
  # cell times out INSIDE the eval (an error value from the peer),
  # never as an abandoned call the peer keeps evaluating.
  @call_margin_ms 2_000

  # Registered on the peer node, which is exclusive to one session.
  @contexts Aveline.Runtime.Backend.Peer.Contexts
  @task_supervisor Aveline.Runtime.Backend.Peer.TaskSupervisor

  @impl true
  def start(_opts) do
    args = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    with {:ok, pid, _node} <- :peer.start_link(%{connection: 0, args: args}),
         {:ok, _apps} <-
           :peer.call(pid, :application, :ensure_all_started, [:elixir], @boot_timeout_ms),
         :ok <- :peer.call(pid, __MODULE__, :bootstrap, [], @boot_timeout_ms) do
      {:ok, %{peer: pid}}
    else
      failure -> {:error, "could not boot the peer runtime node: #{inspect(failure)}"}
    end
  catch
    kind, reason ->
      {:error,
       "could not boot the peer runtime node: " <>
         Exception.format_banner(kind, reason, __STACKTRACE__)}
  end

  @impl true
  def evaluate(state, ref, source, parents, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, Evaluator.default_timeout_ms())

    case ensure_started(state) do
      {:ok, state} ->
        try do
          outcome =
            :peer.call(
              state.peer,
              __MODULE__,
              :peer_evaluate,
              [ref, source, parents, opts],
              timeout_ms + @call_margin_ms
            )

          {outcome, state}
        catch
          _kind, _reason ->
            # The node died mid-eval (halted or wedged cell). Report it
            # as a value and boot fresh on the next evaluate.
            stop(state)

            {{:error,
              %{
                message:
                  "the peer runtime node went away mid-evaluation (a halted or wedged cell?); " <>
                    "the next run boots a fresh node — rerun upstream cells first",
                stdout: "",
                stdout_truncated: false
              }}, %{state | peer: :down}}
        end

      {:error, message} ->
        {{:error, %{message: message, stdout: "", stdout_truncated: false}}, state}
    end
  end

  @impl true
  def prune(%{peer: pid} = state, keep_refs) when is_pid(pid) do
    try do
      :peer.call(pid, Agent, :update, [@contexts, &Map.take(&1, keep_refs)], 5_000)
      state
    catch
      _kind, _reason -> state
    end
  end

  def prune(state, _keep_refs), do: state

  @impl true
  def stop(%{peer: pid}) when is_pid(pid) do
    try do
      :peer.stop(pid)
    catch
      _kind, _reason -> :ok
    end

    :ok
  end

  def stop(_state), do: :ok

  @doc false
  # Runs ON the peer node at boot. The process serving a :peer.call is
  # transient, so the long-lived pieces (the contexts agent, the
  # evaluator's task supervisor) hang off an unlinked keeper process
  # that sleeps forever — the whole node dies with the session anyway.
  def bootstrap do
    {:ok, _apps} = Application.ensure_all_started(:explorer)
    caller = self()

    spawn(fn ->
      {:ok, _} = Task.Supervisor.start_link(name: @task_supervisor)
      {:ok, _} = Agent.start_link(fn -> %{} end, name: @contexts)
      send(caller, {:bootstrapped, self()})
      Process.sleep(:infinity)
    end)

    receive do
      {:bootstrapped, _keeper} -> :ok
    after
      15_000 -> {:error, :bootstrap_timeout}
    end
  end

  @doc false
  # Runs ON the peer node, once per evaluate. The session serializes
  # evaluates, so the read-eval-store around the agent never races.
  # Strips value and context from the outcome: contexts stay here,
  # and only node-safe terms cross back.
  def peer_evaluate(ref, source, parents, opts) do
    contexts = Agent.get(@contexts, & &1)
    opts = Keyword.put(opts, :task_supervisor, @task_supervisor)

    case Evaluator.eval(source, Evaluator.parent_context(contexts, parents), opts) do
      {:ok, %{context: context} = ok} ->
        Agent.update(@contexts, &Map.put(&1, ref, context))
        {:ok, Map.take(ok, [:result, :stdout, :stdout_truncated])}

      {:error, error} ->
        {:error, Map.take(error, [:message, :stdout, :stdout_truncated])}
    end
  end

  defp ensure_started(%{peer: pid} = state) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, state}, else: start([])
  end

  defp ensure_started(%{peer: :down}), do: start([])
end
