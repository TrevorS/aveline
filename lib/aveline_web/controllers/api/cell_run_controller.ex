defmodule AvelineWeb.Api.CellRunController do
  @moduledoc """
  Notebook cell execution over the API. Runs are synchronous — the
  executors' ceilings (12s frames, 10s per code eval, plus a one-time
  peer-node boot on a notebook's first code run) bound the request,
  and concurrent code runs on one notebook queue behind each other —
  and every execution-domain failure comes back as a recorded run with
  `status: "error"`, so the agent reads one shape either way. Refusals
  (not a notebook, no such cell, code cells outside local mode) never
  record anything.
  """
  use AvelineWeb, :controller

  alias Aveline.Docs
  alias Aveline.Runs
  alias AvelineWeb.Api.Envelope
  alias AvelineWeb.Api.Views

  action_fallback AvelineWeb.Api.FallbackController

  @doc """
  Execute one cell and return the recorded run. Body (optional):
  `{"actor": "human" | "agent"}` — defaults to "agent" for API calls;
  anything else is refused (`invalid_actor`) before anything executes.
  """
  def run(conn, %{"doc_slug" => slug, "block_id" => block_id} = params) do
    ws = conn.assigns.current_workspace
    user = conn.assigns.current_user

    with %_{} = doc <- Docs.get_current_by_slug(ws.id, slug) || {:error, :not_found},
         {:ok, run} <-
           Runs.run_cell(doc, block_id, %{user_id: user.id, type: params["actor"] || "agent"}) do
      Envelope.ok(conn, %{run: Views.cell_run(run)})
    end
  end

  @doc """
  The latest runs of one cell, newest first. `?limit=` caps at 100
  (default 20).
  """
  def index(conn, %{"doc_slug" => slug, "block_id" => block_id} = params) do
    ws = conn.assigns.current_workspace

    with %_{} = doc <- Docs.get_current_by_slug(ws.id, slug) || {:error, :not_found},
         {:ok, limit} <- parse_limit(params["limit"]) do
      runs = Runs.list_runs(doc.base_doc_id, block_id, limit: limit)
      Envelope.ok(conn, %{runs: Enum.map(runs, &Views.cell_run/1)})
    end
  end

  defp parse_limit(nil), do: {:ok, 20}
  defp parse_limit(n) when is_integer(n) and n in 1..100, do: {:ok, n}

  defp parse_limit(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n in 1..100 -> {:ok, n}
      _ -> {:error, "limit must be an integer between 1 and 100"}
    end
  end

  defp parse_limit(_), do: {:error, "limit must be an integer between 1 and 100"}
end
