defmodule AgenticRuntime.TestRepo.Migrations.CreateSagentsPersistence do
  use Ecto.Migration

  def change do
    create table(:sagents_conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :title, :string
      add :version, :integer, default: 1, null: false
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sagents_conversations, [:user_id])
    create index(:sagents_conversations, [:updated_at])

    create table(:sagents_agent_states, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id,
          references(:sagents_conversations, on_delete: :delete_all, type: :binary_id),
          null: false

      add :state_data, :map, null: false
      add :version, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sagents_agent_states, [:conversation_id])

    create table(:sagents_display_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id,
          references(:sagents_conversations, on_delete: :delete_all, type: :binary_id),
          null: false

      add :message_type, :string, null: false
      add :content, :map, null: false
      add :content_type, :string, null: false, default: "text"
      add :status, :string, default: "completed"
      add :sequence, :integer, default: 0, null: false
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:sagents_display_messages, [:conversation_id, :inserted_at, :sequence])
    create index(:sagents_display_messages, [:content_type])
    create index(:sagents_display_messages, [:status])

    create unique_index(
             :sagents_display_messages,
             [:conversation_id, "(content->>'call_id')"],
             name: :unique_tool_call_per_conversation,
             where: "content_type = 'tool_call'"
           )
  end
end
