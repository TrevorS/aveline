defmodule Aveline.Frames.Graph do
  @moduledoc """
  Doc-level frame graph checks, pure. Bindings flow strictly downward
  (Livebook-style): a frame may only reference frames that appear
  EARLIER in the block list, so the graph is acyclic by construction —
  the check is name uniqueness + reference direction.

  Runs against the post-apply block list inside `Docs.apply_ops` — a
  `move_block` can invalidate a previously valid reference, so the
  whole version fails all-or-nothing.
  """

  @doc "The doc's frame blocks, in document order."
  def frames(blocks) when is_list(blocks) do
    Enum.filter(blocks, &(is_map(&1) and &1["type"] == "frame"))
  end

  def frames(_), do: []

  @doc """
  The doc's runnable cells — frame blocks plus elixir code blocks — in
  document order.
  """
  def cells(blocks) when is_list(blocks), do: Enum.filter(blocks, &cell?/1)
  def cells(_), do: []

  defp cell?(%{"type" => "frame"}), do: true
  defp cell?(%{"type" => "code", "language" => "elixir"}), do: true
  defp cell?(_), do: false

  @code_ref_re ~r/\bframe\(\s*"([a-z][a-z0-9_]*)"\s*\)/

  @doc """
  The frame names a code cell consumes via `frame("name")`, extracted
  statically from its source — first-reference order, deduped. v1
  whole-source scanning: a name built at runtime escapes this and only
  affects derived staleness, never execution.
  """
  def code_refs(%{"type" => "code"} = block) do
    @code_ref_re
    |> Regex.scan(block["content"] || "")
    |> Enum.map(fn [_match, name] -> name end)
    |> Enum.uniq()
  end

  def code_refs(_), do: []

  @doc """
  Validate the frame graph of a full block list: names unique per doc,
  every `input.frame` reference resolving to an earlier frame block.
  Returns `:ok` or `{:error, reason}`.
  """
  def validate(blocks) do
    blocks
    |> frames()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn frame, {:ok, seen} ->
      name = frame["name"]

      cond do
        MapSet.member?(seen, name) ->
          {:halt, {:error, "frame name #{inspect(name)} is used more than once in this doc"}}

        ref = upstream_ref(frame) ->
          if MapSet.member?(seen, ref) do
            {:cont, {:ok, MapSet.put(seen, name)}}
          else
            {:halt,
             {:error,
              "frame #{inspect(name)} references #{inspect(ref)}, which is not an earlier frame in this doc — bindings only flow downward"}}
          end

        true ->
          {:cont, {:ok, MapSet.put(seen, name)}}
      end
    end)
    |> case do
      {:ok, _seen} -> :ok
      err -> err
    end
  end

  @doc "The upstream frame name a block consumes, or nil for source inputs."
  def upstream_ref(%{"input" => %{"frame" => name}}) when is_binary(name), do: name
  def upstream_ref(_), do: nil

  @doc """
  The earlier frame block a given frame's `input.frame` points at, or
  nil. `blocks` is the full block list; `frame` must be one of them.
  """
  def upstream_block(blocks, %{"id" => id} = frame) do
    case upstream_ref(frame) do
      nil ->
        nil

      ref ->
        blocks
        |> frames()
        |> Enum.take_while(&(&1["id"] != id))
        |> Enum.find(&(&1["name"] == ref))
    end
  end
end
