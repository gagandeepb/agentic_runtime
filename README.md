# AgenticRuntime

An opinionated agent + conversation runtime for Phoenix applications, layered on
top of [`sagents`](https://hex.pm/packages/sagents) and
[`langchain`](https://github.com/brainlid/langchain).

`AgenticRuntime` ships:

- A factory that composes the standard middleware stack (TodoList, ConversationTitle,
  FileSystem, SubAgent, Summarization, PatchToolCalls, AskUserQuestion, optional
  HumanInTheLoop) so consumers don't reassemble it from parts.
- A `Conversations` Ecto context for persisting conversations, agent state
  snapshots, and rich display messages (with multi-content-type support).
- A `Coordinator` for conversation-scoped agent lifecycle (start / resume / stop,
  PubSub topics, presence tracking).
- `IntegrationHelpers` for translating agent PubSub events into Phoenix Channel
  socket-assigns updates.

## Status

- **Pre-1.0 (`0.1.0`).** The public API may change without deprecation cycles.
- The `langchain` dependency is currently pinned to a [GitHub fork](https://github.com/nelsonkopliku/langchain).
  Until the fork is upstreamed or published to hex, downstream apps must add the
  same `:override` in their own `mix.exs`.
- **PostgreSQL is required.** Conversations, agent state, and display messages
  all persist to Postgres via Ecto.

## Installation

Add `agentic_runtime` and the langchain fork override to your `mix.exs`:

```elixir
def deps do
  [
    {:agentic_runtime, "~> 0.1.0"},
    {:langchain,
     github: "nelsonkopliku/langchain",
     ref: "e7a32fad6a2477ee6b1460510c4614dab8ed1263",
     override: true}
  ]
end
```

## Setup

### 1. Migration

Copy the schema migration from `priv/repo/migrations/` (file
`20260318081407_create_sagents_persistence.exs`) into your application's
`priv/repo/migrations/` directory and run `mix ecto.migrate`. It assumes a
`users` table with an integer primary key — adjust the `:user_id` foreign-key
reference if your accounts table is named or typed differently.

### 2. Configuration

```elixir
# config/config.exs
config :agentic_runtime,
  repo: MyApp.Repo,
  pubsub_name: MyApp.PubSub,
  presence_module: MyAppWeb.Presence
```

| Key                | Purpose                                                              |
| ------------------ | -------------------------------------------------------------------- |
| `:repo`            | Your Ecto Repo. Used by `Conversations` and the persistence callbacks. |
| `:pubsub_name`     | Phoenix.PubSub name. Used by `Coordinator` for agent event topics.   |
| `:presence_module` | Phoenix.Presence module. Used for tracking conversation viewers.     |

### 3. Implement the `AgenticRuntime.Scope` protocol

Your application's scope struct (whatever your auth wires into the socket /
plug assigns) needs to implement the `AgenticRuntime.Scope` protocol so the
runtime can derive the tenant owner id for query scoping.

```elixir
defimpl AgenticRuntime.Scope, for: MyApp.Accounts.Scope do
  def owner_id(%MyApp.Accounts.Scope{user: %{id: id}}), do: id
end
```

`nil` scopes are permitted for tests, admin scripts, and background jobs;
persistence functions return `{:error, :not_found}` for tenant-isolated
reads/writes performed under a `nil` scope.

### 4. Wire the supervisor

Add the runtime supervisor to your application's supervision tree:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    MyApp.Repo,
    {Phoenix.PubSub, name: MyApp.PubSub},
    MyAppWeb.Presence,
    MyAppWeb.Endpoint,
    AgenticRuntime.start_runtime([])
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

## Minimal example

```elixir
# Build a model config
model =
  AgenticRuntime.build_anthropic_model_config(
    "claude-opus-4-7",
    System.fetch_env!("ANTHROPIC_API_KEY"),
    []
  )

# Define a tool
search_tool =
  AgenticRuntime.new_tool!(%{
    name: "search",
    description: "Search the knowledge base",
    function: fn %{"query" => q}, _context -> {:ok, "Results for #{q}"} end
  })

# Start a conversation session
{:ok, conversation} =
  AgenticRuntime.Conversations.create_conversation(scope, %{title: "New chat"})

{:ok, session} =
  AgenticRuntime.Agents.Coordinator.start_conversation_session(conversation.id,
    scope: scope,
    filesystem_scope: {:user, scope.user.id},
    factory_opts: [
      model_config: model,
      base_system_prompt: "You are a helpful assistant.",
      tools: [search_tool]
    ]
  )

# Send a user message
message = AgenticRuntime.build_new_user_message!("What's the weather like?")
:ok = AgenticRuntime.add_message(session.agent_id, message)
```

## Phoenix Channel integration

`AgenticRuntime.IntegrationHelpers` provides socket-assigns helpers for the full
agent event lifecycle. A minimal channel:

```elixir
defmodule MyAppWeb.ConversationChannel do
  use MyAppWeb, :channel

  alias AgenticRuntime.IntegrationHelpers
  alias AgenticRuntime.Agents.Coordinator

  @impl true
  def join("conversation:" <> conversation_id, _payload, socket) do
    socket = IntegrationHelpers.init_agent_state(socket)

    case IntegrationHelpers.load_conversation(socket, conversation_id,
           scope: socket.assigns.current_scope,
           user_id: socket.assigns.current_user.id
         ) do
      {:ok, socket} -> {:ok, socket}
      {:error, :not_found, socket} -> {:error, %{reason: "conversation not found"}}
    end
  end

  @impl true
  def handle_in("send_message", %{"text" => text}, socket) do
    msg = AgenticRuntime.build_new_user_message!(text)
    :ok = AgenticRuntime.add_message(socket.assigns.agent_id, msg)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:llm_deltas, deltas}, socket) do
    {:noreply, IntegrationHelpers.handle_llm_deltas(socket, deltas)}
  end

  def handle_info({:status_changed, :running}, socket),
    do: {:noreply, IntegrationHelpers.handle_status_running(socket)}

  def handle_info({:status_changed, :idle}, socket),
    do: {:noreply, IntegrationHelpers.handle_status_idle(socket)}

  # ... see `AgenticRuntime.IntegrationHelpers` for the full set of handlers
end
```

The full handler surface — HITL approvals, AskUserQuestion responses, tool
execution updates, conversation title generation, agent shutdown — is
documented in the `AgenticRuntime.IntegrationHelpers` module.

## Testing

Consumers should use `Ecto.Adapters.SQL.Sandbox` for tests that exercise
`Conversations` directly. For tests that exercise the agent lifecycle without
spinning up real Sagents processes, configure the runtime to use Mox doubles of
the adapter behaviours:

```elixir
# test/test_helper.exs
Mox.defmock(MyApp.ServerAdapterMock, for: AgenticRuntime.Agents.ServerAdapter)
Mox.defmock(MyApp.SupervisorAdapterMock, for: AgenticRuntime.Agents.SupervisorAdapter)

Application.put_env(:agentic_runtime, :server_adapter, MyApp.ServerAdapterMock)
Application.put_env(:agentic_runtime, :supervisor_adapter, MyApp.SupervisorAdapterMock)
```

This library's own test suite uses the same pattern — see `test/test_helper.exs`
and `test/support/` for a full example.

## Local development

A `docker-compose.yml` is included for convenience:

```sh
docker compose up -d
mix deps.get
MIX_ENV=test mix ecto.create -r AgenticRuntime.TestRepo
MIX_ENV=test mix ecto.migrate -r AgenticRuntime.TestRepo
mix test
```

## Roadmap / known limitations

- The `langchain` dependency is a github-pinned fork. Replacing it with a hex
  release (either upstream or a published fork) is a prerequisite for hex
  publication.
- ExDoc / `@spec` coverage is incomplete; module documentation is still being
  filled out.
- API is `0.1.0` — breaking changes may land before `1.0.0`.

## License

See [LICENSE](LICENSE).
