defmodule Membrane.Gemini.EndpointStateMachineTest do
  # State-machine corner cases exercised by sending session-callback messages
  # (`{:on_message, %ServerMessage{}}`, `{:on_transcription, ...}`,
  # `{:on_error, ...}`) straight to the Endpoint process.
  #
  # Round-trip tests through the scripted mock (endpoint_test.exs) are the
  # default — they also exercise gemini_ex's decode/dispatch, so they catch
  # contract drift. Direct injection is reserved for corners that are awkward
  # to sequence over the socket; fixtures still go through
  # `ServerMessage.from_api/1` (via `GeminiMock.Frames.to_server_message/1`)
  # on the same wire maps the mock serves, to minimize that drift.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Membrane.Gemini.Test.PipelineHelper
  import Membrane.Testing.Assertions

  alias GeminiMock.{Frames, Scenario}
  alias Membrane.Buffer
  alias Membrane.Gemini.Events
  alias Membrane.Testing

  @moduletag timeout: 30_000

  defp start!(mode \\ :raw) do
    extra_opts = Scenario.setup!()
    pipeline = Testing.Pipeline.start_link_supervised!(spec: bin_spec(mode, extra_opts))
    conn = Scenario.await_connection()
    assert %{"setup" => _setup} = Scenario.await_client_frame(conn)
    endpoint = Testing.Pipeline.get_child_pid!(pipeline, [:gemini, :gemini])
    await_playing(endpoint)
    {pipeline, conn, endpoint}
  end

  # Injected messages may produce actions (events, buffers) which are illegal
  # before the element enters playback, so wait for it.
  defp await_playing(endpoint) do
    case :sys.get_state(endpoint).playback do
      :playing ->
        :ok

      _other ->
        Process.sleep(10)
        await_playing(endpoint)
    end
  end

  defp inject_message(endpoint, frame) do
    send(endpoint, {:on_message, Frames.to_server_message(frame)})
    # Forces the endpoint to process the message before we assert on its effects
    :sys.get_state(endpoint)
    :ok
  end

  defp complete_turn(pipeline, conn, prompt) do
    push_text(pipeline, prompt)
    assert %{"realtimeInput" => %{"text" => ^prompt}} = Scenario.await_client_frame(conn)
    Scenario.push(conn, [Frames.audio_of_ms(10), Frames.generation_complete()])
    assert_sink_event(pipeline, :sink, %Events.ResponseStart{})
    assert_sink_event(pipeline, :sink, %Events.ResponseEnd{interrupted?: false})
  end

  test "interrupted in standby is a no-op" do
    {pipeline, conn, endpoint} = start!()

    inject_message(endpoint, Frames.interrupted())

    refute_sink_event(pipeline, :sink, %Events.ResponseEnd{}, 100)
    complete_turn(pipeline, conn, "still fine?")
  end

  test "a multi-part modelTurn emits a buffer and a Thinking event from one message" do
    {pipeline, _conn, endpoint} = start!()

    pcm = :binary.copy(<<7, 7>>, 240)

    inject_message(
      endpoint,
      Frames.model_turn([
        %{
          "inlineData" => %{"mimeType" => "audio/pcm;rate=24000", "data" => Base.encode64(pcm)}
        },
        %{"thought" => true, "text" => "in the same frame"}
      ])
    )

    assert {:event, %Events.ResponseStart{}} = pop_sink_payload(pipeline)
    assert {:buffer, %Buffer{payload: ^pcm}} = pop_sink_payload(pipeline)
    assert {:event, %Events.Thinking{text: "in the same frame"}} = pop_sink_payload(pipeline)
  end

  test "an unrecognised model turn part is logged and skipped" do
    {pipeline, conn, endpoint} = start!()

    log =
      capture_log(fn ->
        inject_message(
          endpoint,
          Frames.model_turn([%{"functionCall" => %{"name" => "some_tool"}}])
        )
      end)

    assert log =~ "Unrecognised response part"
    refute_sink_buffer(pipeline, :sink, %Buffer{}, 100)

    # The unrecognised part still started a response; complete it before the
    # next prompt. NOTE: sending the text prompt before generationComplete is
    # processed would crash the endpoint — `handle_generation_complete/1` has
    # no clause for raw mode in the :text_sent/:text_interrupt statuses
    # (lib/endpoint.ex) — hence the explicit synchronisation on ResponseEnd.
    Scenario.push(conn, Frames.generation_complete())
    assert_sink_event(pipeline, :sink, %Events.ResponseEnd{interrupted?: false})

    complete_turn(pipeline, conn, "still fine?")
  end

  test "session errors are logged without crashing the endpoint" do
    {pipeline, conn, endpoint} = start!()

    log =
      capture_log(fn ->
        send(endpoint, {:on_error, :connection_hiccup})
        :sys.get_state(endpoint)
      end)

    assert log =~ "Unhandled error received by session"
    complete_turn(pipeline, conn, "still fine?")
  end

  test "output transcriptions are suppressed after a text barge-in" do
    {pipeline, conn, endpoint} = start!()

    push_text(pipeline, "prompt")
    assert %{"realtimeInput" => _input} = Scenario.await_client_frame(conn)
    Scenario.push(conn, Frames.thinking("t"))
    assert_sink_event(pipeline, :sink, %Events.ResponseStart{})

    # Barge-in puts the endpoint into :text_interrupt
    push_text(pipeline, "barge-in")
    assert_sink_event(pipeline, :sink, %Events.ResponseEnd{interrupted?: true})
    assert %{"realtimeInput" => _input} = Scenario.await_client_frame(conn)

    # The transcription callback delivers raw string-keyed maps
    send(endpoint, {:on_transcription, {:output, %{"text" => "of the aborted response"}}})
    :sys.get_state(endpoint)

    refute_sink_event(pipeline, :sink, %Events.Transcript{audio_origin: :server}, 100)
  end

  test "messages arriving after EOS are swallowed with a log" do
    {pipeline, conn, endpoint} = start!()

    complete_turn(pipeline, conn, "prompt")
    eos(pipeline, :audio_src)
    eos(pipeline, :text_src)
    assert_end_of_stream(pipeline, :sink)

    log =
      capture_log(fn ->
        inject_message(endpoint, Frames.output_transcription("too late"))
      end)

    assert log =~ "Message received after element went into EOS status"
    refute_sink_event(pipeline, :sink, %Events.Transcript{}, 100)
  end

  test "turnComplete without usageMetadata does not complete a paced turn" do
    # Documents current behaviour: the endpoint's turn_complete clause requires
    # usageMetadata to be present (lib/endpoint.ex), so a bare turnComplete hits
    # the unrecognised-message fallback and paced mode keeps waiting. Worth
    # raising with maintainers whether a bare turnComplete should complete the
    # turn as well.
    {pipeline, conn, _endpoint} = start!(:paced)

    push_text(pipeline, "prompt")
    assert %{"realtimeInput" => _input} = Scenario.await_client_frame(conn)
    Scenario.push(conn, [Frames.audio_of_ms(10), Frames.generation_complete()])
    assert_sink_event(pipeline, :sink, %Events.ResponseStart{})

    log =
      capture_log(fn ->
        Scenario.push(conn, %{"serverContent" => %{"turnComplete" => true}})
        refute_sink_event(pipeline, :sink, %Events.ResponseEnd{}, 300)
      end)

    assert log =~ "Unrecognised message"

    # With usageMetadata attached the turn completes
    Scenario.push(conn, Frames.turn_complete())
    assert_sink_event(pipeline, :sink, %Events.ResponseEnd{interrupted?: false})
  end
end
