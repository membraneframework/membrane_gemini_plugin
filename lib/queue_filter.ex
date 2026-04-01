defmodule Membrane.Gemini.QueueFilter do
  @moduledoc false

  use Membrane.Filter

  require Membrane.Logger
  alias Membrane.RawAudio
  alias Membrane.Gemini.Events

  @audio_format %RawAudio{sample_format: :s16le, channels: 1, sample_rate: 24_000}

  def_input_pad :input,
    accepted_format: %RawAudio{sample_format: :s16le, channels: 1, sample_rate: 24_000},
    flow_control: :push

  def_output_pad :output,
    accepted_format: %RawAudio{sample_format: :s16le, channels: 1, sample_rate: 24_000},
    flow_control: :manual,
    demand_unit: :buffers

  @impl true
  def handle_init(_ctx, _opts) do
    state = %{
      queue: Qex.new(),
      pts_counter: 0,
      last_buffer_duration: Membrane.Time.milliseconds(40)
    }

    {[], state}
  end

  @impl true
  def handle_setup(_ctx, state) do
    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[stream_format: {:output, @audio_format}], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, %{queue: queue} = state) do
    {[], %{state | queue: Qex.push(queue, buffer)}}
  end

  @impl true
  def handle_demand(
        :output,
        1,
        :buffers,
        %{playback: :playing} = _ctx,
        %{queue: queue, pts_counter: pts_counter} =
          state
      ) do
    {queue, events} = pop_while_event(queue)

    event_actions =
      Enum.map(events, fn event -> {:event, {:output, event}} end)

    {buffer, new_queue} =
      case Qex.pop(queue) do
        {{:value, %Membrane.Buffer{} = buffer}, new_queue} ->
          {%{buffer | pts: pts_counter}, new_queue}

        {:empty, _queue} ->
          buffer_duration = state.last_buffer_duration

          silence_buffer = %Membrane.Buffer{
            payload: RawAudio.silence(@audio_format, buffer_duration),
            pts: pts_counter
          }

          {silence_buffer, queue}
      end

    buffer_duration = buffer.payload |> byte_size() |> RawAudio.bytes_to_time(@audio_format)

    actions =
      event_actions ++
        [buffer: {:output, buffer}]

    state =
      %{
        queue: new_queue,
        last_buffer_duration: min(buffer_duration, Membrane.Time.milliseconds(40)),
        pts_counter: pts_counter + buffer_duration
      }

    {actions, state}
  end

  @impl true
  def handle_event(:input, %Events.Transcript{direction: :output} = event, _ctx, state),
    do: do_handle_event(event, state)

  @impl true
  def handle_event(:input, %Events.Transcript{direction: :input} = event, _ctx, state),
    do: {[event: {:output, event}], state}

  @impl true
  def handle_event(:input, %Events.Thinking{} = event, _ctx, state),
    do: do_handle_event(event, state)

  @impl true
  def handle_event(:input, %Events.ResponseStart{} = start_event, _ctx, %{queue: queue} = state) do
    maybe_end_event =
      case Qex.pop_back(queue) do
        {{:value, element}, _queue} ->
          if not match?(%Events.ResponseEnd{}, element) do
            Membrane.Logger.warning("""
            Received `ResponseStart` event, but the queue is non-empty
            and missing a `ResponseEnd` event, indicating it missing.
            """)
          end

          [event: {:output, %Events.ResponseEnd{interrupted?: true}}]

        {:empty, _queue} ->
          []
      end

    {maybe_end_event ++ [event: {:output, start_event}], %{state | queue: Qex.new()}}
  end

  @impl true
  def handle_event(
        :input,
        %Events.ResponseEnd{interrupted?: false} = event,
        _ctx,
        %{queue: queue} = state
      ) do
    # NOTE: once this event is pushed to the queue, no further elements should be pushed
    # until it is popped or the queue is discarded by receiving a `ResponseStart` event
    {[], %{state | queue: Qex.push(queue, event)}}
  end

  @impl true
  def handle_event(:input, %Events.ResponseEnd{interrupted?: true} = event, _ctx, state) do
    {[event: {:output, event}], %{state | queue: Qex.new()}}
  end

  @spec do_handle_event(event :: Membrane.Event.t(), state :: map()) ::
          {[Membrane.Element.Action.event()], map()}
  defp do_handle_event(event, %{queue: queue} = state) do
    case Qex.pop(queue) do
      {{:value, _value}, _queue} ->
        {[], %{state | queue: Qex.push(queue, event)}}

      {:empty, _queue} ->
        {[event: {:output, event}], state}
    end
  end

  @spec pop_while_event(queue :: Qex.t(), events :: [Membrane.Event.t()]) ::
          {Qex.t(), [Membrane.Event.t()]}
  defp pop_while_event(queue, events \\ []) do
    case Qex.pop(queue) do
      {{:value, %Membrane.Buffer{}}, _queue} ->
        {queue, Enum.reverse(events)}

      {{:value, event}, new_queue} ->
        pop_while_event(new_queue, [event | events])

      {:empty, _queue} ->
        {queue, Enum.reverse(events)}
    end
  end
end
