defmodule Aveline.Frames.ExecutorTest do
  @moduledoc """
  The Explorer edge, exercised against in-memory columns/rows inputs —
  no database. Every failure must come back as an error value; the
  executor may never raise into (or crash) its caller.
  """
  use ExUnit.Case, async: true

  alias Aveline.Frames.Executor

  defp input do
    %{
      "columns" => ["region", "amount", "profit"],
      "rows" => [
        ["emea", 50, 5],
        ["emea", 150, 30],
        ["amer", 250, 100],
        ["amer", 400, 120],
        ["apac", 90, 9]
      ]
    }
  end

  test "the full pipeline: filter, mutate, group/summarise, sort" do
    ops = [
      %{"op" => "filter", "expr" => %{"gt" => [%{"col" => "amount"}, %{"lit" => 100}]}},
      %{"op" => "mutate", "name" => "margin", "expr" => %{"div" => [%{"col" => "profit"}, %{"col" => "amount"}]}},
      %{"op" => "group_by", "columns" => ["region"]},
      %{"op" => "summarise", "aggs" => [%{"name" => "total", "fn" => "sum", "col" => "amount"}]},
      %{"op" => "sort", "by" => [%{"col" => "total", "dir" => "desc"}]}
    ]

    assert {:ok, out} = Executor.run(input(), ops)
    assert out["columns"] == ["region", "total"]
    assert out["rows"] == [["amer", 650], ["emea", 150]]
    refute Map.has_key?(out, "truncated")
  end

  test "whole-frame summarise, select, head, and column order" do
    assert {:ok, out} =
             Executor.run(input(), [
               %{
                 "op" => "summarise",
                 "aggs" => [
                   %{"name" => "n", "fn" => "count", "col" => "region"},
                   %{"name" => "avg_amount", "fn" => "mean", "col" => "amount"},
                   %{"name" => "min_amount", "fn" => "min", "col" => "amount"},
                   %{"name" => "max_amount", "fn" => "max", "col" => "amount"}
                 ]
               }
             ])

    assert out["columns"] == ["n", "avg_amount", "min_amount", "max_amount"]
    assert out["rows"] == [[5, 188.0, 50, 400]]

    assert {:ok, out} =
             Executor.run(input(), [
               %{"op" => "select", "columns" => ["profit", "region"]},
               %{"op" => "head", "n" => 2}
             ])

    assert out["columns"] == ["profit", "region"]
    assert out["rows"] == [[5, "emea"], [30, "emea"]]

    # No ops: the input passes through with its column order intact.
    assert {:ok, out} = Executor.run(input(), [])
    assert out["columns"] == ["region", "amount", "profit"]
    assert length(out["rows"]) == 5
  end

  test "boolean expressions: and / or / not / string equality" do
    ops = [
      %{
        "op" => "filter",
        "expr" => %{
          "and" => [
            %{"not" => %{"eq" => [%{"col" => "region"}, %{"lit" => "emea"}]}},
            %{
              "or" => [
                %{"gte" => [%{"col" => "amount"}, %{"lit" => 400}]},
                %{"lte" => [%{"col" => "amount"}, %{"lit" => 90}]}
              ]
            }
          ]
        }
      },
      %{"op" => "select", "columns" => ["region", "amount"]}
    ]

    assert {:ok, out} = Executor.run(input(), ops)
    assert out["rows"] == [["amer", 400], ["apac", 90]]
  end

  test "output caps at 500 rows with a truncated flag" do
    big = %{"columns" => ["n"], "rows" => Enum.map(1..600, &[&1])}

    assert {:ok, out} = Executor.run(big, [])
    assert length(out["rows"]) == Executor.output_row_cap()
    assert out["truncated"] == true
  end

  test "non-finite floats become nil cells (JSON has no Infinity)" do
    zero = %{"columns" => ["a", "b"], "rows" => [[1, 0]]}

    ops = [
      %{"op" => "mutate", "name" => "q", "expr" => %{"div" => [%{"col" => "a"}, %{"col" => "b"}]}}
    ]

    assert {:ok, %{"rows" => [[1, 0, nil]]}} = Executor.run(zero, ops)
  end

  test "failures are error values, never raises" do
    # Unknown column.
    assert {:error, msg} =
             Executor.run(input(), [
               %{"op" => "filter", "expr" => %{"gt" => [%{"col" => "ghost"}, %{"lit" => 1}]}}
             ])

    assert msg =~ "frame execution failed"

    # Mixed types in one input column.
    mixed = %{"columns" => ["x"], "rows" => [[1], ["two"]]}
    assert {:error, _} = Executor.run(mixed, [])

    # Type mismatch inside an expression (string > int comparison).
    assert {:error, _} =
             Executor.run(input(), [
               %{"op" => "filter", "expr" => %{"gt" => [%{"col" => "region"}, %{"lit" => 1}]}}
             ])

    # Duplicate / missing columns in the input shape.
    assert {:error, msg} = Executor.run(%{"columns" => ["a", "a"], "rows" => [[1, 2]]}, [])
    assert msg =~ "duplicate column"

    assert {:error, msg} = Executor.run(%{"columns" => [], "rows" => []}, [])
    assert msg =~ "no columns"

    # Not a columns/rows result at all.
    assert {:error, _} = Executor.run(%{"error" => "upstream said no"}, [])
    assert {:error, _} = Executor.run(nil, [])
  end
end
