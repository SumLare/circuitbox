require 'test_helper'
require 'circuitbox'

class CircuitBreakerTest < Minitest::Test
  SUCCESSFUL_RESPONSE_STRING = "Success!"
  RequestFailureError = Timeout::Error
  class ConnectionError < StandardError; end;
  class SomeOtherError < StandardError; end;

  def setup
    Circuitbox::CircuitBreaker.reset
  end

  def test_goes_into_half_open_state_on_sleep
    circuit = Circuitbox::CircuitBreaker.new(:yammer)
    circuit.send(:open!)
    assert circuit.send(:half_open?)
  end

  describe "when in half open state" do
    before do
      Circuitbox::CircuitBreaker.reset
      @circuit = Circuitbox::CircuitBreaker.new(:yammer)
    end

    it "opens circuit on next failed request" do
      @circuit.stubs(half_open?: true)
      @circuit.expects(:open!)
      @circuit.run { raise RequestFailureError }
    end

    it "closes circuit on successful request" do
      @circuit.send(:half_open!)
      @circuit.run { 'success' }
      assert !@circuit.send(:half_open?)
      assert !@circuit.send(:open?)
    end
  end

  def test_should_use_timeout_class_if_exceptions_are_not_defined
    circuit = Circuitbox::CircuitBreaker.new(:yammer, timeout_seconds: 45)
    circuit.expects(:timeout).with(45).once
    emulate_circuit_run(circuit, :success, StandardError)
  end

  def test_should_not_use_timeout_class_if_custom_exceptions_are_defined
    circuit = Circuitbox::CircuitBreaker.new(:yammer, exceptions: [ConnectionError])
    circuit.expects(:timeout).never
    emulate_circuit_run(circuit, :success, StandardError)
  end

  def test_should_return_response_if_it_doesnt_timeout
    circuit = Circuitbox::CircuitBreaker.new(:yammer)
    response = emulate_circuit_run(circuit, :success, SUCCESSFUL_RESPONSE_STRING)
    assert_equal SUCCESSFUL_RESPONSE_STRING, response
  end

  def test_timeout_seconds_run_options_overrides_circuit_options
    circuit = Circuitbox::CircuitBreaker.new(:yammer, timeout_seconds: 60)
    circuit.expects(:timeout).with(30).once
    circuit.run(timeout_seconds: 30) { true }
  end

  def test_catches_connection_error_failures_if_defined
    circuit = Circuitbox::CircuitBreaker.new(:yammer, :exceptions => [ConnectionError])
    response = emulate_circuit_run(circuit, :failure, ConnectionError)
    assert_equal nil, response
  end

  def test_doesnt_catch_out_of_scope_exceptions
    circuit = Circuitbox::CircuitBreaker.new(:yammer, :exceptions => [ConnectionError, RequestFailureError])

    assert_raises SomeOtherError do
      emulate_circuit_run(circuit, :failure, SomeOtherError)
    end
  end

  def test_records_response_failure
    circuit = Circuitbox::CircuitBreaker.new(:yammer, :exceptions => [RequestFailureError])
    circuit.expects(:log_event).with(:failure)
    emulate_circuit_run(circuit, :failure, RequestFailureError)
  end

  def test_records_response_success
    circuit = Circuitbox::CircuitBreaker.new(:yammer)
    circuit.expects(:log_event).with(:success)
    emulate_circuit_run(circuit, :success, SUCCESSFUL_RESPONSE_STRING)
  end

  def test_does_not_send_request_if_circuit_is_open
    circuit = Circuitbox::CircuitBreaker.new(:yammer)
    circuit.stubs(:open? => true)
    circuit.expects(:yield).never
    response = emulate_circuit_run(circuit, :failure, RequestFailureError)
    assert_equal nil, response
  end

  def test_returns_nil_response_on_failed_request
    circuit = Circuitbox::CircuitBreaker.new(:yammer)
    response = emulate_circuit_run(circuit, :failure, RequestFailureError)
    assert_equal nil, response
  end

  def test_puts_circuit_to_sleep_once_opened
    circuit = Circuitbox::CircuitBreaker.new(:yammer)
    circuit.stubs(:open? => true)

    assert !circuit.send(:open_flag?)
    emulate_circuit_run(circuit, :failure, RequestFailureError)
    assert circuit.send(:open_flag?)

    circuit.expects(:open!).never
    emulate_circuit_run(circuit, :failure, RequestFailureError)
  end

  def test_open_is_true_if_open_flag
    circuit = Circuitbox::CircuitBreaker.new(:yammer)
    circuit.stubs(:open_flag? => true)
    assert circuit.open?
  end

  def test_open_checks_if_volume_threshold_has_passed
    circuit = Circuitbox::CircuitBreaker.new(:yammer)
    circuit.stubs(:open_flag? => false)

    circuit.expects(:passed_volume_threshold?).once
    circuit.open?
  end

  def test_open_checks_error_rate_threshold
    circuit = Circuitbox::CircuitBreaker.new(:yammer)
    circuit.stubs(:open_flag? => false, 
                  :passed_volume_threshold? => true)

    circuit.expects(:passed_rate_threshold?).once
    circuit.open?
  end

  def test_open_is_false_if_awake_and_under_rate_threshold
    circuit = Circuitbox::CircuitBreaker.new(:yammer)
    circuit.stubs(:open_flag? => false, 
                  :passed_volume_threshold? => false,
                  :passed_rate_threshold => false)

    assert !circuit.open?
  end

  def test_error_rate_threshold_calculation
    circuit = Circuitbox::CircuitBreaker.new(:yammer)
    circuit.stubs(:failure_count => 3, :success_count => 2)
    assert circuit.send(:passed_rate_threshold?)

    circuit.stubs(:failure_count => 2, :success_count => 3)
    assert !circuit.send(:passed_rate_threshold?)
  end

  def test_logs_and_retrieves_success_events
    circuit = Circuitbox::CircuitBreaker.new(:yammer)
    5.times { circuit.send(:log_event, :success) }
    assert_equal 5, circuit.send(:success_count)
  end

  def test_logs_and_retrieves_failure_events
    circuit = Circuitbox::CircuitBreaker.new(:yammer)
    5.times { circuit.send(:log_event, :failure) }
    assert_equal 5, circuit.send(:failure_count)
  end

  def test_logs_events_by_minute
    circuit = Circuitbox::CircuitBreaker.new(:yammer)

    Timecop.travel(Time.now.change(sec: 5))
    4.times { circuit.send(:log_event, :success) }
    assert_equal 4, circuit.send(:success_count)

    Timecop.travel(1.minute.from_now)
    7.times { circuit.send(:log_event, :success) }
    assert_equal 7, circuit.send(:success_count)

    Timecop.travel(30.seconds.from_now)
    circuit.send(:log_event, :success)
    assert_equal 8, circuit.send(:success_count)

    Timecop.travel(50.seconds.from_now)
    assert_equal 0, circuit.send(:success_count)
  end

  def test_notifies_on_open_circuit
    circuit = Circuitbox::CircuitBreaker.new(:yammer)
    Circuitbox::Notifier.expects(:notify).with(:open, :yammer, nil)
    circuit.send(:log_event, :open)
  end
  
  def emulate_circuit_run(circuit, response_type, response_value)
    circuit.run do
      case response_type
      when :failure
        raise response_value
      when :success
        response_value
      end
    end
  rescue RequestFailureError
    nil
  end
end
