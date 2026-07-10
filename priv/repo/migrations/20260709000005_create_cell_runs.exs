defmodule Aveline.Repo.Migrations.CreateCellRuns do
  @moduledoc """
  Run captures for notebook frame cells. Editing a cell's source makes a
  new doc version; running a cell makes a `cell_run` — append-only
  provenance in its own table so version rows stay lean (every version is
  a full blocks copy dragged into every list query; embedded outputs
  would re-persist forever). A read joins the current version's cells to
  their latest run at the boundary; staleness is derived from
  `snapshot_hash`, never stored.
  """
  use Ecto.Migration

  def up do
    create table(:cell_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      # Stable logical doc id (runs outlive the version they ran against).
      add :base_doc_id, :binary_id, null: false
      # The specific version row the cell was on when it ran.
      add :doc_version_id, references(:docs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :block_id, :string, null: false
      # Catalog query the cell resolved to at run time.
      add :query_ref, :string
      # sha256 of the cell source fields + the referenced query's current
      # SQL/version — recomputed at read to derive fresh/stale.
      add :snapshot_hash, :string, null: false

      add :status, :string, null: false
      # Captured result (columns/rows/truncated) for an ok run; {} on error.
      add :outputs, :map, null: false, default: %{}
      add :truncated, :boolean, null: false, default: false
      add :error_text, :text
      add :duration_ms, :integer

      add :actor_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :actor_type, :string, null: false

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create constraint(:cell_runs, :cell_runs_status_known, check: "status IN ('ok', 'error')")

    create constraint(:cell_runs, :cell_runs_actor_type_known,
             check: "actor_type IN ('human', 'agent')"
           )

    # Latest-run-per-cell + per-cell history both read (base_doc_id,
    # block_id) newest-first.
    create index(:cell_runs, [:base_doc_id, :block_id, :inserted_at])
  end

  def down do
    drop table(:cell_runs)
  end
end
