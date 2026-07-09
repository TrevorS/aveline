defmodule Aveline.Blocks.Block do
  @moduledoc """
  Block validation + normalization.

  Blocks live inside `docs.blocks` (jsonb). This module is pure — no Repo,
  no Ecto. Given a map (typically decoded from a JSON request body), it
  returns `{:ok, normalized}` (string keys, deterministic field order) or
  `{:error, reason}`.

  v0 block types:
    * `heading`   — `%{type, level (1-3), text}` (plain text, no inline)
    * `paragraph` — `%{type, content: [<inline span>]}`
    * `code`      — `%{type, language: string|null, content: string,
      name?}` — a fenced snippet anywhere; in a notebook, an elixir
      code block is also an executable cell (Runs evaluates `content`
      in the notebook's runtime session, local deployments only) and
      `name` is an optional snake_case label. Outputs live in
      cell_runs — never on the block.
    * `list`      — `%{type, ordered: bool, items: [%{id, content: [<inline>]}]}`
    * `table`     — `%{type, headers: [string], rows: [[ [<inline>] ]]}`
    * `doc_link`  — `%{type, doc_id: uuid, note?: [<inline>]}` — an ordered
      reference to another doc in the same workspace. A doc whose body
      chains doc_links is a story/trail. The API also accepts `doc` (a
      slug); the Docs context resolves it to `doc_id` before validation
      reaches here, and verifies the target exists in the workspace.
    * `chart`     — `%{type, data_source_id: uuid, query: sql, viz}` — a
      live query against a workspace data source. `viz` is
      `%{"type" => "table" | "line" | "bar", "x" => col?, "y" => col?}`
      (x/y required for line/bar). The API also accepts `source` (a
      data source name); the Docs context resolves it to the source's
      base id and verifies it exists in the workspace. Reads gain a
      computed `result` (columns/rows or error) — never persisted.
    * `frame`     — `%{type, name, input, ops, viz?}` — a notebook cell:
      a named dataframe whose `input` is a data-source query
      (`%{"data_source_id", "query"}`, with `input.source` name
      resolution mirroring chart) XOR an earlier frame in the same doc
      (`%{"frame" => name}`), transformed by a declarative op pipeline
      (see `Aveline.Frames`). `viz` reuses the chart grammar. Frame
      blocks are notebook-only and their name graph is checked by the
      Docs context. Outputs live in cell_runs — never on the block; the
      `result` / `schema` / `source` echoes are not fields here, so
      pasted echoes strip on rewrite.

  Docs can also be linked inline: any span (paragraph, list item, table
  cell, doc_link note) may carry `link: %{doc_id}` — same write-time
  resolution and read-time target echo as the doc_link block, but as a
  mention in prose instead of a card. See `Aveline.Blocks.Inline`.

  Every block has an `id` (`b_<22>` for blocks, `li_<22>` for list items)
  and an optional `metadata` map (free-form jsonb).
  """

  alias Aveline.Blocks.Id
  alias Aveline.Blocks.Inline

  @types ~w(heading paragraph code list table doc_link chart frame)

  @uuid_re ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  @max_frame_name 64
  @frame_name_re ~r/^[a-z][a-z0-9_]*$/

  @doc "Returns the list of supported block types."
  def types, do: @types

  @doc """
  Validate and normalize a block. Mints an `id` if one isn't supplied (only
  for internal callers — the API/CLI surface always lets the server mint).

  Returns `{:ok, normalized}` or `{:error, reason_string}`.
  """
  def validate(block, opts \\ [])

  def validate(%{} = block, opts) do
    mint_id? = Keyword.get(opts, :mint_id?, false)

    with {:ok, type} <- validate_type(block),
         {:ok, id} <- validate_or_mint_id(block, mint_id?),
         {:ok, metadata} <- validate_metadata(block),
         {:ok, type_fields} <- validate_type_fields(type, block) do
      out =
        %{"id" => id, "type" => type}
        |> Map.merge(type_fields)
        |> maybe_put_metadata(metadata)

      {:ok, out}
    end
  end

  def validate(_, _), do: {:error, "block must be an object"}

  @doc """
  Validate a partial patch (used by `modify_block`). Only fields present in
  the patch are validated; the rest are left untouched on apply. `type` and
  `id` cannot be changed by a patch.
  """
  def validate_patch(existing_block, %{} = patch) do
    type = Map.fetch!(existing_block, "type")

    cond do
      Map.has_key?(patch, "type") and patch["type"] != type ->
        {:error, "cannot change block type via modify_block; delete + insert instead"}

      Map.has_key?(patch, "id") ->
        {:error, "cannot change block id via modify_block"}

      true ->
        # Build a synthetic full block (existing merged with patch) and revalidate.
        merged = Map.merge(existing_block, Map.delete(patch, "type"))

        case validate(merged) do
          {:ok, normalized} -> {:ok, normalized}
          err -> err
        end
    end
  end

  # ===== Internal: type-specific validators =====

  defp validate_type(%{"type" => t}) when t in @types, do: {:ok, t}

  defp validate_type(%{"type" => t}) when is_binary(t),
    do: {:error, "unknown block type #{inspect(t)}; expected one of #{inspect(@types)}"}

  defp validate_type(_), do: {:error, "block.type required"}

  defp validate_or_mint_id(%{"id" => id}, _) when is_binary(id) do
    if Id.valid_block_id?(id),
      do: {:ok, id},
      else: {:error, "block.id must start with b_"}
  end

  defp validate_or_mint_id(%{}, true), do: {:ok, Id.mint_block()}
  defp validate_or_mint_id(%{}, false), do: {:error, "block.id required"}

  defp validate_metadata(%{"metadata" => m}) when is_map(m), do: {:ok, m}
  defp validate_metadata(%{"metadata" => nil}), do: {:ok, nil}
  defp validate_metadata(%{"metadata" => _}), do: {:error, "block.metadata must be an object"}
  defp validate_metadata(%{}), do: {:ok, nil}

  defp maybe_put_metadata(map, nil), do: map
  defp maybe_put_metadata(map, m) when m == %{}, do: map
  defp maybe_put_metadata(map, m), do: Map.put(map, "metadata", m)

  # heading
  defp validate_type_fields("heading", %{"level" => level, "text" => text})
       when level in [1, 2, 3] and is_binary(text) do
    {:ok, %{"level" => level, "text" => text}}
  end

  defp validate_type_fields("heading", _) do
    {:error, "heading requires level (1-3) and text (string)"}
  end

  # paragraph
  defp validate_type_fields("paragraph", %{"content" => content}) do
    case Inline.validate_spans(content) do
      {:ok, normalized} -> {:ok, %{"content" => normalized}}
      err -> err
    end
  end

  defp validate_type_fields("paragraph", _) do
    {:error, "paragraph requires content (list of inline spans)"}
  end

  # code — also a notebook cell when the language is elixir; `name` is
  # an optional label there and harmless anywhere else.
  defp validate_type_fields("code", %{"content" => content} = block) when is_binary(content) do
    lang =
      case Map.get(block, "language") do
        nil -> nil
        "" -> nil
        s when is_binary(s) -> s
        _ -> :error
      end

    name = Map.get(block, "name")

    cond do
      lang == :error ->
        {:error, "code.language must be a string or null"}

      name != nil and not valid_frame_name?(name) ->
        {:error, "code.name must be a snake_case identifier (max #{@max_frame_name} chars)"}

      true ->
        out = %{"content" => content, "language" => lang}
        {:ok, if(name, do: Map.put(out, "name", name), else: out)}
    end
  end

  defp validate_type_fields("code", _) do
    {:error, "code requires content (string)"}
  end

  # list
  defp validate_type_fields("list", %{"items" => items} = block) when is_list(items) do
    ordered = Map.get(block, "ordered", false)

    if not is_boolean(ordered) do
      {:error, "list.ordered must be a boolean"}
    else
      case validate_list_items(items) do
        {:ok, normalized} -> {:ok, %{"ordered" => ordered, "items" => normalized}}
        err -> err
      end
    end
  end

  defp validate_type_fields("list", _), do: {:error, "list requires items (list)"}

  # table
  defp validate_type_fields("table", %{"headers" => headers, "rows" => rows})
       when is_list(headers) and is_list(rows) do
    cond do
      Enum.any?(headers, fn h -> not is_binary(h) end) ->
        {:error, "table.headers must be a list of strings"}

      Enum.any?(rows, fn r -> not is_list(r) end) ->
        {:error, "table.rows must be a list of lists of cells"}

      Enum.any?(rows, fn r -> length(r) != length(headers) end) ->
        {:error, "every table row must have the same length as headers"}

      true ->
        case validate_table_rows(rows) do
          {:ok, normalized} -> {:ok, %{"headers" => headers, "rows" => normalized}}
          err -> err
        end
    end
  end

  defp validate_type_fields("table", _) do
    {:error, "table requires headers (list of strings) and rows (list of cell lists)"}
  end

  # doc_link — `target` (the read-time echo) is intentionally not a field
  # here: normalization rebuilds the block from known fields only, so an
  # echoed block pasted back into a write is stripped of it automatically.
  defp validate_type_fields("doc_link", %{"doc_id" => doc_id} = block) when is_binary(doc_id) do
    cond do
      not Regex.match?(@uuid_re, doc_id) ->
        {:error,
         "doc_link.doc_id must be a UUID (the target's base_doc_id); or pass doc: <slug> and the server resolves it"}

      true ->
        case Map.get(block, "note") do
          nil ->
            {:ok, %{"doc_id" => String.downcase(doc_id)}}

          spans ->
            case Inline.validate_spans(spans) do
              {:ok, []} -> {:ok, %{"doc_id" => String.downcase(doc_id)}}
              {:ok, normalized} -> {:ok, %{"doc_id" => String.downcase(doc_id), "note" => normalized}}
              err -> err
            end
        end
    end
  end

  defp validate_type_fields("doc_link", _) do
    {:error, "doc_link requires doc_id (target base_doc_id) or doc (target slug, resolved server-side)"}
  end

  # chart — a live SQL query against a workspace data source. The
  # computed `result` / `source` echoes are not fields here, so pasted
  # echoes are stripped on rewrite.
  defp validate_type_fields("chart", %{"data_source_id" => ds_id, "query" => query} = block)
       when is_binary(ds_id) and is_binary(query) do
    cond do
      not Regex.match?(@uuid_re, ds_id) ->
        {:error,
         "chart.data_source_id must be a UUID (the source's base id); or pass source: <name> and the server resolves it"}

      String.trim(query) == "" ->
        {:error, "chart.query cannot be blank"}

      String.length(query) > 10_000 ->
        {:error, "chart.query too long (10k max)"}

      true ->
        with {:ok, clean_viz} <- validate_viz(Map.get(block, "viz", %{"type" => "table"})) do
          {:ok,
           %{
             "data_source_id" => String.downcase(ds_id),
             "query" => query,
             "viz" => clean_viz
           }}
        end
    end
  end

  defp validate_type_fields("chart", _) do
    {:error,
     "chart requires data_source_id (source base id, or source: <name> resolved server-side), query (SQL), and optional viz"}
  end

  # frame — a notebook cell. Shape only: the name graph (unique names,
  # refs pointing upward) needs the whole doc and the doc's kind, so it
  # lives in the Docs context; execution lives in cell runs. The
  # captured `result` / `schema` / `source` echoes are not fields here,
  # so pasted echoes strip on rewrite.
  defp validate_type_fields("frame", %{"name" => name, "input" => input} = block) do
    cond do
      not valid_frame_name?(name) ->
        {:error, "frame.name must be a snake_case identifier (max #{@max_frame_name} chars)"}

      true ->
        with {:ok, input} <- validate_frame_input(input),
             {:ok, ops} <- Aveline.Frames.Pipeline.validate(Map.get(block, "ops", [])),
             {:ok, viz} <- validate_viz(Map.get(block, "viz", %{"type" => "table"})) do
          {:ok, %{"name" => name, "input" => input, "ops" => ops, "viz" => viz}}
        end
    end
  end

  defp validate_type_fields("frame", _) do
    {:error,
     "frame requires name (snake_case), input ({source|data_source_id, query} or {frame: <earlier frame name>}), and optional ops + viz"}
  end

  # ===== Helpers (placed after all validate_type_fields clauses so the
  # compiler doesn't complain about non-contiguous clause grouping) =====

  # Shared by chart and frame: the viz grammar is one language.
  defp validate_viz(viz) do
    cond do
      not is_map(viz) or viz["type"] not in ["table", "line", "bar", "combo"] ->
        {:error, "viz.type must be \"table\", \"line\", \"bar\", or \"combo\""}

      viz["type"] in ["line", "bar"] and
          not (is_binary(viz["x"]) and viz["x"] != "" and is_binary(viz["y"]) and viz["y"] != "") ->
        {:error, "viz needs x and y (column names) for line/bar"}

      viz["type"] == "combo" and not valid_combo_series?(viz) ->
        {:error, "viz combo needs x and series: 1-4 of {y: column, type: line | bar, axis?: left | right}"}

      true ->
        {:ok, clean_viz(viz)}
    end
  end

  defp clean_viz(%{"type" => "table"}), do: %{"type" => "table"}

  defp clean_viz(%{"type" => "combo"} = viz) do
    %{
      "type" => "combo",
      "x" => viz["x"],
      "series" =>
        Enum.map(viz["series"], fn s ->
          base = %{"y" => s["y"], "type" => s["type"]}
          if s["axis"] == "right", do: Map.put(base, "axis", "right"), else: base
        end)
    }
  end

  defp clean_viz(%{"type" => t} = viz), do: %{"type" => t, "x" => viz["x"], "y" => viz["y"]}

  defp valid_frame_name?(name),
    do:
      is_binary(name) and byte_size(name) <= @max_frame_name and
        Regex.match?(@frame_name_re, name)

  # input is a data-source query XOR an upstream frame reference.
  defp validate_frame_input(%{"data_source_id" => ds_id, "query" => query} = input)
       when is_binary(ds_id) and is_binary(query) do
    cond do
      Map.has_key?(input, "frame") ->
        {:error, "frame.input takes a source query or an upstream frame, not both"}

      not Regex.match?(@uuid_re, ds_id) ->
        {:error,
         "frame.input.data_source_id must be a UUID (the source's base id); or pass input.source: <name> and the server resolves it"}

      String.trim(query) == "" ->
        {:error, "frame.input.query cannot be blank"}

      String.length(query) > 10_000 ->
        {:error, "frame.input.query too long (10k max)"}

      true ->
        {:ok, %{"data_source_id" => String.downcase(ds_id), "query" => query}}
    end
  end

  defp validate_frame_input(%{"frame" => name} = input) do
    cond do
      Map.has_key?(input, "query") or Map.has_key?(input, "data_source_id") or
          Map.has_key?(input, "source") ->
        {:error, "frame.input takes a source query or an upstream frame, not both"}

      not valid_frame_name?(name) ->
        {:error, "frame.input.frame must be an upstream frame's snake_case name"}

      true ->
        {:ok, %{"frame" => name}}
    end
  end

  defp validate_frame_input(_input) do
    {:error, "frame.input must be {source|data_source_id, query} or {frame: <earlier frame name>}"}
  end

  defp valid_combo_series?(%{"x" => x, "series" => series}) when is_binary(x) and x != "" do
    is_list(series) and length(series) in 1..4 and
      Enum.all?(series, fn
        %{"y" => y, "type" => t} = s ->
          is_binary(y) and y != "" and t in ["line", "bar"] and
            Map.get(s, "axis", "left") in ["left", "right"]

        _ ->
          false
      end)
  end

  defp valid_combo_series?(_), do: false

  defp validate_list_items(items) do
    Enum.reduce_while(items, {:ok, []}, fn raw_item, {:ok, acc} ->
      case validate_list_item(raw_item) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        err -> {:halt, err}
      end
    end)
  end

  defp validate_list_item(%{"content" => content} = item) do
    id =
      case Map.get(item, "id") do
        nil -> Id.mint_list_item()
        existing when is_binary(existing) -> existing
        _ -> :error
      end

    cond do
      id == :error ->
        {:error, "list item id must be a string"}

      is_binary(id) and not Aveline.Blocks.Id.valid_list_item_id?(id) ->
        {:error, "list item id must start with li_"}

      true ->
        case Inline.validate_spans(content) do
          {:ok, normalized} -> {:ok, %{"id" => id, "content" => normalized}}
          err -> err
        end
    end
  end

  defp validate_list_item(_), do: {:error, "list item must be %{content: [...]}"}

  defp validate_table_rows(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case validate_table_row(row) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        err -> {:halt, err}
      end
    end)
  end

  defp validate_table_row(row) when is_list(row) do
    Enum.reduce_while(row, {:ok, []}, fn cell, {:ok, acc} ->
      case Inline.validate_spans(cell) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        err -> {:halt, err}
      end
    end)
  end
end
