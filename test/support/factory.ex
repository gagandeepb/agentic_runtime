defmodule AgenticRuntime.Factory do
  @moduledoc """
  ExMachina factories for `agentic_runtime` test data.

  Mirrors the Trento application's `test/support/factory.ex` style:
  Ecto-backed factories for owned schemas (`Conversation`, `AgentState`,
  `DisplayMessage`) plus a small number of plain helpers for the host-owned
  `users` table and for non-schema attribute maps.
  """

  use ExMachina.Ecto, repo: AgenticRuntime.TestRepo

  alias AgenticRuntime.Conversations.AgentState
  alias AgenticRuntime.Conversations.Conversation
  alias AgenticRuntime.Conversations.DisplayMessage
  alias AgenticRuntime.TestRepo

  defmodule Scope do
    @moduledoc "Test scope struct used in lieu of a host application's Scope."
    defstruct [:owner_id]
  end

  defimpl AgenticRuntime.Scope, for: AgenticRuntime.Factory.Scope do
    def owner_id(%{owner_id: id}), do: id
  end

  # ---- ExMachina factories (Ecto-backed) ----------------------------------

  def conversation_factory do
    %Conversation{
      title: Faker.Lorem.sentence(3),
      version: 1,
      metadata: %{},
      user_id: insert_test_user!()
    }
  end

  def agent_state_factory do
    %AgentState{
      state_data: %{"version" => 1, "state" => %{"messages" => []}},
      version: 1,
      conversation: build(:conversation)
    }
  end

  def display_message_text_factory do
    %DisplayMessage{
      message_type: "user",
      content_type: "text",
      content: %{"text" => Faker.Lorem.sentence()},
      sequence: 0,
      status: "completed",
      metadata: %{},
      conversation: build(:conversation)
    }
  end

  def display_message_tool_call_factory do
    %DisplayMessage{
      message_type: "assistant",
      content_type: "tool_call",
      content: %{
        "call_id" => "call_#{System.unique_integer([:positive])}",
        "name" => "test_tool",
        "arguments" => %{"q" => Faker.Lorem.word()}
      },
      sequence: 0,
      status: "pending",
      metadata: %{},
      conversation: build(:conversation)
    }
  end

  @doc """
  Builds a `Scope` struct for test use. Inserts a fresh user when no
  `owner_id` is given.
  """
  def scope_factory(attrs) do
    owner_id = Map.get(attrs, :owner_id, insert_test_user!())
    %Scope{owner_id: owner_id}
  end

  # ---- Plain helpers (non-ExMachina) --------------------------------------

  @doc """
  Inserts a row in the host-owned `users` table via raw SQL and returns
  the generated id. The `users` table is not mapped by any agentic_runtime
  Ecto schema, so ExMachina cannot manage it.
  """
  def insert_test_user!(attrs \\ %{}) do
    email = Map.get(attrs, :email, Faker.Internet.email())

    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "INSERT INTO users (email, inserted_at, updated_at) VALUES ($1, NOW(), NOW()) RETURNING id",
        [email]
      )

    id
  end

  @doc """
  Returns a map suitable for `AgenticRuntime.Conversations.create_conversation/2`.
  """
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

  @doc """
  Returns a map suitable for `Conversations.append_display_message/3` for
  text content.
  """
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

  @doc """
  Returns a map suitable for `Conversations.append_display_message/3` for a
  `tool_call` content entry. The `call_id` is unique per call.
  """
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
