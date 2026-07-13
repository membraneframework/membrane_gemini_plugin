defmodule Membrane.Gemini.QueueFilterTest do
  # QueueFilter's callbacks are pure functions of (callback args, state), so
  # they are tested directly: driving them through a pipeline would put a
  # membrane InputQueue between the filter and the sink, whose one-buffer
  # prefetch makes demand-by-demand assertions non-deterministic. The filter's
  # in-pipeline behaviour (behind Realtimer) is covered by the paced-mode
  # endpoint tests.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Membrane.Buffer
  alias Membrane.Gemini.Events
  alias Membrane.Gemini.QueueFilter
  alias Membrane.RawAudio

  @format %RawAudio{sample_format: :s16le, channels: 1, sample_rate: 24_000}
  # The only ctx field the filter's callbacks inspect
  @ctx %{playback: :playing}

  defp init_state do
    {[], state} = QueueFilter.handle_init(@ctx, nil)
    state
  end

  defp push_buffer(state, payload) do
    {[], state} = QueueFilter.handle_buffer(:input, %Buffer{payload: payload}, @ctx, state)
    state
  end

  defp handle_event(state, event), do: QueueFilter.handle_event(:input, event, @ctx, state)

  defp demand(state), do: QueueFilter.handle_demand(:output, 1, :buffers, @ctx, state)

  defp payload_of_ms(ms, byte \\ <<0, 1>>),
    do: :binary.copy(byte, div(@format.sample_rate * ms, 1000))

  defp silence_of_ms(ms), do: RawAudio.silence(@format, Membrane.Time.milliseconds(ms))

  defp ms(value), do: Membrane.Time.milliseconds(value)

  test "injects 40 ms of silence per demand when the queue is empty" do
    silence = silence_of_ms(40)

    {actions, state} = demand(init_state())
    assert [buffer: {:output, %Buffer{payload: ^silence, pts: 0}}] = actions

    {actions, _state} = demand(state)
    pts = ms(40)
    assert [buffer: {:output, %Buffer{payload: ^silence, pts: ^pts}}] = actions
  end

  test "passes buffers through in order, one per demand" do
    b1 = payload_of_ms(20, <<1, 1>>)
    b2 = payload_of_ms(20, <<2, 2>>)

    state = init_state() |> push_buffer(b1) |> push_buffer(b2)

    {actions, state} = demand(state)
    assert [buffer: {:output, %Buffer{payload: ^b1, pts: 0}}] = actions

    {actions, _state} = demand(state)
    pts = ms(20)
    assert [buffer: {:output, %Buffer{payload: ^b2, pts: ^pts}}] = actions
  end

  test "keeps PTS contiguous and caps silence duration at 40 ms" do
    state = init_state() |> push_buffer(payload_of_ms(20, <<1, 1>>))

    {actions, state} = demand(state)
    assert [buffer: {:output, %Buffer{pts: 0}}] = actions

    # Queue empty: silence matches the last buffer's duration (20 ms < 40 ms cap)
    {actions, state} = demand(state)
    silence_20 = silence_of_ms(20)
    pts_20 = ms(20)
    assert [buffer: {:output, %Buffer{payload: ^silence_20, pts: ^pts_20}}] = actions

    state = push_buffer(state, payload_of_ms(100, <<3, 3>>))

    {actions, state} = demand(state)
    pts_40 = ms(40)
    assert [buffer: {:output, %Buffer{pts: ^pts_40}}] = actions

    # Last buffer was 100 ms, but injected silence is capped at 40 ms
    {actions, _state} = demand(state)
    silence_40 = silence_of_ms(40)
    pts_140 = ms(140)
    assert [buffer: {:output, %Buffer{payload: ^silence_40, pts: ^pts_140}}] = actions
  end

  test "server transcript is queued behind buffers and released after them" do
    b1 = payload_of_ms(20, <<1, 1>>)
    transcript = %Events.Transcript{audio_origin: :server, text: "queued"}

    state = init_state() |> push_buffer(b1)

    # Queue non-empty: the event is held, no immediate action
    assert {[], state} = handle_event(state, transcript)

    {actions, state} = demand(state)
    assert [buffer: {:output, %Buffer{payload: ^b1}}] = actions

    # Next demand releases the queued event first, then a (silence) buffer
    {actions, _state} = demand(state)
    assert [event: {:output, ^transcript}, buffer: {:output, %Buffer{}}] = actions
  end

  test "server transcript passes through immediately when the queue is empty" do
    transcript = %Events.Transcript{audio_origin: :server, text: "immediate"}
    assert {[event: {:output, ^transcript}], _state} = handle_event(init_state(), transcript)
  end

  test "client transcript passes through immediately even with queued buffers" do
    transcript = %Events.Transcript{audio_origin: :client, text: "immediate"}
    state = init_state() |> push_buffer(payload_of_ms(20))

    assert {[event: {:output, ^transcript}], _state} = handle_event(state, transcript)
  end

  test "Thinking event is immediate on empty queue, queued behind buffers otherwise" do
    thinking = %Events.Thinking{text: "hmm"}

    assert {[event: {:output, ^thinking}], _state} = handle_event(init_state(), thinking)

    b1 = payload_of_ms(20, <<1, 1>>)
    state = init_state() |> push_buffer(b1)
    assert {[], state} = handle_event(state, thinking)

    {actions, state} = demand(state)
    assert [buffer: {:output, %Buffer{payload: ^b1}}] = actions

    {actions, _state} = demand(state)
    assert [event: {:output, ^thinking}, buffer: {:output, %Buffer{}}] = actions
  end

  test "ResponseStart flushes queued buffers and synthesizes an interrupted ResponseEnd" do
    state =
      init_state()
      |> push_buffer(payload_of_ms(20, <<1, 1>>))
      |> push_buffer(payload_of_ms(20, <<2, 2>>))

    {{actions, state}, log} =
      with_log(fn -> handle_event(state, %Events.ResponseStart{}) end)

    assert [
             event: {:output, %Events.ResponseEnd{interrupted?: true}},
             event: {:output, %Events.ResponseStart{}}
           ] = actions

    assert log =~ "missing a `ResponseEnd` event"

    # Queued buffers were discarded: the next demand yields silence
    {actions, _state} = demand(state)
    silence = silence_of_ms(40)
    assert [buffer: {:output, %Buffer{payload: ^silence}}] = actions
  end

  test "ResponseStart after a clean ResponseEnd does not synthesize an interrupted one" do
    state = init_state() |> push_buffer(payload_of_ms(20, <<1, 1>>))
    {[], state} = handle_event(state, %Events.ResponseEnd{interrupted?: false})

    log =
      capture_log(fn ->
        {actions, _state} = handle_event(state, %Events.ResponseStart{})

        # The queue ended with a clean ResponseEnd, so the synthesized event is
        # emitted without the missing-ResponseEnd warning
        assert [
                 event: {:output, %Events.ResponseEnd{interrupted?: true}},
                 event: {:output, %Events.ResponseStart{}}
               ] = actions
      end)

    refute log =~ "missing a `ResponseEnd` event"
  end

  test "ResponseStart on empty queue emits no ResponseEnd" do
    assert {[event: {:output, %Events.ResponseStart{}}], _state} =
             handle_event(init_state(), %Events.ResponseStart{})
  end

  test "clean ResponseEnd is held until queued buffers drain" do
    b1 = payload_of_ms(10, <<1, 1>>)
    response_end = %Events.ResponseEnd{interrupted?: false}

    state = init_state() |> push_buffer(b1)
    assert {[], state} = handle_event(state, response_end)

    {actions, state} = demand(state)
    assert [buffer: {:output, %Buffer{payload: ^b1}}] = actions

    {actions, _state} = demand(state)
    silence = silence_of_ms(10)

    assert [event: {:output, ^response_end}, buffer: {:output, %Buffer{payload: ^silence}}] =
             actions
  end

  test "interrupted ResponseEnd is emitted immediately and flushes the queue" do
    response_end = %Events.ResponseEnd{interrupted?: true}

    state = init_state() |> push_buffer(payload_of_ms(20, <<1, 1>>))

    assert {[event: {:output, ^response_end}], state} = handle_event(state, response_end)

    # The queued buffer was discarded; silence falls back to the 40 ms default
    # since no buffer was ever popped
    {actions, _state} = demand(state)
    silence = silence_of_ms(40)
    assert [buffer: {:output, %Buffer{payload: ^silence}}] = actions
  end
end
