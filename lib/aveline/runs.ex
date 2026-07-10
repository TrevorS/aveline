defmodule Aveline.Runs do
  @moduledoc """
  Run-capture for notebook frame cells. Running a cell resolves its
  catalog query, executes it through the same async chart engine
  (`Docs.run_chart` → `Catalog`/`Cache`/`Engine` — never DuckDB directly),
  and appends a `cell_run` recording the output, provenance, and a
  `snapshot_hash`. Error runs are captured too, so a notebook read never
  fails on a down source.

  Staleness is DERIVED, never stored: a cell's `snapshot_hash` is a
  fingerprint of its source fields plus the current SQL/version of its
  referenced query AND that query's whole transitive upstream closure.
  `staleness/2` recomputes it at read time and compares against the
  latest run — a mismatch is `:stale`, a match `:fresh`, no run
  `:never_run`. Editing any upstream query bumps its version, so the
  fingerprint moves and every downstream cell — even across a chain of
  derived queries — renders stale with zero stored state.
  """

  import Ecto.Query

  alias Aveline.Broadcasts
  alias Aveline.Config
  alias Aveline.DataSources.Engine
  alias Aveline.DataSources.Queries
  alias Aveline.Docs
  alias Aveline.Docs.Doc
  alias Aveline.Events
  alias Aveline.Repo
  alias Aveline.Runs.CellRun
  alias Aveline.Runtime

  @doc """
  Run one notebook cell in `doc` (by block id) as `actor`
  (`%{user_id: id, actor_type: "human" | "agent"}`), capturing a
  `cell_run`. Dispatches on the cell kind:

    * a frame cell resolves its catalog query through the chart engine
      (never touches DuckDB directly);
    * an Elixir code cell evaluates in the notebook's runtime session —
      but only where `Config.local_mode?/0`; elsewhere it returns
      `{:error, :execution_disabled, msg}` so the API/renderer can surface
      a portable "execution disabled" state instead of running code.

  An error run is still recorded (status "error"); the caller gets the run
  either way. Returns `{:ok, %CellRun{}}`, `{:error, :not_found}` when the
  block isn't a runnable cell, or `{:error, :execution_disabled, msg}`.
  """
  def run_cell(%Doc{} = doc, block_id, actor) when is_binary(block_id) do
    case cell_block(doc, block_id) do
      %{"type" => "frame", "query_ref" => ref} = block when is_binary(ref) ->
        run_frame_cell(doc, block, ref, actor)

      %{"type" => "code", "language" => "elixir"} = block ->
        run_code_cell(doc, block, actor)

      _ ->
        {:error, :not_found}
    end
  end

  defp run_frame_cell(%Doc{} = doc, block, ref, actor) do
    Broadcasts.publish_cell_run(:cell_run_started, doc, %{block_id: block["id"]})
    started = System.monotonic_time(:millisecond)
    result = Docs.run_chart(doc.workspace_id, block)
    duration = System.monotonic_time(:millisecond) - started

    doc
    |> base_attrs(block, actor)
    |> Map.merge(%{query_ref: ref, duration_ms: duration})
    |> Map.merge(result_fields(result))
    |> capture(doc)
  end

  # Code cells are gated to local deploy mode: elsewhere a notebook still
  # renders (source + last captured output), but running is refused with a
  # structured error the API surfaces and the renderer explains.
  defp run_code_cell(%Doc{} = doc, block, actor) do
    if Config.local_mode?() do
      Broadcasts.publish_cell_run(:cell_run_started, doc, %{block_id: block["id"]})

      outcome =
        Runtime.eval(doc.base_doc_id, block["id"], block["content"] || "",
          workspace_id: doc.workspace_id,
          actor_user_id: actor[:user_id]
        )

      doc
      |> base_attrs(block, actor)
      |> Map.merge(%{query_ref: nil, duration_ms: eval_duration(outcome)})
      |> Map.merge(code_result_fields(outcome))
      |> capture(doc)
    else
      {:error, :execution_disabled,
       "code cell execution is disabled in this deployment (set DEPLOY_MODE=local to enable)"}
    end
  end

  # Fields shared by every captured run, before the type-specific merge.
  defp base_attrs(%Doc{} = doc, block, actor) do
    %{
      workspace_id: doc.workspace_id,
      base_doc_id: doc.base_doc_id,
      doc_version_id: doc.id,
      block_id: block["id"],
      snapshot_hash: snapshot_hash(doc, block),
      actor_user_id: actor[:user_id],
      actor_type: actor[:actor_type] || "agent",
      inserted_at: DateTime.utc_now()
    }
  end

  defp capture(attrs, %Doc{} = doc) do
    with {:ok, run} <- insert_run(attrs) do
      run = Repo.preload(run, :actor_user)
      record_event(doc, run)
      # Tell every open viewer the run landed; each re-annotates the cell
      # in place from the freshly-captured run.
      Broadcasts.publish_cell_run(:cell_run_finished, doc, %{block_id: run.block_id})
      {:ok, run}
    end
  end

  # A code eval captures its inspected return value + stdout on an ok run,
  # and the failure message + whatever stdout it managed to write on an
  # error run — mirroring how a frame error run records on the row without
  # breaking the read. A runtime that couldn't start is itself an error run.
  defp code_result_fields(%{status: :ok, result: result, stdout: stdout} = reply),
    do: %{
      status: "ok",
      error_text: nil,
      outputs:
        %{"result" => result, "stdout" => stdout}
        |> maybe_put_table(reply[:table])
        |> maybe_put_chart(reply[:chart]),
      truncated: (reply[:table] || %{})["truncated"] == true
    }

  defp code_result_fields(%{status: :error, error: error, stdout: stdout}),
    do: %{
      status: "error",
      error_text: error,
      outputs: %{"stdout" => stdout},
      truncated: false
    }

  defp code_result_fields(other),
    do: %{
      status: "error",
      error_text: "runtime unavailable: #{inspect(other)}",
      outputs: %{},
      truncated: false
    }

  # A code cell that returns an Explorer DataFrame/Series carries a
  # rendered table alongside the inspected result; one that returns a
  # plot carries a chart spec; a scalar carries neither.
  defp maybe_put_table(outputs, nil), do: outputs
  defp maybe_put_table(outputs, table), do: Map.put(outputs, "table", table)

  defp maybe_put_chart(outputs, nil), do: outputs
  defp maybe_put_chart(outputs, chart), do: Map.put(outputs, "chart", chart)

  defp eval_duration(%{duration_ms: ms}) when is_integer(ms), do: ms
  defp eval_duration(_), do: 0

  # An ok run captures the columns/rows result; an error run stores the
  # message and an empty output — the failure is on the record, the read
  # doesn't break.
  defp result_fields(%{"error" => msg}),
    do: %{status: "error", error_text: to_string(msg), outputs: %{}, truncated: false}

  defp result_fields(%{} = ok),
    do: %{status: "ok", error_text: nil, outputs: ok, truncated: ok["truncated"] == true}

  defp insert_run(attrs) do
    %CellRun{}
    |> CellRun.insert_changeset(attrs)
    |> Repo.insert()
  end

  defp record_event(%Doc{} = doc, %CellRun{} = run) do
    Events.record(%{
      workspace_id: doc.workspace_id,
      actor: run.actor_user_id,
      actor_type: run.actor_type,
      action: "cell_run",
      target_kind: "doc",
      target_id: doc.base_doc_id,
      target_slug: doc.slug,
      target_label: doc.title,
      data: %{
        "block_id" => run.block_id,
        "query_ref" => run.query_ref,
        "status" => run.status,
        "version" => doc.version_number
      }
    })
  end

  @doc """
  The latest run per cell for a logical doc, as `%{block_id => %CellRun{}}`.
  The read boundary joins these onto the current version's frame cells.
  """
  def latest_per_cell(base_doc_id) when is_binary(base_doc_id) do
    from(r in CellRun,
      where: r.base_doc_id == ^base_doc_id,
      order_by: [asc: r.inserted_at, asc: r.id],
      preload: [:actor_user]
    )
    |> Repo.all()
    # Ascending order means the last write per block wins — the latest run.
    |> Enum.reduce(%{}, fn run, acc -> Map.put(acc, run.block_id, run) end)
  end

  @doc "The latest N runs for one cell, newest first — the run history API."
  def list_for_cell(base_doc_id, block_id, limit \\ 20)
      when is_binary(base_doc_id) and is_binary(block_id) do
    from(r in CellRun,
      where: r.base_doc_id == ^base_doc_id and r.block_id == ^block_id,
      order_by: [desc: r.inserted_at, desc: r.id],
      limit: ^limit,
      preload: [:actor_user]
    )
    |> Repo.all()
  end

  @doc """
  Derive `:fresh | :stale | :never_run` per frame cell in `doc`, given the
  latest run per cell (from `latest_per_cell/1`). Recomputes each cell's
  expected `snapshot_hash` from the current source + query and compares.
  """
  def staleness(%Doc{} = doc, latest_runs) when is_map(latest_runs) do
    for block <- doc.blocks || [], cell?(block), into: %{} do
      id = block["id"]

      state =
        case Map.get(latest_runs, id) do
          nil ->
            :never_run

          %CellRun{snapshot_hash: hash} ->
            if hash == snapshot_hash(doc, block), do: :fresh, else: :stale
        end

      {id, state}
    end
  end

  @doc """
  Fingerprint a frame cell: its authored source fields plus the current
  SQL/version of the catalog query it references AND every query in that
  query's transitive upstream closure. Editing any query in the chain (a
  new version) moves the hash, so the cell reads stale — a cell over a
  derived `b = SELECT … FROM a` goes stale when `a` is edited, not just
  when `b` is. A missing query (renamed/deleted out from under the cell,
  or an upstream ref that no longer resolves) hashes distinctly too.
  """
  def snapshot_hash(%Doc{workspace_id: ws_id}, %{"query_ref" => ref} = block)
      when is_binary(ref) do
    cell = %{
      "name" => block["name"],
      "query_ref" => ref,
      "viz" => block["viz"] || %{"type" => "table"}
    }

    payload = Jason.encode!(%{"cell" => cell, "queries" => query_closure(ws_id, ref)})
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  # A code cell's fingerprint is just its own source — its `query("…")`
  # dependencies aren't statically known, so editing the cell's source is
  # the one signal that moves the hash (a new doc version) and reads it
  # stale. (A frame cell also tracks its upstream query closure; a code
  # cell can't, so v1 hashes the source alone.)
  def snapshot_hash(%Doc{}, %{"type" => "code"} = block) do
    source = %{
      "content" => block["content"],
      "name" => block["name"],
      "language" => block["language"]
    }

    :crypto.hash(:sha256, Jason.encode!(%{"code" => source}))
    |> Base.encode16(case: :lower)
  end

  def snapshot_hash(_doc, _block), do: nil

  # The referenced query plus every query it transitively depends on,
  # each fingerprinted by base id + version + SQL. Derived queries pull
  # in their parsed refs recursively; the `seen` map both dedupes the DAG
  # and guards the walk from ever looping. Sorted by name so the payload
  # is order-stable across recomputes.
  defp query_closure(ws_id, ref) do
    ws_id
    |> collect_closure(ref, %{})
    |> Map.values()
    |> Enum.sort_by(& &1["name"])
  end

  defp collect_closure(_ws_id, name, seen) when is_map_key(seen, name), do: seen

  defp collect_closure(ws_id, name, seen) do
    case Queries.get_current_by_name(ws_id, name) do
      nil ->
        Map.put(seen, name, %{"name" => name, "missing" => true})

      %{kind: "derived", sql: sql} = q ->
        seen = Map.put(seen, name, query_print(q))

        case Engine.parse(sql) do
          {:ok, refs} -> Enum.reduce(refs, seen, &collect_closure(ws_id, &1, &2))
          {:error, _} -> seen
        end

      q ->
        Map.put(seen, name, query_print(q))
    end
  end

  defp query_print(q) do
    %{"name" => q.name, "base" => q.base_query_id, "version" => q.version_number, "sql" => q.sql}
  end

  @doc """
  Read-boundary enrichment for a notebook: augment each frame cell with
  its latest captured run (`"run"`) and a derived staleness flag
  (`"stale"`). Never executes anything — mirrors the `run_charts: false`
  chart echo. A no-op for non-notebook docs.
  """
  def annotate(%Doc{kind: "notebook"} = doc) do
    latest = latest_per_cell(doc.base_doc_id)
    stale = staleness(doc, latest)

    exec_enabled = Config.local_mode?()

    blocks =
      Enum.map(doc.blocks || [], fn
        %{"type" => "frame", "id" => id} = block ->
          block
          |> Map.put("run", run_summary(Map.get(latest, id)))
          |> Map.put("stale", Atom.to_string(Map.get(stale, id, :never_run)))
          |> Map.merge(frame_meta(doc.workspace_id, block["query_ref"]))

        %{"type" => "code", "language" => "elixir", "id" => id} = block ->
          # Mark the block an executable cell and echo its latest run,
          # staleness, and whether this deployment can run it — the
          # renderer shows a Run button or a quiet "disabled" state
          # accordingly, so the same notebook is portable across modes.
          block
          |> Map.put("cell", true)
          |> Map.put("exec_enabled", exec_enabled)
          |> Map.put("run", run_summary(Map.get(latest, id)))
          |> Map.put("stale", Atom.to_string(Map.get(stale, id, :never_run)))

        block ->
          block
      end)

    %{doc | blocks: blocks}
  end

  def annotate(%Doc{} = doc), do: doc

  # A frame's SQL + engine live in the catalog query it references — echoed
  # here so the renderer can show "sql" and "config" tabs, without the write
  # path ever storing them on the block.
  defp frame_meta(ws_id, ref) when is_binary(ref) do
    case Aveline.DataSources.Queries.get_current_by_name(ws_id, ref) do
      %{sql: sql, kind: kind, data_source_id: ds_id} ->
        %{"query_sql" => sql, "query_kind" => kind, "query_engine" => engine_label(kind, ds_id)}

      _ ->
        %{}
    end
  end

  defp frame_meta(_ws_id, _ref), do: %{}

  defp engine_label("derived", _ds_id), do: "DuckDB (catalog)"

  defp engine_label("raw", ds_id) when is_binary(ds_id) do
    case Aveline.DataSources.get_latest_by_base(ds_id) do
      %{name: name, adapter: adapter} -> "#{name} (#{adapter})"
      _ -> "external source"
    end
  end

  defp engine_label(_kind, _ds_id), do: nil

  defp run_summary(nil), do: nil

  defp run_summary(%CellRun{} = r) do
    %{
      "id" => r.id,
      "status" => r.status,
      "outputs" => r.outputs,
      "truncated" => r.truncated,
      "error_text" => r.error_text,
      "duration_ms" => r.duration_ms,
      "snapshot_hash" => r.snapshot_hash,
      "ran_at" => DateTime.to_iso8601(r.inserted_at),
      "actor" => %{"type" => r.actor_type}
    }
  end

  defp cell_block(%Doc{blocks: blocks}, block_id) do
    Enum.find(blocks || [], &(&1["id"] == block_id))
  end

  # The runnable notebook cells: frame cells and Elixir code cells. Other
  # blocks (prose, plain code blocks, charts) never carry a run/staleness.
  defp cell?(%{"type" => "frame"}), do: true
  defp cell?(%{"type" => "code", "language" => "elixir"}), do: true
  defp cell?(_), do: false
end
