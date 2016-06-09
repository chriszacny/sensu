require "sensu/api/utilities/resolve_event"

module Sensu
  module API
    module Routes
      module Clients
        include Utilities::ResolveEvent

        CLIENTS_URI = /^\/clients$/
        CLIENT_URI = /^\/clients\/([\w\.-]+)$/
        CLIENT_HISTORY_URI = /^\/clients\/([\w\.-]+)\/history$/

        def post_clients
          read_data do |client|
            client[:keepalives] = client.fetch(:keepalives, false)
            client[:version] = VERSION
            client[:timestamp] = Time.now.to_i
            validator = Validators::Client.new
            if validator.valid?(client)
              @redis.set("client:#{client[:name]}", Sensu::JSON.dump(client)) do
                @redis.sadd("clients", client[:name]) do
                  @response_content = {:name => client[:name]}
                  created!
                end
              end
            else
              bad_request!
            end
          end
        end

        def get_clients
          @response_content = []
          @redis.smembers("clients") do |clients|
            clients = pagination(clients)
            unless clients.empty?
              clients.each_with_index do |client_name, index|
                @redis.get("client:#{client_name}") do |client_json|
                  unless client_json.nil?
                    @response_content << Sensu::JSON.load(client_json)
                  else
                    @logger.error("client data missing from registry", :client_name => client_name)
                    @redis.srem("clients", client_name)
                  end
                  if index == clients.length - 1
                    respond
                  end
                end
              end
            else
              respond
            end
          end
        end

        def get_client
          client_name = CLIENT_URI.match(@http_request_uri)[1]
          @redis.get("client:#{client_name}") do |client_json|
            unless client_json.nil?
              @response_content = Sensu::JSON.load(client_json)
              respond
            else
              not_found!
            end
          end
        end

        def get_client_history
          client_name = CLIENT_HISTORY_URI.match(@http_request_uri)[1]
          @response_content = []
          @redis.smembers("result:#{client_name}") do |checks|
            unless checks.empty?
              checks.each_with_index do |check_name, index|
                result_key = "#{client_name}:#{check_name}"
                history_key = "history:#{result_key}"
                @redis.lrange(history_key, -21, -1) do |history|
                  history.map! do |status|
                    status.to_i
                  end
                  @redis.get("result:#{result_key}") do |result_json|
                    unless result_json.nil?
                      result = Sensu::JSON.load(result_json)
                      last_execution = result[:executed]
                      unless history.empty? || last_execution.nil?
                        item = {
                          :check => check_name,
                          :history => history,
                          :last_execution => last_execution.to_i,
                          :last_status => history.last,
                          :last_result => result
                        }
                        @response_content << item
                      end
                    end
                    if index == checks.length - 1
                      respond
                    end
                  end
                end
              end
            else
              respond
            end
          end
        end

        def delete_client
          client_name = CLIENT_URI.match(@http_request_uri)[1]
          @redis.get("client:#{client_name}") do |client_json|
            unless client_json.nil?
              @redis.hgetall("events:#{client_name}") do |events|
                events.each do |check_name, event_json|
                  resolve_event(event_json)
                end
                delete_client = Proc.new do |attempts|
                  attempts += 1
                  @redis.hgetall("events:#{client_name}") do |events|
                    if events.empty? || attempts == 5
                      @logger.info("deleting client from registry", :client_name => client_name)
                      @redis.srem("clients", client_name) do
                        @redis.del("client:#{client_name}")
                        @redis.del("client:#{client_name}:signature")
                        @redis.del("events:#{client_name}")
                        @redis.smembers("result:#{client_name}") do |checks|
                          checks.each do |check_name|
                            result_key = "#{client_name}:#{check_name}"
                            @redis.del("result:#{result_key}")
                            @redis.del("history:#{result_key}")
                          end
                          @redis.del("result:#{client_name}")
                        end
                      end
                    else
                      EM::Timer.new(1) do
                        delete_client.call(attempts)
                      end
                    end
                  end
                end
                delete_client.call(0)
                @response_content = {:issued => Time.now.to_i}
                accepted!
              end
            else
              not_found!
            end
          end
        end
      end
    end
  end
end
