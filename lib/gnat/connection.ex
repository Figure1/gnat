require Logger

defmodule Gnat.Connection do
  @moduledoc false

  use Connection

  alias Gnat.{Proto, Buffer}
  alias Proto.{Info, Ping, Pong, Msg}

  def start_link(options) do
    Connection.start_link(__MODULE__, Enum.into(options, %{}))
  end

  def init(options) do
    {:ok, socket} = :gen_tcp.connect(
      String.to_char_list(options.host),
      options.port,
      [:binary, active: false]
    )

    # Wait for an INFO message.
    {:ok, raw_message} = :gen_tcp.recv(socket, 0)
    info = Proto.parse(raw_message)

    # Go into async mode.
    :inet.setopts(socket, active: :once)

    Proto.connect(
      verbose: false,
      pedantic: false,
      lang: "Elixir",
      version: "1.0",
      protocol: 1
    ) |> transmit(socket)

    Proto.ping |> transmit(socket)

    state = %{
      socket: socket,
      buffer: "",
      deliver_to: nil,
      msgs: [],
      requests: %{},
      info: info |> Map.from_struct
    } |> Map.merge(options)

    {:connect, nil, state}
  end

  def connect(_info, state) do
    {:ok, state}
  end

  def terminate(_reason, state) do
    Logger.debug "Closing socket"
    :gen_tcp.close(state.socket)
  end

  def handle_info({:tcp, socket, data}, state) do
    %{ buffer: buffer } = state

    {messages, buffer} = Buffer.process(buffer <> data)

    Enum.each messages, fn message ->
      GenServer.cast(self(), {:message, message})
    end

    state = %{state | buffer: buffer}

    # Allow the socket to send us the next message
    :inet.setopts(socket, active: :once)

    {:noreply, state}
  end

  def handle_cast({:message, raw_message}, state) do
    Logger.debug "<<- #{raw_message}"
    Proto.parse(raw_message) |> handle_message(state)
  end

  def handle_message(%Info{} = info, state) do
    {:noreply, %{state | info: info}}
  end

  def handle_message(%Ping{}, state) do
    Proto.pong |> transmit(state.socket)
    {:noreply, state}
  end

  def handle_message(%Pong{}, state) do
    {:noreply, state}
  end

  # If requests has key sid, then the Msg is a part of a req/rpl cycle.
  # If requests[sid] is nil, then no one is waiting on the result yet,
  # otherwise the value is the waiter.
  def handle_message(%Msg{} = msg, state) do
    %{requests: requests} = state
    %{sid: sid} = msg

    if Map.has_key?(requests, sid) do
      if waiter = requests[sid] do
        GenServer.reply(waiter, {:ok, msg})
        requests = Map.delete(requests, sid)
        {:noreply, %{state | requests: requests}}
      else
        {:noreply, put_in(state, [:requests, sid], msg)}
      end
    else
      if state.deliver_to do
        send(state.deliver_to, {:nats_msg, msg})
        {:noreply, state}
      else
        {:noreply, %{state | msgs: [msg | state.msgs]}}
      end
    end
  end

  # Mark the sid as a part of a req/rpl cycle.
  # See comment on handle_message(%Msg{}, state).
  def handle_call({:request, sid}, _from, state) do
    {:reply, :ok, put_in(state, [:requests, sid], nil)}
  end

  # Return the response of a req/res cycle, or block if it's not ready.
  # See comment on handle_message(%Msg{}, state).
  def handle_call({:response, sid}, from, state) do
    %{requests: requests} = state

    if response = requests[sid] do
      requests = Map.delete(requests, sid)
      {:reply, {:ok, response}, %{state | requests: requests}}
    else
      {:noreply, put_in(state, [:requests, sid], from)}
    end
  end

  def handle_call({:transmit, raw_message}, _from, state) do
    transmit(raw_message, state.socket)
    {:reply, :ok, state}
  end

  def handle_call(:next_msg, _from, state) do
    %{msgs: msgs} = state
    msg = List.last(msgs)
    msgs = List.delete_at(msgs, -1)
    {:reply, msg, %{state | msgs: msgs}}
  end

  def handle_call(:info, _from, state) do
    %{info: info} = state
    {:reply, info, state}
  end

  defp transmit(raw_message, socket) do
    Logger.debug "->> #{raw_message}"
    :gen_tcp.send(socket, "#{raw_message}\r\n")
  end

end
