defmodule Aveline.FrameBlockTest do
  @moduledoc """
  Pure validation/normalization of the `frame` block type. The write-path
  behaviour (catalog-query creation, notebook gating) lives in
  Aveline.CellRunsTest; this file only exercises Block.validate/2.
  """
  use ExUnit.Case, async: true

  alias Aveline.Blocks.Block

  describe "query_ref form" do
    test "validates and normalizes, defaulting viz to table" do
      assert {:ok, block} =
               Block.validate(
                 %{"type" => "frame", "name" => "orders", "query_ref" => "orders_by_day"},
                 mint_id?: true
               )

      assert block["type"] == "frame"
      assert block["name"] == "orders"
      assert block["query_ref"] == "orders_by_day"
      assert block["viz"] == %{"type" => "table"}
    end

    test "keeps a line viz with x/y" do
      assert {:ok, block} =
               Block.validate(
                 %{
                   "type" => "frame",
                   "name" => "growth",
                   "query_ref" => "daily",
                   "viz" => %{"type" => "line", "x" => "day", "y" => "n"}
                 },
                 mint_id?: true
               )

      assert block["viz"] == %{"type" => "line", "x" => "day", "y" => "n"}
    end

    test "keeps a scatter viz with x/y and an optional color column" do
      assert {:ok, block} =
               Block.validate(
                 %{
                   "type" => "frame",
                   "name" => "clusters",
                   "query_ref" => "pca",
                   "viz" => %{"type" => "scatter", "x" => "pc1", "y" => "pc2", "color" => "species"}
                 },
                 mint_id?: true
               )

      assert block["viz"] == %{"type" => "scatter", "x" => "pc1", "y" => "pc2", "color" => "species"}
    end

    test "an upper-cased query_ref is rejected (names are lowercase identifiers)" do
      assert {:error, msg} =
               Block.validate(
                 %{"type" => "frame", "name" => "g", "query_ref" => "Daily"},
                 mint_id?: true
               )

      assert msg =~ "query_ref"
    end
  end

  describe "inline query form" do
    test "validates and keeps the SQL (derived, no source)" do
      assert {:ok, block} =
               Block.validate(
                 %{"type" => "frame", "name" => "ones", "query" => "select 1 as one"},
                 mint_id?: true
               )

      assert block["name"] == "ones"
      assert block["query"] == "select 1 as one"
      refute Map.has_key?(block, "source")
      refute Map.has_key?(block, "query_ref")
    end

    test "keeps a source for a raw cell" do
      assert {:ok, %{"query" => "select 1", "source" => "warehouse"}} =
               Block.validate(
                 %{
                   "type" => "frame",
                   "name" => "raw_cell",
                   "query" => "select 1",
                   "source" => "warehouse"
                 },
                 mint_id?: true
               )
    end
  end

  describe "rejections" do
    test "both query_ref and query is invalid" do
      assert {:error, msg} =
               Block.validate(
                 %{"type" => "frame", "name" => "x", "query_ref" => "a", "query" => "select 1"},
                 mint_id?: true
               )

      assert msg =~ "exactly one"
    end

    test "neither query_ref nor query is invalid" do
      assert {:error, msg} =
               Block.validate(%{"type" => "frame", "name" => "x"}, mint_id?: true)

      assert msg =~ "query_ref"
    end

    test "a non-identifier name is invalid" do
      assert {:error, msg} =
               Block.validate(
                 %{"type" => "frame", "name" => "Not A Name", "query_ref" => "a"},
                 mint_id?: true
               )

      assert msg =~ "frame.name"
    end

    test "an empty inline query is invalid" do
      assert {:error, msg} =
               Block.validate(
                 %{"type" => "frame", "name" => "x", "query" => "   "},
                 mint_id?: true
               )

      assert msg =~ "non-empty"
    end
  end

  test "echo fields are stripped on normalization" do
    assert {:ok, block} =
             Block.validate(
               %{
                 "type" => "frame",
                 "name" => "orders",
                 "query_ref" => "orders_by_day",
                 "result" => %{"columns" => ["x"], "rows" => [[1]]},
                 "source" => %{"name" => "sneaky"},
                 "run" => %{"status" => "ok"}
               },
               mint_id?: true
             )

    refute Map.has_key?(block, "result")
    refute Map.has_key?(block, "run")
    # query_ref form carries no source echo.
    refute Map.has_key?(block, "source")
  end

  test "frame is one of the known block types" do
    assert "frame" in Block.types()
  end
end
