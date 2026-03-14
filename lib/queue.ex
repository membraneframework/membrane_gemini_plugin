defmodule Membrane.Gemini.QueueFilter do
  @moduledoc false

  use Membrane.Filter

  require Membrane.Logger
  alias Membrane.RawAudio

  @audio_format %RawAudio{sample_format: :s16le, channels: 1, sample_rate: 24_000}

  def_input_pad(:input,
    accepted_format: %RawAudio{sample_format: :s16le, channels: 1, sample_rate: 24_000},
    flow_control: :push
  )

  def_output_pad(:output,
    accepted_format: %RawAudio{sample_format: :s16le, channels: 1, sample_rate: 24_000},
    flow_control: :manual,
    demand_unit: :buffers
  )

  @impl true
  def handle_init(_ctx, _opts) do
    state = %{
      queue: Qex.new(),
      pts_counter: 0
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
    # NOTE: buffer byte-size assumed through empirical tests
    buffer_time = RawAudio.bytes_to_time(1920, @audio_format)

    {new_queue, events} = pop_while_event(queue)

    {buffer, new_queue} =
      case Qex.pop(new_queue) do
        {{:value, %Membrane.Buffer{} = buffer}, new_queue} ->
          {buffer, new_queue}

        {:empty, _queue} ->
          silence_buffer = %Membrane.Buffer{
            payload: RawAudio.silence(@audio_format, buffer_time)
          }

          {silence_buffer, new_queue}
      end

    actions =
      Enum.map(events, fn event -> {:event, {:output, event}} end) ++
        [buffer: {:output, %{buffer | pts: pts_counter}}]

    {actions, %{state | queue: new_queue, pts_counter: pts_counter + buffer_time}}
  end

  @impl true
  def handle_event(:input, %Membrane.Gemini.Events.Transcript{direction: :output} = event, _ctx, state),
    do: do_handle_event(event, state)

  def handle_event(:input, %Membrane.Gemini.Events.Transcript{direction: :input} = event, _ctx, state) do
    {[forward: event], state}
  end

  def handle_event(:input, %Membrane.Gemini.Events.Thinking{} = event, _ctx, state),
    do: do_handle_event(event, state)

  def handle_event(
        :input,
        %Membrane.Gemini.Events.ResponseStart{} = start_event,
        _ctx,
        %{queue: queue} = state
      ) do
    case Qex.pop_back(queue) do
      {{:value, %Membrane.Gemini.Events.ResponseEnd{interrupted?: false} = end_event}, _queue} ->
        {[forward: %{end_event | interrupted?: true}, forward: start_event],
         %{state | queue: Qex.new()}}

      {:empty, _queue} ->
        {[forward: start_event], state}
    end
  end

  def handle_event(
        :input,
        %Membrane.Gemini.Events.ResponseEnd{interrupted?: false} = event,
        _ctx,
        %{queue: queue} = state
      ) do
    # invariant: once this event is pushed to the queue, no further elements may be pushed
    # until it is popped or the queue is discarded by receiving a ResponseStartEvent
    {[], %{state | queue: Qex.push(queue, event)}}
  end

  def handle_event(
        :input,
        %Membrane.Gemini.Events.ResponseEnd{interrupted?: true} = event,
        _ctx,
        state
      ) do
    {[forward: event], %{state | queue: Qex.new()}}
  end

  @spec do_handle_event(event :: Membrane.Event.t(), state :: map()) ::
          {[Membrane.Element.Action.forward()], map()}
  defp do_handle_event(event, %{queue: queue} = state) do
    case Qex.pop(queue) do
      {{:value, _value}, _queue} ->
        {[], %{state | queue: Qex.push(queue, event)}}

      {:empty, _queue} ->
        {[forward: event], state}
    end
  end

  @spec pop_while_event(queue :: Qex.t(), events :: [Membrane.Event.t()]) :: {Qex.t(), [Membrane.Event.t()]}
  defp pop_while_event(queue, events \\ []) do
    case Qex.pop(queue) do
      {{:value, %Membrane.Buffer{}}, _queue} ->
        {queue, Enum.reverse(events)}
      {{:value, event}, new_queue} ->
        {new_queue, [event | events]}
      {:empty, _queue} ->
        {queue, Enum.reverse(events)}
    end
    end
end
