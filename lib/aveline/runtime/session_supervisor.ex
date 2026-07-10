defmodule Aveline.Runtime.SessionSupervisor do
  @moduledoc """
  DynamicSupervisor for notebook evaluation sessions. One
  `Runtime.Session` child per open notebook, started on demand by
  `Aveline.Runtime.session/2` and dropped when it idle-stops (sessions are
  `restart: :temporary`, so a normal or crashed exit removes the child
  rather than respawning it with lost state).
  """

  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Start a session child for `base_doc_id`, or return the running one."
  def start_session(opts) do
    case DynamicSupervisor.start_child(__MODULE__, {Aveline.Runtime.Session, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end
end
