defmodule Aveline.Repo.Migrations.AddKindToDocs do
  @moduledoc """
  A doc's `kind` — "doc" (ordinary) or "notebook" (container of blocks
  plus executable cells). Set once at creation, carried immutably across
  versions like pin_slot/orientation. The fact lives in the schema so a
  CHECK can see it, mirroring actor_type_valid.

  Pre-launch — no backfill. Existing rows default to 'doc'.
  """
  use Ecto.Migration

  def up do
    alter table(:docs) do
      add :kind, :string, null: false, default: "doc"
    end

    create constraint(:docs, :kind_valid, check: "kind IN ('doc', 'notebook')")
  end

  def down do
    drop constraint(:docs, :kind_valid)

    alter table(:docs) do
      remove :kind
    end
  end
end
