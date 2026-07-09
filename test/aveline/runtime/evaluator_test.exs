defmodule Aveline.Runtime.EvaluatorTest do
  @moduledoc """
  The eval mechanics in isolation: values + rendered results, the
  context (bindings AND env) accumulating across evals, group-leader
  stdout capture with the truncation flag, every raise/throw/exit
  caught as an error value, the brutal-kill timeout (with stdout
  captured before the kill surviving it), and the injected frame/1
  bridge.
  """
  use ExUnit.Case, async: true

  alias Aveline.Runtime.Evaluator

  test "returns the value, its rendered result, and the accumulated context" do
    ctx = Evaluator.initial_context()

    assert {:ok, %{value: 1, result: "1", stdout: "", context: ctx}} =
             Evaluator.eval("x = 1", ctx)

    assert {:ok, %{value: 3, result: "3", context: ctx}} = Evaluator.eval("y = x + 2", ctx)
    assert ctx.binding[:x] == 1
    assert ctx.binding[:y] == 3
  end

  test "the env carries too — an alias made in one cell applies to the next" do
    ctx = Evaluator.initial_context()

    assert {:ok, %{context: ctx}} =
             Evaluator.eval("alias Explorer.DataFrame, as: DF\nimport Bitwise", ctx)

    assert {:ok, %{value: 2, result: "2"}} =
             Evaluator.eval("DF.new(a: [1, 2]) |> DF.n_rows() |> band(255)", ctx)
  end

  test "captures stdout via the swapped group leader" do
    assert {:ok, %{value: :ok, stdout: "hello\nworld\n", stdout_truncated: false}} =
             Evaluator.eval(~s|IO.puts("hello")\nIO.puts("world")|, Evaluator.initial_context())
  end

  test "stdout past the cap is truncated AND flagged" do
    assert {:ok, %{stdout: stdout, stdout_truncated: true}} =
             Evaluator.eval(
               ~s|IO.write(String.duplicate("a", 70_000))|,
               Evaluator.initial_context()
             )

    assert String.ends_with?(stdout, "(stdout truncated)")
  end

  test "a raise is an error value, not a crash" do
    assert {:error, %{message: message}} =
             Evaluator.eval(~s|raise "boom"|, Evaluator.initial_context())

    assert message =~ "RuntimeError"
    assert message =~ "boom"
  end

  test "throws, exits, and compile errors are error values too" do
    ctx = Evaluator.initial_context()

    assert {:error, %{message: m1}} = Evaluator.eval("throw :ball", ctx)
    assert m1 =~ "ball"

    assert {:error, %{message: m2}} = Evaluator.eval("exit :bye", ctx)
    assert m2 =~ "bye"

    assert {:error, %{message: m3}} = Evaluator.eval("1 +", ctx)
    assert is_binary(m3) and m3 != ""
  end

  test "a hung eval is killed at the timeout; stdout survives the kill" do
    assert {:error, %{message: message, stdout: stdout}} =
             Evaluator.eval(
               ~s|IO.puts("before")\nProcess.sleep(:infinity)|,
               Evaluator.initial_context(),
               timeout_ms: 100
             )

    assert message =~ "timed out"
    assert stdout =~ "before"
  end

  test "frame/1 resolves through the injected resolver into a dataframe" do
    resolver = fn
      "orders" -> {:ok, %{"columns" => ["region", "amount"], "rows" => [["emea", 50], ["amer", 250]]}}
      other -> {:error, "no frame named #{inspect(other)} above this cell"}
    end

    assert {:ok, %{value: 2}} =
             Evaluator.eval(
               ~s{frame("orders") |> Explorer.DataFrame.n_rows()},
               Evaluator.initial_context(),
               frame_resolver: resolver
             )

    # A miss raises inside the cell — an error value out here.
    assert {:error, %{message: message}} =
             Evaluator.eval(~s{frame("ghost")}, Evaluator.initial_context(), frame_resolver: resolver)

    assert message =~ "ghost"
  end

  test "frame/1 without a resolver is an error value" do
    assert {:error, %{message: message}} =
             Evaluator.eval(~s{frame("orders")}, Evaluator.initial_context())

    assert message =~ "notebook code cell"
  end
end
