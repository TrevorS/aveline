defmodule Aveline.Runs.CellRun do
  @moduledoc """
  One captured run of a notebook frame cell: the output it produced, when,
  by whom, against which doc version and query. Append-only — a run is
  never edited. `snapshot_hash` is the fingerprint of the cell's source +
  its query at run time; a read recomputes it to decide fresh/stale, so no
  staleness state is stored. Holds outputs (a chart's columns/rows) for an
  ok run and `{}` + `error_text` for an error run — error runs are
  captured too, so a notebook read never fails and the failure is on the
  record.
  """
  use Aveline.Schema
  import Ecto.Changeset

  alias Aveline.Accounts.User
  alias Aveline.Docs.Doc
  alias Aveline.Workspaces.Workspace

  @statuses ~w(ok error)
  @actor_types ~w(human agent)

  # Append-only: an explicit inserted_at, no updated_at.
  @timestamps_opts [type: :utc_datetime_usec]
  schema "cell_runs" do
    field :base_doc_id, :binary_id
    field :block_id, :string
    field :query_ref, :string
    field :snapshot_hash, :string
    field :status, :string
    field :outputs, :map, default: %{}
    field :truncated, :boolean, default: false
    field :error_text, :string
    field :duration_ms, :integer
    field :actor_type, :string
    field :inserted_at, :utc_datetime_usec

    belongs_to :workspace, Workspace, type: :binary_id
    belongs_to :doc_version, Doc, type: :binary_id, foreign_key: :doc_version_id
    belongs_to :actor_user, User, type: :binary_id
  end

  def statuses, do: @statuses

  def insert_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :workspace_id,
      :base_doc_id,
      :doc_version_id,
      :block_id,
      :query_ref,
      :snapshot_hash,
      :status,
      :outputs,
      :truncated,
      :error_text,
      :duration_ms,
      :actor_user_id,
      :actor_type,
      :inserted_at
    ])
    |> validate_required([
      :workspace_id,
      :base_doc_id,
      :doc_version_id,
      :block_id,
      :snapshot_hash,
      :status,
      :actor_type,
      :inserted_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:actor_type, @actor_types)
  end
end
