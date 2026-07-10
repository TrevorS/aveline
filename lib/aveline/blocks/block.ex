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
    * `code`      — `%{type, language: string|null, content: string}`
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
  # Chart query_ref is a catalog query name (same charset as Query.name).
  @query_name_re ~r/^[a-z][a-z0-9_]{0,39}$/

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

  # code — a code block. Statically rendered anywhere (prose fenced code);
  # inside a kind=notebook doc a `language: "elixir"` code block is also an
  # executable cell (run surface + cell_runs), gated to local deploy mode
  # at run time — the block shape is identical, execution is a runtime
  # capability, so notebooks stay portable. Optional `name` labels the cell.
  defp validate_type_fields("code", %{"content" => content} = block) when is_binary(content) do
    lang =
      case Map.get(block, "language") do
        nil -> nil
        "" -> nil
        s when is_binary(s) -> s
        _ -> :error
      end

    name =
      case Map.get(block, "name") do
        nil -> nil
        "" -> nil
        s when is_binary(s) -> s
        _ -> :error
      end

    cond do
      lang == :error ->
        {:error, "code.language must be a string or null"}

      name == :error ->
        {:error, "code.name must be a string or null"}

      is_binary(name) and not Regex.match?(@query_name_re, name) ->
        {:error,
         "code.name must be a snake_case identifier: lowercase letter first, then letters/digits/underscores (40 max)"}

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

  # chart — a view over a named catalog query. `query_ref` is the query
  # name (resolved/verified in the Docs write path); the query owns the
  # SQL and the data source. The computed `result`/`source`/`query_sql`
  # echoes are not fields here, so pasted echoes are stripped on rewrite.
  defp validate_type_fields("chart", %{"query_ref" => ref} = block) when is_binary(ref) do
    viz = Map.get(block, "viz", %{"type" => "table"})

    cond do
      not Regex.match?(@query_name_re, ref) ->
        {:error, "chart.query_ref must be a catalog query name (lowercase letter, then letters/digits/underscores)"}

      true ->
        case validate_and_clean_viz(viz) do
          {:ok, clean_viz} -> {:ok, %{"query_ref" => String.downcase(ref), "viz" => clean_viz}}
          err -> err
        end
    end
  end

  defp validate_type_fields("chart", _) do
    {:error, "chart requires query_ref (a catalog query name; create the query first, then chart it) and optional viz"}
  end

  # frame — a notebook cell that owns a catalog query. `name` is the
  # cell's identity (and the name a created query takes); the cell carries
  # EXACTLY ONE OF `query_ref` (an existing catalog query name) or `query`
  # (inline SQL — with an optional `source` naming a data source for a RAW
  # cell, absent => DERIVED). The Docs write path turns an inline cell into
  # a catalog query and rewrites it to the query_ref form, and gates frames
  # to kind=notebook docs; this validator stays pure. `viz` reuses the
  # chart grammar. The run echoes (result/source/query_sql) are not fields
  # here, so pasted echoes are stripped on rewrite — same as chart.
  defp validate_type_fields("frame", %{"name" => name} = block) when is_binary(name) do
    has_ref? = Map.has_key?(block, "query_ref")
    has_query? = Map.has_key?(block, "query")

    cond do
      not Regex.match?(@query_name_re, name) ->
        {:error,
         "frame.name must be a table-safe identifier: lowercase letter first, then letters/digits/underscores (40 max)"}

      has_ref? and has_query? ->
        {:error, "frame carries exactly one of query_ref (an existing catalog query) or query (inline SQL) — not both"}

      has_ref? ->
        validate_frame_ref(name, block["query_ref"], Map.get(block, "viz", %{"type" => "table"}))

      has_query? ->
        validate_frame_inline(name, block, Map.get(block, "viz", %{"type" => "table"}))

      true ->
        {:error, "frame requires query_ref (an existing catalog query name) or query (inline SQL to author the cell)"}
    end
  end

  defp validate_type_fields("frame", _) do
    {:error, "frame requires name (a snake_case identifier) and exactly one of query_ref or query (inline SQL)"}
  end

  # ===== Helpers (placed after all validate_type_fields clauses so the
  # compiler doesn't complain about non-contiguous clause grouping) =====

  # Shared chart viz validation + normalization (drops unknown keys).
  defp validate_and_clean_viz(viz) do
    cond do
      not is_map(viz) or viz["type"] not in ["table", "line", "bar", "combo", "scatter"] ->
        {:error, "chart.viz.type must be \"table\", \"line\", \"bar\", \"combo\", or \"scatter\""}

      viz["type"] in ["line", "bar", "scatter"] and
          not (is_binary(viz["x"]) and viz["x"] != "" and is_binary(viz["y"]) and viz["y"] != "") ->
        {:error, "chart.viz needs x and y (column names) for line/bar/scatter"}

      viz["type"] == "combo" and not valid_combo_series?(viz) ->
        {:error, "chart.viz combo needs x and series: 1-4 of {y: column, type: line | bar, axis?: left | right}"}

      true ->
        clean =
          case viz["type"] do
            "table" ->
              %{"type" => "table"}

            "combo" ->
              %{
                "type" => "combo",
                "x" => viz["x"],
                "series" =>
                  Enum.map(viz["series"], fn s ->
                    base = %{"y" => s["y"], "type" => s["type"]}
                    if s["axis"] == "right", do: Map.put(base, "axis", "right"), else: base
                  end)
              }

            "scatter" ->
              base = %{"type" => "scatter", "x" => viz["x"], "y" => viz["y"]}
              # Optional: color points by a categorical column (one series each).
              if is_binary(viz["color"]) and viz["color"] != "",
                do: Map.put(base, "color", viz["color"]),
                else: base

            t ->
              %{"type" => t, "x" => viz["x"], "y" => viz["y"]}
          end

        {:ok, clean}
    end
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

  # A frame referencing an existing catalog query by name; the Docs write
  # path verifies it resolves (Block stays pure).
  defp validate_frame_ref(name, ref, viz) when is_binary(ref) do
    if Regex.match?(@query_name_re, ref) do
      case validate_and_clean_viz(viz) do
        {:ok, clean} -> {:ok, %{"name" => name, "query_ref" => String.downcase(ref), "viz" => clean}}
        err -> err
      end
    else
      {:error, "frame.query_ref must be a catalog query name (lowercase letter, then letters/digits/underscores)"}
    end
  end

  defp validate_frame_ref(_name, _ref, _viz),
    do: {:error, "frame.query_ref must be a string (a catalog query name)"}

  # A frame authoring its own query inline. `query` is opaque SQL (parsed
  # at create time by the catalog, not here); `source` is an optional data
  # source name (present => RAW cell, absent => DERIVED). The Docs write
  # path creates the catalog query and rewrites this to the query_ref form.
  defp validate_frame_inline(name, block, viz) do
    sql = block["query"]
    source = Map.get(block, "source")

    cond do
      not (is_binary(sql) and String.trim(sql) != "") ->
        {:error, "frame.query must be a non-empty SQL string"}

      not (is_nil(source) or (is_binary(source) and source != "")) ->
        {:error, "frame.source, when present, must be a data source name (string)"}

      true ->
        case validate_and_clean_viz(viz) do
          {:ok, clean} ->
            base = %{"name" => name, "query" => sql, "viz" => clean}
            {:ok, if(source, do: Map.put(base, "source", source), else: base)}

          err ->
            err
        end
    end
  end

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
