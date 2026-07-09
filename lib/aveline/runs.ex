defmodule Aveline.Runs do
  @moduledoc """
  Notebook cell runs. Editing source makes doc versions; running cells
  makes rows here — outputs are NEVER written into docs.blocks or
  version rows, so version history stays lean and list queries never
  drag result payloads.

  Staleness is derived, not stored: every run persists a
  `snapshot_hash` = hash(cell source fields + upstream run hashes), and
  `staleness/2` recomputes the expected hash chain from the current
  version's sources at read time. Editing an upstream cell changes the
  chain, so every dependent renders stale with zero stored state.

  Execution failures are run rows with `status: "error"` — a down data
  source, an unrun upstream, a broken pipeline are all records, never
  raises, and reading a notebook never executes anything.
  """

  import Ecto.Query

  alias Aveline.Broadcasts
  alias Aveline.Config
  alias Aveline.DataSources
  alias Aveline.Docs.Doc
  alias Aveline.Events
  alias Aveline.Frames.Executor
  alias Aveline.Frames.Graph
  alias Aveline.Repo
  alias Aveline.Runs.CellRun
  alias Aveline.Runtime.Session

  # Frames pull far more rows than chart echoes — the executor is the
  # thing that reduces them.
  @frame_input_row_cap 50_000

  def frame_input_row_cap, do: @frame_input_row_cap

  # ===== Execute =====

  @doc """
  Execute one cell — a frame against its input (a data-source query or
  the latest run of an earlier frame), or an elixir code block in the
  notebook's runtime session — and record the run, error runs too.
  `actor` is `%{user_id: ..., type: "human" | "agent"}`.

  Returns `{:ok, %CellRun{}}` for both ok and error runs;
  `{:error, :not_notebook}` / `{:error, :cell_not_found}` /
  `{:error, :invalid_actor}` / `{:error, :execution_disabled}` are
  refusals (nothing ran, nothing recorded, nothing broadcast).
  """
  def run_cell(doc, block_id, actor)

  def run_cell(%Doc{kind: "notebook"} = doc, block_id, actor) do
    blocks = doc.blocks || []

    with {:ok, actor} <- validate_actor(actor),
         %{} = block <- find_cell(blocks, block_id) || {:error, :cell_not_found},
         :ok <- ensure_executable(block) do
      Broadcasts.publish_doc_event(:cell_run_started, %{
        base_doc_id: doc.base_doc_id,
        workspace_id: doc.workspace_id,
        block_id: block_id
      })

      execute_and_record(doc, blocks, block, actor)
    end
  end

  def run_cell(%Doc{}, _block_id, _actor), do: {:error, :not_notebook}

  # Once :cell_run_started is out, a terminal :cell_run_finished must
  # ALWAYS follow — an insert failure or an unexpected raise still
  # broadcasts one (with `run: nil`) so no viewer is stranded on a
  # forever-"running" cell whose run will never record.
  defp execute_and_record(doc, blocks, block, actor) do
    latest = latest_per_cell(doc.base_doc_id)
    started = System.monotonic_time(:millisecond)
    result = execute(doc, blocks, block, latest)
    duration_ms = System.monotonic_time(:millisecond) - started

    case insert_run(doc, block, actor, Map.put(result, :duration_ms, duration_ms)) do
      {:ok, run} ->
        {:ok, run}

      {:error, _changeset} = err ->
        publish_run_finished(doc, block["id"], nil)
        err
    end
  catch
    kind, reason ->
      publish_run_finished(doc, block["id"], nil)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # ===== Read =====

  @doc "Latest run per cell for a logical doc, as %{block_id => %CellRun{}}."
  def latest_per_cell(base_doc_id) when is_binary(base_doc_id) do
    from(r in CellRun,
      where: r.base_doc_id == ^base_doc_id,
      distinct: r.block_id,
      order_by: [asc: r.block_id, desc: r.inserted_at],
      preload: [:actor_user, doc_version: ^version_number_only()]
    )
    |> Repo.all()
    |> Map.new(&{&1.block_id, &1})
  end

  @doc "Runs of one cell, newest first."
  def list_runs(base_doc_id, block_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    from(r in CellRun,
      where: r.base_doc_id == ^base_doc_id and r.block_id == ^block_id,
      order_by: [desc: r.inserted_at],
      limit: ^limit,
      preload: [:actor_user, doc_version: ^version_number_only()]
    )
    |> Repo.all()
  end

  @doc """
  Derives `:fresh` / `:stale` / `:never_run` per cell (frames and
  elixir code blocks), keyed by block id. The expected hash chain is
  recomputed purely from the CURRENT version's cell sources; a cell is
  fresh only when its latest run is ok and carries exactly that hash —
  so an edit anywhere upstream (or a rerun of a stale upstream)
  cascades staleness without any stored flag.
  """
  def staleness(%Doc{} = doc, latest_runs) when is_map(latest_runs) do
    doc.blocks
    |> Graph.cells()
    |> Enum.reduce({%{}, %{}}, fn block, {states, expected_by_name} ->
      expected = snapshot_hash(block, expected_upstream(block, expected_by_name))

      state =
        case latest_runs[block["id"]] do
          nil -> :never_run
          %CellRun{status: "ok", snapshot_hash: ^expected} -> :fresh
          %CellRun{} -> :stale
        end

      {Map.put(states, block["id"], state), put_expected(expected_by_name, block, expected)}
    end)
    |> elem(0)
  end

  # A frame consumes its declared upstream; a code cell consumes every
  # frame its source references via frame("name") — same first-
  # reference order the run records.
  defp expected_upstream(%{"type" => "code"} = block, expected_by_name) do
    block
    |> Graph.code_refs()
    |> Enum.flat_map(&List.wrap(expected_by_name[&1]))
  end

  defp expected_upstream(block, expected_by_name) do
    case Graph.upstream_ref(block) do
      nil -> []
      ref -> List.wrap(expected_by_name[ref])
    end
  end

  # Only frames bind names other cells can consume; a code cell's name
  # is a label.
  defp put_expected(expected_by_name, %{"type" => "frame", "name" => name}, expected),
    do: Map.put(expected_by_name, name, expected)

  defp put_expected(expected_by_name, _block, _expected), do: expected_by_name

  @doc """
  sha256 over the cell's canonical source fields (frames: name, input,
  ops — viz is presentation, not data; code cells: language, content,
  name) plus its upstream hashes, hex-encoded.
  """
  def snapshot_hash(block, upstream_hashes) when is_list(upstream_hashes) do
    source = Map.take(block, source_fields(block))

    :crypto.hash(:sha256, [canonical(source) | upstream_hashes])
    |> Base.encode16(case: :lower)
  end

  defp source_fields(%{"type" => "code"}), do: ["language", "content", "name"]
  defp source_fields(_frame), do: ["name", "input", "ops"]

  # ===== Internal =====

  # Every reader of a run consumes only the pointed-at version's NUMBER
  # (provenance caption, API echo) — never preload the version row's
  # blocks / operations / search_text into run reads.
  defp version_number_only, do: from(d in Doc, select: struct(d, [:id, :version_number]))

  # Refused before the started broadcast and before any execution — a
  # bogus actor must never dial the customer database or strand viewers
  # on a "running" cell whose run will never record.
  defp validate_actor(actor) do
    type = actor[:type] || "agent"

    if type in CellRun.actor_types(),
      do: {:ok, %{user_id: actor[:user_id], type: type}},
      else: {:error, :invalid_actor}
  end

  defp find_cell(blocks, block_id) do
    blocks
    |> Graph.cells()
    |> Enum.find(&(&1["id"] == block_id))
  end

  # Code cells evaluate arbitrary Elixir inside this deployment, so
  # they only run where DEPLOY_MODE=local (single-user Docker). A
  # refusal, not an error run: nothing evaluates, nothing records, and
  # the same notebook stays fully readable on non-local deployments.
  defp ensure_executable(%{"type" => "code"}) do
    if Config.local_mode?(), do: :ok, else: {:error, :execution_disabled}
  end

  defp ensure_executable(_frame), do: :ok

  # Returns the run row's execution fields (status, outputs, stdout,
  # stdout_truncated, upstream_hashes). Every failure past this point
  # is an error RUN, not a refusal — provenance keeps the story.

  # A code cell evaluates in the notebook's runtime session: contexts
  # (bindings + env) accumulate down the doc from the nearest earlier
  # code cell, and frame("name") rebuilds an upstream frame's
  # dataframe from its latest CAPTURED run — running a code cell never
  # implicitly runs a frame. Everything the evaluator catches is an
  # error run.
  defp execute(doc, blocks, %{"type" => "code"} = block, latest) do
    earlier = Enum.take_while(blocks, &(&1["id"] != block["id"]))
    upstream_hashes = code_upstream_hashes(earlier, block, latest)

    parents =
      earlier |> Graph.cells() |> Enum.filter(&(&1["type"] == "code")) |> Enum.map(& &1["id"])

    outcome =
      Session.evaluate(doc.base_doc_id, block["id"], block["content"] || "",
        parents: parents,
        frame_resolver: frame_resolver(earlier, latest)
      )

    case outcome do
      {:ok, %{result: result, stdout: stdout, stdout_truncated: truncated?}} ->
        %{
          status: "ok",
          outputs: %{"result" => result},
          stdout: stdout,
          stdout_truncated: truncated?,
          upstream_hashes: upstream_hashes
        }

      {:error, %{message: message, stdout: stdout, stdout_truncated: truncated?}} ->
        %{
          status: "error",
          outputs: %{"error" => message},
          stdout: stdout,
          stdout_truncated: truncated?,
          upstream_hashes: upstream_hashes
        }
    end
  end

  defp execute(doc, blocks, block, latest) do
    {status, outputs, upstream_hashes} =
      case resolve_input(doc, blocks, block, latest) do
        {:ok, input, upstream_hashes} ->
          case Executor.run(input, block["ops"] || []) do
            {:ok, outputs} -> {"ok", outputs, upstream_hashes}
            {:error, msg} -> {"error", %{"error" => msg}, upstream_hashes}
          end

        {:error, msg, upstream_hashes} ->
          {"error", %{"error" => msg}, upstream_hashes}
      end

    %{
      status: status,
      outputs: outputs,
      stdout: nil,
      stdout_truncated: false,
      upstream_hashes: upstream_hashes
    }
  end

  # The recorded upstream chain mirrors staleness/2's expected chain:
  # every statically referenced frame with a run contributes its latest
  # run's hash, in first-reference order.
  defp code_upstream_hashes(earlier_blocks, block, latest) do
    frames_by_name = frames_by_name(earlier_blocks)

    block
    |> Graph.code_refs()
    |> Enum.flat_map(fn ref ->
      case frames_by_name[ref] && latest[frames_by_name[ref]["id"]] do
        %CellRun{snapshot_hash: hash} -> [hash]
        _ -> []
      end
    end)
  end

  # The bindings bridge behind frame("name"): resolve an EARLIER frame
  # through its latest captured run and hand the outputs to the eval —
  # the dataframe is rebuilt inside the evaluation task, and misses
  # raise in the cell, landing as error runs.
  defp frame_resolver(earlier_blocks, latest) do
    frames_by_name = frames_by_name(earlier_blocks)

    fn name ->
      case frames_by_name[name] do
        nil ->
          {:error, "no frame named #{inspect(name)} above this cell"}

        frame ->
          case latest[frame["id"]] do
            %CellRun{status: "ok", outputs: outputs} -> {:ok, outputs}
            %CellRun{} -> {:error, "frame #{inspect(name)} last run failed; rerun it first"}
            nil -> {:error, "frame #{inspect(name)} has not been run yet"}
          end
      end
    end
  end

  defp frames_by_name(blocks), do: blocks |> Graph.frames() |> Map.new(&{&1["name"], &1})

  defp resolve_input(doc, blocks, block, latest) do
    case block["input"] do
      %{"frame" => ref} ->
        resolve_frame_input(blocks, block, ref, latest)

      %{"data_source_id" => base_id, "query" => query} ->
        resolve_source_input(doc, base_id, query)

      _ ->
        {:error, "invalid frame input", []}
    end
  end

  # An upstream frame binds through its latest CAPTURED run — running a
  # dependent never implicitly runs its upstream.
  defp resolve_frame_input(blocks, block, ref, latest) do
    upstream = Graph.upstream_block(blocks, block)

    case upstream && latest[upstream["id"]] do
      %CellRun{status: "ok", outputs: outputs, snapshot_hash: hash} ->
        {:ok, outputs, [hash]}

      %CellRun{snapshot_hash: hash} ->
        {:error, "upstream frame #{inspect(ref)} last run failed; rerun it first", [hash]}

      nil ->
        {:error, "upstream frame #{inspect(ref)} has not been run yet", []}
    end
  end

  defp resolve_source_input(doc, base_id, query) do
    ws_id = doc.workspace_id

    case DataSources.get_latest_by_base(base_id) do
      %{workspace_id: ^ws_id, deleted_at: nil} = ds ->
        case DataSources.Cache.run(ds, query, row_cap: @frame_input_row_cap) do
          {:ok, result} -> {:ok, result, []}
          {:error, msg} -> {:error, msg, []}
        end

      %{workspace_id: ^ws_id} ->
        {:error, "data source was deleted (credential destroyed); connect a new one and update this cell", []}

      _ ->
        {:error, "data source not found", []}
    end
  end

  defp insert_run(doc, block, actor, result) do
    %CellRun{}
    |> CellRun.changeset(%{
      workspace_id: doc.workspace_id,
      base_doc_id: doc.base_doc_id,
      doc_version_id: doc.id,
      block_id: block["id"],
      snapshot_hash: snapshot_hash(block, result.upstream_hashes),
      status: result.status,
      outputs: result.outputs,
      stdout: result.stdout,
      actor_user_id: actor.user_id,
      actor_type: actor.type,
      duration_ms: result.duration_ms,
      truncated: result.outputs["truncated"] == true or result.stdout_truncated == true,
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert()
    |> case do
      {:ok, run} ->
        run = Repo.preload(run, [:actor_user, doc_version: version_number_only()])

        Events.record(%{
          workspace_id: doc.workspace_id,
          actor: actor.user_id,
          actor_type: actor.type,
          action: "cell_run",
          target_kind: "doc",
          target_id: doc.base_doc_id,
          target_slug: doc.slug,
          target_label: doc.title,
          data: %{
            "block_id" => block["id"],
            "frame" => block["name"],
            "status" => run.status,
            "duration_ms" => run.duration_ms
          }
        })

        publish_run_finished(doc, block["id"], run)

        {:ok, run}

      err ->
        err
    end
  end

  # `run: nil` is the stranded-viewer escape hatch: the run failed to
  # record, but subscribers still clear their running flag.
  defp publish_run_finished(doc, block_id, run) do
    Broadcasts.publish_doc_event(:cell_run_finished, %{
      base_doc_id: doc.base_doc_id,
      workspace_id: doc.workspace_id,
      block_id: block_id,
      run: run
    })
  end

  # Deterministic encoding for hashing: object keys sorted, scalars as
  # JSON. Jason alone won't do — Elixir map order is unspecified.
  defp canonical(map) when is_map(map) do
    inner =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> [Jason.encode!(k), ":", canonical(v)] end)
      |> Enum.intersperse(",")

    ["{", inner, "}"]
  end

  defp canonical(list) when is_list(list),
    do: ["[", list |> Enum.map(&canonical/1) |> Enum.intersperse(","), "]"]

  defp canonical(scalar), do: Jason.encode!(scalar)
end
