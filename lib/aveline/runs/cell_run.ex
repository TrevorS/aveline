defmodule Aveline.Runs.CellRun do
  @moduledoc """
  One captured execution of a notebook frame cell — append-only
  provenance, deliberately separate from doc versions (running cells
  never mints versions; editing source never mints runs).

  `outputs` is the capped tabular result for ok runs and
  `%{"error" => msg}` for error runs — error runs are records too.
  `snapshot_hash` is hash(cell source fields + upstream run hashes);
  `Aveline.Runs.staleness/2` recomputes the expected chain at read time
  and a mismatch renders the cell stale. `stdout` is reserved for code
  cells (group-leader capture); frame cells leave it nil.
  """
  use Aveline.Schema
  import Ecto.Changeset

  alias Aveline.Accounts.User
  alias Aveline.Docs.Doc
  alias Aveline.Workspaces.Workspace

  @statuses ~w(ok error)
  @actor_types ~w(human agent)

  schema "cell_runs" do
    field :base_doc_id, :binary_id
    field :block_id, :string
    field :snapshot_hash, :string
    field :status, :string
    field :outputs, :map, default: %{}
    field :stdout, :string
    field :actor_type, :string
    field :duration_ms, :integer
    field :truncated, :boolean, default: false
    field :inserted_at, :utc_datetime_usec

    belongs_to :workspace, Workspace, type: :binary_id
    belongs_to :doc_version, Doc, type: :binary_id
    belongs_to :actor_user, User, type: :binary_id
  end

  def statuses, do: @statuses
  def actor_types, do: @actor_types

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :workspace_id,
      :base_doc_id,
      :doc_version_id,
      :block_id,
      :snapshot_hash,
      :status,
      :outputs,
      :stdout,
      :actor_user_id,
      :actor_type,
      :duration_ms,
      :truncated,
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
