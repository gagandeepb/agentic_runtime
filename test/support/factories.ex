defmodule AgenticRuntime.Factories do
  @moduledoc """
  Faker-driven helpers for building test data. Functions ending in `!` insert
  into the test repo; the others build maps or structs without touching the DB.
  """

  alias AgenticRuntime.TestRepo

  defmodule Scope do
    @moduledoc "Test scope struct used in lieu of a host application's Scope."
    defstruct [:owner_id]
  end

  defimpl AgenticRuntime.Scope, for: AgenticRuntime.Factories.Scope do
    def owner_id(%{owner_id: id}), do: id
  end

  def build_scope(owner_id \\ nil) do
    %Scope{owner_id: owner_id || insert_user!()}
  end

  def insert_user!(attrs \\ %{}) do
    email = Map.get(attrs, :email, Faker.Internet.email())

    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "INSERT INTO users (email, inserted_at, updated_at) VALUES ($1, NOW(), NOW()) RETURNING id",
        [email]
      )

    id
  end

  def conversation_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        title: Faker.Lorem.sentence(3),
        version: 1,
        metadata: %{}
      },
      overrides
    )
  end

  def insert_conversation!(scope, overrides \\ %{}) do
    {:ok, conversation} =
      AgenticRuntime.Conversations.create_conversation(scope, conversation_attrs(overrides))

    conversation
  end

  def text_message_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        message_type: "user",
        content_type: "text",
        content: %{"text" => Faker.Lorem.sentence()},
        sequence: 0,
        status: "completed",
        metadata: %{}
      },
      overrides
    )
  end

  def tool_call_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        message_type: "assistant",
        content_type: "tool_call",
        content: %{
          "call_id" => "call_#{System.unique_integer([:positive])}",
          "name" => "test_tool",
          "arguments" => %{"q" => Faker.Lorem.word()}
        },
        sequence: 0,
        status: "pending",
        metadata: %{}
      },
      overrides
    )
  end
end
