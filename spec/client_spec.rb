require File.dirname(__FILE__) + '/../lib/sensu/client.rb'
require File.dirname(__FILE__) + '/helpers.rb'

describe 'Sensu::Client' do
  include Helpers

  before do
    @client = Sensu::Client.new(options)
  end

  it 'can connect to rabbitmq' do
    async_wrapper do
      @client.setup_transport
      async_done
    end
  end

  it 'can send a keepalive' do
    async_wrapper do
      keepalive_queue do |queue|
        @client.setup_transport
        @client.publish_keepalive
        queue.subscribe do |payload|
          keepalive = Oj.load(payload)
          expect(keepalive[:name]).to eq('i-424242')
          expect(keepalive[:service][:password]).to eq('REDACTED')
          async_done
        end
      end
    end
  end

  it 'can schedule keepalive publishing' do
    async_wrapper do
      keepalive_queue do |queue|
        @client.setup_transport
        @client.setup_keepalives
        queue.subscribe do |payload|
          keepalive = Oj.load(payload)
          expect(keepalive[:name]).to eq('i-424242')
          async_done
        end
      end
    end
  end

  it 'can send a check result' do
    async_wrapper do
      result_queue do |queue|
        @client.setup_transport
        check = result_template[:check]
        @client.publish_result(check)
        queue.subscribe do |payload|
          result = Oj.load(payload)
          expect(result[:client]).to eq('i-424242')
          expect(result[:check][:name]).to eq('foobar')
          async_done
        end
      end
    end
  end

  it 'can execute a check command' do
    async_wrapper do
      result_queue do |queue|
        @client.setup_transport
        @client.execute_check_command(check_template)
        queue.subscribe do |payload|
          result = Oj.load(payload)
          expect(result[:client]).to eq('i-424242')
          expect(result[:check][:output]).to eq("WARNING\n")
          expect(result[:check]).to have_key(:executed)
          async_done
        end
      end
    end
  end

  it 'can substitute check command tokens with attributes, default values, and execute it' do
    async_wrapper do
      result_queue do |queue|
        @client.setup_transport
        check = check_template
        check[:command] = 'echo :::nested.attribute|default::: :::missing|default::: :::missing|::: :::nested.attribute:::::::nested.attribute:::'
        @client.execute_check_command(check)
        queue.subscribe do |payload|
          result = Oj.load(payload)
          expect(result[:client]).to eq('i-424242')
          expect(result[:check][:output]).to eq("true default true:true\n")
          async_done
        end
      end
    end
  end

  it 'can run a check extension' do
    async_wrapper do
      result_queue do |queue|
        @client.setup_transport
        check = {
          :name => 'sensu_gc_metrics'
        }
        @client.run_check_extension(check)
        queue.subscribe do |payload|
          result = Oj.load(payload)
          expect(result[:client]).to eq('i-424242')
          expect(result[:check][:output]).to start_with('{')
          expect(result[:check]).to have_key(:executed)
          async_done
        end
      end
    end
  end

  it 'can setup subscriptions' do
    async_wrapper do
      @client.setup_transport
      @client.setup_subscriptions
      timer(1) do
        amq.fanout('test', :passive => true) do |exchange, declare_ok|
          expect(declare_ok).to be_an_instance_of(AMQ::Protocol::Exchange::DeclareOk)
          expect(exchange.status).to eq(:opening)
          async_done
        end
      end
    end
  end

  it 'can receive a check request and execute the check' do
    async_wrapper do
      result_queue do |queue|
        @client.setup_transport
        @client.setup_subscriptions
        timer(1) do
          amq.fanout('test').publish(Oj.dump(check_template))
        end
        queue.subscribe do |payload|
          result = Oj.load(payload)
          expect(result[:client]).to eq('i-424242')
          expect(result[:check][:output]).to eq("WARNING\n")
          expect(result[:check][:status]).to eq(1)
          async_done
        end
      end
    end
  end

  it 'can receive a check request and not execute the check due to safe mode' do
    async_wrapper do
      result_queue do |queue|
        @client.safe_mode = true
        @client.setup_transport
        @client.setup_subscriptions
        timer(1) do
          amq.fanout('test').publish(Oj.dump(check_template))
        end
        queue.subscribe do |payload|
          result = Oj.load(payload)
          expect(result[:client]).to eq('i-424242')
          expect(result[:check][:output]).to include('safe mode')
          expect(result[:check][:status]).to eq(3)
          async_done
        end
      end
    end
  end

  it 'can schedule standalone check execution' do
    async_wrapper do
      result_queue do |queue|
        @client.setup_transport
        @client.setup_standalone
        expected = ['standalone', 'sensu_gc_metrics']
        queue.subscribe do |payload|
          result = Oj.load(payload)
          expect(result[:client]).to eq('i-424242')
          expect(result[:check]).to have_key(:issued)
          expect(result[:check]).to have_key(:output)
          expect(result[:check]).to have_key(:status)
          expect(expected.delete(result[:check][:name])).not_to be_nil
          if expected.empty?
            async_done
          end
        end
      end
    end
  end

  it 'can accept external result input via sockets' do
    async_wrapper do
      result_queue do |queue|
        @client.setup_transport
        @client.setup_sockets
        timer(1) do
          EM::connect('127.0.0.1', 3030, nil) do |socket|
            socket.send_data('{"name": "tcp", "output": "tcp", "status": 1}')
            socket.close_connection_after_writing
          end
          EM::open_datagram_socket('127.0.0.1', 0, nil) do |socket|
            data = '{"name": "udp", "output": "udp", "status": 1}'
            socket.send_datagram(data, '127.0.0.1', 3030)
            socket.close_connection_after_writing
          end
        end
        expected = ['tcp', 'udp']
        queue.subscribe do |payload|
          result = Oj.load(payload)
          expect(result[:client]).to eq('i-424242')
          expect(expected.delete(result[:check][:name])).not_to be_nil
          if expected.empty?
            async_done
          end
        end
      end
    end
  end
end
