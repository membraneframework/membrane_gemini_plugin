defmodule Membrane.Gemini.QueueFilter do
  @moduledoc false

  use Membrane.Filter

  require Membrane.Logger
  alias Membrane.RawAudio

  @audio_format %RawAudio{sample_format: :s16le, channels: 1, sample_rate: 24_000}

  def_input_pad :input,
    accepted_format: @audio_format,
    flow_control: :push

  def_output_pad :output,
    accepted_format: @audio_format,
    flow_control: :manual,
    demand_unit: :buffers

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

    # pop all events from the front so that either the queue's next element is a buffer or it's empty
    {events, queue_tail} =
      Enum.split_while(queue, fn element -> not match?(%Membrane.Buffer{}, element) end)

    # `Enum.split_while` returns the queue tail as a regular list so it has to be converted back
    new_queue = Qex.new(queue_tail)

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
  def handle_event(
        :input,
        %Membrane.Gemini.OutputTranscriptEvent{} = event,
        _ctx,
        %{queue: queue} = state
      ) do
    {[], %{state | queue: Qex.push(queue, event)}}
  end

  def handle_event(:input, %Membrane.Gemini.InputTranscriptEvent{} = event, _ctx, state) do
    {[forward: event], state}
  end

  def handle_event(
        :input,
        %Membrane.Gemini.ThinkingEvent{} = event,
        _ctx,
        %{queue: queue} = state
      ) do
    {[], %{state | queue: Qex.push(queue, event)}}
  end

  def handle_event(
        :input,
        %Membrane.Gemini.ResponseStartEvent{} = start_event,
        _ctx,
        %{queue: queue} = state
      ) do
    if Enum.empty?(queue) do
      {[forward: start_event], state}
    else
      {{:value, %Membrane.Gemini.ResponseEndEvent{interrupted: false} = end_event}, _queue} =
        Qex.pop_back(queue)

      {[forward: %{end_event | interrupted: true}, forward: start_event],
       %{state | queue: Qex.new()}}
    end
  end

  def handle_event(
        :input,
        %Membrane.Gemini.ResponseEndEvent{interrupted: false} = event,
        _ctx,
        %{queue: queue} = state
      ) do
    # invariant: once this event is pushed to the queue, no further elements may be pushed
    # until it is popped or the queue is discarded by receiving a ResponseStartEvent
    {[], %{state | queue: Qex.push(queue, event)}}
  end

  def handle_event(
        :input,
        %Membrane.Gemini.ResponseEndEvent{interrupted: true} = event,
        _ctx,
        state
      ) do
    {[forward: event], %{state | queue: Qex.new()}}
  end
end
