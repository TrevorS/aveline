defmodule Aveline.FramesTest do
  @moduledoc """
  The frame cell language, pure: expression AST, per-op shapes, whole-
  pipeline legality + schema threading, the doc-level name graph, and
  the frame block's validation (including echo stripping). No DB, no
  Explorer.
  """
  use ExUnit.Case, async: true

  alias Aveline.Blocks.Block
  alias Aveline.Frames.Expr
  alias Aveline.Frames.Graph
  alias Aveline.Frames.Op
  alias Aveline.Frames.Pipeline

  # ===== Expr =====

  describe "Expr.validate/1" do
    test "col, lit, and every operator normalize" do
      assert {:ok, %{"col" => "amount"}} = Expr.validate(%{"col" => "amount"})

      for lit <- [1, 1.5, "s", true, false, nil] do
        assert {:ok, %{"lit" => ^lit}} = Expr.validate(%{"lit" => lit})
      end

      for op <- ~w(add sub mul div eq neq gt gte lt lte and or) do
        expr = %{op => [%{"col" => "a"}, %{"lit" => 1}]}
        assert {:ok, ^expr} = Expr.validate(expr)
      end

      assert {:ok, %{"not" => %{"col" => "flag"}}} = Expr.validate(%{"not" => %{"col" => "flag"}})
    end

    test "nesting normalizes recursively and junk keys are rejected" do
      expr = %{
        "and" => [
          %{"gt" => [%{"col" => "amount"}, %{"lit" => 100}]},
          %{"not" => %{"eq" => [%{"col" => "region"}, %{"lit" => "emea"}]}}
        ]
      }

      assert {:ok, ^expr} = Expr.validate(expr)

      assert {:error, msg} = Expr.validate(%{"col" => "a", "extra" => 1})
      assert msg =~ "exactly one key"

      assert {:error, msg} = Expr.validate(%{"pow" => [%{"col" => "a"}, %{"lit" => 2}]})
      assert msg =~ "unknown expression op"
    end

    test "bad shapes are errors, not raises" do
      assert {:error, _} = Expr.validate("amount")
      assert {:error, _} = Expr.validate(nil)
      assert {:error, _} = Expr.validate(%{})
      assert {:error, msg} = Expr.validate(%{"add" => [%{"col" => "a"}]})
      assert msg =~ "exactly two operands"
      assert {:error, _} = Expr.validate(%{"col" => ""})
      assert {:error, _} = Expr.validate(%{"col" => 42})
      assert {:error, msg} = Expr.validate(%{"lit" => %{"nested" => true}})
      assert msg =~ "lit must be"
    end

    test "depth cap" do
      deep =
        Enum.reduce(1..Expr.max_depth(), %{"col" => "a"}, fn _, inner ->
          %{"not" => inner}
        end)

      assert {:error, msg} = Expr.validate(deep)
      assert msg =~ "too deep"

      # One level shallower fits exactly.
      ok = Enum.reduce(1..(Expr.max_depth() - 1), %{"col" => "a"}, fn _, e -> %{"not" => e} end)
      assert {:ok, _} = Expr.validate(ok)
    end

    test "node cap" do
      # A balanced boolean tree: 6 levels of binary ors = 127 nodes at
      # depth 7 — inside the depth cap, over the node cap.
      leaf = %{"lit" => true}
      tree = Enum.reduce(1..6, leaf, fn _, t -> %{"or" => [t, t]} end)

      assert {:error, msg} = Expr.validate(tree)
      assert msg =~ "too large"
    end

    test "columns/1 collects referenced names" do
      expr = %{
        "and" => [
          %{"gt" => [%{"col" => "amount"}, %{"lit" => 100}]},
          %{"eq" => [%{"col" => "region"}, %{"col" => "amount"}]}
        ]
      }

      assert Expr.columns(expr) == ["amount", "region"]
      assert Expr.columns(%{"lit" => 1}) == []
    end
  end

  # ===== Op =====

  describe "Op.validate/1" do
    test "every op normalizes and strips junk fields" do
      assert {:ok, %{"op" => "filter", "expr" => %{"col" => "a"}}} =
               Op.validate(%{"op" => "filter", "expr" => %{"col" => "a"}, "junk" => 1})

      assert {:ok, %{"op" => "mutate", "name" => "margin", "expr" => _}} =
               Op.validate(%{
                 "op" => "mutate",
                 "name" => "margin",
                 "expr" => %{"div" => [%{"col" => "profit"}, %{"col" => "revenue"}]}
               })

      assert {:ok, %{"op" => "group_by", "columns" => ["region"]}} =
               Op.validate(%{"op" => "group_by", "columns" => ["region"]})

      assert {:ok, %{"op" => "summarise", "aggs" => [%{"name" => "total", "fn" => "sum", "col" => "amount"}]}} =
               Op.validate(%{
                 "op" => "summarise",
                 "aggs" => [%{"name" => "total", "fn" => "sum", "col" => "amount", "junk" => 1}]
               })

      # dir defaults to asc
      assert {:ok, %{"op" => "sort", "by" => [%{"col" => "total", "dir" => "asc"}]}} =
               Op.validate(%{"op" => "sort", "by" => [%{"col" => "total"}]})

      assert {:ok, %{"op" => "select", "columns" => ["a", "b"]}} =
               Op.validate(%{"op" => "select", "columns" => ["a", "b"]})

      assert {:ok, %{"op" => "head", "n" => 10}} = Op.validate(%{"op" => "head", "n" => 10})
    end

    test "bad shapes per op" do
      assert {:error, _} = Op.validate(%{"op" => "filter"})
      assert {:error, msg} = Op.validate(%{"op" => "mutate", "name" => "Bad Name", "expr" => %{"col" => "a"}})
      assert msg =~ "snake_case"
      assert {:error, _} = Op.validate(%{"op" => "group_by", "columns" => []})

      assert {:error, msg} =
               Op.validate(%{"op" => "summarise", "aggs" => [%{"name" => "t", "fn" => "median", "col" => "a"}]})

      assert msg =~ "agg.fn"
      assert {:error, msg} = Op.validate(%{"op" => "sort", "by" => [%{"col" => "a", "dir" => "sideways"}]})
      assert msg =~ "asc"
      assert {:error, _} = Op.validate(%{"op" => "head", "n" => 0})
      assert {:error, _} = Op.validate(%{"op" => "head", "n" => "10"})
      assert {:error, msg} = Op.validate(%{"op" => "pivot"})
      assert msg =~ "unknown frame op"
      assert {:error, _} = Op.validate("filter")
    end
  end

  # ===== Pipeline =====

  describe "Pipeline.validate/1" do
    test "the frames-TIP example pipeline validates" do
      ops = [
        %{"op" => "filter", "expr" => %{"gt" => [%{"col" => "amount"}, %{"lit" => 100}]}},
        %{"op" => "mutate", "name" => "margin", "expr" => %{"div" => [%{"col" => "profit"}, %{"col" => "revenue"}]}},
        %{"op" => "group_by", "columns" => ["region"]},
        %{"op" => "summarise", "aggs" => [%{"name" => "total", "fn" => "sum", "col" => "amount"}]},
        %{"op" => "sort", "by" => [%{"col" => "total", "dir" => "desc"}]}
      ]

      assert {:ok, ^ops} = Pipeline.validate(ops)
    end

    test "ops cap" do
      op = %{"op" => "head", "n" => 1}
      assert {:ok, _} = Pipeline.validate(List.duplicate(op, Pipeline.max_ops()))
      assert {:error, msg} = Pipeline.validate(List.duplicate(op, Pipeline.max_ops() + 1))
      assert msg =~ "too many ops"
    end

    test "group_by must be immediately followed by summarise; bare summarise is whole-frame" do
      assert {:error, msg} =
               Pipeline.validate([%{"op" => "group_by", "columns" => ["region"]}])

      assert msg =~ "immediately followed by summarise"

      assert {:error, _} =
               Pipeline.validate([
                 %{"op" => "group_by", "columns" => ["region"]},
                 %{"op" => "head", "n" => 5}
               ])

      assert {:ok, _} =
               Pipeline.validate([
                 %{"op" => "summarise", "aggs" => [%{"name" => "n", "fn" => "count", "col" => "id"}]}
               ])
    end

    test "an invalid op fails the whole pipeline" do
      assert {:error, _} =
               Pipeline.validate([
                 %{"op" => "head", "n" => 1},
                 %{"op" => "filter"}
               ])
    end
  end

  describe "Pipeline.schema/2 threading" do
    test "unknown source columns thread until summarise/select pin the set" do
      ops = [
        %{"op" => "filter", "expr" => %{"gt" => [%{"col" => "amount"}, %{"lit" => 1}]}},
        %{"op" => "group_by", "columns" => ["region"]},
        %{"op" => "summarise", "aggs" => [%{"name" => "total", "fn" => "sum", "col" => "amount"}]}
      ]

      assert {:ok, ["region", "total"]} = Pipeline.schema(:unknown, ops)
    end

    test "references after a pinned set are checked concretely" do
      ops = [
        %{"op" => "select", "columns" => ["region"]},
        %{"op" => "filter", "expr" => %{"gt" => [%{"col" => "amount"}, %{"lit" => 1}]}}
      ]

      assert {:error, msg} = Pipeline.schema(["region", "amount"], ops)
      assert msg =~ "filter references unknown column(s): amount"

      # ...and validate/1 catches it even from an unknown start, because
      # select pins the set mid-pipeline.
      assert {:error, _} = Pipeline.validate(ops)
    end

    test "mutate adds its column to a known set" do
      ops = [
        %{"op" => "mutate", "name" => "margin", "expr" => %{"div" => [%{"col" => "p"}, %{"col" => "r"}]}},
        %{"op" => "sort", "by" => [%{"col" => "margin"}]}
      ]

      assert {:ok, ["p", "r", "margin"]} = Pipeline.schema(["p", "r"], ops)
      assert {:error, msg} = Pipeline.schema(["p"], ops)
      assert msg =~ "mutate references unknown column(s): r"
    end
  end

  # ===== Graph =====

  describe "Graph.validate/1" do
    defp frame_block(id, name, input) do
      %{"id" => id, "type" => "frame", "name" => name, "input" => input, "ops" => []}
    end

    test "unique names + upward refs pass; non-frame blocks are ignored" do
      blocks = [
        %{"id" => "b_h", "type" => "heading", "level" => 1, "text" => "hi"},
        frame_block("b_1", "orders", %{"data_source_id" => "x", "query" => "select 1"}),
        frame_block("b_2", "big_orders", %{"frame" => "orders"})
      ]

      assert :ok = Graph.validate(blocks)
    end

    test "duplicate names rejected" do
      blocks = [
        frame_block("b_1", "orders", %{"data_source_id" => "x", "query" => "select 1"}),
        frame_block("b_2", "orders", %{"data_source_id" => "x", "query" => "select 2"})
      ]

      assert {:error, msg} = Graph.validate(blocks)
      assert msg =~ "more than once"
    end

    test "forward and dangling refs rejected — bindings flow downward" do
      # b_1 references a frame defined AFTER it.
      blocks = [
        frame_block("b_1", "big_orders", %{"frame" => "orders"}),
        frame_block("b_2", "orders", %{"data_source_id" => "x", "query" => "select 1"})
      ]

      assert {:error, msg} = Graph.validate(blocks)
      assert msg =~ "not an earlier frame"

      assert {:error, _} = Graph.validate([frame_block("b_1", "a", %{"frame" => "ghost"})])
      # Self-reference is just a forward ref to itself.
      assert {:error, _} = Graph.validate([frame_block("b_1", "a", %{"frame" => "a"})])
    end

    test "upstream_block/2 finds the earlier frame by name" do
      a = frame_block("b_1", "orders", %{"data_source_id" => "x", "query" => "select 1"})
      b = frame_block("b_2", "big", %{"frame" => "orders"})

      assert Graph.upstream_block([a, b], b) == a
      assert Graph.upstream_block([a, b], a) == nil
    end
  end

  # ===== Block validation =====

  describe "frame block validation" do
    test "valid frame normalizes; echo fields are stripped" do
      uuid = Ecto.UUID.generate()

      assert {:ok, out} =
               Block.validate(
                 %{
                   "type" => "frame",
                   "name" => "high_value_orders",
                   "input" => %{"data_source_id" => uuid, "query" => "select * from orders"},
                   "ops" => [%{"op" => "filter", "expr" => %{"gt" => [%{"col" => "amount"}, %{"lit" => 100}]}}],
                   "viz" => %{"type" => "bar", "x" => "region", "y" => "total", "junk" => 1},
                   "result" => %{"rows" => [["forged"]]},
                   "schema" => ["forged"],
                   "source" => %{"name" => "forged"}
                 },
                 mint_id?: true
               )

      assert out["name"] == "high_value_orders"
      assert out["input"] == %{"data_source_id" => uuid, "query" => "select * from orders"}
      assert out["viz"] == %{"type" => "bar", "x" => "region", "y" => "total"}
      refute Map.has_key?(out, "result")
      refute Map.has_key?(out, "schema")
      refute Map.has_key?(out, "source")
    end

    test "ops default to [] and viz defaults to table" do
      uuid = Ecto.UUID.generate()

      assert {:ok, out} =
               Block.validate(
                 %{
                   "type" => "frame",
                   "name" => "orders",
                   "input" => %{"data_source_id" => uuid, "query" => "select 1"}
                 },
                 mint_id?: true
               )

      assert out["ops"] == []
      assert out["viz"] == %{"type" => "table"}
    end

    test "input is source-query XOR frame" do
      uuid = Ecto.UUID.generate()

      assert {:ok, out} =
               Block.validate(
                 %{"type" => "frame", "name" => "big", "input" => %{"frame" => "orders"}},
                 mint_id?: true
               )

      assert out["input"] == %{"frame" => "orders"}

      assert {:error, msg} =
               Block.validate(
                 %{
                   "type" => "frame",
                   "name" => "big",
                   "input" => %{"data_source_id" => uuid, "query" => "select 1", "frame" => "orders"}
                 },
                 mint_id?: true
               )

      assert msg =~ "not both"

      assert {:error, msg} =
               Block.validate(
                 %{"type" => "frame", "name" => "big", "input" => %{}},
                 mint_id?: true
               )

      assert msg =~ "frame.input"
    end

    test "name must be snake_case; query caps mirror chart" do
      uuid = Ecto.UUID.generate()
      input = %{"data_source_id" => uuid, "query" => "select 1"}

      for bad <- ["Orders", "1orders", "or ders", "", String.duplicate("a", 65)] do
        assert {:error, msg} =
                 Block.validate(%{"type" => "frame", "name" => bad, "input" => input}, mint_id?: true)

        assert msg =~ "snake_case"
      end

      assert {:error, msg} =
               Block.validate(
                 %{"type" => "frame", "name" => "a", "input" => %{"data_source_id" => uuid, "query" => "  "}},
                 mint_id?: true
               )

      assert msg =~ "blank"

      assert {:error, msg} =
               Block.validate(
                 %{
                   "type" => "frame",
                   "name" => "a",
                   "input" => %{"data_source_id" => uuid, "query" => String.duplicate("x", 10_001)}
                 },
                 mint_id?: true
               )

      assert msg =~ "too long"
    end

    test "viz grammar is shared with chart" do
      uuid = Ecto.UUID.generate()
      base = %{"type" => "frame", "name" => "a", "input" => %{"data_source_id" => uuid, "query" => "select 1"}}

      assert {:error, msg} = Block.validate(Map.put(base, "viz", %{"type" => "pie"}), mint_id?: true)
      assert msg =~ "viz.type"

      assert {:error, msg} = Block.validate(Map.put(base, "viz", %{"type" => "line"}), mint_id?: true)
      assert msg =~ "needs x and y"
    end
  end
end
