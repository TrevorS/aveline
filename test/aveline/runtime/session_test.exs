defmodule Aveline.Runtime.SessionTest do
  @moduledoc """
  Session lifecycle: one process per notebook, contexts accumulating
  down the parent chain, crash-isolated evals, timeout kills that
  leave the session (and its contexts) standing, forget_evaluation GC
  on doc edits, and the idle stop.
  """
  use ExUnit.Case, async: true

  alias Aveline.Broadcasts
  alias Aveline.Runtime.Session

  defp base_id, do: Ecto.UUID.generate()

  defp code_block(id, content),
    do: %{"type" => "code", "language" => "elixir", "id" => id, "content" => content}

  test "ensure/2 is idempotent per notebook" do
    base = base_id()

    assert {:ok, pid} = Session.ensure(base)
    assert {:ok, ^pid} = Session.ensure(base)
    assert Session.whereis(base) == pid

    assert {:ok, other_pid} = Session.ensure(base_id())
    refute other_pid == pid
  end

  test "contexts accumulate through the parent chain" do
    base = base_id()

    assert {:ok, %{result: "1"}} = Session.evaluate(base, "c1", "x = 1")
    assert {:ok, %{result: "3"}} = Session.evaluate(base, "c2", "y = x + 2", parents: ["c1"])
    # The nearest evaluated parent wins; never-evaluated parents are skipped.
    assert {:ok, %{result: "4"}} = Session.evaluate(base, "c4", "x + y", parents: ["c1", "c2", "c3"])
  end

  test "a raising eval is isolated — the session and its contexts survive" do
    base = base_id()

    {:ok, _} = Session.evaluate(base, "c1", "x = 41")
    pid = Session.whereis(base)

    assert {:error, %{message: message}} =
             Session.evaluate(base, "c2", ~s|raise "boom"|, parents: ["c1"])

    assert message =~ "boom"
    assert Session.whereis(base) == pid

    assert {:ok, %{result: "42"}} = Session.evaluate(base, "c3", "x + 1", parents: ["c1", "c2"])
  end

  test "a timed-out eval is killed without taking the session down" do
    base = base_id()
    {:ok, _} = Session.evaluate(base, "c1", "x = 1")
    pid = Session.whereis(base)

    assert {:error, %{message: message}} =
             Session.evaluate(base, "c2", "Process.sleep(:infinity)", timeout_ms: 100)

    assert message =~ "timed out"
    assert Session.whereis(base) == pid
    assert {:ok, %{result: "1"}} = Session.evaluate(base, "c3", "x", parents: ["c1"])
  end

  test "a doc edit that deletes a cell drops its context (forget_evaluation GC)" do
    base = base_id()
    ws_id = Ecto.UUID.generate()

    assert {:ok, %{result: "1"}} = Session.evaluate(base, "c1", "x = 1")

    # An edit that keeps c1 keeps its context...
    Broadcasts.publish_doc_event(:doc_updated, %{
      base_doc_id: base,
      workspace_id: ws_id,
      blocks: [code_block("c1", "x = 1")]
    })

    assert {:ok, %{result: "1"}} = Session.evaluate(base, "c2", "x", parents: ["c1"])

    # ...an edit that deletes it forgets its bindings.
    Broadcasts.publish_doc_event(:doc_updated, %{base_doc_id: base, workspace_id: ws_id, blocks: []})

    assert {:error, %{message: message}} = Session.evaluate(base, "c3", "x", parents: ["c1"])
    assert message =~ "undefined variable"
  end

  test "an idle session stops itself" do
    base = base_id()

    assert {:ok, pid} = Session.ensure(base, idle_timeout_ms: 50)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end
end
