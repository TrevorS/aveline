defmodule Aveline.Runtime.Backend.PeerTest do
  @moduledoc """
  The peer-node substrate for real: boots an isolated BEAM with this
  node's code paths, keeps contexts ON the peer between evals, and
  survives a cell that halts the whole node — the acceptance line an
  in-process eval cannot honor. Node boots are slow, so everything
  shares one boot per test.
  """
  use ExUnit.Case, async: true

  alias Aveline.Runtime.Backend.Peer

  @moduletag timeout: 120_000

  setup do
    # The peer's control process is linked to whoever boots it (in
    # production: the session, which traps exits). Trap here so a
    # halted peer exits toward the test as a message, not a kill.
    Process.flag(:trap_exit, true)
    :ok
  end

  test "evaluates on another OS process, carries context, and outlives System.halt" do
    assert {:ok, state} = Peer.start([])

    {outcome, state} = Peer.evaluate(state, "c1", "x = System.pid()", [], [])
    assert {:ok, %{result: peer_os_pid, stdout: "", stdout_truncated: false}} = outcome
    refute peer_os_pid == inspect(System.pid())

    # The context carries on the peer; stdout comes back captured.
    {outcome, state} =
      Peer.evaluate(state, "c2", ~s|IO.puts("hi")\nx == System.pid()|, ["c1"], [])

    assert {:ok, %{result: "true", stdout: "hi\n"}} = outcome

    # Explorer is preloaded; the rendered dataframe comes back as a
    # string — the NIF resource itself never crosses nodes.
    {outcome, state} = Peer.evaluate(state, "c3", "Explorer.DataFrame.new(a: [1, 2, 3])", [], [])
    assert {:ok, %{result: result}} = outcome
    assert result =~ "Explorer.DataFrame"

    # A cell that halts the node kills only the peer, as an error value...
    {outcome, state} = Peer.evaluate(state, "c4", "System.halt(0)", [], [])
    assert {:error, %{message: message}} = outcome
    assert message =~ "peer runtime node"

    # ...and the next evaluate boots a fresh node with empty contexts.
    {outcome, state} = Peer.evaluate(state, "c5", "1 + 1", [], [])
    assert {:ok, %{result: "2"}} = outcome

    {outcome, state} = Peer.evaluate(state, "c6", "x", ["c1"], [])
    assert {:error, %{message: message}} = outcome
    assert message =~ "undefined variable"

    assert :ok = Peer.stop(state)
  end

  test "prune drops contexts on the peer" do
    assert {:ok, state} = Peer.start([])

    {outcome, state} = Peer.evaluate(state, "c1", "x = 1", [], [])
    assert {:ok, _} = outcome

    state = Peer.prune(state, [])

    {outcome, state} = Peer.evaluate(state, "c2", "x", ["c1"], [])
    assert {:error, %{message: message}} = outcome
    assert message =~ "undefined variable"

    assert :ok = Peer.stop(state)
  end
end
