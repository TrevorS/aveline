defmodule Aveline.Runtime.Peer do
  @moduledoc """
  A `Runtime.Backend` that would evaluate on an isolated BEAM peer node
  (Livebook's standalone-runtime pattern) — booting a `:peer` node,
  loading the code path, and running each cell there so a cell can neither
  read app process state nor share a scheduler with the web tier.

  Stubbed for a follow-up. `Aveline.Runtime.InProcess` ships first; it is
  the default the session starts. This module documents the seam and fails
  loudly if selected, rather than silently degrading to in-process
  evaluation (which would quietly drop the isolation guarantee).
  """

  @behaviour Aveline.Runtime.Backend

  @impl true
  def init(_opts),
    do: {:error, :not_implemented}

  @impl true
  def eval(_state, _cell_id, _source, _opts),
    do: raise("Aveline.Runtime.Peer is not implemented yet — use Aveline.Runtime.InProcess")
end
